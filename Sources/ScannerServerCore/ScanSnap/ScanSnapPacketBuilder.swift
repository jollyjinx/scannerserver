public struct ScanSnapDiscoveryPackets: Sendable, Hashable {
    public let vens: [UInt8]
    public let ssnr: [UInt8]
}

public struct ScanSnapRegistrationPackets: Sendable, Hashable {
    public let vens: [UInt8]
    public let ssnr: [UInt8]
    public let v2ss: [UInt8]

    public var all: [[UInt8]] { [vens, ssnr, v2ss] }
}

public struct ScanSnapTimestamp: Sendable, Hashable {
    public let year: UInt16
    public let month: UInt8
    public let day: UInt8
    public let hour: UInt8
    public let minute: UInt8
    public let second: UInt8

    public init(year: UInt16, month: UInt8, day: UInt8, hour: UInt8, minute: UInt8, second: UInt8) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }
}

public enum ScanSnapButtonSequenceStep: Sendable, Hashable {
    case handshakeCommand(UInt32)
    case initializationFrame(index: Int)
}

public enum ScanSnapPacketBuilder {
    public static let startupAdvertisementPort: UInt16 = 53_220
    public static let registrationSourcePort: UInt16 = 55_264
    public static let registrationPort: UInt16 = 52_217
    public static let controlPort: UInt16 = 53_219
    public static let dataPort: UInt16 = 53_218
    public static let buttonNoticePort: UInt16 = 55_265
    public static let pairingIdentityFieldLength = 48

    public static let buttonHandshakeCommands: [UInt32] = [0x13, 0x30]
    public static let buttonInitializationSequence: [ScanSnapButtonSequenceStep] = [
        .handshakeCommand(0x13),
        .initializationFrame(index: 0),
        .handshakeCommand(0x30),
        .initializationFrame(index: 1),
        .initializationFrame(index: 2),
        .initializationFrame(index: 3),
        .initializationFrame(index: 4),
        .initializationFrame(index: 5),
        .initializationFrame(index: 6),
    ]

    public static func discovery(
        clientIPAddress: String,
        clientPort: UInt16,
        token: [UInt8]
    ) throws -> ScanSnapDiscoveryPackets {
        try requireByteCount(token, field: "discovery token", expected: 8)
        let ip = try ScanSnapByteCodec.ipv4Bytes(clientIPAddress)

        var vens = [UInt8](repeating: 0, count: 32)
        vens.replaceBytes(at: 0, with: Array("VENS".utf8))
        vens.replaceBytes(at: 8, with: ip)
        vens.replaceBytes(at: 12, with: token)
        vens.replaceBytes(at: 22, with: ScanSnapByteCodec.bigEndianBytes(clientPort))
        vens[25] = 0x10

        var ssnr = [UInt8](repeating: 0, count: 32)
        ssnr.replaceBytes(at: 0, with: Array("ssNR".utf8))
        ssnr.replaceBytes(at: 8, with: ip)
        ssnr.replaceBytes(at: 12, with: token)
        ssnr.replaceBytes(at: 22, with: ScanSnapByteCodec.bigEndianBytes(clientPort))
        ssnr[24] = 0x01

        return ScanSnapDiscoveryPackets(vens: vens, ssnr: ssnr)
    }

    public static func registration(
        clientIPAddress: String,
        clientMACAddress: [UInt8]
    ) throws -> ScanSnapRegistrationPackets {
        try requireByteCount(clientMACAddress, field: "client MAC address", expected: 6)
        let ip = try ScanSnapByteCodec.ipv4Bytes(clientIPAddress)

        func packet(signature: String, version: UInt32?, flag: UInt16) -> [UInt8] {
            var packet = [UInt8](repeating: 0, count: 32)
            packet.replaceBytes(at: 0, with: Array(signature.utf8))
            if let version {
                packet.replaceBytes(at: 4, with: ScanSnapByteCodec.bigEndianBytes(version))
            }
            packet.replaceBytes(at: 8, with: ip)
            packet.replaceBytes(at: 12, with: clientMACAddress)
            packet[22] = 0xD7
            packet[23] = 0xE0
            packet.replaceBytes(at: 24, with: ScanSnapByteCodec.bigEndianBytes(flag))
            return packet
        }

        return ScanSnapRegistrationPackets(
            vens: packet(signature: "VENS", version: nil, flag: 0x0010),
            ssnr: packet(signature: "ssNR", version: nil, flag: 0x0100),
            v2ss: packet(signature: "V2ss", version: 1, flag: 0x1000)
        )
    }

    public static func heartbeat(
        clientIPAddress: String,
        clientMACAddress: [UInt8]
    ) throws -> [UInt8] {
        var packet = try registration(
            clientIPAddress: clientIPAddress,
            clientMACAddress: clientMACAddress
        ).vens
        packet.replaceBytes(at: 4, with: ScanSnapByteCodec.bigEndianBytes(UInt32(1)))
        packet.replaceBytes(at: 24, with: ScanSnapByteCodec.bigEndianBytes(UInt16(0x1000)))
        return packet
    }

