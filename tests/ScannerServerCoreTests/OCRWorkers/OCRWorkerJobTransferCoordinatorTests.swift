import Foundation
import ScannerServerCore
import Testing

@Suite("OCR worker job transfer coordinator")
struct OCRWorkerJobTransferCoordinatorTests {
    @Test("Leasing combines worker authentication, capabilities, and durable capacity")
    func coordinatedLeasing() async throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try await fixture.registerWorker(
            capabilities: [OCRWorkerCapability.cropPDFPages],
            maxConcurrentJobs: 1
        )
        _ = try await fixture.jobs.enqueue(fixture.manifest(
            jobID: "first",
            cropPages: true
        ))
        _ = try await fixture.jobs.enqueue(fixture.manifest(jobID: "second"))
        let coordinator = fixture.coordinator(validator: AcceptingTransferValidator())

        await #expect(throws: OCRWorkerRegistryError.authenticationFailed) {
            _ = try await coordinator.leaseNext(
                workerID: fixture.workerID,
                request: OCRWorkerJobPollRequest(
                    authenticationToken: String(repeating: "f", count: 64),
                    waitSeconds: 0
                )
            )
        }

        let first = try #require(try await coordinator.leaseNext(
            workerID: fixture.workerID,
            request: OCRWorkerJobPollRequest(
                authenticationToken: fixture.authenticationToken,
                waitSeconds: 0
            )
        ))
        #expect(first.manifest.jobID == "first")
        #expect(try await coordinator.leaseNext(
            workerID: fixture.workerID,
            request: OCRWorkerJobPollRequest(
                authenticationToken: fixture.authenticationToken,
                waitSeconds: 0
            )
        ) == nil)
        #expect(try await fixture.jobs.snapshot(jobID: "second").status == .queued)
    }

    @Test("Source transfer confines paths and verifies the queued bytes")
    func sourceIntegrity() async throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try await fixture.registerWorker()
        let source = Data("%PDF-1.7\nsource\n".utf8)
        let sourceURL = fixture.workspace.appendingPathComponent("source.pdf")
        try source.write(to: sourceURL)
        _ = try await fixture.jobs.enqueue(fixture.manifest(
            sourceURL: sourceURL,
            source: source
        ))
        let coordinator = fixture.coordinator(validator: AcceptingTransferValidator())
        let lease = try #require(try await fixture.lease())

        let transferred = try await coordinator.source(
            workerID: fixture.workerID,
            authenticationToken: fixture.authenticationToken,
            jobID: lease.manifest.jobID,
            leaseToken: lease.leaseToken
        )
        #expect(transferred.data == source)
        #expect(transferred.sha256 == OCRWorkerSHA256.hexDigest(source))

        try Data("%PDF-1.7\nchanged\n".utf8).write(to: sourceURL)
        await #expect(throws: OCRWorkerTransferError.sourceChanged) {
            _ = try await coordinator.source(
                workerID: fixture.workerID,
                authenticationToken: fixture.authenticationToken,
                jobID: lease.manifest.jobID,
                leaseToken: lease.leaseToken
            )
        }

        _ = try await fixture.jobs.fail(
            jobID: lease.manifest.jobID,
            workerID: lease.workerID,
            leaseToken: lease.leaseToken,
            failure: "test complete"
        )
        let outsideURL = fixture.root.appendingPathComponent("outside.pdf")
        try source.write(to: outsideURL)
        _ = try await fixture.jobs.enqueue(fixture.manifest(
            jobID: "outside",
            sourceURL: outsideURL,
            source: source
        ))
        let outsideLease = try #require(try await fixture.lease())
        await #expect(throws: OCRWorkerTransferError.pathOutsideScanDirectory) {
            _ = try await coordinator.source(
                workerID: fixture.workerID,
                authenticationToken: fixture.authenticationToken,
                jobID: outsideLease.manifest.jobID,
                leaseToken: outsideLease.leaseToken
            )
        }
    }

    @Test("Result publication rolls back if cancellation changes the lease during validation")
    func resultCancellationRollback() async throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try await fixture.registerWorker()
        let source = Data("%PDF-1.7\nsource\n".utf8)
        let sourceURL = fixture.workspace.appendingPathComponent("source.pdf")
        let outputURL = fixture.workspace.appendingPathComponent("result.ocr.pdf")
        try source.write(to: sourceURL)
        _ = try await fixture.jobs.enqueue(fixture.manifest(
            sourceURL: sourceURL,
            outputURL: outputURL,
            source: source
        ))
        let lease = try #require(try await fixture.lease())
        let coordinator = fixture.coordinator(validator: CancellingTransferValidator(
            jobs: fixture.jobs,
            jobID: lease.manifest.jobID
        ))
        let result = Data("%PDF-1.7\nsearchable\n".utf8)

        await #expect(throws: OCRWorkerJobStoreError.invalidTransition(
            from: .cancelled,
            to: .leased
        )) {
            _ = try await coordinator.acceptResult(
                workerID: fixture.workerID,
                authenticationToken: fixture.authenticationToken,
                jobID: lease.manifest.jobID,
                leaseToken: lease.leaseToken,
                data: result
            )
        }

        #expect(try await fixture.jobs.snapshot(jobID: lease.manifest.jobID).status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path)
        #expect(!leftovers.contains { $0.hasPrefix(".ocr-upload.") })
    }

    @Test("A live lease atomically publishes a verified result and records its digest")
    func successfulResultPublication() async throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try await fixture.registerWorker()
        let source = Data("%PDF-1.7\nsource\n".utf8)
        let result = Data("%PDF-1.7\nsearchable\n".utf8)
        let sourceURL = fixture.workspace.appendingPathComponent("source.pdf")
        let outputURL = fixture.workspace.appendingPathComponent("result.ocr.pdf")
        try source.write(to: sourceURL)
        _ = try await fixture.jobs.enqueue(fixture.manifest(
            sourceURL: sourceURL,
            outputURL: outputURL,
            source: source
        ))
        let lease = try #require(try await fixture.lease())

        let snapshot = try await fixture.coordinator(
            validator: AcceptingTransferValidator()
        ).acceptResult(
            workerID: fixture.workerID,
            authenticationToken: fixture.authenticationToken,
            jobID: lease.manifest.jobID,
            leaseToken: lease.leaseToken,
            data: result
        )

        #expect(snapshot.status == .succeeded)
        #expect(snapshot.result == OCRWorkerJobResult(
            outputByteCount: Int64(result.count),
            outputSHA256: OCRWorkerSHA256.hexDigest(result)
        ))
        #expect(try Data(contentsOf: outputURL) == result)
    }

    @Test("Long polling propagates cancellation without an orphaned wait task")
    func pollingCancellation() async throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try await fixture.registerWorker()
        let coordinator = OCRWorkerJobTransferCoordinator(
            registry: fixture.registry,
            jobs: fixture.jobs,
            outputDirectory: fixture.outputDirectory,
            resultValidator: AcceptingTransferValidator(),
            webUpdates: fixture.webUpdates,
            sleep: { _ in throw CancellationError() }
        )

        await #expect(throws: CancellationError.self) {
            _ = try await coordinator.leaseNext(
                workerID: fixture.workerID,
                request: OCRWorkerJobPollRequest(
                    authenticationToken: fixture.authenticationToken,
                    waitSeconds: 30
                )
            )
        }
    }
}

