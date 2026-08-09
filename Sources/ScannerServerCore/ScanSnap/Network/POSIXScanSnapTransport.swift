#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct POSIXScanSnapUDPTransportFactory: ScanSnapUDPTransportFactory {
    public init() {}

    public func makeTransport() async throws -> any ScanSnapUDPTransport {
        try POSIXScanSnapUDPTransport()
    }
}

public actor POSIXScanSnapUDPTransport: ScanSnapUDPTransport {
    private var descriptor: Int32

    public init() throws {
        descriptor = try makeSocket(type: scanSnapDatagramSocketType, operation: "socket(UDP)")
    }

    deinit {
        closeDescriptor(descriptor)
    }

    public func bind(to localAddress: ScanSnapSocketAddress, allowsBroadcast: Bool) throws -> UInt16 {
        try setBooleanSocketOption(descriptor, name: SO_REUSEADDR, enabled: true, operation: "setsockopt(SO_REUSEADDR)")
        if allowsBroadcast {
            try setBooleanSocketOption(descriptor, name: SO_BROADCAST, enabled: true, operation: "setsockopt(SO_BROADCAST)")
        }

        let address = try ipv4SocketAddress(localAddress)
        let result = withSocketAddress(address) { pointer, length in
            systemBind(descriptor, pointer, length)
        }
        guard result == 0 else {
            throw currentSocketError(operation: "bind(UDP)")
        }
        return try boundPort(of: descriptor)
    }

    public func send(_ bytes: [UInt8], to remoteAddress: ScanSnapSocketAddress) throws {
        try Task.checkCancellation()
        let address = try ipv4SocketAddress(remoteAddress)
        let sent = bytes.withUnsafeBytes { buffer in
            withSocketAddress(address) { pointer, length in
                systemSendTo(descriptor, buffer.baseAddress, buffer.count, pointer, length)
            }
        }
        guard sent >= 0 else {
            throw currentSocketError(operation: "sendto")
        }
        guard sent == bytes.count else {
            throw ScanSnapSocketError.systemCall(operation: "sendto(short write)", code: 0)
        }
    }

    public func receive(maximumBytes: Int, timeoutMilliseconds: UInt64) throws -> ScanSnapDatagram? {
        guard maximumBytes > 0 else {
            throw ScanSnapSocketError.invalidBufferLength(maximumBytes)
        }
        guard try waitForDescriptor(
            descriptor,
            events: Int16(POLLIN),
            timeoutMilliseconds: timeoutMilliseconds,
            operation: "receive(UDP)"
        ) else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        var remote = sockaddr_in()
        var remoteLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let received = bytes.withUnsafeMutableBytes { buffer in
            withUnsafeMutablePointer(to: &remote) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                    systemReceiveFrom(
                        descriptor,
                        buffer.baseAddress,
                        buffer.count,
                        socketPointer,
                        &remoteLength
                    )
                }
            }
        }
        guard received >= 0 else {
            throw currentSocketError(operation: "recvfrom")
        }
        bytes.removeSubrange(received..<bytes.count)
        return ScanSnapDatagram(bytes: bytes, remoteAddress: try socketAddress(remote))
    }

    public func close() {
        closeDescriptor(descriptor)
        descriptor = -1
    }
}

public struct POSIXScanSnapTCPConnectionFactory: ScanSnapTCPConnectionFactory {
    public init() {}

    public func connect(
        to remoteAddress: ScanSnapSocketAddress,
        binding localAddress: ScanSnapSocketAddress?,
        timeoutMilliseconds: UInt64
    ) async throws -> any ScanSnapTCPConnection {
        let descriptor = try connectSocket(
            to: remoteAddress,
            binding: localAddress,
            timeoutMilliseconds: timeoutMilliseconds
        )
        return POSIXScanSnapTCPConnection(descriptor: descriptor)
    }
}

