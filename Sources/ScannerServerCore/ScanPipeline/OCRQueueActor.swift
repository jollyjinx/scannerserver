import Foundation

public enum OCRJobExecutionLocation: String, Equatable, Sendable {
    case local
    case remote
}

public struct OCRJobTiming: Equatable, Sendable {
    public let input: String
    public let output: String
    public let status: String
    public let duration: TimeInterval
    public let metadata: OCRWorkerJobMetadata?
    public let executionLocation: OCRJobExecutionLocation?

    public init(
        input: String,
        output: String,
        status: String,
        duration: TimeInterval,
        metadata: OCRWorkerJobMetadata? = nil,
        executionLocation: OCRJobExecutionLocation? = nil
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
    public let replaceExistingText: Bool

    public init(
        sourcePath: String,
        documentName: String,
        finalOutputPath: String,
        workDirectory: URL,
        environment: [String: String],
        removeBlankPages: Bool,
        cropPages: Bool,
        replaceExistingText: Bool = false
    ) {
        self.sourcePath = sourcePath
        self.documentName = documentName
        self.finalOutputPath = finalOutputPath
        self.workDirectory = workDirectory
        self.environment = environment
        self.removeBlankPages = removeBlankPages
        self.cropPages = cropPages
        self.replaceExistingText = replaceExistingText
    }
}

public struct OCRQueueWorkerCapacity: Equatable, Sendable {
    public let remoteJobSlots: Int
    public let internalOCREnabled: Bool
    public let internalOCRFallbackOnly: Bool
    public let internalCPULimit: Int?
    public let internalNiceLevel: Int?

    public init(
        remoteJobSlots: Int = 0,
        internalOCREnabled: Bool = true,
        internalOCRFallbackOnly: Bool = false,
        internalCPULimit: Int? = nil,
        internalNiceLevel: Int? = nil
    ) {
        self.remoteJobSlots = max(0, remoteJobSlots)
        self.internalOCREnabled = internalOCREnabled
        self.internalOCRFallbackOnly = internalOCRFallbackOnly
        self.internalCPULimit = internalCPULimit.map { max(1, $0) }
        self.internalNiceLevel = internalNiceLevel.map { min(max(1, $0), 19) }
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
        let replaceExistingText: Bool
        let deferredProcessing: DeferredScanProcessing?
        let workerMetadata: OCRWorkerJobMetadata?
        let streamingPageWork: StreamingOCRPageWork?
        let outputDirectory: String?
    }

    private struct ActiveJob: Sendable {
        let job: Job
        let started: Date
        let reservedCPUs: Int
        var localReservationCPUs: Int
        let executionPreference: OCRDispatchPreference
        let task: Task<Void, Never>
    }

    private struct ScheduleCandidate: Sendable {
        let index: Int
        let reservedCPUs: Int
        let localReservationCPUs: Int
        let executionPreference: OCRDispatchPreference
        let niceLevel: Int?
    }

    private struct JobCompletion: Sendable {
        let finished: Date
        let status: String
        let output: String
        let error: String
        let publishedOutputPath: String
        let followUpJobs: [Job]
        let executionLocation: OCRJobExecutionLocation?
        let rawPageFallbackRequested: Bool
        let cancellableOutputPath: String?

        init(
            finished: Date,
            status: String,
            output: String,
            error: String,
            publishedOutputPath: String,
            followUpJobs: [Job] = [],
            executionLocation: OCRJobExecutionLocation? = nil,
            rawPageFallbackRequested: Bool = false,
            cancellableOutputPath: String? = nil
        ) {
            self.finished = finished
            self.status = status
            self.output = output
            self.error = error
            self.publishedOutputPath = publishedOutputPath
            self.followUpJobs = followUpJobs
            self.executionLocation = executionLocation
            self.rawPageFallbackRequested = rawPageFallbackRequested
            self.cancellableOutputPath = cancellableOutputPath
        }

        func replacing(error: String? = nil, publishedOutputPath: String? = nil) -> JobCompletion {
            JobCompletion(
                finished: finished,
                status: status,
                output: output,
                error: error ?? self.error,
                publishedOutputPath: publishedOutputPath ?? self.publishedOutputPath,
                followUpJobs: followUpJobs,
                executionLocation: executionLocation,
                rawPageFallbackRequested: rawPageFallbackRequested,
                cancellableOutputPath: cancellableOutputPath
            )
        }
    }

