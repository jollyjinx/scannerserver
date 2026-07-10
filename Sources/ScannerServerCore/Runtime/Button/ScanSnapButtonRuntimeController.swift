import Foundation

public actor ScanSnapButtonRuntimeController {
    public nonisolated let isEligible: Bool

    private let lifecycle: ScanSnapButtonLifecycleActor
    private let dispatcher: ScanJobButtonScanDispatcher

    public init(
        isEligible: Bool,
        lifecycle: ScanSnapButtonLifecycleActor,
        dispatcher: ScanJobButtonScanDispatcher
    ) {
        self.isEligible = isEligible
        self.lifecycle = lifecycle
        self.dispatcher = dispatcher
    }

    @discardableResult
    public func start() async throws -> Bool {
        guard isEligible else { return false }
        await dispatcher.attach(lifecycle: lifecycle)
        do {
            return try await lifecycle.start()
        } catch {
            await dispatcher.detachLifecycle()
            throw error
        }
    }

    public func stop() async {
        await dispatcher.detachLifecycle()
        await lifecycle.stop()
    }

    public func state() async -> ScanSnapButtonLifecycleState {
        await lifecycle.state
    }
}

public enum ScanSnapButtonRuntimeFactory {
    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        scannerStore: ScannerConfigStore? = nil,
        settingsStore: ScanSettingsStore? = nil,
        scanJobs: ScanJobActor,
        network: any ScanSnapSetupNetworkProviding = SystemScanSnapSetupNetworkProvider(),
        udpTransportFactory: any ScanSnapUDPTransportFactory = POSIXScanSnapUDPTransportFactory(),
        reachability: any ScanSnapButtonReachabilityChecking = ScanSnapButtonTCPReachabilityChecker(),
        armer: any ScanSnapButtonArming = ScanSnapButtonSessionArmer(),
        clock: any ScanSnapButtonClock = SystemScanSnapButtonClock()
    ) -> ScanSnapButtonRuntimeController {
        let scannerStore = scannerStore ?? ScannerConfigStore(environment: environment)
        let settingsStore = settingsStore ?? ScanSettingsStore(environment: environment)
        let buttonConfiguration = ScanSnapButtonConfiguration(environment: environment)
        let scannerProvider = StoreBackedScanSnapButtonScannerConfigurationProvider(
            store: scannerStore,
            environment: environment,
            network: network
        )
        let modeProvider = StoreBackedScanSnapButtonModeProvider(store: settingsStore)
        let dispatcher = ScanJobButtonScanDispatcher(
            scanJobs: scanJobs,
            scannerStore: scannerStore,
            environment: environment
        )
        let lifecycle = ScanSnapButtonLifecycleActor(
            configuration: buttonConfiguration,
            udpTransportFactory: udpTransportFactory,
            scannerProvider: scannerProvider,
            modeProvider: modeProvider,
            scanDispatcher: dispatcher,
            reachability: reachability,
            armer: armer,
            clock: clock
        )
        let isWiFiBackend = environment["SCAN_BACKEND", default: "wifi"] == "wifi"
        return ScanSnapButtonRuntimeController(
            isEligible: isWiFiBackend && buttonConfiguration.isEnabled,
            lifecycle: lifecycle,
            dispatcher: dispatcher
        )
    }
}