public actor POSIXScanSnapTCPConnection: ScanSnapTCPConnection {
    private var descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        closeDescriptor(descriptor)
    }

    public func read(maximumBytes: Int, timeoutMilliseconds: UInt64) throws -> [UInt8] {
        guard maximumBytes > 0 else {
            throw ScanSnapSocketError.invalidBufferLength(maximumBytes)
        }
        guard try waitForDescriptor(
            descriptor,
            events: Int16(POLLIN),
            timeoutMilliseconds: timeoutMilliseconds,
            operation: "read(TCP)"
        ) else {
            throw ScanSnapSocketError.timedOut(operation: "read(TCP)")
        }

        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        let received = bytes.withUnsafeMutableBytes { buffer in
            systemReceive(descriptor, buffer.baseAddress, buffer.count)
        }
        guard received >= 0 else {
            throw currentSocketError(operation: "recv")
        }
        bytes.removeSubrange(received..<bytes.count)
        return bytes
    }

    public func write(_ bytes: [UInt8], timeoutMilliseconds: UInt64) throws -> Int {
        guard !bytes.isEmpty else { return 0 }
        guard try waitForDescriptor(
            descriptor,
            events: Int16(POLLOUT),
            timeoutMilliseconds: timeoutMilliseconds,
            operation: "write(TCP)"
        ) else {
            throw ScanSnapSocketError.timedOut(operation: "write(TCP)")
        }

        let written = bytes.withUnsafeBytes { buffer in
            systemSend(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written >= 0 else {
            throw currentSocketError(operation: "send")
        }
        return written
    }

    public func shutdownWriting() throws {
        guard descriptor >= 0 else {
            throw ScanSnapSocketError.systemCall(operation: "shutdown(SHUT_WR)", code: EBADF)
        }
        guard systemShutdownWriting(descriptor) == 0 else {
            throw currentSocketError(operation: "shutdown(SHUT_WR)")
        }
    }

    public func close() {
        closeDescriptor(descriptor)
        descriptor = -1
    }
}

private let scanSnapPollSliceMilliseconds: UInt64 = 50

#if os(Linux)
private let scanSnapDatagramSocketType = Int32(SOCK_DGRAM.rawValue)
private let scanSnapStreamSocketType = Int32(SOCK_STREAM.rawValue)
#else
private let scanSnapDatagramSocketType = SOCK_DGRAM
private let scanSnapStreamSocketType = SOCK_STREAM
#endif

private func makeSocket(type: Int32, operation: String) throws -> Int32 {
    let descriptor = socket(AF_INET, type, 0)
    guard descriptor >= 0 else {
        throw currentSocketError(operation: operation)
    }

    let flags = fcntl(descriptor, F_GETFL, 0)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        let error = currentSocketError(operation: "fcntl(O_NONBLOCK)")
        closeDescriptor(descriptor)
        throw error
    }

#if !os(Linux)
    if type == scanSnapStreamSocketType {
        do {
            try setBooleanSocketOption(descriptor, name: SO_NOSIGPIPE, enabled: true, operation: "setsockopt(SO_NOSIGPIPE)")
        } catch {
            closeDescriptor(descriptor)
            throw error
        }
    }
#endif
    return descriptor
}

private func connectSocket(
    to remoteAddress: ScanSnapSocketAddress,
    binding localAddress: ScanSnapSocketAddress?,
    timeoutMilliseconds: UInt64
) throws -> Int32 {
    let descriptor = try makeSocket(type: scanSnapStreamSocketType, operation: "socket(TCP)")
    do {
        if let localAddress {
            let address = try ipv4SocketAddress(localAddress)
            let result = withSocketAddress(address) { pointer, length in
                systemBind(descriptor, pointer, length)
            }
            guard result == 0 else {
                throw currentSocketError(operation: "bind(TCP)")
            }
        }

        let address = try ipv4SocketAddress(remoteAddress)
        let result = withSocketAddress(address) { pointer, length in
            systemConnect(descriptor, pointer, length)
        }
        if result != 0 {
            guard errno == EINPROGRESS else {
                throw currentSocketError(operation: "connect")
            }
            guard try waitForDescriptor(
                descriptor,
                events: Int16(POLLOUT),
                timeoutMilliseconds: timeoutMilliseconds,
                operation: "connect"
            ) else {
                throw ScanSnapSocketError.timedOut(operation: "connect")
            }

            var connectionError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &connectionError, &length) == 0 else {
                throw currentSocketError(operation: "getsockopt(SO_ERROR)")
            }
            guard connectionError == 0 else {
                throw ScanSnapSocketError.systemCall(operation: "connect", code: connectionError)
            }
        }
        return descriptor
    } catch {
        closeDescriptor(descriptor)
        throw error
    }
}

private func waitForDescriptor(
    _ descriptor: Int32,
    events: Int16,
    timeoutMilliseconds: UInt64,
    operation: String
) throws -> Bool {
    var remaining = timeoutMilliseconds
    repeat {
        try Task.checkCancellation()
        let slice = min(remaining, scanSnapPollSliceMilliseconds)
        var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
        let result = poll(&pollDescriptor, 1, Int32(slice))
        if result > 0 {
            if pollDescriptor.revents & Int16(POLLNVAL) != 0 {
                throw ScanSnapSocketError.systemCall(operation: operation, code: EBADF)
            }
            return true
        }
        if result < 0, errno != EINTR {
            throw currentSocketError(operation: "poll(\(operation))")
        }
        if result == 0 {
            if slice >= remaining { return false }
            remaining -= slice
        }
    } while true
}

