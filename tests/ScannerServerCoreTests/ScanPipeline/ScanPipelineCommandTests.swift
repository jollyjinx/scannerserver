import Foundation
import ScannerServerCore
import Testing

@Suite("Scan pipeline commands")
struct ScanPipelineCommandTests {
    @Test("OCR commands use the installed native entry point")
    func commandConstruction() {
        let configuration = ScanPipelineConfiguration(
            environment: ["PATH": "/usr/local/bin", "SCAN_LANGUAGE": "nld"]
        )

        let ocr = ScanPipelineCommands.ocr(
            inputPath: "/scans/input.pdf",
            environment: configuration.environment
        )
        #expect(ocr.executable == "ocrmypdf")
        #expect(ocr.arguments == [
            "--language", "nld",
            "--rotate-pages",
            "--rotate-pages-threshold", "2.0",
            "--deskew",
            "--optimize", "1",
            "/scans/input.pdf",
            "/scans/input.ocr.pdf",
        ])
        #expect(ocr.environment?["SCAN_LANGUAGE"] == "nld")
    }

    @Test("OCR output paths reject non-PDF and already OCR inputs")
    func ocrOutputPathValidation() {
        #expect(OCRInputPath.outputPath(for: "/scans/input.pdf") == "/scans/input.ocr.pdf")
        #expect(OCRInputPath.outputPath(for: "/scans/input.ocr.pdf") == nil)
        #expect(OCRInputPath.outputPath(for: "/scans/input.png") == nil)
    }
}
