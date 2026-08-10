import Foundation
import Hummingbird
import HummingbirdTesting
import ScannerServerCore
import Testing

@Suite("Runtime OCR composition")
struct RuntimeOCRCompositionTests {
    @Test("Live dependencies run scan and OCR through the composed queue")
    func liveDependenciesWireOCRQueue() async throws {
        let fixture = try LiveCommandFixture()
        defer { fixture.remove() }
        let dependencies = ScannerServerDependencies.live(environment: fixture.environment)

        let started = await dependencies.scanJobs.start(
            configuration: ScanPipelineConfiguration(environment: fixture.environment)
        )
        #expect(started)
        await dependencies.scanJobs.waitUntilIdle()
        await dependencies.ocrQueue.waitUntilIdle()

        let scanState = await dependencies.scanJobs.state
        let ocrState = await dependencies.ocrQueue.state
        #expect(scanState.status == "done")
        #expect(scanState.output == fixture.inputURL.path)
        #expect(ocrState.status == "done")
        #expect(ocrState.input == fixture.inputURL.path)
        #expect(ocrState.output == fixture.outputURL.path)
        #expect(ocrState.queued == 0)
    }

    @Test("Index renders injected OCR running, queued, output, and error state safely")
    func indexRendersOCRState() async throws {
        let fixture = try HTTPRuntimeFixture()
        defer { fixture.remove() }
        let firstInput = "/scans/<first>&.pdf"
        let secondInput = "/scans/<second>&.pdf"
        let executor = RuntimeOCRProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(
                exitStatus: 9,
                standardOutput: "<ocr-output>&\n",
                standardError: "<ocr-error>&\n"
            )),
        ])
        let ocrQueue = OCRQueueActor(
            executor: executor,
            configuration: OCRQueueConfiguration(cpuLimit: 3, niceLevel: 10)
        )
        let dependencies = fixture.dependencies(ocrQueue: ocrQueue)
        let application = try ScannerServerApplication.make(
            configuration: try ScannerServerServiceConfiguration(hostname: "127.0.0.1", port: 8080),
            dependencies: dependencies
        )

        await ocrQueue.enqueue(firstInput)
        await ocrQueue.enqueue(secondInput)
        await executor.waitForRequestCount(1)

        try await application.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(response.status == .ok)
                #expect(body.contains("<h2>OCR</h2>"))
                #expect(body.contains("<span class=\"status\">running</span> 1 queued"))
                #expect(body.contains("CPU budget: 3; priority: nice +10"))
                #expect(body.contains("Input: /scans/&lt;first&gt;&amp;.pdf"))
                #expect(!body.contains(firstInput))
            }

            await executor.resumeNextSuspendedExecution()
            await ocrQueue.waitUntilIdle()

            try await client.execute(uri: "/", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(body.contains("<span class=\"status\">failed (9)</span>"))
                #expect(body.contains("Input: /scans/&lt;second&gt;&amp;.pdf"))
                #expect(body.contains("<pre>&lt;ocr-output&gt;&amp;</pre>"))
                #expect(body.contains("<pre>&lt;ocr-error&gt;&amp;</pre>"))
                #expect(!body.contains("1 queued"))
                #expect(!body.contains("<ocr-output>"))
                #expect(!body.contains("<ocr-error>"))
            }
        }
    }

    @Test("Runtime shutdown cancels scan and OCR workers")
    func shutdownCancelsWorkers() async throws {
        let fixture = try HTTPRuntimeFixture()
        defer { fixture.remove() }
        let executor = RuntimeOCRProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0)),
            .suspended(ProcessResult(exitStatus: 0)),
        ])
        let ocrQueue = OCRQueueActor(executor: executor)
        let scanJobs = ScanJobActor(
            nativeScanner: ProcessBackedTestScanner(executor),
            ocrQueue: ocrQueue
        )
        let dependencies = fixture.dependencies(scanJobs: scanJobs, ocrQueue: ocrQueue)
        let runtime = ScannerServerRuntime(dependencies: dependencies)

        #expect(await scanJobs.start(configuration: ScanPipelineConfiguration(environment: fixture.environment)))
        await ocrQueue.enqueue("/scans/pending.pdf")
        await executor.waitForRequestCount(2)
        await runtime.shutdown()

        #expect(await scanJobs.state.status == "cancelled")
        #expect(await ocrQueue.state.status == "cancelled")
        #expect(await ocrQueue.state.queued == 0)
    }
}

