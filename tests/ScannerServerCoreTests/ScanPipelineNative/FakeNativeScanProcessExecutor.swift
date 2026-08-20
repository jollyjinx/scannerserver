import Foundation
import ScannerServerCore

enum FakeNativeScanProcessError: Error, Sendable {
    case missingStub
}

actor FakeNativeScanProcessExecutor: ProcessExecutor {
    enum Stub: Sendable {
        case result(ProcessResult)
        case executableResult(executable: String, result: ProcessResult)
        case materialize(files: [String: Data], result: ProcessResult)
        case suspended
    }

    private struct RequestWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var stubs: [Stub]
    private var recordedRequests: [ProcessRequest] = []
    private var suspendedExecutions: [CheckedContinuation<Void, any Error>] = []
    private var requestWaiters: [RequestWaiter] = []

    init(stubs: [Stub]) {
        self.stubs = stubs
    }

    func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        recordedRequests.append(request)
        resumeSatisfiedRequestWaiters()
        guard !stubs.isEmpty else { throw FakeNativeScanProcessError.missingStub }

        if let index = stubs.firstIndex(where: { stub in
            if case .executableResult(executable: let executable, result: _) = stub {
                return executable == request.executable
            }
            return false
        }) {
            let stub = stubs.remove(at: index)
            if case .executableResult(executable: _, result: let result) = stub {
                return result
            }
        }

        switch stubs.removeFirst() {
        case .result(let result):
            return result
        case .executableResult(executable: _, result: let result):
            return result
        case .materialize(let files, let result):
            for (path, contents) in files {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try contents.write(to: url)
            }
            return result
        case .suspended:
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    suspendedExecutions.append(continuation)
                }
            } onCancel: {
                Task { await self.cancelNextSuspendedExecution() }
            }
            try Task.checkCancellation()
            return ProcessResult(exitStatus: 0)
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
}

extension FakeNativeScanProcessExecutor: OCRExecuting {
    func execute(_ request: OCRExecutionRequest) async throws -> OCRExecutionResult {
        try await LocalOCRProcessAdapter(
            processExecutor: self,
            documentExecutor: self
        ).execute(request)
    }
}
