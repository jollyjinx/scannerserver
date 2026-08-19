import Foundation
import JLog

public protocol ScanSnapButtonRuntimeControlling: Sendable {
    @discardableResult
    func start() async throws -> Bool
    func stop() async
}

public actor ScanSnapButtonRuntimeController: ScanSnapButtonRuntimeControlling {
    public nonisolated let isEligible: Bool

    private let lifecycle: ScanSnapButtonLifecycleActor
    private let scanJobs: ScanJobActor
    private let acquisitionSessions: ScanSnapAcquisitionSessionCoordinator
    private let startupAdvertisementListener: ScanSnapStartupAdvertisementListener
    private let configurationChangeCoordinator: ScanSnapButtonConfigurationChangeCoordinator?
    private var scanEventHandlerID: UUID?

    public init(
        isEligible: Bool,
        lifecycle: ScanSnapButtonLifecycleActor,
        scanJobs: ScanJobActor,
        acquisitionSessions: ScanSnapAcquisitionSessionCoordinator = ScanSnapAcquisitionSessionCoordinator(),
        startupAdvertisementListener: ScanSnapStartupAdvertisementListener,
        configurationChangeCoordinator: ScanSnapButtonConfigurationChangeCoordinator? = nil
    ) {
        self.isEligible = isEligible
        self.lifecycle = lifecycle
        self.scanJobs = scanJobs
        self.acquisitionSessions = acquisitionSessions
        self.startupAdvertisementListener = startupAdvertisementListener
        self.configurationChangeCoordinator = configurationChangeCoordinator
    }

    @discardableResult
    public func start() async throws -> Bool {
        guard isEligible else { return false }
        guard scanEventHandlerID == nil else { return false }

        scanEventHandlerID = await scanJobs.addEventHandler { [lifecycle, acquisitionSessions] event in
            switch event {
            case .started(let trigger):
                let reusesArmedSession = await lifecycle.scanDidStart(
                    buttonNoticeConfirmsSession: trigger == .scannerButton
                )
                await acquisitionSessions.prepareForAcquisition(
                    reusingArmedSession: reusesArmedSession
                )
            case .finished(let succeeded):
                if !succeeded {
                    JLog.warning("Scan failed; recovering ScanSnap button session")
                }
                await lifecycle.scanDidFinish(succeeded: succeeded)
            }
        }
        do {
            let started = try await lifecycle.start()
            if started {
                await configurationChangeCoordinator?.attach(lifecycle: lifecycle)
                do {
                    _ = try await startupAdvertisementListener.start { [lifecycle] advertisement in
                        await lifecycle.scannerDidAdvertiseStartup(advertisement)
                    }
                } catch {
                    JLog.warning(
                        "ScanSnap startup-advertisement listener failed to start: \(error.localizedDescription)"
                    )
                }
            } else {
                if let scanEventHandlerID {
                    await scanJobs.removeEventHandler(scanEventHandlerID)
                    self.scanEventHandlerID = nil
                }
            }
            return started
        } catch {
            if let scanEventHandlerID {
                await scanJobs.removeEventHandler(scanEventHandlerID)
                self.scanEventHandlerID = nil
            }
            throw error
        }
    }

    public func stop() async {
        if let scanEventHandlerID {
            await scanJobs.removeEventHandler(scanEventHandlerID)
            self.scanEventHandlerID = nil
        }
        await startupAdvertisementListener.stop()
        await configurationChangeCoordinator?.detach()
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
        acquisitionSessions: ScanSnapAcquisitionSessionCoordinator = ScanSnapAcquisitionSessionCoordinator(),
        network: any ScanSnapSetupNetworkProviding = SystemScanSnapSetupNetworkProvider(),
        udpTransportFactory: any ScanSnapUDPTransportFactory = POSIXScanSnapUDPTransportFactory(),
        reachability: any ScanSnapButtonReachabilityChecking = ScanSnapButtonTCPReachabilityChecker(),
        armer: any ScanSnapButtonArming = ScanSnapButtonSessionArmer(),
        clock: any ScanSnapButtonClock = SystemScanSnapButtonClock(),
        sleeper: any ScanSnapSleeper = TaskScanSnapSleeper(),
        reachabilityState: ScanSnapReachabilityState? = nil,
        configurationChangeCoordinator: ScanSnapButtonConfigurationChangeCoordinator? = nil
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
            settingsStore: settingsStore,
            environment: environment
        )
        let heartbeat = ScanSnapButtonHeartbeatActor(
            udpTransportFactory: udpTransportFactory,
            sleeper: sleeper
        )
        let lifecycle = ScanSnapButtonLifecycleActor(
            configuration: buttonConfiguration,
            udpTransportFactory: udpTransportFactory,
            scannerProvider: scannerProvider,
            modeProvider: modeProvider,
            scanDispatcher: dispatcher,
            reachability: reachability,
            armer: armer,
            heartbeat: heartbeat,
            reachabilityState: reachabilityState,
            clock: clock,
            sleeper: sleeper
        )
        let startupAdvertisementListener = ScanSnapStartupAdvertisementListener(
            port: buttonConfiguration.startupAdvertisementPort,
            pollMilliseconds: buttonConfiguration.listenerPollMilliseconds,
            udpTransportFactory: udpTransportFactory,
            sleeper: sleeper
        )
        let isWiFiBackend = environment["SCAN_BACKEND", default: "wifi"] == "wifi"
        return ScanSnapButtonRuntimeController(
            isEligible: isWiFiBackend && buttonConfiguration.isEnabled,
            lifecycle: lifecycle,
            scanJobs: scanJobs,
            acquisitionSessions: acquisitionSessions,
            startupAdvertisementListener: startupAdvertisementListener,
            configurationChangeCoordinator: configurationChangeCoordinator
        )
    }
}
