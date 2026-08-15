import Foundation

public protocol OCRWorkerResultValidating: Sendable {
    func validate(fileURL: URL) async throws
}

public struct QPDFOCRWorkerResultValidator: OCRWorkerResultValidating {
    private let executor: any ProcessExecutor

    public init(executor: any ProcessExecutor = FoundationProcessExecutor()) {
        self.executor = executor
    }

    public func validate(fileURL: URL) async throws {
        let result = try await executor.execute(ProcessRequest(
            executable: "qpdf",
            arguments: ["--check", fileURL.path]
        ))
        guard result.succeeded else {
            let diagnostic = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OCRWorkerResultValidationError.qpdfRejected(
                diagnostic.isEmpty ? "qpdf exited with status \(result.exitStatus)" : diagnostic
            )
        }
    }
}

public enum OCRWorkerResultValidationError: Error, LocalizedError, Sendable {
    case qpdfRejected(String)

    public var errorDescription: String? {
        switch self {
        case .qpdfRejected(let diagnostic):
            "OCR worker result failed qpdf validation: \(diagnostic)"
        }
    }
}
