import Foundation
import JLog

public struct DistributedOCRConfiguration: Equatable, Sendable {
    public let enabled: Bool
    public let assignmentWaitSeconds: TimeInterval
    public let completionTimeoutSeconds: TimeInterval

    public init(
        enabled: Bool = true,
        assignmentWaitSeconds: TimeInterval = 30,
        completionTimeoutSeconds: TimeInterval = 3_600
    ) {
        self.enabled = enabled
        self.assignmentWaitSeconds = max(0, assignmentWaitSeconds)
        self.completionTimeoutSeconds = max(1, completionTimeoutSeconds)
    }

    public init(environment: [String: String]) {
        self.init(
            enabled: Self.bool(environment["SCAN_OCR_REMOTE_ENABLED"], default: true),
            assignmentWaitSeconds: Self.seconds(
                environment["SCAN_OCR_REMOTE_ASSIGNMENT_WAIT_SECONDS"],
                default: 30
            ),
            completionTimeoutSeconds: Self.seconds(
                environment["SCAN_OCR_REMOTE_COMPLETION_TIMEOUT_SECONDS"],
                default: 3_600
            )
        )
    }

    private static func bool(_ value: String?, default fallback: Bool) -> Bool {
        guard let value else { return fallback }
        return switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": true
        case "0", "false", "no", "off": false
        default: fallback
        }
    }

    private static func seconds(_ value: String?, default fallback: TimeInterval) -> TimeInterval {
        guard let value, let parsed = TimeInterval(value), parsed >= 0 else { return fallback }
        return parsed
    }
}

public enum OCRRemoteDispatchError: Error, LocalizedError, Sendable {
    case invalidOCRRequest
    case assignmentTimedOut
    case completionTimedOut
    case remoteFailed(String)
    case resultMissing

    public var errorDescription: String? {
        switch self {
        case .invalidOCRRequest: "Could not convert the OCR command into a remote job."
        case .assignmentTimedOut: "No OCR worker claimed the job before the assignment timeout."
        case .completionTimedOut: "The remote OCR job exceeded its completion timeout."
        case .remoteFailed(let message): "Remote OCR failed: \(message)"
        case .resultMissing: "The remote worker reported success without publishing its output."
        }
    }
}

public struct DistributedOCRProcessExecutor: ProcessExecutor {
    private enum LocalExecutionOutcome: Sendable {
        case completed(ProcessResult)
        case paused
        case atCapacity
    }

    private let local: any ProcessExecutor
    private let workers: OCRWorkerRegistry
    private let jobs: OCRWorkerJobStore
    private let internalWorker: InternalOCRWorkerControl
    private let localCapacity: OCRLocalCapacityPool
    private let configuration: DistributedOCRConfiguration

    public init(
        local: any ProcessExecutor,
        workers: OCRWorkerRegistry,
        jobs: OCRWorkerJobStore,
        internalWorker: InternalOCRWorkerControl = InternalOCRWorkerControl(),
        localCapacity: OCRLocalCapacityPool? = nil,
        configuration: DistributedOCRConfiguration
    ) {
        self.local = local
        self.workers = workers
        self.jobs = jobs
        self.internalWorker = internalWorker
        self.localCapacity = localCapacity ?? OCRLocalCapacityPool(
            capacity: OCRQueueConfiguration().cpuLimit,
            webUpdates: internalWorker.webUpdates
        )
        self.configuration = configuration
    }

    public func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        guard request.executable == "ocrmypdf",
              let remoteRequest = try? makeRemoteRequest(request) else {
            return try await local.execute(request)
        }

