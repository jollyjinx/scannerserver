import Foundation
import Hummingbird

public struct ScannerServerServiceConfiguration: Equatable, Sendable {
    public static let defaultHostname = "0.0.0.0"
    public static let defaultPort = 8080

    public let hostname: String
    public let port: Int

    public init(hostname: String = defaultHostname, port: Int = defaultPort) throws {
        guard (1...65_535).contains(port) else {
            throw ScannerServerConfigurationError.invalidPort(port)
        }
        self.hostname = hostname
        self.port = port
    }

    public init(environment: [String: String]) throws {
        let hostname = environment["WEB_HOST"] ?? Self.defaultHostname
        let port: Int
        if let value = environment["WEB_PORT"] {
            guard let parsedPort = Int(value) else {
                throw ScannerServerConfigurationError.invalidPortValue(value)
            }
            port = parsedPort
        } else {
            port = Self.defaultPort
        }
        try self.init(hostname: hostname, port: port)
    }

    public func overriding(hostname: String?, port: Int?) throws -> Self {
        try Self(hostname: hostname ?? self.hostname, port: port ?? self.port)
    }
}

public enum ScannerServerConfigurationError: Error, Equatable, Sendable {
    case invalidPort(Int)
    case invalidPortValue(String)
    case missingIndexResource
    case unreadableIndexResource
    case invalidIndexResource
}

public struct ScannerSetupDevice: Equatable, Sendable {
    public let id: String
    public let name: String
    public let ipAddress: String
    public let macAddress: String
    public let serial: String

    public init(id: String, name: String, ipAddress: String, macAddress: String, serial: String) {
        self.id = id
        self.name = name
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.serial = serial
    }
}

public struct ScannerSetupState: Equatable, Sendable {
    public let serviceAvailable: Bool
    public let configured: Bool
    public let needsPassword: Bool
    public let name: String
    public let ipAddress: String
    public let macAddress: String
    public let serial: String
    public let lastError: String
    public let devices: [ScannerSetupDevice]
    public let scannerEnvironment: [String: String]

    public init(
        serviceAvailable: Bool,
        configured: Bool = false,
        needsPassword: Bool = false,
        name: String = "ScanSnap",
        ipAddress: String = "",
        macAddress: String = "",
        serial: String = "",
        lastError: String = "",
        devices: [ScannerSetupDevice] = [],
        scannerEnvironment: [String: String] = [:]
    ) {
        self.serviceAvailable = serviceAvailable
        self.configured = configured
        self.needsPassword = needsPassword
        self.name = name
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.serial = serial
        self.lastError = lastError
        self.devices = devices
        self.scannerEnvironment = scannerEnvironment
    }
}

public enum ScannerSetupOutcome: String, Sendable {
    case discoveryStarted = "discovery-started"
    case noDevice = "no-device"
    case manualNotFound = "manual-not-found"
    case manualInvalid = "manual-invalid"
    case passwordNeeded = "password-needed"
    case passwordFailed = "password-failed"
    case configured
    case cleared
    case setupRequired = "setup-required"
    case unavailable
}

public protocol ScannerSetupServing: Sendable {
    func state() async -> ScannerSetupState
    func ensureDiscoveryStarted() async
    func discover() async -> ScannerSetupOutcome
    func select(deviceID: String) async -> ScannerSetupOutcome
    func configureManually(ipAddress: String, macAddress: String, serial: String) async -> ScannerSetupOutcome
    func savePassword(_ password: String) async -> ScannerSetupOutcome
    func clear() async -> ScannerSetupOutcome
}

public extension ScannerSetupServing {
    func ensureDiscoveryStarted() async {}
}

public actor StoredScannerSetupService: ScannerSetupServing {
    private let store: ScannerConfigStore

    public init(store: ScannerConfigStore) {
        self.store = store
    }

    public func state() async -> ScannerSetupState {
        guard let config = await store.activeConfiguration() else {
            return ScannerSetupState(serviceAvailable: false)
        }
        return ScannerSetupState(
            serviceAvailable: false,
            configured: config.status == .configured,
            needsPassword: config.status == .needsPassword,
            name: config.name,
            ipAddress: config.scannerIP,
            macAddress: config.mac,
            serial: config.serial,
            lastError: config.lastError,
            scannerEnvironment: config.environmentOverrides
        )
    }

    public func discover() async -> ScannerSetupOutcome { .unavailable }
    public func select(deviceID: String) async -> ScannerSetupOutcome { .unavailable }
    public func configureManually(ipAddress: String, macAddress: String, serial: String) async -> ScannerSetupOutcome {
        .unavailable
    }
    public func savePassword(_ password: String) async -> ScannerSetupOutcome { .unavailable }

    public func clear() async -> ScannerSetupOutcome {
        do {
            try await store.clear()
            return .cleared
        } catch {
            return .unavailable
        }
    }
}

