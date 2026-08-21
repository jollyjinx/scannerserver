import Foundation
import ScannerServerCore
import Testing

@Suite("Typed OCR execution module")
struct OCRExecutionModuleTests {
    @Test("Typed requests preserve protocol-v1 OCRmyPDF manifest arguments and metadata")
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
        let executor = OCRExecutionModule(
            local: local,
            workers: registry,
            jobs: jobs,
            configuration: DistributedOCRConfiguration(
                assignmentWaitSeconds: 2,
                completionTimeoutSeconds: 5
            )
        )
        let request = ocrTestRequest(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            environment: ["SCAN_LANGUAGE": "deu+eng"],
            jobs: 8,
            forceOCR: true,
            metadata: OCRWorkerJobMetadata(
                documentName: "scan.pdf",
                batchID: "batch",
                pageNumber: 3,
                operations: ["OCR (deu+eng)"]
            )
        )

        async let execution = executor.execute(request)
        let lease = try await requireLease(jobs: jobs, registration: registration)
        #expect(lease.manifest.containerArguments == [
            "--language", "deu+eng",
            "--force-ocr",
            "--rotate-pages", "--rotate-pages-threshold", "2.0",
            "--deskew", "--optimize", "1",
            "--jobs", "8",
            "/work/source.pdf", "/work/result.pdf",
        ])
        #expect(lease.manifest.metadata == request.metadata)
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
        #expect(result.location == .remote)
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
        let executor = OCRExecutionModule(
            local: local,
            workers: registry,
            jobs: jobs,
            configuration: DistributedOCRConfiguration(
                assignmentWaitSeconds: 2,
                completionTimeoutSeconds: 5
            )
        )
        let crop = OCRWorkerCropConfiguration(marginPoints: 2.5)
        let request = ocrTestRequest(
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

        #expect(try await execution.location == .remote)
        #expect(await local.requests.isEmpty)
    }

    @Test("Remote blank-page configuration is included only for a capable worker")
    func remoteBlankPageExecution() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputURL = root.appendingPathComponent("page.pdf")
        let outputURL = root.appendingPathComponent("page.ocr.pdf")
        try Data("%PDF-1.4\ninput\n".utf8).write(to: inputURL)

        let registry = OCRWorkerRegistry()
        let registration = distributedTestRegistration(capabilities: [
            OCRWorkerCapability.cropPDFPages,
            OCRWorkerCapability.removeBlankPDFPages,
        ])
        _ = try await registry.register(registration)
        _ = try await registry.approve(workerID: registration.workerID)
        let jobs = OCRWorkerJobStore(leaseTokenProvider: { "lease-token" })
        let local = DistributedTestExecutor()
        let executor = OCRExecutionModule(
            local: local,
            workers: registry,
            jobs: jobs,
            configuration: DistributedOCRConfiguration(
                assignmentWaitSeconds: 2,
                completionTimeoutSeconds: 5
            )
        )
        let blank = OCRWorkerBlankPageConfiguration(whiteThreshold: 240)
        let request = ocrTestRequest(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            workerBlankPageConfiguration: blank
        )

        async let execution = executor.execute(request)
        let lease = try await requireLease(jobs: jobs, registration: registration)
        #expect(lease.manifest.removeBlankPages)
        #expect(lease.manifest.blankPageConfiguration == blank)
        let output = Data("%PDF-1.4\nremote filtered output\n".utf8)
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

        #expect(try await execution.location == .remote)
        #expect(await local.requests.isEmpty)
    }

    @Test("No eligible worker preserves the local OCR executor")
    func localFallback() async throws {
        let localResult = OCRExecutionResult(
            outcome: .succeeded,
            standardOutput: "local\n",
            location: .local
        )
        let local = DistributedTestExecutor(result: localResult)
        let capacity = OCRLocalCapacityPool(capacity: 1)
        let executor = OCRExecutionModule(
            local: local,
            workers: OCRWorkerRegistry(),
            jobs: OCRWorkerJobStore(),
            localCapacity: capacity,
            configuration: DistributedOCRConfiguration()
        )
        let request = ocrTestRequest(
            inputPath: "/scans/input.pdf",
            outputPath: "/scans/input.ocr.pdf"
        )

        let result = try await executor.execute(request)
        #expect(result == localResult)
        #expect(result.location == .local)
        #expect(await local.requests == [request])
        #expect(await capacity.availableCPUs == 1)
    }

    @Test("Remote assignment timeout falls back locally and releases capacity")
    func assignmentTimeoutFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputURL = root.appendingPathComponent("input.pdf")
        try Data("%PDF-1.4\ninput\n".utf8).write(to: inputURL)
        let registry = OCRWorkerRegistry()
        let registration = distributedTestRegistration()
        _ = try await registry.register(registration)
        _ = try await registry.approve(workerID: registration.workerID)
        let jobs = OCRWorkerJobStore()
        let capacity = OCRLocalCapacityPool(capacity: 2)
        let local = DistributedTestExecutor(result: OCRExecutionResult(
            outcome: .succeeded,
            standardOutput: "local fallback\n",
            location: .local
        ))
        let executor = OCRExecutionModule(
            local: local,
            workers: registry,
            jobs: jobs,
            localCapacity: capacity,
            configuration: DistributedOCRConfiguration(
                assignmentWaitSeconds: 0,
                completionTimeoutSeconds: 5
            )
        )
        let request = ocrTestRequest(
            inputPath: inputURL.path,
            outputPath: root.appendingPathComponent("input.ocr.pdf").path,
            jobs: 2
        )

        let result = try await executor.execute(request)

        #expect(result.location == .local)
        #expect(await local.requests == [request])
        #expect(await capacity.availableCPUs == 2)
        #expect(await jobs.snapshots().first?.status == .cancelled)
    }

    @Test("Cancelling remote execution never starts local fallback")
    func cancellationDoesNotFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputURL = root.appendingPathComponent("scan.pdf")
        try Data("%PDF-1.4\ninput\n".utf8).write(to: inputURL)

        let registry = OCRWorkerRegistry()
        let registration = distributedTestRegistration()
        _ = try await registry.register(registration)
        _ = try await registry.approve(workerID: registration.workerID)
        let jobs = OCRWorkerJobStore()
        let local = DistributedTestExecutor()
        let executor = OCRExecutionModule(
            local: local,
            workers: registry,
            jobs: jobs,
            configuration: DistributedOCRConfiguration(
                assignmentWaitSeconds: 30,
                completionTimeoutSeconds: 30
            )
        )
        let execution = Task {
            try await executor.execute(ocrTestRequest(
                inputPath: inputURL.path,
                outputPath: root.appendingPathComponent("scan.ocr.pdf").path
            ))
        }
        for _ in 0..<100 {
            if !(await jobs.snapshots()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        execution.cancel()
        let result = await execution.result

        guard case .failure(let error) = result else {
            Issue.record("Expected OCR cancellation")
            return
        }
        #expect(error is CancellationError)
        #expect(await local.requests.isEmpty)
        #expect(await jobs.snapshots().first?.status == .cancelled)
    }

    @Test("Scheduler-assigned internal slots run locally while remote workers are online")
    func schedulerAssignedLocalExecution() async throws {
        let registry = OCRWorkerRegistry()
        let registration = distributedTestRegistration()
        _ = try await registry.register(registration)
        _ = try await registry.approve(workerID: registration.workerID)
        let jobs = OCRWorkerJobStore()
        let localResult = OCRExecutionResult(
            outcome: .succeeded,
            standardOutput: "local\n",
            location: .local
        )
        let local = DistributedTestExecutor(result: localResult)
        let executor = OCRExecutionModule(
            local: local,
            workers: registry,
            jobs: jobs,
            configuration: DistributedOCRConfiguration()
        )
        let request = ocrTestRequest(
            inputPath: "/scans/input.pdf",
            outputPath: "/scans/input.ocr.pdf",
            dispatchPreference: .reservedInternal
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
        let executor = OCRExecutionModule(
            local: local,
            workers: OCRWorkerRegistry(webUpdates: webUpdates),
            jobs: OCRWorkerJobStore(),
            internalWorker: internalWorker,
            localCapacity: OCRLocalCapacityPool(capacity: 1, webUpdates: webUpdates),
            configuration: DistributedOCRConfiguration()
        )
        let firstRequest = ocrTestRequest(
            inputPath: "/scans/first.pdf",
            outputPath: "/scans/first.ocr.pdf",
            jobs: 1
        )
        let secondRequest = ocrTestRequest(
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
        let executor = OCRExecutionModule(
            local: local,
            workers: registry,
            jobs: jobs,
            internalWorker: internalWorker,
            configuration: DistributedOCRConfiguration(
                assignmentWaitSeconds: 2,
                completionTimeoutSeconds: 5
            )
        )
        let request = ocrTestRequest(
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

        #expect(try await execution.location == .remote)
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
        let executor = OCRExecutionModule(
            local: local,
            workers: registry,
            jobs: jobs,
            configuration: DistributedOCRConfiguration(
                assignmentWaitSeconds: 2,
                completionTimeoutSeconds: 5
            )
        )
        let request = ocrTestRequest(
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

private actor DistributedTestExecutor: OCRExecuting {
    private(set) var requests: [OCRExecutionRequest] = []
    let result: OCRExecutionResult

    init(result: OCRExecutionResult = OCRExecutionResult(
        outcome: .failed(exitStatus: 99),
        location: .local
    )) {
        self.result = result
    }

    func execute(_ request: OCRExecutionRequest) -> OCRExecutionResult {
        requests.append(request)
        return result
    }
}

private actor CancellableDistributedTestExecutor: OCRExecuting {
    private(set) var requestCount = 0
    private(set) var cancellationCount = 0

    func execute(_ request: OCRExecutionRequest) async throws -> OCRExecutionResult {
        requestCount += 1
        do {
            try await Task.sleep(for: .seconds(30))
            return OCRExecutionResult(
                outcome: .succeeded,
                standardOutput: "local\n",
                location: .local
            )
        } catch is CancellationError {
            try? Data("partial local output".utf8).write(to: request.outputURL)
            cancellationCount += 1
            throw CancellationError()
        }
    }
}

private func ocrTestRequest(
    inputPath: String,
    outputPath: String,
    environment: [String: String]? = nil,
    jobs: Int = 1,
    forceOCR: Bool = false,
    workerCropConfiguration: OCRWorkerCropConfiguration? = nil,
    workerBlankPageConfiguration: OCRWorkerBlankPageConfiguration? = nil,
    metadata: OCRWorkerJobMetadata? = nil,
    dispatchPreference: OCRDispatchPreference = .remoteFirst
) -> OCRExecutionRequest {
    OCRExecutionRequest(
        inputURL: URL(fileURLWithPath: inputPath),
        outputURL: URL(fileURLWithPath: outputPath),
        options: OCRProcessingOptions(environment: environment, jobs: jobs, forceOCR: forceOCR),
        context: OCRProcessContext(environment: environment),
        metadata: metadata,
        cropConfiguration: workerCropConfiguration,
        blankPageConfiguration: workerBlankPageConfiguration,
        dispatchPreference: dispatchPreference
    )
}

private func distributedTestRegistration(
    capabilities: [String] = [OCRWorkerCapability.cropPDFPages]
) -> OCRWorkerRegistrationRequest {
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
        capabilities: capabilities
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
