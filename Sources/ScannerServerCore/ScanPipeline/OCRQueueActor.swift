import Foundation

public struct OCRJobTiming: Equatable, Sendable {
    public let input: String
    public let output: String
    public let status: String
    public let duration: TimeInterval

    public init(input: String, output: String, status: String, duration: TimeInterval) {
        self.input = input
        self.output = output
        self.status = status
        self.duration = duration
    }
}

public struct OCRQueueState: Equatable, Sendable {
    public var started: Date?
    public var finished: Date?
    public var status: String
    public var input: String
    public var output: String
    public var error: String
    public var cpuLimit: Int
    public var niceLevel: Int?
    public var running: Int
    public var queued: Int
    public var recentJobs: [OCRJobTiming]

    public init(
        started: Date? = nil,
        finished: Date? = nil,
        status: String = "idle",
        input: String = "",
        output: String = "",
        error: String = "",
        cpuLimit: Int = 1,
        niceLevel: Int? = nil,
        running: Int = 0,
        queued: Int = 0,
        recentJobs: [OCRJobTiming] = []
    ) {
        self.started = started
        self.finished = finished
        self.status = status
        self.input = input
        self.output = output
        self.error = error
        self.cpuLimit = cpuLimit
        self.niceLevel = niceLevel
        self.running = running
        self.queued = queued
        self.recentJobs = recentJobs
    }
}

