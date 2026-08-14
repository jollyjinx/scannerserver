import ScannerServerCore

enum FakeProcessError: Error, Sendable {
    case expectedFailure
    case missingStub
}

actor FakeProcessExecutor: ProcessExecutor {
    enum Stub: Sendable {
        case result(ProcessResult)
        case failure(FakeProcessError)
        case suspended(ProcessResult)
        case suspendedIgnoringCancellation(ProcessResult)
    }

    private struct RequestWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var stubs: [Stub]
    private var recordedRequests: [ProcessRequest] = []
    private var suspendedExecutions: [CheckedContinuation<Void, any Error>] = []
    private var requestWaiters: [RequestWaiter] = []
    private var ignoredCancellationCount = 0
    private var ignoredCancellationWaiters: [RequestWaiter] = []

    init(stubs: [Stub]) {
        self.stubs = stubs
    }

    func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        recordedRequests.append(request)
        resumeSatisfiedRequestWaiters()

        guard !stubs.isEmpty else { throw FakeProcessError.missingStub }
        let stub = stubs.removeFirst()
        switch stub {
        case .result(let result):
            return result
        case .failure(let error):
            throw error
        case .suspended(let result):
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    suspendedExecutions.append(continuation)
                }
            } onCancel: {
                Task { await self.cancelNextSuspendedExecution() }
            }
            try Task.checkCancellation()
            return result
        case .suspendedIgnoringCancellation(let result):
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    suspendedExecutions.append(continuation)
                }
            } onCancel: {
                Task { await self.recordIgnoredCancellation() }
            }
            return result
        }
    }

    func requests() -> [ProcessRequest] {
        recordedRequests
    }

    func waitForRequestCount(_ count: Int) async {
        guard recordedRequests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(RequestWaiter(count: count, continuation: continuation))
        }
    }

    func resumeNextSuspendedExecution() {
        guard !suspendedExecutions.isEmpty else { return }
        suspendedExecutions.removeFirst().resume(returning: ())
    }

    func waitForIgnoredCancellationCount(_ count: Int) async {
        guard ignoredCancellationCount < count else { return }
        await withCheckedContinuation { continuation in
            ignoredCancellationWaiters.append(RequestWaiter(
                count: count,
                continuation: continuation
            ))
        }
    }

    private func resumeSatisfiedRequestWaiters() {
        let satisfied = requestWaiters.filter { recordedRequests.count >= $0.count }
        requestWaiters.removeAll { recordedRequests.count >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }

    private func cancelNextSuspendedExecution() {
        guard !suspendedExecutions.isEmpty else { return }
        suspendedExecutions.removeFirst().resume(throwing: CancellationError())
    }

    private func recordIgnoredCancellation() {
        ignoredCancellationCount += 1
        let satisfied = ignoredCancellationWaiters.filter {
            ignoredCancellationCount >= $0.count
        }
        ignoredCancellationWaiters.removeAll {
            ignoredCancellationCount >= $0.count
        }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
