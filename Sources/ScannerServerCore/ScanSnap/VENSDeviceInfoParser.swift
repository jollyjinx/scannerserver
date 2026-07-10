import Foundation

public enum VENSDeviceInfoParser {
    public static let packetLength = 132
    public static let signature: [UInt8] = Array("VENS".utf8)

    public static func parse(
        _ packet: [UInt8],
        remoteIPAddress: String? = nil
    ) throws -> ScanSnapDevice {
        guard packet.count >= packetLength else {
            throw ScanSnapProtocolError.packetTooShort(minimum: packetLength, actual: packet.count)
        }

        let actualSignature = Array(packet[0..<4])
        guard actualSignature == signature else {
            throw ScanSnapProtocolError.invalidSignature(expected: signature, actual: actualSignature)
        }

        let advertisedIPAddress = try ScanSnapByteCodec.ipv4Address(packet[16..<20])
        let remoteFallback = remoteIPAddress.flatMap { $0.isEmpty ? nil : $0 }
        let ipAddress = advertisedIPAddress == "0.0.0.0" ? (remoteFallback ?? advertisedIPAddress) : advertisedIPAddress
        let macAddress = packet[28..<34]
            .map { String(format: "%02x", $0) }
            .joined(separator: ":")
        let clientIPAddress = try ScanSnapByteCodec.ipv4Address(packet[120..<124])

        return ScanSnapDevice(
            ipAddress: ipAddress,
            macAddress: macAddress,
            serialNumber: asciiText(packet[40..<104]),
            name: asciiText(packet[104..<120]).nonEmpty ?? "ScanSnap",
            dataPort: try ScanSnapByteCodec.readUInt16(from: packet, at: 22),
            controlPort: try ScanSnapByteCodec.readUInt16(from: packet, at: 26),
            state: try ScanSnapByteCodec.readUInt32(from: packet, at: 36),
            clientIPAddress: clientIPAddress == "0.0.0.0" ? nil : clientIPAddress,
            metadata: Array(packet[124..<132])
        )
    }

    private static func asciiText(_ bytes: ArraySlice<UInt8>) -> String {
        let beforeTerminator = bytes.prefix { $0 != 0 }
        let ascii = beforeTerminator.filter { $0 < 0x80 }
        return String(decoding: ascii, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
