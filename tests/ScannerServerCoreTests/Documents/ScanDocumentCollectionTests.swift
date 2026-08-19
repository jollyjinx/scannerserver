import Foundation
import ScannerServerCore
import Testing

@Suite("Scan document collection lifecycle")
struct ScanDocumentCollectionTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test("Discovery exposes only regular scan outputs and preserves document grouping")
    func discovery() async throws {
        let fixture = try CollectionFixture()
        defer { fixture.remove() }
        try fixture.write("source", named: "2026-08-19.120000.pdf")
        try fixture.write("searchable", named: "2026-08-19.120000.ocr.pdf")
        try fixture.write("image", named: "2026-08-18.090000-page-0001.png")
        try fixture.write("hidden", named: ".hidden.pdf")
        try fixture.write("notes", named: "notes.txt")
        try FileManager.default.createDirectory(
            at: fixture.outputDirectory.appendingPathComponent("directory.pdf"),
            withIntermediateDirectories: false
        )

        let groups = await fixture.collection.groups(timeZone: utc)

        #expect(groups.map(\.day) == ["Wednesday, 2026-08-19", "Tuesday, 2026-08-18"])
        #expect(groups[0].files.count == 1)
        #expect(groups[0].files[0].files.map(\.name) == [
            "2026-08-19.120000.pdf",
            "2026-08-19.120000.ocr.pdf",
        ])
        #expect(groups[0].files[0].viewName == "2026-08-19.120000.ocr.pdf")
        #expect(groups[1].files[0].files.map(\.name) == [
            "2026-08-18.090000-page-0001.png"
        ])
    }

    @Test("Validated reads return bytes and media type without escaping the collection")
    func validatedReads() async throws {
        let fixture = try CollectionFixture()
        defer { fixture.remove() }
        try fixture.write("pdf", named: "scan.pdf")
        try fixture.write("png", named: "scan.png")
        let outsideURL = fixture.root.appendingPathComponent("outside.pdf")
        try Data("outside".utf8).write(to: outsideURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.outputDirectory.appendingPathComponent("linked.pdf"),
            withDestinationURL: outsideURL
        )

        let pdf = await fixture.collection.resource(named: "scan.pdf")
        let png = await fixture.collection.resource(named: "scan.png")

        #expect(pdf?.data == Data("pdf".utf8))
        #expect(pdf?.contentType == "application/pdf")
        #expect(png?.data == Data("png".utf8))
        #expect(png?.contentType == "image/png")
        #expect(await fixture.collection.resource(named: "../outside.pdf") == nil)
        #expect(await fixture.collection.resource(named: "linked.pdf") == nil)
        #expect(await fixture.collection.resource(named: "missing.pdf") == nil)
    }

    @Test("Preview requests stay inside the collection and use the configured provider")
    func previews() async throws {
        let previewProvider = CapturingPreviewProvider(result: Data("preview".utf8))
        let fixture = try CollectionFixture(previewProvider: previewProvider)
        defer { fixture.remove() }
        try fixture.write("pdf", named: "scan.pdf")

        let data = try await fixture.collection.preview(named: "scan.pdf")

        #expect(data == Data("preview".utf8))
        let request = try #require(await previewProvider.requests.first)
        #expect(request.sourceURL == fixture.outputDirectory.appendingPathComponent("scan.pdf"))
        #expect(request.outputDirectory == fixture.outputDirectory)
        #expect(try await fixture.collection.preview(named: "missing.pdf") == nil)
        #expect(await previewProvider.requests.count == 1)
    }

    @Test("Removal cancels document work before deleting the output and preview sidecar")
    func removalLifecycle() async throws {
        let cancellation = CancellationRecorder()
        let fixture = try CollectionFixture(
            workCanceller: ScanDocumentWorkCanceller { path in
                await cancellation.record(
                    path: path,
                    fileExistedWhenCancelled: FileManager.default.fileExists(atPath: path)
                )
            }
        )
        defer { fixture.remove() }
        let fileURL = try fixture.write("pdf", named: "scan.pdf")
        let previewURL = fixture.outputDirectory.appendingPathComponent(".previews/scan.pdf.jpg")
        try FileManager.default.createDirectory(
            at: previewURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("preview".utf8).write(to: previewURL)

        await fixture.collection.remove(named: "scan.pdf")

        #expect(await cancellation.paths == [fileURL.path])
        #expect(await cancellation.fileExistedWhenCancelled == [true])
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: previewURL.path))

        await fixture.collection.remove(named: "missing.pdf")
        await fixture.collection.remove(named: "../outside.pdf")
        #expect(await cancellation.paths == [fileURL.path])
    }
}

private struct CollectionFixture {
    let root: URL
    let outputDirectory: URL
    let collection: ScanDocumentCollection

    init(
        previewProvider: any ScanPreviewProviding = CompatibleScanPreviewProvider(),
        workCanceller: ScanDocumentWorkCanceller = ScanDocumentWorkCanceller()
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        outputDirectory = root.appendingPathComponent("scans", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        collection = ScanDocumentCollection(
            outputDirectory: outputDirectory,
            previewProvider: previewProvider,
            workCanceller: workCanceller
        )
    }

    @discardableResult
    func write(_ contents: String, named name: String) throws -> URL {
        let url = outputDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor CapturingPreviewProvider: ScanPreviewProviding {
    struct Request: Sendable {
        let sourceURL: URL
        let outputDirectory: URL
    }

    private(set) var requests: [Request] = []
    private let result: Data

    init(result: Data) {
        self.result = result
    }

    func preview(for sourceURL: URL, outputDirectory: URL) -> Data {
        requests.append(Request(sourceURL: sourceURL, outputDirectory: outputDirectory))
        return result
    }
}

private actor CancellationRecorder {
    private(set) var paths: [String] = []
    private(set) var fileExistedWhenCancelled: [Bool] = []

    func record(path: String, fileExistedWhenCancelled: Bool) {
        paths.append(path)
        self.fileExistedWhenCancelled.append(fileExistedWhenCancelled)
    }
}
