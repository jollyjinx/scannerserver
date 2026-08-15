import Foundation
import ScannerServerCore
import Testing

@Suite("OCR worker result validation")
struct OCRWorkerResultValidatorTests {
    @Test("qpdf checks the staging file before publication")
    func request() async throws {
        let executor = ResultValidationExecutor(result: ProcessResult(exitStatus: 0))
        let validator = QPDFOCRWorkerResultValidator(executor: executor)
        let url = URL(fileURLWithPath: "/scans/.ocr-upload.job")

        try await validator.validate(fileURL: url)

        #expect(await executor.requests == [ProcessRequest(
            executable: "qpdf",
            arguments: ["--check", url.path]
        )])
    }

    @Test("qpdf rejection is returned to the upload boundary")
    func rejection() async {
        let executor = ResultValidationExecutor(result: ProcessResult(
            exitStatus: 2,
            standardError: "damaged PDF"
        ))
        let validator = QPDFOCRWorkerResultValidator(executor: executor)

        await #expect(throws: OCRWorkerResultValidationError.self) {
            try await validator.validate(fileURL: URL(fileURLWithPath: "/tmp/result.pdf"))
        }
    }
}

private actor ResultValidationExecutor: ProcessExecutor {
    private(set) var requests: [ProcessRequest] = []
    let result: ProcessResult

    init(result: ProcessResult) { self.result = result }

    func execute(_ request: ProcessRequest) -> ProcessResult {
        requests.append(request)
        return result
    }
}
