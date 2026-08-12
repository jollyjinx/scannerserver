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
        let fixture = try HTTPFixture(environment: [
            "SCAN_BACKEND": "sane",
            "SCANNERSERVER_VERSION": "2026.08.08.231742",
        ])
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
                #expect(body.contains("Version 2026.08.08.231742"))
                #expect(body.contains("action=\"/scan\""))
                #expect(body.contains("name=\"mode_id\""))
                #expect(body.contains("No scans yet."))
                #expect(body.contains("fetch(`/updates?since=${revision}`"))
                #expect(!body.contains("SCANNER_SERVER_REVISION"))
                #expect(!body.contains("SCANNER_SERVER_VERSION"))
            }
            try await client.execute(uri: "/version", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "2026.08.08.231742\n")
            }
            try await client.execute(uri: "/health", method: .post) { response in
                #expect(response.status == .notFound || response.status == .methodNotAllowed)
            }
        }
    }

    @Test("Development builds and blank version overrides use a truthful fallback")
    func developmentVersionFallback() {
        #expect(ScannerServerBuildInformation(environment: [:]).version == "development")
        #expect(
            ScannerServerBuildInformation(environment: ["SCANNERSERVER_VERSION": "  "]).version
                == "development"
        )
    }

    @Test("Refreshing retries an unusable scan directory and recovers after it is repaired")
    func unusableScanDirectory() async throws {
        let fixture = try HTTPFixture(environment: ["SCAN_BACKEND": "sane"])
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.outputDirectory)
        try Data("not a directory".utf8).write(to: fixture.outputDirectory)
        let application = try fixture.application()

        try await application.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(response.status == .serviceUnavailable)
                #expect(response.headers[.contentType] == "text/html; charset=utf-8")
                #expect(body.contains("Scan directory is not accessible"))
                #expect(body.contains("SCAN_OUTPUT_DIR"))
                #expect(body.contains(fixture.outputDirectory.path))
                #expect(!body.contains("action=\"/scan\""))
            }

            try FileManager.default.removeItem(at: fixture.outputDirectory)
            try FileManager.default.createDirectory(
                at: fixture.outputDirectory,
                withIntermediateDirectories: true
            )

            try await client.execute(uri: "/", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(response.status == .ok)
                #expect(body.contains("action=\"/scan\""))
                #expect(!body.contains("Scan directory is not accessible"))
            }
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test("The startup access check creates a missing scan directory and removes its probe")
    func scanDirectoryAccessCheck() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scanDirectory = root.appendingPathComponent("scans", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let issue = ScanDirectoryAccessIssue.check(directory: scanDirectory)
        let contents = try FileManager.default.contentsOfDirectory(atPath: scanDirectory.path)

        #expect(issue == nil)
        #expect(contents.isEmpty)
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

    @Test("First-run discovery polling preserves manual form input")
    func discoveryRefresh() async throws {
        let fixture = try HTTPFixture(environment: ["SCAN_BACKEND": "wifi"])
        defer { fixture.remove() }
        let scannerSetup = RunningDiscoverySetupService()
        let application = try fixture.application(scannerSetup: scannerSetup)

        try await application.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(!body.contains(#"<meta http-equiv="refresh""#))
                #expect(body.contains(#"fetch("/setup/scanners/state""#))
                #expect(body.contains("data-scanner-devices"))
                #expect(body.contains("You can use manual setup at the same time."))
                #expect(body.contains("Scanner IPv4 address or host name"))
                #expect(body.contains("Scanner password or product serial number"))
                #expect(body.contains("sessionStorage"))
                #expect(!body.contains(#"name="scanner_security_key""#))
            }
            try await client.execute(uri: "/setup/scanners/state", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/json; charset=utf-8")
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(body.contains(#""discoveryInProgress":true"#))
                #expect(body.contains(#""ipAddress":"192.0.2.44""#))
                #expect(body.contains(#""needsPassword":false"#))
            }
        }
    }

    @Test("Manual scanner setup uses one unified credential field")
    func unifiedManualCredentialForm() async throws {
        let fixture = try HTTPFixture(environment: ["SCAN_BACKEND": "wifi"])
        defer { fixture.remove() }
        let application = try fixture.application(scannerSetup: PasswordNeededSetupService())

        try await application.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(body.contains("action=\"/setup/scanners/manual\""))
                #expect(body.contains("name=\"scanner_ip\""))
                #expect(body.contains("name=\"scanner_credential\""))
                #expect(body.contains("Scanner password or product serial number"))
                #expect(body.contains("If you never changed the scanner password"))
                #expect(!body.contains("name=\"scanner_serial\""))
                #expect(!body.contains("name=\"scanner_mac\""))
                #expect(!body.contains("name=\"scanner_password\""))
                #expect(!body.contains("name=\"scanner_security_key\""))
                #expect(body.contains("sessionStorage"))
                #expect(body.contains("restoreSubmittedIPAddress"))
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
        let scannerReachability = ScanSnapReachabilityState(isReachable: true)
        let application = try fixture.application(scannerReachability: scannerReachability)

        try await application.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                let body = String(buffer: response.body)
                let summary = try #require(body.range(of: "<section class=\"scanner-summary\""))
                let summaryEnd = try #require(body.range(of: "</section>", range: summary.lowerBound..<body.endIndex))
                let scan = try #require(body.range(of: "<section><h2>Scan</h2>"))
                let advanced = try #require(body.range(of: "<details><summary>Advanced settings</summary>"))
                let scannerSetup = try #require(body.range(of: "<h2>Scanner setup</h2>"))
                let advancedEnd = try #require(body.range(of: "</details>", range: advanced.lowerBound..<body.endIndex))
                let reachability = try #require(body.range(of: "scanner-reachability reachable"))

                #expect(body.contains("action=\"/scan\""))
                #expect(body.contains("scanner-reachability-dot"))
                #expect(body.contains("Reachable</span>"))
                #expect(summary.lowerBound < reachability.lowerBound)
                #expect(reachability.lowerBound < summaryEnd.lowerBound)
                #expect(summaryEnd.lowerBound < scan.lowerBound)
                #expect(scan.lowerBound < advanced.lowerBound)
                #expect(advanced.lowerBound < scannerSetup.lowerBound)
                #expect(scannerSetup.lowerBound < advancedEnd.lowerBound)
                let advancedContent = body[advanced.lowerBound..<advancedEnd.upperBound]
                #expect(!advancedContent.contains("scanner-reachability"))
            }

            await scannerReachability.update(isReachable: false)
            try await client.execute(uri: "/", method: .get) { response in
                let body = String(buffer: response.body)
                let summary = try #require(body.range(of: "<section class=\"scanner-summary\""))
                let scan = try #require(body.range(of: "<section><h2>Scan</h2>"))
                #expect(body.contains("scanner-reachability unreachable"))
                #expect(body.contains("Not reachable</span>"))
                #expect(!body.contains("scanner-reachability reachable"))
                #expect(summary.lowerBound < scan.lowerBound)
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
                "SCAN_OCR_CPU_LIMIT=4",
                "SCAN_OCR_NICE=true",
                "SCAN_CROP_MARGIN_POINTS=2.5",
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
            #expect(mode.settings.ocrCPULimit == 4)
            #expect(mode.settings.ocrNice)
            #expect(!mode.settings.removeBlankPages)
            #expect(mode.settings.cropPages)
            #expect(mode.settings.cropMarginPoints == 2.5)
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
                #expect(body.contains(#"<select name="SCAN_OCR_CPU_LIMIT">"#))
                #expect(body.contains(#"<option value="4" selected>"#))
                #expect(body.contains("Automatic uses the background CPU allowance while reserving one processor"))
                #expect(body.contains(#"<select name="SCAN_OCR_NICE">"#))
                #expect(body.contains(#"<option value="true" selected>Niced (reduced)</option>"#))
                #expect(body.contains(#"name="SCAN_CROP_MARGIN_POINTS" value="2.5" min="0" step="0.1""#))
                #expect(body.contains(#"class="mode-load-form""#))
                #expect(body.contains(#"class="mode-editor-form""#))
                #expect(body.contains("<legend>Document</legend>"))
                #expect(body.contains("<legend>Scan quality</legend>"))
                #expect(body.contains("<legend>Processing</legend>"))
                #expect(body.contains("<legend>Physical button</legend>"))
                #expect(body.components(separatedBy: #"class="setting-card""#).count - 1 == 3)
                #expect(body.contains("Extra space kept around detected content after autocropping"))
                #expect(body.contains("Duplex scans both sides; simplex scans only the front."))
                #expect(body.contains("The iX500 Wi-Fi backend does not expose this control."))
                #expect(body.contains("Create searchable text in the background for PDF output."))
                #expect(body.contains("Use this mode when the scanner&#39;s physical button is pressed."))
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
                #expect(body.contains("name=\"scanner_credential\""))
                #expect(!body.contains("name=\"scanner_mac\""))
                #expect(!body.contains("name=\"scanner_serial\""))
                #expect(!body.contains("name=\"scanner_security_key\""))
                #expect(!body.contains("security key cannot be derived from the Ethernet address"))
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
                #expect(body.contains("Recent processing jobs"))
                #expect(body.contains("page-0001.pdf"))
                #expect(body.contains("cancelled in "))
            }
        }

        #expect(await fixture.ocrQueue.state.status == "cancelled")
        #expect(await fixture.ocrQueue.state.queued == 0)
    }

    @Test("Deleting a source scan cancels its active OCR job")
    func deleteCancelsActiveOCR() async throws {
        let executor = SlowCapturingExecutor(delay: .seconds(30))
        let fixture = try HTTPFixture(
            environment: ["SCAN_BACKEND": "sane"],
            executor: executor
        )
        defer { fixture.remove() }
        let fileName = "2026-07-10.120000.pdf"
        let fileURL = fixture.outputDirectory.appendingPathComponent(fileName)
        try Data("pdf bytes".utf8).write(to: fileURL)
        let application = try fixture.application()

        await fixture.ocrQueue.enqueue(fileURL.path)
        while await executor.requests.isEmpty { await Task.yield() }

        try await application.test(.router) { client in
            try await postForm(client, uri: "/files/\(fileName)/delete", body: "") { response in
                expectRedirect(response, to: "/")
            }
        }

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(await fixture.ocrQueue.state.status == "cancelled")
        #expect(await fixture.ocrQueue.state.recentJobs.first?.input == fileURL.path)
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
            try await postForm(client, uri: "/setup/scanners/manual", body: "scanner_ip=&scanner_credential=") { response in
                expectRedirect(response, to: "/?setup=manual-missing")
            }
            try await postForm(client, uri: "/setup/scanners/manual", body: "scanner_ip=192.0.2.8&scanner_credential=") { response in
                expectRedirect(response, to: "/?setup=manual-missing")
            }
            try await postForm(client, uri: "/setup/scanners/manual", body: "scanner_ip=192.0.2.8&scanner_credential=secret") { response in
                expectRedirect(response, to: "/?setup=unavailable")
            }
            try await postForm(client, uri: "/setup/scanners/clear", body: "") { response in
                expectRedirect(response, to: "/?setup=cleared")
            }
        }
    }

    @Test("Unified manual setup POST forwards the credential without exposing protocol keys")
    func unifiedManualSetupCredential() async throws {
        let fixture = try HTTPFixture(environment: ["SCAN_BACKEND": "wifi"])
        defer { fixture.remove() }
        let scannerSetup = CapturingManualSetupService()
        let application = try fixture.application(scannerSetup: scannerSetup)

        try await application.test(.router) { client in
            try await postForm(
                client,
                uri: "/setup/scanners/manual",
                body: "scanner_ip=office-scanner.example&scanner_credential=AWRHC08122"
            ) { response in
                expectRedirect(response, to: "/?setup=configured")
            }
        }

        let request = try #require(await scannerSetup.unifiedRequests.first)
        #expect(request.ipAddress == "office-scanner.example")
        #expect(request.credential == "AWRHC08122")
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
        scannerSetup: (any ScannerSetupServing)? = nil,
        scannerReachability: ScanSnapReachabilityState? = nil
    ) throws -> some ApplicationProtocol {
        let dependencies = ScannerServerDependencies(
            settingsStore: settingsStore,
            scanJobs: scanJobs,
            ocrQueue: ocrQueue,
            outputPathResolver: ScanOutputPathResolver(outputDirectory: outputDirectory),
            scannerSetup: scannerSetup ?? StoredScannerSetupService(
                store: ScannerConfigStore(environment: environment)
            ),
            scannerReachability: scannerReachability,
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
        ScannerSetupState(
            serviceAvailable: true,
            devices: [ScannerSetupDevice(
                id: "84:25:3f:aa:bb:cc",
                name: "Office ScanSnap",
                ipAddress: "192.0.2.44",
                macAddress: "84:25:3f:aa:bb:cc",
                serial: "AWRHC08122"
            )]
        )
    }

    func discoveryInProgress() -> Bool { true }
    func ensureDiscoveryStarted() {}
    func shutdown() {}
    func discover() -> ScannerSetupOutcome { .discoveryStarted }
    func select(deviceID: String) -> ScannerSetupOutcome { .unavailable }

    func configureManually(ipAddress: String, credential: String) -> ScannerSetupOutcome { .unavailable }
    func clear() -> ScannerSetupOutcome { .cleared }
}

