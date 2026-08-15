import Foundation
import ScannerServerCore
import Testing

@Suite("Distributed OCR process executor")
struct DistributedOCRProcessExecutorTests {
    @Test("Eligible workers receive OCRmyPDF jobs and publish the original output path")
    func remoteExecution() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputURL = root.appendingPathComponent("scan.pdf")
        let outputURL = root.appendingPathComponent("scan.ocr.pdf")
        try Data("%PDF-1.4\ninput\n".utf8).write(to: inputURL)

        let registry = OCRWorkerRegistry()
        let registration = distributedTestRegistration()
        _ = try await registry.register(registration)
        _ = try await registry.approve(workerID: registration.workerID)
        let jobs = OCRWorkerJobStore(leaseTokenProvider: { "lease-token" })
        let local = DistributedTestExecutor()
        let executor = DistributedOCRProcessExecutor(
            local: local,
            workers: registry,
            jobs: jobs,
            configuration: DistributedOCRConfiguration(
                assignmentWaitSeconds: 2,
                completionTimeoutSeconds: 5
            )
        )
        let request = ScanPipelineCommands.ocr(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            environment: ["SCAN_LANGUAGE": "deu+eng"],
            jobs: 8
        )

        async let execution = executor.execute(request)
        let lease = try await requireLease(jobs: jobs, registration: registration)
        #expect(lease.manifest.containerArguments?.suffix(2) == [
            "/work/source.pdf", "/work/result.pdf",
        ])
        let output = Data("%PDF-1.4\nremote searchable output\n".utf8)
        try output.write(to: outputURL)
        _ = try await jobs.succeed(
            jobID: lease.manifest.jobID,
            workerID: registration.workerID,
            leaseToken: lease.leaseToken,
            result: OCRWorkerJobResult(
                outputByteCount: Int64(output.count),
                outputSHA256: OCRWorkerSHA256.hexDigest(output)
            )
        )

        let result = try await execution
        #expect(result.succeeded)
        #expect(result.executionLocation == .remote)
        #expect(result.standardOutput == outputURL.path + "\n")
        #expect(await local.requests.isEmpty)
    }

    @Test("Remote autocrop configuration is included in a capable worker lease")
    func remoteCropExecution() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputURL = root.appendingPathComponent("page.pdf")
        let outputURL = root.appendingPathComponent("page.ocr.pdf")
        try Data("%PDF-1.4\ninput\n".utf8).write(to: inputURL)

        let registry = OCRWorkerRegistry()
        let registration = distributedTestRegistration()
        _ = try await registry.register(registration)
        _ = try await registry.approve(workerID: registration.workerID)
        let jobs = OCRWorkerJobStore(leaseTokenProvider: { "lease-token" })
        let local = DistributedTestExecutor()
        let executor = DistributedOCRProcessExecutor(
            local: local,
            workers: registry,
            jobs: jobs,
            configuration: DistributedOCRConfiguration(
                assignmentWaitSeconds: 2,
                completionTimeoutSeconds: 5
            )
        )
        let crop = OCRWorkerCropConfiguration(marginPoints: 2.5)
        let request = ScanPipelineCommands.ocr(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            environment: ["SCAN_LANGUAGE": "deu+eng"],
            workerCropConfiguration: crop
        )

        async let execution = executor.execute(request)
        let lease = try await requireLease(jobs: jobs, registration: registration)
        #expect(lease.manifest.cropPages)
        #expect(lease.manifest.cropConfiguration == crop)
        let output = Data("%PDF-1.4\nremote cropped searchable output\n".utf8)
        try output.write(to: outputURL)
        _ = try await jobs.succeed(
            jobID: lease.manifest.jobID,
            workerID: registration.workerID,
            leaseToken: lease.leaseToken,
            result: OCRWorkerJobResult(
                outputByteCount: Int64(output.count),
                outputSHA256: OCRWorkerSHA256.hexDigest(output)
            )
        )

        #expect(try await execution.executionLocation == .remote)
        #expect(await local.requests.isEmpty)
    }

    @Test("No eligible worker preserves the local OCR executor")
    func localFallback() async throws {
        let localResult = ProcessResult(exitStatus: 0, standardOutput: "local\n")
        let local = DistributedTestExecutor(result: localResult)
        let executor = DistributedOCRProcessExecutor(
            local: local,
            workers: OCRWorkerRegistry(),
            jobs: OCRWorkerJobStore(),
            configuration: DistributedOCRConfiguration()
        )
        let request = ScanPipelineCommands.ocr(
            inputPath: "/scans/input.pdf",
            outputPath: "/scans/input.ocr.pdf"
        )

        let result = try await executor.execute(request)
        #expect(result == localResult)
        #expect(result.executionLocation == .local)
        #expect(await local.requests == [request])
    }

    @Test("Scheduler-assigned internal slots run locally while remote workers are online")
    func schedulerAssignedLocalExecution() async throws {
        let registry = OCRWorkerRegistry()
        let registration = distributedTestRegistration()
        _ = try await registry.register(registration)
        _ = try await registry.approve(workerID: registration.workerID)
        let jobs = OCRWorkerJobStore()
        let localResult = ProcessResult(exitStatus: 0, standardOutput: "local\n")
        let local = DistributedTestExecutor(result: localResult)
        let executor = DistributedOCRProcessExecutor(
            local: local,
            workers: registry,
            jobs: jobs,
            configuration: DistributedOCRConfiguration()
        )
        let request = ScanPipelineCommands.ocr(
            inputPath: "/scans/input.pdf",
            outputPath: "/scans/input.ocr.pdf",
            executionPreference: .localOnly
        )

        let result = try await executor.execute(request)

        #expect(result == localResult)
        #expect(await local.requests == [request])
        #expect(await jobs.snapshots().isEmpty)
    }

    @Test("Concurrent local fallback cannot exceed the scanner host CPU pool")
    func boundedLocalFallback() async throws {
        let webUpdates = WebUpdateNotifier()
        let internalWorker = InternalOCRWorkerControl(webUpdates: webUpdates)
        let local = CancellableDistributedTestExecutor()
        let executor = DistributedOCRProcessExecutor(
            local: local,
            workers: OCRWorkerRegistry(webUpdates: webUpdates),
            jobs: OCRWorkerJobStore(),
            internalWorker: internalWorker,
            localCapacity: OCRLocalCapacityPool(capacity: 1, webUpdates: webUpdates),
            configuration: DistributedOCRConfiguration()
        )
        let firstRequest = ScanPipelineCommands.ocr(
            inputPath: "/scans/first.pdf",
            outputPath: "/scans/first.ocr.pdf",
            jobs: 1
        )
        let secondRequest = ScanPipelineCommands.ocr(
            inputPath: "/scans/second.pdf",
            outputPath: "/scans/second.ocr.pdf",
            jobs: 1
        )

        let first = Task { try await executor.execute(firstRequest) }
        for _ in 0..<100 {
            if await local.requestCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let second = Task { try await executor.execute(secondRequest) }
        try await Task.sleep(for: .milliseconds(100))

        #expect(await local.requestCount == 1)

        first.cancel()
        second.cancel()
        _ = await first.result
        _ = await second.result
    }

    @Test("Pausing active internal OCR cancels local fallback and lets a remote worker take over")
    func pausedInternalWorkerAllowsRemoteTakeover() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputURL = root.appendingPathComponent("scan.pdf")
        let outputURL = root.appendingPathComponent("scan.ocr.pdf")
        try Data("%PDF-1.4\ninput\n".utf8).write(to: inputURL)

        let webUpdates = WebUpdateNotifier()
        let internalWorker = InternalOCRWorkerControl(webUpdates: webUpdates)
        let registry = OCRWorkerRegistry(webUpdates: webUpdates)
        let jobs = OCRWorkerJobStore(leaseTokenProvider: { "lease-token" })
        let local = CancellableDistributedTestExecutor()
        let executor = DistributedOCRProcessExecutor(
            local: local,
            workers: registry,
            jobs: jobs,
            internalWorker: internalWorker,
            configuration: DistributedOCRConfiguration(
                assignmentWaitSeconds: 2,
                completionTimeoutSeconds: 5
            )
        )
        let request = ScanPipelineCommands.ocr(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            environment: ["SCAN_LANGUAGE": "deu+eng"]
        )

        async let execution = executor.execute(request)
        for _ in 0..<100 {
            if await local.requestCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await local.requestCount == 1)

        try await internalWorker.setPaused(true)
        let registration = distributedTestRegistration()
        _ = try await registry.register(registration)
        _ = try await registry.approve(workerID: registration.workerID)
        let lease = try await requireLease(jobs: jobs, registration: registration)
        let output = Data("%PDF-1.4\nremote takeover output\n".utf8)
        try output.write(to: outputURL)
        _ = try await jobs.succeed(
            jobID: lease.manifest.jobID,
            workerID: registration.workerID,
            leaseToken: lease.leaseToken,
            result: OCRWorkerJobResult(
                outputByteCount: Int64(output.count),
                outputSHA256: OCRWorkerSHA256.hexDigest(output)
            )
        )

        #expect(try await execution.executionLocation == .remote)
        #expect(await local.cancellationCount == 1)
        #expect(try Data(contentsOf: outputURL) == output)
    }

    @Test("Approved enabled workers get first refusal after a stale heartbeat")
    func staleWorkerStillGetsFirstRefusal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputURL = root.appendingPathComponent("scan.pdf")
        let outputURL = root.appendingPathComponent("scan.ocr.pdf")
        try Data("%PDF-1.4\ninput\n".utf8).write(to: inputURL)

        let registry = OCRWorkerRegistry(offlineAfterSeconds: 1)
        let registration = distributedTestRegistration()
        let stale = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await registry.register(registration, now: stale)
        _ = try await registry.approve(workerID: registration.workerID, now: stale)
        #expect(await registry.snapshots().first?.availability == .offline)

        let jobs = OCRWorkerJobStore(leaseTokenProvider: { "lease-token" })
        let local = DistributedTestExecutor()
        let executor = DistributedOCRProcessExecutor(
            local: local,
            workers: registry,
            jobs: jobs,
            configuration: DistributedOCRConfiguration(
                assignmentWaitSeconds: 2,
                completionTimeoutSeconds: 5
            )
        )
        let request = ScanPipelineCommands.ocr(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            environment: ["SCAN_LANGUAGE": "deu+eng"]
        )

        async let execution = executor.execute(request)
        let lease = try await requireLease(jobs: jobs, registration: registration)
        let output = Data("%PDF-1.4\nremote searchable output\n".utf8)
        try output.write(to: outputURL)
        _ = try await jobs.succeed(
            jobID: lease.manifest.jobID,
            workerID: registration.workerID,
            leaseToken: lease.leaseToken,
            result: OCRWorkerJobResult(
                outputByteCount: Int64(output.count),
                outputSHA256: OCRWorkerSHA256.hexDigest(output)
            )
        )

        #expect(try await execution.succeeded)
        #expect(await local.requests.isEmpty)
    }
}

