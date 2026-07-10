public struct ScanSnapSocketAddress: Sendable, Hashable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public static func anyIPv4(port: UInt16) -> ScanSnapSocketAddress {
        ScanSnapSocketAddress(host: "0.0.0.0", port: port)
    }
}

public struct ScanSnapDatagram: Sendable, Hashable {
    public let bytes: [UInt8]
    public let remoteAddress: ScanSnapSocketAddress

    public init(bytes: [UInt8], remoteAddress: ScanSnapSocketAddress) {
        self.bytes = bytes
        self.remoteAddress = remoteAddress
    }
}

public enum ScanSnapSocketError: Error, Sendable, Equatable {
    case invalidIPv4Address(String)
    case invalidBufferLength(Int)
    case systemCall(operation: String, code: Int32)
    case timedOut(operation: String)
    case connectionClosed(expectedBytes: Int, receivedBytes: Int)
    case writeMadeNoProgress(remainingBytes: Int)
}