private func ipv4SocketAddress(_ address: ScanSnapSocketAddress) throws -> sockaddr_in {
    var socketAddress = sockaddr_in()
    socketAddress.sin_family = sa_family_t(AF_INET)
    socketAddress.sin_port = address.port.bigEndian
    let result = address.host.withCString { text in
        inet_pton(AF_INET, text, &socketAddress.sin_addr)
    }
    guard result == 1 else {
        throw ScanSnapSocketError.invalidIPv4Address(address.host)
    }
    return socketAddress
}

private func socketAddress(_ address: sockaddr_in) throws -> ScanSnapSocketAddress {
    var address = address
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    let result = buffer.withUnsafeMutableBufferPointer { bufferPointer in
        inet_ntop(AF_INET, &address.sin_addr, bufferPointer.baseAddress, socklen_t(bufferPointer.count))
    }
    guard result != nil else {
        throw currentSocketError(operation: "inet_ntop")
    }
    let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
    let host = String(decoding: buffer[..<terminator].map(UInt8.init(bitPattern:)), as: UTF8.self)
    return ScanSnapSocketAddress(host: host, port: UInt16(bigEndian: address.sin_port))
}

private func boundPort(of descriptor: Int32) throws -> UInt16 {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
            getsockname(descriptor, socketPointer, &length)
        }
    }
    guard result == 0 else {
        throw currentSocketError(operation: "getsockname")
    }
    return UInt16(bigEndian: address.sin_port)
}

private func setBooleanSocketOption(
    _ descriptor: Int32,
    name: Int32,
    enabled: Bool,
    operation: String
) throws {
    var value: Int32 = enabled ? 1 : 0
    let result = withUnsafePointer(to: &value) { pointer in
        setsockopt(descriptor, SOL_SOCKET, name, pointer, socklen_t(MemoryLayout<Int32>.size))
    }
    guard result == 0 else {
        throw currentSocketError(operation: operation)
    }
}

private func withSocketAddress<Result>(
    _ address: sockaddr_in,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
) rethrows -> Result {
    var address = address
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
            try body(socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

private func currentSocketError(operation: String) -> ScanSnapSocketError {
    ScanSnapSocketError.systemCall(operation: operation, code: errno)
}

private func closeDescriptor(_ descriptor: Int32) {
    guard descriptor >= 0 else { return }
#if os(Linux)
    _ = Glibc.close(descriptor)
#else
    _ = Darwin.close(descriptor)
#endif
}

private func systemBind(
    _ descriptor: Int32,
    _ address: UnsafePointer<sockaddr>,
    _ length: socklen_t
) -> Int32 {
#if os(Linux)
    Glibc.bind(descriptor, address, length)
#else
    Darwin.bind(descriptor, address, length)
#endif
}

private func systemConnect(
    _ descriptor: Int32,
    _ address: UnsafePointer<sockaddr>,
    _ length: socklen_t
) -> Int32 {
#if os(Linux)
    Glibc.connect(descriptor, address, length)
#else
    Darwin.connect(descriptor, address, length)
#endif
}

private func systemSendTo(
    _ descriptor: Int32,
    _ buffer: UnsafeRawPointer?,
    _ count: Int,
    _ address: UnsafePointer<sockaddr>,
    _ length: socklen_t
) -> Int {
#if os(Linux)
    Glibc.sendto(descriptor, buffer, count, Int32(MSG_NOSIGNAL), address, length)
#else
    Darwin.sendto(descriptor, buffer, count, 0, address, length)
#endif
}

private func systemReceiveFrom(
    _ descriptor: Int32,
    _ buffer: UnsafeMutableRawPointer?,
    _ count: Int,
    _ address: UnsafeMutablePointer<sockaddr>,
    _ length: UnsafeMutablePointer<socklen_t>
) -> Int {
#if os(Linux)
    Glibc.recvfrom(descriptor, buffer, count, 0, address, length)
#else
    Darwin.recvfrom(descriptor, buffer, count, 0, address, length)
#endif
}

private func systemReceive(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
#if os(Linux)
    Glibc.recv(descriptor, buffer, count, 0)
#else
    Darwin.recv(descriptor, buffer, count, 0)
#endif
}

private func systemSend(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
#if os(Linux)
    Glibc.send(descriptor, buffer, count, Int32(MSG_NOSIGNAL))
#else
    Darwin.send(descriptor, buffer, count, 0)
#endif
}

private func systemShutdownWriting(_ descriptor: Int32) -> Int32 {
#if os(Linux)
    Glibc.shutdown(descriptor, Int32(SHUT_WR))
#else
    Darwin.shutdown(descriptor, SHUT_WR)
#endif
}