private struct TransferFixture: Sendable {
    let workerID = "transfer-worker"
    let authenticationToken = String(repeating: "a", count: 64)
    let root: URL
    let outputDirectory: URL
    let workspace: URL
    let webUpdates: WebUpdateNotifier
    let registry: OCRWorkerRegistry
    let jobs: OCRWorkerJobStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        outputDirectory = root.appendingPathComponent("scans", isDirectory: true)
        workspace = outputDirectory.appendingPathComponent(".ocr-work.test", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let webUpdates = WebUpdateNotifier()
        self.webUpdates = webUpdates
        registry = OCRWorkerRegistry(webUpdates: webUpdates)
        jobs = OCRWorkerJobStore(leaseTokenProvider: { "lease-token" })
    }

    func registerWorker(
        capabilities: [String] = [],
        maxConcurrentJobs: Int = 1
    ) async throws {
        _ = try await registry.register(OCRWorkerRegistrationRequest(
            workerID: workerID,
            authenticationToken: authenticationToken,
            displayName: "Transfer Worker",
            hostname: "worker.local",
            workerVersion: "test",
            architecture: "arm64",
            cpuCount: 4,
            maxConcurrentJobs: maxConcurrentJobs,
            ocrLanguages: ["eng"],
            capabilities: capabilities
        ))
        _ = try await registry.approve(workerID: workerID)
    }

    func coordinator(
        validator: any OCRWorkerResultValidating
    ) -> OCRWorkerJobTransferCoordinator {
        OCRWorkerJobTransferCoordinator(
            registry: registry,
            jobs: jobs,
            outputDirectory: outputDirectory,
            resultValidator: validator,
            webUpdates: webUpdates
        )
    }

    func lease() async throws -> OCRWorkerJobLease? {
        try await jobs.leaseNext(workerID: workerID, ocrLanguages: ["eng"])
    }

    func manifest(
        jobID: String = "job-1",
        sourceURL: URL? = nil,
        outputURL: URL? = nil,
        source: Data = Data("%PDF-1.7\nsource\n".utf8),
        cropPages: Bool = false
    ) -> OCRWorkerJobManifest {
        let sourceURL = sourceURL ?? workspace.appendingPathComponent("\(jobID).pdf")
        let outputURL = outputURL ?? workspace.appendingPathComponent("\(jobID).ocr.pdf")
        return OCRWorkerJobManifest(
            jobID: jobID,
            sourcePath: sourceURL.path,
            outputPath: outputURL.path,
            sourceByteCount: Int64(source.count),
            sourceSHA256: OCRWorkerSHA256.hexDigest(source),
            ocrLanguages: ["eng"],
            ocrEnabled: true,
            removeBlankPages: false,
            cropPages: cropPages,
            cropConfiguration: cropPages ? OCRWorkerCropConfiguration() : nil
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct AcceptingTransferValidator: OCRWorkerResultValidating {
    func validate(fileURL: URL) async throws {}
}

private struct CancellingTransferValidator: OCRWorkerResultValidating {
    let jobs: OCRWorkerJobStore
    let jobID: String

    func validate(fileURL: URL) async throws {
        _ = try await jobs.cancel(jobID: jobID)
    }
}
