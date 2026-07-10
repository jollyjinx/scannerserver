import Foundation
import ScannerServerCore
import Testing

@Suite("System ScanSnap setup network provider")
struct SystemScanSnapSetupNetworkProviderTests {
    @Test("Network commands use the shared executor with a bounded timeout")
    func sharedExecutorAndTimeout() async throws {
        let executor = RecordingSetupProcessExecutor(results: [
            ProcessResult(
                exitStatus: 0,
                standardOutput: """
                [{"ifname":"vlan5","addr_info":[{"family":"inet","local":"10.112.10.6","prefixlen":24}]}]
                """,
                standardError: "diagnostic output is captured"
            ),
        ])
        let provider = SystemScanSnapSetupNetworkProvider(
            executor: executor,
            commandTimeoutMilliseconds: 321,
            commandEnvironment: ["PATH": "/test/bin"]
        )

        let interfaces = try await provider.ipv4Interfaces()

        #expect(interfaces == [try ScanSnapSetupIPv4Interface(
            name: "vlan5",
            ipAddress: "10.112.10.6",
            prefixLength: 24
        )])
        let request = try #require(await executor.requests.first)
        #expect(request.executable == "ip")
        #expect(request.arguments == ["-j", "-4", "addr", "show", "scope", "global"])
        #expect(request.environment == ["PATH": "/test/bin"])
        #expect(request.timeoutMilliseconds == 321)
    }

    @Test("Cancellation is not swallowed by command fallback")
    func cancellationIsPropagated() async throws {
        let executor = RecordingSetupProcessExecutor(results: [], suspend: true)
        let provider = SystemScanSnapSetupNetworkProvider(executor: executor)
        let task = Task { try await provider.ipv4Interfaces() }
        await executor.waitForRequest()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected setup lookup cancellation")
        } catch is CancellationError {
            // Expected.
        }

        #expect(await executor.requests.count == 1)
        #expect(await executor.observedCancellation)
    }
}

private actor RecordingSetupProcessExecutor: ProcessExecutor {
    private var results: [ProcessResult]
    private let suspend: Bool
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [ProcessRequest] = []
    private(set) var observedCancellation = false

    init(results: [ProcessResult], suspend: Bool = false) {
        self.results = results
        self.suspend = suspend
    }

    func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        requests.append(request)
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
        if suspend {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                observedCancellation = true
                throw CancellationError()
            }
        }
        guard !results.isEmpty else { throw RecordingSetupProcessError.missingResult }
        return results.removeFirst()
    }

    func waitForRequest() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }
}

private enum RecordingSetupProcessError: Error {
    case missingResult
}
