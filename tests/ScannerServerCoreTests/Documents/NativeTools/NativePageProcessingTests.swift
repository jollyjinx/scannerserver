import Foundation
@testable import ScannerServerCore
import Testing

@Suite("Native page processing")
struct NativePageProcessingTests {
    @Test("Blank and crop decisions preserve threshold boundaries")
    func decisionBoundaries() throws {
        let blankOptions = try NativeRemoveBlankPagesOptions(arguments: ["scan.pdf"])
        #expect(NativeBlankPageDecision.evaluate(
            nonwhiteRatio: 0.00299,
            mean: 248,
            options: blankOptions
        ).isBlank)
        #expect(!NativeBlankPageDecision.evaluate(
            nonwhiteRatio: 0.003,
            mean: 248,
            options: blankOptions
        ).isBlank)

        let cropOptions = try NativeCropPDFPagesOptions(arguments: ["scan.pdf"])
        #expect(cropOptions.marginPoints == 1.0)
        let image = NativeDocumentImageDimensions(width: 100, height: 100)
        #expect(NativeCropPageDecision.evaluate(
            image: image,
            boundingBox: .init(left: 0, top: 0, width: 80, height: 100),
            density: 0.08,
            options: cropOptions
        ).shouldCrop)
        #expect(!NativeCropPageDecision.evaluate(
            image: image,
            boundingBox: .init(left: 0, top: 0, width: 81, height: 81),
            density: 0.08,
            options: cropOptions
        ).shouldCrop)
        #expect(NativeCropPageDecision.evaluate(
            image: image,
            boundingBox: .init(left: 2, top: 2, width: 95, height: 96),
            density: 0.08,
            boundingBoxKind: .pageEdges,
            options: cropOptions
        ).shouldCrop)
    }

    @Test("Crop analysis detects a full sheet inside a noisy scanner border")
    func fullSheetBorderDetection() throws {
        let width = 200
        let height = 300
        let inset = 16
        var rgb = Data()
        rgb.reserveCapacity(width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let isPaper = (inset..<(width - inset)).contains(x)
                    && (inset..<(height - inset)).contains(y)
                let value: UInt8 = isPaper ? 245 : ((x + y).isMultiple(of: 3) ? 230 : 210)
                rgb.append(contentsOf: [value, value, value])
            }
        }

        let executor = NativeDocumentToolExecutor(
            executor: FakeNativeDocumentProcessExecutor(stubs: [])
        )
        let analysis = try executor.cropPixelAnalysis(
            rgb: rgb,
            width: width,
            height: height,
            border: 32,
            backgroundDelta: 8
        )

        #expect(analysis.boundingBoxKind == .pageEdges)
        #expect(analysis.boundingBox == NativeImageBoundingBox(
            left: inset,
            top: inset,
            width: width - 2 * inset,
            height: height - 2 * inset
        ))
    }

    @Test("Crop analysis detects a near-full sheet without requiring mask pixels at image zero")
    func nearFullSheetBorderDetection() throws {
        let width = 200
        let height = 300
        let inset = 40
        var rgb = Data()
        rgb.reserveCapacity(width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let isPaper = (inset..<(width - inset)).contains(x)
                    && (inset..<(height - inset)).contains(y)
                let isEdgeNoise = (x == 10 || x == width - 11) && y == height / 2
                    || (y == 10 || y == height - 11) && x == width / 2
                let value: UInt8 = isEdgeNoise ? 220 : (isPaper ? 248 : 237)
                rgb.append(contentsOf: [value, value, value])
            }
        }

        let executor = NativeDocumentToolExecutor(
            executor: FakeNativeDocumentProcessExecutor(stubs: [])
        )
        let analysis = try executor.cropPixelAnalysis(
            rgb: rgb,
            width: width,
            height: height,
            border: 64,
            backgroundDelta: 8
        )

        #expect(analysis.boundingBoxKind == .pageEdges)
        #expect(analysis.boundingBox == NativeImageBoundingBox(
            left: inset,
            top: inset,
            width: width - 2 * inset,
            height: height - 2 * inset
        ))
    }

    @Test("Blank analysis ignores a dark scanner border but retains real page content")
    func blankScannerBorderDetection() throws {
        let width = 200
        let height = 300
        let border = 6
        var grayscale = Data(repeating: 250, count: width * height)
        for y in 0..<height {
            for x in 0..<width where x < border || x >= width - border
                || y < border || y >= height - border
            {
                grayscale[y * width + x] = 210
            }
        }

        let executor = NativeDocumentToolExecutor(
            executor: FakeNativeDocumentProcessExecutor(stubs: [])
        )
        let blank = try executor.blankPixelAnalysis(
            grayscale: grayscale,
            width: width,
            height: height,
            whiteThreshold: 230
        )
        let options = try NativeRemoveBlankPagesOptions(arguments: ["scan.pdf"])
        #expect(NativeBlankPageDecision.evaluate(
            nonwhiteRatio: blank.nonwhiteRatio,
            mean: blank.mean,
            options: options
        ).isBlank)

        for y in 120..<180 {
            for x in 95..<105 {
                grayscale[y * width + x] = 80
            }
        }
        let content = try executor.blankPixelAnalysis(
            grayscale: grayscale,
            width: width,
            height: height,
            whiteThreshold: 230
        )
        #expect(!NativeBlankPageDecision.evaluate(
            nonwhiteRatio: content.nonwhiteRatio,
            mean: content.mean,
            options: options
        ).isBlank)
    }

    @Test("Inherited MediaBox and direct image resources are resolved structurally")
    func inheritedPDFObjects() throws {
        let document = try NativePDFJSONDocument(data: pdfJSON())

        #expect(document.pageReferences == ["4 0 R"])
        #expect(try document.mediaBox(forPageAt: 0) == NativePDFBox(
            left: 0, bottom: 0, right: 612, top: 792
        ))
        #expect(try document.directImageReferences(forPageAt: 0) == ["10 0 R"])

        let updateData = try document.updateData(
            cropBoxes: [0: .init(left: 10, bottom: 20, right: 300, top: 700)],
            keepOriginalBoxes: false
        )
        let root = try #require(
            JSONSerialization.jsonObject(with: updateData) as? [String: Any]
        )
        let qpdf = try #require(root["qpdf"] as? [Any])
        let objects = try #require(qpdf[1] as? [String: Any])
        let page = try #require(objects["obj:4 0 R"] as? [String: Any])
        let value = try #require(page["value"] as? [String: Any])
        #expect(value["/CropBox"] as? [Double] == [10, 20, 300, 700])
        #expect(value["/MediaBox"] as? [Double] == [10, 20, 300, 700])

        let emptyData = try document.emptyPagesUpdateData()
        let emptyRoot = try #require(
            JSONSerialization.jsonObject(with: emptyData) as? [String: Any]
        )
        let emptyQPDF = try #require(emptyRoot["qpdf"] as? [Any])
        let emptyObjects = try #require(emptyQPDF[1] as? [String: Any])
        let pages = try #require(emptyObjects["obj:3 0 R"] as? [String: Any])
        let pagesValue = try #require(pages["value"] as? [String: Any])
        #expect((pagesValue["/Kids"] as? [Any])?.isEmpty == true)
        #expect((pagesValue["/Count"] as? NSNumber)?.intValue == 0)
    }

    @Test("pdfimages list rejects malformed output and retains object IDs")
    func pdfImagesListParsing() throws {
        let output = """
        page   num  type   width height color comp bpc  enc interp  object ID x-ppi y-ppi size ratio
        --------------------------------------------------------------------------------------------
           1     0 image    100    200  rgb     3   8  image  no        10  0    72    72 10K 5%
           1     1 smask    100    200  gray    1   8  image  no        12  0    72    72  1K 1%
        """
        let list = try NativePDFImagesList(output: output)
        #expect(list.rows.map(\.objectReference) == ["10 0 R", "12 0 R"])
        #expect(throws: NativePDFImagesListError.self) {
            _ = try NativePDFImagesList(output: "not a table")
        }
    }

    @Test("Cancellation reaches native blank-page inspection and cleans staging")
    func blankCancellation() async throws {
        let underlying = FakeNativeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(
                exitStatus: 0,
                standardOutput: String(decoding: try pdfJSON(), as: UTF8.self)
            )),
            .suspended,
        ])
        let fileSystem = FakeNativeDocumentFileSystem()
        let executor = NativeDocumentToolExecutor(executor: underlying, fileSystem: fileSystem)
        let task = Task {
            try await executor.execute(ProcessRequest(
                executable: "remove-blank-pages",
                arguments: ["/work/raw.pdf"],
                workingDirectory: URL(fileURLWithPath: "/work", isDirectory: true)
            ))
        }

        await underlying.waitForRequestCount(2)
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fileSystem.recordedRemovedPaths() == [
            "/work/.native-document-tools-test-1",
        ])
    }

    @Test("Failed atomic replacement leaves the destination intact")
    func replacementRollback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("scan.pdf")
        let missingSource = directory.appendingPathComponent("missing.pdf")
        try Data("original".utf8).write(to: destination)

        #expect(throws: (any Error).self) {
            try FoundationNativeDocumentFileSystem().replaceFileAtomically(
                at: destination,
                with: missingSource
            )
        }
        #expect(try Data(contentsOf: destination) == Data("original".utf8))
    }

    private func pdfJSON() throws -> Data {
        let objects: [String: Any] = [
            "trailer": ["value": ["/Root": "1 0 R"]],
            "obj:1 0 R": ["value": ["/Type": "/Catalog", "/Pages": "3 0 R"]],
            "obj:3 0 R": ["value": [
                "/Type": "/Pages", "/Kids": ["4 0 R"], "/Count": 1,
                "/MediaBox": "9 0 R", "/Resources": "8 0 R",
            ]],
            "obj:4 0 R": ["value": ["/Type": "/Page", "/Parent": "3 0 R"]],
            "obj:8 0 R": ["value": ["/XObject": [
                "/Scan": "10 0 R", "/Nested": "11 0 R", "/Mask": "12 0 R",
            ]]],
            "obj:9 0 R": ["value": [0, 0, 612, 792]],
            "obj:10 0 R": ["stream": ["dict": ["/Subtype": "/Image"]]],
            "obj:11 0 R": ["stream": ["dict": ["/Subtype": "/Form"]]],
            "obj:12 0 R": ["stream": ["dict": [
                "/Subtype": "/Image", "/ImageMask": true,
            ]]],
        ]
        return try JSONSerialization.data(withJSONObject: [
            "qpdf": [[
                "jsonversion": 2,
                "pdfversion": "1.7",
                "calledgetallpages": true,
                "pushedinheritedpageresources": false,
                "maxobjectid": 12,
            ], objects],
        ])
    }
}
