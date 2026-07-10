import Foundation
import ScannerServerCore
import Testing

@Suite("Native scan preview provider")
struct NativeScanPreviewProviderTests {
    @Test("vipsthumbnail requests render PDF page zero and PNG input directly")
    func commandConstruction() {
        let destination = URL(fileURLWithPath: "/scans/.previews/scan.jpg")

        let pdfRequest = VIPSThumbnailCommand(
            sourceURL: URL(fileURLWithPath: "/scans/scan.pdf"),
            destinationURL: destination,
            sourceKind: .pdf
        ).processRequest
        let pngRequest = VIPSThumbnailCommand(
            sourceURL: URL(fileURLWithPath: "/scans/page.png"),
            destinationURL: destination,
            sourceKind: .png
        ).processRequest

        #expect(pdfRequest == ProcessRequest(
            executable: "vipsthumbnail",
            arguments: [
                "/scans/scan.pdf[page=0]",
                "--size", "320x420",
                "--output", "/scans/.previews/scan.jpg[Q=82,optimize_coding]",
            ]
        ))
        #expect(pngRequest.arguments.first == "/scans/page.png")
        #expect(pngRequest.arguments.dropFirst() == pdfRequest.arguments.dropFirst())
    }

    @Test("A preview newer than its source is returned without invoking vipsthumbnail")
    func cacheHit() async throws {
        let fixture = try PreviewFixture(sourceName: "scan.pdf", sourceData: Data("source".utf8))
        defer { fixture.remove() }
        let cachedData = Data("cached-preview".utf8)
        try fixture.createCachedPreview(cachedData)
        let executor = FakePreviewProcessExecutor(behavior: .throwFailure)
        let provider = NativeScanPreviewProvider(executor: executor)

        let result = try await provider.preview(
            for: fixture.sourceURL,
            outputDirectory: fixture.outputDirectory
        )

        #expect(result == cachedData)
        #expect(await executor.requests().isEmpty)
    }

    @Test("Successful rendering atomically publishes the materialized JPEG")
    func successfulRendering() async throws {
        let fixture = try PreviewFixture(sourceName: "scan.pdf", sourceData: Data("pdf".utf8))
        defer { fixture.remove() }
        let renderedData = Data("rendered-jpeg".utf8)
        let executor = FakePreviewProcessExecutor(behavior: .materialize(renderedData))
        let provider = NativeScanPreviewProvider(executor: executor)

        let result = try await provider.preview(
            for: fixture.sourceURL,
            outputDirectory: fixture.outputDirectory
        )
        let request = try #require(await executor.requests().only)

        #expect(result == renderedData)
        #expect(try Data(contentsOf: fixture.previewURL) == renderedData)
        #expect(request.executable == "vipsthumbnail")
        #expect(request.arguments.first == "\(fixture.sourceURL.path)[page=0]")
        #expect(request.arguments[1...2] == ["--size", "320x420"])
        #expect(request.arguments[3] == "--output")
        #expect(request.arguments[4].hasSuffix(".tmp.jpg[Q=82,optimize_coding]"))
    }

    @Test("A failed native process publishes the deterministic placeholder")
    func processFailureFallback() async throws {
        let fixture = try PreviewFixture(sourceName: "page.png", sourceData: Data("png".utf8))
        defer { fixture.remove() }
        let executor = FakePreviewProcessExecutor(behavior: .processFailure)
        let provider = NativeScanPreviewProvider(executor: executor)

        let result = try await provider.preview(
            for: fixture.sourceURL,
            outputDirectory: fixture.outputDirectory
        )

        #expect(result == PlaceholderPreview.jpegBytes)
        #expect(try Data(contentsOf: fixture.previewURL) == PlaceholderPreview.jpegBytes)
        #expect(await executor.requests().count == 1)
    }

    @Test("Unsupported and empty sources use the placeholder without invoking the tool")
    func sourceFallbacks() async throws {
        for (name, bytes) in [
            ("notes.txt", Data("unsupported".utf8)),
            ("empty.pdf", Data()),
        ] {
            let fixture = try PreviewFixture(sourceName: name, sourceData: bytes)
            defer { fixture.remove() }
            let executor = FakePreviewProcessExecutor(behavior: .throwFailure)
            let provider = NativeScanPreviewProvider(executor: executor)

            let result = try await provider.preview(
                for: fixture.sourceURL,
                outputDirectory: fixture.outputDirectory
            )

            #expect(result == PlaceholderPreview.jpegBytes)
            #expect(try Data(contentsOf: fixture.previewURL) == PlaceholderPreview.jpegBytes)
            #expect(await executor.requests().isEmpty)
        }
    }

    @Test("Concurrent requests share one render and publish one intact preview")
    func concurrentRequests() async throws {
        let fixture = try PreviewFixture(sourceName: "page.png", sourceData: Data("png".utf8))
        defer { fixture.remove() }
        let renderedData = Data(repeating: 0xa5, count: 4_096)
        let executor = FakePreviewProcessExecutor(behavior: .blockedMaterialize(renderedData))
        let provider = NativeScanPreviewProvider(executor: executor)

        async let results: [Data] = withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    try await provider.preview(
                        for: fixture.sourceURL,
                        outputDirectory: fixture.outputDirectory
                    )
                }
            }

            var values: [Data] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        await executor.waitForRequestCount(1)
        await executor.release()
        let previewResults = try await results

        #expect(previewResults.count == 24)
        #expect(previewResults.allSatisfy { $0 == renderedData })
        #expect(await executor.requests().count == 1)
        #expect(try Data(contentsOf: fixture.previewURL) == renderedData)
    }
}

private struct PreviewFixture {
    let root: URL
    let outputDirectory: URL
    let sourceURL: URL

    init(sourceName: String, sourceData: Data) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        outputDirectory = root.appendingPathComponent("scans", isDirectory: true)
        sourceURL = outputDirectory.appendingPathComponent(sourceName)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try sourceData.write(to: sourceURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: sourceURL.path
        )
    }

    var previewURL: URL {
        outputDirectory
            .appendingPathComponent(PreviewOutputName.directoryName, isDirectory: true)
            .appendingPathComponent("\(sourceURL.lastPathComponent).jpg")
    }

    func createCachedPreview(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: previewURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: previewURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: previewURL.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
