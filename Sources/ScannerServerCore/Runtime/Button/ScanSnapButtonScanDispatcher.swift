import Foundation

public actor ScanJobButtonScanDispatcher: ScanSnapButtonScanDispatching {
    private let scanJobs: ScanJobActor
    private let scannerStore: ScannerConfigStore
    private let environment: [String: String]

    private weak var lifecycle: ScanSnapButtonLifecycleActor?
    private var completionTask: Task<Void, Never>?
    private var completionGeneration: UInt64 = 0

    public init(
        scanJobs: ScanJobActor,
        scannerStore: ScannerConfigStore,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.scanJobs = scanJobs
        self.scannerStore = scannerStore
        self.environment = environment
    }

    public func attach(lifecycle: ScanSnapButtonLifecycleActor) {
        self.lifecycle = lifecycle
    }

    public func detachLifecycle() {
        lifecycle = nil
        completionGeneration &+= 1
        completionTask?.cancel()
        completionTask = nil
    }

    public func isScanRunning() async -> Bool {
        if completionTask != nil { return true }
        return await scanJobs.state.status == "running"
    }

    public func startButtonScan(mode: ScanMode) async -> Bool {
        guard completionTask == nil else { return false }

        var activeEnvironment = environment
        if let scanner = await scannerStore.activeConfiguration() {
            activeEnvironment.merge(scanner.environmentOverrides) { _, configured in configured }
        }
        let configuration = ScanPipelineConfiguration(
            environment: activeEnvironment,
            modeOverrides: mode.environment(trigger: "button")
        )
        guard await scanJobs.start(configuration: configuration) else { return false }

        completionGeneration &+= 1
        let generation = completionGeneration
        completionTask = Task { [weak self, scanJobs] in
            await scanJobs.waitUntilIdle()
            guard !Task.isCancelled else { return }
            await self?.scanDidFinish(generation: generation)
        }
        return true
    }

    private func scanDidFinish(generation: UInt64) async {
        guard generation == completionGeneration else { return }
        if let lifecycle {
            await lifecycle.scanDidFinish()
        }
        guard generation == completionGeneration else { return }
        completionTask = nil
    }
}