    public static func vensFrame(
        clientMACAddress: [UInt8],
        command: [UInt8]
    ) throws -> [UInt8] {
        try requireByteCount(clientMACAddress, field: "client MAC address", expected: 6)
        let length = 32 + command.count
        precondition(length <= Int(UInt32.max))

        var packet = [UInt8](repeating: 0, count: length)
        packet.replaceBytes(at: 0, with: ScanSnapByteCodec.bigEndianBytes(UInt32(length)))
        packet.replaceBytes(at: 4, with: Array("VENS".utf8))
        packet.replaceBytes(at: 8, with: ScanSnapByteCodec.bigEndianBytes(UInt32(1)))
        packet.replaceBytes(at: 16, with: clientMACAddress)
        packet.replaceBytes(at: 32, with: command)
        return packet
    }

    public static func pairing(
        clientMACAddress: [UInt8],
        identity: ScanSnapIdentity,
        clientIPAddress: String,
        timestamp: ScanSnapTimestamp,
        deviceMetadata: [UInt8]
    ) throws -> [UInt8] {
        try requireByteCount(clientMACAddress, field: "client MAC address", expected: 6)
        try requireByteCount(deviceMetadata, field: "device metadata", expected: 8)
        let ip = try ScanSnapByteCodec.ipv4Bytes(clientIPAddress)

        var packet = [UInt8](repeating: 0, count: 128)
        packet.replaceBytes(at: 0, with: ScanSnapByteCodec.bigEndianBytes(UInt32(packet.count)))
        packet.replaceBytes(at: 4, with: Array("VENS".utf8))
        packet.replaceBytes(at: 8, with: ScanSnapByteCodec.bigEndianBytes(UInt32(0x11)))
        packet.replaceBytes(at: 16, with: clientMACAddress)
        packet[33] = 0x06
        packet[34] = 0x1E
        packet.replaceBytes(at: 40, with: ScanSnapByteCodec.bigEndianBytes(UInt32(1)))
        packet.replaceBytes(at: 44, with: ip)
        packet[50] = 0xD7
        packet[51] = 0xE1
        packet.replaceBytes(at: 52, with: identity.asciiBytes.prefix(pairingIdentityFieldLength))
        packet.replaceBytes(at: 100, with: ScanSnapByteCodec.bigEndianBytes(timestamp.year))
        packet[102] = timestamp.month
        packet[103] = timestamp.day
        packet[104] = timestamp.hour
        packet[105] = timestamp.minute
        packet[106] = timestamp.second
        packet.replaceBytes(at: 108, with: deviceMetadata)
        packet.replaceBytes(at: 116, with: ScanSnapByteCodec.bigEndianBytes(UInt32(0xFFFF_E3E0)))
        return packet
    }

    public static func handshakeCommand(
        _ command: UInt32,
        clientMACAddress: [UInt8]
    ) throws -> [UInt8] {
        try requireByteCount(clientMACAddress, field: "client MAC address", expected: 6)
        var packet = [UInt8](repeating: 0, count: 32)
        packet.replaceBytes(at: 0, with: ScanSnapByteCodec.bigEndianBytes(UInt32(packet.count)))
        packet.replaceBytes(at: 4, with: Array("VENS".utf8))
        packet.replaceBytes(at: 8, with: ScanSnapByteCodec.bigEndianBytes(command))
        packet.replaceBytes(at: 16, with: clientMACAddress)
        return packet
    }

    public static func buttonInitializationFrames(clientMACAddress: [UInt8]) throws -> [[UInt8]] {
        try buttonInitializationCommands.map {
            try vensFrame(clientMACAddress: clientMACAddress, command: $0)
        }
    }

    public static func releaseFrame(clientMACAddress: [UInt8]) throws -> [UInt8] {
        try vensFrame(clientMACAddress: clientMACAddress, command: releaseCommand)
    }

    public static let buttonInitializationCommands: [[UInt8]] = [
        [0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12, 0x00, 0x00, 0x00, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        [0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xE7, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        [0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC2, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        [0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xE6, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        [0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0xE6, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x1E, 0x00, 0x00],
        [0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0xD5, 0x00, 0x00, 0x00, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        [0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xD6, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
    ]

    public static var releaseCommand: [UInt8] {
        buttonInitializationCommands[6]
    }

    private static func requireByteCount(
        _ bytes: [UInt8],
        field: String,
        expected: Int
    ) throws {
        guard bytes.count == expected else {
            throw ScanSnapProtocolError.invalidByteCount(
                field: field,
                expected: expected,
                actual: bytes.count
            )
        }
    }
}

private extension Array where Element == UInt8 {
    mutating func replaceBytes<C: Collection>(at offset: Int, with bytes: C) where C.Element == UInt8 {
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
