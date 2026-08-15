import Foundation
import ScannerServerCore
import Testing

@Suite("OCR worker job store")
struct OCRWorkerJobStoreTests {
    @Test("Jobs lease FIFO to workers with every required OCR language")
    func compatibleFIFOLeasing() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let store = OCRWorkerJobStore(leaseTokenProvider: { "lease-token" })
        _ = try await store.enqueue(testManifest(
            jobID: "first",
            languages: ["deu", "eng"],
            createdAt: start
        ))
        _ = try await store.enqueue(testManifest(
            jobID: "second",
            languages: ["eng"],
            createdAt: start.addingTimeInterval(1)
        ))

        let lease = try await store.leaseNext(
            workerID: "mac-studio",
            ocrLanguages: ["eng"],
            now: start.addingTimeInterval(2)
        )

        #expect(lease?.manifest.jobID == "second")
        #expect(lease?.leaseToken == "lease-token")
        #expect(lease?.attempt == 1)
        #expect(try await store.snapshot(jobID: "first").status == .queued)
    }

    @Test("Autocrop jobs lease only to workers that advertise crop support")
    func cropCapabilityLeasing() async throws {
        let store = OCRWorkerJobStore(leaseTokenProvider: { "lease-token" })
        _ = try await store.enqueue(testManifest(cropPages: true))

        #expect(try await store.leaseNext(
            workerID: "ocr-only",
            ocrLanguages: ["eng"]
        ) == nil)
        #expect(try await store.leaseNext(
            workerID: "ocr-and-crop",
            ocrLanguages: ["eng"],
            capabilities: [OCRWorkerCapability.cropPDFPages]
        )?.manifest.jobID == "job-1")
    }

    @Test("Only the lease owner can renew and complete a live lease")
    func authenticatedTransitions() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let store = OCRWorkerJobStore(
            leaseDurationSeconds: 30,
            leaseTokenProvider: { "secret-lease-token" }
        )
        _ = try await store.enqueue(testManifest(createdAt: start))
        let lease = try #require(try await store.leaseNext(
            workerID: "mac-studio",
            ocrLanguages: ["eng"],
            now: start
        ))

        await #expect(throws: OCRWorkerJobStoreError.invalidLease) {
            _ = try await store.renew(
                jobID: lease.manifest.jobID,
                workerID: "impostor",
                leaseToken: lease.leaseToken,
                now: start.addingTimeInterval(5)
            )
        }

        let renewed = try await store.renew(
            jobID: lease.manifest.jobID,
            workerID: lease.workerID,
            leaseToken: lease.leaseToken,
            now: start.addingTimeInterval(20)
        )
        #expect(renewed.expiresAt == start.addingTimeInterval(50))

        let completed = try await store.succeed(
            jobID: lease.manifest.jobID,
            workerID: lease.workerID,
            leaseToken: lease.leaseToken,
            result: OCRWorkerJobResult(
                outputByteCount: 2_048,
                outputSHA256: String(repeating: "b", count: 64)
            ),
            now: start.addingTimeInterval(25)
        )
        #expect(completed.status == .succeeded)
        #expect(completed.leasedWorkerID == nil)
        #expect(completed.result?.outputByteCount == 2_048)
    }

    @Test("Expired leases return to the queue and reject stale completion")
    func leaseExpiry() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let tokens = TokenSequence(["first-token", "second-token"])
        let store = OCRWorkerJobStore(
            leaseDurationSeconds: 10,
            leaseTokenProvider: { tokens.next() }
        )
        _ = try await store.enqueue(testManifest(createdAt: start))
        let first = try #require(try await store.leaseNext(
            workerID: "worker-1",
            ocrLanguages: ["eng"],
            now: start
        ))

        await #expect(throws: OCRWorkerJobStoreError.leaseExpired) {
            _ = try await store.fail(
                jobID: first.manifest.jobID,
                workerID: first.workerID,
                leaseToken: first.leaseToken,
                failure: "late",
                now: start.addingTimeInterval(10)
            )
        }

        let second = try #require(try await store.leaseNext(
            workerID: "worker-2",
            ocrLanguages: ["eng"],
            now: start.addingTimeInterval(11)
        ))
        #expect(second.attempt == 2)
        #expect(second.leaseToken == "second-token")
    }

    @Test("Queued and leased jobs can be cancelled but terminal jobs cannot")
    func cancellation() async throws {
        let store = OCRWorkerJobStore(leaseTokenProvider: { "token" })
        _ = try await store.enqueue(testManifest())
        let cancelled = try await store.cancel(jobID: "job-1")
        #expect(cancelled.status == .cancelled)

        await #expect(throws: OCRWorkerJobStoreError.invalidTransition(from: .cancelled, to: .cancelled)) {
            _ = try await store.cancel(jobID: "job-1")
        }

        _ = try await store.enqueue(testManifest(jobID: "job-2"))
        _ = try await store.leaseNext(workerID: "worker", ocrLanguages: ["eng"])
        let cancelledLease = try await store.cancel(jobID: "job-2")
        #expect(cancelledLease.status == .cancelled)
        #expect(cancelledLease.leasedWorkerID == nil)
        #expect(try await store.leaseNext(workerID: "worker", ocrLanguages: ["eng"]) == nil)
    }

    @Test("Pausing a worker returns only its leases to the queue and rejects stale tokens")
    func workerLeaseRequeue() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let tokens = TokenSequence(["worker-one-token", "worker-two-token", "new-token"])
        let store = OCRWorkerJobStore(leaseTokenProvider: { tokens.next() })
        _ = try await store.enqueue(testManifest(jobID: "job-1", createdAt: start))
        _ = try await store.enqueue(testManifest(
            jobID: "job-2",
            createdAt: start.addingTimeInterval(1)
        ))
        let first = try #require(try await store.leaseNext(
            workerID: "worker-1",
            ocrLanguages: ["eng"],
            now: start.addingTimeInterval(2)
        ))
        let second = try #require(try await store.leaseNext(
            workerID: "worker-2",
            ocrLanguages: ["eng"],
            now: start.addingTimeInterval(2)
        ))

        #expect(try await store.requeueLeases(
            workerID: "worker-1",
            now: start.addingTimeInterval(3)
        ) == 1)
        #expect(try await store.snapshot(jobID: first.manifest.jobID).status == .queued)
        #expect(try await store.snapshot(jobID: second.manifest.jobID).leasedWorkerID == "worker-2")
        await #expect(throws: OCRWorkerJobStoreError.invalidTransition(from: .queued, to: .leased)) {
            _ = try await store.renew(
                jobID: first.manifest.jobID,
                workerID: first.workerID,
                leaseToken: first.leaseToken,
                now: start.addingTimeInterval(4)
            )
        }
        #expect(try await store.leaseNext(
            workerID: "worker-3",
            ocrLanguages: ["eng"],
            now: start.addingTimeInterval(4)
        )?.manifest.jobID == "job-1")
    }

    @Test("Workers can report a terminal failure without exposing the lease token")
    func terminalFailure() async throws {
        let store = OCRWorkerJobStore(leaseTokenProvider: { "private-token" })
        _ = try await store.enqueue(testManifest())
        let lease = try #require(try await store.leaseNext(
            workerID: "worker",
            ocrLanguages: ["eng"]
        ))

        let failed = try await store.fail(
            jobID: lease.manifest.jobID,
            workerID: lease.workerID,
            leaseToken: lease.leaseToken,
            failure: "container exited 1"
        )

        #expect(failed.status == .failed)
        #expect(failed.failure == "container exited 1")
        #expect(failed.leasedWorkerID == nil)
    }

    @Test("Atomic leasing enforces each worker's concurrent job limit")
    func workerCapacity() async throws {
        let store = OCRWorkerJobStore(leaseTokenProvider: { UUID().uuidString })
        _ = try await store.enqueue(testManifest(jobID: "job-1"))
        _ = try await store.enqueue(testManifest(jobID: "job-2"))

        let first = try #require(try await store.leaseNext(
            workerID: "worker",
            ocrLanguages: ["eng"],
            maximumActiveLeases: 1
        ))
        #expect(try await store.leaseNext(
            workerID: "worker",
            ocrLanguages: ["eng"],
            maximumActiveLeases: 1
        ) == nil)
        _ = try await store.fail(
            jobID: first.manifest.jobID,
            workerID: first.workerID,
            leaseToken: first.leaseToken,
            failure: "expected"
        )
        #expect(try await store.leaseNext(
            workerID: "worker",
            ocrLanguages: ["eng"],
            maximumActiveLeases: 1
        )?.manifest.jobID == "job-2")
    }

    @Test("Jobs and live leases survive restart and expired leases recover")
    func persistenceAndRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("jobs.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let first = OCRWorkerJobStore(
            fileURL: fileURL,
            leaseDurationSeconds: 10,
            leaseTokenProvider: { "first-token" }
        )
        _ = try await first.enqueue(testManifest(createdAt: start))
        _ = try await first.leaseNext(
            workerID: "worker-1",
            ocrLanguages: ["eng"],
            now: start
        )

        let reloaded = OCRWorkerJobStore(
            fileURL: fileURL,
            leaseDurationSeconds: 10,
            leaseTokenProvider: { "second-token" }
        )
        #expect(try await reloaded.snapshot(jobID: "job-1").leasedWorkerID == "worker-1")
        #expect(try await reloaded.requeueExpiredLeases(now: start.addingTimeInterval(11)) == 1)

        let recovered = try #require(try await reloaded.leaseNext(
            workerID: "worker-2",
            ocrLanguages: ["eng"],
            now: start.addingTimeInterval(12)
        ))
        #expect(recovered.attempt == 2)

        let secondReload = OCRWorkerJobStore(fileURL: fileURL)
        #expect(try await secondReload.snapshot(jobID: "job-1").leasedWorkerID == "worker-2")
    }
}

private func testManifest(
    jobID: String = "job-1",
    languages: [String] = ["eng"],
    cropPages: Bool = false,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> OCRWorkerJobManifest {
    OCRWorkerJobManifest(
        jobID: jobID,
        sourcePath: "/scans/input.pdf",
        outputPath: "/scans/input.ocr.pdf",
        sourceByteCount: 1_024,
        sourceSHA256: String(repeating: "a", count: 64),
        ocrLanguages: languages,
        ocrEnabled: true,
        removeBlankPages: false,
        cropPages: cropPages,
        createdAt: createdAt
    )
}

private final class TokenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.withLock { values.removeFirst() }
    }
}