    private struct JobExecutionResult: Sendable {
        let exitStatus: Int32
        let standardOutput: String
        let standardError: String
        let executionLocation: OCRJobExecutionLocation?

        var succeeded: Bool { exitStatus == 0 }

        init(_ result: ProcessResult) {
            exitStatus = result.exitStatus
            standardOutput = result.standardOutput
            standardError = result.standardError
            executionLocation = nil
        }

        init(_ result: OCRExecutionResult) {
            exitStatus = result.exitStatus
            standardOutput = result.standardOutput
            standardError = result.standardError
            executionLocation = switch result.location {
            case .local: .local
            case .remote: .remote
            }
        }

        init(exitStatus: Int32, standardOutput: String = "", standardError: String = "") {
            self.exitStatus = exitStatus
            self.standardOutput = standardOutput
            self.standardError = standardError
            executionLocation = nil
        }
    }

    private let ocrExecutor: any OCRExecuting
    private let documentExecutor: any ProcessExecutor
    private let streamingDocuments: StreamingOCRDocumentModule
    private let workspaceSuffixProvider: WorkspaceSuffixProvider
    private let configuration: OCRQueueConfiguration
    private let localCapacity: OCRLocalCapacityPool
    private let workerCapacityProvider: WorkerCapacityProvider
    private var queue: [Job] = []
    private var activeJobs: [UUID: ActiveJob] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var isCancellingAll = false
    private var finishingJobCount = 0
    private var finishingJobBatchCounts: [UUID: Int] = [:]
    private var pendingCleanups: [UUID: URL] = [:]
    private var unconfirmedCleanupBatches: Set<UUID> = []
    private var latestCompletionStatus: String?
    private var queueState: OCRQueueState

