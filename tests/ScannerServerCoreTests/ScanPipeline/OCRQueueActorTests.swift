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
        #expect(requests.map(\.executable) == ["ocr-scan", "ocr-scan", "ocr-scan"])
        #expect(requests.map(\.arguments) == [
            ["/scans/one.pdf"],
            ["/scans/two.pdf"],
            ["/scans/three.pdf"],
        ])

        let state = await queue.state
        #expect(state.status == "done")
        #expect(state.input == "/scans/three.pdf")
        #expect(state.output == "/scans/three.ocr.pdf")
        #expect(state.error.isEmpty)
        #expect(state.queued == 0)
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
