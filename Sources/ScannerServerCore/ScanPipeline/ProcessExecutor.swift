import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ProcessRequest: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]?
    public let workingDirectory: URL?
    public let timeoutMilliseconds: UInt64?
    public let niceLevel: Int?
    public let ocrWorkerMetadata: OCRWorkerJobMetadata?
    public let ocrWorkerCropConfiguration: OCRWorkerCropConfiguration?

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        timeoutMilliseconds: UInt64? = nil,
        niceLevel: Int? = nil,
        ocrWorkerMetadata: OCRWorkerJobMetadata? = nil,
        ocrWorkerCropConfiguration: OCRWorkerCropConfiguration? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeoutMilliseconds = timeoutMilliseconds
        self.niceLevel = niceLevel.map { min(max($0, 1), 19) }
        self.ocrWorkerMetadata = ocrWorkerMetadata
        self.ocrWorkerCropConfiguration = ocrWorkerCropConfiguration
    }

    func applyingNiceLevel(_ niceLevel: Int) -> ProcessRequest {
        ProcessRequest(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeoutMilliseconds: timeoutMilliseconds,
            niceLevel: niceLevel,
            ocrWorkerMetadata: ocrWorkerMetadata,
            ocrWorkerCropConfiguration: ocrWorkerCropConfiguration
        )
    }

    fileprivate var launchRequest: ProcessRequest {
        guard let niceLevel, executable != "nice" else { return self }
        return ProcessRequest(
            executable: "nice",
            arguments: ["-n", String(niceLevel), executable] + arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeoutMilliseconds: timeoutMilliseconds,
            ocrWorkerMetadata: ocrWorkerMetadata,
            ocrWorkerCropConfiguration: ocrWorkerCropConfiguration
        )
    }
}

public enum ProcessExecutionLocation: String, Equatable, Sendable {
    case local
    case remote
}

public struct ProcessResult: Equatable, Sendable {
    public let exitStatus: Int32
    public let standardOutput: String
    public let standardError: String
    public let deferredScanProcessing: DeferredScanProcessing?
    public let postProcessingHandled: Bool
    public let executionLocation: ProcessExecutionLocation

    public init(
        exitStatus: Int32,
        standardOutput: String = "",
        standardError: String = "",
        deferredScanProcessing: DeferredScanProcessing? = nil,
        postProcessingHandled: Bool = false,
        executionLocation: ProcessExecutionLocation = .local
    ) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.deferredScanProcessing = deferredScanProcessing
        self.postProcessingHandled = postProcessingHandled
        self.executionLocation = executionLocation
    }

    public var succeeded: Bool { exitStatus == 0 }
}

public protocol ProcessExecutor: Sendable {
    func execute(_ request: ProcessRequest) async throws -> ProcessResult
}

struct NiceProcessExecutor: ProcessExecutor {
    let executor: any ProcessExecutor
    let niceLevel: Int

    func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        try await executor.execute(request.applyingNiceLevel(niceLevel))
    }
}

public enum ProcessExecutorError: Error, Equatable, LocalizedError, Sendable {
    case executableNotFound(String)
    case launchFailed(executable: String, code: Int32)
    case waitFailed(code: Int32)
    case readFailed(code: Int32)
    case timedOut(milliseconds: UInt64)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let executable):
            "Executable not found in PATH: \(executable)"
        case let .launchFailed(executable, code):
            "Could not launch \(executable): POSIX error \(code)"
        case .waitFailed(let code):
            "Could not wait for subprocess: POSIX error \(code)"
        case .readFailed(let code):
            "Could not read subprocess output: POSIX error \(code)"
        case .timedOut(let milliseconds):
            "Subprocess timed out after \(milliseconds) ms"
        }
    }
}

