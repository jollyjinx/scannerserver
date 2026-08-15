import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct OCRWorkerContainerConfiguration: Equatable, Sendable {
    public let runtime: String
    public let image: String
    public let cpusPerJob: Int
    public let memory: String
    public let workspaceRoot: URL
    public let userID: Int
    public let groupID: Int

    public init(
        runtime: String = "container",
        image: String = "ghcr.io/jollyjinx/scannerserver:latest",
        cpusPerJob: Int,
        memory: String = "8G",
        workspaceRoot: URL = Self.defaultWorkspaceRoot,
        userID: Int = Int(getuid()),
        groupID: Int = Int(getgid())
    ) {
        self.runtime = runtime
        self.image = image
        self.cpusPerJob = max(1, cpusPerJob)
        self.memory = memory
        self.workspaceRoot = workspaceRoot
        self.userID = userID
        self.groupID = groupID
    }

    public static var defaultWorkspaceRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("scannerserver-worker", isDirectory: true)
            .appendingPathComponent("jobs", isDirectory: true)
    }

    public func processRequest(
        lease: OCRWorkerJobLease,
        workspace: URL
    ) throws -> ProcessRequest {
        guard let arguments = lease.manifest.containerArguments,
              arguments.contains("/work/source.pdf"),
              arguments.contains("/work/result.pdf"),
              !runtime.isEmpty,
              !image.isEmpty,
              !memory.isEmpty else {
            throw OCRWorkerContainerError.invalidJob
        }
        return ProcessRequest(
            executable: runtime,
            arguments: [
                "run", "--rm",
                "--cpus", String(cpusPerJob),
                "--memory", memory,
                "--uid", String(userID),
                "--gid", String(groupID),
                "--env", "SCAN_OUTPUT_DIR=/work",
                "--env", "TMPDIR=/work/.tmp",
                "--volume", "\(workspace.path):/work",
                image,
                "ocrmypdf",
            ] + arguments,
            workingDirectory: workspace
        )
    }
}

public enum OCRWorkerContainerError: Error, LocalizedError, Sendable {
    case invalidJob
    case sourceSizeMismatch
    case sourceDigestMismatch
    case containerFailed(status: Int32, diagnostic: String)
    case missingResult

    public var errorDescription: String? {
        switch self {
        case .invalidJob:
            "The server supplied an invalid container job."
        case .sourceSizeMismatch:
            "The downloaded OCR source size does not match its manifest."
        case .sourceDigestMismatch:
            "The downloaded OCR source digest does not match its manifest."
        case let .containerFailed(status, diagnostic):
            diagnostic.isEmpty
                ? "OCR container exited with status \(status)."
                : "OCR container exited with status \(status): \(diagnostic)"
        case .missingResult:
            "The OCR container did not create /work/result.pdf."
        }
    }
}

public struct OCRWorkerJobProcessor: Sendable {
    private enum ProcessingEvent: Sendable {
        case completed(ProcessResult)
        case leaseLost(String)
    }

    private let client: OCRWorkerHTTPClient
    private let executor: any ProcessExecutor
    private let configuration: OCRWorkerContainerConfiguration

    public init(
        client: OCRWorkerHTTPClient,
        executor: any ProcessExecutor = FoundationProcessExecutor(),
        configuration: OCRWorkerContainerConfiguration
    ) {
        self.client = client
        self.executor = executor
        self.configuration = configuration
    }

    public func process(
        lease: OCRWorkerJobLease,
        workerID: String,
        authenticationToken: String
    ) async throws {
        let workspace = configuration.workspaceRoot.appendingPathComponent(
            lease.manifest.jobID,
            isDirectory: true
        )
        let sourceURL = workspace.appendingPathComponent("source.pdf")
        let resultURL = workspace.appendingPathComponent("result.pdf")
        try? FileManager.default.removeItem(at: workspace)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        do {
            let source = try await client.downloadSource(
                workerID: workerID,
                authenticationToken: authenticationToken,
                lease: lease
            )
            guard source.count == lease.manifest.sourceByteCount else {
                throw OCRWorkerContainerError.sourceSizeMismatch
            }
            guard OCRWorkerSHA256.hexDigest(source) == lease.manifest.sourceSHA256 else {
                throw OCRWorkerContainerError.sourceDigestMismatch
            }
            try source.write(to: sourceURL, options: .atomic)
            let request = try configuration.processRequest(lease: lease, workspace: workspace)
            let result = try await runWithLeaseRenewal(
                request: request,
                lease: lease,
                workerID: workerID,
                authenticationToken: authenticationToken
            )
            guard result.succeeded else {
                throw OCRWorkerContainerError.containerFailed(
                    status: result.exitStatus,
                    diagnostic: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            guard FileManager.default.fileExists(atPath: resultURL.path) else {
                throw OCRWorkerContainerError.missingResult
            }
            let output = try Data(contentsOf: resultURL, options: .mappedIfSafe)
            _ = try await client.uploadResult(
                workerID: workerID,
                authenticationToken: authenticationToken,
                lease: lease,
                data: output
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = try? await client.reportFailure(
                workerID: workerID,
                authenticationToken: authenticationToken,
                lease: lease,
                failure: error.localizedDescription
            )
            throw error
        }
    }

    private func runWithLeaseRenewal(
        request: ProcessRequest,
        lease: OCRWorkerJobLease,
        workerID: String,
        authenticationToken: String
    ) async throws -> ProcessResult {
        let renewalSeconds = max(5, Int(lease.expiresAt.timeIntervalSince(lease.leasedAt) / 3))
        return try await withThrowingTaskGroup(of: ProcessingEvent.self) { group in
            group.addTask {
                .completed(try await executor.execute(request))
            }
            group.addTask {
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(renewalSeconds))
                        _ = try await client.renew(
                            workerID: workerID,
                            authenticationToken: authenticationToken,
                            lease: lease
                        )
                    }
                    throw CancellationError()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return .leaseLost(error.localizedDescription)
                }
            }

            defer { group.cancelAll() }
            guard let event = try await group.next() else { throw CancellationError() }
            switch event {
            case .completed(let result): return result
            case .leaseLost(let message):
                throw OCRWorkerContainerError.containerFailed(status: -1, diagnostic: message)
            }
        }
    }
}
