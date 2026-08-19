import Foundation

public actor ScanJobButtonScanDispatcher: ScanSnapButtonScanDispatching {
    private let scanJobs: ScanJobActor
    private let scannerStore: ScannerConfigStore
    private let settingsStore: ScanSettingsStore
    private let environment: [String: String]

    public init(
        scanJobs: ScanJobActor,
        scannerStore: ScannerConfigStore,
        settingsStore: ScanSettingsStore? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.scanJobs = scanJobs
        self.scannerStore = scannerStore
        self.settingsStore = settingsStore ?? ScanSettingsStore(environment: environment)
        self.environment = environment
    }

    public func isScanRunning() async -> Bool {
        return await scanJobs.state.status == "running"
    }

    public func startButtonScan(mode: ScanMode) async -> Bool {
        var activeEnvironment = environment
        if let scanner = await scannerStore.activeConfiguration() {
            activeEnvironment.merge(scanner.environmentOverrides) { _, configured in configured }
        }
        let modeOverrides = (try? await settingsStore.load()).map {
            $0.environment(for: mode, trigger: "button")
        } ?? mode.environment(trigger: "button")
        let configuration = ScanPipelineConfiguration(
            environment: activeEnvironment,
            modeOverrides: modeOverrides
        )
        return await scanJobs.start(configuration: configuration)
    }
}
