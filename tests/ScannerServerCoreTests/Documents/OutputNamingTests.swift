import Foundation
import ScannerServerCore
import Testing

@Suite("Document output naming")
struct OutputNamingTests {
    @Test("All compatible output variants use the existing names")
    func compatibleNames() throws {
        let timestamp = try ScanTimestamp(rawValue: "2026-07-10.142305")
        let firstPage = try ScanPageNumber(rawValue: 1)

        #expect(try ScanOutputName(timestamp: timestamp, format: .pdf).fileName.rawValue == "2026-07-10.142305.pdf")
        #expect(try ScanOutputName(timestamp: timestamp, format: .pdf, isOCR: true).fileName.rawValue == "2026-07-10.142305.ocr.pdf")
        #expect(try ScanOutputName(timestamp: timestamp, format: .pdf, pageNumber: firstPage).fileName.rawValue == "2026-07-10.142305-page-0001.pdf")
        #expect(try ScanOutputName(timestamp: timestamp, format: .pdf, pageNumber: firstPage, isOCR: true).fileName.rawValue == "2026-07-10.142305-page-0001.ocr.pdf")
        #expect(try ScanOutputName(timestamp: timestamp, format: .png, pageNumber: firstPage).fileName.rawValue == "2026-07-10.142305-page-0001.png")
    }

    @Test("Page padding is a minimum width and previews stay in .previews")
    func pagePaddingAndPreviewName() throws {
        let timestamp = try ScanTimestamp(rawValue: "2026-07-10.142305")
        let page = try ScanPageNumber(rawValue: 10_000)
        let source = try ScanOutputName(
            timestamp: timestamp,
            format: .png,
            pageNumber: page
        ).fileName

        #expect(source.rawValue == "2026-07-10.142305-page-10000.png")
        #expect(PreviewOutputName(sourceFileName: source).relativePath == ".previews/2026-07-10.142305-page-10000.png.jpg")
    }

    @Test(
        "Invalid timestamps are rejected",
        arguments: [
            "2026-07-10",
            "2026-02-29.120000",
            "2026-13-10.120000",
            "2026-07-10.246000",
            "2026-07-10T120000",
        ]
    )
    func invalidTimestamps(_ value: String) {
        #expect(throws: ScanTimestampError.self) {
            try ScanTimestamp(rawValue: value)
        }
    }

    @Test("Generated names reject impossible format combinations")
    func invalidCombinations() throws {
        let timestamp = try ScanTimestamp(rawValue: "2026-07-10.142305")

        #expect(throws: ScanOutputNameError.pngRequiresPageNumber) {
            try ScanOutputName(timestamp: timestamp, format: .png)
        }
        #expect(throws: ScanOutputNameError.ocrRequiresPDF) {
            try ScanOutputName(
                timestamp: timestamp,
                format: .png,
                pageNumber: ScanPageNumber(rawValue: 1),
                isOCR: true
            )
        }
        #expect(throws: ScanPageNumberError.mustBePositive(0)) {
            try ScanPageNumber(rawValue: 0)
        }
    }
}
