import Foundation
import Hummingbird
import HummingbirdTesting
import ScannerServerCore
import Testing

@Suite("Scanner server HTTP application")
struct ScannerServerApplicationTests {
    @Test("Service configuration preserves the container environment contract")
    func environmentConfiguration() throws {
        let defaults = try ScannerServerServiceConfiguration(environment: [:])
        #expect(defaults.hostname == "0.0.0.0")
        #expect(defaults.port == 8080)

        let configured = try ScannerServerServiceConfiguration(
            environment: ["WEB_HOST": "127.0.0.1", "WEB_PORT": "9090"]
        )
        #expect(configured.hostname == "127.0.0.1")
        #expect(configured.port == 9090)
    }

    @Test("Invalid ports fail during startup validation", arguments: ["invalid", "0", "65536"])
    func invalidPort(value: String) {
        #expect(throws: ScannerServerConfigurationError.self) {
            try ScannerServerServiceConfiguration(environment: ["WEB_PORT": value])
        }
    }

    @Test("Health and functional index routes are available")
    func baselineRoutes() async throws {
        let fixture = try HTTPFixture(environment: ["SCAN_BACKEND": "sane"])
        defer { fixture.remove() }
        let application = try fixture.application()

        try await application.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "ok\n")
            }
            try await client.execute(uri: "/", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/html; charset=utf-8")
                #expect(body.contains("<h1>scannerserver</h1>"))
                #expect(body.contains("action=\"/scan\""))
                #expect(body.contains("name=\"mode_id\""))
                #expect(body.contains("No scans yet."))
                #expect(body.contains("fetch(`/updates?since=${revision}`"))
                #expect(!body.contains("SCANNER_SERVER_REVISION"))
            }
            try await client.execute(uri: "/health", method: .post) { response in
                #expect(response.status == .notFound || response.status == .methodNotAllowed)
            }
        }
    }

    @Test("Browser update request completes only after a server state revision")
    func browserUpdates() async throws {
        let fixture = try HTTPFixture(environment: ["SCAN_BACKEND": "sane"])
        defer { fixture.remove() }
        let application = try fixture.application()
        let revision = await fixture.scanJobs.webUpdates.notify()

        try await application.test(.router) { client in
            try await client.execute(uri: "/updates?since=0", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/plain; charset=utf-8")
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(String(buffer: response.body) == "\(revision)\n")
            }
            try await client.execute(uri: "/updates?since=invalid", method: .get) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test("First-run page refreshes only while scanner discovery is running")
    func discoveryRefresh() async throws {
        let fixture = try HTTPFixture(environment: ["SCAN_BACKEND": "wifi"])
        defer { fixture.remove() }
        let scannerSetup = RunningDiscoverySetupService()
        let application = try fixture.application(scannerSetup: scannerSetup)

        try await application.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(body.contains(#"<meta http-equiv="refresh" content="2">"#))
            }
        }
    }

    @Test("Configured scanner setup is hidden inside advanced settings")
    func configuredSetupIsAdvanced() async throws {
        let fixture = try HTTPFixture(environment: ["SCAN_BACKEND": "wifi"])
        defer { fixture.remove() }
        let scannerStore = ScannerConfigStore(environment: fixture.environment)
        try await scannerStore.save(ScannerConfig(
            status: .configured,
            scannerIP: "192.0.2.8",
            mac: "84:25:3f:aa:bb:cc",
            serial: "ABC1234",
            name: "Office ScanSnap",
            pairingKey: "configured-key"
        ))
        let application = try fixture.application()

        try await application.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                let body = String(buffer: response.body)
                let advanced = try #require(body.range(of: "<details><summary>Advanced settings</summary>"))
                let scannerSetup = try #require(body.range(of: "<h2>Scanner setup</h2>"))
                let advancedEnd = try #require(body.range(of: "</details>", range: advanced.lowerBound..<body.endIndex))

                #expect(body.contains("action=\"/scan\""))
                #expect(advanced.lowerBound < scannerSetup.lowerBound)
                #expect(scannerSetup.lowerBound < advancedEnd.lowerBound)
            }
        }
    }

    @Test("Mode forms preserve field names, persist settings, and redirect with 303")
    func modeForms() async throws {
        let fixture = try HTTPFixture(environment: ["SCAN_BACKEND": "sane"])
        defer { fixture.remove() }
        let application = try fixture.application()

        try await application.test(.router) { client in
            try await postForm(client, uri: "/modes/default", body: "mode_id=photo-png") { response in
                expectRedirect(response, to: "/")
            }
            var settings = try await fixture.settingsStore.load()
            #expect(settings.defaultModeID == "photo-png")

            let form = [
                "mode_id=",
                "name=%3Cscript%3Ealert%281%29%3C%2Fscript%3E",
                "SCAN_SIMPLEX=true",
                "SCAN_FORMAT=png",
                "SCAN_PAGE_MODE=single",
                "SCAN_RESOLUTION=600",
                "SCAN_MODE=Gray",
                "SCAN_LANGUAGE=eng",
                "SCAN_OCR_ENABLED=on",
                "SCAN_CROP_PAGES=on",
                "set_default=on",
            ].joined(separator: "&")
            try await postForm(client, uri: "/modes/save", body: form) { response in
                #expect(response.status == .seeOther)
                #expect(response.headers[.location] == "/?edit_mode=script-alert-1-script")
            }

            settings = try await fixture.settingsStore.load()
            let mode = try #require(settings.mode(id: "script-alert-1-script"))
            #expect(mode.name == "<script>alert(1)</script>")
            #expect(mode.settings.simplex)
            #expect(mode.settings.source == "ADF Simplex")
            #expect(mode.settings.format == "png")
            #expect(mode.settings.pageMode == "single")
            #expect(mode.settings.ocrEnabled)
            #expect(!mode.settings.removeBlankPages)
            #expect(mode.settings.cropPages)
            #expect(settings.defaultModeID == mode.id)

            try await client.execute(uri: "/?edit_mode=script-alert-1-script", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(!body.contains("<script>alert(1)</script>"))
                #expect(body.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
                #expect(body.contains(#"<select name="SCAN_LANGUAGE">"#))
                #expect(body.contains(#"<option value="deu+eng">German + English</option>"#))
                #expect(body.contains(#"<option value="deu">German</option>"#))
                #expect(body.contains(#"<option value="eng" selected>English</option>"#))
                #expect(!body.contains(#"<input name="SCAN_LANGUAGE""#))
            }
            try await postForm(client, uri: "/modes/delete", body: "mode_id=script-alert-1-script") { response in
                expectRedirect(response, to: "/")
            }
            settings = try await fixture.settingsStore.load()
            #expect(settings.mode(id: "script-alert-1-script") == nil)
            #expect(settings.defaultModeID == settings.modes[0].id)
        }
    }

    @Test("Scan form dispatches the selected mode and remains single-flight")
    func scanFormAndSingleFlight() async throws {
        let executor = SlowCapturingExecutor()
        let fixture = try HTTPFixture(
            environment: ["SCAN_BACKEND": "sane"],
            executor: executor
        )
        defer { fixture.remove() }
        let application = try fixture.application()

        try await application.test(.router) { client in
            try await postForm(client, uri: "/scan", body: "mode_id=photo-png") { response in
                expectRedirect(response, to: "/")
            }
            try await postForm(client, uri: "/scan", body: "mode_id=duplex-pdf-ocr") { response in
                expectRedirect(response, to: "/")
            }

            await Task.yield()
            let state = await fixture.scanJobs.state
            #expect(state.status == "running")
            let requests = await executor.requests
            #expect(requests.count == 1)
            #expect(requests.first?.environment?["SCAN_PROFILE_ID"] == "photo-png")
            #expect(requests.first?.environment?["SCAN_TRIGGER"] == "web")
            #expect(requests.first?.environment?["SCAN_FORMAT"] == "png")
        }
        await fixture.scanJobs.cancel()
    }

    @Test("Wi-Fi scans require truthful setup state")
    func scanRequiresSetup() async throws {
        let fixture = try HTTPFixture(environment: ["SCAN_BACKEND": "wifi"])
        defer { fixture.remove() }
        let application = try fixture.application()

        try await application.test(.router) { client in
            try await postForm(client, uri: "/scan", body: "mode_id=duplex-pdf-ocr") { response in
                expectRedirect(response, to: "/?setup=setup-required")
            }
            try await client.execute(uri: "/", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(body.contains("Live scanner discovery and pairing are not available"))
                #expect(!body.contains("action=\"/scan\""))
                #expect(body.contains("action=\"/setup/scanners/discover\""))
                #expect(body.contains("action=\"/setup/scanners/manual\""))
                #expect(body.contains("name=\"scanner_security_key\""))
                #expect(body.contains("security key cannot be derived from the Ethernet address"))
                #expect(body.contains("action=\"/setup/scanners/clear\""))
            }
        }
        #expect(await fixture.executor.requests.isEmpty)
    }

    @Test("OCR can be cancelled from the web page and records elapsed jobs")
    func cancelOCR() async throws {
        let executor = SlowCapturingExecutor(delay: .seconds(30))
        let fixture = try HTTPFixture(
            environment: ["SCAN_BACKEND": "sane"],
            executor: executor
        )
        defer { fixture.remove() }
        let application = try fixture.application()

        await fixture.ocrQueue.enqueue("/scans/page-0001.pdf")
        while await executor.requests.isEmpty { await Task.yield() }

        try await application.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(String(buffer: response.body).contains("action=\"/ocr/cancel\""))
            }
            try await postForm(client, uri: "/ocr/cancel", body: "") { response in
                expectRedirect(response, to: "/")
            }
            try await client.execute(uri: "/", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(body.contains("Recent OCR jobs"))
                #expect(body.contains("page-0001.pdf"))
                #expect(body.contains("cancelled in "))
            }
        }

        #expect(await fixture.ocrQueue.state.status == "cancelled")
        #expect(await fixture.ocrQueue.state.queued == 0)
    }

    @Test("Setup routes preserve fields and report unavailable services without fake success")
    func setupRoutes() async throws {
        let fixture = try HTTPFixture(environment: ["SCAN_BACKEND": "wifi"])
        defer { fixture.remove() }
        let application = try fixture.application()

        try await application.test(.router) { client in
            try await postForm(client, uri: "/setup/scanners/discover", body: "") { response in
                expectRedirect(response, to: "/?setup=unavailable")
            }
            try await postForm(client, uri: "/setup/scanners/select", body: "device_id=") { response in
                expectRedirect(response, to: "/?setup=no-device")
            }
            try await postForm(client, uri: "/setup/scanners/manual", body: "scanner_ip=&scanner_mac=&scanner_serial=&scanner_security_key=") { response in
                expectRedirect(response, to: "/?setup=manual-missing")
            }
            try await postForm(client, uri: "/setup/scanners/manual", body: "scanner_ip=192.0.2.8&scanner_mac=&scanner_serial=ABC&scanner_security_key=secret") { response in
                expectRedirect(response, to: "/?setup=unavailable")
            }
            try await postForm(client, uri: "/setup/scanners/password", body: "scanner_password=secret") { response in
                expectRedirect(response, to: "/?setup=unavailable")
            }
            try await postForm(client, uri: "/setup/scanners/clear", body: "") { response in
                expectRedirect(response, to: "/?setup=cleared")
            }
        }
    }

    @Test("Manual setup accepts a security key in the initial form")
    func manualSetupSecurityKey() async throws {
        let fixture = try HTTPFixture(environment: ["SCAN_BACKEND": "wifi"])
        defer { fixture.remove() }
        let scannerSetup = CapturingManualSetupService()
        let application = try fixture.application(scannerSetup: scannerSetup)

        try await application.test(.router) { client in
            let form = [
                "scanner_ip=192.0.2.8",
                "scanner_mac=",
                "scanner_serial=AWRHC08122",
                "scanner_security_key=8122",
            ].joined(separator: "&")
            try await postForm(client, uri: "/setup/scanners/manual", body: form) { response in
                expectRedirect(response, to: "/?setup=configured")
            }
        }

        let request = try #require(await scannerSetup.manualRequests.first)
        #expect(request.ipAddress == "192.0.2.8")
        #expect(request.macAddress.isEmpty)
        #expect(request.serial == "AWRHC08122")
        #expect(await scannerSetup.securityKeys == ["8122"])
    }

    @Test("File routes download, view, preview, reject traversal, and delete files")
    func fileRoutes() async throws {
        let fixture = try HTTPFixture(environment: ["SCAN_BACKEND": "sane"])
        defer { fixture.remove() }
        let fileName = "2026-07-10.120000.pdf"
        let contents = Data("pdf bytes".utf8)
        try contents.write(to: fixture.outputDirectory.appendingPathComponent(fileName))
        try Data("outside".utf8).write(to: fixture.outputDirectory.deletingLastPathComponent().appendingPathComponent("outside.pdf"))
        let application = try fixture.application()

        try await application.test(.router) { client in
            try await client.execute(uri: "/files/\(fileName)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/pdf")
                #expect(response.headers[.contentDisposition] == "attachment; filename=\(fileName)")
                #expect(Data(buffer: response.body) == contents)
            }
            try await client.execute(uri: "/view/\(fileName)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentDisposition] == "inline; filename=\(fileName)")
            }
            try await client.execute(uri: "/files/\(fileName)/preview", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "image/jpeg")
                #expect(response.body.readableBytes > 100)
            }
            try await client.execute(uri: "/files/%2E%2E%2Foutside.pdf", method: .get) { response in
                #expect(response.status == .notFound)
            }
            try await postForm(client, uri: "/files/\(fileName)/delete", body: "") { response in
                expectRedirect(response, to: "/")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.outputDirectory.appendingPathComponent(fileName).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.outputDirectory.appendingPathComponent(".previews/\(fileName).jpg").path))
    }

    @Test("Bulk delete accepts repeated browser form fields")
    func bulkDelete() async throws {
        let fixture = try HTTPFixture(environment: ["SCAN_BACKEND": "sane"])
        defer { fixture.remove() }
        let names = ["2026-07-10.120000.pdf", "2026-07-10.120100.png"]
        for name in names {
            try Data(name.utf8).write(to: fixture.outputDirectory.appendingPathComponent(name))
        }
        let application = try fixture.application()

        try await application.test(.router) { client in
            let body = names.map { "files=\($0)" }.joined(separator: "&")
            try await postForm(client, uri: "/files/delete-selected", body: body) { response in
                expectRedirect(response, to: "/")
            }
        }
        for name in names {
            #expect(!FileManager.default.fileExists(atPath: fixture.outputDirectory.appendingPathComponent(name).path))
        }
    }

    @Test("Index groups files and escapes every dynamic filename")
    func indexFileStateIsEscaped() async throws {
        let fixture = try HTTPFixture(environment: ["SCAN_BACKEND": "sane"])
        defer { fixture.remove() }
        let fileName = "2026-07-10.<script>.pdf"
        try Data("pdf".utf8).write(to: fixture.outputDirectory.appendingPathComponent(fileName))
        let application = try fixture.application()

        try await application.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(body.contains("Friday, 2026-07-10"))
                #expect(body.contains("2026-07-10.&lt;script&gt;.pdf"))
                #expect(!body.contains("2026-07-10.<script>.pdf"))
                #expect(body.contains("/files/2026-07-10.%3Cscript%3E.pdf"))
                #expect(body.contains(#"<input type="checkbox" data-select-all> Select all"#))
                #expect(body.contains(#"document.querySelectorAll('input[name="files"]')"#))
            }
        }
    }
}