private actor DistributedTestExecutor: ProcessExecutor {
    private(set) var requests: [ProcessRequest] = []
    let result: ProcessResult

    init(result: ProcessResult = ProcessResult(exitStatus: 99)) {
        self.result = result
    }

    func execute(_ request: ProcessRequest) -> ProcessResult {
        requests.append(request)
        return result
    }
}

private actor CancellableDistributedTestExecutor: ProcessExecutor {
    private(set) var requestCount = 0
    private(set) var cancellationCount = 0

    func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        requestCount += 1
        do {
            try await Task.sleep(for: .seconds(30))
            return ProcessResult(exitStatus: 0, standardOutput: "local\n")
        } catch is CancellationError {
            if let outputPath = request.arguments.last {
                try? Data("partial local output".utf8).write(
                    to: URL(fileURLWithPath: outputPath)
                )
            }
            cancellationCount += 1
            throw CancellationError()
        }
    }
}

private func distributedTestRegistration() -> OCRWorkerRegistrationRequest {
    OCRWorkerRegistrationRequest(
        workerID: "remote-worker",
        authenticationToken: String(repeating: "a", count: 64),
        displayName: "Remote Worker",
        hostname: "remote.local",
        workerVersion: "development",
        architecture: "arm64",
        cpuCount: 8,
        maxConcurrentJobs: 1,
        ocrLanguages: ["deu", "eng"],
        capabilities: [OCRWorkerCapability.cropPDFPages]
    )
}

private func requireLease(
    jobs: OCRWorkerJobStore,
    registration: OCRWorkerRegistrationRequest
) async throws -> OCRWorkerJobLease {
    for _ in 0..<100 {
        if let lease = try await jobs.leaseNext(
            workerID: registration.workerID,
            ocrLanguages: registration.ocrLanguages,
            capabilities: registration.capabilities ?? []
        ) {
            return lease
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Remote OCR job was not enqueued")
    throw CancellationError()
}
