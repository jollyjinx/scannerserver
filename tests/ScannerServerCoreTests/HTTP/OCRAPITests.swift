import Foundation
import ScannerServerCore
import Testing

@Suite("OCR API adapters")
struct OCRAPITests {
    @Test("PDF text extraction reads the existing text layer as UTF-8 layout text")
    func extractsPDFTextLayer() async throws {
        let executor = CapturingPDFTextExecutor(result: ProcessResult(
            exitStatus: 0,
            standardOutput: "First page\u{000c}Second page\n"
        ))
        let extractor = PDFToTextExtractor(executor: executor)
        let input = URL(fileURLWithPath: "/scans/invoice.ocr.pdf")

        let text = try await extractor.extractText(from: input)

        #expect(text == "First page\u{000c}Second page\n")
        let request = try #require(await executor.lastRequest)
        #expect(request.executable == "pdftotext")
        #expect(request.arguments == [
            "-layout", "-enc", "UTF-8", "/scans/invoice.ocr.pdf", "-",
        ])
    }

    @Test("PDF text extraction reports subprocess diagnostics")
    func reportsPDFTextFailure() async {
        let extractor = PDFToTextExtractor(executor: CapturingPDFTextExecutor(
            result: ProcessResult(exitStatus: 1, standardError: "damaged xref")
        ))

        await #expect(throws: OCRTextExtractionError.failed("damaged xref")) {
            try await extractor.extractText(from: URL(fileURLWithPath: "/scans/broken.pdf"))
        }
    }
}

private actor CapturingPDFTextExecutor: ProcessExecutor {
    private let result: ProcessResult
    private(set) var lastRequest: ProcessRequest?

    init(result: ProcessResult) {
        self.result = result
    }

    func execute(_ request: ProcessRequest) -> ProcessResult {
        lastRequest = request
        return result
    }
}
