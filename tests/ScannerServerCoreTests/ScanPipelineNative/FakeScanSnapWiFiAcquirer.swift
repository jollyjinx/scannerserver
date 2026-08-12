import Foundation
import ScannerServerCore

actor FakeScanSnapWiFiAcquirer: ScanSnapWiFiAcquiring {
    enum Stub: Sendable {
        case materialize(Data, ScanSnapWiFiAcquisitionResult)
        case result(ScanSnapWiFiAcquisitionResult)
        case failure(ScanSnapAcquisitionError)
        case suspended
    }

    private var stubs: [Stub]
    private var recordedRequests: [ScanSnapWiFiAcquisitionRequest] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendedExecutions: [CheckedContinuation<Void, any Error>] = []

    init(stubs: [Stub] = [
        .materialize(Data("raw".utf8), ScanSnapWiFiAcquisitionResult(pageCount: 1)),
    ]) {
        self.stubs = stubs
    }

    func acquire(
        _ request: ScanSnapWiFiAcquisitionRequest
    ) async throws -> ScanSnapWiFiAcquisitionResult {
        recordedRequests.append(request)
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !stubs.isEmpty else { throw FakeNativeScanProcessError.missingStub }

        switch stubs.removeFirst() {
        case let .materialize(data, result):
            try FileManager.default.createDirectory(
                at: request.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: request.outputURL)
            return result
        case let .result(result):
            return result
        case let .failure(error):
            throw error
        case .suspended:
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    suspendedExecutions.append(continuation)
                }
            } onCancel: {
                Task { await self.cancelNextSuspendedExecution() }
            }
            try Task.checkCancellation()
            return ScanSnapWiFiAcquisitionResult(pageCount: 0)
        }
    }

    func requests() -> [ScanSnapWiFiAcquisitionRequest] {
        recordedRequests
    }

    func waitForRequest() async {
        guard recordedRequests.isEmpty else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    private func cancelNextSuspendedExecution() {
        guard !suspendedExecutions.isEmpty else { return }
        suspendedExecutions.removeFirst().resume(throwing: CancellationError())
    }
}
