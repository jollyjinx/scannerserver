import Foundation
import Testing
@testable import ScannerServerCore

@Suite("OCR worker runtime module")
struct OCRWorkerRuntimeModuleTests {
    @Test("Registration heartbeats while approval or enablement is pending")
    func approvalWaiting() async throws {
        let control = TestRuntimeControlClient(
            register: [.success(response(.pendingApproval, interval: 3))],
            heartbeats: [
                .success(response(.disabled, interval: 4)),
                .success(response(.online, interval: 5)),
            ]
        )
        let sleeper = TestRuntimeSleeper()
        let events = TestRuntimeEventRecorder()
        let module = makeModule(control: control, sleeper: sleeper, events: events)

        let approved = try await module.registerAndWaitUntilApproved()

        #expect(approved.availability == .online)
        #expect(await sleeper.durations == [.seconds(3), .seconds(4)])
        #expect(await control.heartbeatRequests.map(\.runningJobs) == [0, 0])
        #expect(await events.values == [
            .availability(.pendingApproval),
            .availability(.disabled),
            .availability(.online),
        ])
    }

    @Test("Heartbeat failure ends the approved session and cancels its lease poll")
    func heartbeatFailure() async {
        let control = TestRuntimeControlClient(heartbeats: [.failure(.heartbeatFailed)])
        let jobs = TestRuntimeJobClient()
        let module = makeModule(control: control, jobs: jobs)

        await #expect(throws: TestRuntimeError.heartbeatFailed) {
            try await module.runApprovedSession(heartbeatIntervalSeconds: 1)
        }
        #expect(await control.heartbeatRequests.count == 1)
        #expect(await jobs.cancellationCount == 1)
    }

    @Test("Connection failures use the configured reconnect delay")
    func reconnectDelay() async throws {
        let control = TestRuntimeControlClient(register: [.failure(.registrationFailed)])
        let sleeper = TestRuntimeSleeper(cancelOnCall: 1)
        let events = TestRuntimeEventRecorder()
        let module = makeModule(
            control: control,
            sleeper: sleeper,
            events: events,
            reconnectDelay: .seconds(7)
        )

        try await module.run()

        #expect(await sleeper.durations == [.seconds(7)])
        #expect(await events.values == [
            .connectionFailed(TestRuntimeError.registrationFailed.localizedDescription),
        ])
    }

    @Test("Dispatcher fills every advertised concurrent job slot")
    func dispatcherCapacity() async {
        let jobs = TestRuntimeJobClient(leases: [lease(1), lease(2), lease(3)])
        let processor = TestRuntimeProcessor()
        let activity = OCRWorkerActivity()
        let module = makeModule(jobs: jobs, processor: processor, maximumConcurrentJobs: 3)
        let task = Task { try await module.runJobDispatcher(activity: activity) }

        await processor.waitForStartedCount(3)

        #expect(await jobs.callCount == 3)
        #expect(await processor.runningCount == 3)
        #expect(await activity.count == 3)

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await processor.cancellationCount == 3)
        #expect(await activity.count == 0)
    }

    @Test("Dispatcher serializes long-poll lease requests")
    func leasePollSerialization() async {
        let jobs = TestRuntimeJobClient()
        let module = makeModule(jobs: jobs, maximumConcurrentJobs: 4)
        let task = Task { try await module.runJobDispatcher() }

        for expectedCallCount in 1...3 {
            await jobs.waitForCallCount(expectedCallCount)
            #expect(await jobs.maximumSimultaneousRequests == 1)
            await jobs.returnNextLease(nil)
        }

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await jobs.maximumSimultaneousRequests == 1)
    }

    @Test("Cancelling the dispatcher cancels every in-flight job")
    func cancellation() async {
        let jobs = TestRuntimeJobClient(leases: [lease(1)])
        let processor = TestRuntimeProcessor()
        let activity = OCRWorkerActivity()
        let events = TestRuntimeEventRecorder()
        let module = makeModule(
            jobs: jobs,
            processor: processor,
            events: events,
            maximumConcurrentJobs: 1
        )
        let task = Task { try await module.runJobDispatcher(activity: activity) }
        await processor.waitForStartedCount(1)

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(await processor.cancellationCount == 1)
        #expect(await activity.count == 0)
        #expect(await events.values == [.jobStarted(jobID: "job-1", attempt: 1)])
    }

    @Test("A failed job is logged and does not stop dispatch")
    func failedJob() async {
        let jobs = TestRuntimeJobClient(leases: [lease(1)])
        let processor = TestRuntimeProcessor(failingJobIDs: ["job-1"])
        let activity = OCRWorkerActivity()
        let events = TestRuntimeEventRecorder()
        let module = makeModule(
            jobs: jobs,
            processor: processor,
            events: events,
            maximumConcurrentJobs: 1
        )
        let task = Task { try await module.runJobDispatcher(activity: activity) }

        await events.waitForCount(2)
        await jobs.waitForCallCount(2)

        #expect(await events.values == [
            .jobStarted(jobID: "job-1", attempt: 1),
            .jobFailed(
                jobID: "job-1",
                message: TestRuntimeError.jobFailed.localizedDescription
            ),
        ])
        #expect(await activity.count == 0)

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private func makeModule(
    control: TestRuntimeControlClient = TestRuntimeControlClient(),
    jobs: TestRuntimeJobClient = TestRuntimeJobClient(),
    processor: TestRuntimeProcessor = TestRuntimeProcessor(),
    sleeper: TestRuntimeSleeper = TestRuntimeSleeper(),
    events: TestRuntimeEventRecorder = TestRuntimeEventRecorder(),
    maximumConcurrentJobs: Int = 1,
    reconnectDelay: Duration = .seconds(5)
) -> OCRWorkerRuntimeModule {
    OCRWorkerRuntimeModule(
        registration: registration,
        configuration: OCRWorkerRuntimeConfiguration(
            maximumConcurrentJobs: maximumConcurrentJobs,
            reconnectDelay: reconnectDelay
        ),
        controlClient: control,
        jobClient: jobs,
        processor: processor,
        sleeper: sleeper,
        events: OCRWorkerRuntimeEventHandler { event in
            await events.record(event)
        }
    )
}

