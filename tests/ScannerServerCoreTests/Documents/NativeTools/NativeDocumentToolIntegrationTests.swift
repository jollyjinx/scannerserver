import Foundation
@testable import ScannerServerCore
import Testing

@Suite(
    "Native document tool integration",
    .enabled(if: NativeDocumentToolIntegrationEnvironment.shouldRun)
)
struct NativeDocumentToolIntegrationTests {
    @Test("Receipt fixture preserves legacy blank and crop results")
    func receiptFixtureParity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pdfURL = directory.appendingPathComponent("receipt.pdf")
        try #require(FileManager.default.fileExists(
            atPath: NativeDocumentToolIntegrationEnvironment.fixtureURL.path
        ))
        try FileManager.default.copyItem(
            at: NativeDocumentToolIntegrationEnvironment.fixtureURL,
            to: pdfURL
        )

        let executor = NativeDocumentToolExecutor(executor: FoundationProcessExecutor())
        let blankResult = try await executor.execute(ProcessRequest(
            executable: "remove-blank-pages",
            arguments: [pdfURL.path, "--debug"],
            workingDirectory: directory
        ))
        #expect(blankResult.succeeded)
        #expect(blankResult.standardOutput.contains("Removed 0 blank pages."))

        let cropResult = try await executor.execute(ProcessRequest(
            executable: "crop-pdf-pages",
            arguments: [pdfURL.path, "--debug"],
            workingDirectory: directory
        ))
        #expect(cropResult.succeeded)
        #expect(cropResult.standardOutput.contains("Cropped 2 pages."))

        let inspection = try await FoundationProcessExecutor().execute(ProcessRequest(
            executable: "qpdf",
            arguments: [
                "--json-output=2",
                "--json-stream-data=none",
                "--json-key=pages",
                pdfURL.path,
            ]
        ))
        try #require(inspection.succeeded)
        let document = try NativePDFJSONDocument(data: Data(inspection.standardOutput.utf8))
        #expect(document.pageReferences.count == 2)

        let expectedSizes = [(238.4, 801.68), (235.52, 806.0)]
        for (index, expected) in expectedSizes.enumerated() {
            let box = try document.mediaBox(forPageAt: index)
            #expect(abs((box.right - box.left) - expected.0) < 0.02)
            #expect(abs((box.top - box.bottom) - expected.1) < 0.02)
        }

        let check = try await FoundationProcessExecutor().execute(ProcessRequest(
            executable: "qpdf",
            arguments: ["--check", pdfURL.path]
        ))
        #expect(check.succeeded)
    }
}

private enum NativeDocumentToolIntegrationEnvironment {
    static let required = ProcessInfo.processInfo.environment[
        "SCANNERSERVER_REQUIRE_NATIVE_TOOL_TESTS"
    ] == "1"

    static let tools = ["qpdf", "pdfimages", "pdfinfo", "vips"]
    static let shouldRun = required || tools.allSatisfy(isAvailable)

    static let fixtureURL: URL = {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            repository.deleteLastPathComponent()
        }
        return repository.appendingPathComponent(
            "tests/fixtures/receipt-small-page.pdf",
            isDirectory: false
        )
    }()

    private static func isAvailable(_ executable: String) -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { directory in
            FileManager.default.isExecutableFile(
                atPath: URL(fileURLWithPath: String(directory), isDirectory: true)
                    .appendingPathComponent(executable)
                    .path
            )
        }
    }
}
