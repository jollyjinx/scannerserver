import Foundation

public actor OCRWorkerJobStore {
    public typealias LeaseTokenProvider = @Sendable () -> String

    private struct StoredLease: Codable, Sendable {
        let workerID: String
        let token: String
        let leasedAt: Date
        var expiresAt: Date
    }

    private struct StoredJob: Codable, Sendable {
        let manifest: OCRWorkerJobManifest
        var status: OCRWorkerJobStatus
        var attemptCount: Int
        var lease: StoredLease?
        var result: OCRWorkerJobResult?
        var failure: String?
        var completedWorkerID: String?
        var startedAt: Date?
        var updatedAt: Date
    }

    private struct StoredJobs: Codable, Sendable {
        let formatVersion: Int
        var jobs: [StoredJob]
    }

    public let fileURL: URL?
    public let leaseDurationSeconds: TimeInterval

    private let leaseTokenProvider: LeaseTokenProvider
    private var jobs: [String: StoredJob]

    public init(
        fileURL: URL? = nil,
        leaseDurationSeconds: TimeInterval = 60,
        leaseTokenProvider: @escaping LeaseTokenProvider = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
    ) {
        self.fileURL = fileURL
        self.leaseDurationSeconds = max(1, leaseDurationSeconds)
        self.leaseTokenProvider = leaseTokenProvider

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let stored = try? decoder.decode(StoredJobs.self, from: data),
           stored.formatVersion == 1 {
            var loaded: [String: StoredJob] = [:]
            for job in stored.jobs {
                loaded[job.manifest.jobID] = job
            }
            jobs = loaded
        } else {
            jobs = [:]
        }
    }

    public static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let path = environment["SCAN_OCR_WORKER_JOBS_PATH"] {
            return URL(fileURLWithPath: path)
        }
        let outputDirectory = environment["SCAN_OUTPUT_DIR"] ?? "/scans"
        return URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent(".scannerserver-ocr-jobs.json")
    }

    @discardableResult
    public func enqueue(_ manifest: OCRWorkerJobManifest) throws -> OCRWorkerJobSnapshot {
        try validate(manifest)
        guard jobs[manifest.jobID] == nil else {
            throw OCRWorkerJobStoreError.duplicateJob(manifest.jobID)
        }
        let job = StoredJob(
            manifest: manifest,
            status: .queued,
            attemptCount: 0,
            lease: nil,
            result: nil,
            failure: nil,
            completedWorkerID: nil,
            startedAt: nil,
            updatedAt: manifest.createdAt
        )
        jobs[manifest.jobID] = job
        try persist()
        return snapshot(job)
    }

    public func leaseNext(
        workerID: String,
        ocrLanguages: [String],
        capabilities: [String] = [],
        maximumActiveLeases: Int? = nil,
        now: Date = Date()
    ) throws -> OCRWorkerJobLease? {
        guard !workerID.isEmpty else { throw OCRWorkerJobStoreError.invalidLease }
        let reclaimed = requeueExpiredLeasesWithoutPersisting(now: now)
        if let maximumActiveLeases,
           activeLeaseCount(workerID: workerID) >= max(1, maximumActiveLeases) {
            if reclaimed > 0 { try persist() }
            return nil
        }
        let supportedLanguages = Set(ocrLanguages)
        let supportedCapabilities = Set(capabilities)
        let candidates = jobs.values.filter { job in
            job.status == .queued
                && job.manifest.ocrLanguages.allSatisfy(supportedLanguages.contains)
                && (!job.manifest.cropPages
                    || supportedCapabilities.contains(OCRWorkerCapability.cropPDFPages))
        }
        guard let jobID = candidates.sorted(by: jobOrder).first?.manifest.jobID else {
            if reclaimed > 0 { try persist() }
            return nil
        }

        var job = jobs[jobID]!
        let token = leaseTokenProvider()
        let lease = StoredLease(
            workerID: workerID,
            token: token,
            leasedAt: now,
            expiresAt: now.addingTimeInterval(leaseDurationSeconds)
        )
        job.status = .leased
        job.attemptCount += 1
        job.lease = lease
        job.failure = nil
        job.completedWorkerID = nil
        job.startedAt = now
        job.updatedAt = now
        jobs[jobID] = job
        try persist()
        return assignment(job: job, lease: lease)
    }

    @discardableResult
    public func renew(
        jobID: String,
        workerID: String,
        leaseToken: String,
        now: Date = Date()
    ) throws -> OCRWorkerJobLease {
        var (job, lease) = try authenticatedLease(
            jobID: jobID,
            workerID: workerID,
            leaseToken: leaseToken,
            now: now
        )
        lease.expiresAt = now.addingTimeInterval(leaseDurationSeconds)
        job.lease = lease
        job.updatedAt = now
        jobs[jobID] = job
        try persist()
        return assignment(job: job, lease: lease)
    }

    @discardableResult
    public func succeed(
        jobID: String,
        workerID: String,
        leaseToken: String,
        result: OCRWorkerJobResult,
        now: Date = Date()
    ) throws -> OCRWorkerJobSnapshot {
        guard result.outputByteCount > 0, Self.isSHA256(result.outputSHA256) else {
            throw OCRWorkerJobStoreError.invalidResult
        }
        var (job, _) = try authenticatedLease(
            jobID: jobID,
            workerID: workerID,
            leaseToken: leaseToken,
            now: now
        )
        job.status = .succeeded
        job.lease = nil
        job.result = result
        job.failure = nil
        job.completedWorkerID = workerID
        job.updatedAt = now
        jobs[jobID] = job
        try persist()
        return snapshot(job)
    }

    @discardableResult
    public func fail(
        jobID: String,
        workerID: String,
        leaseToken: String,
        failure: String,
        now: Date = Date()
    ) throws -> OCRWorkerJobSnapshot {
        var (job, _) = try authenticatedLease(
            jobID: jobID,
            workerID: workerID,
            leaseToken: leaseToken,
            now: now
        )
        job.status = .failed
        job.lease = nil
        job.failure = String(failure.prefix(4_096))
        job.completedWorkerID = workerID
        job.updatedAt = now
        jobs[jobID] = job
        try persist()
        return snapshot(job)
    }

    @discardableResult
    public func cancel(jobID: String, now: Date = Date()) throws -> OCRWorkerJobSnapshot {
        guard var job = jobs[jobID] else {
            throw OCRWorkerJobStoreError.unknownJob(jobID)
        }
        guard job.status == .queued || job.status == .leased else {
            throw OCRWorkerJobStoreError.invalidTransition(from: job.status, to: .cancelled)
        }
        job.status = .cancelled
        job.lease = nil
        job.updatedAt = now
        jobs[jobID] = job
        try persist()
        return snapshot(job)
    }

    @discardableResult
    public func requeueExpiredLeases(now: Date = Date()) throws -> Int {
        let count = requeueExpiredLeasesWithoutPersisting(now: now)
        if count > 0 { try persist() }
        return count
    }

    @discardableResult
    public func requeueLeases(workerID: String, now: Date = Date()) throws -> Int {
        var count = 0
        for jobID in jobs.keys {
            guard var job = jobs[jobID],
                  job.status == .leased,
                  job.lease?.workerID == workerID else {
                continue
            }
            job.status = .queued
            job.lease = nil
            job.failure = nil
            job.updatedAt = now
            jobs[jobID] = job
            count += 1
        }
        if count > 0 { try persist() }
        return count
    }

    public func snapshots() -> [OCRWorkerJobSnapshot] {
        jobs.values.sorted(by: jobOrder).map(snapshot)
    }

    private func activeLeaseCount(workerID: String) -> Int {
        jobs.values.count { job in
            job.status == .leased && job.lease?.workerID == workerID
        }
    }

    public func snapshot(jobID: String) throws -> OCRWorkerJobSnapshot {
        guard let job = jobs[jobID] else {
            throw OCRWorkerJobStoreError.unknownJob(jobID)
        }
        return snapshot(job)
    }

    public func authorizeLease(
        jobID: String,
        workerID: String,
        leaseToken: String,
        now: Date = Date()
    ) throws -> OCRWorkerJobManifest {
        try authenticatedLease(
            jobID: jobID,
            workerID: workerID,
            leaseToken: leaseToken,
            now: now
        ).0.manifest
    }

    private func authenticatedLease(
        jobID: String,
        workerID: String,
        leaseToken: String,
        now: Date
    ) throws -> (StoredJob, StoredLease) {
        guard let job = jobs[jobID] else {
            throw OCRWorkerJobStoreError.unknownJob(jobID)
        }
        guard job.status == .leased, let lease = job.lease else {
            throw OCRWorkerJobStoreError.invalidTransition(from: job.status, to: .leased)
        }
        guard lease.workerID == workerID, lease.token == leaseToken else {
            throw OCRWorkerJobStoreError.invalidLease
        }
        guard now < lease.expiresAt else {
            throw OCRWorkerJobStoreError.leaseExpired
        }
        return (job, lease)
    }

    private func requeueExpiredLeasesWithoutPersisting(now: Date) -> Int {
        var count = 0
        for jobID in jobs.keys {
            guard var job = jobs[jobID],
                  job.status == .leased,
                  let lease = job.lease,
                  now >= lease.expiresAt else {
                continue
            }
            job.status = .queued
            job.lease = nil
            job.updatedAt = now
            jobs[jobID] = job
            count += 1
        }
        return count
    }

    private func validate(_ manifest: OCRWorkerJobManifest) throws {
        let allowedID = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !manifest.jobID.isEmpty,
              manifest.jobID.count <= 128,
              manifest.jobID.unicodeScalars.allSatisfy(allowedID.contains),
              !manifest.sourcePath.isEmpty,
              !manifest.outputPath.isEmpty,
              manifest.sourceByteCount > 0,
              Self.isSHA256(manifest.sourceSHA256),
              !manifest.ocrLanguages.contains(where: { $0.isEmpty }) else {
            throw OCRWorkerJobStoreError.invalidManifest
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }
    }

    private func assignment(job: StoredJob, lease: StoredLease) -> OCRWorkerJobLease {
        OCRWorkerJobLease(
            manifest: job.manifest,
            workerID: lease.workerID,
            leaseToken: lease.token,
            leasedAt: lease.leasedAt,
            expiresAt: lease.expiresAt,
            attempt: job.attemptCount
        )
    }

    private func snapshot(_ job: StoredJob) -> OCRWorkerJobSnapshot {
        OCRWorkerJobSnapshot(
            manifest: job.manifest,
            status: job.status,
            attemptCount: job.attemptCount,
            leasedWorkerID: job.lease?.workerID,
            completedWorkerID: job.completedWorkerID,
            leasedAt: job.lease?.leasedAt ?? job.startedAt,
            leaseExpiresAt: job.lease?.expiresAt,
            result: job.result,
            failure: job.failure,
            updatedAt: job.updatedAt
        )
    }

    private func jobOrder(_ lhs: StoredJob, _ rhs: StoredJob) -> Bool {
        if lhs.manifest.createdAt == rhs.manifest.createdAt {
            return lhs.manifest.jobID < rhs.manifest.jobID
        }
        return lhs.manifest.createdAt < rhs.manifest.createdAt
    }

    private func persist() throws {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = StoredJobs(formatVersion: 1, jobs: jobs.values.sorted(by: jobOrder))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(stored)
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
    }
}
