import Foundation
import ScannerServerCore
import Testing

@Suite("Scan job actor")
struct ScanJobActorTests {
    @Test("Native scanner execution receives the merged configuration")
    func nativeScannerExecution() async {
        let scanner = FakeNativeScanner(result: ProcessResult(
            exitStatus: 0,
            standardOutput: "/scans/native.pdf\n"
        ))
        let actor = ScanJobActor(nativeScanner: scanner)
        let configuration = ScanPipelineConfiguration(environment: ["SCAN_TRIGGER": "button"])

        #expect(await actor.start(configuration: configuration))
        await actor.waitUntilIdle()

        #expect(await scanner.configurations == [configuration])
        #expect(await actor.state.status == "done")
        #expect(await actor.state.output == "/scans/native.pdf")
    }

    @Test("A running scan rejects a second start")
    func singleFlight() async {
        let executor = FakeProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0, standardOutput: "/scans/scan.pdf\n")),
        ])
        let actor = ScanJobActor(nativeScanner: ProcessBackedTestScanner(executor))
        let configuration = ScanPipelineConfiguration(environment: [:])

        #expect(await actor.start(configuration: configuration))
        await executor.waitForRequestCount(1)
        #expect(!(await actor.start(configuration: configuration)))
        #expect(await actor.state.status == "running")

        await executor.resumeNextSuspendedExecution()
        await actor.waitUntilIdle()
        let state = await actor.state
        #expect(state.status == "done")
        #expect(state.output == "/scans/scan.pdf")
        #expect(state.started != nil)
        #expect(state.finished != nil)
    }

    @Test("Multipage source is visible while OCR preprocessing is still running")
    func sourcePrecedesOCRProcessing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "scan-job-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("scan.pdf")
        try Data("raw source".utf8).write(to: source)

        let executor = FakeProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let ocrQueue = OCRQueueActor(
            ocrExecutor: executor,
            documentExecutor: executor,
            workspaceSuffixProvider: { "test" },
            configuration: OCRQueueConfiguration(cpuLimit: 1, niceLevel: nil)
        )
        let scanner = FakeNativeScanner(result: ProcessResult(
            exitStatus: 0,
            standardOutput: "\(source.path)\n"
        ))
        let actor = ScanJobActor(nativeScanner: scanner, ocrQueue: ocrQueue)

        #expect(await actor.start(configuration: ScanPipelineConfiguration(environment: [:])))
        await actor.waitUntilIdle()
        await executor.waitForRequestCount(1)

        #expect(await actor.state.status == "done")
        #expect(await actor.state.output == source.path)
        #expect(await ocrQueue.state.status == "running")
        #expect(await executor.requests().first?.executable == "remove-blank-pages")

        await executor.resumeNextSuspendedExecution()
        await ocrQueue.waitUntilIdle()

        #expect(await executor.requests().map(\.executable) == [
            "remove-blank-pages", "crop-pdf-pages", "ocrmypdf",
        ])
        #expect(try Data(contentsOf: source) == Data("raw source".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".ocr-work.test").path
        ))
    }

    @Test("Non-OCR preprocessing continues after acquisition becomes idle")
    func acquisitionPrecedesProcessingOnlyJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "scan-job-processing-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("scan.pdf")
        try Data("raw source".utf8).write(to: source)

        let executor = FakeProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(
            ocrExecutor: executor,
            documentExecutor: executor,
            workspaceSuffixProvider: { "processing-test" },
            configuration: OCRQueueConfiguration(cpuLimit: 1, niceLevel: nil)
        )
        let scanner = FakeNativeScanner(result: ProcessResult(
            exitStatus: 0,
            standardOutput: "\(source.path)\n"
        ))
        let actor = ScanJobActor(nativeScanner: scanner, ocrQueue: queue)
        let configuration = ScanPipelineConfiguration(environment: [
            "SCAN_OCR_ENABLED": "false",
            "SCAN_PAGE_MODE": "multi",
            "SCAN_FORMAT": "pdf",
            "SCAN_REMOVE_BLANK_PAGES": "true",
            "SCAN_CROP_PAGES": "true",
        ])

        #expect(await actor.start(configuration: configuration))
        await actor.waitUntilIdle()
        await executor.waitForRequestCount(1)

        #expect(await actor.state.status == "done")
        #expect(await queue.state.status == "running")
        #expect(await executor.requests().first?.executable == "remove-blank-pages")

        await executor.resumeNextSuspendedExecution()
        await queue.waitUntilIdle()
        #expect(await executor.requests().map(\.executable) == [
            "remove-blank-pages", "crop-pdf-pages",
        ])
    }

    @Test("Single-page preprocessing continues after acquisition becomes idle")
    func singlePageAcquisitionPrecedesProcessing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "single-page-scan-job-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("scans", isDirectory: true)

        let executor = FakeProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(
            ocrExecutor: executor,
            documentExecutor: executor,
            workspaceSuffixProvider: { "single-page-processing" },
            configuration: OCRQueueConfiguration(cpuLimit: 1, niceLevel: nil)
        )
        let pipeline = NativeScanPipeline(
            executor: executor,
            wifiAcquirer: FakeScanSnapWiFiAcquirer(),
            timestampProvider: {
                try! ScanTimestamp(rawValue: "2026-08-13.205338")
            },
            workDirectorySuffixProvider: { "single-page-processing" }
        )
        let actor = ScanJobActor(nativeScanner: pipeline, ocrQueue: queue)
        let configuration = ScanPipelineConfiguration(environment: [
            "SCAN_OUTPUT_DIR": output.path,
            "SCAN_BACKEND": "wifi",
            "SCANNER_IP": "192.0.2.20",
            "SCAN_PAIRING_KEY": "pairing-key",
            "SCAN_FORMAT": "pdf",
            "SCAN_PAGE_MODE": "single",
            "SCAN_OCR_ENABLED": "true",
            "SCAN_REMOVE_BLANK_PAGES": "true",
            "SCAN_CROP_PAGES": "true",
        ])

        #expect(await actor.start(configuration: configuration))
        await executor.waitForRequestCount(1)

        #expect(await actor.state.status == "done")
        #expect(await queue.state.status == "running")
        #expect(await executor.requests().first?.executable == "remove-blank-pages")

        await actor.cancel()
        await queue.cancelAll()
    }

    @Test("A nonzero scan exit records status, output, and error")
    func commandFailure() async {
        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(
                exitStatus: 64,
                standardOutput: "partial output\n",
                standardError: "scanner configuration missing\n"
            )),
        ])
        let actor = ScanJobActor(nativeScanner: ProcessBackedTestScanner(executor))

        #expect(await actor.start(configuration: ScanPipelineConfiguration(environment: [:])))
        await actor.waitUntilIdle()
        let state = await actor.state
        #expect(state.status == "failed (64)")
        #expect(state.output == "partial output")
        #expect(state.error == "scanner configuration missing")
    }

    @Test("Executor failures are recorded")
    func executorFailure() async {
        let executor = FakeProcessExecutor(stubs: [.failure(.expectedFailure)])
        let actor = ScanJobActor(nativeScanner: ProcessBackedTestScanner(executor))

        #expect(await actor.start(configuration: ScanPipelineConfiguration(environment: [:])))
        await actor.waitUntilIdle()
        #expect(await actor.state.status == "failed")
        #expect(!(await actor.state.error.isEmpty))
    }

    @Test("Cancellation finishes the active scan")
    func cancellation() async {
        let executor = FakeProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0)),
        ])
        let actor = ScanJobActor(nativeScanner: ProcessBackedTestScanner(executor))

        #expect(await actor.start(configuration: ScanPipelineConfiguration(environment: [:])))
        await executor.waitForRequestCount(1)
        await actor.cancel()

        let state = await actor.state
        #expect(state.status == "cancelled")
        #expect(state.finished != nil)
    }
}

private actor FakeNativeScanner: NativeScanExecuting {
    private let result: ProcessResult
    private(set) var configurations: [ScanPipelineConfiguration] = []

    init(result: ProcessResult) {
        self.result = result
    }

    func scan(configuration: ScanPipelineConfiguration) -> NativeScanResult {
        configurations.append(configuration)
        return NativeScanResult(
            process: result,
            postProcessing: result.succeeded ? .queuePublishedOutputs : .none
        )
    }
}
