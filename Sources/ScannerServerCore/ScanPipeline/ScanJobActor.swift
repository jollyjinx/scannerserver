import Foundation

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
    public nonisolated let webUpdates: WebUpdateNotifier
    private let nativeScanner: any NativeScanExecuting
    private let ocrQueue: OCRQueueActor?
    private var worker: Task<Void, Never>?
    private var jobState = ScanJobState()

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

    @discardableResult
    public func start(configuration: ScanPipelineConfiguration) async -> Bool {
        guard worker == nil else { return false }

        jobState = ScanJobState(started: Date(), status: "running")
        await webUpdates.notify()
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
        await webUpdates.notify()
    }

    private func finishCancellation() async {
        jobState.finished = Date()
        jobState.status = "cancelled"
        worker = nil
        await webUpdates.notify()
    }

    private func finish(error: any Error) async {
        jobState.finished = Date()
        jobState.status = "failed"
        jobState.error = error.localizedDescription
        worker = nil
        await webUpdates.notify()
    }
}
