import Foundation

public actor ScannerServerRuntime {
    public nonisolated let dependencies: ScannerServerDependencies

    public init(dependencies: ScannerServerDependencies) {
        self.dependencies = dependencies
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ScannerServerRuntime {
        ScannerServerRuntime(dependencies: .live(environment: environment))
    }

    public func run(configuration: ScannerServerServiceConfiguration) async throws {
        let application = try ScannerServerApplication.make(
            configuration: configuration,
            dependencies: dependencies
        )
        do {
            try await application.runService()
        } catch {
            await shutdown()
            throw error
        }
        await shutdown()
    }

    public func shutdown() async {
        await dependencies.scanJobs.cancel()
        await dependencies.ocrQueue.cancelAll()
    }
}
