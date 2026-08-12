import Foundation
import ScannerServerCore
import Testing

@Suite("Native scan pipeline")
struct NativeScanPipelineTests {
    @Test("OCR multipage source is published before blank removal and crop")
    func saneMultipagePDF() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let timestamp = "2026-07-10.142305"
        let finalPDF = fixture.output.appendingPathComponent("\(timestamp).pdf")
        let executor = FakeNativeScanProcessExecutor(stubs: [
            .materialize(files: [
                fixture.work.appendingPathComponent("page-0002.pnm").path: Data("two".utf8),
                fixture.work.appendingPathComponent("page-0001.pnm").path: Data("one".utf8),
            ], result: ProcessResult(exitStatus: 0, standardError: "scanner warming up\n")),
            .materialize(
                files: [fixture.rawPDF.path: Data("multipage-pdf".utf8)],
                result: ProcessResult(exitStatus: 0)
            ),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let pipeline = fixture.pipeline(executor: executor)
        let configuration = fixture.configuration([
            "SCAN_BACKEND": "sane",
            "SCAN_TIMESTAMP": timestamp,
            "SCAN_DEVICE": "fujitsu:ScanSnap-iX500:001",
            "SCAN_RESOLUTION": "600",
            "SCAN_MODE": "Gray",
            "SCAN_SOURCE": "ADF Duplex",
            "SCAN_REMOVE_BLANK_PAGES": "true",
            "SCAN_CROP_PAGES": "true",
        ])

        let result = try await pipeline.scan(configuration: configuration)
        let requests = await executor.requests()

        #expect(result.exitStatus == 0)
        #expect(result.standardOutput == "\(finalPDF.path)\n")
        #expect(result.standardError.contains("scanimage: scanner warming up"))
        #expect(try Data(contentsOf: finalPDF) == Data("multipage-pdf".utf8))
        #expect(requests.map(\.executable) == ["scanimage", "img2pdf", "set-pdf-creator"])
        #expect(requests[0].arguments == [
            "--device-name", "fujitsu:ScanSnap-iX500:001",
            "--batch=\(fixture.work.appendingPathComponent("page-%04d.pnm").path)",
            "--format=pnm",
            "--resolution", "600",
            "--mode", "Gray",
            "--source", "ADF Duplex",
        ])
        #expect(requests[1].arguments == [
            fixture.work.appendingPathComponent("page-0001.pnm").path,
            fixture.work.appendingPathComponent("page-0002.pnm").path,
            "-o", fixture.rawPDF.path,
        ])
        #expect(requests[2].arguments == [fixture.rawPDF.path, "--creator", "ScanSnap"])
        #expect(requests.allSatisfy { $0.environment?["SCAN_TIMESTAMP"] == timestamp })
        #expect(requests.allSatisfy { $0.workingDirectory == fixture.work })
        #expect(!FileManager.default.fileExists(atPath: fixture.work.path))
    }

    @Test("Non-OCR multipage source is also published before blank removal and crop")
    func nonOCRMultipagePDFPublishesImmediately() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let timestamp = "2026-07-10.142305"
        let finalPDF = fixture.output.appendingPathComponent("\(timestamp).pdf")
        let executor = FakeNativeScanProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
        ])
        let wifiAcquirer = FakeScanSnapWiFiAcquirer(stubs: [
            .materialize(
                Data("multipage-pdf".utf8),
                ScanSnapWiFiAcquisitionResult(pageCount: 2)
            ),
        ])
        let pipeline = fixture.pipeline(executor: executor, wifiAcquirer: wifiAcquirer)
        let configuration = fixture.configuration([
            "SCAN_BACKEND": "wifi",
            "SCAN_TIMESTAMP": timestamp,
            "SCANNER_IP": "192.0.2.20",
            "SCAN_PAIRING_KEY": "pairing-key",
            "SCAN_OCR_ENABLED": "false",
            "SCAN_PAGE_MODE": "multi",
            "SCAN_FORMAT": "pdf",
            "SCAN_REMOVE_BLANK_PAGES": "true",
            "SCAN_CROP_PAGES": "true",
        ])

        let result = try await pipeline.scan(configuration: configuration)

        #expect(result == ProcessResult(exitStatus: 0, standardOutput: "\(finalPDF.path)\n"))
        #expect(await executor.requests().map(\.executable) == ["set-pdf-creator"])
        #expect(try Data(contentsOf: finalPDF) == Data("multipage-pdf".utf8))
    }

    @Test("Wi-Fi options and processing arguments produce single-page PDFs")
    func wifiSinglePagePDF() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let timestamp = "2026-07-10.142306"
        let firstPage = fixture.output.appendingPathComponent("\(timestamp)-page-0001.pdf")
        let secondPage = fixture.output.appendingPathComponent("\(timestamp)-page-0002.pdf")
        let executor = FakeNativeScanProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
            .materialize(
                files: [
                    firstPage.path: Data("page-one".utf8),
                    secondPage.path: Data("page-two".utf8),
                ],
                result: ProcessResult(
                    exitStatus: 0,
                    standardOutput: "\(firstPage.path)\n\(secondPage.path)\n"
                )
            ),
        ])
        let wifiAcquirer = FakeScanSnapWiFiAcquirer()
        let pipeline = fixture.pipeline(executor: executor, wifiAcquirer: wifiAcquirer)
        let configuration = fixture.configuration([
            "SCAN_BACKEND": "wifi",
            "SCAN_TIMESTAMP": timestamp,
            "SCANNER_IP": "192.0.2.20",
            "SCAN_PAIRING_KEY": "primary-key",
            "SCANSNAP_PAIRING_KEY": "fallback-key",
            "SCANSNAP_CLIENT_IP": "192.0.2.30",
            "SCANSNAP_CLIENT_MAC": "02:11:22:33:44:55",
            "SCAN_SOURCE": "ADF Simplex",
            "SCAN_WIFI_DEBUG": "true",
            "SCAN_FORMAT": "pdf",
            "SCAN_PAGE_MODE": "single",
            "SCAN_BLANK_WHITE_THRESHOLD": "240",
            "SCAN_BLANK_CONTENT_RATIO_THRESHOLD": "0.01",
            "SCAN_BLANK_MEAN_THRESHOLD": "247.5",
            "SCAN_BLANK_DEBUG": "1",
            "SCAN_CROP_BACKGROUND_DELTA": "9",
            "SCAN_CROP_BORDER_PX": "50",
            "SCAN_CROP_MARGIN_POINTS": "10.5",
            "SCAN_CROP_MAX_WIDTH_RATIO": "0.7",
            "SCAN_CROP_MAX_HEIGHT_RATIO": "0.75",
            "SCAN_CROP_MIN_DENSITY": "0.1",
            "SCAN_CROP_KEEP_ORIGINAL_BOXES": "1",
            "SCAN_CROP_DEBUG": "yes",
            "SCAN_RAW_PDF_CREATOR": "ScannerServer",
        ])

        let result = try await pipeline.scan(configuration: configuration)
        let requests = await executor.requests()
        let acquisition = try #require(await wifiAcquirer.requests().first)

        #expect(result.exitStatus == 0)
        #expect(result.standardOutput == "\(firstPage.path)\n\(secondPage.path)\n")
        #expect(acquisition.scannerIPAddress == "192.0.2.20")
        #expect(acquisition.identity == ScanSnapIdentity("primary-key"))
        #expect(acquisition.clientIPAddress == "192.0.2.30")
        #expect(acquisition.clientMACAddress == [0x02, 0x11, 0x22, 0x33, 0x44, 0x55])
        #expect(acquisition.simplex)
        #expect(acquisition.debug)
        #expect(!acquisition.reusesArmedSession)
        #expect(acquisition.outputURL == fixture.rawPDF)
        #expect(requests.map(\.executable) == [
            "remove-blank-pages",
            "crop-pdf-pages",
            "set-pdf-creator",
            "split-pdf-pages",
        ])
        #expect(requests[0].arguments == [
            fixture.rawPDF.path,
            "--white-threshold", "240",
            "--content-ratio-threshold", "0.01",
            "--mean-threshold", "247.5",
            "--debug",
        ])
        #expect(requests[1].arguments == [
            fixture.rawPDF.path,
            "--background-delta", "9",
            "--border-px", "50",
            "--margin-points", "10.5",
            "--max-width-ratio", "0.7",
            "--max-height-ratio", "0.75",
            "--min-density", "0.1",
            "--keep-original-boxes",
            "--debug",
        ])
        #expect(requests[2].arguments == [fixture.rawPDF.path, "--creator", "ScannerServer"])
        #expect(requests[3].arguments == [fixture.rawPDF.path, fixture.output.path, timestamp])
        #expect(!FileManager.default.fileExists(atPath: fixture.work.path))
    }

    @Test("Wi-Fi acquisition reuses a button session handed off by the lifecycle")
    func wifiReusesHandedOffButtonSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sessions = ScanSnapAcquisitionSessionCoordinator()
        await sessions.prepareForAcquisition(reusingArmedSession: true)
        let executor = FakeNativeScanProcessExecutor(stubs: [])
        let wifiAcquirer = FakeScanSnapWiFiAcquirer(stubs: [
            .failure(.scannerRejected(status: -7)),
        ])
        let pipeline = fixture.pipeline(
            executor: executor,
            wifiAcquirer: wifiAcquirer,
            acquisitionSessions: sessions
        )

        _ = try await pipeline.scan(configuration: fixture.configuration([
            "SCAN_BACKEND": "wifi",
            "SCAN_TIMESTAMP": "2026-07-10.142306",
            "SCANNER_IP": "192.0.2.20",
            "SCAN_PAIRING_KEY": "pairing-key",
        ]))

        let request = try #require(await wifiAcquirer.requests().first)
        #expect(request.reusesArmedSession)
        #expect(await sessions.consumeForAcquisition() == .registerFresh)
    }

    @Test("PNG aliases use export-scan-images and the injected timestamp")
    func pngExport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let timestamp = try ScanTimestamp(rawValue: "2026-07-10.142307")
        let image = fixture.output.appendingPathComponent("\(timestamp.rawValue)-page-0001.png")
        let executor = FakeNativeScanProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .materialize(
                files: [image.path: Data("png".utf8)],
                result: ProcessResult(exitStatus: 0, standardOutput: "\(image.path)\n")
            ),
        ])
        let pipeline = fixture.pipeline(executor: executor, timestamp: timestamp)
        let configuration = fixture.configuration([
            "SCAN_BACKEND": "wifi",
            "SCANNER_IP": "192.0.2.20",
            "SCANSNAP_PAIRING_KEY": "pairing-key",
            "SCAN_FORMAT": "images",
            "SCAN_PAGE_MODE": "single",
            "SCAN_REMOVE_BLANK_PAGES": "false",
            "SCAN_CROP_PAGES": "false",
        ])

        let result = try await pipeline.scan(configuration: configuration)
        let requests = await executor.requests()

        #expect(configuration.format == "png")
        #expect(result == ProcessResult(exitStatus: 0, standardOutput: "\(image.path)\n"))
        #expect(requests.map(\.executable) == ["set-pdf-creator", "export-scan-images"])
        #expect(requests[1].arguments == [fixture.rawPDF.path, fixture.output.path, timestamp.rawValue])
    }

    @Test("SANE success without page files returns status 2")
    func saneNoPages() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executor = FakeNativeScanProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
        ])
        let wifiAcquirer = FakeScanSnapWiFiAcquirer(stubs: [
            .result(ScanSnapWiFiAcquisitionResult(pageCount: 1)),
        ])
        let pipeline = fixture.pipeline(executor: executor, wifiAcquirer: wifiAcquirer)
        let configuration = fixture.configuration([
            "SCAN_BACKEND": "sane",
            "SCAN_TIMESTAMP": "2026-07-10.142308",
        ])

        let result = try await pipeline.scan(configuration: configuration)

        #expect(result.exitStatus == 2)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.contains("No pages were scanned"))
        #expect(await executor.requests().map(\.executable) == ["scanimage"])
        #expect(!FileManager.default.fileExists(atPath: fixture.work.path))
    }

    @Test("Wi-Fi success without raw output returns status 2")
    func wifiNoOutput() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executor = FakeNativeScanProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
        ])
        let wifiAcquirer = FakeScanSnapWiFiAcquirer(stubs: [
            .result(ScanSnapWiFiAcquisitionResult(pageCount: 1)),
        ])
        let pipeline = fixture.pipeline(executor: executor, wifiAcquirer: wifiAcquirer)
        let result = try await pipeline.scan(configuration: fixture.configuration([
            "SCAN_BACKEND": "wifi",
            "SCAN_TIMESTAMP": "2026-07-10.142309",
            "SCANNER_IP": "192.0.2.20",
            "SCANSNAP_PAIRING_KEY": "pairing-key",
        ]))

        #expect(result.exitStatus == 2)
        #expect(result.standardError.contains("No scan output was created"))
        #expect(!FileManager.default.fileExists(atPath: fixture.work.path))
    }

    @Test("Wi-Fi acquisition failure preserves signed scanner diagnostics")
    func wifiFailurePreservesStandardOutputDiagnostics() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executor = FakeNativeScanProcessExecutor(stubs: [])
        let wifiAcquirer = FakeScanSnapWiFiAcquirer(stubs: [
            .failure(.scannerRejected(status: -7)),
        ])
        let pipeline = fixture.pipeline(executor: executor, wifiAcquirer: wifiAcquirer)

        let result = try await pipeline.scan(configuration: fixture.configuration([
            "SCAN_BACKEND": "wifi",
            "SCAN_TIMESTAMP": "2026-07-10.142309",
            "SCANNER_IP": "192.0.2.20",
            "SCANSNAP_PAIRING_KEY": "pairing-key",
        ]))

        #expect(result.exitStatus == 1)
        #expect(result.standardError.contains("status -7"))
    }

    @Test("Missing merged Wi-Fi configuration returns status 64")
    func wifiConfigurationError() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executor = FakeNativeScanProcessExecutor(stubs: [])
        let pipeline = fixture.pipeline(executor: executor)

        let result = try await pipeline.scan(configuration: fixture.configuration([
            "SCAN_BACKEND": "wifi",
            "SCAN_TIMESTAMP": "2026-07-10.142310",
        ]))

        #expect(result.exitStatus == 64)
        #expect(result.standardError.contains("requires SCANNER_IP"))
        #expect(await executor.requests().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.work.path))
    }

    @Test("Existing multipage PDF is preserved and returns status 73")
    func multipageOutputConflict() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let timestamp = "2026-07-10.142311"
        let finalPDF = fixture.output.appendingPathComponent("\(timestamp).pdf")
        try FileManager.default.createDirectory(at: fixture.output, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: finalPDF)
        let executor = FakeNativeScanProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
        ])
        let wifiAcquirer = FakeScanSnapWiFiAcquirer(stubs: [
            .materialize(Data("new".utf8), ScanSnapWiFiAcquisitionResult(pageCount: 1)),
        ])
        let pipeline = fixture.pipeline(executor: executor, wifiAcquirer: wifiAcquirer)
        let result = try await pipeline.scan(configuration: fixture.configuration([
            "SCAN_BACKEND": "wifi",
            "SCAN_TIMESTAMP": timestamp,
            "SCANNER_IP": "192.0.2.20",
            "SCANSNAP_PAIRING_KEY": "pairing-key",
            "SCAN_REMOVE_BLANK_PAGES": "false",
            "SCAN_CROP_PAGES": "false",
        ]))

        #expect(result.exitStatus == 73)
        #expect(result.standardError.contains("Output file already exists"))
        #expect(try Data(contentsOf: finalPDF) == Data("existing".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.work.path))
    }

    @Test("Split output conflicts retain document-tool status compatibility")
    func splitOutputConflict() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executor = FakeNativeScanProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 1, standardError: "FileExistsError: page already exists")),
        ])
        let pipeline = fixture.pipeline(executor: executor)
        let result = try await pipeline.scan(configuration: fixture.configuration([
            "SCAN_BACKEND": "wifi",
            "SCAN_TIMESTAMP": "2026-07-10.142312",
            "SCANNER_IP": "192.0.2.20",
            "SCANSNAP_PAIRING_KEY": "pairing-key",
            "SCAN_FORMAT": "pdf",
            "SCAN_PAGE_MODE": "single",
            "SCAN_REMOVE_BLANK_PAGES": "false",
            "SCAN_CROP_PAGES": "false",
        ]))

        #expect(result.exitStatus == 73)
        #expect(result.standardError.contains("FileExistsError"))
        #expect(!FileManager.default.fileExists(atPath: fixture.work.path))
    }

    @Test("Cancellation reaches native Wi-Fi acquisition and removes the work directory")
    func cancellationCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executor = FakeNativeScanProcessExecutor(stubs: [])
        let wifiAcquirer = FakeScanSnapWiFiAcquirer(stubs: [.suspended])
        let pipeline = fixture.pipeline(executor: executor, wifiAcquirer: wifiAcquirer)
        let configuration = fixture.configuration([
            "SCAN_BACKEND": "wifi",
            "SCAN_TIMESTAMP": "2026-07-10.142313",
            "SCANNER_IP": "192.0.2.20",
            "SCANSNAP_PAIRING_KEY": "pairing-key",
        ])
        let task = Task { try await pipeline.scan(configuration: configuration) }

        await wifiAcquirer.waitForRequest()
        #expect(FileManager.default.fileExists(atPath: fixture.work.path))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.work.path))
    }
}

