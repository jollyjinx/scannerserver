import Foundation

public extension ExternalDocumentToolCommand {
    func processRequest(
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) -> ProcessRequest {
        ProcessRequest(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
    }
}

public enum DocumentProcessingStep: String, Equatable, Sendable {
    case removeBlankPages
    case cropPages
    case setCreatorMetadata
    case splitPDFPages
    case exportScanImages
}

public enum DocumentProcessingError: Error, Equatable, LocalizedError, Sendable {
    case subprocessFailed(
        step: DocumentProcessingStep,
        command: ExternalDocumentToolCommand,
        result: ProcessResult
    )
    case outputConflict(
        step: DocumentProcessingStep,
        command: ExternalDocumentToolCommand,
        result: ProcessResult
    )
    case missingFinalOutput(
        step: DocumentProcessingStep,
        command: ExternalDocumentToolCommand,
        result: ProcessResult
    )

    /// Status presented to shell-compatible callers of the former scan_once.sh workflow.
    public var compatibleExitStatus: Int32 {
        switch self {
        case .subprocessFailed(_, _, let result):
            result.exitStatus
        case .outputConflict:
            73
        case .missingFinalOutput:
            2
        }
    }

    /// The unmodified result returned by ProcessExecutor.
    public var processResult: ProcessResult {
        switch self {
        case .subprocessFailed(_, _, let result),
             .outputConflict(_, _, let result),
             .missingFinalOutput(_, _, let result):
            result
        }
    }

    public var errorDescription: String? {
        switch self {
        case .subprocessFailed(let step, _, let result):
            "Document tool \(step.rawValue) failed with exit status \(result.exitStatus)."
        case .outputConflict(let step, _, _):
            "Document tool \(step.rawValue) found an existing output file."
        case .missingFinalOutput(let step, _, _):
            "Document tool \(step.rawValue) did not emit a final output path."
        }
    }

    static func completedProcessFailure(
        step: DocumentProcessingStep,
        command: ExternalDocumentToolCommand,
        result: ProcessResult
    ) -> Self {
        let diagnostic = result.standardError.lowercased()
        if result.exitStatus == 73
            || diagnostic.contains("fileexistserror")
            || diagnostic.contains("already exists")
        {
            return .outputConflict(step: step, command: command, result: result)
        }
        return .subprocessFailed(step: step, command: command, result: result)
    }
}

public enum DocumentToolOutputPaths {
    public static func parse(_ standardOutput: String) -> [String] {
        standardOutput
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
