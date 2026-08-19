import Foundation
import JLog

public protocol OCRWorkerRuntimeControlClient: Sendable {
    func register(
        _ registration: OCRWorkerRegistrationRequest
    ) async throws -> OCRWorkerRegistrationResponse

    func heartbeat(
        workerID: String,
        request: OCRWorkerHeartbeatRequest
    ) async throws -> OCRWorkerRegistrationResponse
}

public protocol OCRWorkerRuntimeJobClient: Sendable {
    func leaseNextJob(
        workerID: String,
        request: OCRWorkerJobPollRequest
    ) async throws -> OCRWorkerJobLease?
}

public protocol OCRWorkerRuntimeJobProcessing: Sendable {
    func process(
        lease: OCRWorkerJobLease,
        workerID: String,
        authenticationToken: String
    ) async throws
}

public protocol OCRWorkerRuntimeSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct TaskOCRWorkerRuntimeSleeper: OCRWorkerRuntimeSleeping {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public enum OCRWorkerRuntimeEvent: Equatable, Sendable {
    case availability(OCRWorkerAvailability)
    case connectionFailed(String)
    case jobStarted(jobID: String, attempt: Int)
    case jobCompleted(jobID: String)
    case jobFailed(jobID: String, message: String)
}

public struct OCRWorkerRuntimeEventHandler: Sendable {
    private let operation: @Sendable (OCRWorkerRuntimeEvent) async -> Void

    public init(_ operation: @escaping @Sendable (OCRWorkerRuntimeEvent) async -> Void) {
        self.operation = operation
    }

    public func handle(_ event: OCRWorkerRuntimeEvent) async {
        await operation(event)
    }

    public static let logging = OCRWorkerRuntimeEventHandler { event in
        switch event {
        case .availability(.pendingApproval):
            JLog.notice("Worker registered and is waiting for approval in scannerserver")
        case .availability(.online):
            JLog.notice("Worker is approved and online")
        case .availability(.busy):
            JLog.info("Worker is processing")
        case .availability(.paused):
            JLog.notice("Worker is paused in scannerserver")
        case .availability(.offline):
            JLog.warning("Worker is marked offline")
        case .availability(.disabled):
            JLog.notice("Worker is disabled in scannerserver")
        case .connectionFailed(let message):
            JLog.warning("OCR worker connection failed: \(message); retrying")
        case let .jobStarted(jobID, attempt):
            JLog.notice("Starting remote OCR job \(jobID), attempt \(attempt)")
        case .jobCompleted(let jobID):
            JLog.notice("Completed remote OCR job \(jobID)")
        case let .jobFailed(jobID, message):
            JLog.warning("Remote OCR job \(jobID) failed: \(message)")
        }
    }
}

public struct OCRWorkerRuntimeConfiguration: Equatable, Sendable {
    public let maximumConcurrentJobs: Int
    public let leaseWaitSeconds: Int
    public let reconnectDelay: Duration

    public init(
        maximumConcurrentJobs: Int,
        leaseWaitSeconds: Int = 20,
        reconnectDelay: Duration = .seconds(5)
    ) {
        self.maximumConcurrentJobs = max(1, maximumConcurrentJobs)
        self.leaseWaitSeconds = max(1, leaseWaitSeconds)
        self.reconnectDelay = reconnectDelay
    }
}

public enum OCRWorkerRuntimeError: Error, LocalizedError, Sendable {
    case noLongerAvailable

    public var errorDescription: String? {
        "Worker is no longer enabled for job dispatch."
    }
}

/// Owns registration, approval waiting, heartbeat supervision, leasing, and job task lifetimes.
public struct OCRWorkerRuntimeModule: Sendable {
    private enum JobEvent: Sendable {
        case lease(OCRWorkerJobLease?)
        case jobFinished
    }

    private let registration: OCRWorkerRegistrationRequest
    private let configuration: OCRWorkerRuntimeConfiguration
    private let controlClient: any OCRWorkerRuntimeControlClient
    private let jobClient: any OCRWorkerRuntimeJobClient
    private let processor: any OCRWorkerRuntimeJobProcessing
    private let sleeper: any OCRWorkerRuntimeSleeping
    private let events: OCRWorkerRuntimeEventHandler

    public init(
        registration: OCRWorkerRegistrationRequest,
        configuration: OCRWorkerRuntimeConfiguration,
        controlClient: any OCRWorkerRuntimeControlClient,
        jobClient: any OCRWorkerRuntimeJobClient,
        processor: any OCRWorkerRuntimeJobProcessing,
        sleeper: any OCRWorkerRuntimeSleeping = TaskOCRWorkerRuntimeSleeper(),
        events: OCRWorkerRuntimeEventHandler = .logging
    ) {
        self.registration = registration
        self.configuration = configuration
        self.controlClient = controlClient
        self.jobClient = jobClient
        self.processor = processor
        self.sleeper = sleeper
        self.events = events
    }

