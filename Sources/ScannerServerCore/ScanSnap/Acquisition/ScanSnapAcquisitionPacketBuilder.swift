enum ScanSnapAcquisitionPacketBuilder {
    static let maximumSidesPerBatch = 256
    static let maximumImageBytes = 16 * 1_024 * 1_024

    static let feederEmptyStatus: [UInt8] = [
        0x00, 0x0A, 0x00, 0x00, 0x00, 0x00,
        0x80, 0x03, 0x00, 0x00, 0x00, 0x00,
    ]

    static let setupCommands: [[UInt8]] = [
        decode("0000000a000000200000000000000000c2000000000000002000000000000000"),
        decode("00000006000000080000000800000000d50000000808000000000000000000000000000000000000"),
        decode("00000006000000000000000000000000d8000000000000000000000000000000"),
        decode("0000000a000000000000002000000000e9000000000000200000000000000000012c012c000028d0000044dc0500000000000000000000000000000000000000"),
        decode("00000006000000000000005000000000d400000050000000000000000000000000030101d000c1808080908080000000000000000000000000000000000000300010012c012c05810000000028d0000044dc040000000000000000000000000000000000000000000000000000000000"),
        decode("0000000a000000200000000000000000c2000000000000002000000000000000"),
        statusCommand,
        endCommand,
    ]

    static let statusCommand = decode(
        "0000000600000012000000000000000003000000120000000000000000000000"
    )
    static let stateCommand = decode(
        "0000000a000000200000000000000000c2000000000000002000000000000000"
    )
    static let endCommand = decode(
        "00000006000000000000000000000000e0000000000000000000000000000000"
    )

    static func scanStart(side: UInt8) -> [UInt8] {
        var command = decode(
            "0000000c00300000000000000000000028000002000030000000000000000000"
        )
        if side.isMultiple(of: 2) == false {
            command[21] = 0x80
        }
        command[26] = side
        return command
    }

    static func doneQuery(side: UInt8) -> [UInt8] {
        var command = decode(
            "0000000c00000020000000000000000028008000008000002000000000000000"
        )
        command[26] = side
        return command
    }

    static func scannerStatus(in response: [UInt8]) throws -> Int32? {
        guard response.count >= 12 else { return nil }
        guard Array(response[4..<8]) == Array("VENS".utf8) else { return nil }
        let value = try ScanSnapByteCodec.readUInt32(from: response, at: 8)
        let status = Int32(bitPattern: value)
        return status == 0 ? nil : status
    }

    static func reportsFeederEmpty(_ response: [UInt8]) -> Bool {
        response.count >= feederEmptyStatus.count
            && Array(response.suffix(feederEmptyStatus.count)) == feederEmptyStatus
    }

    private static func decode(_ text: String) -> [UInt8] {
        precondition(text.count.isMultiple(of: 2))
        var result: [UInt8] = []
        result.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            result.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return result
    }
}