    package init(
        ocrExecutor: any OCRExecuting,
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
        self.ocrExecutor = ocrExecutor
        let resolvedDocumentExecutor = documentExecutor
            ?? NativeDocumentToolExecutor(executor: FoundationProcessExecutor())
        self.documentExecutor = resolvedDocumentExecutor
        self.streamingDocuments = StreamingOCRDocumentModule(
            documentExecutor: resolvedDocumentExecutor,
            pageWriter: streamingPageWriter,
            webUpdates: webUpdates
        )
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

    public var state: OCRQueueState {
        get async {
            var state = queueState
            let documentState = await streamingDocuments.state
            state.finalizingJobs = documentState.finalizingJobs
            if state.running == 0, state.queued == 0, !documentState.finalizingJobs.isEmpty {
                state.status = "running"
            }
            let latestQueueEvent = [state.started, state.finished].compactMap { $0 }.max()
            if let completion = documentState.latestCompletion,
               state.running == 0,
               state.queued == 0,
               documentState.finalizingJobs.isEmpty,
               latestQueueEvent.map({ completion.finished >= $0 }) ?? true {
                state.finished = completion.finished
                state.status = completion.status
                state.output = completion.output
                state.error = completion.error
            }
            return state
        }
    }

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
            replaceExistingText: false,
            deferredProcessing: nil,
            workerMetadata: nil,
            streamingPageWork: nil,
            outputDirectory: nil
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
            replaceExistingText: false,
            deferredProcessing: deferredProcessing,
            workerMetadata: nil,
            streamingPageWork: nil,
            outputDirectory: nil
        ))
        await scheduleAvailableJobs()
        await publishQueueState()
    }

    public func beginStreamingScan(_ request: StreamingScanRequest) async -> UUID {
        let rawPDF = request.workDirectory.appendingPathComponent("raw.pdf", isDirectory: false)
        let rawDestination = request.workDirectory.deletingLastPathComponent()
            .appendingPathComponent(request.documentName, isDirectory: false)
        let failurePolicy: StreamingOCRFailurePolicy = isTruthy(
            request.environment["SCAN_OCR_ONLY"]
        )
            ? .publishRawOnFailure(source: rawPDF, destination: rawDestination)
            : .sourceAlreadyPublished
        return await streamingDocuments.begin(StreamingOCRDocumentRequest(
            documentName: request.documentName,
            finalOutputURL: URL(fileURLWithPath: request.finalOutputPath),
            workDirectory: request.workDirectory,
            environment: request.environment,
            removeBlankPages: request.removeBlankPages,
            cropPages: request.cropPages,
            failurePolicy: failurePolicy
        )).rawValue
    }

    public func enqueueImportedPDF(_ imported: ImportedPDFOCRRequest) async throws -> Int {
        try await streamingDocuments.prepareImportedPDF(
            imported,
            yieldPage: { [weak self] work in
                guard let self else { throw CancellationError() }
                await self.enqueueStreamingPageWork(work)
            },
            cancelScheduledPages: { [weak self] documentID in
                await self?.cancelScheduledJobs(batchIDs: [documentID.rawValue])
            }
        )
    }

    public func submitStreamingPage(
        batchID: UUID,
        page: ScanSnapAcquiredPage
    ) async throws {
        let work = try await streamingDocuments.reserveJPEGPage(
            documentID: StreamingOCRDocumentID(rawValue: batchID),
            page: page
        )
        await enqueueStreamingPageWork(work)
    }

    private func enqueueStreamingPageWork(_ work: StreamingOCRPageWork) async {
        queue.append(Job(
            inputPath: work.reservation.inputURL.path,
            batchID: work.reservation.documentID.rawValue,
            environment: work.environment,
            workingDirectory: work.reservation.inputURL.deletingLastPathComponent(),
            ocrEnabled: true,
            removeBlankPages: work.removeBlankPages,
            cropPages: work.cropPages,
            replaceExistingText: work.replaceExistingText,
            deferredProcessing: nil,
            workerMetadata: work.metadata,
            streamingPageWork: work,
            outputDirectory: nil
        ))
        await scheduleAvailableJobs()
        await publishQueueState()
    }

    public func finishStreamingScan(batchID: UUID, pageCount: Int) async throws {
        try await streamingDocuments.seal(
            StreamingOCRDocumentID(rawValue: batchID),
            expectedPageCount: pageCount
        )
        await publishQueueState()
    }

    @discardableResult
    public func cancelStreamingScan(batchID: UUID, publishRawFallback: Bool = false) async -> Bool {
        let documentID = StreamingOCRDocumentID(rawValue: batchID)
        let reason: StreamingOCRTerminationReason = publishRawFallback
            ? .failed("Streaming scan failed before document finalization completed.")
            : .cancelled
        let handle = await streamingDocuments.invalidate(documentID, reason: reason)
        await cancelScheduledJobs(batchIDs: [batchID])
        let removed: Bool
        if let handle {
            removed = await streamingDocuments.finishCancellation(handle).workspaceRemoved
        } else {
            removed = true
        }
        await scheduleAvailableJobs()
        resumeIdleWaitersIfIdle()
        await publishQueueState()
        return removed
    }

    public func waitUntilIdle() async {
        let documentState = await streamingDocuments.state
        guard !queue.isEmpty
                || !activeJobs.isEmpty
                || finishingJobCount > 0
                || !documentState.activeDocumentIDs.isEmpty else { return }
        if !queue.isEmpty || !activeJobs.isEmpty || finishingJobCount > 0 {
            await withCheckedContinuation { continuation in
                idleWaiters.append(continuation)
            }
        }
        await streamingDocuments.waitUntilIdle()
    }

    public func cancelAll() async {
        let documentHandles = await streamingDocuments.invalidateAll(reason: .cancelled)
        let queuedJobs = queue
        queue.removeAll()
        for job in queuedJobs {
            disposeDeferredJob(job, publishFallback: false)
        }
        isCancellingAll = true
        let tasks = activeJobs.values.map(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        for handle in documentHandles {
            _ = await streamingDocuments.finishCancellation(handle)
        }
        isCancellingAll = false
        for batchID in Array(pendingCleanups.keys) {
            sweepPendingCleanupsIfPossible(batchID: batchID)
        }
        await scheduleAvailableJobs()
        await publishQueueState()
    }

    public func cancelJobs(referencing path: String) async {
        let matchingDocumentIDs = await streamingDocuments.documentIDs(referencing: path)
        let matchingBatchIDs = Set(matchingDocumentIDs.map(\.rawValue))
        var documentHandles: [StreamingOCRCancellationHandle] = []
        for documentID in matchingDocumentIDs {
            if let handle = await streamingDocuments.invalidate(documentID, reason: .cancelled) {
                documentHandles.append(handle)
            }
        }
        let removedJobs = queue.filter {
            matchingBatchIDs.contains($0.batchID)
                || jobReferencesPath($0, path: path)
        }
        let queuedCount = queue.count
        queue.removeAll {
            matchingBatchIDs.contains($0.batchID)
                || jobReferencesPath($0, path: path)
        }
        for job in removedJobs {
            disposeDeferredJob(job, publishFallback: false)
        }
        let removedQueuedJob = queue.count != queuedCount
        queueState.queued = queue.count

        let matchingTasks = activeJobs.values
            .filter {
                matchingBatchIDs.contains($0.job.batchID)
                    || jobReferencesPath($0.job, path: path)
            }
            .map(\.task)
        for task in matchingTasks { task.cancel() }
        for task in matchingTasks { await task.value }
        for handle in documentHandles {
            _ = await streamingDocuments.finishCancellation(handle)
        }
        for batchID in Array(pendingCleanups.keys) {
            sweepPendingCleanupsIfPossible(batchID: batchID)
        }

        if removedQueuedJob || !matchingTasks.isEmpty || !documentHandles.isEmpty {
            await scheduleAvailableJobs()
            resumeIdleWaitersIfIdle()
            await publishQueueState()
        }
    }

    private func cancelScheduledJobs(batchIDs: Set<UUID>) async {
        queue.removeAll { batchIDs.contains($0.batchID) }
        let tasks = activeJobs.values
            .filter { batchIDs.contains($0.job.batchID) }
            .map(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        await scheduleAvailableJobs()
        resumeIdleWaitersIfIdle()
        await publishQueueState()
    }

    @discardableResult
    private func scheduleAvailableJobs() async -> Bool {
        guard !isCancellingAll else { return false }
        let workerCapacity = await workerCapacityProvider()
        queueState.cpuLimit = cpuLimit(for: workerCapacity)
        queueState.niceLevel = niceLevel(for: workerCapacity)
        var startedJob = false

        while let candidate = await nextSchedulableJob(workerCapacity: workerCapacity) {
            let job = queue[candidate.index]
            queue.remove(at: candidate.index)
            start(
                job: job,
                reservedCPUs: candidate.reservedCPUs,
                localReservationCPUs: candidate.localReservationCPUs,
                executionPreference: candidate.executionPreference,
                niceLevel: candidate.niceLevel
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
        _ = await scheduleAvailableJobs()
        await publishQueueState()
    }

    private func start(
        job: Job,
        reservedCPUs: Int,
        localReservationCPUs: Int,
        executionPreference: OCRDispatchPreference,
        niceLevel: Int?
    ) {
        let identifier = UUID()
        let started = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            let completion = await self.run(
                identifier: identifier,
                job: job,
                jobs: reservedCPUs,
                executionPreference: executionPreference,
                niceLevel: niceLevel
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
        queueState.niceLevel = niceLevel
    }

    private func run(
        identifier: UUID,
        job: Job,
        jobs: Int,
        executionPreference: OCRDispatchPreference,
        niceLevel: Int?
    ) async -> JobCompletion {
        if let deferredProcessing = job.deferredProcessing {
            return await runDeferredProcessing(
                job: job,
                deferredProcessing: deferredProcessing,
                niceLevel: niceLevel
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
        let outputPath: String
        if let outputDirectory = job.outputDirectory {
            guard let path = OCRInputPath.outputPath(for: job.inputPath, in: outputDirectory) else {
                return JobCompletion(
                    finished: Date(),
                    status: "failed (64)",
                    output: "",
                    error: "Raw PDF must end in .pdf and must not already be an OCR PDF: \(job.inputPath)",
                    publishedOutputPath: ""
                )
            }
            outputPath = path
        } else {
            outputPath = job.ocrEnabled
                ? OCRInputPath.outputPath(for: job.inputPath)!
                : job.inputPath
        }
        guard !job.ocrEnabled || !FileManager.default.fileExists(atPath: outputPath) else {
            return JobCompletion(
                finished: Date(),
                status: "failed (73)",
                output: "",
                error: "OCR output file already exists: \(outputPath)",
                publishedOutputPath: job.outputDirectory == nil ? outputPath : "",
                rawPageFallbackRequested: job.outputDirectory != nil
            )
        }

        do {
            let result = try await execute(
                identifier: identifier,
                job: job,
                outputPath: outputPath,
                jobs: jobs,
                executionPreference: executionPreference,
                niceLevel: niceLevel
            )
            let processOutput = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return JobCompletion(
                finished: Date(),
                status: result.succeeded ? "done" : "failed (\(result.exitStatus))",
                output: result.succeeded && processOutput.isEmpty ? outputPath : processOutput,
                error: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines),
                publishedOutputPath: result.succeeded ? outputPath : "",
                executionLocation: result.executionLocation,
                rawPageFallbackRequested: !result.succeeded && job.outputDirectory != nil,
                cancellableOutputPath: job.outputDirectory == nil ? nil : outputPath
            )
        } catch is CancellationError {
            return JobCompletion(
                finished: Date(),
                status: "cancelled",
                output: "",
                error: "",
                publishedOutputPath: "",
                cancellableOutputPath: job.outputDirectory == nil ? nil : outputPath
            )
        } catch {
            return JobCompletion(
                finished: Date(),
                status: "failed",
                output: "",
                error: error.localizedDescription,
                publishedOutputPath: "",
                rawPageFallbackRequested: job.outputDirectory != nil,
                cancellableOutputPath: job.outputDirectory == nil ? nil : outputPath
            )
        }
    }

    private func finish(identifier: UUID, completion: JobCompletion) async {
        guard let activeJob = activeJobs.removeValue(forKey: identifier) else { return }
        finishingJobCount += 1
        finishingJobBatchCounts[activeJob.job.batchID, default: 0] += 1
        let cancelled = isCancellingAll || Task.isCancelled || completion.status == "cancelled"
        let effectiveCompletion: JobCompletion
        if cancelled {
            removeCancellableOutputIfPresent(completion)
            effectiveCompletion = JobCompletion(
                finished: completion.finished,
                status: "cancelled",
                output: "",
                error: "",
                publishedOutputPath: ""
            )
        } else if completion.rawPageFallbackRequested {
            removeCancellableOutputIfPresent(completion)
            if let fallback = publishRawPageFallback(for: activeJob.job) {
                effectiveCompletion = completion.replacing(publishedOutputPath: fallback)
            } else {
                unconfirmedCleanupBatches.insert(activeJob.job.batchID)
                effectiveCompletion = completion.replacing(
                    error: completion.error + cleanupRetentionNote(activeJob.job.workingDirectory)
                )
            }
        } else {
            effectiveCompletion = completion
        }
        record(
            job: activeJob.job,
            started: activeJob.started,
            completion: effectiveCompletion
        )
        if queueState.finished.map({ effectiveCompletion.finished >= $0 }) ?? true {
            latestCompletionStatus = effectiveCompletion.status
            queueState.finished = effectiveCompletion.finished
            queueState.input = activeJob.job.inputPath
            queueState.output = effectiveCompletion.output
            queueState.error = effectiveCompletion.error
        }
        queue.append(contentsOf: effectiveCompletion.followUpJobs)
        if activeJob.localReservationCPUs > 0 {
            await localCapacity.release(activeJob.localReservationCPUs)
        }
        await scheduleAvailableJobs()
        if let work = activeJob.job.streamingPageWork {
            let outcome: StreamingOCRPageOutcome
            if effectiveCompletion.status == "cancelled" {
                outcome = .cancelled
            } else if effectiveCompletion.status == "done",
                      !effectiveCompletion.publishedOutputPath.isEmpty {
                outcome = .succeeded(outputURL: URL(
                    fileURLWithPath: effectiveCompletion.publishedOutputPath
                ))
            } else {
                outcome = .failed(
                    status: effectiveCompletion.status,
                    diagnostic: effectiveCompletion.error
                )
            }
            await streamingDocuments.completePage(work.reservation, outcome: outcome)
        }
        finishingJobCount -= 1
        let remainingFinishing = (finishingJobBatchCounts[activeJob.job.batchID] ?? 1) - 1
        if remainingFinishing <= 0 {
            finishingJobBatchCounts[activeJob.job.batchID] = nil
        } else {
            finishingJobBatchCounts[activeJob.job.batchID] = remainingFinishing
        }
        sweepPendingCleanupsIfPossible(batchID: activeJob.job.batchID)
        if activeJobs.isEmpty,
           queue.isEmpty,
           finishingJobCount == 0 {
            queueState.status = latestCompletionStatus ?? effectiveCompletion.status
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

    private func cpuReservation(for job: Job, cpuLimit: Int) -> Int {
        if job.deferredProcessing != nil {
            return cpuLimit
        }
        if job.streamingPageWork != nil { return 1 }
        let pageMode = job.environment?["SCAN_PAGE_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return pageMode == "single" ? 1 : cpuLimit
    }

    private func nextSchedulableJob(
        workerCapacity: OCRQueueWorkerCapacity
    ) async -> ScheduleCandidate? {
        let internalCPULimit = cpuLimit(for: workerCapacity)
        let internalNiceLevel = niceLevel(for: workerCapacity)
        for (index, job) in queue.enumerated() {
            let reservedCPUs = cpuReservation(for: job, cpuLimit: internalCPULimit)
            if canUseDistributedCapacity(job) {
                let activeDistributedJobs = activeJobs.values.filter {
                    canUseDistributedCapacity($0.job)
                }
                let activeRemoteJobs = activeDistributedJobs.filter {
                    $0.executionPreference == .remoteFirst
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
                        executionPreference: .remoteFirst,
                        niceLevel: internalNiceLevel
                    )
                }

                let remoteCapacityHasPriority = workerCapacity.internalOCRFallbackOnly
                    && workerCapacity.remoteJobSlots > 0
                let localLimit = workerCapacity.internalOCREnabled && !remoteCapacityHasPriority
                    ? internalCPULimit
                    : 0
                let activeLocalJobs = activeDistributedJobs.filter {
                    $0.executionPreference == .reservedInternal
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
                        executionPreference: .reservedInternal,
                        niceLevel: internalNiceLevel
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
            guard batchUsage + reservedCPUs <= internalCPULimit,
                  let localReservation = await localCapacity.tryAcquire(reservedCPUs) else {
                continue
            }
            return ScheduleCandidate(
                index: index,
                reservedCPUs: reservedCPUs,
                localReservationCPUs: localReservation,
                executionPreference: .remoteFirst,
                niceLevel: internalNiceLevel
            )
        }
        return nil
    }

    private func canUseDistributedCapacity(_ job: Job) -> Bool {
        job.deferredProcessing == nil
            && job.ocrEnabled
            && (
                job.streamingPageWork != nil
                    || (!job.removeBlankPages && !job.cropPages && pageMode(for: job) == "single")
            )
    }

    private func pageMode(for job: Job) -> String? {
        job.environment?["SCAN_PAGE_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func cpuLimit(for workerCapacity: OCRQueueWorkerCapacity) -> Int {
        min(workerCapacity.internalCPULimit ?? configuration.cpuLimit, configuration.cpuLimit)
    }

    private func niceLevel(for workerCapacity: OCRQueueWorkerCapacity) -> Int? {
        if workerCapacity.internalCPULimit == nil,
           workerCapacity.internalNiceLevel == nil {
            return configuration.niceLevel
        }
        return workerCapacity.internalNiceLevel
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

    private func jobReferencesPath(_ job: Job, path: String) -> Bool {
        let candidate = standardizedPath(path)
        if standardizedPath(job.inputPath) == candidate {
            return true
        }
        if let output = OCRInputPath.outputPath(for: job.inputPath),
           standardizedPath(output) == candidate {
            return true
        }
        if let outputDirectory = job.outputDirectory,
           let output = OCRInputPath.outputPath(for: job.inputPath, in: outputDirectory),
           standardizedPath(output) == candidate {
            return true
        }
        return false
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func execute(
        identifier: UUID,
        job: Job,
        outputPath: String,
        jobs: Int,
        executionPreference: OCRDispatchPreference,
        niceLevel: Int?
    ) async throws -> JobExecutionResult {
        if job.streamingPageWork != nil {
            return try await executeStreamingPage(
                job: job,
                outputPath: outputPath,
                jobs: jobs,
                executionPreference: executionPreference,
                niceLevel: niceLevel
            )
        }
        guard job.removeBlankPages || job.cropPages else {
            guard job.ocrEnabled else {
                return JobExecutionResult(exitStatus: 0, standardOutput: job.inputPath + "\n")
            }
            await transferLocalReservationToOCR(identifier: identifier)
            return JobExecutionResult(try await ocrExecutor.execute(ocrRequest(
                job: job,
                inputURL: URL(fileURLWithPath: job.inputPath),
                outputURL: URL(fileURLWithPath: outputPath),
                jobs: jobs,
                executionPreference: executionPreference,
                niceLevel: niceLevel
            )))
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
        let documentExecutor = prioritizedDocumentExecutor(niceLevel: niceLevel)
        if job.removeBlankPages {
            let result = try await documentExecutor.execute(
                options.removeBlankPagesRequest(pdfPath: stagedInput.path).command.processRequest(
                    environment: job.environment,
                    workingDirectory: workspace
                )
            )
            guard result.succeeded else { return JobExecutionResult(result) }
        }
        if job.cropPages {
            let result = try await documentExecutor.execute(
                options.cropPagesRequest(pdfPath: stagedInput.path).command.processRequest(
                    environment: job.environment,
                    workingDirectory: workspace
                )
            )
            guard result.succeeded else { return JobExecutionResult(result) }
        }

        if job.ocrEnabled {
            await transferLocalReservationToOCR(identifier: identifier)
            return JobExecutionResult(try await ocrExecutor.execute(ocrRequest(
                job: job,
                inputURL: stagedInput,
                outputURL: URL(fileURLWithPath: outputPath),
                jobs: jobs,
                executionPreference: executionPreference,
                workingDirectory: workspace,
                niceLevel: niceLevel
            )))
        }

        try Task.checkCancellation()
        try FoundationNativeDocumentFileSystem().replaceFileAtomically(
            at: inputURL,
            with: stagedInput
        )
        return JobExecutionResult(exitStatus: 0, standardOutput: outputPath + "\n")
    }

    private func transferLocalReservationToOCR(identifier: UUID) async {
        guard var activeJob = activeJobs[identifier], activeJob.localReservationCPUs > 0 else {
            return
        }
        let reservation = activeJob.localReservationCPUs
        activeJob.localReservationCPUs = 0
        activeJobs[identifier] = activeJob
        await localCapacity.release(reservation)
    }

    private func executeStreamingPage(
        job: Job,
        outputPath: String,
        jobs: Int,
        executionPreference: OCRDispatchPreference,
        niceLevel: Int?
    ) async throws -> JobExecutionResult {
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
        return JobExecutionResult(try await ocrExecutor.execute(ocrRequest(
            job: job,
            inputURL: URL(fileURLWithPath: job.inputPath),
            outputURL: URL(fileURLWithPath: outputPath),
            jobs: jobs,
            executionPreference: executionPreference,
            niceLevel: niceLevel,
            cropConfiguration: cropConfiguration,
            blankPageConfiguration: blankPageConfiguration
        )))
    }

    private func ocrRequest(
        job: Job,
        inputURL: URL,
        outputURL: URL,
        jobs: Int,
        executionPreference: OCRDispatchPreference,
        workingDirectory: URL? = nil,
        niceLevel: Int? = nil,
        cropConfiguration: OCRWorkerCropConfiguration? = nil,
        blankPageConfiguration: OCRWorkerBlankPageConfiguration? = nil
    ) -> OCRExecutionRequest {
        OCRExecutionRequest(
            inputURL: inputURL,
            outputURL: outputURL,
            options: OCRProcessingOptions(
                environment: job.environment,
                jobs: jobs,
                forceOCR: job.replaceExistingText
            ),
            context: OCRProcessContext(
                environment: job.environment,
                workingDirectory: workingDirectory ?? job.workingDirectory,
                niceLevel: niceLevel
            ),
            metadata: workerMetadata(for: job),
            cropConfiguration: cropConfiguration,
            blankPageConfiguration: blankPageConfiguration,
            dispatchPreference: executionPreference
        )
    }

    private func runDeferredProcessing(
        job: Job,
        deferredProcessing: DeferredScanProcessing,
        niceLevel: Int?
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
        if deferredProcessing.ocrOnly {
            pendingCleanups[job.batchID] = deferredProcessing.cleanupDirectory
        }
        defer {
            if !deferredProcessing.ocrOnly {
                deferredProcessing.removeCleanupDirectoryIfValid()
            }
        }

        do {
            let result = try await DocumentProcessingOrchestrator(
                executor: prioritizedDocumentExecutor(niceLevel: niceLevel)
            )
                .process(deferredProcessing.plan)
            guard result.outputPaths.allSatisfy(regularFileExists) else {
                let retained = !disposeDeferredProcessing(
                    batchID: job.batchID, deferredProcessing, publishFallback: true
                )
                return JobCompletion(
                    finished: Date(),
                    status: "failed (2)",
                    output: "",
                    error: "No output files were created."
                        + cleanupRetentionNote(retained ? deferredProcessing.cleanupDirectory : nil),
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
                        workingDirectory: deferredProcessing.ocrOnly
                            ? deferredProcessing.plan.workingDirectory
                            : nil,
                        ocrEnabled: true,
                        removeBlankPages: false,
                        cropPages: false,
                        replaceExistingText: false,
                        deferredProcessing: nil,
                        workerMetadata: nil,
                        streamingPageWork: nil,
                        outputDirectory: deferredProcessing.ocrOnly
                            ? deferredProcessing.cleanupDirectory.deletingLastPathComponent().path
                            : nil
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
            disposeDeferredProcessing(batchID: job.batchID, deferredProcessing, publishFallback: false)
            return JobCompletion(
                finished: Date(),
                status: "cancelled",
                output: "",
                error: "",
                publishedOutputPath: ""
            )
        } catch let error as DocumentProcessingError {
            let retained = !disposeDeferredProcessing(
                batchID: job.batchID, deferredProcessing, publishFallback: true
            )
            return JobCompletion(
                finished: Date(),
                status: "failed (\(error.compatibleExitStatus))",
                output: "",
                error: (error.processResult.standardError.isEmpty
                    ? error.localizedDescription
                    : error.processResult.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
                    + cleanupRetentionNote(retained ? deferredProcessing.cleanupDirectory : nil),
                publishedOutputPath: ""
            )
        } catch {
            let retained = !disposeDeferredProcessing(
                batchID: job.batchID, deferredProcessing, publishFallback: true
            )
            return JobCompletion(
                finished: Date(),
                status: "failed",
                output: "",
                error: error.localizedDescription
                    + cleanupRetentionNote(retained ? deferredProcessing.cleanupDirectory : nil),
                publishedOutputPath: ""
            )
        }
    }

    private func prioritizedDocumentExecutor(niceLevel: Int?) -> any ProcessExecutor {
        guard let niceLevel else {
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

    private func resumeIdleWaitersIfIdle() {
        if queue.isEmpty,
           activeJobs.isEmpty,
           finishingJobCount == 0 {
            for batchID in Array(pendingCleanups.keys) {
                sweepPendingCleanupsIfPossible(batchID: batchID)
            }
            resumeIdleWaiters()
        }
    }

    private func disposeDeferredJob(_ job: Job, publishFallback: Bool) {
        guard let deferredProcessing = job.deferredProcessing else { return }
        if deferredProcessing.ocrOnly {
            if publishFallback { deferredProcessing.publishRawPDFFallback() }
            pendingCleanups[job.batchID] = nil
        }
        deferredProcessing.removeCleanupDirectoryIfValid()
    }

    @discardableResult
    private func disposeDeferredProcessing(
        batchID: UUID,
        _ deferredProcessing: DeferredScanProcessing,
        publishFallback: Bool
    ) -> Bool {
        guard deferredProcessing.ocrOnly else { return true }
        let published = !publishFallback || deferredProcessing.publishRawPDFFallback()
        pendingCleanups[batchID] = nil
        guard published else {
            unconfirmedCleanupBatches.insert(batchID)
            return false
        }
        deferredProcessing.removeCleanupDirectoryIfValid()
        return true
    }

    private func publishRawPageFallback(for job: Job) -> String? {
        guard let outputDirectory = job.outputDirectory else { return nil }
        let inputURL = URL(fileURLWithPath: job.inputPath)
        let destination = URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent(inputURL.lastPathComponent)
        do {
            try FoundationNativeScanFileSystem().placeFileExclusively(
                at: inputURL,
                destination: destination
            )
            return destination.path
        } catch {
            return nil
        }
    }

    private func removeCancellableOutputIfPresent(_ completion: JobCompletion) {
        guard let path = completion.cancellableOutputPath else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func sweepPendingCleanupsIfPossible(batchID: UUID) {
        guard let cleanup = pendingCleanups[batchID],
              !queue.contains(where: { $0.batchID == batchID }),
              !activeJobs.values.contains(where: { $0.job.batchID == batchID }),
              (finishingJobBatchCounts[batchID] ?? 0) == 0
        else { return }
        pendingCleanups[batchID] = nil
        guard !unconfirmedCleanupBatches.contains(batchID) else {
            unconfirmedCleanupBatches.remove(batchID)
            return
        }
        try? FileManager.default.removeItem(at: cleanup)
    }

    private func cleanupRetentionNote(_ cleanupDirectory: URL?) -> String {
        guard let cleanupDirectory else { return "" }
        return "\nThe scan was retained in \(cleanupDirectory.path) because publishing the raw fallback failed."
    }

    private func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
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
