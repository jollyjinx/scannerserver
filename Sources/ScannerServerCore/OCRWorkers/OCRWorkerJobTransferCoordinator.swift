import Foundation

public struct OCRWorkerJobSource: Equatable, Sendable {
    public let data: Data
    public let sha256: String

    public init(data: Data, sha256: String) {
        self.data = data
        self.sha256 = sha256
    }
}

public enum OCRWorkerTransferError: Error, LocalizedError, Sendable {
    case pathOutsideScanDirectory
    case sourceChanged
    case invalidPDF
    case outputExists

    public var errorDescription: String? {
        switch self {
        case .pathOutsideScanDirectory: "OCR job path is outside the scan directory."
        case .sourceChanged: "OCR source changed after the job was queued."
        case .invalidPDF: "OCR worker result is not a PDF."
        case .outputExists: "OCR output already exists."
        }
    }
}

/// Coordinates authenticated worker leases with their source and result file transfers.
///
/// Mutable registration and lease state remain isolated to `OCRWorkerRegistry` and
/// `OCRWorkerJobStore`. This value is intentionally stateless so unrelated worker transfers can
/// proceed concurrently while every durable transition remains serialized by the job store.
public struct OCRWorkerJobTransferCoordinator: Sendable {
    public typealias NowProvider = @Sendable () -> Date
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    public let maximumResultBytes: Int

    private let registry: OCRWorkerRegistry
    private let jobs: OCRWorkerJobStore
    private let outputDirectory: URL
    private let resultValidator: any OCRWorkerResultValidating
    private let webUpdates: WebUpdateNotifier
    private let now: NowProvider
    private let sleep: Sleeper

    public init(
        registry: OCRWorkerRegistry,
        jobs: OCRWorkerJobStore,
        outputDirectory: URL,
        resultValidator: any OCRWorkerResultValidating,
        webUpdates: WebUpdateNotifier,
        maximumResultBytes: Int = 1_073_741_824,
        now: @escaping NowProvider = { Date() },
        sleep: @escaping Sleeper = { duration in try await Task.sleep(for: duration) }
    ) {
        self.registry = registry
        self.jobs = jobs
        self.outputDirectory = outputDirectory
        self.resultValidator = resultValidator
        self.webUpdates = webUpdates
        self.maximumResultBytes = max(1, maximumResultBytes)
        self.now = now
        self.sleep = sleep
    }

    public static func maximumResultBytes(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        let fallback = 1_073_741_824
        guard let value = environment["SCAN_OCR_WORKER_MAX_RESULT_BYTES"],
              let parsed = Int(value), parsed > 0 else {
            return fallback
        }
        return parsed
    }

    public func leaseNext(
        workerID: String,
        request poll: OCRWorkerJobPollRequest
    ) async throws -> OCRWorkerJobLease? {
        let deadline = now().addingTimeInterval(TimeInterval(min(max(poll.waitSeconds, 0), 30)))
        while true {
            try Task.checkCancellation()
            let worker = try await registry.authorizeJobRequest(
                workerID: workerID,
                authenticationToken: poll.authenticationToken,
                requireCapacity: false
            )
            if let lease = try await jobs.leaseNext(
                workerID: workerID,
                ocrLanguages: worker.ocrLanguages,
                capabilities: worker.capabilities,
                maximumActiveLeases: worker.maxConcurrentJobs
            ) {
                await webUpdates.notify()
                return lease
            }
            guard now() < deadline else { return nil }
            try await sleep(.milliseconds(500))
        }
    }

    public func source(
        workerID: String,
        authenticationToken: String,
        jobID: String,
        leaseToken: String
    ) async throws -> OCRWorkerJobSource {
        _ = try await registry.authorizeJobRequest(
            workerID: workerID,
            authenticationToken: authenticationToken,
            requireCapacity: false
        )
        let manifest = try await jobs.authorizeLease(
            jobID: jobID,
            workerID: workerID,
            leaseToken: leaseToken
        )
        let sourceURL = try jobURL(path: manifest.sourcePath)
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard data.count == manifest.sourceByteCount,
              OCRWorkerSHA256.hexDigest(data) == manifest.sourceSHA256 else {
            throw OCRWorkerTransferError.sourceChanged
        }
        return OCRWorkerJobSource(data: data, sha256: manifest.sourceSHA256)
    }

