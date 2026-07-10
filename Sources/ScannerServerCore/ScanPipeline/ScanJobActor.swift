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
    private let executor: any ProcessExecutor
    private let ocrQueue: OCRQueueActor?
    private var worker: Task<Void, Never>?
    private var jobState = ScanJobState()

    public init(executor: any ProcessExecutor, ocrQueue: OCRQueueActor? = nil) {
        self.executor = executor
        self.ocrQueue = ocrQueue
    }

    public var state: ScanJobState { jobState }

    @discardableResult
    public func start(
        configuration: ScanPipelineConfiguration,
        workingDirectory: URL? = nil
    ) -> Bool {
        guard worker == nil else { return false }

        jobState = ScanJobState(started: Date(), status: "running")
        let request = ScanPipelineCommands.scan(
            configuration: configuration,
            workingDirectory: workingDirectory
        )
        worker = Task {
            do {
                let result = try await executor.execute(request)
                await finish(result: result, configuration: configuration)
            } catch is CancellationError {
                finishCancellation()
            } catch {
                finish(error: error)
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
            for path in paths where ScanOutputPaths.shouldEnqueueOCR(path: path, configuration: configuration) {
                await ocrQueue.enqueue(path, environment: configuration.environment)
            }
        }
        worker = nil
    }

    private func finishCancellation() {
        jobState.finished = Date()
        jobState.status = "cancelled"
        worker = nil
    }

    private func finish(error: any Error) {
        jobState.finished = Date()
        jobState.status = "failed"
        jobState.error = error.localizedDescription
        worker = nil
    }
}
