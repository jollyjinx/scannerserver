import Foundation
@testable import ScannerServerCore
import Testing

@Suite(
    "ScanSnap long-password hardware diagnostics",
    .serialized,
    .enabled(if: ScanSnapLongPasswordHardwareEnvironment.shouldRun)
)
struct ScanSnapLongPasswordHardwareTests {
    @Test(
        "A password whose identity exceeds 16 bytes can reserve the scanner",
        .timeLimit(.minutes(1))
    )
    func longPasswordCanReserveScanner() async throws {
        let scannerIPAddress = try #require(ScanSnapLongPasswordHardwareEnvironment.scannerIPAddress)
        let password = try #require(ScanSnapLongPasswordHardwareEnvironment.password)
        let identity = try ScanSnapIdentity.derive(fromPassword: password)
        let identityBytes = Array(identity.value.utf8)
        try #require(identityBytes.count > 16, "Use a password whose derived identity exceeds 16 bytes.")
        try #require(
            identityBytes.count <= ScanSnapPacketBuilder.pairingIdentityFieldLength,
            "The VENS password identity field is 48 bytes."
        )

        let network = SystemScanSnapSetupNetworkProvider()
        let clientIPAddress = try await network.clientIPAddress(for: scannerIPAddress)
        let interface = try #require(
            try await network.ipv4Interfaces().first(where: { $0.ipAddress == clientIPAddress }),
            "Could not identify the interface used to reach the scanner."
        )
        let clientMACAddress = try await network.clientMACAddress(preferredInterface: interface.name)
        let harness = ScanSnapLongPasswordHardwareHarness(
            scannerIPAddress: scannerIPAddress,
            clientIPAddress: clientIPAddress,
            clientMACAddress: clientMACAddress
        )

        let truncatedStatus = try await harness.probe(identity: identity, frame: .legacyTruncated)
        print("ScanSnap long-password probe: legacy-truncated status \(truncatedStatus.code)")
        #expect(
            truncatedStatus != .accepted,
            "The diagnostic password unexpectedly fits the existing 16-byte behavior."
        )

        let fullWidthLegacyStatus = try await harness.probe(identity: identity, frame: .legacyFullWidth)
        print("ScanSnap long-password probe: legacy-full-width status \(fullWidthLegacyStatus.code)")
        if fullWidthLegacyStatus == .accepted {
            return
        }

        let officialStatus = try await harness.probe(identity: identity, frame: .officialPasswordReservation)
        print("ScanSnap long-password probe: official-password-reservation status \(officialStatus.code)")
        #expect(
            officialStatus == .accepted,
            "Neither full-width pairing frame accepted the password-derived identity."
        )
    }
}

private enum ScanSnapLongPasswordHardwareEnvironment {
    private static let environment = ProcessInfo.processInfo.environment