public actor FoundationProcessExecutor: ProcessExecutor {
    /// POSIX pipe reads and `waitpid` are blocking calls. Running them on Swift's
    /// cooperative executor can consume every worker while a document tool is
    /// active, preventing unrelated actors (including HTTP and button recovery)
    /// from making progress.
    private nonisolated static let blockingQueue = DispatchQueue(
        label: "eu.jinx.scannerserver.process-io",
        qos: .utility,
        attributes: .concurrent
    )

    private struct RunningProcess: Sendable {
        let processID: pid_t
    }

    private struct SpawnedProcess: Sendable {
        let processID: pid_t
        let standardOutput: Int32
        let standardError: Int32
    }

    private enum WaitOutcome: Sendable {
        case exited(Int32)
    }

    private var runningProcesses: [UUID: RunningProcess] = [:]
    private let terminationGracePeriodMilliseconds: UInt64

    public init(terminationGracePeriodMilliseconds: UInt64 = 250) {
        self.terminationGracePeriodMilliseconds = terminationGracePeriodMilliseconds
    }

    public func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        try Task.checkCancellation()

        let launchRequest = request.launchRequest
        let executableURL = try executableURL(for: launchRequest)
        let spawned = try Self.spawn(launchRequest, executableURL: executableURL)
        let identifier = UUID()
        runningProcesses[identifier] = RunningProcess(processID: spawned.processID)

        defer {
            runningProcesses[identifier] = nil
            Self.closeDescriptor(spawned.standardOutput)
            Self.closeDescriptor(spawned.standardError)
        }

        async let outputData = Self.readToEnd(spawned.standardOutput)
        async let errorData = Self.readToEnd(spawned.standardError)

        do {
            let status = try await withTaskCancellationHandler {
                try await waitForTermination(
                    identifier: identifier,
                    processID: spawned.processID,
                    timeoutMilliseconds: launchRequest.timeoutMilliseconds
                )
            } onCancel: {
                Task { await self.requestTermination(identifier) }
            }

            try Task.checkCancellation()
            let (capturedOutput, capturedError) = try await (outputData, errorData)
            return ProcessResult(
                exitStatus: status,
                standardOutput: String(decoding: capturedOutput, as: UTF8.self),
                standardError: String(decoding: capturedError, as: UTF8.self)
            )
        } catch {
            requestTermination(identifier)
            throw error
        }
    }

    private func executableURL(for request: ProcessRequest) throws -> URL {
        if request.executable.contains("/") {
            let path = URL(fileURLWithPath: request.executable).path
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw ProcessExecutorError.executableNotFound(request.executable)
            }
            return URL(fileURLWithPath: path)
        }

        let path = request.environment?["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(request.executable)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw ProcessExecutorError.executableNotFound(request.executable)
    }

    private func waitForTermination(
        identifier: UUID,
        processID: pid_t,
        timeoutMilliseconds: UInt64?
    ) async throws -> Int32 {
        guard let timeoutMilliseconds else {
            return try await Self.wait(for: processID)
        }

        return try await withThrowingTaskGroup(of: WaitOutcome.self) { group in
            group.addTask {
                .exited(try await Self.wait(for: processID))
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(Int64(clamping: timeoutMilliseconds)))
                try Task.checkCancellation()
                await self.requestTermination(identifier)
                throw ProcessExecutorError.timedOut(milliseconds: timeoutMilliseconds)
            }

            defer { group.cancelAll() }
            guard let outcome = try await group.next() else {
                throw CancellationError()
            }
            switch outcome {
            case .exited(let status):
                return status
            }
        }
    }

    private func requestTermination(_ identifier: UUID) {
        guard let running = runningProcesses[identifier] else { return }
        Self.signalProcessGroup(running.processID, signal: SIGTERM)

        guard terminationGracePeriodMilliseconds > 0 else {
            Self.signalProcessGroup(running.processID, signal: SIGKILL)
            return
        }

        let gracePeriod = terminationGracePeriodMilliseconds
        Task {
            try? await Task.sleep(for: .milliseconds(Int64(clamping: gracePeriod)))
            guard runningProcesses[identifier]?.processID == running.processID else { return }
            Self.signalProcessGroup(running.processID, signal: SIGKILL)
        }
    }

    private nonisolated static func spawn(
        _ request: ProcessRequest,
        executableURL: URL
    ) throws -> SpawnedProcess {
        var outputDescriptors = [Int32](repeating: -1, count: 2)
        var errorDescriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&outputDescriptors) == 0 else {
            throw ProcessExecutorError.launchFailed(executable: request.executable, code: errno)
        }
        guard pipe(&errorDescriptors) == 0 else {
            let code = errno
            closeDescriptor(outputDescriptors[0])
            closeDescriptor(outputDescriptors[1])
            throw ProcessExecutorError.launchFailed(executable: request.executable, code: code)
        }

        #if canImport(Darwin)
        var fileActions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        #else
        var fileActions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        var processID: pid_t = 0

        let cleanupDescriptors = {
            closeDescriptor(outputDescriptors[0])
            closeDescriptor(outputDescriptors[1])
            closeDescriptor(errorDescriptors[0])
            closeDescriptor(errorDescriptors[1])
        }

        var code = posix_spawn_file_actions_init(&fileActions)
        guard code == 0 else {
            cleanupDescriptors()
            throw ProcessExecutorError.launchFailed(executable: request.executable, code: code)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        code = posix_spawnattr_init(&attributes)
        guard code == 0 else {
            cleanupDescriptors()
            throw ProcessExecutorError.launchFailed(executable: request.executable, code: code)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        code = posix_spawn_file_actions_adddup2(&fileActions, outputDescriptors[1], STDOUT_FILENO)
        if code == 0 {
            code = posix_spawn_file_actions_adddup2(&fileActions, errorDescriptors[1], STDERR_FILENO)
        }
        for descriptor in outputDescriptors + errorDescriptors where code == 0 {
            code = posix_spawn_file_actions_addclose(&fileActions, descriptor)
        }
        if code == 0, let workingDirectory = request.workingDirectory {
            code = workingDirectory.path.withCString {
                posix_spawn_file_actions_addchdir_np(&fileActions, $0)
            }
        }
        if code == 0 {
            code = posix_spawnattr_setpgroup(&attributes, 0)
        }
        if code == 0 {
            code = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        }
        guard code == 0 else {
            cleanupDescriptors()
            throw ProcessExecutorError.launchFailed(executable: request.executable, code: code)
        }

        let arguments = [executableURL.path] + request.arguments
        let environment = (request.environment ?? ProcessInfo.processInfo.environment)
            .map { "\($0.key)=\($0.value)" }
            .sorted()

        code = withCStringArray(arguments) { argumentPointer in
            withCStringArray(environment) { environmentPointer in
                executableURL.path.withCString { executablePointer in
                    posix_spawn(
                        &processID,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argumentPointer,
                        environmentPointer
                    )
                }
            }
        }

        closeDescriptor(outputDescriptors[1])
        closeDescriptor(errorDescriptors[1])
        outputDescriptors[1] = -1
        errorDescriptors[1] = -1

        guard code == 0 else {
            cleanupDescriptors()
            throw ProcessExecutorError.launchFailed(executable: request.executable, code: code)
        }

        return SpawnedProcess(
            processID: processID,
            standardOutput: outputDescriptors[0],
            standardError: errorDescriptors[0]
        )
    }

    private nonisolated static func withCStringArray<Result>(
        _ values: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        let strings = values.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var pointers: [UnsafeMutablePointer<CChar>?] = strings + [nil]
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private nonisolated static func wait(for processID: pid_t) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            blockingQueue.async {
                continuation.resume(with: Result { try waitSynchronously(for: processID) })
            }
        }
    }

    private nonisolated static func waitSynchronously(for processID: pid_t) throws -> Int32 {
        var status: Int32 = 0
        while true {
            let result = waitpid(processID, &status, 0)
            if result == processID {
                let signal = status & 0x7f
                return signal == 0 ? (status >> 8) & 0xff : 128 + signal
            }
            if result == -1, errno == EINTR { continue }
            throw ProcessExecutorError.waitFailed(code: errno)
        }
    }

    private nonisolated static func readToEnd(_ descriptor: Int32) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            blockingQueue.async {
                continuation.resume(with: Result { try readToEndSynchronously(descriptor) })
            }
        }
    }

    private nonisolated static func readToEndSynchronously(_ descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                throw ProcessExecutorError.readFailed(code: errno)
            }
        }
    }

    private nonisolated static func signalProcessGroup(_ processID: pid_t, signal: Int32) {
        _ = kill(-processID, signal)
    }

    private nonisolated static func closeDescriptor(_ descriptor: Int32) {
        if descriptor >= 0 { _ = close(descriptor) }
    }
}