public protocol ScanPreviewProviding: Sendable {
    func preview(for sourceURL: URL, outputDirectory: URL) async throws -> Data
}

public struct CompatibleScanPreviewProvider: ScanPreviewProviding {
    public init() {}

    public func preview(for sourceURL: URL, outputDirectory: URL) async throws -> Data {
        let previewDirectory = outputDirectory.appendingPathComponent(PreviewOutputName.directoryName, isDirectory: true)
        let previewURL = previewDirectory.appendingPathComponent("\(sourceURL.lastPathComponent).jpg")
        let fileManager = FileManager.default
        if let previewAttributes = try? fileManager.attributesOfItem(atPath: previewURL.path),
           let sourceAttributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
           let previewDate = previewAttributes[.modificationDate] as? Date,
           let sourceDate = sourceAttributes[.modificationDate] as? Date,
           previewDate >= sourceDate {
            return try Data(contentsOf: previewURL)
        }

        let data = PlaceholderPreview.jpegBytes
        try fileManager.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        try data.write(to: previewURL, options: .atomic)
        return data
    }
}

public struct ScannerServerDependencies: Sendable {
    public let settingsStore: ScanSettingsStore
    public let scanJobs: ScanJobActor
    public let ocrQueue: OCRQueueActor
    public let outputPathResolver: ScanOutputPathResolver
    public let scannerSetup: any ScannerSetupServing
    public let previewProvider: any ScanPreviewProviding
    public let environment: [String: String]

    public init(
        settingsStore: ScanSettingsStore,
        scanJobs: ScanJobActor,
        ocrQueue: OCRQueueActor? = nil,
        outputPathResolver: ScanOutputPathResolver,
        scannerSetup: any ScannerSetupServing,
        previewProvider: any ScanPreviewProviding = CompatibleScanPreviewProvider(),
        environment: [String: String]
    ) {
        self.settingsStore = settingsStore
        self.scanJobs = scanJobs
        self.ocrQueue = ocrQueue ?? OCRQueueActor(executor: FoundationProcessExecutor())
        self.outputPathResolver = outputPathResolver
        self.scannerSetup = scannerSetup
        self.previewProvider = previewProvider
        self.environment = environment
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ScannerServerDependencies {
        let outputDirectory = URL(fileURLWithPath: environment["SCAN_OUTPUT_DIR"] ?? "/scans", isDirectory: true)
        let processExecutor = FoundationProcessExecutor()
        let ocrQueue = OCRQueueActor(executor: processExecutor)
        return ScannerServerDependencies(
            settingsStore: ScanSettingsStore(environment: environment),
            scanJobs: ScanJobActor(executor: processExecutor, ocrQueue: ocrQueue),
            ocrQueue: ocrQueue,
            outputPathResolver: ScanOutputPathResolver(outputDirectory: outputDirectory),
            scannerSetup: ScanSnapSetupService(
                environment: environment,
                store: ScannerConfigStore(environment: environment)
            ),
            previewProvider: NativeScanPreviewProvider(executor: processExecutor),
            environment: environment
        )
    }
}

public enum ScannerServerApplication {
    public static func make(
        configuration: ScannerServerServiceConfiguration
    ) throws -> some ApplicationProtocol {
        try make(configuration: configuration, dependencies: .live())
    }

    public static func make(
        configuration: ScannerServerServiceConfiguration,
        dependencies: ScannerServerDependencies
    ) throws -> some ApplicationProtocol {
        let router = try makeRouter(dependencies: dependencies)
        return Application(
            responder: router.buildResponder(),
            configuration: .init(
                address: .hostname(configuration.hostname, port: configuration.port),
                serverName: ScannerServerCore.productName
            )
        )
    }

