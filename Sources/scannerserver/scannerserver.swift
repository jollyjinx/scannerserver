import ArgumentParser
import JLog
import ScannerServerCore

@main
struct ScannerServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: ScannerServerCore.productName,
        abstract: "Run the ScanSnap scanner service."
    )

    mutating func run() async throws {
        JLog.notice("ScannerServer Swift runtime initialized")
    }
}
