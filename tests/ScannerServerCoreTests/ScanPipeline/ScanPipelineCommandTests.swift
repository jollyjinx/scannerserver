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

    @Test("OCR commands support a bounded worker count and nice priority")
    func boundedNiceOCR() {
        let request = ScanPipelineCommands.ocr(
            inputPath: "/scans/source.pdf",
            outputPath: "/scans/source.ocr.pdf",
            jobs: 10,
            niceLevel: 10
        )

        #expect(request.executable == "nice")
        #expect(request.arguments == [
            "-n", "10", "ocrmypdf",
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

    @Test("OCR output paths reject non-PDF and already OCR inputs")
    func ocrOutputPathValidation() {
        #expect(OCRInputPath.outputPath(for: "/scans/input.pdf") == "/scans/input.ocr.pdf")
        #expect(OCRInputPath.outputPath(for: "/scans/input.ocr.pdf") == nil)
        #expect(OCRInputPath.outputPath(for: "/scans/input.png") == nil)
    }
}
