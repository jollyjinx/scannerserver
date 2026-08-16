import Foundation
import ScannerServerCore
import Testing

@Suite("OCR queue actor")
struct OCRQueueActorTests {
    @Test("Streaming pages start OCR before acquisition finishes and assemble in order")
    func streamingPages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "streaming-ocr-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(".scan-work.test", isDirectory: true)
        let final = root.appendingPathComponent("2026-08-15.143000.ocr.pdf")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let pdf = Data("%PDF-1.4\nstreamed\n".utf8)
        let executor = FakeProcessExecutor(stubs: [
            .materializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .materializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .materializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(
            executor: executor,
            documentExecutor: executor,
            configuration: OCRQueueConfiguration(cpuLimit: 2)
        )
        let batchID = await queue.beginStreamingScan(StreamingScanRequest(
            documentName: "2026-08-15.143000.pdf",
            finalOutputPath: final.path,
            workDirectory: work,
            environment: ["SCAN_LANGUAGE": "deu+eng"],
            removeBlankPages: false,
            cropPages: false
        ))

        try await queue.submitStreamingPage(
            batchID: batchID,
            page: ScanSnapAcquiredPage(pageNumber: 1, jpegData: Data([0xff, 0xd8, 0xff, 0xd9]))
        )
        await executor.waitForRequestCount(1)
        #expect(await executor.requests().count == 1)

        try await queue.submitStreamingPage(
            batchID: batchID,
            page: ScanSnapAcquiredPage(pageNumber: 2, jpegData: Data([0xff, 0xd8, 0xff, 0xd9]))
        )
        try await queue.finishStreamingScan(batchID: batchID, pageCount: 2)
        await queue.waitUntilIdle()

        let requests = await executor.requests()
        #expect(requests.map(\.executable) == ["ocrmypdf", "ocrmypdf", "qpdf", "set-pdf-creator"])
        #expect(requests[0].ocrWorkerMetadata?.documentName == "2026-08-15.143000.pdf")
        #expect(Set(requests.prefix(2).compactMap { $0.ocrWorkerMetadata?.pageNumber }) == Set([1, 2]))
        #expect(requests[2].arguments.contains { $0.hasSuffix("page-0001.ocr.pdf") })
        #expect(requests[2].arguments.contains { $0.hasSuffix("page-0002.ocr.pdf") })
        #expect(try Data(contentsOf: final) == pdf)
        #expect(!FileManager.default.fileExists(atPath: work.path))
        let state = await queue.state
        let pageTimings = state.recentJobs.filter { $0.metadata?.pageNumber != nil }
        #expect(pageTimings.count == 2)
        #expect(pageTimings.allSatisfy { $0.executionLocation == .local })
    }

    @Test("Submitting a page cannot erase an earlier page completion across suspension")
    func streamingPageSubmissionReentrancy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "streaming-reentrancy-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(".scan-work.test", isDirectory: true)
        let final = root.appendingPathComponent("2026-08-15.222202.ocr.pdf")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let pdf = Data("%PDF-1.4\nstreamed\n".utf8)
        let executor = FakeProcessExecutor(stubs: [
            .suspendedMaterializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .suspendedMaterializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .materializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let pageWriter = SuspendingStreamingPagePDFWriter()
        let queue = OCRQueueActor(
            executor: executor,
            documentExecutor: executor,
            streamingPageWriter: pageWriter,
            configuration: OCRQueueConfiguration(cpuLimit: 1)
        )
        let batchID = await queue.beginStreamingScan(StreamingScanRequest(
            documentName: "2026-08-15.222202.pdf",
            finalOutputPath: final.path,
            workDirectory: work,
            environment: ["SCAN_LANGUAGE": "deu+eng"],
            removeBlankPages: false,
            cropPages: false
        ))

        try await queue.submitStreamingPage(
            batchID: batchID,
            page: ScanSnapAcquiredPage(pageNumber: 1, jpegData: Data([0xff, 0xd8, 0xff, 0xd9]))
        )
        await executor.waitForRequestCount(1)

        let secondSubmission = Task {
            try await queue.submitStreamingPage(
                batchID: batchID,
                page: ScanSnapAcquiredPage(
                    pageNumber: 2,
                    jpegData: Data([0xff, 0xd8, 0xff, 0xd9])
                )
            )
        }
        await pageWriter.waitUntilSecondWriteIsSuspended()

        let firstCompletionRevision = await queue.webUpdates.currentRevision
        await executor.resumeNextSuspendedExecution()
        _ = await queue.webUpdates.wait(after: firstCompletionRevision)

        await pageWriter.resumeSecondWrite()
        try await secondSubmission.value
        await executor.waitForRequestCount(2)
        try await queue.finishStreamingScan(batchID: batchID, pageCount: 2)

        let secondCompletionRevision = await queue.webUpdates.currentRevision
        await executor.resumeNextSuspendedExecution()
        _ = await queue.webUpdates.wait(after: secondCompletionRevision)
        await queue.waitUntilIdle()

        #expect(FileManager.default.fileExists(atPath: final.path))
        #expect(await executor.requests().map(\.executable) == [
            "ocrmypdf", "ocrmypdf", "qpdf", "set-pdf-creator",
        ])
        await queue.cancelAll()
    }

