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
        #expect(result.standardOutput == outputURL.path + "\n")
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

        #expect(try await executor.execute(request) == localResult)
        #expect(await local.requests == [request])
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
        ocrLanguages: ["deu", "eng"]
    )
}

private func requireLease(
    jobs: OCRWorkerJobStore,
    registration: OCRWorkerRegistrationRequest
) async throws -> OCRWorkerJobLease {
    for _ in 0..<100 {
        if let lease = try await jobs.leaseNext(
            workerID: registration.workerID,
            ocrLanguages: registration.ocrLanguages
        ) {
            return lease
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Remote OCR job was not enqueued")
    throw CancellationError()
}
