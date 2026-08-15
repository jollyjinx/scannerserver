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

private struct ScannerSetupPollingState: Encodable {
    let serviceAvailable: Bool
    let discoveryInProgress: Bool
    let configured: Bool
    let needsPassword: Bool
    let lastError: String
    let devices: [ScannerSetupPollingDevice]
}

private struct ScannerSetupPollingDevice: Encodable {
    let id: String
    let name: String
    let ipAddress: String
    let macAddress: String
    let serial: String

    init(_ device: ScannerSetupDevice) {
        id = device.id
        name = device.name
        ipAddress = device.ipAddress
        macAddress = device.macAddress
        serial = device.serial
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
    func discoveryInProgress() async -> Bool
    func ensureDiscoveryStarted() async
    func shutdown() async
    func discover() async -> ScannerSetupOutcome
    func select(deviceID: String) async -> ScannerSetupOutcome
    func configureManually(ipAddress: String, credential: String) async -> ScannerSetupOutcome
    func clear() async -> ScannerSetupOutcome
}

public extension ScannerSetupServing {
    func discoveryInProgress() async -> Bool { false }
    func ensureDiscoveryStarted() async {}
    func shutdown() async {}
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
    public func configureManually(ipAddress: String, credential: String) async -> ScannerSetupOutcome { .unavailable }

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
    public let scannerStore: ScannerConfigStore
    public let scanJobs: ScanJobActor
    public let scanSnapAcquisitionSessions: ScanSnapAcquisitionSessionCoordinator
    public let ocrQueue: OCRQueueActor
    public let ocrWorkerRegistry: OCRWorkerRegistry
    public let ocrWorkerJobs: OCRWorkerJobStore
    public let outputPathResolver: ScanOutputPathResolver
    public let scannerSetup: any ScannerSetupServing
    public let previewProvider: any ScanPreviewProviding
    public let webUpdates: WebUpdateNotifier
    public let scannerReachability: ScanSnapReachabilityState
    public let environment: [String: String]
    public let buttonConfigurationChanges: ScanSnapButtonConfigurationChangeCoordinator?
    public let scanDirectoryAccessIssue: ScanDirectoryAccessIssue?