public actor OCRQueueActor {
    public typealias WorkspaceSuffixProvider = @Sendable () -> String
    public nonisolated let webUpdates: WebUpdateNotifier

    private struct Job: Sendable {
        let inputPath: String
        let batchID: UUID
        let environment: [String: String]?
        let workingDirectory: URL?
        let ocrEnabled: Bool
        let removeBlankPages: Bool
        let cropPages: Bool
    }

    private struct ActiveJob: Sendable {
        let job: Job
        let started: Date
        let reservedCPUs: Int
        let task: Task<Void, Never>
    }

    private struct JobCompletion: Sendable {
        let finished: Date
        let status: String
        let output: String
        let error: String
        let publishedOutputPath: String
    }

    private let executor: any ProcessExecutor
    private let documentExecutor: any ProcessExecutor
    private let workspaceSuffixProvider: WorkspaceSuffixProvider
    private let configuration: OCRQueueConfiguration
    private var queue: [Job] = []
    private var activeJobs: [UUID: ActiveJob] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var isCancellingAll = false
    private var queueState: OCRQueueState

    public init(
        executor: any ProcessExecutor,
        documentExecutor: (any ProcessExecutor)? = nil,
        workspaceSuffixProvider: @escaping WorkspaceSuffixProvider = { UUID().uuidString },
        configuration: OCRQueueConfiguration = OCRQueueConfiguration(),
        webUpdates: WebUpdateNotifier = WebUpdateNotifier()
    ) {
        self.executor = executor
        self.documentExecutor = documentExecutor ?? NativeDocumentToolExecutor(executor: executor)
        self.workspaceSuffixProvider = workspaceSuffixProvider
        self.configuration = configuration
        self.webUpdates = webUpdates
        self.queueState = OCRQueueState(
            cpuLimit: configuration.cpuLimit,
            niceLevel: configuration.niceLevel
        )
    }

    public var state: OCRQueueState { queueState }

    public func enqueue(
        _ inputPath: String,
        batchID: UUID = UUID(),
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        ocrEnabled: Bool = true,
        removeBlankPages: Bool = false,
        cropPages: Bool = false
    ) async {
        queue.append(Job(
            inputPath: inputPath,
            batchID: batchID,
            environment: environment,
            workingDirectory: workingDirectory,
            ocrEnabled: ocrEnabled,
            removeBlankPages: removeBlankPages,
            cropPages: cropPages
        ))
        scheduleAvailableJobs()
        await publishQueueState()
    }

    public func waitUntilIdle() async {
        guard !queue.isEmpty || !activeJobs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    public func cancelAll() async {
        queue.removeAll()
        isCancellingAll = true
        let tasks = activeJobs.values.map(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        isCancellingAll = false
        scheduleAvailableJobs()
        await publishQueueState()
    }

    public func cancelJobs(referencing path: String) async {
        let queuedCount = queue.count
        queue.removeAll { jobReferencesPath($0.inputPath, path: path) }
        let removedQueuedJob = queue.count != queuedCount
        queueState.queued = queue.count

        let matchingTasks = activeJobs.values
            .filter { jobReferencesPath($0.job.inputPath, path: path) }
            .map(\.task)
        for task in matchingTasks { task.cancel() }
        for task in matchingTasks { await task.value }

        if removedQueuedJob || !matchingTasks.isEmpty {
            scheduleAvailableJobs()
            await publishQueueState()
        }
    }

    private func scheduleAvailableJobs() {
        guard !isCancellingAll else { return }
        var availableCPUs = configuration.cpuLimit
            - activeJobs.values.reduce(0) { $0 + $1.reservedCPUs }

        while let index = queue.firstIndex(where: { canSchedule($0, availableCPUs: availableCPUs) }) {
            let job = queue[index]
            let reservedCPUs = cpuReservation(for: job)
            queue.remove(at: index)
            availableCPUs -= reservedCPUs
            start(job: job, reservedCPUs: reservedCPUs)
        }

        queueState.running = activeJobs.count
        queueState.queued = queue.count
        if !activeJobs.isEmpty {
            queueState.status = "running"
        } else if !queue.isEmpty {
            queueState.status = "queued"
        }
    }

    private func start(job: Job, reservedCPUs: Int) {
        let identifier = UUID()
        let started = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            let completion = await self.run(job: job, jobs: reservedCPUs)
            await self.finish(identifier: identifier, completion: completion)
        }
        activeJobs[identifier] = ActiveJob(
            job: job,
            started: started,
            reservedCPUs: reservedCPUs,
            task: task
        )
        queueState.started = started
        queueState.finished = nil
        queueState.input = job.inputPath
        queueState.output = ""
        queueState.error = ""
        queueState.niceLevel = configuration.niceLevel(for: job.environment)
    }

    private func run(job: Job, jobs: Int) async -> JobCompletion {
        guard job.inputPath.lowercased().hasSuffix(".pdf"),
              !job.inputPath.lowercased().hasSuffix(".ocr.pdf")
        else {
            return JobCompletion(
                finished: Date(),
                status: "failed (64)",
                output: "",
                error: "Raw PDF must end in .pdf and must not already be an OCR PDF: \(job.inputPath)",
                publishedOutputPath: ""
            )
        }
        let outputPath = job.ocrEnabled
            ? OCRInputPath.outputPath(for: job.inputPath)!
            : job.inputPath
        guard !job.ocrEnabled || !FileManager.default.fileExists(atPath: outputPath) else {
            return JobCompletion(
                finished: Date(),
                status: "failed (73)",
                output: "",
                error: "OCR output file already exists: \(outputPath)",
                publishedOutputPath: outputPath
            )
        }

        do {
            let result = try await execute(job: job, outputPath: outputPath, jobs: jobs)
            let processOutput = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return JobCompletion(
                finished: Date(),
                status: result.succeeded ? "done" : "failed (\(result.exitStatus))",
                output: result.succeeded && processOutput.isEmpty ? outputPath : processOutput,
                error: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines),
                publishedOutputPath: result.succeeded ? outputPath : ""
            )
        } catch is CancellationError {
            return JobCompletion(
                finished: Date(),
                status: "cancelled",
                output: "",
                error: "",
                publishedOutputPath: ""
            )
        } catch {
            return JobCompletion(
                finished: Date(),
                status: "failed",
                output: "",
                error: error.localizedDescription,
                publishedOutputPath: ""
            )
        }
    }

    private func finish(identifier: UUID, completion: JobCompletion) async {
        guard let activeJob = activeJobs.removeValue(forKey: identifier) else { return }
        record(
            job: activeJob.job,
            started: activeJob.started,
            completion: completion
        )
        queueState.finished = completion.finished
        queueState.input = activeJob.job.inputPath
        queueState.output = completion.output
        queueState.error = completion.error
        scheduleAvailableJobs()
        if activeJobs.isEmpty, queue.isEmpty {
            queueState.status = completion.status
            resumeIdleWaiters()
        }
        await publishQueueState()
    }

    private func record(job: Job, started: Date, completion: JobCompletion) {
        queueState.recentJobs.insert(
            OCRJobTiming(
                input: job.inputPath,
                output: completion.publishedOutputPath,
                status: completion.status,
                duration: max(0, completion.finished.timeIntervalSince(started))
            ),
            at: 0
        )
        if queueState.recentJobs.count > 20 {
            queueState.recentJobs.removeLast(queueState.recentJobs.count - 20)
        }
    }

    private func cpuReservation(for job: Job) -> Int {
        let pageMode = job.environment?["SCAN_PAGE_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return pageMode == "single" ? 1 : cpuLimit(for: job)
    }

    private func canSchedule(_ job: Job, availableCPUs: Int) -> Bool {
        let reservation = cpuReservation(for: job)
        guard reservation <= availableCPUs else { return false }
        let batchUsage = activeJobs.values
            .filter { $0.job.batchID == job.batchID }
            .reduce(0) { $0 + $1.reservedCPUs }
        return batchUsage + reservation <= cpuLimit(for: job)
    }

    private func cpuLimit(for job: Job) -> Int {
        guard let rawValue = job.environment?["SCAN_OCR_CPU_LIMIT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let requested = Int(rawValue),
            requested > 0
        else {
            return configuration.cpuLimit
        }
        return min(requested, configuration.cpuLimit)
    }

    private func publishQueueState() async {
        queueState.running = activeJobs.count
        queueState.queued = queue.count
        await webUpdates.notify()
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func jobReferencesPath(_ inputPath: String, path: String) -> Bool {
        let candidate = standardizedPath(path)
        if standardizedPath(inputPath) == candidate {
            return true
        }
        return OCRInputPath.outputPath(for: inputPath).map(standardizedPath) == candidate
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func execute(job: Job, outputPath: String, jobs: Int) async throws -> ProcessResult {
        guard job.removeBlankPages || job.cropPages else {
            guard job.ocrEnabled else {
                return ProcessResult(exitStatus: 0, standardOutput: job.inputPath + "\n")
            }
            return try await executor.execute(ScanPipelineCommands.ocr(
                inputPath: job.inputPath,
                outputPath: outputPath,
                environment: job.environment,
                workingDirectory: job.workingDirectory,
                jobs: jobs,
                niceLevel: configuration.niceLevel(for: job.environment)
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

        if job.ocrEnabled {
            return try await executor.execute(ScanPipelineCommands.ocr(
                inputPath: stagedInput.path,
                outputPath: outputPath,
                environment: job.environment,
                workingDirectory: workspace,
                jobs: jobs,
                niceLevel: configuration.niceLevel(for: job.environment)
            ))
        }

        try Task.checkCancellation()
        try FoundationNativeDocumentFileSystem().replaceFileAtomically(
            at: inputURL,
            with: stagedInput
        )
        return ProcessResult(exitStatus: 0, standardOutput: outputPath + "\n")
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