private let registration = OCRWorkerRegistrationRequest(
    workerID: "worker-1",
    authenticationToken: "authentication-token",
    displayName: "Test worker",
    hostname: "test-host",
    workerVersion: "test",
    architecture: "test",
    cpuCount: 4,
    maxConcurrentJobs: 4,
    ocrLanguages: ["eng"]
)

private func response(
    _ availability: OCRWorkerAvailability,
    interval: Int = 1
) -> OCRWorkerRegistrationResponse {
    OCRWorkerRegistrationResponse(
        workerID: registration.workerID,
        availability: availability,
        heartbeatIntervalSeconds: interval
    )
}

private func lease(_ number: Int) -> OCRWorkerJobLease {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return OCRWorkerJobLease(
        manifest: OCRWorkerJobManifest(
            jobID: "job-\(number)",
            sourcePath: "/scans/source-\(number).pdf",
            outputPath: "/scans/source-\(number).ocr.pdf",
            sourceByteCount: 1,
            sourceSHA256: String(repeating: "a", count: 64),
            ocrLanguages: ["eng"],
            ocrEnabled: true,
            removeBlankPages: false,
            cropPages: false,
            createdAt: now
        ),
        workerID: registration.workerID,
        leaseToken: "lease-\(number)",
        leasedAt: now,
        expiresAt: now.addingTimeInterval(60),
        attempt: number
    )
}

private enum TestRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case registrationFailed
    case heartbeatFailed
    case missingStub
    case jobFailed

    var errorDescription: String? {
        switch self {
        case .registrationFailed: "registration failed"
        case .heartbeatFailed: "heartbeat failed"
        case .missingStub: "missing test stub"
        case .jobFailed: "job exploded"
        }
    }
}

private actor TestRuntimeControlClient: OCRWorkerRuntimeControlClient {
    private var registerResults: [Result<OCRWorkerRegistrationResponse, TestRuntimeError>]
    private var heartbeatResults: [Result<OCRWorkerRegistrationResponse, TestRuntimeError>]
    private(set) var heartbeatRequests: [OCRWorkerHeartbeatRequest] = []

    init(
        register: [Result<OCRWorkerRegistrationResponse, TestRuntimeError>] = [],
        heartbeats: [Result<OCRWorkerRegistrationResponse, TestRuntimeError>] = []
    ) {
        registerResults = register
        heartbeatResults = heartbeats
    }

    func register(
        _ registration: OCRWorkerRegistrationRequest
    ) async throws -> OCRWorkerRegistrationResponse {
        guard !registerResults.isEmpty else { throw TestRuntimeError.missingStub }
        return try registerResults.removeFirst().get()
    }

    func heartbeat(
        workerID: String,
        request: OCRWorkerHeartbeatRequest
    ) async throws -> OCRWorkerRegistrationResponse {
        heartbeatRequests.append(request)
        guard !heartbeatResults.isEmpty else { throw TestRuntimeError.missingStub }
        return try heartbeatResults.removeFirst().get()
    }
}