    public init(
        settingsStore: ScanSettingsStore,
        scannerStore: ScannerConfigStore? = nil,
        scanJobs: ScanJobActor,
        scanSnapAcquisitionSessions: ScanSnapAcquisitionSessionCoordinator = ScanSnapAcquisitionSessionCoordinator(),
        ocrQueue: OCRQueueActor? = nil,
        ocrWorkerRegistry: OCRWorkerRegistry? = nil,
        ocrWorkerJobs: OCRWorkerJobStore? = nil,
        outputPathResolver: ScanOutputPathResolver,
        scannerSetup: any ScannerSetupServing,
        previewProvider: any ScanPreviewProviding = CompatibleScanPreviewProvider(),
        webUpdates: WebUpdateNotifier? = nil,
        scannerReachability: ScanSnapReachabilityState? = nil,
        environment: [String: String],
        buttonConfigurationChanges: ScanSnapButtonConfigurationChangeCoordinator? = nil
    ) {
        self.settingsStore = settingsStore
        self.scannerStore = scannerStore ?? ScannerConfigStore(environment: environment)
        self.scanJobs = scanJobs
        self.scanSnapAcquisitionSessions = scanSnapAcquisitionSessions
        self.ocrQueue = ocrQueue ?? OCRQueueActor(
            executor: FoundationProcessExecutor(),
            configuration: OCRQueueConfiguration(environment: environment)
        )
        self.outputPathResolver = outputPathResolver
        self.scannerSetup = scannerSetup
        self.previewProvider = previewProvider
        let webUpdates = webUpdates ?? scanJobs.webUpdates
        self.webUpdates = webUpdates
        self.ocrWorkerRegistry = ocrWorkerRegistry ?? OCRWorkerRegistry(
            fileURL: OCRWorkerRegistry.defaultFileURL(environment: environment),
            webUpdates: webUpdates
        )
        self.ocrWorkerJobs = ocrWorkerJobs ?? OCRWorkerJobStore(
            fileURL: OCRWorkerJobStore.defaultFileURL(environment: environment)
        )
        self.scannerReachability = scannerReachability ?? ScanSnapReachabilityState(webUpdates: webUpdates)
        self.environment = environment
        self.buttonConfigurationChanges = buttonConfigurationChanges
        self.scanDirectoryAccessIssue = ScanDirectoryAccessIssue.check(
            directory: outputPathResolver.outputDirectory
        )
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ScannerServerDependencies {
        let outputDirectory = URL(fileURLWithPath: environment["SCAN_OUTPUT_DIR"] ?? "/scans", isDirectory: true)
        let processExecutor = FoundationProcessExecutor()
        let documentExecutor = NativeDocumentToolExecutor(executor: processExecutor)
        let webUpdates = WebUpdateNotifier()
        let ocrQueue = OCRQueueActor(
            executor: processExecutor,
            configuration: OCRQueueConfiguration(environment: environment),
            webUpdates: webUpdates
        )
        let ocrWorkerRegistry = OCRWorkerRegistry(
            fileURL: OCRWorkerRegistry.defaultFileURL(environment: environment),
            webUpdates: webUpdates
        )
        let settingsStore = ScanSettingsStore(environment: environment)
        let scannerStore = ScannerConfigStore(environment: environment)
        let buttonConfigurationChanges = ScanSnapButtonConfigurationChangeCoordinator()
        let scannerReachability = ScanSnapReachabilityState(webUpdates: webUpdates)
        let scanSnapAcquisitionSessions = ScanSnapAcquisitionSessionCoordinator()
        return ScannerServerDependencies(
            settingsStore: settingsStore,
            scannerStore: scannerStore,
            scanJobs: ScanJobActor(
                nativeScanner: NativeScanPipeline(
                    executor: documentExecutor,
                    acquisitionSessions: scanSnapAcquisitionSessions
                ),
                ocrQueue: ocrQueue,
                webUpdates: webUpdates
            ),
            scanSnapAcquisitionSessions: scanSnapAcquisitionSessions,
            ocrQueue: ocrQueue,
            ocrWorkerRegistry: ocrWorkerRegistry,
            outputPathResolver: ScanOutputPathResolver(outputDirectory: outputDirectory),
            scannerSetup: ScanSnapSetupService(
                environment: environment,
                store: scannerStore,
                configurationChangeNotifier: buttonConfigurationChanges
            ),
            previewProvider: NativeScanPreviewProvider(executor: processExecutor),
            webUpdates: webUpdates,
            scannerReachability: scannerReachability,
            environment: environment,
            buttonConfigurationChanges: buttonConfigurationChanges
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
        guard indexTemplate.contains("<!-- SCANNER_SERVER_CONTENT -->"),
              indexTemplate.contains("<!-- SCANNER_SERVER_VERSION -->") else {
            throw ScannerServerConfigurationError.invalidIndexResource
        }
        let buildInformation = ScannerServerBuildInformation(environment: dependencies.environment)
        let router = Router()

        router.get("/") { request, _ in
            await webPageResponse(
                request: request,
                page: .scan,
                template: indexTemplate,
                dependencies: dependencies,
                buildInformation: buildInformation
            )
        }
        router.get("/documents") { request, _ in
            await webPageResponse(
                request: request,
                page: .documents,
                template: indexTemplate,
                dependencies: dependencies,
                buildInformation: buildInformation
            )
        }
        router.get("/presets") { request, _ in
            await webPageResponse(
                request: request,
                page: .presets,
                template: indexTemplate,
                dependencies: dependencies,
                buildInformation: buildInformation
            )
        }
        router.get("/settings") { request, _ in
            await webPageResponse(
                request: request,
                page: .settings,
                template: indexTemplate,
                dependencies: dependencies,
                buildInformation: buildInformation
            )
        }
        router.get("/workers") { request, _ in
            await webPageResponse(
                request: request,
                page: .workers,
                template: indexTemplate,
                dependencies: dependencies,
                buildInformation: buildInformation
            )
        }
        router.get("/health") { _, _ in "ok\n" }
        router.get("/version") { _, _ in "\(buildInformation.version)\n" }
        router.get("/updates") { request, _ -> Response in
            let value = queryValues(request.uri.query)["since"] ?? ""
            guard let since = UInt64(value) else {
                return textResponse("Invalid revision\n", status: .badRequest)
            }
            let revision = await dependencies.webUpdates.wait(after: since)
            return dataResponse(
                Data("\(revision)\n".utf8),
                contentType: "text/plain; charset=utf-8",
                additionalHeaders: [.cacheControl: "no-store"]
            )
        }

        router.post("/scan") { request, context -> Response in
            let form = try await decodeForm(ModeIDForm.self, request: request, context: context)
            let settings = try await dependencies.settingsStore.load()
            let mode = form.modeID.flatMap(settings.mode(id:)) ?? settings.defaultMode
            let setup = await dependencies.scannerSetup.state()
            let wifiBackend = dependencies.environment["SCAN_BACKEND", default: "wifi"] == "wifi"
            guard !wifiBackend || setup.configured else {
                return redirect(setup: .setupRequired, to: "/settings")
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
        router.post("/scan/cancel") { _, _ -> Response in
            await dependencies.scanJobs.cancel()
            return .redirect(to: "/")
        }
        router.post("/ocr/cancel") { _, _ -> Response in
            await dependencies.ocrQueue.cancelAll()
            return .redirect(to: "/")
        }

        router.get("/api/ocr-workers") { _, _ -> Response in
            jsonResponse(await dependencies.ocrWorkerRegistry.snapshots())
        }
        router.post("/api/ocr-workers/register") { request, context -> Response in
            do {
                let registration = try await decodeJSON(
                    OCRWorkerRegistrationRequest.self,
                    request: request,
                    context: context
                )
                return jsonResponse(try await dependencies.ocrWorkerRegistry.register(registration))
            } catch {
                return workerAPIErrorResponse(error)
            }
        }
        router.post("/api/ocr-workers/:id/heartbeat") { request, context -> Response in
            guard let workerID = workerID(context: context) else {
                return textResponse("Missing worker ID\n", status: .badRequest)
            }
            do {
                let heartbeat = try await decodeJSON(
                    OCRWorkerHeartbeatRequest.self,
                    request: request,
                    context: context
                )
                return jsonResponse(try await dependencies.ocrWorkerRegistry.heartbeat(
                    workerID: workerID,
                    request: heartbeat
                ))
            } catch {
                return workerAPIErrorResponse(error)
            }
        }
        router.post("/workers/:id/approve") { _, context -> Response in
            if let workerID = workerID(context: context) {
                _ = try? await dependencies.ocrWorkerRegistry.approve(workerID: workerID)
            }
            return .redirect(to: "/workers")
        }
        router.post("/workers/:id/enable") { _, context -> Response in
            if let workerID = workerID(context: context) {
                _ = try? await dependencies.ocrWorkerRegistry.setEnabled(true, workerID: workerID)
            }
            return .redirect(to: "/workers")
        }
        router.post("/workers/:id/disable") { _, context -> Response in
            if let workerID = workerID(context: context) {
                _ = try? await dependencies.ocrWorkerRegistry.setEnabled(false, workerID: workerID)
            }
            return .redirect(to: "/workers")
        }

        router.post("/modes/default") { request, context -> Response in
            let form = try await decodeForm(ModeIDForm.self, request: request, context: context)
            try await dependencies.settingsStore.setDefaultMode(id: form.modeID)
            return .redirect(to: "/presets")
        }

        router.post("/modes/save") { request, context -> Response in
            let form = try await decodeForm(ModeSaveForm.self, request: request, context: context)
            let modeSettings = form.modeSettings
            let modeID = try await dependencies.settingsStore.saveMode(
                name: form.name ?? "Scan mode",
                settings: modeSettings,
                existingID: form.modeID,
                setDefault: form.setDefault != nil
            )
            return .redirect(to: "/presets?edit_mode=\(urlQueryValue(modeID))")
        }

        router.post("/modes/delete") { request, context -> Response in
            let form = try await decodeForm(ModeIDForm.self, request: request, context: context)
            try await dependencies.settingsStore.deleteMode(id: form.modeID)
            return .redirect(to: "/presets")
        }

        router.post("/setup/scanners/discover") { _, _ -> Response in
            redirect(setup: await dependencies.scannerSetup.discover(), to: "/settings")
        }
        router.get("/setup/scanners/state") { _, _ -> Response in
            await dependencies.scannerSetup.ensureDiscoveryStarted()
            let state = await dependencies.scannerSetup.state()
            let payload = ScannerSetupPollingState(
                serviceAvailable: state.serviceAvailable,
                discoveryInProgress: await dependencies.scannerSetup.discoveryInProgress(),
                configured: state.configured,
                needsPassword: state.needsPassword,
                lastError: state.lastError,
                devices: state.devices.map(ScannerSetupPollingDevice.init)
            )
            return dataResponse(
                try JSONEncoder().encode(payload),
                contentType: "application/json; charset=utf-8",
                additionalHeaders: [.cacheControl: "no-store"]
            )
        }
        router.post("/setup/scanners/select") { request, context -> Response in
            let form = try await decodeForm(ScannerSelectForm.self, request: request, context: context)
            guard let deviceID = form.deviceID, !deviceID.isEmpty else {
                return redirect(setup: .noDevice, to: "/settings")
            }
            return redirect(setup: await dependencies.scannerSetup.select(deviceID: deviceID), to: "/settings")
        }
        router.post("/setup/scanners/manual") { request, context -> Response in
            let form = try await decodeForm(ScannerManualForm.self, request: request, context: context)
            let ipAddress = form.scannerIP ?? ""
            let credential = form.scannerCredential ?? ""
            guard !ipAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Response.redirect(to: "/settings?setup=manual-missing")
            }
            return redirect(
                setup: await dependencies.scannerSetup.configureManually(
                    ipAddress: ipAddress,
                    credential: credential
                ),
                to: "/settings"
            )
        }
        router.post("/setup/scanners/clear") { _, _ -> Response in
            redirect(setup: await dependencies.scannerSetup.clear(), to: "/settings")
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
                await deleteFile(name: name, dependencies: dependencies)
            }
            return .redirect(to: "/documents")
        }
        router.post("/files/:name/delete") { _, context -> Response in
            if let name = routeName(context: context) {
                await deleteFile(name: name, dependencies: dependencies)
            }
            return .redirect(to: "/documents")
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
    let ocrCPULimit: String?
    let ocrNice: String?
    let removeBlankPages: String?
    let cropPages: String?
    let cropMarginPoints: String?
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
        case ocrCPULimit = "SCAN_OCR_CPU_LIMIT"
        case ocrNice = "SCAN_OCR_NICE"
        case removeBlankPages = "SCAN_REMOVE_BLANK_PAGES"
        case cropPages = "SCAN_CROP_PAGES"
        case cropMarginPoints = "SCAN_CROP_MARGIN_POINTS"
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
            "SCAN_OCR_CPU_LIMIT": ocrCPULimit ?? "",
            "SCAN_OCR_NICE": ocrNice ?? "false",
            "SCAN_REMOVE_BLANK_PAGES": removeBlankPages == nil ? "false" : "true",
            "SCAN_CROP_PAGES": cropPages == nil ? "false" : "true",
            "SCAN_CROP_MARGIN_POINTS": cropMarginPoints ?? "",
        ])
    }
}

private struct ScannerSelectForm: Decodable {
    let deviceID: String?
    enum CodingKeys: String, CodingKey { case deviceID = "device_id" }
}

private struct ScannerManualForm: Decodable {
    let scannerIP: String?
    let scannerCredential: String?
    enum CodingKeys: String, CodingKey {
        case scannerIP = "scanner_ip"
        case scannerCredential = "scanner_credential"
    }
}

private func decodeForm<Form: Decodable>(
    _ type: Form.Type,
    request: Request,
    context: some RequestContext
) async throws -> Form {
    try await URLEncodedFormDecoder().decode(type, from: request, context: context)
}

private func decodeJSON<Value: Decodable>(
    _ type: Value.Type,
    request: Request,
    context: some RequestContext
) async throws -> Value {
    let buffer = try await request.body.collect(upTo: context.maxUploadSize)
    return try JSONDecoder().decode(type, from: Data(buffer.readableBytesView))
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

private func redirect(setup outcome: ScannerSetupOutcome, to path: String = "/") -> Response {
    .redirect(to: "\(path)?setup=\(outcome.rawValue)")
}

private func routeName(context: some RequestContext) -> String? {
    context.parameters.get("name")?.removingPercentEncoding
}

private func workerID(context: some RequestContext) -> String? {
    context.parameters.get("id")?.removingPercentEncoding
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

private func deleteFile(name: String, dependencies: ScannerServerDependencies) async {
    guard let fileURL = try? dependencies.outputPathResolver.resolve(name) else { return }
    await dependencies.ocrQueue.cancelJobs(referencing: fileURL.path)
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

private struct WorkerAPIError: Encodable {
    let error: String
}

private func jsonResponse<Value: Encodable>(
    _ value: Value,
    status: HTTPResponse.Status = .ok
) -> Response {
    do {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return dataResponse(
            try encoder.encode(value),
            status: status,
            contentType: "application/json; charset=utf-8",
            additionalHeaders: [.cacheControl: "no-store"]
        )
    } catch {
        return textResponse("Could not encode response\n", status: .internalServerError)
    }
}

private func workerAPIErrorResponse(_ error: any Error) -> Response {
    let status: HTTPResponse.Status
    if let registryError = error as? OCRWorkerRegistryError,
       registryError == .authenticationFailed {
        status = .unauthorized
    } else {
        status = .badRequest
    }
    return jsonResponse(
        WorkerAPIError(error: error.localizedDescription),
        status: status
    )
}

private func scanDirectoryErrorResponse(
    template: String,
    issue: ScanDirectoryAccessIssue,
    buildInformation: ScannerServerBuildInformation
) -> Response {
    let content = """
    <section>
      <h2>Scan directory is not accessible</h2>
      <p class="warning">scannerserver is incorrectly configured and cannot read and write its scan directory.</p>
      <p>Configured <code>SCAN_OUTPUT_DIR</code>:</p>
      <pre>\(htmlEscape(issue.directoryPath))</pre>
      <p>Check that the directory is mounted into the container and that the container user can create, read, update, and delete files in it. Refresh this page after correcting the configuration or permissions.</p>
      <p class="muted">Access check: \(htmlEscape(issue.details))</p>
    </section>
    """
    let html = template
        .replacingOccurrences(of: "<!-- SCANNER_SERVER_REFRESH -->", with: "")
        .replacingOccurrences(of: "SCANNER_SERVER_REVISION", with: "0")
        .replacingOccurrences(
            of: "<!-- SCANNER_SERVER_VERSION -->",
            with: htmlEscape(buildInformation.version)
        )
        .replacingOccurrences(of: "<!-- SCANNER_SERVER_CONTENT -->", with: content)
    return dataResponse(
        Data(html.utf8),
        status: .serviceUnavailable,
        contentType: "text/html; charset=utf-8",
        additionalHeaders: [.cacheControl: "no-store"]
    )
}

private enum ScannerServerPage: String, CaseIterable {
    case scan
    case documents
    case presets
    case workers
    case settings

    var path: String {
        switch self {
        case .scan: "/"
        default: "/\(rawValue)"
        }
    }

    var label: String { rawValue.capitalized }
}

private func webPageResponse(
    request: Request,
    page: ScannerServerPage,
    template: String,
    dependencies: ScannerServerDependencies,
    buildInformation: ScannerServerBuildInformation
) async -> Response {
    if let issue = ScanDirectoryAccessIssue.check(
        directory: dependencies.outputPathResolver.outputDirectory
    ) {
        return scanDirectoryErrorResponse(
            template: template,
            issue: issue,
            buildInformation: buildInformation
        )
    }
    do {
        return try await indexResponse(
            request: request,
            page: page,
            template: template,
            dependencies: dependencies,
            buildInformation: buildInformation
        )
    } catch {
        return scanDirectoryErrorResponse(
            template: template,
            issue: ScanDirectoryAccessIssue(
                directoryPath: dependencies.outputPathResolver.outputDirectory.path,
                details: error.localizedDescription
            ),
            buildInformation: buildInformation
        )
    }
}

private func indexResponse(
    request: Request,
    page: ScannerServerPage,
    template: String,
    dependencies: ScannerServerDependencies,
    buildInformation: ScannerServerBuildInformation
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
    let workers = await dependencies.ocrWorkerRegistry.snapshots()
    let setup = await dependencies.scannerSetup.state()
    let scannerIsReachable = await dependencies.scannerReachability.isReachable
    let localTime = ScannerServerLocalTime(environment: dependencies.environment)
    let query = queryValues(request.uri.query)
    let webRevision = await dependencies.webUpdates.currentRevision
    let groups = scanFileGroups(
        outputDirectory: dependencies.outputPathResolver.outputDirectory,
        timeZone: localTime.timeZone
    )
    let content = renderIndexContent(
        page: page,
        settings: settings,
        editModeID: query["edit_mode"],
        setupMessageCode: query["setup"],
        setup: setup,
        scannerIsReachable: scannerIsReachable,
        wifiBackend: wifiBackend,
        job: job,
        ocr: ocr,
        workers: workers,
        groups: groups,
        localTime: localTime
    )
    let refresh = page == .workers ? "<meta http-equiv=\"refresh\" content=\"10\">" : ""
    let html = template
        .replacingOccurrences(of: "<!-- SCANNER_SERVER_REFRESH -->", with: refresh)
        .replacingOccurrences(of: "SCANNER_SERVER_REVISION", with: "\(webRevision)")
        .replacingOccurrences(
            of: "<!-- SCANNER_SERVER_VERSION -->",
            with: htmlEscape(buildInformation.version)
        )
        .replacingOccurrences(of: "<!-- SCANNER_SERVER_CONTENT -->", with: content)
    return dataResponse(Data(html.utf8), contentType: "text/html; charset=utf-8")
}

private func scanFileGroups(outputDirectory: URL, timeZone: TimeZone) -> [ScanDayGroup] {
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
    return ScanFileGrouping.groups(for: files, timeZone: timeZone)
}

private func renderIndexContent(
    page: ScannerServerPage,
    settings: ScanSettings,
    editModeID: String?,
    setupMessageCode: String?,
    setup: ScannerSetupState,
    scannerIsReachable: Bool,
    wifiBackend: Bool,
    job: ScanJobState,
    ocr: OCRQueueState,
    workers: [OCRWorkerSnapshot],
    groups: [ScanDayGroup],
    localTime: ScannerServerLocalTime
) -> String {
    let selectedMode: ScanMode
    if editModeID == "new" {
        selectedMode = ScanMode(id: "", name: "", settings: settings.defaultMode.settings)
    } else {
        selectedMode = editModeID.flatMap(settings.mode(id:)) ?? settings.defaultMode
    }

    var html = renderNavigation(active: page)
    if let message = setupMessage(setupMessageCode) {
        html += "<p class=\"notice\">\(htmlEscape(message))</p>"
    }
    if wifiBackend && setup.configured {
        html += renderScannerReachabilitySummary(
            setup,
            scannerIsReachable: scannerIsReachable
        )
    }
    switch page {
    case .scan:
        if !wifiBackend || setup.configured {
            html += renderScan(settings: settings, job: job)
            html += renderStatus(job: job, ocr: ocr, localTime: localTime)
        } else {
            html += "<section class=\"empty-state\"><p class=\"eyebrow\">Setup required</p>"
            html += "<h2>Connect a scanner before your first scan</h2>"
            html += "<p class=\"muted\">Scanner discovery and connection are managed separately from everyday scanning.</p>"
            html += "<a class=\"button-link\" href=\"/settings\">Open scanner settings</a></section>"
        }
    case .documents:
        html += renderFiles(groups)
    case .presets:
        html += renderModes(
            settings: settings,
            selectedMode: selectedMode,
            maximumOCRCPUs: ocr.cpuLimit
        )
    case .workers:
        html += renderWorkers(workers, localTime: localTime)
    case .settings:
        if wifiBackend {
            html += renderScannerSetup(setup)
        } else {
            html += "<section><p class=\"eyebrow\">Scanner settings</p><h2>Scanner connection</h2>"
            html += "<p>This server uses the <strong>sane</strong> scan backend. Its connection is configured outside the web interface.</p></section>"
        }
    }
    return html
}

private func renderWorkers(
    _ workers: [OCRWorkerSnapshot],
    localTime: ScannerServerLocalTime
) -> String {
    var html = "<section class=\"workers-panel\"><div class=\"section-heading\"><div>"
    html += "<p class=\"eyebrow\">Distributed processing</p><h2>OCR workers</h2>"
    html += "<p class=\"muted\">Register, approve, and monitor remote processing capacity. Document dispatch is not enabled yet.</p>"
    html += "</div></div>"
    guard !workers.isEmpty else {
        html += "<div class=\"empty-state compact\"><h3>No workers registered</h3>"
        html += "<p class=\"muted\">Start scannerserver-worker with this server's address. New workers will appear here for approval.</p></div></section>"
        return html
    }

    html += "<div class=\"worker-list\">"
    for worker in workers {
        html += "<article class=\"worker-card\"><div class=\"worker-card-head\"><div>"
        html += "<h3>\(htmlEscape(worker.displayName))</h3>"
        html += "<p class=\"muted\">\(htmlEscape(worker.hostname)) · \(htmlEscape(worker.architecture))</p></div>"
        html += workerStatusPill(worker.availability) + "</div>"
        html += "<dl class=\"worker-facts\"><div><dt>Capacity</dt><dd>\(worker.cpuCount) CPUs · \(worker.maxConcurrentJobs) job slot"
        if worker.maxConcurrentJobs != 1 { html += "s" }
        html += "</dd></div><div><dt>Running</dt><dd>\(worker.runningJobs)</dd></div>"
        html += "<div><dt>Languages</dt><dd>\(htmlEscape(worker.ocrLanguages.joined(separator: ", ")))</dd></div>"
        html += "<div><dt>Version</dt><dd>\(htmlEscape(worker.workerVersion))</dd></div></dl>"
        html += "<p class=\"muted\">Last seen \(htmlEscape(localTime.statusTimestamp(for: worker.lastSeen)))</p>"
        html += "<div class=\"button-row\">"
        let encodedID = urlPathComponent(worker.workerID)
        if !worker.approved {
            html += "<form class=\"inline-form\" method=\"post\" action=\"/workers/\(encodedID)/approve\"><button>Approve worker</button></form>"
        } else if worker.enabled {
            html += "<form class=\"inline-form\" method=\"post\" action=\"/workers/\(encodedID)/disable\"><button class=\"secondary-button\">Disable</button></form>"
        } else {
            html += "<form class=\"inline-form\" method=\"post\" action=\"/workers/\(encodedID)/enable\"><button>Enable</button></form>"
        }
        html += "</div></article>"
    }
    return html + "</div></section>"
}

private func workerStatusPill(_ availability: OCRWorkerAvailability) -> String {
    let label: String
    let cssClass: String
    switch availability {
    case .pendingApproval:
        label = "Approval required"
        cssClass = "working"
    case .online:
        label = "Online"
        cssClass = "success"
    case .busy:
        label = "Processing"
        cssClass = "working"
    case .offline:
        label = "Offline"
        cssClass = "error"
    case .disabled:
        label = "Disabled"
        cssClass = ""
    }
    return "<span class=\"status-pill \(cssClass)\">\(label)</span>"
}

private func renderNavigation(active: ScannerServerPage) -> String {
    var html = "<nav class=\"primary-nav\" aria-label=\"Primary\">"
    for page in ScannerServerPage.allCases {
        let current = page == active ? " aria-current=\"page\"" : ""
        html += "<a href=\"\(page.path)\"\(current)>\(htmlEscape(page.label))</a>"
    }
    return html + "</nav>"
}

private func renderScan(settings: ScanSettings, job: ScanJobState) -> String {
    let buttonMode = settings.defaultMode
    var html = "<section class=\"scan-panel\"><div class=\"section-heading\">"
    html += "<div><p class=\"eyebrow\">Scanner controls</p><h2>Start a new scan</h2>"
    html += "<p class=\"muted\">Choose a preset and start scanning. Preset settings are managed separately.</p></div>"
    html += "</div><form class=\"scan-form\" method=\"post\" action=\"/scan\">"
    html += "<label>Preset<select name=\"mode_id\" data-preset-select>"
    for mode in settings.modes {
        let selected = mode.id == settings.defaultModeID ? " selected" : ""
        html += "<option value=\"\(htmlEscape(mode.id))\" data-summary=\"\(htmlEscape(modeSummary(mode)))\"\(selected)>\(htmlEscape(mode.name))</option>"
    }
    html += "</select><span class=\"setting-help\" data-preset-summary>\(htmlEscape(modeSummary(buttonMode)))</span></label>"
    let scanDisabled = job.status == "running" ? " disabled" : ""
    html += "<button class=\"primary-action\"\(scanDisabled)>Start scan</button>"
    html += "</form>"
    if let message = emptyFeederMessage(for: job) {
        html += "<p class=\"warning\" role=\"alert\">\(htmlEscape(message))</p>"
    }
    if job.status == "running" {
        html += "<form class=\"inline-form\" method=\"post\" action=\"/scan/cancel\"><button class=\"danger-button\" data-confirm=\"Cancel the current scan?\">Cancel scan</button></form>"
    }
    html += "<div class=\"button-preset-note\"><span>Physical button</span>"
    html += "<strong>\(htmlEscape(buttonMode.name))</strong><a href=\"/presets?edit_mode=\(urlQueryValue(buttonMode.id))\">Manage</a>"
    html += "</div></section>"
    return html
}

private func emptyFeederMessage(for job: ScanJobState) -> String? {
    guard job.status.hasPrefix("failed") else { return nil }
    let diagnostic = "\(job.output)\n\(job.error)".lowercased()
    let emptyFeederDiagnostics = [
        "no pages were scanned",
        "no document in scanner",
    ]
    guard emptyFeederDiagnostics.contains(where: diagnostic.contains) else { return nil }
    return "No paper was detected in the feeder. Load paper, then start a new scan."
}

private func renderScannerReachabilitySummary(
    _ setup: ScannerSetupState,
    scannerIsReachable: Bool
) -> String {
    let reachabilityClass = scannerIsReachable ? "reachable" : "unreachable"
    let reachabilityText = scannerIsReachable ? "Reachable" : "Not reachable"
    var html = "<section class=\"scanner-summary\" aria-label=\"Scanner status\">"
    html += "<p class=\"scanner-name\"><strong>\(htmlEscape(setup.name))</strong>"
    html += " <span class=\"scanner-reachability \(reachabilityClass)\">"
    html += "<span class=\"scanner-reachability-dot\" aria-hidden=\"true\"></span>"
    html += "\(reachabilityText)</span></p></section>"
    return html
}

private func renderScannerSetup(_ setup: ScannerSetupState) -> String {
    "<section data-scanner-setup data-configured=\"\(setup.configured)\" data-needs-password=\"\(setup.needsPassword)\">\(renderScannerSetupContent(setup))</section>"
}

private func renderScannerSetupContent(_ setup: ScannerSetupState) -> String {
    var html = "<h2>Scanner setup</h2>"
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
    let errorHidden = setup.lastError.isEmpty ? " hidden" : ""
    html += "<pre data-scanner-setup-error\(errorHidden)>\(htmlEscape(setup.lastError))</pre>"
    if setup.needsPassword {
        html += "<p class=\"muted\" data-scanner-discovery-status>Automatic discovery is paused. Correct the scanner password or product serial number and try again.</p>"
    } else if !setup.configured {
        html += "<p class=\"muted\" data-scanner-discovery-status>Looking for scanners automatically…</p>"
    }
    html += "<div class=\"setup-controls\"><form method=\"post\" action=\"/setup/scanners/discover\"><button>Discover scanners</button></form>"
    html += "<div data-scanner-devices>\(renderScannerDevices(setup.devices))</div>"
    html += "<form method=\"post\" action=\"/setup/scanners/manual\" data-scanner-manual-form>"
    html += "<label>Scanner IPv4 address or host name<input name=\"scanner_ip\" value=\"\(htmlEscape(setup.ipAddress))\" required></label>"
    html += "<label>Scanner password or product serial number<input type=\"text\" name=\"scanner_credential\" required></label>"
    html += "<p class=\"muted\">If you never changed the scanner password, enter the product serial number printed on the scanner. The factory password will be derived automatically.</p>"
    html += "<button>Connect scanner</button></form>"
    html += "<form method=\"post\" action=\"/setup/scanners/clear\"><button class=\"danger-button\" data-confirm=\"Clear this scanner setup?\">Clear scanner setup</button></form></div>"
    return html
}

private func renderScannerDevices(_ devices: [ScannerSetupDevice]) -> String {
    guard !devices.isEmpty else { return "" }
    var html = "<form method=\"post\" action=\"/setup/scanners/select\"><div class=\"device-list\">"
    for device in devices {
        html += "<label><input type=\"radio\" name=\"device_id\" value=\"\(htmlEscape(device.id))\"> \(htmlEscape(device.name)) \(htmlEscape(device.ipAddress))</label>"
    }
    html += "</div><button>Use selected scanner</button></form>"
    return html
}

private func renderModes(
    settings: ScanSettings,
    selectedMode: ScanMode,
    maximumOCRCPUs: Int
) -> String {
    var html = "<section class=\"preset-workspace\"><div class=\"section-heading\"><div>"
    html += "<p class=\"eyebrow\">Reusable configurations</p><h2>Presets</h2>"
    html += "<p class=\"muted\">Create scan configurations and choose the preset used by the scanner's physical button.</p>"
    html += "</div><a class=\"button-link secondary-link\" href=\"/presets?edit_mode=new\">New preset</a></div>"
    html += "<div class=\"preset-layout\"><aside class=\"preset-sidebar\" aria-label=\"Saved presets\"><h3>Saved presets</h3><ul class=\"mode-list\">"
    for mode in settings.modes {
        let selected = mode.id == selectedMode.id ? " aria-current=\"true\"" : ""
        let badge = mode.id == settings.defaultModeID ? " <span class=\"default-badge\">Button</span>" : ""
        html += "<li><a href=\"/presets?edit_mode=\(urlQueryValue(mode.id))\"\(selected)>"
        html += "<strong>\(htmlEscape(mode.name))</strong>\(badge)<span class=\"muted\">\(htmlEscape(modeSummary(mode)))</span></a></li>"
    }
    html += "</ul></aside><div class=\"preset-editor\"><div class=\"editor-heading\">"
    html += "<p class=\"eyebrow\">\(selectedMode.id.isEmpty ? "New preset" : "Edit preset")</p>"
    html += "<h3>\(htmlEscape(selectedMode.id.isEmpty ? "Untitled preset" : selectedMode.name))</h3></div>"
    html += "<form class=\"mode-editor-form\" method=\"post\" action=\"/modes/save\">"
    html += "<input type=\"hidden\" name=\"mode_id\" value=\"\(htmlEscape(selectedMode.id))\">"
    html += "<fieldset class=\"setting-group\"><legend>Document</legend>"
    html += "<div class=\"settings-grid settings-grid-four\">"
    html += textInput(
        name: "name",
        label: "Name",
        value: selectedMode.name,
        help: "A label for this reusable scan mode."
    )
    html += select(
        name: "SCAN_SIMPLEX",
        label: "Sides",
        values: [("false", "Duplex"), ("true", "Simplex")],
        selected: selectedMode.settings.simplexText,
        help: "Duplex scans both sides; simplex scans only the front."
    )
    html += select(
        name: "SCAN_FORMAT",
        label: "Output",
        values: [("pdf", "PDF"), ("png", "PNG pages")],
        selected: selectedMode.settings.format,
        help: "Create a PDF document or one PNG image per scanned page."
    )
    html += select(
        name: "SCAN_PAGE_MODE",
        label: "Pages",
        values: [("multi", "Multipage file"), ("single", "One file per page")],
        selected: selectedMode.settings.pageMode,
        help: "Combine pages into one PDF or save one PDF per page."
    )
    html += "</div></fieldset>"
    html += "<fieldset class=\"setting-group\"><legend>Scan quality</legend>"
    html += "<div class=\"settings-grid settings-grid-two\">"
    html += select(
        name: "SCAN_RESOLUTION",
        label: "Resolution",
        values: ["200", "300", "400", "600"].map { ($0, "\($0) dpi") },
        selected: selectedMode.settings.resolution,
        help: "Requested scan resolution. The iX500 Wi-Fi backend does not expose this control."
    )
    html += select(
        name: "SCAN_MODE",
        label: "Color mode",
        values: ["Color", "Gray", "Lineart"].map { ($0, $0) },
        selected: selectedMode.settings.mode,
        help: "Requested color processing. The iX500 Wi-Fi backend does not expose this control."
    )
    html += "</div></fieldset>"
    html += "<fieldset class=\"setting-group\"><legend>Processing</legend>"
    html += "<div class=\"processing-grid\"><div class=\"setting-card\">"
    html += checkbox(
        name: "SCAN_OCR_ENABLED",
        label: "OCR",
        checked: selectedMode.settings.ocrEnabled,
        help: "Create searchable text in the background for PDF output."
    )
    html += select(
        name: "SCAN_LANGUAGE",
        label: "OCR language",
        values: [
            ("deu+eng", "German + English"),
            ("deu", "German"),
            ("eng", "English"),
        ],
        selected: selectedMode.settings.language,
        help: "Languages used by Tesseract when OCR is enabled."
    )
    var cpuChoices = [("", "Automatic (up to \(maximumOCRCPUs))")]
    cpuChoices += (1...max(1, maximumOCRCPUs)).map { (String($0), "\($0)") }
    if let selectedLimit = selectedMode.settings.ocrCPULimit,
       selectedLimit > maximumOCRCPUs {
        cpuChoices.append((
            String(selectedLimit),
            "\(selectedLimit) (currently capped to \(maximumOCRCPUs))"
        ))
    }
    html += select(
        name: "SCAN_OCR_CPU_LIMIT",
        label: "Processing CPUs",
        values: cpuChoices,
        selected: selectedMode.settings.ocrCPULimitText,
        help: "Automatic uses the background CPU allowance while reserving one processor for scanning and the web service."
    )
    html += select(
        name: "SCAN_OCR_NICE",
        label: "Post-scan priority",
        values: [("false", "Normal"), ("true", "Niced (reduced)")],
        selected: selectedMode.settings.ocrNiceText,
        help: "Niced background processing yields CPU time while scanning and the web service remain at normal priority."
    )
    html += "</div><div class=\"setting-card\">"
    html += checkbox(
        name: "SCAN_CROP_PAGES",
        label: "Autocrop",
        checked: selectedMode.settings.cropPages,
        help: "Trim scanner-bed borders around detected paper during background processing."
    )
    html += numberInput(
        name: "SCAN_CROP_MARGIN_POINTS",
        label: "Crop margin",
        value: selectedMode.settings.cropMarginPointsText,
        minimum: "0",
        step: "0.1",
        help: "Extra space kept around detected content after autocropping, in PDF points (1 pt = 1/72 inch)."
    )
    html += "</div><div class=\"setting-card\">"
    html += checkbox(
        name: "SCAN_REMOVE_BLANK_PAGES",
        label: "Remove blanks",
        checked: selectedMode.settings.removeBlankPages,
        help: "Discard pages detected as blank during background PDF processing."
    )
    html += "</div></div></fieldset>"
    html += "<fieldset class=\"setting-group\"><legend>Physical button</legend>"
    html += "<div class=\"button-setting-card\">"
    html += checkbox(
        name: "set_default",
        label: "Button default",
        checked: selectedMode.id == settings.defaultModeID,
        help: "Use this mode when the scanner's physical button is pressed."
    )
    html += "</div></fieldset><div class=\"mode-actions button-row\"><button>Save mode</button>"
    if !selectedMode.id.isEmpty {
        html += "<button class=\"danger-button\" formaction=\"/modes/delete\" data-confirm=\"Delete this preset?\">Delete mode</button>"
    }
    html += "</div></form></div></div></section>"
    return html
}

private func renderStatus(
    job: ScanJobState,
    ocr: OCRQueueState,
    localTime: ScannerServerLocalTime
) -> String {
    var html = "<section class=\"activity-panel\"><div class=\"section-heading\"><div>"
    html += "<p class=\"eyebrow\">Live progress</p><h2>Current activity</h2></div>"
    html += "<a href=\"/documents\">View documents</a></div><div class=\"activity-grid\">"
    html += "<article class=\"activity-card\"><div class=\"activity-card-head\"><h3>Scan</h3>"
    html += statusPill(job.status) + "</div>"
    if let started = job.started {
        html += "<p class=\"muted\">Started \(htmlEscape(localTime.statusTimestamp(for: started)))</p>"
    }
    if let finished = job.finished {
        html += "<p class=\"muted\">Finished \(htmlEscape(localTime.statusTimestamp(for: finished)))</p>"
    }
    if !job.output.isEmpty || !job.error.isEmpty {
        html += "<details class=\"technical-details\"><summary>Technical details</summary>"
        if !job.output.isEmpty { html += "<pre>\(htmlEscape(job.output))</pre>" }
        if !job.error.isEmpty { html += "<pre>\(htmlEscape(job.error))</pre>" }
        html += "</details>"
    }
    html += "</article><article class=\"activity-card\"><div class=\"activity-card-head\"><h3>Background processing</h3>"
    html += statusPill(ocr.status)
    if ocr.running > 1 { html += "<span class=\"queue-count\">\(ocr.running) jobs active</span>" }
    if ocr.queued > 0 { html += "<span class=\"queue-count\">\(ocr.queued) queued</span>" }
    html += "</div><p class=\"muted\">CPU budget \(ocr.cpuLimit) · priority "
    if let niceLevel = ocr.niceLevel {
        html += "nice +\(niceLevel)"
    } else {
        html += "normal"
    }
    html += "</p>"
    if ocr.status == "running" || ocr.status == "queued" || ocr.queued > 0 {
        html += "<form class=\"inline-form\" method=\"post\" action=\"/ocr/cancel\"><button class=\"danger-button\">Cancel processing</button></form>"
    }
    if let started = ocr.started {
        html += "<p class=\"muted\">Started \(htmlEscape(localTime.statusTimestamp(for: started)))</p>"
    }
    if let finished = ocr.finished {
        html += "<p class=\"muted\">Finished \(htmlEscape(localTime.statusTimestamp(for: finished)))</p>"
    }
    if !ocr.input.isEmpty || !ocr.output.isEmpty || !ocr.error.isEmpty {
        html += "<details class=\"technical-details\"><summary>Technical details</summary>"
        if !ocr.input.isEmpty { html += "<p>Input: \(htmlEscape(ocr.input))</p>" }
        if !ocr.output.isEmpty { html += "<pre>\(htmlEscape(ocr.output))</pre>" }
        if !ocr.error.isEmpty { html += "<pre>\(htmlEscape(ocr.error))</pre>" }
        html += "</details>"
    }
    if !ocr.recentJobs.isEmpty {
        html += "<details class=\"technical-details\"><summary>Recent processing jobs</summary><ul class=\"ocr-history\">"
        for recent in ocr.recentJobs {
            let name = URL(fileURLWithPath: recent.input).lastPathComponent
            html += "<li><span class=\"file-name\">\(htmlEscape(name))</span>: "
            html += "\(htmlEscape(recent.status)) in \(htmlEscape(elapsedTime(recent.duration)))</li>"
        }
        html += "</ul></details>"
    }
    return html + "</article></div></section>"
}

private func renderFiles(_ groups: [ScanDayGroup]) -> String {
    var html = "<section class=\"documents-panel\"><div class=\"section-heading\"><div>"
    html += "<p class=\"eyebrow\">Scan results</p><h2>Documents</h2>"
    html += "<p class=\"muted\">Open completed scans, download source files, or remove documents.</p></div></div>"
    guard !groups.isEmpty else {
        return html + "<div class=\"empty-state compact\"><h3>No scans yet</h3><p class=\"muted\">Completed scans will appear here.</p><a class=\"button-link\" href=\"/\">Start a scan</a></div></section>"
    }
    html += "<form class=\"documents-form\" method=\"post\" action=\"/files/delete-selected\"><div class=\"document-actions\">"
    html += "<label class=\"select-all\"><input type=\"checkbox\" data-select-all> Select all</label>"
    html += "<button class=\"danger-button compact-button\" data-confirm=\"Delete the selected files?\">Delete selected</button></div><div class=\"file-groups\">"
    for group in groups {
        html += "<div><h3>\(htmlEscape(group.day))</h3><ul class=\"file-list\">"
        for document in group.files {
            let viewPath = urlPathComponent(document.viewName)
            let previewPath = urlPathComponent(document.previewName)
            html += "<li class=\"file-row\"><a class=\"preview-link\" href=\"/view/\(viewPath)\" target=\"_blank\"><img class=\"file-preview\" src=\"/files/\(previewPath)/preview\" alt=\"Preview of \(htmlEscape(document.title))\"></a><div class=\"file-details\">"
            html += "<a class=\"document-title\" href=\"/view/\(viewPath)\" target=\"_blank\">\(htmlEscape(document.title))</a>"
            for file in document.files {
                let path = urlPathComponent(file.name)
                html += "<div class=\"file-variant\"><input type=\"checkbox\" name=\"files\" value=\"\(htmlEscape(file.name))\">"
                html += "<a href=\"/files/\(path)\">\(htmlEscape(file.kind.label))</a> <span class=\"file-name\">\(htmlEscape(file.name))</span>"
                html += "<button class=\"danger-button compact-button\" formaction=\"/files/\(path)/delete\" data-confirm=\"Delete this file?\">Delete</button></div>"
            }
            html += "</div></li>"
        }
        html += "</ul></div>"
    }
    return html + "</div></form></section>"
}

private func statusPill(_ status: String) -> String {
    let normalized = status.lowercased()
    let style: String
    if ["running", "queued"].contains(normalized) {
        style = "working"
    } else if ["done", "idle"].contains(normalized) {
        style = "success"
    } else if normalized.hasPrefix("failed") || ["error", "cancelled"].contains(normalized) {
        style = "error"
    } else {
        style = "neutral"
    }
    return "<span class=\"status-pill \(style)\">\(htmlEscape(status.capitalized))</span>"
}

private func modeSummary(_ mode: ScanMode) -> String {
    let value = mode.settings
    let sides = value.simplex ? "Simplex" : "Duplex"
    let output = value.format == "png" ? "PNG pages" : "PDF"
    let pages = value.pageMode == "single" ? "single pages" : "multipage"
    let ocr = value.ocrEnabled ? "OCR on" : "OCR off"
    let crop = value.cropPages
        ? "autocrop on (\(value.cropMarginPointsText) pt margin)"
        : "autocrop off"
    return "\(sides), \(output), \(pages), \(ocr), \(crop), \(value.resolution) dpi \(value.mode)"
}

private func elapsedTime(_ interval: TimeInterval) -> String {
    if interval < 10 {
        return String(format: "%.1f s", interval)
    }
    if interval < 60 {
        return String(format: "%.0f s", interval)
    }
    let totalSeconds = Int(interval.rounded())
    return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
}

private func option(value: String, label: String, selected: Bool) -> String {
    "<option value=\"\(htmlEscape(value))\"\(selected ? " selected" : "")>\(htmlEscape(label))</option>"
}

private func textInput(name: String, label: String, value: String, help: String) -> String {
    "<label>\(htmlEscape(label))<input name=\"\(htmlEscape(name))\" value=\"\(htmlEscape(value))\">"
        + settingHelp(help) + "</label>"
}

private func numberInput(
    name: String,
    label: String,
    value: String,
    minimum: String,
    step: String,
    help: String
) -> String {
    "<label>\(htmlEscape(label))<input type=\"number\" name=\"\(htmlEscape(name))\" "
        + "value=\"\(htmlEscape(value))\" min=\"\(htmlEscape(minimum))\" "
        + "step=\"\(htmlEscape(step))\">\(settingHelp(help))</label>"
}

private func select(
    name: String,
    label: String,
    values: [(String, String)],
    selected: String,
    help: String
) -> String {
    "<label>\(htmlEscape(label))<select name=\"\(htmlEscape(name))\">"
        + values.map { option(value: $0.0, label: $0.1, selected: $0.0 == selected) }.joined()
        + "</select>\(settingHelp(help))</label>"
}

private func checkbox(name: String, label: String, checked: Bool, help: String) -> String {
    "<label class=\"checkbox-setting\"><span><input type=\"checkbox\" name=\"\(htmlEscape(name))\""
        + "\(checked ? " checked" : "")> \(htmlEscape(label))</span>"
        + settingHelp(help) + "</label>"
}

private func settingHelp(_ help: String) -> String {
    "<span class=\"setting-help\">\(htmlEscape(help))</span>"
}

private func setupMessage(_ code: String?) -> String? {
    switch code {
    case "discovery-started": "Scanner discovery started."
    case "no-device": "Choose a discovered scanner."
    case "manual-missing": "Enter the scanner IPv4 address or host name and its password or product serial number."
    case "manual-not-found": "No scanner matching those details was found."
    case "manual-invalid": "The scanner details are invalid."
    case "password-needed": "Enter the scanner password or product serial number to finish setup."
    case "password-failed": "The scanner password or product serial number was rejected."
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

private func loadIndexHTML() throws -> String {
    guard let url = Bundle.module.url(forResource: "index", withExtension: "html") else {
        throw ScannerServerConfigurationError.missingIndexResource
    }
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
        throw ScannerServerConfigurationError.unreadableIndexResource
    }
    return contents
}