    public static func makeRouter(
        dependencies: ScannerServerDependencies
    ) throws -> Router<BasicRequestContext> {
        let indexTemplate = try loadIndexHTML()
        guard indexTemplate.contains("<!-- SCANNER_SERVER_CONTENT -->") else {
            throw ScannerServerConfigurationError.invalidIndexResource
        }
        let router = Router()

        router.get("/") { request, _ -> Response in
            try await indexResponse(request: request, template: indexTemplate, dependencies: dependencies)
        }
        router.get("/health") { _, _ in "ok\n" }

        router.post("/scan") { request, context -> Response in
            let form = try await decodeForm(ModeIDForm.self, request: request, context: context)
            let settings = try await dependencies.settingsStore.load()
            let mode = form.modeID.flatMap(settings.mode(id:)) ?? settings.defaultMode
            let setup = await dependencies.scannerSetup.state()
            let wifiBackend = dependencies.environment["SCAN_BACKEND", default: "wifi"] == "wifi"
            guard !wifiBackend || setup.configured else {
                return redirect(setup: .setupRequired)
            }

            var environment = dependencies.environment
            environment.merge(setup.scannerEnvironment) { _, configured in configured }
            let configuration = ScanPipelineConfiguration(
                environment: environment,
                modeOverrides: mode.environment(trigger: "web")
            )
            _ = await dependencies.scanJobs.start(configuration: configuration)
            return .redirect(to: "/")
        }

        router.post("/modes/default") { request, context -> Response in
            let form = try await decodeForm(ModeIDForm.self, request: request, context: context)
            var settings = try await dependencies.settingsStore.load()
            if let modeID = form.modeID, settings.setDefaultMode(id: modeID) {
                try await dependencies.settingsStore.save(settings)
            }
            return .redirect(to: "/")
        }

        router.post("/modes/save") { request, context -> Response in
            let form = try await decodeForm(ModeSaveForm.self, request: request, context: context)
            var settings = try await dependencies.settingsStore.load()
            let modeSettings = form.modeSettings
            let modeID = settings.saveMode(
                name: form.name ?? "Scan mode",
                settings: modeSettings,
                existingID: form.modeID,
                setDefault: form.setDefault != nil
            )
            try await dependencies.settingsStore.save(settings)
            return .redirect(to: "/?edit_mode=\(urlQueryValue(modeID))")
        }

        router.post("/modes/delete") { request, context -> Response in
            let form = try await decodeForm(ModeIDForm.self, request: request, context: context)
            var settings = try await dependencies.settingsStore.load()
            if let modeID = form.modeID, settings.deleteMode(id: modeID) {
                try await dependencies.settingsStore.save(settings)
            }
            return .redirect(to: "/")
        }

        router.post("/setup/scanners/discover") { _, _ -> Response in
            redirect(setup: await dependencies.scannerSetup.discover())
        }
        router.post("/setup/scanners/select") { request, context -> Response in
            let form = try await decodeForm(ScannerSelectForm.self, request: request, context: context)
            guard let deviceID = form.deviceID, !deviceID.isEmpty else {
                return redirect(setup: .noDevice)
            }
            return redirect(setup: await dependencies.scannerSetup.select(deviceID: deviceID))
        }
        router.post("/setup/scanners/manual") { request, context -> Response in
            let form = try await decodeForm(ScannerManualForm.self, request: request, context: context)
            let ipAddress = form.scannerIP ?? ""
            let macAddress = form.scannerMAC ?? ""
            guard !ipAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !macAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Response.redirect(to: "/?setup=manual-missing")
            }
            return redirect(
                setup: await dependencies.scannerSetup.configureManually(
                    ipAddress: ipAddress,
                    macAddress: macAddress,
                    serial: form.scannerSerial ?? ""
                )
            )
        }
        router.post("/setup/scanners/password") { request, context -> Response in
            let form = try await decodeForm(ScannerPasswordForm.self, request: request, context: context)
            return redirect(setup: await dependencies.scannerSetup.savePassword(form.scannerPassword ?? ""))
        }
        router.post("/setup/scanners/clear") { _, _ -> Response in
            redirect(setup: await dependencies.scannerSetup.clear())
        }

