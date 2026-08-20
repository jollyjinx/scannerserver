import Foundation
import ScannerServerCore
import Testing

@Suite("Streaming OCR document module")
struct StreamingOCRDocumentModuleTests {
    @Test("Out-of-order page completion assembles in source order")
    func outOfOrderCompletion() async throws {
        let fixture = try StreamingDocumentFixture(name: "out-of-order")
        defer { fixture.remove() }
        let pdf = Data("%PDF-1.4\nmerged\n".utf8)
        let executor = FakeProcessExecutor(stubs: [
            .materializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let module = StreamingOCRDocumentModule(documentExecutor: executor)
        let documentID = await module.begin(fixture.request())
        let page2 = try await fixture.reservePage(2, in: module, documentID: documentID)
        let page1 = try await fixture.reservePage(1, in: module, documentID: documentID)
        let output2 = try fixture.writeProcessedPage(2)
        let output1 = try fixture.writeProcessedPage(1)

        await module.completePage(page2.reservation, outcome: .succeeded(outputURL: output2))
        await module.completePage(page1.reservation, outcome: .succeeded(outputURL: output1))
        try await module.seal(documentID, expectedPageCount: 2)
        await module.waitUntilIdle()

        let requests = await executor.requests()
        #expect(requests.map(\.executable) == ["qpdf", "set-pdf-creator"])
        let mergeArguments = requests[0].arguments
        let page1Index = try #require(mergeArguments.firstIndex(of: output1.path))
        let page2Index = try #require(mergeArguments.firstIndex(of: output2.path))
        #expect(page1Index < page2Index)
        #expect(try Data(contentsOf: fixture.finalOutput) == pdf)
        #expect(!(await module.state.activeDocumentIDs.contains(documentID)))
    }

    @Test("A suspended page reservation cannot overwrite an earlier completion")
    func pageReservationReentrancy() async throws {
        let fixture = try StreamingDocumentFixture(name: "page-reentrancy")
        defer { fixture.remove() }
        let pdf = Data("%PDF-1.4\nreentrant\n".utf8)
        let executor = FakeProcessExecutor(stubs: [
            .materializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let writer = SecondWriteSuspendingPageWriter()
        let module = StreamingOCRDocumentModule(documentExecutor: executor, pageWriter: writer)
        let documentID = await module.begin(fixture.request())
        let page1 = try await module.reserveJPEGPage(
            documentID: documentID,
            page: ScanSnapAcquiredPage(pageNumber: 1, jpegData: Data("one".utf8))
        )
        let output1 = try fixture.writeProcessedPage(1)
        await module.completePage(page1.reservation, outcome: .succeeded(outputURL: output1))

        let secondReservation = Task {
            try await module.reserveJPEGPage(
                documentID: documentID,
                page: ScanSnapAcquiredPage(pageNumber: 2, jpegData: Data("two".utf8))
            )
        }
        await writer.waitUntilSecondWriteIsSuspended()
        await writer.resumeSecondWrite()
        let page2 = try await secondReservation.value
        let output2 = try fixture.writeProcessedPage(2)
        await module.completePage(page2.reservation, outcome: .succeeded(outputURL: output2))
        try await module.seal(documentID, expectedPageCount: 2)
        await module.waitUntilIdle()

        #expect(FileManager.default.fileExists(atPath: fixture.finalOutput.path))
        #expect(await executor.requests().first?.arguments.contains(output1.path) == true)
    }

    @Test("All-blank input keeps the lowest-numbered original page")
    func allBlankKeepsFirstSourcePage() async throws {
        let fixture = try StreamingDocumentFixture(name: "all-blank")
        defer { fixture.remove() }
        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "0\n")),
            .result(ProcessResult(exitStatus: 0, standardOutput: "0\n")),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let module = StreamingOCRDocumentModule(documentExecutor: executor)
        let documentID = await module.begin(fixture.request(removeBlankPages: true))
        let page2 = try await fixture.reservePage(2, data: Data("second source".utf8), in: module, documentID: documentID)
        let page1Data = Data("first source".utf8)
        let page1 = try await fixture.reservePage(1, data: page1Data, in: module, documentID: documentID)
        let output2 = try fixture.writeProcessedPage(2, data: Data("blank two".utf8))
        let output1 = try fixture.writeProcessedPage(1, data: Data("blank one".utf8))
        await module.completePage(page2.reservation, outcome: .succeeded(outputURL: output2))
        await module.completePage(page1.reservation, outcome: .succeeded(outputURL: output1))

        try await module.seal(documentID, expectedPageCount: 2)
        await module.waitUntilIdle()

        #expect(try Data(contentsOf: fixture.finalOutput) == page1Data)
        #expect(await executor.requests().map(\.executable) == [
            "qpdf", "qpdf", "set-pdf-creator",
        ])
    }

