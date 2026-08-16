import Foundation

public struct OCRJobTiming: Equatable, Sendable {
    public let input: String
    public let output: String
    public let status: String
    public let duration: TimeInterval
    public let metadata: OCRWorkerJobMetadata?
    public let executionLocation: ProcessExecutionLocation?

    public init(
        input: String,
        output: String,
        status: String,
        duration: TimeInterval,
        metadata: OCRWorkerJobMetadata? = nil,
        executionLocation: ProcessExecutionLocation? = nil
    ) {
        self.input = input
        self.output = output
        self.status = status
        self.duration = duration
        self.metadata = metadata
        self.executionLocation = executionLocation
    }
}

public enum OCRQueueJobPhase: String, Equatable, Sendable {
    case waiting
    case processing
    case finalizing
}

public struct OCRQueueJobSnapshot: Equatable, Sendable {
    public let input: String
    public let documentName: String
    public let pageNumber: Int?
    public let operations: [String]
    public let phase: OCRQueueJobPhase
    public let started: Date?
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
    public var waitingJobs: [OCRQueueJobSnapshot]
    public var processingJobs: [OCRQueueJobSnapshot]
    public var finalizingJobs: [OCRQueueJobSnapshot]

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
        recentJobs: [OCRJobTiming] = [],
        waitingJobs: [OCRQueueJobSnapshot] = [],
        processingJobs: [OCRQueueJobSnapshot] = [],
        finalizingJobs: [OCRQueueJobSnapshot] = []
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
        self.waitingJobs = waitingJobs
        self.processingJobs = processingJobs
        self.finalizingJobs = finalizingJobs
    }
}

public struct StreamingScanRequest: Sendable {
    public let documentName: String
    public let finalOutputPath: String
    public let workDirectory: URL
    public let environment: [String: String]
    public let removeBlankPages: Bool
    public let cropPages: Bool

    public init(
        documentName: String,
        finalOutputPath: String,
        workDirectory: URL,
        environment: [String: String],
        removeBlankPages: Bool,
        cropPages: Bool
    ) {
        self.documentName = documentName
        self.finalOutputPath = finalOutputPath
        self.workDirectory = workDirectory
        self.environment = environment
        self.removeBlankPages = removeBlankPages
        self.cropPages = cropPages
    }
}

public struct ImportedPDFOCRRequest: Sendable {
    public let sourcePath: String
    public let documentName: String
    public let finalOutputPath: String
    public let workDirectory: URL
    public let environment: [String: String]
    public let removeBlankPages: Bool
    public let cropPages: Bool

    public init(
        sourcePath: String,
        documentName: String,
        finalOutputPath: String,
        workDirectory: URL,
        environment: [String: String],
        removeBlankPages: Bool,
        cropPages: Bool
    ) {
        self.sourcePath = sourcePath
        self.documentName = documentName
        self.finalOutputPath = finalOutputPath
        self.workDirectory = workDirectory
        self.environment = environment
        self.removeBlankPages = removeBlankPages
        self.cropPages = cropPages
    }
}

public struct OCRQueueWorkerCapacity: Equatable, Sendable {
    public let remoteJobSlots: Int
    public let internalOCREnabled: Bool

    public init(remoteJobSlots: Int = 0, internalOCREnabled: Bool = true) {
        self.remoteJobSlots = max(0, remoteJobSlots)
        self.internalOCREnabled = internalOCREnabled
    }
}

public protocol StreamingPagePDFWriting: Sendable {
    func write(pages: [Data], to outputURL: URL) async throws
}

extension ScanSnapPDFWriter: StreamingPagePDFWriting {}