        router.get("/files/:name/preview") { _, context -> Response in
            guard let sourceURL = resolvedFile(context: context, dependencies: dependencies),
                  ["pdf", "png"].contains(sourceURL.pathExtension.lowercased()) else {
                return textResponse("Not found", status: .notFound)
            }
            let data = try await dependencies.previewProvider.preview(
                for: sourceURL,
                outputDirectory: dependencies.outputPathResolver.outputDirectory
            )
            return dataResponse(data, contentType: "image/jpeg")
        }
        router.get("/files/:name") { _, context -> Response in
            fileResponse(context: context, dependencies: dependencies, disposition: "attachment")
        }
        router.get("/view/:name") { _, context -> Response in
            fileResponse(context: context, dependencies: dependencies, disposition: "inline")
        }
        router.post("/files/delete-selected") { request, context -> Response in
            let names = try await decodeRepeatedFormValue(
                named: "files",
                request: request,
                context: context
            )
            for name in names {
                deleteFile(name: name, dependencies: dependencies)
            }
            return .redirect(to: "/")
        }
        router.post("/files/:name/delete") { _, context -> Response in
            if let name = routeName(context: context) {
                deleteFile(name: name, dependencies: dependencies)
            }
            return .redirect(to: "/")
        }

        return router
    }
}

private struct ModeIDForm: Decodable {
    let modeID: String?
    enum CodingKeys: String, CodingKey { case modeID = "mode_id" }
}

private struct ModeSaveForm: Decodable {
    let modeID: String?
    let name: String?
    let language: String?
    let resolution: String?
    let mode: String?
    let source: String?
    let simplex: String?
    let format: String?
    let pageMode: String?
    let ocrEnabled: String?
    let removeBlankPages: String?
    let cropPages: String?
    let setDefault: String?

    enum CodingKeys: String, CodingKey {
        case modeID = "mode_id"
        case name
        case language = "SCAN_LANGUAGE"
        case resolution = "SCAN_RESOLUTION"
        case mode = "SCAN_MODE"
        case source = "SCAN_SOURCE"
        case simplex = "SCAN_SIMPLEX"
        case format = "SCAN_FORMAT"
        case pageMode = "SCAN_PAGE_MODE"
        case ocrEnabled = "SCAN_OCR_ENABLED"
        case removeBlankPages = "SCAN_REMOVE_BLANK_PAGES"
        case cropPages = "SCAN_CROP_PAGES"
        case setDefault = "set_default"
    }

    var modeSettings: ModeSettings {
        let isSimplex = ModeSettings.isTruthy(simplex ?? "false")
        return ModeSettings(values: [
            "SCAN_LANGUAGE": language ?? "",
            "SCAN_RESOLUTION": resolution ?? "",
            "SCAN_MODE": mode ?? "",
            "SCAN_SOURCE": source ?? ModeSettings.source(forSimplex: isSimplex),
            "SCAN_SIMPLEX": simplex ?? "false",
            "SCAN_FORMAT": format ?? "pdf",
            "SCAN_PAGE_MODE": pageMode ?? "multi",
            "SCAN_OCR_ENABLED": ocrEnabled == nil ? "false" : "true",
            "SCAN_REMOVE_BLANK_PAGES": removeBlankPages == nil ? "false" : "true",
            "SCAN_CROP_PAGES": cropPages == nil ? "false" : "true",
        ])
    }
}

private struct ScannerSelectForm: Decodable {
    let deviceID: String?
    enum CodingKeys: String, CodingKey { case deviceID = "device_id" }
}

private struct ScannerManualForm: Decodable {
    let scannerIP: String?
    let scannerMAC: String?
    let scannerSerial: String?
    enum CodingKeys: String, CodingKey {
        case scannerIP = "scanner_ip"
        case scannerMAC = "scanner_mac"
        case scannerSerial = "scanner_serial"
    }
}

private struct ScannerPasswordForm: Decodable {
    let scannerPassword: String?
    enum CodingKeys: String, CodingKey { case scannerPassword = "scanner_password" }
}

private func decodeForm<Form: Decodable>(
    _ type: Form.Type,
    request: Request,
    context: some RequestContext
) async throws -> Form {
    try await URLEncodedFormDecoder().decode(type, from: request, context: context)
}

private func decodeRepeatedFormValue(
    named name: String,
    request: Request,
    context: some RequestContext
) async throws -> [String] {
    let buffer = try await request.body.collect(upTo: context.maxUploadSize)
    var components = URLComponents()
    components.query = String(buffer: buffer)
    return components.queryItems?.filter { $0.name == name }.compactMap(\.value) ?? []
}

