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
    private let local: any ProcessExecutor
    private let workers: OCRWorkerRegistry
    private let jobs: OCRWorkerJobStore
    private let configuration: DistributedOCRConfiguration

    public init(
        local: any ProcessExecutor,
        workers: OCRWorkerRegistry,
        jobs: OCRWorkerJobStore,
        configuration: DistributedOCRConfiguration
    ) {
        self.local = local
        self.workers = workers
        self.jobs = jobs
        self.configuration = configuration
    }

    public func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        guard configuration.enabled,
              request.executable == "ocrmypdf",
              let remoteRequest = try? makeRemoteRequest(request),
              await workers.hasPreferredWorker(ocrLanguages: remoteRequest.languages) else {
            return try await local.execute(request)
        }

        do {
            return try await executeRemotely(remoteRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            JLog.warning("Remote OCR unavailable; falling back locally: \(error.localizedDescription)")
            return try await local.execute(request)
        }
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
            removeBlankPages: false,
            cropPages: false,
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
            metadata: request.ocrWorkerMetadata
        )
    }
}
