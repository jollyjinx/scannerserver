import ArgumentParser
import Foundation
import JLog
import ScannerServerCore

extension JLog.Level: @retroactive ExpressibleByArgument {}

@main
struct ScannerServerWorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scannerserver-worker",
        abstract: "Register this computer as an OCR worker for scannerserver."
    )

    @Option(help: "The scannerserver base URL. When omitted, discover scannerserver through Bonjour.")
    var server: String?

    @Option(help: "Seconds to wait for Bonjour discovery when --server is omitted.")
    var discoveryTimeout: Int = 10

    @Option(help: "Name shown on the scannerserver Workers page.")
    var name: String = ProcessInfo.processInfo.hostName

    @Option(help: "CPUs advertised for containerized document processing.")
    var cpus: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)

    @Option(help: "Maximum documents processed concurrently.")
    var jobs: Int = 1

    @Option(parsing: .upToNextOption, help: "OCR language codes supported by the worker.")
    var languages: [String] = ["deu", "eng"]

    @Option(help: "Persistent worker identity file.")
    var identityFile: String = WorkerIdentity.defaultFileURL.path

    @Option(help: "Set the log level.")
    var logLevel: JLog.Level = .notice

    mutating func validate() throws {
        guard cpus > 0 else { throw ValidationError("--cpus must be positive") }
        guard jobs > 0, jobs <= cpus else {
            throw ValidationError("--jobs must be positive and no greater than --cpus")
        }
        guard !languages.isEmpty else { throw ValidationError("At least one OCR language is required") }
        guard discoveryTimeout > 0 else { throw ValidationError("--discovery-timeout must be positive") }
    }

    mutating func run() async throws {
        JLog.loglevel = logLevel
        let serverURL = try await resolveServerURL()
        let client = try OCRWorkerHTTPClient(serverURL: serverURL)
        let identity = try WorkerIdentity.loadOrCreate(
            at: URL(fileURLWithPath: identityFile, isDirectory: false)
        )
        let registration = OCRWorkerRegistrationRequest(
            workerID: identity.workerID,
            authenticationToken: identity.authenticationToken,
            displayName: name,
            hostname: ProcessInfo.processInfo.hostName,
            workerVersion: ScannerServerBuildInformation().version,
            architecture: architectureName,
            cpuCount: cpus,
            maxConcurrentJobs: jobs,
            ocrLanguages: languages.sorted()
        )

        JLog.notice("Connecting OCR worker \(name) to \(serverURL.absoluteString)")
        var lastAvailability: OCRWorkerAvailability?
        while !Task.isCancelled {
            do {
                var state = try await client.register(registration)
                if state.availability != lastAvailability {
                    log(state.availability)
                    lastAvailability = state.availability
                }
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(state.heartbeatIntervalSeconds))
                    state = try await client.heartbeat(
                        workerID: identity.workerID,
                        request: OCRWorkerHeartbeatRequest(
                            authenticationToken: identity.authenticationToken,
                            runningJobs: 0
                        )
                    )
                    if state.availability != lastAvailability {
                        log(state.availability)
                        lastAvailability = state.availability
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                JLog.warning("OCR worker connection failed: \(error.localizedDescription); retrying")
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func resolveServerURL() async throws -> URL {
        if let server {
            guard let url = URL(string: server) else {
                throw ValidationError("--server is not a valid URL")
            }
            return url
        }
        #if canImport(Network)
        JLog.notice("Looking for scannerserver through Bonjour")
        return try await BonjourScannerServerDiscovery().discover(
            timeout: .seconds(discoveryTimeout)
        )
        #else
        throw ValidationError("Bonjour discovery is only available on Apple platforms; pass --server")
        #endif
    }

    private func log(_ availability: OCRWorkerAvailability) {
        switch availability {
        case .pendingApproval:
            JLog.notice("Worker registered and is waiting for approval in scannerserver")
        case .online:
            JLog.notice("Worker is approved and online")
        case .busy:
            JLog.info("Worker is processing")
        case .offline:
            JLog.warning("Worker is marked offline")
        case .disabled:
            JLog.notice("Worker is disabled in scannerserver")
        }
    }

    private var architectureName: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
