import Foundation

public struct ProcessRequest: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]?
    public let workingDirectory: URL?

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public struct ProcessResult: Equatable, Sendable {
    public let exitStatus: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitStatus: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { exitStatus == 0 }
}

public protocol ProcessExecutor: Sendable {
    func execute(_ request: ProcessRequest) async throws -> ProcessResult
}

public enum ProcessExecutorError: Error, Equatable, LocalizedError, Sendable {
    case executableNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let executable):
            "Executable not found in PATH: \(executable)"
        }
    }
}

public actor FoundationProcessExecutor: ProcessExecutor {
    private var runningProcesses: [UUID: Process] = [:]

    public init() {}

    public func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        try Task.checkCancellation()

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let identifier = UUID()

        process.executableURL = try executableURL(for: request)
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.workingDirectory
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        runningProcesses[identifier] = process

        defer {
            runningProcesses[identifier] = nil
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
        }

        async let outputData = Self.readToEnd(outputPipe.fileHandleForReading)
        async let errorData = Self.readToEnd(errorPipe.fileHandleForReading)

        do {
            let status = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { terminatedProcess in
                        continuation.resume(returning: terminatedProcess.terminationStatus)
                    }
                    do {
                        try process.run()
                        try? outputPipe.fileHandleForWriting.close()
                        try? errorPipe.fileHandleForWriting.close()
                    } catch {
                        try? outputPipe.fileHandleForWriting.close()
                        try? errorPipe.fileHandleForWriting.close()
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                Task { await self.terminate(identifier) }
            }

            try Task.checkCancellation()
            let (capturedOutput, capturedError) = await (outputData, errorData)
            return ProcessResult(
                exitStatus: status,
                standardOutput: String(decoding: capturedOutput, as: UTF8.self),
                standardError: String(decoding: capturedError, as: UTF8.self)
            )
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw error
        }
    }

    private func executableURL(for request: ProcessRequest) throws -> URL {
        if request.executable.contains("/") {
            return URL(fileURLWithPath: request.executable)
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

    private func terminate(_ identifier: UUID) {
        guard let process = runningProcesses[identifier], process.isRunning else { return }
        process.terminate()
    }

    @concurrent
    private nonisolated static func readToEnd(_ handle: FileHandle) async -> Data {
        handle.readDataToEndOfFile()
    }
}
