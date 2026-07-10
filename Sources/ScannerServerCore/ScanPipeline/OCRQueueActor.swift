import Foundation

public struct OCRQueueState: Equatable, Sendable {
    public var started: Date?
    public var finished: Date?
    public var status: String
    public var input: String
    public var output: String
    public var error: String
    public var queued: Int

    public init(
        started: Date? = nil,
        finished: Date? = nil,
        status: String = "idle",
        input: String = "",
        output: String = "",
        error: String = "",
        queued: Int = 0
    ) {
        self.started = started
        self.finished = finished
        self.status = status
        self.input = input
        self.output = output
        self.error = error
        self.queued = queued
    }
}

public actor OCRQueueActor {
    public typealias WorkspaceSuffixProvider = @Sendable () -> String

    private struct Job: Sendable {
        let inputPath: String
        let environment: [String: String]?
        let workingDirectory: URL?
        let removeBlankPages: Bool
        let cropPages: Bool
    }

    private let executor: any ProcessExecutor
    private let documentExecutor: any ProcessExecutor
    private let workspaceSuffixProvider: WorkspaceSuffixProvider
    private var queue: [Job] = []
    private var worker: Task<Void, Never>?
    private var queueState = OCRQueueState()

    public init(
        executor: any ProcessExecutor,
        documentExecutor: (any ProcessExecutor)? = nil,
        workspaceSuffixProvider: @escaping WorkspaceSuffixProvider = { UUID().uuidString }
    ) {
        self.executor = executor
        self.documentExecutor = documentExecutor ?? NativeDocumentToolExecutor(executor: executor)
        self.workspaceSuffixProvider = workspaceSuffixProvider
    }

    public var state: OCRQueueState { queueState }

    public func enqueue(
        _ inputPath: String,
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        removeBlankPages: Bool = false,
        cropPages: Bool = false
    ) {
        queue.append(Job(
            inputPath: inputPath,
            environment: environment,
            workingDirectory: workingDirectory,
            removeBlankPages: removeBlankPages,
            cropPages: cropPages
        ))
        queueState.queued = queue.count
        if queueState.status == "idle" {
            queueState.status = "queued"
        }

        guard worker == nil else { return }
        worker = Task { await runWorker() }
    }

    public func waitUntilIdle() async {
        let currentWorker = worker
        await currentWorker?.value
    }

    public func cancelAll() async {
        queue.removeAll()
        queueState.queued = 0
        let currentWorker = worker
        currentWorker?.cancel()
        await currentWorker?.value
    }

    private func runWorker() async {
        while !Task.isCancelled, !queue.isEmpty {
            let job = queue.removeFirst()
            queueState = OCRQueueState(
                started: Date(),
                status: "running",
                input: job.inputPath,
                queued: queue.count
            )

            guard let outputPath = OCRInputPath.outputPath(for: job.inputPath) else {
                queueState.finished = Date()
                queueState.status = "failed (64)"
                queueState.error = "Raw PDF must end in .pdf and must not already be an OCR PDF: \(job.inputPath)"
                continue
            }
            guard !FileManager.default.fileExists(atPath: outputPath) else {
                queueState.finished = Date()
                queueState.status = "failed (73)"
                queueState.error = "OCR output file already exists: \(outputPath)"
                continue
            }

            do {
                let result = try await execute(job: job, outputPath: outputPath)
                queueState.finished = Date()
                queueState.status = result.succeeded ? "done" : "failed (\(result.exitStatus))"
                let processOutput = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                queueState.output = result.succeeded && processOutput.isEmpty ? outputPath : processOutput
                queueState.error = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                queueState.queued = queue.count
            } catch is CancellationError {
                queue.removeAll()
                queueState.finished = Date()
                queueState.status = "cancelled"
                queueState.queued = 0
                break
            } catch {
                queueState.finished = Date()
                queueState.status = "failed"
                queueState.error = error.localizedDescription
                queueState.queued = queue.count
            }
        }

        if queueState.status == "queued" {
            queueState.status = "idle"
        }
        worker = nil
    }

    private func execute(job: Job, outputPath: String) async throws -> ProcessResult {
        guard job.removeBlankPages || job.cropPages else {
            return try await executor.execute(ScanPipelineCommands.ocr(
                inputPath: job.inputPath,
                outputPath: outputPath,
                environment: job.environment,
                workingDirectory: job.workingDirectory
            ))
        }

        let suffix = workspaceSuffixProvider()
        guard isValidPathComponent(suffix) else {
            throw OCRWorkspaceError.invalidSuffix
        }
        let inputURL = URL(fileURLWithPath: job.inputPath, isDirectory: false)
        let workspace = inputURL.deletingLastPathComponent().appendingPathComponent(
            ".ocr-work.\(suffix)",
            isDirectory: true
        )
        let stagedInput = workspace.appendingPathComponent("source.pdf", isDirectory: false)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: workspace) }
        try fileManager.copyItem(at: inputURL, to: stagedInput)

        let environment = job.environment ?? [:]
        let options = try DocumentProcessingOptions(environment: environment)
        if job.removeBlankPages {
            let result = try await documentExecutor.execute(
                options.removeBlankPagesRequest(pdfPath: stagedInput.path).command.processRequest(
                    environment: job.environment,
                    workingDirectory: workspace
                )
            )
            guard result.succeeded else { return result }
        }
        if job.cropPages {
            let result = try await documentExecutor.execute(
                options.cropPagesRequest(pdfPath: stagedInput.path).command.processRequest(
                    environment: job.environment,
                    workingDirectory: workspace
                )
            )
            guard result.succeeded else { return result }
        }

        return try await executor.execute(ScanPipelineCommands.ocr(
            inputPath: stagedInput.path,
            outputPath: outputPath,
            environment: job.environment,
            workingDirectory: workspace
        ))
    }

    private func isValidPathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }
}

private enum OCRWorkspaceError: Error, LocalizedError {
    case invalidSuffix

    var errorDescription: String? {
        "Invalid OCR work-directory suffix."
    }
}
