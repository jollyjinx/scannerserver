import ArgumentParser
import Foundation
import JLog
import ScannerServerCore

extension JLog.Level: @retroactive ExpressibleByArgument {}

@main
struct ScannerServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: ScannerServerCore.productName,
        abstract: "Run the ScanSnap scanner service."
    )

    @Option(help: "Override the HTTP bind hostname.")
    var host: String?

    @Option(help: "Override WEB_PORT.")
    var port: Int?

    @Option(help: "Set the service log level.")
    var logLevel: JLog.Level = .notice

    mutating func run() async throws {
        JLog.loglevel = logLevel
        let environmentConfiguration = try ScannerServerServiceConfiguration(
            environment: ProcessInfo.processInfo.environment
        )
        let configuration = try environmentConfiguration.overriding(hostname: host, port: port)
        let runtime = ScannerServerRuntime.live()

        JLog.notice("Starting scannerserver on \(configuration.hostname):\(configuration.port)")
        try await runtime.run(configuration: configuration)
    }
}