    public func renew(
        workerID: String,
        jobID: String,
        request: OCRWorkerJobLeaseRequest
    ) async throws -> OCRWorkerJobLease {
        _ = try await registry.authorizeJobRequest(
            workerID: workerID,
            authenticationToken: request.authenticationToken,
            requireCapacity: false
        )
        return try await jobs.renew(
            jobID: jobID,
            workerID: workerID,
            leaseToken: request.leaseToken
        )
    }

    public func reportFailure(
        workerID: String,
        jobID: String,
        request: OCRWorkerJobFailureRequest
    ) async throws -> OCRWorkerJobSnapshot {
        _ = try await registry.authorizeJobRequest(
            workerID: workerID,
            authenticationToken: request.authenticationToken,
            requireCapacity: false
        )
        let snapshot = try await jobs.fail(
            jobID: jobID,
            workerID: workerID,
            leaseToken: request.leaseToken,
            failure: request.failure
        )
        await webUpdates.notify()
        return snapshot
    }

    /// Authenticates a result transfer before the HTTP layer accepts its potentially large body.
    /// `acceptResult` authorizes again after collection so a cancellation or reassignment that
    /// happens during upload cannot publish through a stale lease.
    public func authorizeResult(
        workerID: String,
        authenticationToken: String,
        jobID: String,
        leaseToken: String
    ) async throws {
        _ = try await authorizedManifest(
            workerID: workerID,
            authenticationToken: authenticationToken,
            jobID: jobID,
            leaseToken: leaseToken
        )
    }

    public func acceptResult(
        workerID: String,
        authenticationToken: String,
        jobID: String,
        leaseToken: String,
        data: Data
    ) async throws -> OCRWorkerJobSnapshot {
        let manifest = try await authorizedManifest(
            workerID: workerID,
            authenticationToken: authenticationToken,
            jobID: jobID,
            leaseToken: leaseToken
        )
        guard data.count >= 5, data.prefix(5) == Data("%PDF-".utf8) else {
            throw OCRWorkerTransferError.invalidPDF
        }
        let outputURL = try jobURL(path: manifest.outputPath)
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw OCRWorkerTransferError.outputExists
        }

        let stagingURL = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".ocr-upload.\(jobID).\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        try data.write(to: stagingURL, options: .atomic)
        try await resultValidator.validate(fileURL: stagingURL)
        try FileManager.default.moveItem(at: stagingURL, to: outputURL)
        do {
            let snapshot = try await jobs.succeed(
                jobID: jobID,
                workerID: workerID,
                leaseToken: leaseToken,
                result: OCRWorkerJobResult(
                    outputByteCount: Int64(data.count),
                    outputSHA256: OCRWorkerSHA256.hexDigest(data)
                )
            )
            await webUpdates.notify()
            return snapshot
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private func jobURL(path: String) throws -> URL {
        let directory = outputDirectory.resolvingSymlinksInPath().standardizedFileURL
        let url = URL(fileURLWithPath: path, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard url.pathComponents.count > directory.pathComponents.count,
              Array(url.pathComponents.prefix(directory.pathComponents.count))
                == directory.pathComponents else {
            throw OCRWorkerTransferError.pathOutsideScanDirectory
        }
        return url
    }

    private func authorizedManifest(
        workerID: String,
        authenticationToken: String,
        jobID: String,
        leaseToken: String
    ) async throws -> OCRWorkerJobManifest {
        _ = try await registry.authorizeJobRequest(
            workerID: workerID,
            authenticationToken: authenticationToken,
            requireCapacity: false
        )
        return try await jobs.authorizeLease(
            jobID: jobID,
            workerID: workerID,
            leaseToken: leaseToken
        )
    }
}
