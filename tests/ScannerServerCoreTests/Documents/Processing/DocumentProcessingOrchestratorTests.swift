import Foundation
import ScannerServerCore
import Testing

@Suite("Document processing orchestration")
struct DocumentProcessingOrchestratorTests {
    @Test("Commands execute in compatibility pipeline order")
    func commandOrder() async throws {
        let executor = FakeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(
                exitStatus: 0,
                standardOutput: "/scans/page-0001.pdf\n/scans/page-0002.pdf\n"
            )),
        ])
        let workingDirectory = URL(fileURLWithPath: "/work")
        let orchestrator = DocumentProcessingOrchestrator(executor: executor)

        let result = try await orchestrator.process(try plan(
            removeBlankPages: RemoveBlankPagesRequest(pdfPath: "/work/raw.pdf"),
            cropPages: CropPDFPagesRequest(pdfPath: "/work/raw.pdf"),
            environment: ["PATH": "/helpers"],
            workingDirectory: workingDirectory
        ))

        let requests = await executor.requests()
        #expect(requests.map(\.executable) == [
            "remove-blank-pages",
            "crop-pdf-pages",
            "set-pdf-creator",
            "split-pdf-pages",
        ])
        #expect(requests.allSatisfy { $0.environment == ["PATH": "/helpers"] })
        #expect(requests.allSatisfy { $0.workingDirectory == workingDirectory })
        #expect(result.outputPaths == ["/scans/page-0001.pdf", "/scans/page-0002.pdf"])
    }

    @Test("Disabled optional steps are skipped")
    func optionalStepSkipping() async throws {
        let executor = FakeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0, standardOutput: "/scans/page-0001.png\n")),
        ])
        let timestamp = try ScanTimestamp(rawValue: "2026-07-10.142305")
        let plan = DocumentProcessingPlan(
            creatorMetadata: SetPDFCreatorRequest(pdfPath: "/work/raw.pdf"),
            finalOutput: .exportImages(ExportScanImagesRequest(
                pdfPath: "/work/raw.pdf",
                outputDirectory: "/scans",
                prefix: timestamp
            ))
        )

        let result = try await DocumentProcessingOrchestrator(executor: executor).process(plan)

        #expect(await executor.requests().map(\.executable) == [
            "set-pdf-creator",
            "export-scan-images",
        ])
        #expect(result.outputPaths == ["/scans/page-0001.png"])
    }

    @Test("A failed helper short-circuits later commands and retains process output")
    func failureShortCircuit() async throws {
        let failedResult = ProcessResult(
            exitStatus: 9,
            standardOutput: "partial output\n",
            standardError: "crop failed\n"
        )
        let executor = FakeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .result(failedResult),
        ])
        let orchestrator = DocumentProcessingOrchestrator(executor: executor)

        do {
            _ = try await orchestrator.process(try plan(
                removeBlankPages: RemoveBlankPagesRequest(pdfPath: "/work/raw.pdf"),
                cropPages: CropPDFPagesRequest(pdfPath: "/work/raw.pdf")
            ))
            Issue.record("Expected crop failure")
        } catch let error as DocumentProcessingError {
            #expect(error == .subprocessFailed(
                step: .cropPages,
                command: CropPDFPagesRequest(pdfPath: "/work/raw.pdf").command,
                result: failedResult
            ))
            #expect(error.compatibleExitStatus == 9)
            #expect(error.processResult.standardOutput == "partial output\n")
            #expect(error.processResult.standardError == "crop failed\n")
        }

        #expect(await executor.requests().map(\.executable) == [
            "remove-blank-pages",
            "crop-pdf-pages",
        ])
    }

    @Test("Split and export stdout paths are trimmed and empty lines ignored", arguments: [false, true])
    func outputPathParsing(exportImages: Bool) async throws {
        let executor = FakeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(
                exitStatus: 0,
                standardOutput: "\n  /scans/first output.pdf  \r\n/scans/second.pdf\n\n"
            )),
        ])
        let timestamp = try ScanTimestamp(rawValue: "2026-07-10.142305")
        let finalOutput: DocumentFinalOutputRequest = if exportImages {
            .exportImages(ExportScanImagesRequest(
                pdfPath: "/work/raw.pdf",
                outputDirectory: "/scans",
                prefix: timestamp
            ))
        } else {
            .splitPDF(SplitPDFPagesRequest(
                pdfPath: "/work/raw.pdf",
                outputDirectory: "/scans",
                prefix: timestamp
            ))
        }
        let plan = DocumentProcessingPlan(
            creatorMetadata: SetPDFCreatorRequest(pdfPath: "/work/raw.pdf"),
            finalOutput: finalOutput
        )

        let result = try await DocumentProcessingOrchestrator(executor: executor).process(plan)

        #expect(result.outputPaths == ["/scans/first output.pdf", "/scans/second.pdf"])
    }

    @Test("No emitted paths maps to compatibility exit status 2")
    func missingFinalOutput() async throws {
        let finalResult = ProcessResult(exitStatus: 0, standardOutput: " \n\r\n")
        let executor = FakeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .result(finalResult),
        ])

        do {
            _ = try await DocumentProcessingOrchestrator(executor: executor).process(try plan())
            Issue.record("Expected missing output failure")
        } catch let error as DocumentProcessingError {
            #expect(error.compatibleExitStatus == 2)
            #expect(error.processResult == finalResult)
            guard case .missingFinalOutput(step: .splitPDFPages, _, _) = error else {
                Issue.record("Expected missingFinalOutput, got \(error)")
                return
            }
        }
    }

    @Test("Existing output diagnostics map to status 73 without losing subprocess status")
    func outputConflict() async throws {
        let conflictResult = ProcessResult(
            exitStatus: 1,
            standardOutput: "partial\n",
            standardError: "FileExistsError: Output file already exists: /scans/page-0001.pdf\n"
        )
        let executor = FakeDocumentProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .result(conflictResult),
        ])

        do {
            _ = try await DocumentProcessingOrchestrator(executor: executor).process(try plan())
            Issue.record("Expected output conflict")
        } catch let error as DocumentProcessingError {
            #expect(error.compatibleExitStatus == 73)
            #expect(error.processResult == conflictResult)
            #expect(error.processResult.exitStatus == 1)
            guard case .outputConflict(step: .splitPDFPages, _, _) = error else {
                Issue.record("Expected outputConflict, got \(error)")
                return
            }
        }
    }

    @Test("Cancellation reaches the active ProcessExecutor and stops the pipeline")
    func cancellation() async throws {
        let executor = FakeDocumentProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let orchestrator = DocumentProcessingOrchestrator(executor: executor)
        let processingPlan = try plan(
            removeBlankPages: RemoveBlankPagesRequest(pdfPath: "/work/raw.pdf")
        )
        let task = Task {
            try await orchestrator.process(processingPlan)
        }

        await executor.waitForRequestCount(1)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await executor.requests().map(\.executable) == ["remove-blank-pages"])
    }

    private func plan(
        removeBlankPages: RemoveBlankPagesRequest? = nil,
        cropPages: CropPDFPagesRequest? = nil,
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) throws -> DocumentProcessingPlan {
        let timestamp = try ScanTimestamp(rawValue: "2026-07-10.142305")
        return DocumentProcessingPlan(
            removeBlankPages: removeBlankPages,
            cropPages: cropPages,
            creatorMetadata: SetPDFCreatorRequest(pdfPath: "/work/raw.pdf"),
            finalOutput: .splitPDF(SplitPDFPagesRequest(
                pdfPath: "/work/raw.pdf",
                outputDirectory: "/scans",
                prefix: timestamp
            )),
            environment: environment,
            workingDirectory: workingDirectory
        )
    }
}

@Suite("Preview rendering orchestration")
struct PreviewRenderingOrchestratorTests {
    @Test("Unavailable native rendering writes the deterministic placeholder")
    func placeholderFallback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("scan.pdf.jpg")
        let request = PreviewToolRequest(
            sourcePath: "/scans/scan.pdf",
            destinationPath: destination.path,
            sourceKind: .pdf
        )

        let outcome = try await PreviewRenderingOrchestrator().render(request)

        #expect(outcome == .placeholderWritten(
            destinationPath: destination.path,
            fallback: .neutralJPEG,
            reason: .rendererUnavailable
        ))
        #expect(try Data(contentsOf: destination) == PlaceholderPreview.jpegBytes)
        #expect(PreviewRenderingStep(request: request).nativeRequirement == .pdfImageExtraction)
    }
}