    @Test("A completed final page is not reported as processing during document assembly")
    func streamingFinalPageStateDuringAssembly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "streaming-finalization-state-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(".scan-work.test", isDirectory: true)
        let final = root.appendingPathComponent("2026-08-16.072935.ocr.pdf")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let pdf = Data("%PDF-1.4\nstreamed\n".utf8)
        let executor = FakeProcessExecutor(stubs: [
            .suspendedMaterializeLastArgument(pdf, ProcessResult(
                exitStatus: 0,
                executionLocation: .remote
            )),
            .suspendedMaterializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(
            executor: executor,
            documentExecutor: executor,
            configuration: OCRQueueConfiguration(cpuLimit: 1)
        )
        let batchID = await queue.beginStreamingScan(StreamingScanRequest(
            documentName: "2026-08-16.072935.pdf",
            finalOutputPath: final.path,
            workDirectory: work,
            environment: ["SCAN_LANGUAGE": "deu"],
            removeBlankPages: false,
            cropPages: true
        ))

        try await queue.submitStreamingPage(
            batchID: batchID,
            page: ScanSnapAcquiredPage(pageNumber: 62, jpegData: Data([0xff, 0xd8, 0xff, 0xd9]))
        )
        await executor.waitForRequestCount(1)
        try await queue.finishStreamingScan(batchID: batchID, pageCount: 1)

        await executor.resumeNextSuspendedExecution()
        await executor.waitForRequestCount(2)

        let assemblingState = await queue.state
        #expect(assemblingState.recentJobs.first?.status == "done")
        #expect(assemblingState.processingJobs.isEmpty)
        #expect(assemblingState.finalizingJobs.count == 1)
        #expect(assemblingState.finalizingJobs.first?.documentName == "2026-08-16.072935.pdf")
        #expect(assemblingState.finalizingJobs.first?.operations == [
            "assemble OCR pages", "publish searchable PDF",
        ])

