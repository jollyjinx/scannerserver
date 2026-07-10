import ScannerServerCore

func hexBytes(_ text: String) -> [UInt8] {
    let compact = text.filter { !$0.isWhitespace }
    precondition(compact.count.isMultiple(of: 2))
    return stride(from: 0, to: compact.count, by: 2).map { offset in
        let start = compact.index(compact.startIndex, offsetBy: offset)
        let end = compact.index(start, offsetBy: 2)
        return UInt8(compact[start..<end], radix: 16)!
    }
}

let fixtureClientMAC = hexBytes("021122334455")
