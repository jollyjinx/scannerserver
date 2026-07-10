import Foundation
import ScannerServerCore

enum FakeNativeDocumentToolError: Error, Sendable {
    case missingStub
}

actor FakeNativeDocumentProcessExecutor: ProcessExecutor {
    enum Stub: Sendable {
        case result(ProcessResult)
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
        guard !stubs.isEmpty else { throw FakeNativeDocumentToolError.missingStub }

        switch stubs.removeFirst() {
        case .result(let result):
            return result
        case .suspended:
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    suspendedExecutions.append(continuation)
                }
            } onCancel: {
                Task { await self.cancelNextSuspendedExecution() }
            }
            throw CancellationError()
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

final class FakeNativeDocumentFileSystem: NativeDocumentFileSystem, @unchecked Sendable {
    struct Placement: Equatable {
        let source: String
        let destination: String
    }

    private struct State {
        var items: Set<String> = []
        var dimensions: [String: NativeDocumentImageDimensions] = [:]
        var publicationConflicts: Set<String> = []
        var temporaryDirectoryCount = 0
        var temporaryDirectories: [String] = []
        var removedPaths: [String] = []
        var placements: [Placement] = []
    }

    private let lock = NSLock()
    private var state = State()

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        withState { state in
            _ = state.items.insert(url.path)
        }
    }

    func createTemporaryDirectory(in directory: URL) throws -> URL {
        withState { state in
            state.temporaryDirectoryCount += 1
            let url = directory.appendingPathComponent(
                ".native-document-tools-test-\(state.temporaryDirectoryCount)",
                isDirectory: true
            )
            state.items.insert(url.path)
            state.temporaryDirectories.append(url.path)
            return url
        }
    }

    func itemExists(at url: URL) -> Bool {
        withState { $0.items.contains(url.path) }
    }

    func removeItemIfPresent(at url: URL) throws {
        withState { state in
            let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
            state.items = Set(state.items.filter {
                $0 != url.path && !$0.hasPrefix(prefix)
            })
            state.dimensions = state.dimensions.filter { !$0.key.hasPrefix(prefix) }
            state.removedPaths.append(url.path)
        }
    }

    func regularFiles(
        in directory: URL,
        withPrefix prefix: String,
        pathExtension: String
    ) throws -> [URL] {
        withState { state in
            state.items
                .map { URL(fileURLWithPath: $0) }
                .filter {
                    $0.deletingLastPathComponent().path == directory.path
                        && $0.lastPathComponent.hasPrefix(prefix)
                        && $0.pathExtension == pathExtension
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    func pngDimensions(at url: URL) throws -> NativeDocumentImageDimensions? {
        withState { $0.dimensions[url.path] }
    }

    func placeFileExclusively(at source: URL, destination: URL) throws {
        try withState { state in
            if state.items.contains(destination.path)
                || state.publicationConflicts.contains(destination.path)
            {
                throw NativeDocumentFileSystemError.outputConflict(destination.path)
            }
            state.items.insert(destination.path)
            state.placements.append(Placement(
                source: source.path,
                destination: destination.path
            ))
        }
    }

    func addItem(_ path: String) {
        withState { state in
            _ = state.items.insert(path)
        }
    }

    func addPNG(_ path: String, width: UInt32, height: UInt32) {
        withState { state in
            state.items.insert(path)
            state.dimensions[path] = NativeDocumentImageDimensions(width: width, height: height)
        }
    }

    func conflictOnPublication(at path: String) {
        withState { state in
            _ = state.publicationConflicts.insert(path)
        }
    }

    func contains(_ path: String) -> Bool {
        withState { $0.items.contains(path) }
    }

    func recordedTemporaryDirectories() -> [String] {
        withState { $0.temporaryDirectories }
    }

    func recordedRemovedPaths() -> [String] {
        withState { $0.removedPaths }
    }

    func recordedPlacements() -> [Placement] {
        withState { $0.placements }
    }

    private func withState<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
