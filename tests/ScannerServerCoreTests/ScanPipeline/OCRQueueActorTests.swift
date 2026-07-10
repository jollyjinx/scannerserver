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
    }
}

private func ocrArguments(input: String, output: String) -> [String] {
    [
        "--language", "deu+eng",
        "--rotate-pages",
        "--rotate-pages-threshold", "2.0",
        "--deskew",
        "--optimize", "1",
        input,
        output,
    ]
}