        await executor.resumeNextSuspendedExecution()
        await queue.waitUntilIdle()
        #expect(FileManager.default.fileExists(atPath: final.path))
    }

    @Test("Streaming autocrop is requested from the remote worker and not repeated after assembly")
    func streamingRemoteAutocrop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "streaming-remote-crop-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(".scan-work.test", isDirectory: true)
        let final = root.appendingPathComponent("2026-08-15.160206.ocr.pdf")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let pdf = Data("%PDF-1.4\nremote cropped\n".utf8)
        let executor = FakeProcessExecutor(stubs: [
            .materializeLastArgument(pdf, ProcessResult(exitStatus: 0, executionLocation: .remote)),
            .materializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(
            executor: executor,
            documentExecutor: executor,
            configuration: OCRQueueConfiguration(cpuLimit: 1)
        )
        let batchID = await queue.beginStreamingScan(StreamingScanRequest(
            documentName: "2026-08-15.160206.pdf",
            finalOutputPath: final.path,
            workDirectory: work,
            environment: [
                "SCAN_LANGUAGE": "deu+eng",
                "SCAN_CROP_MARGIN_POINTS": "2.5",
            ],
            removeBlankPages: false,
            cropPages: true
        ))

        try await queue.submitStreamingPage(
            batchID: batchID,
            page: ScanSnapAcquiredPage(pageNumber: 1, jpegData: Data([0xff, 0xd8, 0xff, 0xd9]))
        )
        try await queue.finishStreamingScan(batchID: batchID, pageCount: 1)
        await queue.waitUntilIdle()

        let requests = await executor.requests()
        #expect(requests.map(\.executable) == ["ocrmypdf", "qpdf", "set-pdf-creator"])
        #expect(requests[0].ocrWorkerCropConfiguration?.marginPoints == 2.5)
        #expect(try Data(contentsOf: final) == pdf)
    }

    @Test("Streaming autocrop falls back locally when OCR was not remote")
    func streamingLocalAutocropFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "streaming-local-crop-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(".scan-work.test", isDirectory: true)
        let final = root.appendingPathComponent("2026-08-15.160207.ocr.pdf")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let pdf = Data("%PDF-1.4\nlocally cropped\n".utf8)
        let executor = FakeProcessExecutor(stubs: [
            .materializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
            .materializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(
            executor: executor,
            documentExecutor: executor,
            configuration: OCRQueueConfiguration(cpuLimit: 1)
        )
        let batchID = await queue.beginStreamingScan(StreamingScanRequest(
            documentName: "2026-08-15.160207.pdf",
            finalOutputPath: final.path,
            workDirectory: work,
            environment: ["SCAN_LANGUAGE": "deu+eng"],
            removeBlankPages: false,
            cropPages: true
        ))

        try await queue.submitStreamingPage(
            batchID: batchID,
            page: ScanSnapAcquiredPage(pageNumber: 1, jpegData: Data([0xff, 0xd8, 0xff, 0xd9]))
        )
        try await queue.finishStreamingScan(batchID: batchID, pageCount: 1)
        await queue.waitUntilIdle()

        #expect(await executor.requests().map(\.executable) == [
            "ocrmypdf", "crop-pdf-pages", "qpdf", "set-pdf-creator",
        ])
        #expect(try Data(contentsOf: final) == pdf)
    }

    @Test("Streaming blank removal runs per page and is not repeated after assembly")
    func streamingBlankRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "streaming-blank-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(".scan-work.test", isDirectory: true)
        let final = root.appendingPathComponent("2026-08-16.082110.ocr.pdf")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let pdf = Data("%PDF-1.4\npage filtered on worker\n".utf8)
        let executor = FakeProcessExecutor(stubs: [
            .materializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0, standardOutput: "Removed 0 blank pages.\n")),
            .result(ProcessResult(exitStatus: 0, standardOutput: "1\n")),
            .materializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(
            executor: executor,
            documentExecutor: executor,
            configuration: OCRQueueConfiguration(cpuLimit: 1)
        )
        let batchID = await queue.beginStreamingScan(StreamingScanRequest(
            documentName: "2026-08-16.082110.pdf",
            finalOutputPath: final.path,
            workDirectory: work,
            environment: [
                "SCAN_BLANK_WHITE_THRESHOLD": "240",
                "SCAN_BLANK_CONTENT_RATIO_THRESHOLD": "0.004",
                "SCAN_BLANK_MEAN_THRESHOLD": "249",
            ],
            removeBlankPages: true,
            cropPages: false
        ))

        try await queue.submitStreamingPage(
            batchID: batchID,
            page: ScanSnapAcquiredPage(pageNumber: 1, jpegData: Data([0xff, 0xd8, 0xff, 0xd9]))
        )
        try await queue.finishStreamingScan(batchID: batchID, pageCount: 1)
        await queue.waitUntilIdle()

        let requests = await executor.requests()
        #expect(requests.map(\.executable) == [
            "ocrmypdf", "remove-blank-pages", "qpdf", "qpdf", "set-pdf-creator",
        ])
        #expect(requests[0].ocrWorkerBlankPageConfiguration == OCRWorkerBlankPageConfiguration(
            whiteThreshold: 240,
            contentRatioThreshold: 0.004,
            meanThreshold: 249
        ))
        #expect(requests[1].arguments.contains("--no-keep-one"))
        #expect(requests[2].arguments.first == "--show-npages")
        #expect(try Data(contentsOf: final) == pdf)
    }

    @Test("An entirely blank streaming scan keeps its first source page")
    func streamingAllBlankKeepsOnePage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "streaming-all-blank-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(".scan-work.test", isDirectory: true)
        let final = root.appendingPathComponent("2026-08-16.082111.ocr.pdf")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let emptyPDF = Data("%PDF-1.4\nzero pages\n".utf8)
        let executor = FakeProcessExecutor(stubs: [
            .materializeLastArgument(emptyPDF, ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0, standardOutput: "Removed 1 blank page.\n")),
            .result(ProcessResult(exitStatus: 0, standardOutput: "0\n")),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(
            executor: executor,
            documentExecutor: executor,
            configuration: OCRQueueConfiguration(cpuLimit: 1)
        )
        let batchID = await queue.beginStreamingScan(StreamingScanRequest(
            documentName: "2026-08-16.082111.pdf",
            finalOutputPath: final.path,
            workDirectory: work,
            environment: [:],
            removeBlankPages: true,
            cropPages: false
        ))

        try await queue.submitStreamingPage(
            batchID: batchID,
            page: ScanSnapAcquiredPage(pageNumber: 1, jpegData: Data([0xff, 0xd8, 0xff, 0xd9]))
        )
        try await queue.finishStreamingScan(batchID: batchID, pageCount: 1)
        await queue.waitUntilIdle()

        #expect(FileManager.default.fileExists(atPath: final.path))
        #expect(await executor.requests().map(\.executable) == [
            "ocrmypdf", "remove-blank-pages", "qpdf", "set-pdf-creator",
        ])
    }

    @Test("Deleting a raw document cancels its active and queued streaming pages")
    func deletingStreamingDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "streaming-delete-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(".scan-work.test", isDirectory: true)
        let raw = root.appendingPathComponent("2026-08-15.210920.pdf")
        let final = root.appendingPathComponent("2026-08-15.210920.ocr.pdf")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let executor = FakeProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(
            executor: executor,
            configuration: OCRQueueConfiguration(cpuLimit: 1)
        )
        let batchID = await queue.beginStreamingScan(StreamingScanRequest(
            documentName: raw.lastPathComponent,
            finalOutputPath: final.path,
            workDirectory: work,
            environment: ["SCAN_LANGUAGE": "deu+eng"],
            removeBlankPages: false,
            cropPages: false
        ))

        try await queue.submitStreamingPage(
            batchID: batchID,
            page: ScanSnapAcquiredPage(pageNumber: 1, jpegData: Data([0xff, 0xd8, 0xff, 0xd9]))
        )
        await executor.waitForRequestCount(1)
        try await queue.submitStreamingPage(
            batchID: batchID,
            page: ScanSnapAcquiredPage(pageNumber: 2, jpegData: Data([0xff, 0xd8, 0xff, 0xd9]))
        )
        try await queue.finishStreamingScan(batchID: batchID, pageCount: 2)

        await queue.cancelJobs(referencing: raw.path)
        await queue.waitUntilIdle()

        #expect(await executor.requests().count == 1)
        #expect(!FileManager.default.fileExists(atPath: work.path))
        #expect(!FileManager.default.fileExists(atPath: final.path))
        #expect(await queue.state.status == "cancelled")
        #expect(await queue.state.queued == 0)
        #expect(await queue.state.running == 0)
    }

    @Test("Multipage jobs execute in FIFO order within one CPU budget")
    func fifo() async {
        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "/scans/one.ocr.pdf\n")),
            .result(ProcessResult(exitStatus: 0, standardOutput: "/scans/two.ocr.pdf\n")),
            .result(ProcessResult(exitStatus: 0, standardOutput: "/scans/three.ocr.pdf\n")),
        ])
        let queue = OCRQueueActor(executor: executor, configuration: serialOCRConfiguration)

        await queue.enqueue("/scans/one.pdf")
        await queue.enqueue("/scans/two.pdf")
        await queue.enqueue("/scans/three.pdf")
        await queue.waitUntilIdle()

        let requests = await executor.requests()
        #expect(requests.map(\.executable) == ["ocrmypdf", "ocrmypdf", "ocrmypdf"])
        #expect(requests.map(\.arguments) == [
            ocrArguments(input: "/scans/one.pdf", output: "/scans/one.ocr.pdf"),
            ocrArguments(input: "/scans/two.pdf", output: "/scans/two.ocr.pdf"),
            ocrArguments(input: "/scans/three.pdf", output: "/scans/three.ocr.pdf"),
        ])

        let state = await queue.state
        #expect(state.status == "done")
        #expect(state.input == "/scans/three.pdf")
        #expect(state.output == "/scans/three.ocr.pdf")
        #expect(state.error.isEmpty)
        #expect(state.queued == 0)
        #expect(state.recentJobs.map(\.input) == [
            "/scans/three.pdf", "/scans/two.pdf", "/scans/one.pdf",
        ])
        #expect(state.recentJobs.allSatisfy { $0.status == "done" && $0.duration >= 0 })
    }

    @Test("Preprocessing uses an isolated copy and publishes OCR beside the source")
    func isolatedPreprocessing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ocr-queue-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("scan.pdf")
        let output = root.appendingPathComponent("scan.ocr.pdf")
        let workspace = root.appendingPathComponent(".ocr-work.test", isDirectory: true)
        let stagedInput = workspace.appendingPathComponent("source.pdf")
        try Data("raw source".utf8).write(to: input)

        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(
            executor: executor,
            documentExecutor: executor,
            workspaceSuffixProvider: { "test" },
            configuration: serialOCRConfiguration
        )

        await queue.enqueue(
            input.path,
            environment: ["SCAN_LANGUAGE": "eng"],
            removeBlankPages: true,
            cropPages: true
        )
        await queue.waitUntilIdle()

        let requests = await executor.requests()
        #expect(requests.map(\.executable) == [
            "remove-blank-pages", "crop-pdf-pages", "ocrmypdf",
        ])
        #expect(requests[0].arguments.first == stagedInput.path)
        #expect(requests[1].arguments.first == stagedInput.path)
        #expect(requests[2].arguments == ocrArguments(
            input: stagedInput.path,
            output: output.path,
            language: "eng"
        ))
        #expect(requests.allSatisfy { $0.workingDirectory == workspace })
        #expect(try Data(contentsOf: input) == Data("raw source".utf8))
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        #expect(await queue.state.status == "done")
        #expect(await queue.state.output == output.path)
    }

    @Test("Processing-only jobs replace the source without launching OCR")
    func processingOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "processing-queue-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("scan.pdf")
        try Data("raw source".utf8).write(to: input)

        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(
            executor: executor,
            documentExecutor: executor,
            workspaceSuffixProvider: { "processing-test" },
            configuration: serialOCRConfiguration
        )

        await queue.enqueue(
            input.path,
            ocrEnabled: false,
            removeBlankPages: true,
            cropPages: true
        )
        await queue.waitUntilIdle()

        #expect(await executor.requests().map(\.executable) == [
            "remove-blank-pages", "crop-pdf-pages",
        ])
        #expect(await queue.state.status == "done")
        #expect(await queue.state.output == input.path)
        #expect(try Data(contentsOf: input) == Data("raw source".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".ocr-work.processing-test").path
        ))
    }

    @Test("Nice priority applies to every post-scan preprocessing command")
    func nicePriorityCoversPreprocessing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nice-processing-queue-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("scan.pdf")
        try Data("raw source".utf8).write(to: input)

        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(
            executor: executor,
            documentExecutor: executor,
            workspaceSuffixProvider: { "nice-processing-test" },
            configuration: OCRQueueConfiguration(cpuLimit: 1, niceLevel: 10)
        )

        await queue.enqueue(
            input.path,
            ocrEnabled: false,
            removeBlankPages: true,
            cropPages: true
        )
        await queue.waitUntilIdle()

        let requests = await executor.requests()
        #expect(requests.map(\.executable) == ["remove-blank-pages", "crop-pdf-pages"])
        #expect(requests.map(\.niceLevel) == [10, 10])
    }

    @Test("Deferred single-page processing preserves preprocessing order and queues OCR")
    func deferredSinglePageProcessing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deferred-single-page-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(".scan-work.test", isDirectory: true)
        let input = work.appendingPathComponent("raw.pdf")
        let prefix = "2026-08-13.205338"
        let firstPage = root.appendingPathComponent("\(prefix)-page-0001.pdf")
        let secondPage = root.appendingPathComponent("\(prefix)-page-0002.pdf")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("raw source".utf8).write(to: input)

        let executor = FakeNativeScanProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
            .materialize(
                files: [
                    firstPage.path: Data("page one".utf8),
                    secondPage.path: Data("page two".utf8),
                ],
                result: ProcessResult(
                    exitStatus: 0,
                    standardOutput: "\(firstPage.path)\n\(secondPage.path)\n"
                )
            ),
            .result(ProcessResult(
                exitStatus: 0,
                standardOutput: "\(firstPage.deletingPathExtension().path).ocr.pdf\n"
            )),
            .result(ProcessResult(
                exitStatus: 0,
                standardOutput: "\(secondPage.deletingPathExtension().path).ocr.pdf\n"
            )),
        ])
        let environment = [
            "SCAN_PAGE_MODE": "single",
            "SCAN_LANGUAGE": "eng",
            "SCAN_OCR_NICE": "true",
            "SCAN_OCR_NICE_LEVEL": "12",
        ]
        let plan = DocumentProcessingPlan(
            removeBlankPages: RemoveBlankPagesRequest(pdfPath: input.path),
            cropPages: CropPDFPagesRequest(pdfPath: input.path),
            creatorMetadata: SetPDFCreatorRequest(pdfPath: input.path),
            finalOutput: .splitPDF(SplitPDFPagesRequest(
                pdfPath: input.path,
                outputDirectory: root.path,
                prefix: try ScanTimestamp(rawValue: prefix)
            )),
            environment: environment,
            workingDirectory: work
        )
        let queue = OCRQueueActor(
            executor: executor,
            documentExecutor: executor,
            configuration: serialOCRConfiguration
        )

        await queue.enqueue(DeferredScanProcessing(
            inputPath: input.path,
            cleanupDirectory: work,
            plan: plan,
            ocrEnabled: true
        ))
        await queue.waitUntilIdle()

        let requests = await executor.requests()
        #expect(requests.map(\.executable) == [
            "remove-blank-pages",
            "crop-pdf-pages",
            "set-pdf-creator",
            "split-pdf-pages",
            "ocrmypdf",
            "ocrmypdf",
        ])
        #expect(requests[0].arguments.first == input.path)
        #expect(requests[1].arguments.first == input.path)
        #expect(requests[2].arguments.first == input.path)
        #expect(requests[3].arguments == [input.path, root.path, prefix])
        #expect(requests[4].arguments == ocrArguments(
            input: firstPage.path,
            output: firstPage.deletingPathExtension().path + ".ocr.pdf",
            language: "eng"
        ))
        #expect(requests[5].arguments == ocrArguments(
            input: secondPage.path,
            output: secondPage.deletingPathExtension().path + ".ocr.pdf",
            language: "eng"
        ))
        #expect(requests.allSatisfy { $0.niceLevel == 12 })
        #expect(!FileManager.default.fileExists(atPath: work.path))
        #expect(await queue.state.status == "done")
        #expect(await queue.state.recentJobs.count == 3)
    }

    @Test("Deferred output conflicts retain status compatibility and clean work files")
    func deferredOutputConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deferred-conflict-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(".scan-work.test", isDirectory: true)
        let input = work.appendingPathComponent("raw.pdf")
        let prefix = "2026-08-13.205339"
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("raw source".utf8).write(to: input)

        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(
                exitStatus: 1,
                standardError: "FileExistsError: page already exists\n"
            )),
        ])
        let plan = DocumentProcessingPlan(
            creatorMetadata: SetPDFCreatorRequest(pdfPath: input.path),
            finalOutput: .splitPDF(SplitPDFPagesRequest(
                pdfPath: input.path,
                outputDirectory: root.path,
                prefix: try ScanTimestamp(rawValue: prefix)
            )),
            workingDirectory: work
        )
        let queue = OCRQueueActor(
            executor: executor,
            documentExecutor: executor,
            configuration: serialOCRConfiguration
        )

        await queue.enqueue(DeferredScanProcessing(
            inputPath: input.path,
            cleanupDirectory: work,
            plan: plan,
            ocrEnabled: false
        ))
        await queue.waitUntilIdle()

        #expect(await executor.requests().map(\.executable) == [
            "set-pdf-creator", "split-pdf-pages",
        ])
        #expect(await queue.state.status == "failed (73)")
        #expect(await queue.state.error.contains("FileExistsError"))
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }

    @Test("Deferred processing rejects reported outputs that do not exist")
    func deferredMissingFinalOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deferred-missing-output-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(".scan-work.test", isDirectory: true)
        let input = work.appendingPathComponent("raw.pdf")
        let prefix = "2026-08-13.205342"
        let missingPage = root.appendingPathComponent("\(prefix)-page-0001.pdf")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("raw source".utf8).write(to: input)

        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(
                exitStatus: 0,
                standardOutput: missingPage.path + "\n"
            )),
        ])
        let plan = DocumentProcessingPlan(
            creatorMetadata: SetPDFCreatorRequest(pdfPath: input.path),
            finalOutput: .splitPDF(SplitPDFPagesRequest(
                pdfPath: input.path,
                outputDirectory: root.path,
                prefix: try ScanTimestamp(rawValue: prefix)
            )),
            workingDirectory: work
        )
        let queue = OCRQueueActor(
            executor: executor,
            documentExecutor: executor,
            configuration: serialOCRConfiguration
        )

        await queue.enqueue(DeferredScanProcessing(
            inputPath: input.path,
            cleanupDirectory: work,
            plan: plan,
            ocrEnabled: false
        ))
        await queue.waitUntilIdle()

        #expect(await executor.requests().map(\.executable) == [
            "set-pdf-creator", "split-pdf-pages",
        ])
        #expect(await queue.state.status == "failed (2)")
        #expect(await queue.state.error == "No output files were created.")
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }

    @Test("Invalid deferred cleanup scope is rejected without deleting files")
    func invalidDeferredCleanupScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "invalid-deferred-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("raw.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: input)

        let executor = FakeProcessExecutor(stubs: [])
        let plan = DocumentProcessingPlan(
            creatorMetadata: SetPDFCreatorRequest(pdfPath: input.path),
            finalOutput: .splitPDF(SplitPDFPagesRequest(
                pdfPath: input.path,
                outputDirectory: root.path,
                prefix: try ScanTimestamp(rawValue: "2026-08-13.205340")
            )),
            workingDirectory: root
        )
        let queue = OCRQueueActor(
            executor: executor,
            documentExecutor: executor,
            configuration: serialOCRConfiguration
        )

        await queue.enqueue(DeferredScanProcessing(
            inputPath: input.path,
            cleanupDirectory: root,
            plan: plan,
            ocrEnabled: false
        ))
        await queue.waitUntilIdle()

        #expect(await executor.requests().isEmpty)
        #expect(await queue.state.status == "failed (64)")
        #expect(FileManager.default.fileExists(atPath: input.path))
    }

    @Test("Invalid and conflicting paths fail without launching OCR")
    func invalidAndConflictingPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("scan.pdf")
        let output = root.appendingPathComponent("scan.ocr.pdf")
        try Data().write(to: output)
        let executor = FakeProcessExecutor(stubs: [])
        let queue = OCRQueueActor(executor: executor, configuration: serialOCRConfiguration)

        await queue.enqueue(root.appendingPathComponent("scan.png").path)
        await queue.enqueue(input.path)
        await queue.waitUntilIdle()

        #expect(await executor.requests().isEmpty)
        #expect(await queue.state.status == "failed (73)")
        #expect(await queue.state.error.contains(output.path))
    }

    @Test("A failed OCR job does not prevent the next queued job")
    func failureContinuesQueue() async {
        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 73, standardError: "already exists\n")),
            .result(ProcessResult(exitStatus: 0, standardOutput: "/scans/two.ocr.pdf\n")),
        ])
        let queue = OCRQueueActor(executor: executor, configuration: serialOCRConfiguration)

        await queue.enqueue("/scans/one.pdf")
        await queue.enqueue("/scans/two.pdf")
        await queue.waitUntilIdle()

        #expect(await executor.requests().count == 2)
        #expect(await queue.state.status == "done")
        #expect(await queue.state.input == "/scans/two.pdf")
    }

    @Test("Cancellation stops the worker and clears queued jobs")
    func cancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cancelled-deferred-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(".scan-work.queued", isDirectory: true)
        let input = work.appendingPathComponent("raw.pdf")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("queued".utf8).write(to: input)

        let executor = FakeProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(executor: executor, configuration: serialOCRConfiguration)
        let deferred = DeferredScanProcessing(
            inputPath: input.path,
            cleanupDirectory: work,
            plan: DocumentProcessingPlan(
                creatorMetadata: SetPDFCreatorRequest(pdfPath: input.path),
                finalOutput: .splitPDF(SplitPDFPagesRequest(
                    pdfPath: input.path,
                    outputDirectory: root.path,
                    prefix: try ScanTimestamp(rawValue: "2026-08-13.205341")
                )),
                workingDirectory: work
            ),
            ocrEnabled: false
        )

        await queue.enqueue("/scans/one.pdf")
        await queue.enqueue(deferred)
        await executor.waitForRequestCount(1)
        await queue.cancelAll()

        #expect(await executor.requests().count == 1)
        #expect(await queue.state.status == "cancelled")
        #expect(await queue.state.queued == 0)
        #expect(await queue.state.recentJobs.first?.input == "/scans/one.pdf")
        #expect(await queue.state.recentJobs.first?.status == "cancelled")
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }

    @Test("Cancellation discards OCR follow-ups from late deferred completion")
    func cancellationDiscardsDeferredFollowUps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cancelled-deferred-follow-up-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(".scan-work.active", isDirectory: true)
        let input = work.appendingPathComponent("raw.pdf")
        let prefix = "2026-08-13.205343"
        let page = root.appendingPathComponent("\(prefix)-page-0001.pdf")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: input)
        try Data("page".utf8).write(to: page)

        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0)),
            .suspendedIgnoringCancellation(ProcessResult(
                exitStatus: 0,
                standardOutput: page.path + "\n"
            )),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(
            executor: executor,
            documentExecutor: executor,
            configuration: serialOCRConfiguration
        )
        let deferred = DeferredScanProcessing(
            inputPath: input.path,
            cleanupDirectory: work,
            plan: DocumentProcessingPlan(
                creatorMetadata: SetPDFCreatorRequest(pdfPath: input.path),
                finalOutput: .splitPDF(SplitPDFPagesRequest(
                    pdfPath: input.path,
                    outputDirectory: root.path,
                    prefix: try ScanTimestamp(rawValue: prefix)
                )),
                workingDirectory: work
            ),
            ocrEnabled: true
        )

        await queue.enqueue(deferred)
        await executor.waitForRequestCount(2)
        let cancellation = Task { await queue.cancelAll() }
        await executor.waitForIgnoredCancellationCount(1)
        await executor.resumeNextSuspendedExecution()
        await cancellation.value
        await queue.waitUntilIdle()

        #expect(await executor.requests().map(\.executable) == [
            "set-pdf-creator", "split-pdf-pages",
        ])
        #expect(await queue.state.status == "cancelled")
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }

    @Test("Cancelling the active job preserves unrelated queued jobs")
    func targetedActiveCancellation() async {
        let executor = FakeProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0, standardOutput: "/scans/two.ocr.pdf\n")),
        ])
        let queue = OCRQueueActor(executor: executor, configuration: serialOCRConfiguration)

        await queue.enqueue("/scans/one.pdf")
        await queue.enqueue("/scans/two.pdf")
        await executor.waitForRequestCount(1)
        await queue.cancelJobs(referencing: "/scans/one.pdf")
        await queue.waitUntilIdle()

        #expect(await executor.requests().count == 2)
        #expect(await queue.state.status == "done")
        #expect(await queue.state.input == "/scans/two.pdf")
        #expect(await queue.state.recentJobs.map(\.status) == ["done", "cancelled"])
    }

    @Test("Cancelling a queued job by its output path leaves the active job running")
    func targetedQueuedCancellation() async {
        let executor = FakeProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0, standardOutput: "/scans/one.ocr.pdf\n")),
        ])
        let queue = OCRQueueActor(executor: executor, configuration: serialOCRConfiguration)

        await queue.enqueue("/scans/one.pdf")
        await executor.waitForRequestCount(1)
        await queue.enqueue("/scans/two.pdf")
        await queue.cancelJobs(referencing: "/scans/two.ocr.pdf")
        await executor.resumeNextSuspendedExecution()
        await queue.waitUntilIdle()

        #expect(await executor.requests().count == 1)
        #expect(await queue.state.status == "done")
        #expect(await queue.state.input == "/scans/one.pdf")
        #expect(await queue.state.queued == 0)
    }

    @Test("Single-page jobs use one OCR process per available CPU")
    func singlePageConcurrency() async {
        let executor = FakeProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0)),
            .suspended(ProcessResult(exitStatus: 0)),
            .suspended(ProcessResult(exitStatus: 0)),
            .suspended(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(
            executor: executor,
            configuration: OCRQueueConfiguration(cpuLimit: 3, niceLevel: 10)
        )
        let environment = ["SCAN_PAGE_MODE": "single"]

        await queue.enqueue("/scans/one.pdf", environment: environment)
        await queue.enqueue("/scans/two.pdf", environment: environment)
        await queue.enqueue("/scans/three.pdf", environment: environment)
        await queue.enqueue("/scans/four.pdf", environment: environment)
        await executor.waitForRequestCount(3)

        #expect(await queue.state.running == 3)
        #expect(await queue.state.queued == 1)
        let firstRequests = await executor.requests()
        #expect(firstRequests.allSatisfy {
            $0.executable == "ocrmypdf"
                && $0.niceLevel == 10
                && argumentValue("--jobs", in: $0.arguments) == "1"
        })

        await executor.resumeNextSuspendedExecution()
        await executor.waitForRequestCount(4)
        #expect(await queue.state.running == 3)
        #expect(await queue.state.queued == 0)

        await queue.cancelAll()
        #expect(await queue.state.running == 0)
        #expect(await queue.state.queued == 0)
    }

    @Test("Remote worker slots are added to the optional internal OCR capacity")
    func aggregateWorkerConcurrency() async {
        let executor = FakeProcessExecutor(stubs: Array(
            repeating: .suspended(ProcessResult(exitStatus: 0)),
            count: 18
        ))
        let capacity = TestWorkerCapacityProvider(
            OCRQueueWorkerCapacity(remoteJobSlots: 14, internalOCREnabled: false)
        )
        let queue = OCRQueueActor(
            executor: executor,
            configuration: OCRQueueConfiguration(cpuLimit: 3),
            workerCapacityProvider: { await capacity.value }
        )
        let environment = ["SCAN_PAGE_MODE": "single"]

        for page in 1...18 {
            await queue.enqueue("/scans/page-\(page).pdf", environment: environment)
        }
        await executor.waitForRequestCount(14)

        #expect(await queue.state.running == 14)
        #expect(await queue.state.queued == 4)

        await capacity.set(
            OCRQueueWorkerCapacity(remoteJobSlots: 14, internalOCREnabled: true)
        )
        await queue.capacityDidChange()
        await executor.waitForRequestCount(17)

        #expect(await queue.state.running == 17)
        #expect(await queue.state.queued == 1)
        let requests = await executor.requests()
        #expect(requests.filter { $0.ocrExecutionPreference == .automatic }.count == 14)
        #expect(requests.filter { $0.ocrExecutionPreference == .localOnly }.count == 3)

        await queue.cancelAll()
    }

    @Test("A saved CPU limit controls multipage OCRmyPDF workers")
    func multipageCPULimit() async {
        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "/scans/one.ocr.pdf\n")),
        ])
        let queue = OCRQueueActor(
            executor: executor,
            configuration: OCRQueueConfiguration(cpuLimit: 8, niceLevel: nil)
        )

        await queue.enqueue(
            "/scans/one.pdf",
            environment: ["SCAN_OCR_CPU_LIMIT": "3"]
        )
        await queue.waitUntilIdle()

        let request = await executor.requests().first
        #expect(request?.executable == "ocrmypdf")
        #expect(argumentValue("--jobs", in: request?.arguments ?? []) == "3")
    }

    @Test("A saved OCR priority overrides the queue default", arguments: [
        (
            queueNiceLevel: Optional(10),
            modeNice: "false",
            expectedNiceLevel: Optional<Int>.none,
            expectedExecutable: "ocrmypdf"
        ),
        (
            queueNiceLevel: Optional<Int>.none,
            modeNice: "true",
            expectedNiceLevel: Optional(15),
            expectedExecutable: "ocrmypdf"
        ),
    ])
    func savedPriority(
        queueNiceLevel: Int?,
        modeNice: String,
        expectedNiceLevel: Int?,
        expectedExecutable: String
    ) async {
        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "/scans/one.ocr.pdf\n")),
        ])
        let queue = OCRQueueActor(
            executor: executor,
            configuration: OCRQueueConfiguration(cpuLimit: 1, niceLevel: queueNiceLevel)
        )

        var environment = ["SCAN_OCR_NICE": modeNice]
        environment["SCAN_OCR_NICE_LEVEL"] = "15"
        await queue.enqueue("/scans/one.pdf", environment: environment)
        await queue.waitUntilIdle()

        let request = await executor.requests().first
        #expect(request?.executable == expectedExecutable)
        #expect(request?.niceLevel == expectedNiceLevel)
        #expect(await queue.state.niceLevel == expectedNiceLevel)
    }

    @Test("A saved CPU limit caps parallel pages from one scan")
    func singlePageBatchCPULimit() async {
        let executor = FakeProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0)),
            .suspended(ProcessResult(exitStatus: 0)),
            .suspended(ProcessResult(exitStatus: 0)),
            .suspended(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(
            executor: executor,
            configuration: OCRQueueConfiguration(cpuLimit: 4, niceLevel: nil)
        )
        let batchID = UUID()
        let environment = [
            "SCAN_PAGE_MODE": "single",
            "SCAN_OCR_CPU_LIMIT": "2",
        ]

        await queue.enqueue("/scans/one.pdf", batchID: batchID, environment: environment)
        await queue.enqueue("/scans/two.pdf", batchID: batchID, environment: environment)
        await queue.enqueue("/scans/three.pdf", batchID: batchID, environment: environment)
        await queue.enqueue("/scans/four.pdf", batchID: batchID, environment: environment)
        await executor.waitForRequestCount(2)

        #expect(await queue.state.running == 2)
        #expect(await queue.state.queued == 2)
        #expect(await queue.state.processingJobs.count == 2)
        #expect(await queue.state.waitingJobs.map(\.documentName) == ["three.pdf", "four.pdf"])

        await executor.resumeNextSuspendedExecution()
        await executor.waitForRequestCount(3)
        #expect(await queue.state.running == 2)
        #expect(await queue.state.queued == 1)

        await queue.cancelAll()
    }
}

