import ArgumentParser
import Foundation
import JLog
import ScannerServerCore

extension JLog.Level: @retroactive ExpressibleByArgument {}

private let directOCRDefault = ProcessInfo.processInfo.environment["SCANNERSERVER_WORKER_DIRECT"]
    .map { ["1", "true", "yes", "on"].contains($0.lowercased()) } ?? false
private let workerCPUDefault = directOCRDefault
    ? OCRQueueConfiguration.detectedProcessorCount
    : max(1, ProcessInfo.processInfo.activeProcessorCount - 1)

private enum WorkerJobEvent: Sendable {
    case lease(OCRWorkerJobLease?)
    case jobFinished
}

@main
struct ScannerServerWorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scannerserver-worker",
        abstract: "Register this computer as an OCR worker for scannerserver.",
        subcommands: [ProcessWorkerJobCommand.self]
    )

    @Option(help: "The scannerserver base URL. When omitted, discover scannerserver through Bonjour.")
    var server: String?

    @Option(help: "Seconds to wait for Bonjour discovery when --server is omitted.")
    var discoveryTimeout: Int = 10

    @Option(help: "Name shown on the scannerserver Workers page.")
    var name: String = ProcessInfo.processInfo.hostName

    @Option(help: "CPUs advertised and used for concurrent one-page OCR jobs.")
    var cpus: Int = workerCPUDefault

    @Option(help: "Optional safety cap for concurrent OCR jobs; defaults to --cpus.")
    var maxConcurrentJobs: Int?

    @Option(name: .customLong("jobs"), help: .hidden)
    var legacyJobLimit: Int?

    @Option(parsing: .upToNextOption, help: "OCR language codes supported by the worker.")
    var languages: [String] = ["deu", "eng"]

    @Option(help: "Persistent worker identity file.")
    var identityFile: String = WorkerIdentity.defaultFileURL.path

    @Option(help: "Container runtime executable used for OCR jobs.")
    var containerRuntime: String = "container"

    @Option(help: "Container image containing OCRmyPDF and Tesseract languages.")
    var containerImage: String = "ghcr.io/jollyjinx/scannerserver:latest"

    @Option(help: "Memory allocated to each concurrent OCR container.")
    var memoryPerJob: String = "8G"

    @Option(help: "Directory used for temporary downloaded and processed documents.")
    var workspace: String = OCRWorkerContainerConfiguration.defaultWorkspaceRoot.path

    @Flag(
        inversion: .prefixedNo,
        help: "Run OCRmyPDF directly instead of starting a nested container."
    )
    var directOCR: Bool = directOCRDefault

    @Option(help: "Set the log level.")
    var logLevel: JLog.Level = .notice

    mutating func validate() throws {
        guard cpus > 0 else { throw ValidationError("--cpus must be positive") }
        guard maxConcurrentJobs == nil || legacyJobLimit == nil else {
            throw ValidationError("Pass either --max-concurrent-jobs or the legacy --jobs option, not both")
        }
        if let requestedLimit = maxConcurrentJobs ?? legacyJobLimit,
           requestedLimit <= 0 || requestedLimit > cpus {
            throw ValidationError("The concurrent-job limit must be positive and no greater than --cpus")
        }
        guard !languages.isEmpty else { throw ValidationError("At least one OCR language is required") }
        guard discoveryTimeout > 0 else { throw ValidationError("--discovery-timeout must be positive") }
        if !directOCR {
            guard !containerRuntime.isEmpty else { throw ValidationError("--container-runtime must not be empty") }
            guard !containerImage.isEmpty else { throw ValidationError("--container-image must not be empty") }
            guard !memoryPerJob.isEmpty else { throw ValidationError("--memory-per-job must not be empty") }
        }
    }

    mutating func run() async throws {
        JLog.loglevel = logLevel
        if legacyJobLimit != nil {
            JLog.warning("--jobs is deprecated; use --max-concurrent-jobs only when a safety cap is needed")
        }
        let capacity = OCRWorkerCapacity(
            cpuCount: cpus,
            maximumConcurrentJobs: maxConcurrentJobs ?? legacyJobLimit
        )
        let serverURL = try await resolveServerURL()
        let controlClient = try OCRWorkerHTTPClient(serverURL: serverURL)
        let jobClient = try OCRWorkerHTTPClient(serverURL: serverURL)
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
            cpuCount: capacity.cpuCount,
            maxConcurrentJobs: capacity.maximumConcurrentJobs,
            ocrLanguages: languages.sorted(),
            capabilities: [OCRWorkerCapability.cropPDFPages]
        )

        JLog.notice("Connecting OCR worker \(name) to \(serverURL.absoluteString)")
        while !Task.isCancelled {
            do {
                var state = try await controlClient.register(registration)
                log(state.availability)
                while state.availability == .pendingApproval || state.availability == .disabled {
                    try await Task.sleep(for: .seconds(state.heartbeatIntervalSeconds))
                    state = try await controlClient.heartbeat(
                        workerID: identity.workerID,
                        request: OCRWorkerHeartbeatRequest(
                            authenticationToken: identity.authenticationToken,
                            runningJobs: 0
                        )
                    )
                    log(state.availability)
                }
                guard state.availability == .online || state.availability == .busy else {
                    throw WorkerSessionError.noLongerAvailable
                }
                try await runApprovedSession(
                    controlClient: controlClient,
                    jobClient: jobClient,
                    identity: identity,
                    capacity: capacity,
                    heartbeatIntervalSeconds: state.heartbeatIntervalSeconds
                )
            } catch is CancellationError {
                return
            } catch {
                JLog.warning("OCR worker connection failed: \(error.localizedDescription); retrying")
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func runApprovedSession(
        controlClient: OCRWorkerHTTPClient,
        jobClient: OCRWorkerHTTPClient,
        identity: WorkerIdentity,
        capacity: OCRWorkerCapacity,
        heartbeatIntervalSeconds: Int
    ) async throws {
        let activity = WorkerActivity()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(heartbeatIntervalSeconds))
                    let state = try await controlClient.heartbeat(
                        workerID: identity.workerID,
                        request: OCRWorkerHeartbeatRequest(
                            authenticationToken: identity.authenticationToken,
                            runningJobs: await activity.count
                        )
                    )
                    guard state.availability == .online || state.availability == .busy else {
                        throw WorkerSessionError.noLongerAvailable
                    }
                }
            }
            let processor = OCRWorkerJobProcessor(
                client: jobClient,
                configuration: OCRWorkerContainerConfiguration(
                    runtime: containerRuntime,
                    image: containerImage,
                    cpuLimitPerJob: capacity.cpuLimitPerJob,
                    memory: memoryPerJob,
                    workspaceRoot: URL(fileURLWithPath: workspace, isDirectory: true),
                    directExecution: directOCR
                )
            )
            group.addTask {
                try await runJobDispatcher(
                    processor: processor,
                    client: jobClient,
                    identity: identity,
                    activity: activity,
                    maximumConcurrentJobs: capacity.maximumConcurrentJobs
                )
            }
            defer { group.cancelAll() }
            guard let _ = try await group.next() else {
                throw WorkerSessionError.noLongerAvailable
            }
            throw WorkerSessionError.noLongerAvailable
        }
    }

    private func runJobDispatcher(
        processor: OCRWorkerJobProcessor,
        client: OCRWorkerHTTPClient,
        identity: WorkerIdentity,
        activity: WorkerActivity,
        maximumConcurrentJobs: Int
    ) async throws {
        try await withThrowingTaskGroup(of: WorkerJobEvent.self) { group in
            var activeJobs = 0
            var leaseRequestIsRunning = false
            defer { group.cancelAll() }

            while !Task.isCancelled {
                if activeJobs < maximumConcurrentJobs, !leaseRequestIsRunning {
                    leaseRequestIsRunning = true
                    group.addTask {
                        .lease(try await client.leaseNextJob(
                            workerID: identity.workerID,
                            request: OCRWorkerJobPollRequest(
                                authenticationToken: identity.authenticationToken,
                                waitSeconds: 20
                            )
                        ))
                    }
                }

                guard let event = try await group.next() else {
                    throw WorkerSessionError.noLongerAvailable
                }
                switch event {
                case .lease(nil):
                    leaseRequestIsRunning = false
                case .lease(let lease?):
                    leaseRequestIsRunning = false
                    activeJobs += 1
                    await activity.beginJob()
                    group.addTask {
                        await process(
                            lease: lease,
                            processor: processor,
                            identity: identity,
                            activity: activity
                        )
                        return .jobFinished
                    }
                case .jobFinished:
                    activeJobs = max(0, activeJobs - 1)
                }
            }
            throw CancellationError()
        }
    }

    private func process(
        lease: OCRWorkerJobLease,
        processor: OCRWorkerJobProcessor,
        identity: WorkerIdentity,
        activity: WorkerActivity
    ) async {
        JLog.notice("Starting remote OCR job \(lease.manifest.jobID), attempt \(lease.attempt)")
        do {
            try await processor.process(
                lease: lease,
                workerID: identity.workerID,
                authenticationToken: identity.authenticationToken
            )
            JLog.notice("Completed remote OCR job \(lease.manifest.jobID)")
        } catch is CancellationError {
            // Session shutdown cancels every in-flight page and its nested process.
        } catch {
            JLog.warning("Remote OCR job \(lease.manifest.jobID) failed: \(error.localizedDescription)")
        }
        await activity.finishJob()
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
        case .paused:
            JLog.notice("Worker is paused in scannerserver")
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

private struct ProcessWorkerJobCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process-job",
        abstract: "Run one OCR and autocrop job inside the worker image."
    )

    @Option(name: .customLong("crop-background-delta"))
    var backgroundDelta: Int = 8

    @Option(name: .customLong("crop-border-pixels"))
    var borderPixels: Int = 64

    @Option(name: .customLong("crop-margin-points"))
    var marginPoints: Double = 1.0

    @Option(name: .customLong("crop-maximum-width-ratio"))
    var maximumWidthRatio: Double = 0.80

    @Option(name: .customLong("crop-maximum-height-ratio"))
    var maximumHeightRatio: Double = 0.80

    @Option(name: .customLong("crop-minimum-density"))
    var minimumDensity: Double = 0.08

    @Flag(name: .customLong("crop-keep-original-boxes"))
    var keepOriginalBoxes = false

    @Flag(name: .customLong("crop-debug"))
    var cropDebug = false

    @Argument(parsing: .captureForPassthrough)
    var ocrArguments: [String] = []

    mutating func validate() throws {
        if ocrArguments == ["--help"] || ocrArguments == ["-h"] {
            throw CleanExit.helpRequest(Self.self)
        }
        let arguments = normalizedOCRArguments
        guard arguments.count >= 2,
              arguments[arguments.count - 2] == "/work/source.pdf",
              arguments.last == "/work/result.pdf" else {
            throw ValidationError("OCR arguments must end with /work/source.pdf /work/result.pdf")
        }
    }

    mutating func run() async throws {
        let arguments = normalizedOCRArguments
        let resultURL = URL(fileURLWithPath: arguments.last!, isDirectory: false)
        let result = try await OCRWorkerJobPipeline(
            ocrExecutor: FoundationProcessExecutor()
        ).execute(
            ocrRequest: ProcessRequest(
                executable: "ocrmypdf",
                arguments: arguments,
                workingDirectory: URL(fileURLWithPath: "/work", isDirectory: true)
            ),
            resultURL: resultURL,
            cropConfiguration: OCRWorkerCropConfiguration(
                backgroundDelta: backgroundDelta,
                borderPixels: borderPixels,
                marginPoints: marginPoints,
                maximumWidthRatio: maximumWidthRatio,
                maximumHeightRatio: maximumHeightRatio,
                minimumDensity: minimumDensity,
                keepOriginalBoxes: keepOriginalBoxes,
                debug: cropDebug
            )
        )
        guard result.succeeded else {
            let diagnostic = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            JLog.error("\(diagnostic.isEmpty ? "Worker job processing failed" : diagnostic)")
            throw ExitCode(result.exitStatus)
        }
    }

    private var normalizedOCRArguments: [String] {
        ocrArguments.first == "--" ? Array(ocrArguments.dropFirst()) : ocrArguments
    }
}