    public func run() async throws {
        while !Task.isCancelled {
            do {
                let state = try await registerAndWaitUntilApproved()
                guard state.availability == .online || state.availability == .busy else {
                    throw OCRWorkerRuntimeError.noLongerAvailable
                }
                try await runApprovedSession(
                    heartbeatIntervalSeconds: state.heartbeatIntervalSeconds
                )
            } catch is CancellationError {
                return
            } catch {
                await events.handle(.connectionFailed(error.localizedDescription))
                do {
                    try await sleeper.sleep(for: configuration.reconnectDelay)
                } catch is CancellationError {
                    return
                }
            }
        }
    }

    func registerAndWaitUntilApproved() async throws -> OCRWorkerRegistrationResponse {
        var state = try await controlClient.register(registration)
        await events.handle(.availability(state.availability))
        while state.availability == .pendingApproval || state.availability == .disabled {
            try await sleeper.sleep(for: .seconds(state.heartbeatIntervalSeconds))
            state = try await controlClient.heartbeat(
                workerID: registration.workerID,
                request: heartbeat(runningJobs: 0)
            )
            await events.handle(.availability(state.availability))
        }
        return state
    }

    func runApprovedSession(heartbeatIntervalSeconds: Int) async throws {
        let activity = OCRWorkerActivity()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    try await sleeper.sleep(for: .seconds(heartbeatIntervalSeconds))
                    let state = try await controlClient.heartbeat(
                        workerID: registration.workerID,
                        request: heartbeat(runningJobs: await activity.count)
                    )
                    guard state.availability == .online || state.availability == .busy else {
                        throw OCRWorkerRuntimeError.noLongerAvailable
                    }
                }
            }
            group.addTask {
                try await runJobDispatcher(activity: activity)
            }

            defer { group.cancelAll() }
            guard let _ = try await group.next() else {
                throw OCRWorkerRuntimeError.noLongerAvailable
            }
            throw OCRWorkerRuntimeError.noLongerAvailable
        }
    }

    func runJobDispatcher(activity: OCRWorkerActivity = OCRWorkerActivity()) async throws {
        try await withThrowingTaskGroup(of: JobEvent.self) { group in
            var activeJobs = 0
            var leaseRequestIsRunning = false
            defer { group.cancelAll() }

            while !Task.isCancelled {
                if activeJobs < configuration.maximumConcurrentJobs, !leaseRequestIsRunning {
                    leaseRequestIsRunning = true
                    group.addTask {
                        .lease(try await jobClient.leaseNextJob(
                            workerID: registration.workerID,
                            request: OCRWorkerJobPollRequest(
                                authenticationToken: registration.authenticationToken,
                                waitSeconds: configuration.leaseWaitSeconds
                            )
                        ))
                    }
                }

                guard let event = try await group.next() else {
                    throw OCRWorkerRuntimeError.noLongerAvailable
                }
                switch event {
                case .lease(nil):
                    leaseRequestIsRunning = false
                case .lease(let lease?):
                    leaseRequestIsRunning = false
                    activeJobs += 1
                    await activity.beginJob()
                    group.addTask {
                        await process(lease: lease, activity: activity)
                        return .jobFinished
                    }
                case .jobFinished:
                    activeJobs = max(0, activeJobs - 1)
                }
            }
            throw CancellationError()
        }
    }

    private func process(lease: OCRWorkerJobLease, activity: OCRWorkerActivity) async {
        await events.handle(.jobStarted(jobID: lease.manifest.jobID, attempt: lease.attempt))
        do {
            try await processor.process(
                lease: lease,
                workerID: registration.workerID,
                authenticationToken: registration.authenticationToken
            )
            await events.handle(.jobCompleted(jobID: lease.manifest.jobID))
        } catch is CancellationError {
            // Approved-session shutdown cancels every page and its nested process.
        } catch {
            await events.handle(.jobFailed(
                jobID: lease.manifest.jobID,
                message: error.localizedDescription
            ))
        }
        await activity.finishJob()
    }

    private func heartbeat(runningJobs: Int) -> OCRWorkerHeartbeatRequest {
        OCRWorkerHeartbeatRequest(
            authenticationToken: registration.authenticationToken,
            runningJobs: runningJobs
        )
    }
}

actor OCRWorkerActivity {
    private var runningJobs = 0

    init() {}

    func beginJob() {
        runningJobs += 1
    }

    func finishJob() {
        runningJobs = max(0, runningJobs - 1)
    }

    var count: Int { runningJobs }
}

extension OCRWorkerHTTPClient: OCRWorkerRuntimeControlClient, OCRWorkerRuntimeJobClient {}
extension OCRWorkerJobProcessor: OCRWorkerRuntimeJobProcessing {}