private func redirect(setup outcome: ScannerSetupOutcome) -> Response {
    .redirect(to: "/?setup=\(outcome.rawValue)")
}

private func routeName(context: some RequestContext) -> String? {
    context.parameters.get("name")?.removingPercentEncoding
}

private func resolvedFile(
    context: some RequestContext,
    dependencies: ScannerServerDependencies
) -> URL? {
    guard let name = routeName(context: context) else { return nil }
    return try? dependencies.outputPathResolver.resolve(name)
}

private func fileResponse(
    context: some RequestContext,
    dependencies: ScannerServerDependencies,
    disposition: String
) -> Response {
    guard let fileURL = resolvedFile(context: context, dependencies: dependencies),
          let data = try? Data(contentsOf: fileURL) else {
        return textResponse("Not found", status: .notFound)
    }
    return dataResponse(
        data,
        contentType: mediaType(for: fileURL),
        additionalHeaders: [.contentDisposition: "\(disposition); filename=\(fileURL.lastPathComponent)"]
    )
}

private func deleteFile(name: String, dependencies: ScannerServerDependencies) {
    guard let fileURL = try? dependencies.outputPathResolver.resolve(name) else { return }
    let previewURL = dependencies.outputPathResolver.outputDirectory
        .appendingPathComponent(PreviewOutputName.directoryName, isDirectory: true)
        .appendingPathComponent("\(fileURL.lastPathComponent).jpg")
    try? FileManager.default.removeItem(at: previewURL)
    try? FileManager.default.removeItem(at: fileURL)
}

private func mediaType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "pdf": "application/pdf"
    case "png": "image/png"
    default: "application/octet-stream"
    }
}

private func dataResponse(
    _ data: Data,
    status: HTTPResponse.Status = .ok,
    contentType: String,
    additionalHeaders: HTTPFields = [:]
) -> Response {
    let buffer = ByteBuffer(bytes: data)
    var headers = additionalHeaders
    headers[.contentType] = contentType
    headers[.contentLength] = "\(buffer.readableBytes)"
    return Response(status: status, headers: headers, body: .init(byteBuffer: buffer))
}

private func textResponse(_ text: String, status: HTTPResponse.Status) -> Response {
    dataResponse(Data(text.utf8), status: status, contentType: "text/plain; charset=utf-8")
}

private func indexResponse(
    request: Request,
    template: String,
    dependencies: ScannerServerDependencies
) async throws -> Response {
    try FileManager.default.createDirectory(
        at: dependencies.outputPathResolver.outputDirectory,
        withIntermediateDirectories: true
    )
    let wifiBackend = dependencies.environment["SCAN_BACKEND", default: "wifi"] == "wifi"
    if wifiBackend {
        await dependencies.scannerSetup.ensureDiscoveryStarted()
    }
    let settings = try await dependencies.settingsStore.load()
    let job = await dependencies.scanJobs.state
    let ocr = await dependencies.ocrQueue.state
    let setup = await dependencies.scannerSetup.state()
    let query = queryValues(request.uri.query)
    let groups = scanFileGroups(outputDirectory: dependencies.outputPathResolver.outputDirectory)
    let content = renderIndexContent(
        settings: settings,
        editModeID: query["edit_mode"],
        setupMessageCode: query["setup"],
        setup: setup,
        wifiBackend: wifiBackend,
        job: job,
        ocr: ocr,
        groups: groups
    )
    let html = template.replacingOccurrences(of: "<!-- SCANNER_SERVER_CONTENT -->", with: content)
    return dataResponse(Data(html.utf8), contentType: "text/html; charset=utf-8")
}