private struct LiveCommandFixture {
    let root: URL
    let inputURL: URL
    let outputURL: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tools = root.appendingPathComponent("bin", isDirectory: true)
        let scans = root.appendingPathComponent("scans", isDirectory: true)
        let timestamp = "2026-07-10.120000"
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scans, withIntermediateDirectories: true)
        inputURL = scans.appendingPathComponent("\(timestamp)-page-0001.pdf")
        outputURL = scans.appendingPathComponent("\(timestamp)-page-0001.ocr.pdf")

        try Self.writeExecutable(
            at: tools.appendingPathComponent("scanimage"),
            contents: "#!/bin/sh\nset -eu\noutput_pattern=\"\"\nfor argument; do\n  case \"$argument\" in --batch=*) output_pattern=${argument#--batch=};; esac\ndone\noutput=$(printf '%s' \"$output_pattern\" | sed 's/%04d/0001/')\n: > \"$output\"\n"
        )
        try Self.writeExecutable(
            at: tools.appendingPathComponent("img2pdf"),
            contents: "#!/bin/sh\nset -eu\nfor argument; do\n  if [ \"${previous:-}\" = -o ]; then output=$argument; fi\n  previous=$argument\ndone\n: > \"$output\"\n"
        )
        try Self.writeExecutable(
            at: tools.appendingPathComponent("exiftool"),
            contents: "#!/bin/sh\nset -eu\n"
        )
        try Self.writeExecutable(
            at: tools.appendingPathComponent("qpdf"),
            contents: "#!/bin/sh\nset -eu\nif [ \"$1\" = --show-npages ]; then printf '1\\n'; exit 0; fi\nfor output; do :; done\n: > \"$output\"\n"
        )
        try Self.writeExecutable(
            at: tools.appendingPathComponent("ocrmypdf"),
            contents: "#!/bin/sh\nset -eu\nfor output; do :; done\n: > \"$output\"\nprintf '%s\\n' \"$output\"\n"
        )

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = tools.path + ":" + (environment["PATH"] ?? "")
        environment["SCAN_BACKEND"] = "sane"
        environment["SCAN_PAGE_MODE"] = "single"
        environment["SCAN_TIMESTAMP"] = timestamp
        environment["SCAN_OCR_ENABLED"] = "true"
        environment["SCAN_REMOVE_BLANK_PAGES"] = "false"
        environment["SCAN_CROP_PAGES"] = "false"
        environment["SCAN_OUTPUT_DIR"] = scans.path
        environment["SCAN_SETTINGS_PATH"] = scans.appendingPathComponent(".scanner-settings.json").path
        environment["SCANNER_CONFIG_PATH"] = scans.appendingPathComponent(".scannerserver-scanner.json").path
        self.environment = environment
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func writeExecutable(at url: URL, contents: String) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private struct HTTPRuntimeFixture {
    let root: URL
    let outputDirectory: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        outputDirectory = root.appendingPathComponent("scans", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        environment = [
            "SCAN_BACKEND": "sane",
            "SCAN_OUTPUT_DIR": outputDirectory.path,
            "SCAN_SETTINGS_PATH": outputDirectory.appendingPathComponent(".scanner-settings.json").path,
            "SCANNER_CONFIG_PATH": outputDirectory.appendingPathComponent(".scannerserver-scanner.json").path,
        ]
    }

    func dependencies(
        scanJobs: ScanJobActor? = nil,
        ocrQueue: OCRQueueActor
    ) -> ScannerServerDependencies {
        ScannerServerDependencies(
            settingsStore: ScanSettingsStore(environment: environment),
            scanJobs: scanJobs ?? ScanJobActor(
                nativeScanner: ProcessBackedTestScanner(RuntimeOCRProcessExecutor(stubs: []))
            ),
            ocrQueue: ocrQueue,
            outputPathResolver: ScanOutputPathResolver(outputDirectory: outputDirectory),
            scannerSetup: StoredScannerSetupService(store: ScannerConfigStore(environment: environment)),
            environment: environment
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
