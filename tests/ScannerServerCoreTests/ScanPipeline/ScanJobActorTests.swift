import ScannerServerCore
import Testing

@Suite("Scan job actor")
struct ScanJobActorTests {
    @Test("A running scan rejects a second start")
    func singleFlight() async {
        let executor = FakeProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0, standardOutput: "/scans/scan.pdf\n")),
        ])
        let actor = ScanJobActor(executor: executor)
        let configuration = ScanPipelineConfiguration(environment: [:])

        #expect(await actor.start(configuration: configuration))
        await executor.waitForRequestCount(1)
        #expect(!(await actor.start(configuration: configuration)))
        #expect(await actor.state.status == "running")

        await executor.resumeNextSuspendedExecution()
        await actor.waitUntilIdle()
        let state = await actor.state
        #expect(state.status == "done")
        #expect(state.output == "/scans/scan.pdf")
        #expect(state.started != nil)
        #expect(state.finished != nil)
    }

    @Test("A nonzero scan exit records status, output, and error")
    func commandFailure() async {
        let executor = FakeProcessExecutor(stubs: [
            .result(ProcessResult(
                exitStatus: 64,
                standardOutput: "partial output\n",
                standardError: "scanner configuration missing\n"
            )),
        ])
        let actor = ScanJobActor(executor: executor)

        #expect(await actor.start(configuration: ScanPipelineConfiguration(environment: [:])))
        await actor.waitUntilIdle()
        let state = await actor.state
        #expect(state.status == "failed (64)")
        #expect(state.output == "partial output")
        #expect(state.error == "scanner configuration missing")
    }

    @Test("Executor failures are recorded")
    func executorFailure() async {
        let executor = FakeProcessExecutor(stubs: [.failure(.expectedFailure)])
        let actor = ScanJobActor(executor: executor)

        #expect(await actor.start(configuration: ScanPipelineConfiguration(environment: [:])))
        await actor.waitUntilIdle()
        #expect(await actor.state.status == "failed")
        #expect(!(await actor.state.error.isEmpty))
    }

    @Test("Cancellation finishes the active scan")
    func cancellation() async {
        let executor = FakeProcessExecutor(stubs: [
            .suspended(ProcessResult(exitStatus: 0)),
        ])
        let actor = ScanJobActor(executor: executor)

        #expect(await actor.start(configuration: ScanPipelineConfiguration(environment: [:])))
        await executor.waitForRequestCount(1)
        await actor.cancel()

        let state = await actor.state
        #expect(state.status == "cancelled")
        #expect(state.finished != nil)
    }
}
