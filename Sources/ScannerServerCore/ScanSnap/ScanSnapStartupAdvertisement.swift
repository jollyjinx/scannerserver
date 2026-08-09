import Foundation

public struct ScanSnapStartupAdvertisement: Sendable, Hashable {
    public let scannerIPAddress: String
    public let scannerMACAddress: String

    public init(scannerIPAddress: String, scannerMACAddress: String) {
        self.scannerIPAddress = scannerIPAddress
        self.scannerMACAddress = scannerMACAddress
    }
}

public enum ScanSnapStartupAdvertisementParser {
    public static let packetLength = 48
    public static let command: UInt32 = 0x21

    public static func parse(
        _ packet: [UInt8],
        remoteIPAddress: String? = nil
    ) throws -> ScanSnapStartupAdvertisement {
        guard packet.count >= packetLength else {
            throw ScanSnapProtocolError.packetTooShort(minimum: packetLength, actual: packet.count)
        }

        let declaredLength = try ScanSnapByteCodec.readUInt32(from: packet, at: 0)
        guard declaredLength == UInt32(packetLength) else {
            throw ScanSnapProtocolError.invalidByteCount(
                field: "startup advertisement",
                expected: packetLength,
                actual: Int(declaredLength)
            )
        }

        let expectedSignature = Array("VENS".utf8)
        let actualSignature = Array(packet[4..<8])
        guard actualSignature == expectedSignature else {
            throw ScanSnapProtocolError.invalidSignature(
                expected: expectedSignature,
                actual: actualSignature
            )
        }

        let actualCommand = try ScanSnapByteCodec.readUInt32(from: packet, at: 8)
        guard actualCommand == command else {
            throw ScanSnapProtocolError.invalidCommand(expected: command, actual: actualCommand)
        }

        let advertisedIPAddress = try ScanSnapByteCodec.ipv4Address(packet[20..<24])
        let fallback = remoteIPAddress.flatMap { $0.isEmpty ? nil : $0 }
        let scannerIPAddress = advertisedIPAddress == "0.0.0.0"
            ? (fallback ?? advertisedIPAddress)
            : advertisedIPAddress
        let scannerMACAddress = packet[24..<30]
            .map { String(format: "%02x", $0) }
            .joined(separator: ":")

        return ScanSnapStartupAdvertisement(
            scannerIPAddress: scannerIPAddress,
            scannerMACAddress: scannerMACAddress
        )
    }
}
