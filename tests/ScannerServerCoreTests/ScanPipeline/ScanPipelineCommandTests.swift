import Foundation
import ScannerServerCore
import Testing

@Suite("Local OCR process adapter")
struct LocalOCRProcessAdapterTests {
    @Test("Typed OCR requests map to the installed native entry point")
    func commandConstruction() {
        let configuration = ScanPipelineConfiguration(
            environment: ["PATH": "/usr/local/bin", "SCAN_LANGUAGE": "nld"]
        )

        let request = OCRExecutionRequest(
            inputURL: URL(fileURLWithPath: "/scans/input.pdf"),
            outputURL: URL(fileURLWithPath: "/scans/input.ocr.pdf"),
            options: OCRProcessingOptions(environment: configuration.environment, jobs: 1),
            context: OCRProcessContext(environment: configuration.environment)
        )
        let ocr = LocalOCRProcessAdapter(
            processExecutor: FakeProcessExecutor(stubs: [])
        ).processRequest(for: request)
        #expect(ocr.executable == "ocrmypdf")
        #expect(ocr.arguments == [
            "--language", "nld",
            "--rotate-pages",
            "--rotate-pages-threshold", "2.0",
            "--deskew",
            "--optimize", "1",
            "--jobs", "1",
            "/scans/input.pdf",
            "/scans/input.ocr.pdf",
        ])
        #expect(ocr.environment?["SCAN_LANGUAGE"] == "nld")
    }

    @Test("OCR commands support a bounded worker count and nice priority")
    func boundedNiceOCR() {
        let typedRequest = OCRExecutionRequest(
            inputURL: URL(fileURLWithPath: "/scans/source.pdf"),
            outputURL: URL(fileURLWithPath: "/scans/source.ocr.pdf"),
            options: OCRProcessingOptions(languages: ["deu", "eng"], jobs: 10),
            context: OCRProcessContext(niceLevel: 10)
        )
        let request = LocalOCRProcessAdapter(
            processExecutor: FakeProcessExecutor(stubs: [])
        ).processRequest(for: typedRequest)

        #expect(request.executable == "ocrmypdf")
        #expect(request.niceLevel == 10)
        #expect(request.arguments == [
            "--language", "deu+eng",
            "--rotate-pages",
            "--rotate-pages-threshold", "2.0",
            "--deskew",
            "--optimize", "1",
            "--jobs", "10",
            "/scans/source.pdf",
            "/scans/source.ocr.pdf",
        ])
    }

    @Test("Local OCR owns crop and blank-page post-processing and preserves failures")
    func localPostProcessingOutcome() async throws {
        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "ocr complete\n")),
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 7, standardError: "blank filtering failed\n")),
        ])
        let adapter = LocalOCRProcessAdapter(
            processExecutor: executor,
            documentExecutor: executor
        )
        let result = try await adapter.execute(OCRExecutionRequest(
            inputURL: URL(fileURLWithPath: "/scans/input.pdf"),
            outputURL: URL(fileURLWithPath: "/scans/input.ocr.pdf"),
            options: OCRProcessingOptions(languages: ["deu", "eng"], jobs: 2),
            context: OCRProcessContext(niceLevel: 12),
            cropConfiguration: OCRWorkerCropConfiguration(),
            blankPageConfiguration: OCRWorkerBlankPageConfiguration()
        ))

        #expect(result.outcome == .failed(exitStatus: 7))
        #expect(result.location == .local)
        #expect(result.standardError == "blank filtering failed\n")
        let requests = await executor.requests()
        #expect(requests.map(\.executable) == [
            "ocrmypdf", "crop-pdf-pages", "remove-blank-pages",
        ])
        #expect(requests.allSatisfy { $0.niceLevel == 12 })
    }

    @Test("OCR output paths reject non-PDF and already OCR inputs")
    func ocrOutputPathValidation() {
        #expect(OCRInputPath.outputPath(for: "/scans/input.pdf") == "/scans/input.ocr.pdf")
        #expect(OCRInputPath.outputPath(for: "/scans/input.ocr.pdf") == nil)
        #expect(OCRInputPath.outputPath(for: "/scans/input.png") == nil)
    }
}