private actor PasswordNeededSetupService: ScannerSetupServing {
    func state() -> ScannerSetupState {
        ScannerSetupState(
            serviceAvailable: true,
            needsPassword: true,
            name: "Office ScanSnap",
            ipAddress: "192.0.2.44",
            serial: "AWRHC08122",
            lastError: "Default password was rejected."
        )
    }

    func discover() -> ScannerSetupOutcome { .discoveryStarted }
    func select(deviceID: String) -> ScannerSetupOutcome { .unavailable }
    func configureManually(ipAddress: String, credential: String) -> ScannerSetupOutcome { .passwordFailed }
    func clear() -> ScannerSetupOutcome { .cleared }
}

private actor CapturingManualSetupService: ScannerSetupServing {
    struct UnifiedRequest: Sendable {
        let ipAddress: String
        let credential: String
    }

    private(set) var unifiedRequests: [UnifiedRequest] = []

    func state() -> ScannerSetupState {
        ScannerSetupState(serviceAvailable: true)
    }

    func discover() -> ScannerSetupOutcome { .discoveryStarted }
    func select(deviceID: String) -> ScannerSetupOutcome { .unavailable }

    func configureManually(ipAddress: String, credential: String) -> ScannerSetupOutcome {
        unifiedRequests.append(UnifiedRequest(ipAddress: ipAddress, credential: credential))
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
