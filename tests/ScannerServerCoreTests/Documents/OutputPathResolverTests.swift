import Foundation
import ScannerServerCore
import Testing

@Suite("Scan output path resolution")
struct OutputPathResolverTests {
    @Test("A regular PDF or PNG direct child resolves")
    func regularFileResolves() throws {
        let fixture = try PathFixture()
        defer { fixture.remove() }
        let expected = fixture.outputDirectory.appendingPathComponent("scan.pdf")
        try Data("scan".utf8).write(to: expected)

        let resolved = try fixture.resolver.resolve("scan.pdf")

        #expect(resolved == expected.standardizedFileURL)
    }

    @Test(
        "Traversal and unsupported names are rejected",
        arguments: [
            "../scan.pdf",
            "subdirectory/scan.pdf",
            "/tmp/scan.pdf",
            ".",
            "..",
            "scan.jpg",
            "",
        ]
    )
    func invalidNames(_ name: String) throws {
        let fixture = try PathFixture()
        defer { fixture.remove() }

        #expect(throws: ScanOutputPathError.self) {
            try fixture.resolver.resolve(name)
        }
    }

    @Test("A symlink cannot escape the output directory")
    func symlinkEscapeIsRejected() throws {
        let fixture = try PathFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside.pdf")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.outputDirectory.appendingPathComponent("linked.pdf"),
            withDestinationURL: outside
        )

        #expect(throws: ScanOutputPathError.escapesOutputDirectory("linked.pdf")) {
            try fixture.resolver.resolve("linked.pdf")
        }
    }

    @Test("Missing files and directories are not exposed")
    func onlyRegularFilesResolve() throws {
        let fixture = try PathFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.outputDirectory.appendingPathComponent("directory.pdf"),
            withIntermediateDirectories: false
        )

        #expect(throws: ScanOutputPathError.fileDoesNotExist("missing.pdf")) {
            try fixture.resolver.resolve("missing.pdf")
        }
        #expect(throws: ScanOutputPathError.notARegularFile("directory.pdf")) {
            try fixture.resolver.resolve("directory.pdf")
        }
    }
}

private struct PathFixture {
    let root: URL
    let outputDirectory: URL
    let resolver: ScanOutputPathResolver

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scansnap-document-tests-\(UUID().uuidString)", isDirectory: true)
        outputDirectory = root.appendingPathComponent("scans", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        resolver = ScanOutputPathResolver(outputDirectory: outputDirectory)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
