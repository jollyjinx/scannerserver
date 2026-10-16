import ScannerServerCore
import Testing

/// A strict, shared script checks ordering across UDP, both TCP ports, and delays.
/// Expected bytes come from fixed fixtures, never the production packet builders.
enum ScanSnapProtocolStep: Equatable, Sendable {
    case connect(String, port: UInt16, timeout: UInt64)
    case read(String, [UInt8])
    case write(String, [UInt8])
    case cancelRead(String)
    case shutdown(String)
    case close(String)
    case openUDP(String)
    case bindUDP(String)
    case sendUDP(String, [UInt8])
    case receiveUDP(String, timeout: UInt64)
    case closeUDP(String)
    case sleep(UInt64)
}

actor ScanSnapProtocolScript {
    private var steps: [ScanSnapProtocolStep]
    private let maximumReadSize: Int
    private let maximumWriteSize: Int

    init(_ steps: [ScanSnapProtocolStep], fragmentSize: Int = .max) {
        self.steps = steps
        maximumReadSize = fragmentSize
        maximumWriteSize = fragmentSize
    }

    func assertFinished() {
        #expect(steps.isEmpty, "Unconsumed protocol steps: \(steps)")
    }

    func consume(_ actual: ScanSnapProtocolStep) throws {
        let expected = try #require(steps.first, "Unexpected protocol operation: \(actual)")
        try #require(expected == actual, "Protocol operation differs from the frozen transcript")
        steps.removeFirst()
    }

    func connect(port: UInt16, timeout: UInt64) throws -> String {
        guard case let .connect(channel, _, _) = steps.first else {
            throw mismatch("TCP connect to \(port)")
        }
        try consume(.connect(channel, port: port, timeout: timeout))
        return channel
    }

    func openUDP() throws -> String {
        guard case let .openUDP(channel) = steps.first else {
            throw mismatch("UDP open")
        }
        steps.removeFirst()
        return channel
    }

    func read(_ channel: String, maximumBytes: Int) throws -> [UInt8] {
        if steps.first == .cancelRead(channel) {
            steps.removeFirst()
            throw CancellationError()
        }
        guard case let .read(expectedChannel, bytes) = steps.first else {
            throw mismatch("\(channel) read")
        }
        try #require(expectedChannel == channel)
        steps.removeFirst()
        let count = min(bytes.count, maximumBytes, maximumReadSize)
        if count < bytes.count {
            steps.insert(.read(channel, Array(bytes.dropFirst(count))), at: 0)
        }
        return Array(bytes.prefix(count))
    }

    func write(_ channel: String, bytes: [UInt8]) throws -> Int {
        guard case let .write(expectedChannel, expectedBytes) = steps.first else {
            throw mismatch("\(channel) write")
        }
        try #require(expectedChannel == channel)
        let count = min(bytes.count, maximumWriteSize)
        try #require(Array(bytes.prefix(count)) == Array(expectedBytes.prefix(count)))
        steps.removeFirst()
        if count < expectedBytes.count {
            steps.insert(.write(channel, Array(expectedBytes.dropFirst(count))), at: 0)
        }
        return count
    }

    private func mismatch(_ actual: String) -> ScriptError {
        Issue.record("Unexpected \(actual); next transcript step: \(String(describing: steps.first))")
        return ScriptError.unexpectedOperation
    }

    private enum ScriptError: Error {
        case unexpectedOperation
    }
}

struct ScriptedScanSnapNetwork: ScanSnapTCPConnectionFactory, ScanSnapUDPTransportFactory, ScanSnapSleeper {
    let script: ScanSnapProtocolScript

    func connect(
        to remoteAddress: ScanSnapSocketAddress,
        binding localAddress: ScanSnapSocketAddress?,
        timeoutMilliseconds: UInt64
    ) async throws -> any ScanSnapTCPConnection {
        try #require(remoteAddress.host == "192.0.2.20")
        try #require(localAddress == ScanSnapSocketAddress(host: "192.0.2.30", port: 0))
        let channel = try await script.connect(port: remoteAddress.port, timeout: timeoutMilliseconds)
        return ScriptedScanSnapTCP(script: script, channel: channel)
    }

    func makeTransport() async throws -> any ScanSnapUDPTransport {
        let channel = try await script.openUDP()
        return ScriptedScanSnapUDP(script: script, channel: channel)
    }

    func sleep(milliseconds: UInt64) async throws {
        try await script.consume(.sleep(milliseconds))
    }
}

private struct ScriptedScanSnapTCP: ScanSnapTCPConnection {
    let script: ScanSnapProtocolScript
    let channel: String

    func read(maximumBytes: Int, timeoutMilliseconds: UInt64) async throws -> [UInt8] {
        try await script.read(channel, maximumBytes: maximumBytes)
    }

    func write(_ bytes: [UInt8], timeoutMilliseconds: UInt64) async throws -> Int {
        try await script.write(channel, bytes: bytes)
    }

    func shutdownWriting() async throws {
        try await script.consume(.shutdown(channel))
    }

    func close() async {
        try? await script.consume(.close(channel))
    }
}

private struct ScriptedScanSnapUDP: ScanSnapUDPTransport {
    let script: ScanSnapProtocolScript
    let channel: String

    func bind(to localAddress: ScanSnapSocketAddress, allowsBroadcast: Bool) async throws -> UInt16 {
        try #require(localAddress == ScanSnapSocketAddress(host: "192.0.2.30", port: 55_264))
        try #require(!allowsBroadcast)
        try await script.consume(.bindUDP(channel))
        return 55_264
    }

    func send(_ bytes: [UInt8], to remoteAddress: ScanSnapSocketAddress) async throws {
        try #require(remoteAddress == ScanSnapSocketAddress(host: "192.0.2.20", port: 52_217))
        try await script.consume(.sendUDP(channel, bytes))
    }

    func receive(maximumBytes: Int, timeoutMilliseconds: UInt64) async throws -> ScanSnapDatagram? {
        try #require(maximumBytes == 256)
        try await script.consume(.receiveUDP(channel, timeout: timeoutMilliseconds))
        return nil
    }

    func close() async {
        try? await script.consume(.closeUDP(channel))
    }
}
