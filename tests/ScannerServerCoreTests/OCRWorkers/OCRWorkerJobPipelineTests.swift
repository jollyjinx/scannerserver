import Foundation
import ScannerServerCore
import Testing

@Suite("OCR worker job pipeline")
struct OCRWorkerJobPipelineTests {
    @Test("Successful OCR is autocropped before the worker uploads its result")
    func cropAfterOCR() async throws {
        let ocrExecutor = WorkerPipelineTestExecutor(results: [
            ProcessResult(exitStatus: 0, standardOutput: "ocr complete\n"),
        ])
        let documentExecutor = WorkerPipelineTestExecutor(results: [
            ProcessResult(exitStatus: 0, standardOutput: "crop complete\n"),
        ])
        let resultURL = URL(fileURLWithPath: "/work/result.pdf")
        let request = ProcessRequest(
            executable: "ocrmypdf",
            arguments: ["/work/source.pdf", resultURL.path],
            environment: ["TMPDIR": "/work/.tmp"],
            workingDirectory: URL(fileURLWithPath: "/work", isDirectory: true)
        )
        let crop = OCRWorkerCropConfiguration(
            backgroundDelta: 9,
            borderPixels: 50,
            marginPoints: 2.5,
            maximumWidthRatio: 0.7,
            maximumHeightRatio: 0.75,
            minimumDensity: 0.1,
            keepOriginalBoxes: true,
            debug: true
        )

        let result = try await OCRWorkerJobPipeline(
            ocrExecutor: ocrExecutor,
            documentExecutor: documentExecutor
        ).execute(
            ocrRequest: request,
            resultURL: resultURL,
            cropConfiguration: crop
        )

        #expect(result.succeeded)
        #expect(await ocrExecutor.requests == [request])
        let cropRequest = try #require(await documentExecutor.requests.first)
        #expect(cropRequest.executable == "crop-pdf-pages")
        #expect(cropRequest.arguments == [
            resultURL.path,
            "--background-delta", "9",
            "--border-px", "50",
            "--margin-points", "2.5",
            "--max-width-ratio", "0.7",
            "--max-height-ratio", "0.75",
            "--min-density", "0.1",
            "--keep-original-boxes",
            "--debug",
        ])
        #expect(cropRequest.environment == request.environment)
        #expect(cropRequest.workingDirectory == request.workingDirectory)
    }

    @Test("Failed OCR does not launch autocrop")
    func failedOCRStopsPipeline() async throws {
        let ocrExecutor = WorkerPipelineTestExecutor(results: [
            ProcessResult(exitStatus: 7, standardError: "expected failure"),
        ])
        let documentExecutor = WorkerPipelineTestExecutor(results: [])

        let result = try await OCRWorkerJobPipeline(
            ocrExecutor: ocrExecutor,
            documentExecutor: documentExecutor
        ).execute(
            ocrRequest: ProcessRequest(
                executable: "ocrmypdf",
                arguments: ["/work/source.pdf", "/work/result.pdf"]
            ),
            resultURL: URL(fileURLWithPath: "/work/result.pdf"),
            cropConfiguration: OCRWorkerCropConfiguration()
        )

        #expect(result.exitStatus == 7)
        #expect(await documentExecutor.requests.isEmpty)
    }

    @Test("Successful OCR and autocrop are followed by per-page blank removal")
    func blankRemovalAfterOCRAndCrop() async throws {
        let ocrExecutor = WorkerPipelineTestExecutor(results: [
            ProcessResult(exitStatus: 0, standardOutput: "ocr complete\n"),
        ])
        let documentExecutor = WorkerPipelineTestExecutor(results: [
            ProcessResult(exitStatus: 0, standardOutput: "crop complete\n"),
            ProcessResult(exitStatus: 0, standardOutput: "Removed 1 blank page.\n"),
        ])
        let resultURL = URL(fileURLWithPath: "/work/result.pdf")

        let result = try await OCRWorkerJobPipeline(
            ocrExecutor: ocrExecutor,
            documentExecutor: documentExecutor
        ).execute(
            ocrRequest: ProcessRequest(
                executable: "ocrmypdf",
                arguments: ["/work/source.pdf", resultURL.path]
            ),
            resultURL: resultURL,
            cropConfiguration: OCRWorkerCropConfiguration(),
            blankPageConfiguration: OCRWorkerBlankPageConfiguration()
        )

        #expect(result.succeeded)
        let requests = await documentExecutor.requests
        #expect(requests.map(\.executable) == ["crop-pdf-pages", "remove-blank-pages"])
        #expect(requests[1].arguments.contains("--no-keep-one"))
    }
}

private actor WorkerPipelineTestExecutor: ProcessExecutor {
    private(set) var requests: [ProcessRequest] = []
    private var results: [ProcessResult]

    init(results: [ProcessResult]) {
        self.results = results
    }

    func execute(_ request: ProcessRequest) -> ProcessResult {
        requests.append(request)
        return results.removeFirst()
    }
}
