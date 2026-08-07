import Foundation
import ScannerServerCore
import Testing

@Suite("OCR queue actor")
struct OCRQueueActorTests {
    @Test("Jobs execute in FIFO order on one worker")
    func fifo() async {
        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(exitStatus: 0, standardOutput: "/scans/one.ocr.pdf\n")),
            .result(ProcessResult(exitStatus: 0, standardOutput: "/scans/two.ocr.pdf\n")),
            .result(ProcessResult(exitStatus: 0, standardOutput: "/scans/three.ocr.pdf\n")),
        ])
        let queue = OCRQueueActor(executor: executor)

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
            workspaceSuffixProvider: { "test" }
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

    @Test("Invalid and conflicting paths fail without launching OCR")
    func invalidAndConflictingPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("scan.pdf")
        let output = root.appendingPathComponent("scan.ocr.pdf")
        try Data().write(to: output)
        let executor = FakeProcessExecutor(stubs: [])
        let queue = OCRQueueActor(executor: executor)

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
        let queue = OCRQueueActor(executor: executor)

        await queue.enqueue("/scans/one.pdf")
        await queue.enqueue("/scans/two.pdf")
        await queue.waitUntilIdle()

        #expect(await executor.requests().count == 2)
        #expect(await queue.state.status == "done")
        #expect(await queue.state.input == "/scans/two.pdf")
    }

    @Test("Cancellation stops the worker and clears queued jobs")
    func cancellation() async {
        let executor = FakeProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0)),
        ])
        let queue = OCRQueueActor(executor: executor)

        await queue.enqueue("/scans/one.pdf")
        await queue.enqueue("/scans/two.pdf")
        await executor.waitForRequestCount(1)
        await queue.cancelAll()

        #expect(await executor.requests().count == 1)
        #expect(await queue.state.status == "cancelled")
        #expect(await queue.state.queued == 0)
        #expect(await queue.state.recentJobs.first?.input == "/scans/one.pdf")
        #expect(await queue.state.recentJobs.first?.status == "cancelled")
    }

    @Test("Cancelling the active job preserves unrelated queued jobs")
    func targetedActiveCancellation() async {
        let executor = FakeProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0)),
            .result(ProcessResult(exitStatus: 0, standardOutput: "/scans/two.ocr.pdf\n")),
        ])
        let queue = OCRQueueActor(executor: executor)

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
        let queue = OCRQueueActor(executor: executor)

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
        input,
        output,
    ]
}