    @Test("Finalization failure publishes the OCR-only raw fallback")
    func finalizationFailurePublishesFallback() async throws {
        let fixture = try StreamingDocumentFixture(name: "finalization-failure")
        defer { fixture.remove() }
        let raw = fixture.workDirectory.appendingPathComponent("raw.pdf")
        let fallback = fixture.root.appendingPathComponent("scan.pdf")
        try Data("raw fallback".utf8).write(to: raw)
        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 2, standardError: "merge failed")),
        ])
        let module = StreamingOCRDocumentModule(documentExecutor: executor)
        let documentID = await module.begin(fixture.request(
            failurePolicy: .publishRawOnFailure(source: raw, destination: fallback)
        ))
        let page = try await fixture.reservePage(1, in: module, documentID: documentID)
        let output = try fixture.writeProcessedPage(1)
        await module.completePage(page.reservation, outcome: .succeeded(outputURL: output))

        try await module.seal(documentID, expectedPageCount: 1)
        await module.waitUntilIdle()

        let state = await module.state
        #expect(state.latestCompletion?.status == "failed")
        #expect(state.latestCompletion?.output == fallback.path)
        #expect(FileManager.default.fileExists(atPath: fallback.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.finalOutput.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.workDirectory.path))
    }

    @Test("Fallback publication failure retains the private workspace")
    func fallbackPublicationFailureRetainsWorkspace() async throws {
        let fixture = try StreamingDocumentFixture(name: "fallback-failure")
        defer { fixture.remove() }
        let raw = fixture.workDirectory.appendingPathComponent("raw.pdf")
        let fallback = fixture.root.appendingPathComponent("scan.pdf")
        try Data("raw retained".utf8).write(to: raw)
        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 2, standardError: "merge failed")),
        ])
        let fileSystem = RejectingNativeScanFileSystem(rejectedDestination: fallback)
        let module = StreamingOCRDocumentModule(
            documentExecutor: executor,
            fileSystem: fileSystem
        )
        let documentID = await module.begin(fixture.request(
            failurePolicy: .publishRawOnFailure(source: raw, destination: fallback)
        ))
        let page = try await fixture.reservePage(1, in: module, documentID: documentID)
        let output = try fixture.writeProcessedPage(1)
        await module.completePage(page.reservation, outcome: .succeeded(outputURL: output))

        try await module.seal(documentID, expectedPageCount: 1)
        await module.waitUntilIdle()

        let completion = await module.state.latestCompletion
        #expect(completion?.status == "failed")
        #expect(completion?.error.contains(fixture.workDirectory.path) == true)
        #expect(FileManager.default.fileExists(atPath: raw.path))
        #expect(FileManager.default.fileExists(atPath: fixture.workDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: fallback.path))
    }

    @Test("Cancellation invalidates a suspended finalizer and ignores late completion")
    func cancellationPreventsStalePublication() async throws {
        let fixture = try StreamingDocumentFixture(name: "cancel-finalizer")
        defer { fixture.remove() }
        let raw = fixture.workDirectory.appendingPathComponent("raw.pdf")
        let fallback = fixture.root.appendingPathComponent("scan.pdf")
        try Data("must not publish".utf8).write(to: raw)
        let staged = Data("%PDF-1.4\nlate staged result\n".utf8)
        let executor = FakeProcessExecutor(stubs: [
            .suspendedIgnoringCancellationMaterializeLastArgument(
                staged,
                ProcessResult(exitStatus: 0)
            ),
        ])
        let module = StreamingOCRDocumentModule(documentExecutor: executor)
        let documentID = await module.begin(fixture.request(
            failurePolicy: .publishRawOnFailure(source: raw, destination: fallback)
        ))
        let page = try await fixture.reservePage(1, in: module, documentID: documentID)
        let output = try fixture.writeProcessedPage(1)
        await module.completePage(page.reservation, outcome: .succeeded(outputURL: output))
        try await module.seal(documentID, expectedPageCount: 1)
        await executor.waitForRequestCount(1)

        let handle = try #require(await module.invalidate(documentID, reason: .cancelled))
        let cancellation = Task { await module.finishCancellation(handle) }
        await executor.waitForIgnoredCancellationCount(1)
        await executor.resumeNextSuspendedExecution()
        let result = await cancellation.value
        await module.completePage(page.reservation, outcome: .succeeded(outputURL: output))

        #expect(result.workspaceRemoved)
        #expect(!FileManager.default.fileExists(atPath: fixture.finalOutput.path))
        #expect(!FileManager.default.fileExists(atPath: fallback.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.workDirectory.path))
        #expect(await module.state.latestCompletion?.status == "cancelled")
    }

    @Test("Imported PDF pages are yielded before the complete source is split")
    func importedPDFDispatchesPagesImmediately() async throws {
        let fixture = try StreamingDocumentFixture(name: "import-yield")
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.workDirectory)
        let source = fixture.root.appendingPathComponent("import.pdf")
        try Data("%PDF-1.4\nsource\n".utf8).write(to: source)
        let page = Data("%PDF-1.4\npage\n".utf8)
        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "2\n")),
            .materializeLastArgument(page, ProcessResult(exitStatus: 0)),
            .suspendedMaterializeLastArgument(page, ProcessResult(exitStatus: 0)),
        ])
        let recorder = PageWorkRecorder()
        let module = StreamingOCRDocumentModule(documentExecutor: executor)
        let preparation = Task {
            try await module.prepareImportedPDF(
                fixture.importRequest(source: source),
                yieldPage: { work in await recorder.append(work) },
                cancelScheduledPages: { _ in }
            )
        }

        await executor.waitForRequestCount(3)
        #expect(await recorder.pageNumbers == [1])
        await executor.resumeNextSuspendedExecution()
        #expect(try await preparation.value == 2)
        #expect(await recorder.pageNumbers == [1, 2])
        let documentID = try #require(await recorder.firstDocumentID)
        let handle = try #require(await module.invalidate(documentID, reason: .cancelled))
        _ = await module.finishCancellation(handle)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("Wi-Fi and imported documents share ordered finalization semantics")
    func wifiAndImportedFlowParity() async throws {
        let wifi = try StreamingDocumentFixture(name: "wifi-parity")
        let imported = try StreamingDocumentFixture(name: "import-parity")
        defer {
            wifi.remove()
            imported.remove()
        }
        let pdf = Data("%PDF-1.4\nparity\n".utf8)
        let wifiExecutor = FakeProcessExecutor(stubs: [
            .materializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let wifiModule = StreamingOCRDocumentModule(documentExecutor: wifiExecutor)
        let wifiID = await wifiModule.begin(wifi.request())
        let wifiPage = try await wifi.reservePage(1, in: wifiModule, documentID: wifiID)
        let wifiOutput = try wifi.writeProcessedPage(1)
        await wifiModule.completePage(
            wifiPage.reservation,
            outcome: .succeeded(outputURL: wifiOutput)
        )
        try await wifiModule.seal(wifiID, expectedPageCount: 1)
        await wifiModule.waitUntilIdle()

        try FileManager.default.removeItem(at: imported.workDirectory)
        let source = imported.root.appendingPathComponent("source.pdf")
        try Data("%PDF-1.4\nimport source\n".utf8).write(to: source)
        let importedExecutor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "1\n")),
            .materializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .materializeLastArgument(pdf, ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let importedModule = StreamingOCRDocumentModule(documentExecutor: importedExecutor)
        _ = try await importedModule.prepareImportedPDF(
            imported.importRequest(source: source),
            yieldPage: { work in
                let output = URL(fileURLWithPath: OCRInputPath.outputPath(
                    for: work.reservation.inputURL.path
                )!)
                try pdf.write(to: output)
                await importedModule.completePage(
                    work.reservation,
                    outcome: .succeeded(outputURL: output)
                )
            },
            cancelScheduledPages: { _ in }
        )
        await importedModule.waitUntilIdle()

        #expect(await wifiExecutor.requests().map(\.executable) == [
            "qpdf", "set-pdf-creator",
        ])
        #expect(await importedExecutor.requests().suffix(2).map(\.executable) == [
            "qpdf", "set-pdf-creator",
        ])
        #expect(try Data(contentsOf: wifi.finalOutput) == pdf)
        #expect(try Data(contentsOf: imported.finalOutput) == pdf)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}