private func scanFileGroups(outputDirectory: URL) -> [ScanDayGroup] {
    guard let urls = try? FileManager.default.contentsOfDirectory(
        at: outputDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    let files = urls.compactMap { url -> ScanFile? in
        guard let name = try? ScanOutputFileName(rawValue: url.lastPathComponent),
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return ScanFile(name: name, modificationDate: values.contentModificationDate ?? .distantPast)
    }
    return ScanFileGrouping.groups(for: files)
}

private func renderIndexContent(
    settings: ScanSettings,
    editModeID: String?,
    setupMessageCode: String?,
    setup: ScannerSetupState,
    wifiBackend: Bool,
    job: ScanJobState,
    ocr: OCRQueueState,
    groups: [ScanDayGroup]
) -> String {
    let selectedMode: ScanMode
    if editModeID == "new" {
        selectedMode = ScanMode(id: "", name: "", settings: settings.defaultMode.settings)
    } else {
        selectedMode = editModeID.flatMap(settings.mode(id:)) ?? settings.defaultMode
    }

    var html = "<div class=\"page-head\"><h1>scannerserver</h1></div>"
    if let message = setupMessage(setupMessageCode) {
        html += "<p class=\"notice\">\(htmlEscape(message))</p>"
    }
    if wifiBackend {
        html += renderScannerSetup(setup)
    }

    if !wifiBackend || setup.configured {
        html += "<section><h2>Scan</h2><form method=\"post\" action=\"/scan\">"
        html += "<label>Scan mode<select name=\"mode_id\">"
        for mode in settings.modes {
            let selected = mode.id == settings.defaultModeID ? " selected" : ""
            let suffix = mode.id == settings.defaultModeID ? " (button)" : ""
            html += "<option value=\"\(htmlEscape(mode.id))\"\(selected)>\(htmlEscape(mode.name + suffix))</option>"
        }
        html += "</select></label><div class=\"button-row\">"
        html += "<button\(job.status == "running" ? " disabled" : "")>Start scan</button>"
        html += "<button class=\"secondary-button\" formaction=\"/modes/default\">Use for button</button>"
        html += "</div></form></section>"
        html += renderModes(settings: settings, selectedMode: selectedMode, open: editModeID != nil)
        html += renderStatus(job: job, ocr: ocr)
        html += renderFiles(groups)
    }
    return html
}

private func renderScannerSetup(_ setup: ScannerSetupState) -> String {
    var html = "<section><h2>Scanner setup</h2>"
    if setup.configured {
        html += "<p><strong>\(htmlEscape(setup.name))</strong> <span class=\"status\">configured</span></p>"
        html += "<p class=\"muted\">IP \(htmlEscape(setup.ipAddress))"
        if !setup.serial.isEmpty { html += " · Serial \(htmlEscape(setup.serial))" }
        if !setup.macAddress.isEmpty { html += " · MAC \(htmlEscape(setup.macAddress))" }
        html += "</p>"
    } else {
        html += "<p>Choose the network scanner before scanning.</p>"
    }
    if !setup.serviceAvailable {
        html += "<p class=\"warning\">Live scanner discovery and pairing are not available in this build.</p>"
    }
    if !setup.lastError.isEmpty { html += "<pre>\(htmlEscape(setup.lastError))</pre>" }
    html += "<div class=\"setup-controls\"><form method=\"post\" action=\"/setup/scanners/discover\"><button>Discover scanners</button></form>"
    if !setup.devices.isEmpty {
        html += "<form method=\"post\" action=\"/setup/scanners/select\"><div class=\"device-list\">"
        for device in setup.devices {
            html += "<label><input type=\"radio\" name=\"device_id\" value=\"\(htmlEscape(device.id))\"> \(htmlEscape(device.name)) \(htmlEscape(device.ipAddress))</label>"
        }
        html += "</div><button>Use selected scanner</button></form>"
    }
    html += "<form method=\"post\" action=\"/setup/scanners/manual\">"
    html += "<label>Scanner IP<input name=\"scanner_ip\" value=\"\(htmlEscape(setup.ipAddress))\"></label>"
    html += "<label>Ethernet address<input name=\"scanner_mac\"></label>"
    html += "<label>Serial<input name=\"scanner_serial\"></label><button>Continue setup</button></form>"
    if setup.needsPassword {
        html += "<form method=\"post\" action=\"/setup/scanners/password\"><label>Scanner password<input type=\"password\" name=\"scanner_password\"></label><button>Save password</button></form>"
    }
    html += "<form method=\"post\" action=\"/setup/scanners/clear\"><button class=\"danger-button\">Clear scanner setup</button></form></div></section>"
    return html
}

private func renderModes(settings: ScanSettings, selectedMode: ScanMode, open: Bool) -> String {
    var html = "<section><details\(open ? " open" : "")><summary>Advanced settings</summary><ul class=\"mode-list\">"
    for mode in settings.modes {
        let badge = mode.id == settings.defaultModeID ? " <span class=\"default-badge\">button</span>" : ""
        html += "<li><strong>\(htmlEscape(mode.name))</strong>\(badge)<div class=\"muted\">\(htmlEscape(modeSummary(mode)))</div></li>"
    }
    html += "</ul><form method=\"get\" action=\"/\"><label>Edit mode<select name=\"edit_mode\">"
    for mode in settings.modes {
        html += option(value: mode.id, label: mode.name, selected: mode.id == selectedMode.id)
    }
    html += option(value: "new", label: "New mode", selected: selectedMode.id.isEmpty)
    html += "</select></label><button class=\"secondary-button\">Load</button></form>"
    html += "<form class=\"stack-form\" method=\"post\" action=\"/modes/save\">"
    html += "<input type=\"hidden\" name=\"mode_id\" value=\"\(htmlEscape(selectedMode.id))\"><div class=\"settings-grid\">"
    html += "<label>Name<input name=\"name\" value=\"\(htmlEscape(selectedMode.name))\"></label>"
    html += select(name: "SCAN_SIMPLEX", label: "Sides", values: [("false", "Duplex"), ("true", "Simplex")], selected: selectedMode.settings.simplexText)
    html += select(name: "SCAN_FORMAT", label: "Output", values: [("pdf", "PDF"), ("png", "PNG pages")], selected: selectedMode.settings.format)
    html += select(name: "SCAN_PAGE_MODE", label: "Pages", values: [("multi", "Multipage file"), ("single", "One file per page")], selected: selectedMode.settings.pageMode)
    html += select(name: "SCAN_RESOLUTION", label: "Resolution", values: ["200", "300", "400", "600"].map { ($0, "\($0) dpi") }, selected: selectedMode.settings.resolution)
    html += select(name: "SCAN_MODE", label: "Color mode", values: ["Color", "Gray", "Lineart"].map { ($0, $0) }, selected: selectedMode.settings.mode)
    html += "<label>OCR language<input name=\"SCAN_LANGUAGE\" value=\"\(htmlEscape(selectedMode.settings.language))\"></label></div>"
    html += "<div class=\"checkbox-grid\">"
    html += checkbox(name: "SCAN_OCR_ENABLED", label: "OCR", checked: selectedMode.settings.ocrEnabled)
    html += checkbox(name: "SCAN_CROP_PAGES", label: "Autocrop", checked: selectedMode.settings.cropPages)
    html += checkbox(name: "SCAN_REMOVE_BLANK_PAGES", label: "Remove blanks", checked: selectedMode.settings.removeBlankPages)
    html += checkbox(name: "set_default", label: "Button default", checked: selectedMode.id == settings.defaultModeID)
    html += "</div><div class=\"button-row\"><button>Save mode</button>"
    if !selectedMode.id.isEmpty {
        html += "<button class=\"danger-button\" formaction=\"/modes/delete\">Delete mode</button>"
    }
    html += "</div></form></details></section>"
    return html
}

private func renderStatus(job: ScanJobState, ocr: OCRQueueState) -> String {
    var html = "<section><h2>Status</h2><p><span class=\"status\">\(htmlEscape(job.status))</span></p>"
    if let started = job.started { html += "<p>Started: \(htmlEscape(timestamp(started)))</p>" }
    if let finished = job.finished { html += "<p>Finished: \(htmlEscape(timestamp(finished)))</p>" }
    if !job.output.isEmpty { html += "<pre>\(htmlEscape(job.output))</pre>" }
    if !job.error.isEmpty { html += "<pre>\(htmlEscape(job.error))</pre>" }

    html += "<h2>OCR</h2><p><span class=\"status\">\(htmlEscape(ocr.status))</span>"
    if ocr.queued > 0 { html += " \(ocr.queued) queued" }
    html += "</p>"
    if let started = ocr.started { html += "<p>Started: \(htmlEscape(timestamp(started)))</p>" }
    if let finished = ocr.finished { html += "<p>Finished: \(htmlEscape(timestamp(finished)))</p>" }
    if !ocr.input.isEmpty { html += "<p>Input: \(htmlEscape(ocr.input))</p>" }
    if !ocr.output.isEmpty { html += "<pre>\(htmlEscape(ocr.output))</pre>" }
    if !ocr.error.isEmpty { html += "<pre>\(htmlEscape(ocr.error))</pre>" }
    return html + "</section>"
}

private func renderFiles(_ groups: [ScanDayGroup]) -> String {
    var html = "<section><h2>Files</h2>"
    guard !groups.isEmpty else { return html + "<p>No scans yet.</p></section>" }
    html += "<form method=\"post\" action=\"/files/delete-selected\"><button class=\"danger-button\">Delete selected</button><div class=\"file-groups\">"
    for group in groups {
        html += "<div><h3>\(htmlEscape(group.day))</h3><ul class=\"file-list\">"
        for document in group.files {
            let viewPath = urlPathComponent(document.viewName)
            let previewPath = urlPathComponent(document.previewName)
            html += "<li class=\"file-row\"><a href=\"/view/\(viewPath)\" target=\"_blank\"><img class=\"file-preview\" src=\"/files/\(previewPath)/preview\" alt=\"\"></a><div>"
            html += "<strong>\(htmlEscape(document.title))</strong>"
            for file in document.files {
                let path = urlPathComponent(file.name)
                html += "<div class=\"file-variant\"><input type=\"checkbox\" name=\"files\" value=\"\(htmlEscape(file.name))\">"
                html += "<a href=\"/files/\(path)\">\(htmlEscape(file.kind.label))</a> <span class=\"file-name\">\(htmlEscape(file.name))</span>"
                html += "<button class=\"danger-button\" formaction=\"/files/\(path)/delete\">Delete</button></div>"
            }
            html += "</div></li>"
        }
        html += "</ul></div>"
    }
    return html + "</div></form></section>"
}

private func modeSummary(_ mode: ScanMode) -> String {
    let value = mode.settings
    let sides = value.simplex ? "Simplex" : "Duplex"
    let output = value.format == "png" ? "PNG pages" : "PDF"
    let pages = value.pageMode == "single" ? "single pages" : "multipage"
    let ocr = value.ocrEnabled ? "OCR on" : "OCR off"
    let crop = value.cropPages ? "autocrop on" : "autocrop off"
    return "\(sides), \(output), \(pages), \(ocr), \(crop), \(value.resolution) dpi \(value.mode)"
}

private func option(value: String, label: String, selected: Bool) -> String {
    "<option value=\"\(htmlEscape(value))\"\(selected ? " selected" : "")>\(htmlEscape(label))</option>"
}

private func select(name: String, label: String, values: [(String, String)], selected: String) -> String {
    "<label>\(htmlEscape(label))<select name=\"\(htmlEscape(name))\">"
        + values.map { option(value: $0.0, label: $0.1, selected: $0.0 == selected) }.joined()
        + "</select></label>"
}

private func checkbox(name: String, label: String, checked: Bool) -> String {
    "<label><input type=\"checkbox\" name=\"\(htmlEscape(name))\"\(checked ? " checked" : "")> \(htmlEscape(label))</label>"
}

private func setupMessage(_ code: String?) -> String? {
    switch code {
    case "discovery-started": "Scanner discovery started."
    case "no-device": "Choose a discovered scanner."
    case "manual-missing": "Enter a scanner IP address or Ethernet address."
    case "manual-not-found": "No scanner matching those details was found."
    case "manual-invalid": "The scanner details are invalid."
    case "password-needed": "Enter the scanner password to finish setup."
    case "password-failed": "The scanner password was rejected."
    case "configured": "Scanner configured."
    case "cleared": "Scanner setup cleared."
    case "setup-required": "Choose a Wi-Fi scanner before starting a scan."
    case "unavailable": "Live scanner setup is unavailable in this build."
    default: nil
    }
}

private func queryValues(_ query: String?) -> [String: String] {
    guard let query else { return [:] }
    var components = URLComponents()
    components.query = query
    var values: [String: String] = [:]
    for item in components.queryItems ?? [] {
        if let value = item.value, values[item.name] == nil {
            values[item.name] = value
        }
    }
    return values
}

private func htmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

private func urlPathComponent(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
}

private func urlQueryValue(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+#")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
}

private func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func loadIndexHTML() throws -> String {
    guard let url = Bundle.module.url(forResource: "index", withExtension: "html") else {
        throw ScannerServerConfigurationError.missingIndexResource
    }
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
        throw ScannerServerConfigurationError.unreadableIndexResource
    }
    return contents
}