        var localOnly = request.ocrExecutionPreference == .localOnly
        var remoteFallbackRequired = false
        while !Task.isCancelled {
            let observedRevision = await internalWorker.webUpdates.currentRevision
            if !localOnly,
               !remoteFallbackRequired,
               configuration.enabled,
               await workers.hasPreferredWorker(
                   ocrLanguages: remoteRequest.languages,
                   requiredCapabilities: remoteRequest.requiredCapabilities
               ) {
                do {
                    return try await executeRemotely(remoteRequest)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    JLog.warning("Remote OCR unavailable: \(error.localizedDescription)")
                    remoteFallbackRequired = true
                    if await internalWorker.isPaused {
                        remoteFallbackRequired = false
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                }
            }

            if await internalWorker.isPaused {
                localOnly = false
                remoteFallbackRequired = false
                JLog.notice("Internal OCR worker is paused; waiting for remote capacity or resume")
                try await internalWorker.waitForDispatchChange(after: observedRevision)
                continue
            }

            switch try await executeLocallyUnlessPaused(request) {
            case .completed(let result):
                return result
            case .paused:
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: remoteRequest.outputPath, isDirectory: false)
                )
                // Recheck remote eligibility before waiting so a worker that
                // appeared while local cancellation completed cannot be missed.
                localOnly = false
                remoteFallbackRequired = false
                continue
            case .atCapacity:
                _ = await internalWorker.webUpdates.wait(after: observedRevision)
                try Task.checkCancellation()
                continue
            }
        }
        throw CancellationError()
    }

    private func executeLocallyUnlessPaused(
        _ request: ProcessRequest
    ) async throws -> LocalExecutionOutcome {
        guard !(await internalWorker.isPaused) else { return .paused }

        guard let reservedCPUs = await localCapacity.tryAcquire(
            localCPUReservation(for: request)
        ) else {
            return .atCapacity
        }

        do {
            let outcome = try await withThrowingTaskGroup(of: LocalExecutionOutcome.self) { group in
                group.addTask {
                    .completed(try await local.execute(request))
                }
                group.addTask {
                    try await internalWorker.waitUntilPaused()
                    return .paused
                }
                guard let outcome = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return outcome
            }
            await localCapacity.release(reservedCPUs)
            return outcome
        } catch {
            await localCapacity.release(reservedCPUs)
            throw error
        }
    }

    private func localCPUReservation(for request: ProcessRequest) -> Int {
        guard let jobsIndex = request.arguments.firstIndex(of: "--jobs"),
              request.arguments.indices.contains(jobsIndex + 1),
              let jobs = Int(request.arguments[jobsIndex + 1]),
              jobs > 0 else {
            return 1
        }
        return jobs
    }

    private func executeRemotely(_ request: RemoteRequest) async throws -> ProcessResult {
        let sourceURL = URL(fileURLWithPath: request.inputPath, isDirectory: false)
        let source = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let manifest = OCRWorkerJobManifest(
            sourcePath: request.inputPath,
            outputPath: request.outputPath,
            sourceByteCount: Int64(source.count),
            sourceSHA256: OCRWorkerSHA256.hexDigest(source),
            ocrLanguages: request.languages,
            ocrEnabled: true,
            removeBlankPages: request.blankPageConfiguration != nil,
            blankPageConfiguration: request.blankPageConfiguration,
            cropPages: request.cropConfiguration != nil,
            cropConfiguration: request.cropConfiguration,
            containerArguments: request.containerArguments,
            metadata: request.metadata
        )
        _ = try await jobs.enqueue(manifest)
        JLog.notice("Queued remote OCR job \(manifest.jobID)")

        do {
            let assignmentDeadline = Date().addingTimeInterval(configuration.assignmentWaitSeconds)
            let completionDeadline = Date().addingTimeInterval(configuration.completionTimeoutSeconds)
            var queuedDeadline = assignmentDeadline
            while !Task.isCancelled {
                _ = try await jobs.requeueExpiredLeases()
                let snapshot = try await jobs.snapshot(jobID: manifest.jobID)
                switch snapshot.status {
                case .queued:
                    if Date() >= queuedDeadline {
                        _ = try await jobs.cancel(jobID: manifest.jobID)
                        throw OCRRemoteDispatchError.assignmentTimedOut
                    }
                case .leased:
                    queuedDeadline = Date().addingTimeInterval(configuration.assignmentWaitSeconds)
                case .succeeded:
                    guard FileManager.default.fileExists(atPath: request.outputPath) else {
                        throw OCRRemoteDispatchError.resultMissing
                    }
                    return ProcessResult(
                        exitStatus: 0,
                        standardOutput: request.outputPath + "\n",
                        executionLocation: .remote
                    )
                case .failed:
                    throw OCRRemoteDispatchError.remoteFailed(snapshot.failure ?? "unknown worker failure")
                case .cancelled:
                    throw CancellationError()
                }
                if Date() >= completionDeadline {
                    if snapshot.status == .queued || snapshot.status == .leased {
                        _ = try? await jobs.cancel(jobID: manifest.jobID)
                    }
                    throw OCRRemoteDispatchError.completionTimedOut
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw CancellationError()
        } catch is CancellationError {
            _ = try? await jobs.cancel(jobID: manifest.jobID)
            throw CancellationError()
        }
    }

    private struct RemoteRequest: Sendable {
        let inputPath: String
        let outputPath: String
        let languages: [String]
        let containerArguments: [String]
        let metadata: OCRWorkerJobMetadata?
        let cropConfiguration: OCRWorkerCropConfiguration?
        let blankPageConfiguration: OCRWorkerBlankPageConfiguration?

        var requiredCapabilities: [String] {
            var capabilities: [String] = []
            if cropConfiguration != nil { capabilities.append(OCRWorkerCapability.cropPDFPages) }
            if blankPageConfiguration != nil {
                capabilities.append(OCRWorkerCapability.removeBlankPDFPages)
            }
            return capabilities
        }
    }

    private func makeRemoteRequest(_ request: ProcessRequest) throws -> RemoteRequest {
        guard request.arguments.count >= 2 else { throw OCRRemoteDispatchError.invalidOCRRequest }
        let inputPath = request.arguments[request.arguments.count - 2]
        let outputPath = request.arguments[request.arguments.count - 1]
        guard inputPath.hasSuffix(".pdf"), outputPath.hasSuffix(".pdf") else {
            throw OCRRemoteDispatchError.invalidOCRRequest
        }
        var arguments = Array(request.arguments.dropLast(2))
        arguments += ["/work/source.pdf", "/work/result.pdf"]
        let languages: [String]
        if let index = arguments.firstIndex(of: "--language"), arguments.indices.contains(index + 1) {
            languages = arguments[index + 1].split(separator: "+").map(String.init)
        } else {
            languages = ["eng"]
        }
        return RemoteRequest(
            inputPath: inputPath,
            outputPath: outputPath,
            languages: languages,
            containerArguments: arguments,
            metadata: request.ocrWorkerMetadata,
            cropConfiguration: request.ocrWorkerCropConfiguration,
            blankPageConfiguration: request.ocrWorkerBlankPageConfiguration
        )
    }
}
