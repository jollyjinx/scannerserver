import Foundation

public enum ScanJobEvent: Sendable, Hashable {
    case started
    case finished(succeeded: Bool)
}

public struct ScanJobState: Equatable, Sendable {
    public var started: Date?
    public var finished: Date?
    public var status: String
    public var output: String
    public var error: String

    public init(
        started: Date? = nil,
        finished: Date? = nil,
        status: String = "idle",
        output: String = "",
        error: String = ""
    ) {
        self.started = started
        self.finished = finished
        self.status = status
        self.output = output
        self.error = error
    }
}

public actor ScanJobActor {
    public typealias EventHandler = @Sendable (ScanJobEvent) async -> Void

    public nonisolated let webUpdates: WebUpdateNotifier
    private let nativeScanner: any NativeScanExecuting
    private let ocrQueue: OCRQueueActor?
    private var worker: Task<Void, Never>?
    private var jobState = ScanJobState()
    private var eventContinuations: [UUID: AsyncStream<ScanJobEvent>.Continuation] = [:]
    private var eventHandlers: [UUID: EventHandler] = [:]

    public init(
        nativeScanner: any NativeScanExecuting,
        ocrQueue: OCRQueueActor? = nil,
        webUpdates: WebUpdateNotifier = WebUpdateNotifier()
    ) {
        self.nativeScanner = nativeScanner
        self.ocrQueue = ocrQueue
        self.webUpdates = webUpdates
    }

    public var state: ScanJobState { jobState }

    public func eventStream() -> AsyncStream<ScanJobEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ScanJobEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        eventContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        return stream
    }

    @discardableResult
    public func addEventHandler(_ handler: @escaping EventHandler) -> UUID {
        let id = UUID()
        eventHandlers[id] = handler
        return id
    }

    public func removeEventHandler(_ id: UUID) {
        eventHandlers.removeValue(forKey: id)
    }

    @discardableResult
    public func start(configuration: ScanPipelineConfiguration) async -> Bool {
        guard worker == nil, jobState.status != "running" else { return false }

        jobState = ScanJobState(started: Date(), status: "running")
        await publish(.started)
        worker = Task {
            do {
                let result = try await nativeScanner.scan(configuration: configuration)
                await finish(result: result, configuration: configuration)
            } catch is CancellationError {
                await finishCancellation()
            } catch {
                await finish(error: error)
            }
        }
        await webUpdates.notify()
        return true
    }

    public func waitUntilIdle() async {
        let currentWorker = worker
        await currentWorker?.value
    }

    public func cancel() async {
        let currentWorker = worker
        currentWorker?.cancel()
        await currentWorker?.value
    }

    private func finish(result: ProcessResult, configuration: ScanPipelineConfiguration) async {
        let paths = ScanOutputPaths.existing(from: result.standardOutput)
        jobState.finished = Date()
        jobState.status = result.succeeded ? "done" : "failed (\(result.exitStatus))"
        jobState.output = paths.isEmpty
            ? result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            : paths.joined(separator: "\n")
        jobState.error = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.succeeded, let ocrQueue {
            let preprocessMultipagePDF = configuration.format == "pdf"
                && configuration.pageMode == "multi"
            for path in paths where ScanOutputPaths.shouldEnqueueOCR(path: path, configuration: configuration) {
                await ocrQueue.enqueue(
                    path,
                    environment: configuration.environment,
                    removeBlankPages: preprocessMultipagePDF && configuration.removeBlankPages,
                    cropPages: preprocessMultipagePDF && configuration.cropPages
                )
            }
        }
        worker = nil
        await publish(.finished(succeeded: result.succeeded))
        await webUpdates.notify()
    }

    private func finishCancellation() async {
        jobState.finished = Date()
        jobState.status = "cancelled"
        worker = nil
        await publish(.finished(succeeded: false))
        await webUpdates.notify()
    }

    private func finish(error: any Error) async {
        jobState.finished = Date()
        jobState.status = "failed"
        jobState.error = error.localizedDescription
        worker = nil
        await publish(.finished(succeeded: false))
        await webUpdates.notify()
    }

    private func publish(_ event: ScanJobEvent) async {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
        let handlers = Array(eventHandlers.values)
        for handler in handlers {
            await handler(event)
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}