private actor TestRuntimeSleeper: OCRWorkerRuntimeSleeping {
    private(set) var durations: [Duration] = []
    private let cancelOnCall: Int?

    init(cancelOnCall: Int? = nil) {
        self.cancelOnCall = cancelOnCall
    }

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        if durations.count == cancelOnCall { throw CancellationError() }
    }
}

private actor TestRuntimeEventRecorder {
    private struct Waiter: Sendable {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var values: [OCRWorkerRuntimeEvent] = []
    private var waiters: [Waiter] = []

    func record(_ event: OCRWorkerRuntimeEvent) {
        values.append(event)
        resumeWaiters()
    }

    func waitForCount(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(count: count, continuation: continuation))
        }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { values.count >= $0.count }
        waiters.removeAll { values.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
}

private actor TestRuntimeJobClient: OCRWorkerRuntimeJobClient {
    private struct Waiter: Sendable {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var leases: [OCRWorkerJobLease]
    private var pending: [CheckedContinuation<OCRWorkerJobLease?, any Error>] = []
    private var callWaiters: [Waiter] = []
    private(set) var callCount = 0
    private(set) var cancellationCount = 0
    private var simultaneousRequests = 0
    private(set) var maximumSimultaneousRequests = 0

    init(leases: [OCRWorkerJobLease] = []) {
        self.leases = leases
    }

    func leaseNextJob(
        workerID: String,
        request: OCRWorkerJobPollRequest
    ) async throws -> OCRWorkerJobLease? {
        callCount += 1
        simultaneousRequests += 1
        maximumSimultaneousRequests = max(maximumSimultaneousRequests, simultaneousRequests)
        resumeCallWaiters()
        if !leases.isEmpty {
            simultaneousRequests -= 1
            return leases.removeFirst()
        }

        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending.append(continuation)
                }
            } onCancel: {
                Task { await self.cancelNextLeaseRequest() }
            }
            simultaneousRequests -= 1
            return result
        } catch {
            simultaneousRequests -= 1
            throw error
        }
    }

    func waitForCallCount(_ count: Int) async {
        guard callCount < count else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(Waiter(count: count, continuation: continuation))
        }
    }

    func returnNextLease(_ lease: OCRWorkerJobLease?) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: lease)
    }

    private func cancelNextLeaseRequest() {
        guard !pending.isEmpty else { return }
        cancellationCount += 1
        pending.removeFirst().resume(throwing: CancellationError())
    }

    private func resumeCallWaiters() {
        let ready = callWaiters.filter { callCount >= $0.count }
        callWaiters.removeAll { callCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
}

private actor TestRuntimeProcessor: OCRWorkerRuntimeJobProcessing {
    private struct Waiter: Sendable {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let failingJobIDs: Set<String>
    private var startedWaiters: [Waiter] = []
    private(set) var startedJobIDs: [String] = []
    private(set) var runningCount = 0
    private(set) var cancellationCount = 0

    init(failingJobIDs: Set<String> = []) {
        self.failingJobIDs = failingJobIDs
    }

    func process(
        lease: OCRWorkerJobLease,
        workerID: String,
        authenticationToken: String
    ) async throws {
        startedJobIDs.append(lease.manifest.jobID)
        resumeStartedWaiters()
        if failingJobIDs.contains(lease.manifest.jobID) {
            throw TestRuntimeError.jobFailed
        }

        runningCount += 1
        do {
            try await Task.sleep(for: .seconds(3_600))
            runningCount -= 1
        } catch {
            runningCount -= 1
            cancellationCount += 1
            throw error
        }
    }

    func waitForStartedCount(_ count: Int) async {
        guard startedJobIDs.count < count else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(Waiter(count: count, continuation: continuation))
        }
    }

    private func resumeStartedWaiters() {
        let ready = startedWaiters.filter { startedJobIDs.count >= $0.count }
        startedWaiters.removeAll { startedJobIDs.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
}
