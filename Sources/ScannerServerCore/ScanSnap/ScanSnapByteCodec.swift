public enum ScanSnapByteCodec {
    public static func bigEndianBytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    public static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
    }

    public static func bigEndianBytes(_ value: Int32) -> [UInt8] {
        bigEndianBytes(UInt32(bitPattern: value))
    }

    public static func readUInt16(from bytes: [UInt8], at offset: Int) throws -> UInt16 {
        guard offset >= 0, bytes.count >= offset + 2 else {
            throw ScanSnapProtocolError.packetTooShort(minimum: max(offset + 2, 0), actual: bytes.count)
        }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    public static func readUInt32(from bytes: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset >= 0, bytes.count >= offset + 4 else {
            throw ScanSnapProtocolError.packetTooShort(minimum: max(offset + 4, 0), actual: bytes.count)
        }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    public static func ipv4Bytes(_ address: String) throws -> [UInt8] {
        let components = address.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else {
            throw ScanSnapProtocolError.invalidIPv4Address(address)
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for component in components {
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber),
                  let byte = UInt8(component)
            else {
                throw ScanSnapProtocolError.invalidIPv4Address(address)
            }
            bytes.append(byte)
        }
        return bytes
    }

    public static func ipv4Address(_ bytes: ArraySlice<UInt8>) throws -> String {
        guard bytes.count == 4 else {
            throw ScanSnapProtocolError.invalidByteCount(
                field: "IPv4 address",
                expected: 4,
                actual: bytes.count
            )
        }
        return bytes.map(String.init).joined(separator: ".")
    }
}
