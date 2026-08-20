import Foundation
import ScannerServerCore

enum FakeProcessError: Error, Sendable {
    case expectedFailure
    case missingStub
}

struct ProcessBackedOCRExecutor: OCRExecuting, Sendable {
    let processExecutor: any ProcessExecutor

    init(_ processExecutor: any ProcessExecutor) {
        self.processExecutor = processExecutor
    }

    func execute(_ request: OCRExecutionRequest) async throws -> OCRExecutionResult {
        try await LocalOCRProcessAdapter(
            processExecutor: processExecutor,
            documentExecutor: processExecutor
        ).execute(request)
    }
}

actor FakeProcessExecutor: ProcessExecutor {
    enum Stub: Sendable {
        case result(ProcessResult)
        case materializeLastArgument(Data, ProcessResult)
        case suspendedMaterializeLastArgument(Data, ProcessResult)
        case failure(FakeProcessError)
        case suspended(ProcessResult)
        case suspendedIgnoringCancellation(ProcessResult)
        case suspendedIgnoringCancellationMaterializeLastArgument(Data, ProcessResult)
    }

    private struct RequestWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var stubs: [Stub]
    private var recordedRequests: [ProcessRequest] = []
    private var recordedOCRRequests: [OCRExecutionRequest] = []
    private let ocrLocation: OCRExecutionLocation
    private var suspendedExecutions: [CheckedContinuation<Void, any Error>] = []
    private var requestWaiters: [RequestWaiter] = []
    private var ignoredCancellationCount = 0
    private var ignoredCancellationWaiters: [RequestWaiter] = []

    init(stubs: [Stub], ocrLocation: OCRExecutionLocation = .local) {
        self.stubs = stubs
        self.ocrLocation = ocrLocation
    }

    func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        recordedRequests.append(request)
        resumeSatisfiedRequestWaiters()

        guard !stubs.isEmpty else { throw FakeProcessError.missingStub }
        let stub = stubs.removeFirst()
        switch stub {
        case .result(let result):
            return result
        case let .materializeLastArgument(data, result):
            guard let path = request.arguments.last else { throw FakeProcessError.expectedFailure }
            try data.write(to: URL(fileURLWithPath: path))
            return result
        case let .suspendedMaterializeLastArgument(data, result):
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    suspendedExecutions.append(continuation)
                }
            } onCancel: {
                Task { await self.cancelNextSuspendedExecution() }
            }
            try Task.checkCancellation()
            guard let path = request.arguments.last else { throw FakeProcessError.expectedFailure }
            try data.write(to: URL(fileURLWithPath: path))
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
        case let .suspendedIgnoringCancellationMaterializeLastArgument(data, result):
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    suspendedExecutions.append(continuation)
                }
            } onCancel: {
                Task { await self.recordIgnoredCancellation() }
            }
            guard let path = request.arguments.last else { throw FakeProcessError.expectedFailure }
            try data.write(to: URL(fileURLWithPath: path))
            return result
        }
    }

    func requests() -> [ProcessRequest] {
        recordedRequests
    }

    func ocrRequests() -> [OCRExecutionRequest] {
        recordedOCRRequests
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

extension FakeProcessExecutor: OCRExecuting {
    func execute(_ request: OCRExecutionRequest) async throws -> OCRExecutionResult {
        recordedOCRRequests.append(request)
        if ocrLocation == .local {
            return try await LocalOCRProcessAdapter(
                processExecutor: self,
                documentExecutor: self
            ).execute(request)
        }

        let result = try await execute(LocalOCRProcessAdapter(
            processExecutor: self,
            documentExecutor: self
        ).processRequest(for: request))
        return OCRExecutionResult(
            outcome: result.succeeded ? .succeeded : .failed(exitStatus: result.exitStatus),
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            location: ocrLocation
        )
    }
}