private struct StreamingDocumentFixture: Sendable {
    let root: URL
    let workDirectory: URL
    let finalOutput: URL

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "streaming-document-module-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        workDirectory = root.appendingPathComponent(".scan-work.test", isDirectory: true)
        finalOutput = root.appendingPathComponent("scan.ocr.pdf", isDirectory: false)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    func request(
        removeBlankPages: Bool = false,
        failurePolicy: StreamingOCRFailurePolicy = .sourceAlreadyPublished
    ) -> StreamingOCRDocumentRequest {
        StreamingOCRDocumentRequest(
            documentName: "scan.pdf",
            finalOutputURL: finalOutput,
            workDirectory: workDirectory,
            environment: ["SCAN_LANGUAGE": "deu+eng"],
            removeBlankPages: removeBlankPages,
            cropPages: false,
            failurePolicy: failurePolicy
        )
    }

    func importRequest(source: URL) -> ImportedPDFOCRRequest {
        ImportedPDFOCRRequest(
            sourcePath: source.path,
            documentName: source.lastPathComponent,
            finalOutputPath: finalOutput.path,
            workDirectory: workDirectory,
            environment: ["SCAN_LANGUAGE": "deu+eng"],
            removeBlankPages: false,
            cropPages: false
        )
    }

    func reservePage(
        _ pageNumber: Int,
        data: Data = Data("%PDF-1.4\nsource page\n".utf8),
        in module: StreamingOCRDocumentModule,
        documentID: StreamingOCRDocumentID
    ) async throws -> StreamingOCRPageWork {
        let input = workDirectory.appendingPathComponent(
            String(format: "page-%04d.pdf", pageNumber)
        )
        try data.write(to: input)
        return try await module.reservePreparedPDFPage(
            documentID: documentID,
            pageNumber: pageNumber,
            inputURL: input
        )
    }