public actor OCRQueueActor {
    public typealias WorkspaceSuffixProvider = @Sendable () -> String
    public typealias WorkerCapacityProvider = @Sendable () async -> OCRQueueWorkerCapacity
    public nonisolated let webUpdates: WebUpdateNotifier

    private struct Job: Sendable {
        let inputPath: String
        let batchID: UUID
        let environment: [String: String]?
        let workingDirectory: URL?
        let ocrEnabled: Bool
        let removeBlankPages: Bool
        let cropPages: Bool
        let deferredProcessing: DeferredScanProcessing?
        let workerMetadata: OCRWorkerJobMetadata?
        let streamingPageNumber: Int?
    }

    private struct StreamingPage: Sendable {
        let inputPath: String
        var outputPath: String?
        var status: String?
    }

    private struct StreamingBatch: Sendable {
        let request: StreamingScanRequest
        var pages: [Int: StreamingPage]
        var acquisitionFinished: Bool
        var expectedPageCount: Int?
        var finalizationStarted: Date?
    }

    private struct ActiveJob: Sendable {
        let job: Job
        let started: Date
        let reservedCPUs: Int
        let localReservationCPUs: Int
        let executionPreference: OCRExecutionPreference
        let task: Task<Void, Never>
    }

    private struct ScheduleCandidate: Sendable {
        let index: Int
        let reservedCPUs: Int
        let localReservationCPUs: Int
        let executionPreference: OCRExecutionPreference
    }

    private struct JobCompletion: Sendable {
        let finished: Date
        let status: String
        let output: String
        let error: String
        let publishedOutputPath: String
        let followUpJobs: [Job]
        let executionLocation: ProcessExecutionLocation?

        init(
            finished: Date,
            status: String,
            output: String,
            error: String,
            publishedOutputPath: String,
            followUpJobs: [Job] = [],
            executionLocation: ProcessExecutionLocation? = nil
        ) {
            self.finished = finished
            self.status = status
            self.output = output
            self.error = error
            self.publishedOutputPath = publishedOutputPath
            self.followUpJobs = followUpJobs
            self.executionLocation = executionLocation
        }
    }

    private let executor: any ProcessExecutor
    private let documentExecutor: any ProcessExecutor
    private let streamingPageWriter: any StreamingPagePDFWriting
    private let workspaceSuffixProvider: WorkspaceSuffixProvider
    private let configuration: OCRQueueConfiguration
    private let localCapacity: OCRLocalCapacityPool
    private let workerCapacityProvider: WorkerCapacityProvider
    private var queue: [Job] = []
    private var activeJobs: [UUID: ActiveJob] = [:]
    private var streamingBatches: [UUID: StreamingBatch] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var isCancellingAll = false
    private var queueState: OCRQueueState

    public init(
        executor: any ProcessExecutor,
        documentExecutor: (any ProcessExecutor)? = nil,
        streamingPageWriter: any StreamingPagePDFWriting = ScanSnapPDFWriter(),
        workspaceSuffixProvider: @escaping WorkspaceSuffixProvider = { UUID().uuidString },
        configuration: OCRQueueConfiguration = OCRQueueConfiguration(),
        localCapacity: OCRLocalCapacityPool? = nil,
        workerCapacityProvider: @escaping WorkerCapacityProvider = {
            OCRQueueWorkerCapacity()
        },
        webUpdates: WebUpdateNotifier = WebUpdateNotifier()
    ) {
        self.executor = executor
        self.documentExecutor = documentExecutor ?? NativeDocumentToolExecutor(executor: executor)
        self.streamingPageWriter = streamingPageWriter
        self.workspaceSuffixProvider = workspaceSuffixProvider
        self.configuration = configuration
        self.localCapacity = localCapacity ?? OCRLocalCapacityPool(
            capacity: configuration.cpuLimit,
            webUpdates: webUpdates
        )
        self.workerCapacityProvider = workerCapacityProvider
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
            cropPages: cropPages,
            deferredProcessing: nil,
            workerMetadata: nil,
            streamingPageNumber: nil
        ))
        await scheduleAvailableJobs()
        await publishQueueState()
    }

    public func enqueue(_ deferredProcessing: DeferredScanProcessing) async {
        queue.append(Job(
            inputPath: deferredProcessing.inputPath,
            batchID: UUID(),
            environment: deferredProcessing.plan.environment,
            workingDirectory: deferredProcessing.plan.workingDirectory,
            ocrEnabled: deferredProcessing.ocrEnabled,
            removeBlankPages: deferredProcessing.plan.removeBlankPages != nil,
            cropPages: deferredProcessing.plan.cropPages != nil,
            deferredProcessing: deferredProcessing,
            workerMetadata: nil,
            streamingPageNumber: nil
        ))
        await scheduleAvailableJobs()
        await publishQueueState()
    }

    public func beginStreamingScan(_ request: StreamingScanRequest) -> UUID {
        let batchID = UUID()
        streamingBatches[batchID] = StreamingBatch(
            request: request,
            pages: [:],
            acquisitionFinished: false,
            expectedPageCount: nil,
            finalizationStarted: nil
        )
        return batchID
    }

    public func enqueueImportedPDF(_ imported: ImportedPDFOCRRequest) async throws -> Int {
        try FileManager.default.createDirectory(
            at: imported.workDirectory,
            withIntermediateDirectories: false
        )
        let batchID = beginStreamingScan(StreamingScanRequest(
            documentName: imported.documentName,
            finalOutputPath: imported.finalOutputPath,
            workDirectory: imported.workDirectory,
            environment: imported.environment,
            removeBlankPages: imported.removeBlankPages,
            cropPages: imported.cropPages
        ))

        do {
            let pageCountResult = try await documentExecutor.execute(ProcessRequest(
                executable: "qpdf",
                arguments: ["--show-npages", imported.sourcePath],
                environment: imported.environment,
                workingDirectory: imported.workDirectory
            ))
            guard pageCountResult.succeeded,
                  let pageCount = Int(
                    pageCountResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                  ),
                  pageCount > 0 else {
                throw StreamingScanError.importPreparationFailed(
                    pageCountResult.standardError.isEmpty
                        ? "The uploaded PDF has no readable pages."
                        : pageCountResult.standardError
                )
            }

            for pageNumber in 1...pageCount {
                try Task.checkCancellation()
                let pageURL = imported.workDirectory.appendingPathComponent(
                    String(format: "page-%04d.pdf", pageNumber),
                    isDirectory: false
                )
                let splitResult = try await documentExecutor.execute(ProcessRequest(
                    executable: "qpdf",
                    arguments: [
                        imported.sourcePath,
                        "--pages", ".", String(pageNumber), "--", pageURL.path,
                    ],
                    environment: imported.environment,
                    workingDirectory: imported.workDirectory
                ))
                guard splitResult.succeeded,
                      FileManager.default.fileExists(atPath: pageURL.path) else {
                    throw StreamingScanError.importPreparationFailed(
                        splitResult.standardError.isEmpty
                            ? "Could not extract page \(pageNumber)."
                            : splitResult.standardError
                    )
                }
                try await submitPreparedStreamingPage(
                    batchID: batchID,
                    pageNumber: pageNumber,
                    inputURL: pageURL
                )
            }

            try await finishStreamingScan(batchID: batchID, pageCount: pageCount)
            return pageCount
        } catch {
            await cancelStreamingScan(batchID: batchID)
            throw error
        }
    }

    public func submitStreamingPage(
        batchID: UUID,
        page: ScanSnapAcquiredPage
    ) async throws {
        guard var batch = streamingBatches[batchID], !batch.acquisitionFinished else {
            throw StreamingScanError.unknownBatch
        }
        guard page.pageNumber > 0, batch.pages[page.pageNumber] == nil else {
            throw StreamingScanError.invalidPageNumber
        }
        let inputURL = batch.request.workDirectory.appendingPathComponent(
            String(format: "page-%04d.pdf", page.pageNumber),
            isDirectory: false
        )
        batch.pages[page.pageNumber] = StreamingPage(
            inputPath: inputURL.path,
            outputPath: nil,
            status: nil
        )
        streamingBatches[batchID] = batch

        do {
            try await streamingPageWriter.write(pages: [page.jpegData], to: inputURL)
            try Task.checkCancellation()
        } catch {
            removeStreamingPageReservation(
                batchID: batchID,
                pageNumber: page.pageNumber,
                inputPath: inputURL.path
            )
            try? FileManager.default.removeItem(at: inputURL)
            throw error
        }
        guard streamingBatches[batchID]?.pages[page.pageNumber]?.inputPath == inputURL.path else {
            try? FileManager.default.removeItem(at: inputURL)
            throw StreamingScanError.unknownBatch
        }

        try await enqueueReservedStreamingPage(
            batchID: batchID,
            pageNumber: page.pageNumber,
            inputURL: inputURL
        )
    }

    private func submitPreparedStreamingPage(
        batchID: UUID,
        pageNumber: Int,
        inputURL: URL
    ) async throws {
        guard var batch = streamingBatches[batchID], !batch.acquisitionFinished else {
            throw StreamingScanError.unknownBatch
        }
        guard pageNumber > 0, batch.pages[pageNumber] == nil else {
            throw StreamingScanError.invalidPageNumber
        }
        batch.pages[pageNumber] = StreamingPage(
            inputPath: inputURL.path,
            outputPath: nil,
            status: nil
        )
        streamingBatches[batchID] = batch
        try await enqueueReservedStreamingPage(
            batchID: batchID,
            pageNumber: pageNumber,
            inputURL: inputURL
        )
    }

    private func enqueueReservedStreamingPage(
        batchID: UUID,
        pageNumber: Int,
        inputURL: URL
    ) async throws {
        guard let request = streamingBatches[batchID]?.request,
              streamingBatches[batchID]?.pages[pageNumber]?.inputPath == inputURL.path else {
            throw StreamingScanError.unknownBatch
        }
        var operations: [String] = []
        if request.removeBlankPages { operations.append("remove blank pages") }
        if request.cropPages { operations.append("trim/crop") }
        let language = request.environment["SCAN_LANGUAGE"] ?? "deu+eng"
        operations.append("OCR (\(language))")
        queue.append(Job(
            inputPath: inputURL.path,
            batchID: batchID,
            environment: request.environment,
            workingDirectory: request.workDirectory,
            ocrEnabled: true,
            removeBlankPages: request.removeBlankPages,
            cropPages: request.cropPages,
            deferredProcessing: nil,
            workerMetadata: OCRWorkerJobMetadata(
                documentName: request.documentName,
                batchID: batchID.uuidString.lowercased(),
                pageNumber: pageNumber,
                operations: operations
            ),
            streamingPageNumber: pageNumber
        ))
        await scheduleAvailableJobs()
        await publishQueueState()
    }

    private func removeStreamingPageReservation(
        batchID: UUID,
        pageNumber: Int,
        inputPath: String
    ) {
        guard var batch = streamingBatches[batchID],
              let page = batch.pages[pageNumber],
              page.inputPath == inputPath,
              page.status == nil else {
            return
        }
        batch.pages.removeValue(forKey: pageNumber)
        streamingBatches[batchID] = batch
    }

    public func finishStreamingScan(batchID: UUID, pageCount: Int) async throws {
        guard var batch = streamingBatches[batchID] else {
            throw StreamingScanError.unknownBatch
        }
        guard pageCount == batch.pages.count else {
            throw StreamingScanError.pageCountMismatch(expected: pageCount, received: batch.pages.count)
        }
        batch.acquisitionFinished = true
        batch.expectedPageCount = pageCount
        streamingBatches[batchID] = batch
        try await finalizeStreamingBatchIfReady(batchID)
        await publishQueueState()
    }

    public func cancelStreamingScan(batchID: UUID) async {
        queue.removeAll { $0.batchID == batchID }
        let tasks = activeJobs.values.filter { $0.job.batchID == batchID }.map(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        if let batch = streamingBatches.removeValue(forKey: batchID) {
            try? FileManager.default.removeItem(at: batch.request.workDirectory)
        }
        await scheduleAvailableJobs()
        resumeIdleWaitersIfIdle()
        await publishQueueState()
    }

    public func waitUntilIdle() async {
        guard !queue.isEmpty || !activeJobs.isEmpty || !streamingBatches.isEmpty else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    public func cancelAll() async {
        let queuedJobs = queue
        queue.removeAll()
        for job in queuedJobs {
            job.deferredProcessing?.removeCleanupDirectoryIfValid()
        }
        isCancellingAll = true
        let tasks = activeJobs.values.map(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        let batches = streamingBatches.values
        streamingBatches.removeAll()
        for batch in batches {
            try? FileManager.default.removeItem(at: batch.request.workDirectory)
        }
        isCancellingAll = false
        await scheduleAvailableJobs()
        await publishQueueState()
    }

    public func cancelJobs(referencing path: String) async {
        let matchingBatchIDs = Set(streamingBatches.compactMap { batchID, batch in
            streamingBatch(batch, references: path) ? batchID : nil
        })
        let removedJobs = queue.filter {
            matchingBatchIDs.contains($0.batchID)
                || jobReferencesPath($0.inputPath, path: path)
        }
        let queuedCount = queue.count
        queue.removeAll {
            matchingBatchIDs.contains($0.batchID)
                || jobReferencesPath($0.inputPath, path: path)
        }
        for job in removedJobs {
            job.deferredProcessing?.removeCleanupDirectoryIfValid()
        }
        let removedQueuedJob = queue.count != queuedCount
        queueState.queued = queue.count

        let matchingTasks = activeJobs.values
            .filter {
                matchingBatchIDs.contains($0.job.batchID)
                    || jobReferencesPath($0.job.inputPath, path: path)
            }
            .map(\.task)
        let removedBatches = matchingBatchIDs.compactMap {
            streamingBatches.removeValue(forKey: $0)
        }
        for task in matchingTasks { task.cancel() }
        for task in matchingTasks { await task.value }
        for batch in removedBatches {
            try? FileManager.default.removeItem(at: batch.request.workDirectory)
        }

        if removedQueuedJob || !matchingTasks.isEmpty || !removedBatches.isEmpty {
            await scheduleAvailableJobs()
            resumeIdleWaitersIfIdle()
            await publishQueueState()
        }
    }

    @discardableResult
    private func scheduleAvailableJobs() async -> Bool {
        guard !isCancellingAll else { return false }
        let workerCapacity = await workerCapacityProvider()
        var startedJob = false

        while let candidate = await nextSchedulableJob(workerCapacity: workerCapacity) {
            let job = queue[candidate.index]
            queue.remove(at: candidate.index)
            start(
                job: job,
                reservedCPUs: candidate.reservedCPUs,
                localReservationCPUs: candidate.localReservationCPUs,
                executionPreference: candidate.executionPreference
            )
            startedJob = true
        }

        queueState.running = activeJobs.count
        queueState.queued = queue.count
        if !activeJobs.isEmpty {
            queueState.status = "running"
        } else if !queue.isEmpty {
            queueState.status = "queued"
        }
        return startedJob
    }

    public func capacityDidChange() async {
        if await scheduleAvailableJobs() {
            await publishQueueState()
        }
    }

    private func start(
        job: Job,
        reservedCPUs: Int,
        localReservationCPUs: Int,
        executionPreference: OCRExecutionPreference
    ) {
        let identifier = UUID()
        let started = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            let completion = await self.run(
                job: job,
                jobs: reservedCPUs,
                executionPreference: executionPreference
            )
            await self.finish(identifier: identifier, completion: completion)
        }
        activeJobs[identifier] = ActiveJob(
            job: job,
            started: started,
            reservedCPUs: reservedCPUs,
            localReservationCPUs: localReservationCPUs,
            executionPreference: executionPreference,
            task: task
        )
        queueState.started = started
        queueState.finished = nil
        queueState.input = job.inputPath
        queueState.output = ""
        queueState.error = ""
        queueState.niceLevel = configuration.niceLevel(for: job.environment)
    }

    private func run(
        job: Job,
        jobs: Int,
        executionPreference: OCRExecutionPreference
    ) async -> JobCompletion {
        if let deferredProcessing = job.deferredProcessing {
            return await runDeferredProcessing(
                job: job,
                deferredProcessing: deferredProcessing
            )
        }

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
            let result = try await execute(
                job: job,
                outputPath: outputPath,
                jobs: jobs,
                executionPreference: executionPreference
            )
            let processOutput = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return JobCompletion(
                finished: Date(),
                status: result.succeeded ? "done" : "failed (\(result.exitStatus))",
                output: result.succeeded && processOutput.isEmpty ? outputPath : processOutput,
                error: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines),
                publishedOutputPath: result.succeeded ? outputPath : "",
                executionLocation: result.executionLocation
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
        var streamingFinalizationFailed = false
        let effectiveCompletion = isCancellingAll || Task.isCancelled
            ? JobCompletion(
                finished: Date(),
                status: "cancelled",
                output: "",
                error: "",
                publishedOutputPath: ""
            )
            : completion
        record(
            job: activeJob.job,
            started: activeJob.started,
            completion: effectiveCompletion
        )
        queueState.finished = effectiveCompletion.finished
        queueState.input = activeJob.job.inputPath
        queueState.output = effectiveCompletion.output
        queueState.error = effectiveCompletion.error
        queue.append(contentsOf: effectiveCompletion.followUpJobs)
        if activeJob.localReservationCPUs > 0 {
            await localCapacity.release(activeJob.localReservationCPUs)
        }
        await scheduleAvailableJobs()
        if let pageNumber = activeJob.job.streamingPageNumber,
           var batch = streamingBatches[activeJob.job.batchID],
           var page = batch.pages[pageNumber]
        {
            page.outputPath = effectiveCompletion.publishedOutputPath.isEmpty
                ? nil
                : effectiveCompletion.publishedOutputPath
            page.status = effectiveCompletion.status
            batch.pages[pageNumber] = page
            streamingBatches[activeJob.job.batchID] = batch
            do {
                try await finalizeStreamingBatchIfReady(activeJob.job.batchID)
            } catch {
                streamingFinalizationFailed = true
                queueState.status = "failed"
                queueState.error = error.localizedDescription
                if let failedBatch = streamingBatches.removeValue(forKey: activeJob.job.batchID) {
                    try? FileManager.default.removeItem(at: failedBatch.request.workDirectory)
                }
            }
        }
        if activeJobs.isEmpty, queue.isEmpty, streamingBatches.isEmpty {
            if !streamingFinalizationFailed {
                queueState.status = effectiveCompletion.status
            }
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
                duration: max(0, completion.finished.timeIntervalSince(started)),
                metadata: job.workerMetadata,
                executionLocation: completion.executionLocation
            ),
            at: 0
        )
        if queueState.recentJobs.count > 20 {
            queueState.recentJobs.removeLast(queueState.recentJobs.count - 20)
        }
    }

    private func cpuReservation(for job: Job) -> Int {
        if job.deferredProcessing != nil {
            return cpuLimit(for: job)
        }
        if job.streamingPageNumber != nil { return 1 }
        let pageMode = job.environment?["SCAN_PAGE_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return pageMode == "single" ? 1 : cpuLimit(for: job)
    }

    private func nextSchedulableJob(
        workerCapacity: OCRQueueWorkerCapacity
    ) async -> ScheduleCandidate? {
        for (index, job) in queue.enumerated() {
            let reservedCPUs = cpuReservation(for: job)
            if canUseDistributedCapacity(job) {
                let activeDistributedJobs = activeJobs.values.filter {
                    canUseDistributedCapacity($0.job)
                }
                let activeRemoteJobs = activeDistributedJobs.filter {
                    $0.executionPreference == .automatic
                }
                let activeRemoteBatchJobs = activeRemoteJobs.filter {
                    $0.job.batchID == job.batchID
                }
                if activeRemoteJobs.count < workerCapacity.remoteJobSlots,
                   activeRemoteBatchJobs.count < workerCapacity.remoteJobSlots {
                    return ScheduleCandidate(
                        index: index,
                        reservedCPUs: reservedCPUs,
                        localReservationCPUs: 0,
                        executionPreference: .automatic
                    )
                }

                let localLimit = workerCapacity.internalOCREnabled ? cpuLimit(for: job) : 0
                let activeLocalJobs = activeDistributedJobs.filter {
                    $0.executionPreference == .localOnly
                }
                let activeLocalBatchJobs = activeLocalJobs.filter {
                    $0.job.batchID == job.batchID
                }
                if activeLocalJobs.count < localLimit,
                   activeLocalBatchJobs.count < localLimit {
                    return ScheduleCandidate(
                        index: index,
                        reservedCPUs: reservedCPUs,
                        localReservationCPUs: 0,
                        executionPreference: .localOnly
                    )
                }
                continue
            }

            let batchUsage = activeJobs.values
                .filter {
                    $0.job.batchID == job.batchID
                        && !canUseDistributedCapacity($0.job)
                }
                .reduce(0) { $0 + $1.localReservationCPUs }
            guard batchUsage + reservedCPUs <= cpuLimit(for: job),
                  let localReservation = await localCapacity.tryAcquire(reservedCPUs) else {
                continue
            }
            return ScheduleCandidate(
                index: index,
                reservedCPUs: reservedCPUs,
                localReservationCPUs: localReservation,
                executionPreference: .automatic
            )
        }
        return nil
    }

    private func canUseDistributedCapacity(_ job: Job) -> Bool {
        job.deferredProcessing == nil
            && job.ocrEnabled
            && (
                job.streamingPageNumber != nil
                    || (!job.removeBlankPages && !job.cropPages && pageMode(for: job) == "single")
            )
    }

    private func pageMode(for job: Job) -> String? {
        job.environment?["SCAN_PAGE_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
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
        queueState.waitingJobs = queue.map {
            queueSnapshot(job: $0, phase: .waiting, started: nil)
        }
        queueState.processingJobs = activeJobs.values
            .sorted { $0.started < $1.started }
            .map { queueSnapshot(job: $0.job, phase: .processing, started: $0.started) }
        queueState.finalizingJobs = streamingBatches.values.compactMap { batch in
            guard let started = batch.finalizationStarted else { return nil }
            var operations = ["assemble OCR pages"]
            operations.append("publish searchable PDF")
            return OCRQueueJobSnapshot(
                input: batch.request.finalOutputPath,
                documentName: batch.request.documentName,
                pageNumber: nil,
                operations: operations,
                phase: .finalizing,
                started: started
            )
        }
        .sorted { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) }
        await webUpdates.notify()
    }

    private func queueSnapshot(
        job: Job,
        phase: OCRQueueJobPhase,
        started: Date?
    ) -> OCRQueueJobSnapshot {
        var operations = job.workerMetadata?.operations ?? []
        if operations.isEmpty {
            if job.removeBlankPages { operations.append("remove blank pages") }
            if job.cropPages { operations.append("trim/crop") }
            if job.ocrEnabled {
                let language = job.environment?["SCAN_LANGUAGE"] ?? "deu+eng"
                operations.append("OCR (\(language))")
            }
        }
        return OCRQueueJobSnapshot(
            input: job.inputPath,
            documentName: job.workerMetadata?.documentName
                ?? URL(fileURLWithPath: job.inputPath).lastPathComponent,
            pageNumber: job.workerMetadata?.pageNumber,
            operations: operations,
            phase: phase,
            started: started
        )
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

    private func streamingBatch(_ batch: StreamingBatch, references path: String) -> Bool {
        let candidate = standardizedPath(path)
        if standardizedPath(batch.request.finalOutputPath) == candidate {
            return true
        }
        if OCRInputPath.outputPath(for: path).map(standardizedPath)
            == standardizedPath(batch.request.finalOutputPath) {
            return true
        }
        return batch.request.documentName == URL(fileURLWithPath: candidate).lastPathComponent
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func execute(
        job: Job,
        outputPath: String,
        jobs: Int,
        executionPreference: OCRExecutionPreference
    ) async throws -> ProcessResult {
        if job.streamingPageNumber != nil {
            return try await executeStreamingPage(
                job: job,
                outputPath: outputPath,
                jobs: jobs,
                executionPreference: executionPreference
            )
        }
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
                niceLevel: configuration.niceLevel(for: job.environment),
                workerMetadata: workerMetadata(for: job),
                executionPreference: executionPreference
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
        let documentExecutor = prioritizedDocumentExecutor(for: job)
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
                niceLevel: configuration.niceLevel(for: job.environment),
                workerMetadata: workerMetadata(for: job),
                executionPreference: executionPreference
            ))
        }

        try Task.checkCancellation()
        try FoundationNativeDocumentFileSystem().replaceFileAtomically(
            at: inputURL,
            with: stagedInput
        )
        return ProcessResult(exitStatus: 0, standardOutput: outputPath + "\n")
    }

    private func executeStreamingPage(
        job: Job,
        outputPath: String,
        jobs: Int,
        executionPreference: OCRExecutionPreference
    ) async throws -> ProcessResult {
        let environment = job.environment ?? [:]
        let cropConfiguration = job.cropPages
            ? OCRWorkerCropConfiguration(
                request: try DocumentProcessingOptions(environment: environment)
                    .cropPagesRequest(pdfPath: outputPath)
            )
            : nil
        let blankPageConfiguration = job.removeBlankPages
            ? OCRWorkerBlankPageConfiguration(
                request: try DocumentProcessingOptions(environment: environment)
                    .removeBlankPagesRequest(pdfPath: outputPath)
            )
            : nil
        let result = try await executor.execute(ScanPipelineCommands.ocr(
            inputPath: job.inputPath,
            outputPath: outputPath,
            environment: job.environment,
            workingDirectory: job.workingDirectory,
            jobs: jobs,
            niceLevel: configuration.niceLevel(for: job.environment),
            workerMetadata: workerMetadata(for: job),
            workerCropConfiguration: cropConfiguration,
            workerBlankPageConfiguration: blankPageConfiguration,
            executionPreference: executionPreference
        ))
        guard result.succeeded, result.executionLocation == .local else {
            return result
        }

        let documentExecutor = prioritizedDocumentExecutor(for: job)
        if let cropConfiguration {
            let cropResult = try await documentExecutor.execute(
                cropConfiguration.request(pdfPath: outputPath).command.processRequest(
                    environment: job.environment,
                    workingDirectory: job.workingDirectory
                )
            )
            guard cropResult.succeeded else { return cropResult }
        }
        if let blankPageConfiguration {
            let blankResult = try await documentExecutor.execute(
                blankPageConfiguration.request(pdfPath: outputPath).command.processRequest(
                    environment: job.environment,
                    workingDirectory: job.workingDirectory
                )
            )
            guard blankResult.succeeded else { return blankResult }
        }
        return result
    }

    private func runDeferredProcessing(
        job: Job,
        deferredProcessing: DeferredScanProcessing
    ) async -> JobCompletion {
        if let validationError = deferredProcessing.validationError {
            return JobCompletion(
                finished: Date(),
                status: "failed (64)",
                output: "",
                error: validationError,
                publishedOutputPath: ""
            )
        }
        defer { deferredProcessing.removeCleanupDirectoryIfValid() }

        do {
            let result = try await DocumentProcessingOrchestrator(
                executor: prioritizedDocumentExecutor(for: job)
            )
                .process(deferredProcessing.plan)
            guard result.outputPaths.allSatisfy(regularFileExists) else {
                return JobCompletion(
                    finished: Date(),
                    status: "failed (2)",
                    output: "",
                    error: "No output files were created.",
                    publishedOutputPath: ""
                )
            }
            let output = result.outputPaths.joined(separator: "\n")
            let followUpJobs: [Job] = deferredProcessing.ocrEnabled
                ? result.outputPaths.compactMap { path in
                    guard path.lowercased().hasSuffix(".pdf") else { return nil }
                    return Job(
                        inputPath: path,
                        batchID: job.batchID,
                        environment: job.environment,
                        workingDirectory: nil,
                        ocrEnabled: true,
                        removeBlankPages: false,
                        cropPages: false,
                        deferredProcessing: nil,
                        workerMetadata: nil,
                        streamingPageNumber: nil
                    )
                }
                : []
            return JobCompletion(
                finished: Date(),
                status: "done",
                output: output,
                error: "",
                publishedOutputPath: output,
                followUpJobs: followUpJobs
            )
        } catch is CancellationError {
            return JobCompletion(
                finished: Date(),
                status: "cancelled",
                output: "",
                error: "",
                publishedOutputPath: ""
            )
        } catch let error as DocumentProcessingError {
            return JobCompletion(
                finished: Date(),
                status: "failed (\(error.compatibleExitStatus))",
                output: "",
                error: error.processResult.standardError.isEmpty
                    ? error.localizedDescription
                    : error.processResult.standardError.trimmingCharacters(in: .whitespacesAndNewlines),
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

    private func prioritizedDocumentExecutor(for job: Job) -> any ProcessExecutor {
        guard let niceLevel = configuration.niceLevel(for: job.environment) else {
            return documentExecutor
        }
        return NiceProcessExecutor(executor: documentExecutor, niceLevel: niceLevel)
    }

    private func isValidPathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }

    private func regularFileExists(at path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private func workerMetadata(for job: Job) -> OCRWorkerJobMetadata {
        if let metadata = job.workerMetadata { return metadata }
        var operations: [String] = []
        if job.removeBlankPages { operations.append("remove blank pages") }
        if job.cropPages { operations.append("trim/crop") }
        if job.ocrEnabled {
            operations.append("OCR (\(job.environment?["SCAN_LANGUAGE"] ?? "deu+eng"))")
        }
        return OCRWorkerJobMetadata(
            documentName: URL(fileURLWithPath: job.inputPath).lastPathComponent,
            operations: operations
        )
    }

    private func finalizeStreamingBatchIfReady(_ batchID: UUID) async throws {
        guard var batch = streamingBatches[batchID],
              batch.acquisitionFinished,
              let expectedPageCount = batch.expectedPageCount,
              batch.pages.count == expectedPageCount,
              batch.pages.values.allSatisfy({ $0.status != nil }),
              batch.finalizationStarted == nil
        else { return }

        let failedPages = batch.pages
            .filter { $0.value.status != "done" }
            .map(\.key)
            .sorted()
        guard failedPages.isEmpty else {
            streamingBatches.removeValue(forKey: batchID)
            try? FileManager.default.removeItem(at: batch.request.workDirectory)
            throw StreamingScanError.pageProcessingFailed(failedPages)
        }
        var outputPaths = batch.pages.keys.sorted().compactMap { batch.pages[$0]?.outputPath }
        guard outputPaths.count == expectedPageCount else {
            throw StreamingScanError.pageProcessingFailed(Array(1...expectedPageCount))
        }

        batch.finalizationStarted = Date()
        streamingBatches[batchID] = batch
        await publishQueueState()

        let stagingURL = batch.request.workDirectory.appendingPathComponent("assembled.ocr.pdf")
        if batch.request.removeBlankPages {
            var retainedOutputPaths: [String] = []
            for outputPath in outputPaths {
                let pageCount = try await documentExecutor.execute(ProcessRequest(
                    executable: "qpdf",
                    arguments: ["--show-npages", outputPath],
                    environment: batch.request.environment,
                    workingDirectory: batch.request.workDirectory
                ))
                guard pageCount.succeeded,
                      let count = Int(
                        pageCount.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                      ) else {
                    throw StreamingScanError.assemblyFailed(pageCount.standardError)
                }
                if count > 0 { retainedOutputPaths.append(outputPath) }
            }
            outputPaths = retainedOutputPaths
        }
        if outputPaths.isEmpty {
            guard batch.request.removeBlankPages,
               let firstPageNumber = batch.pages.keys.min(),
               let firstPage = batch.pages[firstPageNumber] else {
                throw StreamingScanError.pageProcessingFailed(Array(1...expectedPageCount))
            }
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: firstPage.inputPath),
                to: stagingURL
            )
        } else {
            let merge = try await documentExecutor.execute(ProcessRequest(
                executable: "qpdf",
                arguments: ["--empty", "--pages"] + outputPaths + ["--", stagingURL.path],
                environment: batch.request.environment,
                workingDirectory: batch.request.workDirectory
            ))
            guard merge.succeeded else {
                throw StreamingScanError.assemblyFailed(merge.standardError)
            }
        }
        let options = try DocumentProcessingOptions(environment: batch.request.environment)
        let metadata = try await documentExecutor.execute(
            SetPDFCreatorRequest(pdfPath: stagingURL.path, creator: options.creator).command.processRequest(
                environment: batch.request.environment,
                workingDirectory: batch.request.workDirectory
            )
        )
        guard metadata.succeeded else {
            throw StreamingScanError.assemblyFailed(metadata.standardError)
        }
        try FoundationNativeScanFileSystem().placeFileExclusively(
            at: stagingURL,
            destination: URL(fileURLWithPath: batch.request.finalOutputPath)
        )
        streamingBatches.removeValue(forKey: batchID)
        try? FileManager.default.removeItem(at: batch.request.workDirectory)
        resumeIdleWaitersIfIdle()
    }

    private func resumeIdleWaitersIfIdle() {
        if queue.isEmpty, activeJobs.isEmpty, streamingBatches.isEmpty {
            resumeIdleWaiters()
        }
    }
}

private enum OCRWorkspaceError: Error, LocalizedError {
    case invalidSuffix

    var errorDescription: String? {
        "Invalid OCR work-directory suffix."
    }
}

public enum StreamingScanError: Error, LocalizedError, Sendable {
    case unknownBatch
    case invalidPageNumber
    case pageCountMismatch(expected: Int, received: Int)
    case pageProcessingFailed([Int])
    case assemblyFailed(String)
    case importPreparationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownBatch: "Streaming scan batch is no longer available."
        case .invalidPageNumber: "Streaming scan received an invalid or duplicate page number."
        case let .pageCountMismatch(expected, received):
            "Streaming scan expected \(expected) pages but received \(received)."
        case .pageProcessingFailed(let pages):
            "Streaming scan page processing failed for page(s): \(pages.map(String.init).joined(separator: ", "))."
        case .assemblyFailed(let diagnostic):
            "Could not assemble the streamed OCR PDF: \(diagnostic)"
        case .importPreparationFailed(let diagnostic):
            "Could not prepare the imported PDF for distributed OCR: \(diagnostic)"
        }
    }
}