private struct HTTPFixture: Sendable {
    let root: URL
    let outputDirectory: URL
    let settingsStore: ScanSettingsStore
    let scanJobs: ScanJobActor
    let ocrQueue: OCRQueueActor
    let executor: SlowCapturingExecutor
    let environment: [String: String]

    init(
        environment additions: [String: String],
        executor: SlowCapturingExecutor = SlowCapturingExecutor(delay: .zero)
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        outputDirectory = root.appendingPathComponent("scans", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var environment = additions
        environment["SCAN_OUTPUT_DIR"] = outputDirectory.path
        environment["SCAN_SETTINGS_PATH"] = outputDirectory.appendingPathComponent(".scanner-settings.json").path
        environment["SCANNER_CONFIG_PATH"] = outputDirectory.appendingPathComponent(".scannerserver-scanner.json").path
        self.environment = environment
        settingsStore = ScanSettingsStore(environment: environment)
        let webUpdates = WebUpdateNotifier()
        scanJobs = ScanJobActor(
            nativeScanner: ProcessBackedTestScanner(executor),
            webUpdates: webUpdates
        )
        ocrQueue = OCRQueueActor(executor: executor, webUpdates: webUpdates)
        self.executor = executor
    }

    func application(
        scannerSetup: (any ScannerSetupServing)? = nil
    ) throws -> some ApplicationProtocol {
        let dependencies = ScannerServerDependencies(
            settingsStore: settingsStore,
            scanJobs: scanJobs,
            ocrQueue: ocrQueue,
            outputPathResolver: ScanOutputPathResolver(outputDirectory: outputDirectory),
            scannerSetup: scannerSetup ?? StoredScannerSetupService(
                store: ScannerConfigStore(environment: environment)
            ),
            environment: environment
        )
        return try ScannerServerApplication.make(
            configuration: ScannerServerServiceConfiguration(hostname: "127.0.0.1", port: 8080),
            dependencies: dependencies
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor RunningDiscoverySetupService: ScannerSetupServing {
    func state() -> ScannerSetupState {
        ScannerSetupState(serviceAvailable: true)
    }

    func discoveryInProgress() -> Bool { true }
    func ensureDiscoveryStarted() {}
    func shutdown() {}
    func discover() -> ScannerSetupOutcome { .discoveryStarted }
    func select(deviceID: String) -> ScannerSetupOutcome { .unavailable }

    func configureManually(
        ipAddress: String,
        macAddress: String,
        serial: String
    ) -> ScannerSetupOutcome { .unavailable }

    func savePassword(_ password: String) -> ScannerSetupOutcome { .unavailable }
    func clear() -> ScannerSetupOutcome { .cleared }
}

private actor CapturingManualSetupService: ScannerSetupServing {
    struct ManualRequest: Sendable {
        let ipAddress: String
        let macAddress: String
        let serial: String
    }

    private(set) var manualRequests: [ManualRequest] = []
    private(set) var securityKeys: [String] = []

    func state() -> ScannerSetupState {
        ScannerSetupState(serviceAvailable: true)
    }

    func discover() -> ScannerSetupOutcome { .discoveryStarted }
    func select(deviceID: String) -> ScannerSetupOutcome { .unavailable }

    func configureManually(
        ipAddress: String,
        macAddress: String,
        serial: String
    ) -> ScannerSetupOutcome {
        manualRequests.append(ManualRequest(
            ipAddress: ipAddress,
            macAddress: macAddress,
            serial: serial
        ))
        return .passwordNeeded
    }

    func savePassword(_ password: String) -> ScannerSetupOutcome {
        securityKeys.append(password)
        return .configured
    }

    func clear() -> ScannerSetupOutcome { .cleared }
}

private actor SlowCapturingExecutor: ProcessExecutor {
    private(set) var requests: [ProcessRequest] = []
    private let delay: Duration

    init(delay: Duration = .seconds(30)) {
        self.delay = delay
    }

    func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        requests.append(request)
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return ProcessResult(exitStatus: 0)
    }
}

private func postForm(
    _ client: TestClientProtocol,
    uri: String,
    body: String,
    test: @escaping (TestResponse) async throws -> Void
) async throws {
    try await client.execute(
        uri: uri,
        method: .post,
        headers: [.contentType: "application/x-www-form-urlencoded"],
        body: ByteBuffer(string: body),
        testCallback: test
    )
}

private func expectRedirect(_ response: TestResponse, to location: String) {
    #expect(response.status == .seeOther)
    #expect(response.headers[.location] == location)
}