    static let shouldRun = environment["SCANNERSERVER_RUN_SCANSNAP_HARDWARE_TESTS"] == "1"
    static let scannerIPAddress = nonEmpty(environment["SCANSNAP_TEST_IP"])
    static let password = nonEmpty(environment["SCANSNAP_TEST_PASSWORD"])

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private actor ScanSnapLongPasswordHardwareHarness {
    enum Frame {
        case legacyTruncated
        case legacyFullWidth
        case officialPasswordReservation
    }

    private let scannerIPAddress: String
    private let clientIPAddress: String
    private let clientMACAddress: [UInt8]
    private let udpFactory = POSIXScanSnapUDPTransportFactory()
    private let tcpFactory = POSIXScanSnapTCPConnectionFactory()

    init(scannerIPAddress: String, clientIPAddress: String, clientMACAddress: [UInt8]) {
        self.scannerIPAddress = scannerIPAddress
        self.clientIPAddress = clientIPAddress
        self.clientMACAddress = clientMACAddress
    }

    func probe(identity: ScanSnapIdentity, frame: Frame) async throws -> ScanSnapPairingStatus {
        for attempt in 1...4 {
            let device = try await register()
            let packet = try pairingPacket(
                identity: identity,
                frame: frame,
                deviceMetadata: device?.metadata ?? [UInt8](repeating: 0, count: 8)
            )
            let status = try await sendPairingPacket(packet)
            if status == .accepted {
                try await releaseSession()
                return status
            }
            guard status == .sessionBusy, attempt < 4 else { return status }
            try await releaseSession()
            try await Task.sleep(for: .seconds(1))
        }
        preconditionFailure("Pairing probe must return within its retry limit.")
    }

    private func register() async throws -> ScanSnapDevice? {
        let transport = try await udpFactory.makeTransport()
        do {
            do {
                _ = try await transport.bind(
                    to: ScanSnapSocketAddress(
                        host: clientIPAddress,
                        port: ScanSnapPacketBuilder.registrationSourcePort
                    ),
                    allowsBroadcast: false
                )
            } catch {
                _ = try await transport.bind(
                    to: ScanSnapSocketAddress(host: clientIPAddress, port: 0),
                    allowsBroadcast: false
                )
            }

            let packets = try ScanSnapPacketBuilder.registration(
                clientIPAddress: clientIPAddress,
                clientMACAddress: clientMACAddress
            ).all
            let scanner = ScanSnapSocketAddress(
                host: scannerIPAddress,
                port: ScanSnapPacketBuilder.registrationPort
            )
            for _ in 0..<4 {
                for packet in packets {
                    try await transport.send(packet, to: scanner)
                }
            }
            let datagram = try await transport.receive(maximumBytes: 256, timeoutMilliseconds: 3_000)
            await transport.close()
            guard let datagram, datagram.bytes.count >= VENSDeviceInfoParser.packetLength else {
                return nil
            }
            return try VENSDeviceInfoParser.parse(
                datagram.bytes,
                remoteIPAddress: datagram.remoteAddress.host
            )
        } catch {
            await transport.close()
            throw error
        }
    }

    private func sendPairingPacket(_ packet: [UInt8]) async throws -> ScanSnapPairingStatus {
        let connection = try await tcpFactory.connect(
            to: ScanSnapSocketAddress(host: scannerIPAddress, port: ScanSnapPacketBuilder.controlPort),
            binding: ScanSnapSocketAddress(host: clientIPAddress, port: 0),
            timeoutMilliseconds: 5_000
        )
        do {
            _ = try await connection.readExactly(16, timeoutMilliseconds: 5_000)
            try await connection.writeAll(packet, timeoutMilliseconds: 5_000)
            let response = try await connection.readExactly(12, timeoutMilliseconds: 5_000)
            await connection.close()
            return try ScanSnapPairingStatus.parse(response: response)
        } catch {
            await connection.close()
            throw error
        }
    }

    private func releaseSession() async throws {
        let connection = try await tcpFactory.connect(
            to: ScanSnapSocketAddress(host: scannerIPAddress, port: ScanSnapPacketBuilder.dataPort),
            binding: ScanSnapSocketAddress(host: clientIPAddress, port: 0),
            timeoutMilliseconds: 5_000
        )
        do {
            _ = try await connection.readExactly(16, timeoutMilliseconds: 5_000)
            try await connection.writeAll(
                ScanSnapPacketBuilder.releaseFrame(clientMACAddress: clientMACAddress),
                timeoutMilliseconds: 5_000
            )
            _ = try await connection.readExactly(16, timeoutMilliseconds: 5_000)
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    private func pairingPacket(
        identity: ScanSnapIdentity,
        frame: Frame,
        deviceMetadata: [UInt8]
    ) throws -> [UInt8] {
        let timestamp = Self.timestamp(Date())
        switch frame {
        case .legacyTruncated:
            var packet = try ScanSnapPacketBuilder.pairing(
                clientMACAddress: clientMACAddress,
                identity: identity,
                clientIPAddress: clientIPAddress,
                timestamp: timestamp,
                deviceMetadata: deviceMetadata
            )
            packet.replaceSubrange(
                52..<100,
                with: repeatElement(UInt8(0), count: ScanSnapPacketBuilder.pairingIdentityFieldLength)
            )
            let identityBytes = Array(identity.value.utf8.prefix(16))
            packet.replaceSubrange(52..<(52 + identityBytes.count), with: identityBytes)
            return packet

        case .legacyFullWidth:
            return try ScanSnapPacketBuilder.pairing(
                clientMACAddress: clientMACAddress,
                identity: identity,
                clientIPAddress: clientIPAddress,
                timestamp: timestamp,
                deviceMetadata: deviceMetadata
            )

        case .officialPasswordReservation:
            let identityBytes = Array(
                identity.value.utf8.prefix(ScanSnapPacketBuilder.pairingIdentityFieldLength)
            )
            let clientIPBytes = try ScanSnapByteCodec.ipv4Bytes(clientIPAddress)
            var packet = [UInt8](repeating: 0, count: 384)
            packet.replaceSubrange(0..<4, with: ScanSnapByteCodec.bigEndianBytes(UInt32(packet.count)))
            packet.replaceSubrange(4..<8, with: Array("VENS".utf8))
            packet.replaceSubrange(8..<12, with: ScanSnapByteCodec.bigEndianBytes(UInt32(0x11)))
            packet.replaceSubrange(16..<22, with: clientMACAddress)
            packet.replaceSubrange(32..<36, with: ScanSnapByteCodec.bigEndianBytes(UInt32(0x0004_0500)))
            packet.replaceSubrange(36..<40, with: ScanSnapByteCodec.bigEndianBytes(UInt32(1)))
            packet.replaceSubrange(40..<44, with: ScanSnapByteCodec.bigEndianBytes(UInt32(1)))
            packet.replaceSubrange(44..<48, with: clientIPBytes)
            packet.replaceSubrange(
                50..<52,
                with: ScanSnapByteCodec.bigEndianBytes(ScanSnapPacketBuilder.buttonNoticePort)
            )
            packet.replaceSubrange(52..<(52 + identityBytes.count), with: identityBytes)
            packet.replaceSubrange(100..<102, with: ScanSnapByteCodec.bigEndianBytes(timestamp.year))
            packet[102] = timestamp.month
            packet[103] = timestamp.day
            packet[104] = timestamp.hour
            packet[105] = timestamp.minute
            packet[106] = timestamp.second
            packet.replaceSubrange(116..<120, with: ScanSnapByteCodec.bigEndianBytes(UInt32(0xFFFF_8170)))
            return packet
        }
    }

    private static func timestamp(_ date: Date) -> ScanSnapTimestamp {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return ScanSnapTimestamp(
            year: UInt16(components.year ?? 1970),
            month: UInt8(components.month ?? 1),
            day: UInt8(components.day ?? 1),
            hour: UInt8(components.hour ?? 0),
            minute: UInt8(components.minute ?? 0),
            second: UInt8(components.second ?? 0)
        )
    }
}
