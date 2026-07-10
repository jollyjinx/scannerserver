import Foundation
import ScannerServerCore
import Testing

@Suite("Scan pipeline commands")
struct ScanPipelineCommandTests {
    @Test("Commands use native OCR and installed scan entry points")
    func commandConstruction() {
        let directory = URL(fileURLWithPath: "/tmp/work", isDirectory: true)
        let configuration = ScanPipelineConfiguration(
            environment: ["PATH": "/usr/local/bin", "SCAN_LANGUAGE": "nld"]
        )

        let scan = ScanPipelineCommands.scan(configuration: configuration, workingDirectory: directory)
        #expect(scan.executable == "scan-once")
        #expect(scan.arguments.isEmpty)
        #expect(scan.environment?["SCAN_LANGUAGE"] == "nld")
        #expect(scan.environment?["PATH"] == "/usr/local/bin")
        #expect(scan.workingDirectory == directory)

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

        let list = ScanPipelineCommands.listScanners(environment: ["PATH": "/sbin"])
        #expect(list.executable == "list-scanners")
        #expect(list.arguments.isEmpty)
        #expect(list.environment == ["PATH": "/sbin"])
    }

    @Test("OCR output paths reject non-PDF and already OCR inputs")
    func ocrOutputPathValidation() {
        #expect(OCRInputPath.outputPath(for: "/scans/input.pdf") == "/scans/input.ocr.pdf")
        #expect(OCRInputPath.outputPath(for: "/scans/input.ocr.pdf") == nil)
        #expect(OCRInputPath.outputPath(for: "/scans/input.png") == nil)
    }
}
