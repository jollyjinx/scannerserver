import Foundation
import ScannerServerCore
import Testing

@Suite("Scan output paths")
struct ScanOutputPathsTests {
    @Test("Output parsing trims lines and retains existing files only")
    func parsing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pdf = directory.appendingPathComponent("scan.pdf")
        let png = directory.appendingPathComponent("scan-1.png")
        #expect(FileManager.default.createFile(atPath: pdf.path, contents: Data()))
        #expect(FileManager.default.createFile(atPath: png.path, contents: Data()))

        let output = " \(pdf.path)\n\nmissing.pdf\r\n\(png.path) \n"
        #expect(ScanOutputPaths.candidates(from: output) == [pdf.path, "missing.pdf", png.path])
        #expect(ScanOutputPaths.existing(from: output) == [pdf.path, png.path])
    }

    @Test("OCR enqueue rules require enabled raw PDF files")
    func enqueueRules() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rawPDF = directory.appendingPathComponent("scan.PDF")
        let ocrPDF = directory.appendingPathComponent("scan.ocr.pdf")
        let image = directory.appendingPathComponent("scan.png")
        for url in [rawPDF, ocrPDF, image] {
            #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
        }

        let enabled = ScanPipelineConfiguration(environment: [:])
        let disabled = ScanPipelineConfiguration(
            environment: [:],
            modeOverrides: ["SCAN_OCR_ENABLED": "false"]
        )

        #expect(ScanOutputPaths.shouldEnqueueOCR(path: rawPDF.path, configuration: enabled))
        #expect(!ScanOutputPaths.shouldEnqueueOCR(path: ocrPDF.path, configuration: enabled))
        #expect(!ScanOutputPaths.shouldEnqueueOCR(path: image.path, configuration: enabled))
        #expect(!ScanOutputPaths.shouldEnqueueOCR(path: rawPDF.path, configuration: disabled))
        #expect(!ScanOutputPaths.shouldEnqueueOCR(
            path: directory.appendingPathComponent("missing.pdf").path,
            configuration: enabled
        ))
    }
}
