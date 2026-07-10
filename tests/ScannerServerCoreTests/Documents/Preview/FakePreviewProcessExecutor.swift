import Foundation
import ScannerServerCore

enum FakePreviewProcessError: Error, Sendable {
    case expectedFailure
    case missingOutputArgument
}

actor FakePreviewProcessExecutor: ProcessExecutor {
    enum Behavior: Sendable {
        case materialize(Data)
        case blockedMaterialize(Data)
        case processFailure
        case throwFailure
    }

    private struct RequestWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let behavior: Behavior
    private var recordedRequests: [ProcessRequest] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var requestWaiters: [RequestWaiter] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        recordedRequests.append(request)
        resumeSatisfiedRequestWaiters()

        switch behavior {
        case .materialize(let data):
            try materialize(data, for: request)
            return ProcessResult(exitStatus: 0)
        case .blockedMaterialize(let data):
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
            try materialize(data, for: request)
            return ProcessResult(exitStatus: 0)
        case .processFailure:
            return ProcessResult(exitStatus: 1, standardError: "expected failure")
        case .throwFailure:
            throw FakePreviewProcessError.expectedFailure
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

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func materialize(_ data: Data, for request: ProcessRequest) throws {
        guard let outputIndex = request.arguments.firstIndex(of: "--output"),
              request.arguments.indices.contains(outputIndex + 1)
        else {
            throw FakePreviewProcessError.missingOutputArgument
        }

        let outputArgument = request.arguments[outputIndex + 1]
        let path = outputArgument.split(separator: "[", maxSplits: 1).first.map(String.init) ?? outputArgument
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func resumeSatisfiedRequestWaiters() {
        let satisfied = requestWaiters.filter { recordedRequests.count >= $0.count }
        requestWaiters.removeAll { recordedRequests.count >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
