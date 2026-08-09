import Foundation

public actor ScanJobButtonScanDispatcher: ScanSnapButtonScanDispatching {
    private let scanJobs: ScanJobActor
    private let scannerStore: ScannerConfigStore
    private let environment: [String: String]

    public init(
        scanJobs: ScanJobActor,
        scannerStore: ScannerConfigStore,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.scanJobs = scanJobs
        self.scannerStore = scannerStore
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
        let configuration = ScanPipelineConfiguration(
            environment: activeEnvironment,
            modeOverrides: mode.environment(trigger: "button")
        )
        return await scanJobs.start(configuration: configuration)
    }
}