private actor SuspendingStreamingPagePDFWriter: StreamingPagePDFWriting {
    private var writeCount = 0
    private var secondWriteIsSuspended = false
    private var secondWriteContinuation: CheckedContinuation<Void, Never>?
    private var secondWriteWaiters: [CheckedContinuation<Void, Never>] = []

    func write(pages: [Data], to outputURL: URL) async throws {
        try await ScanSnapPDFWriter().write(pages: pages, to: outputURL)
        writeCount += 1
        guard writeCount == 2 else { return }
        await withCheckedContinuation { continuation in
            secondWriteContinuation = continuation
            secondWriteIsSuspended = true
            let waiters = secondWriteWaiters
            secondWriteWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilSecondWriteIsSuspended() async {
        guard !secondWriteIsSuspended else { return }
        await withCheckedContinuation { continuation in
            secondWriteWaiters.append(continuation)
        }
    }

    func resumeSecondWrite() {
        secondWriteContinuation?.resume()
        secondWriteContinuation = nil
        secondWriteIsSuspended = false
    }
}

private let serialOCRConfiguration = OCRQueueConfiguration(cpuLimit: 1, niceLevel: nil)

private actor TestWorkerCapacityProvider {
    private(set) var value: OCRQueueWorkerCapacity

    init(_ value: OCRQueueWorkerCapacity) {
        self.value = value
    }

    func set(_ value: OCRQueueWorkerCapacity) {
        self.value = value
    }
}

private func ocrArguments(
    input: String,
    output: String,
    language: String = "deu+eng"
) -> [String] {
    [
        "--language", language,
        "--rotate-pages",
        "--rotate-pages-threshold", "2.0",
        "--deskew",
        "--optimize", "1",
        "--jobs", "1",
        input,
        output,
    ]
}

private func argumentValue(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}
