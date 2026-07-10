public protocol ScanSnapUDPTransport: Sendable {
    func bind(to localAddress: ScanSnapSocketAddress, allowsBroadcast: Bool) async throws -> UInt16
    func send(_ bytes: [UInt8], to remoteAddress: ScanSnapSocketAddress) async throws
    func receive(maximumBytes: Int, timeoutMilliseconds: UInt64) async throws -> ScanSnapDatagram?
    func close() async
}

public protocol ScanSnapUDPTransportFactory: Sendable {
    func makeTransport() async throws -> any ScanSnapUDPTransport
}

public protocol ScanSnapTCPConnection: Sendable {
    func read(maximumBytes: Int, timeoutMilliseconds: UInt64) async throws -> [UInt8]
    func write(_ bytes: [UInt8], timeoutMilliseconds: UInt64) async throws -> Int
    func close() async
}

public extension ScanSnapTCPConnection {
    func readExactly(_ byteCount: Int, timeoutMilliseconds: UInt64) async throws -> [UInt8] {
        guard byteCount >= 0 else {
            throw ScanSnapSocketError.invalidBufferLength(byteCount)
        }

        var result: [UInt8] = []
        result.reserveCapacity(byteCount)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int64(clamping: timeoutMilliseconds)))
        while result.count < byteCount {
            try Task.checkCancellation()
            let remaining = scanSnapRemainingMilliseconds(until: deadline, clock: clock)
            guard remaining > 0 else {
                throw ScanSnapSocketError.timedOut(operation: "readExactly")
            }
            let chunk = try await read(
                maximumBytes: byteCount - result.count,
                timeoutMilliseconds: remaining
            )
            guard !chunk.isEmpty else {
                throw ScanSnapSocketError.connectionClosed(
                    expectedBytes: byteCount,
                    receivedBytes: result.count
                )
            }
            result.append(contentsOf: chunk)
        }
        return result
    }

    func writeAll(_ bytes: [UInt8], timeoutMilliseconds: UInt64) async throws {
        var offset = 0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int64(clamping: timeoutMilliseconds)))
        while offset < bytes.count {
            try Task.checkCancellation()
            let remaining = scanSnapRemainingMilliseconds(until: deadline, clock: clock)
            guard remaining > 0 else {
                throw ScanSnapSocketError.timedOut(operation: "writeAll")
            }
            let written = try await write(
                Array(bytes[offset...]),
                timeoutMilliseconds: remaining
            )
            guard written > 0 else {
                throw ScanSnapSocketError.writeMadeNoProgress(remainingBytes: bytes.count - offset)
            }
            guard written <= bytes.count - offset else {
                throw ScanSnapSocketError.systemCall(operation: "write", code: 0)
            }
            offset += written
        }
    }
}

func scanSnapRemainingMilliseconds(
    until deadline: ContinuousClock.Instant,
    clock: ContinuousClock
) -> UInt64 {
    let components = clock.now.duration(to: deadline).components
    guard components.seconds >= 0 else { return 0 }
    let seconds = UInt64(components.seconds)
    let attoseconds = UInt64(max(components.attoseconds, 0))
    let fractionalMilliseconds = (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
    let (wholeMilliseconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
    guard !overflow else { return .max }
    let (milliseconds, additionOverflow) = wholeMilliseconds.addingReportingOverflow(fractionalMilliseconds)
    return additionOverflow ? .max : milliseconds
}

public protocol ScanSnapTCPConnectionFactory: Sendable {
    func connect(
        to remoteAddress: ScanSnapSocketAddress,
        binding localAddress: ScanSnapSocketAddress?,
        timeoutMilliseconds: UInt64
    ) async throws -> any ScanSnapTCPConnection
}

public protocol ScanSnapSleeper: Sendable {
    func sleep(milliseconds: UInt64) async throws
}

public struct TaskScanSnapSleeper: ScanSnapSleeper {
    public init() {}

    public func sleep(milliseconds: UInt64) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}