    func writeProcessedPage(
        _ pageNumber: Int,
        data: Data = Data("%PDF-1.4\nprocessed page\n".utf8)
    ) throws -> URL {
        let output = workDirectory.appendingPathComponent(
            String(format: "page-%04d.ocr.pdf", pageNumber)
        )
        try data.write(to: output)
        return output
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor PageWorkRecorder {
    private var works: [StreamingOCRPageWork] = []

    var pageNumbers: [Int] { works.map(\.reservation.pageNumber) }
    var firstDocumentID: StreamingOCRDocumentID? { works.first?.reservation.documentID }

    func append(_ work: StreamingOCRPageWork) {
        works.append(work)
    }
}

private actor SecondWriteSuspendingPageWriter: StreamingPagePDFWriting {
    private var writeCount = 0
    private var suspended = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func write(pages: [Data], to outputURL: URL) async throws {
        try pages[0].write(to: outputURL)
        writeCount += 1
        guard writeCount == 2 else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            suspended = true
            let waiters = self.waiters
            self.waiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilSecondWriteIsSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resumeSecondWrite() {
        continuation?.resume()
        continuation = nil
        suspended = false
    }
}

private struct RejectingNativeScanFileSystem: NativeScanFileSystem, Sendable {
    let rejectedDestination: URL
    private let base = FoundationNativeScanFileSystem()

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try base.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }

    func removeItemIfPresent(at url: URL) throws {
        try base.removeItemIfPresent(at: url)
    }

    func regularFileExists(at url: URL) -> Bool {
        base.regularFileExists(at: url)
    }

    func regularFiles(
        in directory: URL,
        withPrefix prefix: String,
        pathExtension: String
    ) throws -> [URL] {
        try base.regularFiles(in: directory, withPrefix: prefix, pathExtension: pathExtension)
    }

    func placeFileExclusively(at source: URL, destination: URL) throws {
        guard destination != rejectedDestination else {
            throw NativeScanFileSystemError.outputConflict(destination.path)
        }
        try base.placeFileExclusively(at: source, destination: destination)
    }
}
