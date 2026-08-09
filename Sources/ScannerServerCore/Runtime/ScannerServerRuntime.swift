import Foundation
import JLog

public actor ScannerServerRuntime {
    public nonisolated let dependencies: ScannerServerDependencies
    private let buttonRuntime: (any ScanSnapButtonRuntimeControlling)?

    public init(
        dependencies: ScannerServerDependencies,
        buttonRuntime: (any ScanSnapButtonRuntimeControlling)? = nil
    ) {
        self.dependencies = dependencies
        self.buttonRuntime = buttonRuntime
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
            reachabilityState: dependencies.scannerReachability,
            configurationChangeCoordinator: dependencies.buttonConfigurationChanges
        )
        return ScannerServerRuntime(
            dependencies: dependencies,
            buttonRuntime: buttonRuntime
        )
    }

    public func run(configuration: ScannerServerServiceConfiguration) async throws {
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
        await buttonRuntime?.stop()
        await dependencies.scannerSetup.shutdown()
        await dependencies.scanJobs.cancel()
        await dependencies.ocrQueue.cancelAll()
    }
}
