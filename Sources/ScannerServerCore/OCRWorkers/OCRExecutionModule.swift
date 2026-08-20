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
    case assignmentTimedOut
    case completionTimedOut
    case remoteFailed(String)
    case resultMissing

    public var errorDescription: String? {
        switch self {
        case .assignmentTimedOut: "No OCR worker claimed the job before the assignment timeout."
        case .completionTimedOut: "The remote OCR job exceeded its completion timeout."
        case .remoteFailed(let message): "Remote OCR failed: \(message)"
        case .resultMissing: "The remote worker reported success without publishing its output."
        }
    }
}

package struct OCRExecutionModule: OCRExecuting, Sendable {
    package typealias NowProvider = @Sendable () -> Date
    package typealias Sleeper = @Sendable (Duration) async throws -> Void

    private enum LocalExecutionOutcome: Sendable {
        case completed(OCRExecutionResult)
        case paused
        case atCapacity
    }

    private let local: any OCRExecuting
    private let workers: OCRWorkerRegistry
    private let jobs: OCRWorkerJobStore
    private let internalWorker: InternalOCRWorkerControl
    private let localCapacity: OCRLocalCapacityPool
    private let configuration: DistributedOCRConfiguration
    private let fileSystem: any NativeScanFileSystem
    private let now: NowProvider
    private let sleep: Sleeper

    package init(
        local: any OCRExecuting,
        workers: OCRWorkerRegistry,
        jobs: OCRWorkerJobStore,
        internalWorker: InternalOCRWorkerControl = InternalOCRWorkerControl(),
        localCapacity: OCRLocalCapacityPool? = nil,
        configuration: DistributedOCRConfiguration = DistributedOCRConfiguration(),
        fileSystem: any NativeScanFileSystem = FoundationNativeScanFileSystem(),
        now: @escaping NowProvider = Date.init,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
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
        self.fileSystem = fileSystem
        self.now = now
        self.sleep = sleep
    }

    package func execute(_ request: OCRExecutionRequest) async throws -> OCRExecutionResult {
        var reservedInternal = request.dispatchPreference == .reservedInternal
        var remoteFallbackRequired = false

        while !Task.isCancelled {
            let observedRevision = await internalWorker.webUpdates.currentRevision
            if !reservedInternal,
               !remoteFallbackRequired,
               configuration.enabled,
               await workers.hasPreferredWorker(
                   ocrLanguages: request.options.languages,
                   requiredCapabilities: request.requiredWorkerCapabilities
               ) {
                do {
                    return try await executeRemotely(request)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    JLog.warning("Remote OCR unavailable: \(error.localizedDescription)")
                    remoteFallbackRequired = true
                }
            }

            if await internalWorker.isPaused {
                reservedInternal = false
                remoteFallbackRequired = false
                JLog.notice("Internal OCR worker is paused; waiting for remote capacity or resume")
                try await internalWorker.waitForDispatchChange(after: observedRevision)
                continue
            }

            switch try await executeLocallyUnlessPaused(request) {
            case .completed(let result):
                return result
            case .paused:
                try? fileSystem.removeItemIfPresent(at: request.outputURL)
                reservedInternal = false
                remoteFallbackRequired = false
            case .atCapacity:
                _ = await internalWorker.webUpdates.wait(after: observedRevision)
                try Task.checkCancellation()
            }
        }
        throw CancellationError()
    }

    private func executeLocallyUnlessPaused(
        _ request: OCRExecutionRequest
    ) async throws -> LocalExecutionOutcome {
        guard !(await internalWorker.isPaused) else { return .paused }
        guard let reservedCPUs = await localCapacity.tryAcquire(request.options.jobs) else {
            return .atCapacity
        }

        do {
            let outcome = try await withThrowingTaskGroup(of: LocalExecutionOutcome.self) { group in
                group.addTask { .completed(try await local.execute(request)) }
                group.addTask {
                    try await internalWorker.waitUntilPaused()
                    return .paused
                }
                guard let outcome = try await group.next() else { throw CancellationError() }
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

    private func executeRemotely(_ request: OCRExecutionRequest) async throws -> OCRExecutionResult {
        let source = try Data(contentsOf: request.inputURL, options: .mappedIfSafe)
        let manifest = OCRWorkerJobManifest(
            sourcePath: request.inputURL.path,
            outputPath: request.outputURL.path,
            sourceByteCount: Int64(source.count),
            sourceSHA256: OCRWorkerSHA256.hexDigest(source),
            ocrLanguages: request.options.languages,
            ocrEnabled: true,
            removeBlankPages: request.blankPageConfiguration != nil,
            blankPageConfiguration: request.blankPageConfiguration,
            cropPages: request.cropConfiguration != nil,
            cropConfiguration: request.cropConfiguration,
            containerArguments: OCRmyPDFCommandBuilder.arguments(
                options: request.options,
                inputPath: "/work/source.pdf",
                outputPath: "/work/result.pdf"
            ),
            metadata: request.metadata,
            createdAt: now()
        )
        _ = try await jobs.enqueue(manifest)
        JLog.notice("Queued remote OCR job \(manifest.jobID)")

        do {
            let assignmentDeadline = now().addingTimeInterval(configuration.assignmentWaitSeconds)
            let completionDeadline = now().addingTimeInterval(configuration.completionTimeoutSeconds)
            var queuedDeadline = assignmentDeadline
            while !Task.isCancelled {
                _ = try await jobs.requeueExpiredLeases(now: now())
                let snapshot = try await jobs.snapshot(jobID: manifest.jobID)
                switch snapshot.status {
                case .queued:
                    if now() >= queuedDeadline {
                        _ = try await jobs.cancel(jobID: manifest.jobID, now: now())
                        throw OCRRemoteDispatchError.assignmentTimedOut
                    }
                case .leased:
                    queuedDeadline = now().addingTimeInterval(configuration.assignmentWaitSeconds)
                case .succeeded:
                    guard fileSystem.regularFileExists(at: request.outputURL) else {
                        throw OCRRemoteDispatchError.resultMissing
                    }
                    return OCRExecutionResult(
                        outcome: .succeeded,
                        standardOutput: request.outputURL.path + "\n",
                        location: .remote
                    )
                case .failed:
                    throw OCRRemoteDispatchError.remoteFailed(
                        snapshot.failure ?? "unknown worker failure"
                    )
                case .cancelled:
                    throw CancellationError()
                }
                if now() >= completionDeadline {
                    if snapshot.status == .queued || snapshot.status == .leased {
                        _ = try? await jobs.cancel(jobID: manifest.jobID, now: now())
                    }
                    throw OCRRemoteDispatchError.completionTimedOut
                }
                try await sleep(.milliseconds(250))
            }
            throw CancellationError()
        } catch is CancellationError {
            _ = try? await jobs.cancel(jobID: manifest.jobID, now: now())
            throw CancellationError()
        }
    }
}