private struct Fixture {
    let root: URL
    let output: URL
    let work: URL
    let rawPDF: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-scan-tests-\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("scans", isDirectory: true)
        work = output.appendingPathComponent(".scan-work.deterministic", isDirectory: true)
        rawPDF = work.appendingPathComponent("raw.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func configuration(_ additions: [String: String]) -> ScanPipelineConfiguration {
        var environment = ["SCAN_OUTPUT_DIR": output.path]
        environment.merge(additions) { _, addition in addition }
        return ScanPipelineConfiguration(environment: environment)
    }

    func pipeline(
        executor: any ProcessExecutor,
        wifiAcquirer: any ScanSnapWiFiAcquiring = FakeScanSnapWiFiAcquirer(),
        timestamp: ScanTimestamp? = nil,
        acquisitionSessions: ScanSnapAcquisitionSessionCoordinator = ScanSnapAcquisitionSessionCoordinator()
    ) -> NativeScanPipeline {
        NativeScanPipeline(
            executor: executor,
            wifiAcquirer: wifiAcquirer,
            acquisitionSessions: acquisitionSessions,
            fileSystem: FoundationNativeScanFileSystem(),
            timestampProvider: { timestamp ?? ScanTimestamp(date: Date(timeIntervalSince1970: 0)) },
            workDirectorySuffixProvider: { "deterministic" }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
