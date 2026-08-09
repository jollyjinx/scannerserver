import Foundation
import ScannerServerCore
import Testing

@Suite("External document tool requests")
struct DocumentToolRequestTests {
    @Test("Blank-page removal preserves pipeline defaults")
    func removeBlankPageDefaults() {
        let command = RemoveBlankPagesRequest(pdfPath: "/work/raw.pdf").command

        #expect(command.executable == "remove-blank-pages")
        #expect(command.arguments == [
            "/work/raw.pdf",
            "--white-threshold", "230",
            "--content-ratio-threshold", "0.003",
            "--mean-threshold", "248.0",
        ])
    }

    @Test("Blank-page optional flags preserve argparse spelling")
    func removeBlankPageFlags() {
        let command = RemoveBlankPagesRequest(
            pdfPath: "raw.pdf",
            keepOne: false,
            debug: true
        ).command

        #expect(command.arguments.suffix(2) == ["--no-keep-one", "--debug"])
    }

    @Test("Cropping preserves pipeline defaults and argument order")
    func cropDefaults() {
        let command = CropPDFPagesRequest(pdfPath: "/work/raw.pdf").command

        #expect(command.executable == "crop-pdf-pages")
        #expect(command.arguments == [
            "/work/raw.pdf",
            "--background-delta", "8",
            "--border-px", "64",
            "--margin-points", "1",
            "--max-width-ratio", "0.80",
            "--max-height-ratio", "0.80",
            "--min-density", "0.08",
        ])
    }

    @Test("Cropping optional flags follow threshold arguments")
    func cropFlags() {
        let command = CropPDFPagesRequest(
            pdfPath: "raw.pdf",
            keepOriginalBoxes: true,
            debug: true
        ).command

        #expect(command.arguments.suffix(2) == ["--keep-original-boxes", "--debug"])
    }

    @Test("Metadata, splitting, and image export requests preserve compatibility")
    func positionalCommands() throws {
        let timestamp = try ScanTimestamp(rawValue: "2026-07-10.142305")
        let split = SplitPDFPagesRequest(
            pdfPath: "/work/raw.pdf",
            outputDirectory: "/scans",
            prefix: timestamp
        )
        let export = ExportScanImagesRequest(
            pdfPath: "/work/raw.pdf",
            outputDirectory: "/scans",
            prefix: timestamp
        )
        let page = try ScanPageNumber(rawValue: 3)

        #expect(SetPDFCreatorRequest(pdfPath: "/work/raw.pdf").command == ExternalDocumentToolCommand(
            executable: "set-pdf-creator",
            arguments: ["/work/raw.pdf", "--creator", "ScanSnap"]
        ))
        #expect(split.command == ExternalDocumentToolCommand(
            executable: "split-pdf-pages",
            arguments: ["/work/raw.pdf", "/scans", "2026-07-10.142305"]
        ))
        #expect(split.outputName(for: page).rawValue == "2026-07-10.142305-page-0003.pdf")
        #expect(export.command == ExternalDocumentToolCommand(
            executable: "export-scan-images",
            arguments: ["/work/raw.pdf", "/scans", "2026-07-10.142305"]
        ))
        #expect(export.outputName(for: page).rawValue == "2026-07-10.142305-page-0003.png")
    }
}

@Suite("Preview compatibility")
struct PreviewCompatibilityTests {
    @Test("Preview requests retain dimensions, quality, and explicit native fallback")
    func requestDefaults() {
        let pdf = PreviewToolRequest(
            sourcePath: "/scans/scan.pdf",
            destinationPath: "/scans/.previews/scan.pdf.jpg",
            sourceKind: .pdf
        )
        let png = PreviewToolRequest(
            sourcePath: "/scans/scan.png",
            destinationPath: "/scans/.previews/scan.png.jpg",
            sourceKind: .png
        )

        #expect(pdf.maximumWidth == 320)
        #expect(pdf.maximumHeight == 420)
        #expect(pdf.renderedJPEGQuality == 82)
        #expect(pdf.optimizeRenderedJPEG)
        #expect(pdf.fallbackJPEGQuality == 75)
        #expect(pdf.renderingPlan == .nativeRenderingRequired(.pdfImageExtraction, fallback: .neutralJPEG))
        #expect(png.renderingPlan == .nativeRenderingRequired(.pngDecoding, fallback: .neutralJPEG))
    }

    @Test("Neutral fallback is the deterministic current JPEG placeholder")
    func placeholderBytes() {
        let bytes = PlaceholderPreview.jpegBytes

        #expect(PlaceholderPreview.width == 320)
        #expect(PlaceholderPreview.height == 420)
        #expect(PlaceholderPreview.rgb.red == 0xf1)
        #expect(PlaceholderPreview.rgb.green == 0xf3)
        #expect(PlaceholderPreview.rgb.blue == 0xf4)
        #expect(PlaceholderPreview.jpegQuality == 75)
        #expect(bytes.count == 2_787)
        #expect(Array(bytes.prefix(4)) == [0xff, 0xd8, 0xff, 0xe0])
        #expect(Array(bytes.suffix(2)) == [0xff, 0xd9])
        #expect(PreviewFallback.neutralJPEG.bytes == bytes)
    }
}
