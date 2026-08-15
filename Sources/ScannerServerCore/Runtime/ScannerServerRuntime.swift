import Foundation
import JLog

public actor ScannerServerRuntime {
    public nonisolated let dependencies: ScannerServerDependencies
    private let buttonRuntime: (any ScanSnapButtonRuntimeControlling)?
    private let ocrWorkerBonjourPublisher: OCRWorkerBonjourPublisher?

    public init(
        dependencies: ScannerServerDependencies,
        buttonRuntime: (any ScanSnapButtonRuntimeControlling)? = nil,
        ocrWorkerBonjourPublisher: OCRWorkerBonjourPublisher? = nil
    ) {
        self.dependencies = dependencies
        self.buttonRuntime = buttonRuntime
        self.ocrWorkerBonjourPublisher = ocrWorkerBonjourPublisher
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ScannerServerRuntime {
        let dependencies = ScannerServerDependencies.live(environment: environment)
        let buttonRuntime = ScanSnapButtonRuntimeFactory.live(
            environment: environment,
            scannerStore: dependencies.scannerStore,
            settingsStore: dependencies.settingsStore,
            scanJobs: dependencies.scanJobs,
            acquisitionSessions: dependencies.scanSnapAcquisitionSessions,
            reachabilityState: dependencies.scannerReachability,
            configurationChangeCoordinator: dependencies.buttonConfigurationChanges
        )
        return ScannerServerRuntime(
            dependencies: dependencies,
            buttonRuntime: buttonRuntime,
            ocrWorkerBonjourPublisher: OCRWorkerBonjourPublisher(environment: environment)
        )
    }

    public func run(configuration: ScannerServerServiceConfiguration) async throws {
        do {
            let cancelledJobs = try await dependencies.ocrWorkerJobs.cancelNonterminalJobs()
            if cancelledJobs > 0 {
                JLog.warning(
                    "Cancelled \(cancelledJobs) orphaned remote OCR job(s) left by the previous server process"
                )
                await dependencies.webUpdates.notify()
            }
        } catch {
            JLog.warning("Could not cancel orphaned remote OCR jobs: \(error.localizedDescription)")
        }
        let application = try ScannerServerApplication.make(
            configuration: configuration,
            dependencies: dependencies
        )
        if let issue = dependencies.scanDirectoryAccessIssue {
            JLog.error(
                "Scan directory is not accessible at \(issue.directoryPath); web requests and button configuration will retry: \(issue.details)"
            )
        }
        await startButtonRuntime()
        await ocrWorkerBonjourPublisher?.start(serviceConfiguration: configuration)
        do {
            try await application.runService()
        } catch {
            await shutdown()
            throw error
        }
        await shutdown()
    }

    public func startButtonRuntime() async {
        do {
            _ = try await buttonRuntime?.start()
        } catch {
            JLog.warning("ScanSnap button listener failed to start: \(error.localizedDescription)")
        }
    }

    public func shutdown() async {
        await ocrWorkerBonjourPublisher?.stop()
        await buttonRuntime?.stop()
        await dependencies.scannerSetup.shutdown()
        await dependencies.scanJobs.cancel()
        await dependencies.ocrQueue.cancelAll()
    }
}
