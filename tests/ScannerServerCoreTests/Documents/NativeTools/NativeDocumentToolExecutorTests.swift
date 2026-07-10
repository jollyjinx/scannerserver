import Foundation
import ScannerServerCore
import Testing

@Suite("Native document tool executor")
struct NativeDocumentToolExecutorTests {
    private struct RotationCase: Sendable, CustomTestStringConvertible {
        let reportedDegrees: Int
        let vipsAngle: String

        var testDescription: String { "rotation \(reportedDegrees)" }
    }

    private let timestamp = "2026-07-10.142305"

    @Test("Creator metadata uses exiftool and supplies a default producer atomically")
    func creatorMetadataArguments() async throws {
        let underlying = FakeNativeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "\n")),
            .result(ProcessResult(exitStatus: 0, standardOutput: "1 image files updated\n")),
        ])
        let executor = NativeDocumentToolExecutor(
            executor: underlying,
            fileSystem: FakeNativeDocumentFileSystem()
        )
        let workingDirectory = URL(fileURLWithPath: "/work", isDirectory: true)
        let request = ProcessRequest(
            executable: "set-pdf-creator",
            arguments: ["raw.pdf", "--creator", "Office Scanner"],
            environment: ["PATH": "/native-tools"],
            workingDirectory: workingDirectory
        )

        let result = try await executor.execute(request)

        #expect(result == ProcessResult(exitStatus: 0))
        #expect(await underlying.requests() == [
            ProcessRequest(
                executable: "exiftool",
                arguments: ["-s3", "-XMP-pdf:Producer", "raw.pdf"],
                environment: request.environment,
                workingDirectory: workingDirectory
            ),
            ProcessRequest(
                executable: "exiftool",
                arguments: [
                    "-overwrite_original",
                    "-PDF:Creator=Office Scanner",
                    "-XMP-xmp:CreatorTool=Office Scanner",
                    "-PDF:Producer=ScanSnap Linux",
                    "-XMP-pdf:Producer=ScanSnap Linux",
                    "raw.pdf",
                ],
                environment: request.environment,
                workingDirectory: workingDirectory
            ),
        ])
    }

    @Test("An existing XMP producer is preserved and synchronized to DocumentInfo")
    func existingProducer() async throws {
        let underlying = FakeNativeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "Vendor Producer\n")),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let executor = NativeDocumentToolExecutor(executor: underlying)

        _ = try await executor.execute(ProcessRequest(
            executable: "set-pdf-creator",
            arguments: ["/work/raw.pdf", "--creator", "ScanSnap"]
        ))

        #expect(await underlying.requests().last?.arguments == [
            "-overwrite_original",
            "-PDF:Creator=ScanSnap",
            "-XMP-xmp:CreatorTool=ScanSnap",
            "-PDF:Producer=Vendor Producer",
            "-XMP-pdf:Producer=Vendor Producer",
            "/work/raw.pdf",
        ])
    }

    @Test("PDF pages use qpdf page count and one-page selections before publication")
    func splitArgumentsNamingAndCleanup() async throws {
        let underlying = FakeNativeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "2\n")),
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let fileSystem = FakeNativeDocumentFileSystem()
        let executor = NativeDocumentToolExecutor(executor: underlying, fileSystem: fileSystem)
        let request = finalizationRequest(executable: "split-pdf-pages")

        let result = try await executor.execute(request)

        let stage = "/scans/.native-document-tools-test-1"
        #expect(await underlying.requests() == [
            inheritedRequest("qpdf", ["--show-npages", "/work/raw.pdf"], from: request),
            inheritedRequest("qpdf", [
                "/work/raw.pdf", "--pages", ".", "1", "--",
                "\(stage)/\(timestamp)-page-0001.pdf",
            ], from: request),
            inheritedRequest("qpdf", [
                "/work/raw.pdf", "--pages", ".", "2", "--",
                "\(stage)/\(timestamp)-page-0002.pdf",
            ], from: request),
        ])
        #expect(result == ProcessResult(
            exitStatus: 0,
            standardOutput: """
            /scans/2026-07-10.142305-page-0001.pdf
            /scans/2026-07-10.142305-page-0002.pdf

            """
        ))
        #expect(fileSystem.recordedPlacements().map(\.destination) == [
            "/scans/\(timestamp)-page-0001.pdf",
            "/scans/\(timestamp)-page-0002.pdf",
        ])
        #expect(fileSystem.recordedRemovedPaths().contains(stage))
        #expect(!fileSystem.contains(stage))
    }

    @Test("Existing split output returns status 73 before staging")
    func splitConflict() async throws {
        let underlying = FakeNativeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "2\n")),
        ])
        let fileSystem = FakeNativeDocumentFileSystem()
        fileSystem.addItem("/scans/\(timestamp)-page-0002.pdf")
        let executor = NativeDocumentToolExecutor(executor: underlying, fileSystem: fileSystem)

        let result = try await executor.execute(finalizationRequest(executable: "split-pdf-pages"))

        #expect(result.exitStatus == 73)
        #expect(result.standardError == "Output file already exists: /scans/\(timestamp)-page-0002.pdf\n")
        #expect(await underlying.requests().map(\.executable) == ["qpdf"])
        #expect(fileSystem.recordedTemporaryDirectories().isEmpty)
    }

    @Test("A zero-page PDF returns status 2")
    func zeroPagePDF() async throws {
        let underlying = FakeNativeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "0\n")),
        ])
        let executor = NativeDocumentToolExecutor(
            executor: underlying,
            fileSystem: FakeNativeDocumentFileSystem()
        )

        let result = try await executor.execute(finalizationRequest(executable: "split-pdf-pages"))

        #expect(result == ProcessResult(
            exitStatus: 2,
            standardError: "PDF has no pages.\n"
        ))
    }

    @Test("Image export uses pdfimages per page and publishes the largest image")
    func exportArgumentsLargestImageAndNaming() async throws {
        let underlying = FakeNativeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "2\n")),
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0, standardOutput: "Page    1 rot:  0\n")),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let fileSystem = FakeNativeDocumentFileSystem()
        let stage = "/scans/.native-document-tools-test-1"
        fileSystem.addPNG("\(stage)/page-0001-000.png", width: 100, height: 200)
        fileSystem.addPNG("\(stage)/page-0001-001.png", width: 300, height: 200)
        let executor = NativeDocumentToolExecutor(executor: underlying, fileSystem: fileSystem)
        let request = finalizationRequest(executable: "export-scan-images")

        let result = try await executor.execute(request)

        #expect(await underlying.requests() == [
            inheritedRequest("qpdf", ["--show-npages", "/work/raw.pdf"], from: request),
            inheritedRequest("pdfimages", [
                "-f", "1", "-l", "1", "-png", "/work/raw.pdf", "\(stage)/page-0001",
            ], from: request),
            inheritedRequest("pdfinfo", [
                "-f", "1", "-l", "1", "/work/raw.pdf",
            ], from: request),
            inheritedRequest("pdfimages", [
                "-f", "2", "-l", "2", "-png", "/work/raw.pdf", "\(stage)/page-0002",
            ], from: request),
        ])
        #expect(result.exitStatus == 0)
        #expect(result.standardOutput == "/scans/\(timestamp)-page-0001.png\n")
        #expect(result.standardError == "Page 2 has no embedded image.\n")
        #expect(fileSystem.recordedPlacements() == [
            .init(
                source: "\(stage)/page-0001-001.png",
                destination: "/scans/\(timestamp)-page-0001.png"
            ),
        ])
        #expect(fileSystem.recordedRemovedPaths().contains(stage))
    }

    @Test(
        "PDF page rotation is applied clockwise with vips",
        arguments: [
            RotationCase(reportedDegrees: 90, vipsAngle: "d90"),
            RotationCase(reportedDegrees: 180, vipsAngle: "d180"),
            RotationCase(reportedDegrees: -90, vipsAngle: "d270"),
        ]
    )
    private func rotatedImageExport(rotation: RotationCase) async throws {
        let underlying = FakeNativeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "1\n")),
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(
                exitStatus: 0,
                standardOutput: "Page rot: \(rotation.reportedDegrees)\n"
            )),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let fileSystem = FakeNativeDocumentFileSystem()
        let stage = "/scans/.native-document-tools-test-1"
        let extracted = "\(stage)/page-0001-000.png"
        let rotated = "\(stage)/rotated-page-0001.png"
        fileSystem.addPNG(extracted, width: 100, height: 200)
        let executor = NativeDocumentToolExecutor(executor: underlying, fileSystem: fileSystem)
        let request = finalizationRequest(executable: "export-scan-images")

        let result = try await executor.execute(request)

        #expect(result.exitStatus == 0)
        #expect(await underlying.requests().last == inheritedRequest("vips", [
            "rot", extracted, rotated, rotation.vipsAngle,
        ], from: request))
        #expect(fileSystem.recordedPlacements() == [
            .init(
                source: rotated,
                destination: "/scans/\(timestamp)-page-0001.png"
            ),
        ])
    }

    @Test("An invalid page rotation fails before publication")
    func invalidPageRotation() async throws {
        let underlying = FakeNativeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "1\n")),
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0, standardOutput: "Page rot: 45\n")),
        ])
        let fileSystem = FakeNativeDocumentFileSystem()
        fileSystem.addPNG(
            "/scans/.native-document-tools-test-1/page-0001-000.png",
            width: 100,
            height: 200
        )
        let executor = NativeDocumentToolExecutor(executor: underlying, fileSystem: fileSystem)

        let result = try await executor.execute(finalizationRequest(executable: "export-scan-images"))

        #expect(result == ProcessResult(
            exitStatus: 2,
            standardError: "pdfinfo did not return a valid rotation for page 1.\n"
        ))
        #expect(fileSystem.recordedPlacements().isEmpty)
        #expect(fileSystem.recordedRemovedPaths() == [
            "/scans/.native-document-tools-test-1",
        ])
    }

    @Test("An export conflict skips rotation and returns status 73")
    func exportConflict() async throws {
        let underlying = FakeNativeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "1\n")),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let fileSystem = FakeNativeDocumentFileSystem()
        fileSystem.addPNG(
            "/scans/.native-document-tools-test-1/page-0001-000.png",
            width: 100,
            height: 200
        )
        fileSystem.addItem("/scans/\(timestamp)-page-0001.png")
        let executor = NativeDocumentToolExecutor(executor: underlying, fileSystem: fileSystem)

        let result = try await executor.execute(finalizationRequest(executable: "export-scan-images"))

        #expect(result == ProcessResult(
            exitStatus: 73,
            standardError: "Output file already exists: /scans/\(timestamp)-page-0001.png\n"
        ))
        #expect(await underlying.requests().map(\.executable) == ["qpdf", "pdfimages"])
        #expect(fileSystem.recordedPlacements().isEmpty)
    }

    @Test("No embedded images returns status 2 and cleans staging")
    func noExportedImages() async throws {
        let underlying = FakeNativeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "1\n")),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let fileSystem = FakeNativeDocumentFileSystem()
        let executor = NativeDocumentToolExecutor(executor: underlying, fileSystem: fileSystem)

        let result = try await executor.execute(finalizationRequest(executable: "export-scan-images"))

        #expect(result.exitStatus == 2)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError == """
        Page 1 has no embedded image.
        No page images were exported.

        """)
        #expect(fileSystem.recordedRemovedPaths() == [
            "/scans/.native-document-tools-test-1",
        ])
    }

    @Test("A publication race rolls back already-published files")
    func publicationRollback() async throws {
        let underlying = FakeNativeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "2\n")),
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let fileSystem = FakeNativeDocumentFileSystem()
        let first = "/scans/\(timestamp)-page-0001.pdf"
        let second = "/scans/\(timestamp)-page-0002.pdf"
        fileSystem.conflictOnPublication(at: second)
        let executor = NativeDocumentToolExecutor(executor: underlying, fileSystem: fileSystem)

        let result = try await executor.execute(finalizationRequest(executable: "split-pdf-pages"))

        #expect(result.exitStatus == 73)
        #expect(!fileSystem.contains(first))
        #expect(!fileSystem.contains(second))
        #expect(fileSystem.recordedRemovedPaths().contains(first))
        #expect(fileSystem.recordedRemovedPaths().contains(
            "/scans/.native-document-tools-test-1"
        ))
    }

    @Test("Cancellation reaches the native CLI executor and cleans staging")
    func cancellation() async throws {
        let underlying = FakeNativeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "1\n")),
            .suspended,
        ])
        let fileSystem = FakeNativeDocumentFileSystem()
        let executor = NativeDocumentToolExecutor(executor: underlying, fileSystem: fileSystem)
        let task = Task {
            try await executor.execute(finalizationRequest(executable: "split-pdf-pages"))
        }

        await underlying.waitForRequestCount(2)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(fileSystem.recordedRemovedPaths().contains(
            "/scans/.native-document-tools-test-1"
        ))
        #expect(await underlying.requests().map(\.executable) == ["qpdf", "qpdf"])
    }

    @Test("Cancellation reaches image rotation and cleans staging")
    func rotationCancellation() async throws {
        let underlying = FakeNativeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "1\n")),
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0, standardOutput: "Page rot: 90\n")),
            .suspended,
        ])
        let fileSystem = FakeNativeDocumentFileSystem()
        fileSystem.addPNG(
            "/scans/.native-document-tools-test-1/page-0001-000.png",
            width: 100,
            height: 200
        )
        let executor = NativeDocumentToolExecutor(executor: underlying, fileSystem: fileSystem)
        let task = Task {
            try await executor.execute(finalizationRequest(executable: "export-scan-images"))
        }

        await underlying.waitForRequestCount(4)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(fileSystem.recordedRemovedPaths().contains(
            "/scans/.native-document-tools-test-1"
        ))
        #expect(fileSystem.recordedPlacements().isEmpty)
        #expect(await underlying.requests().map(\.executable) == [
            "qpdf", "pdfimages", "pdfinfo", "vips",
        ])
    }

    @Test("Malformed native requests fail while unrecognized requests pass through")
    func passThrough() async throws {
        let delegatedResults = [
            ProcessResult(exitStatus: 4, standardError: "usage\n"),
        ]
        let underlying = FakeNativeDocumentProcessExecutor(stubs: delegatedResults.map { .result($0) })
        let executor = NativeDocumentToolExecutor(
            executor: underlying,
            fileSystem: FakeNativeDocumentFileSystem()
        )
        let requests = [
            ProcessRequest(
                executable: "remove-blank-pages",
                arguments: ["/work/raw.pdf", "--white-threshold", "256"]
            ),
            ProcessRequest(
                executable: "crop-pdf-pages",
                arguments: ["/work/raw.pdf", "--min-density", "nan"]
            ),
            ProcessRequest(executable: "set-pdf-creator", arguments: ["/work/raw.pdf"]),
        ]

        let first = try await executor.execute(requests[0])
        let second = try await executor.execute(requests[1])
        let third = try await executor.execute(requests[2])

        #expect(first.exitStatus == 2)
        #expect(second.exitStatus == 2)
        #expect(third == delegatedResults[0])
        #expect(await underlying.requests() == [requests[2]])
    }

    private func finalizationRequest(executable: String) -> ProcessRequest {
        ProcessRequest(
            executable: executable,
            arguments: ["/work/raw.pdf", "/scans", timestamp],
            environment: ["PATH": "/usr/bin"],
            workingDirectory: URL(fileURLWithPath: "/work", isDirectory: true)
        )
    }

    private func inheritedRequest(
        _ executable: String,
        _ arguments: [String],
        from request: ProcessRequest
    ) -> ProcessRequest {
        ProcessRequest(
            executable: executable,
            arguments: arguments,
            environment: request.environment,
            workingDirectory: request.workingDirectory
        )
    }
}
