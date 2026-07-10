import Foundation
import ScannerServerCore
import Testing

@Suite("Scan file compatibility")
struct ScanFileGroupingTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test(
        "Variant, kind, rank, and base-name preserve the legacy contract",
        arguments: [
            ("2026-07-10.120000.pdf", ScanFileVariant.source, 0, "2026-07-10.120000.pdf", ScanFileKind.sourceScan),
            ("2026-07-10.120000.ocr.pdf", .ocr, 1, "2026-07-10.120000.pdf", .ocrPDF),
            ("2026-07-10.120000-page-0007.png", .png, 2, "2026-07-10.120000.png", .pngPage("7")),
            ("image.png", .png, 2, "image.png", .pngImage),
            ("image-page-0001.PNG", .png, 2, "image-page-0001.PNG", .pngImage),
            ("image.OCR.pdf", .source, 0, "image.OCR.pdf", .sourceScan),
        ]
    )
    func classification(
        _ name: String,
        _ variant: ScanFileVariant,
        _ rank: Int,
        _ baseName: String,
        _ kind: ScanFileKind
    ) throws {
        let file = try ScanFile(name: name, modificationDate: .distantPast)

        #expect(file.variant == variant)
        #expect(file.variantRank == rank)
        #expect(file.baseName == baseName)
        #expect(file.kind == kind)
    }

    @Test("Documents preserve legacy grouping, sorting, and preferred paths")
    func groupingAndViewSelection() throws {
        let files = try [
            file("2026-07-09.090000.pdf"),
            file("2026-07-09.090000.ocr.pdf"),
            file("2026-07-10.120000-page-0002.png"),
            file("2026-07-10.120000-page-0001.png"),
            file("2026-07-10.130000-page-0001.pdf"),
            file("2026-07-10.130000-page-0001.ocr.pdf"),
        ]

        let groups = ScanFileGrouping.groups(for: files, timeZone: utc)

        #expect(groups.map(\.day) == ["Friday, 2026-07-10", "Thursday, 2026-07-09"])
        #expect(groups[0].files.map(\.title) == [
            "2026-07-10.130000-page-0001.pdf",
            "2026-07-10.120000.png",
        ])
        #expect(groups[0].files[0].viewName == "2026-07-10.130000-page-0001.ocr.pdf")
        #expect(groups[0].files[0].previewName == "2026-07-10.130000-page-0001.ocr.pdf")
        #expect(groups[0].files[0].viewKind == .ocrPDF)
        #expect(groups[0].files[0].files.map(\.variant) == [.source, .ocr])
        #expect(groups[0].files[1].viewName == "2026-07-10.120000-page-0001.png")
        #expect(groups[0].files[1].files.map(\.name) == [
            "2026-07-10.120000-page-0001.png",
            "2026-07-10.120000-page-0002.png",
        ])
        #expect(groups[1].files[0].viewName == "2026-07-09.090000.ocr.pdf")
    }

    @Test("Invalid date prefixes fall back to modification day")
    func modificationDateFallback() throws {
        let date = Date(timeIntervalSince1970: 1_786_886_400) // 2026-08-16 00:00:00 UTC
        let file = try ScanFile(name: "receipt.pdf", modificationDate: date)

        #expect(ScanFileGrouping.day(for: file, timeZone: utc) == "Sunday, 2026-08-16")
    }

    private func file(_ name: String) throws -> ScanFile {
        try ScanFile(name: name, modificationDate: .distantPast)
    }
}
