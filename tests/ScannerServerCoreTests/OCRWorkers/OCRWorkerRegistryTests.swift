import Foundation
import ScannerServerCore
import Testing

@Suite("OCR worker registry")
struct OCRWorkerRegistryTests {
    @Test("Workers require approval and transition through online, busy, paused, disabled, and offline")
    func lifecycle() async throws {
        let registry = OCRWorkerRegistry(offlineAfterSeconds: 20)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let registration = testRegistration()

        let registered = try await registry.register(registration, now: start)
        #expect(registered.availability == .pendingApproval)
        #expect(await registry.snapshots(now: start).first?.approved == false)

        let approved = try await registry.approve(workerID: registration.workerID, now: start)
        #expect(approved.availability == .online)
        #expect(approved.capabilities == [OCRWorkerCapability.cropPDFPages])
        #expect(await registry.hasPreferredWorker(
            ocrLanguages: ["eng"],
            requiredCapabilities: [OCRWorkerCapability.cropPDFPages]
        ))

        let busy = try await registry.heartbeat(
            workerID: registration.workerID,
            request: OCRWorkerHeartbeatRequest(
                authenticationToken: registration.authenticationToken,
                runningJobs: 1
            ),
            now: start.addingTimeInterval(5)
        )
        #expect(busy.availability == .busy)

        let paused = try await registry.setPaused(
            true,
            workerID: registration.workerID,
            now: start.addingTimeInterval(5)
        )
        #expect(paused.availability == .paused)
        #expect(paused.paused)
        #expect(await registry.hasPreferredWorker(ocrLanguages: ["eng"]) == false)
        await #expect(throws: OCRWorkerRegistryError.workerPaused) {
            _ = try await registry.authorizeJobRequest(
                workerID: registration.workerID,
                authenticationToken: registration.authenticationToken,
                now: start.addingTimeInterval(5)
            )
        }
        _ = try await registry.setPaused(
            false,
            workerID: registration.workerID,
            now: start.addingTimeInterval(5)
        )

        let disabled = try await registry.setEnabled(
            false,
            workerID: registration.workerID,
            now: start.addingTimeInterval(6)
        )
        #expect(disabled.availability == .disabled)

        _ = try await registry.setEnabled(
            true,
            workerID: registration.workerID,
            now: start.addingTimeInterval(6)
        )
        let offline = await registry.snapshots(now: start.addingTimeInterval(30))
        #expect(offline.first?.availability == .offline)
    }

    @Test("A worker ID cannot be taken over with a different token")
    func authentication() async throws {
        let registry = OCRWorkerRegistry()
        let registration = testRegistration()
        _ = try await registry.register(registration)
        let impostor = OCRWorkerRegistrationRequest(
            workerID: registration.workerID,
            authenticationToken: String(repeating: "b", count: 64),
            displayName: "Impostor",
            hostname: "impostor.local",
            workerVersion: "development",
            architecture: "arm64",
            cpuCount: 4,
            maxConcurrentJobs: 1,
            ocrLanguages: ["eng"]
        )

        await #expect(throws: OCRWorkerRegistryError.authenticationFailed) {
            _ = try await registry.register(impostor)
        }
    }

    @Test("Approved registrations survive a registry restart")
    func persistence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("workers.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = testRegistration()
        let first = OCRWorkerRegistry(fileURL: fileURL)
        _ = try await first.register(registration)
        _ = try await first.approve(workerID: registration.workerID)
        _ = try await first.setPaused(true, workerID: registration.workerID)

        let reloaded = OCRWorkerRegistry(fileURL: fileURL)
        let workers = await reloaded.snapshots()

        #expect(workers.count == 1)
        #expect(workers.first?.workerID == registration.workerID)
        #expect(workers.first?.approved == true)
        #expect(workers.first?.paused == true)
    }

    @Test("Deleting a worker removes its persisted approval")
    func deletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("workers.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = testRegistration()
        let registry = OCRWorkerRegistry(fileURL: fileURL)
        _ = try await registry.register(registration)
        _ = try await registry.approve(workerID: registration.workerID)

        let removed = try await registry.remove(workerID: registration.workerID)
        #expect(removed.workerID == registration.workerID)
        #expect(await registry.snapshots().isEmpty)
        #expect(await OCRWorkerRegistry(fileURL: fileURL).snapshots().isEmpty)

        await #expect(throws: OCRWorkerRegistryError.unknownWorker) {
            _ = try await registry.remove(workerID: registration.workerID)
        }
    }
}

private func testRegistration() -> OCRWorkerRegistrationRequest {
    OCRWorkerRegistrationRequest(
        workerID: "mac-studio-1",
        authenticationToken: String(repeating: "a", count: 64),
        displayName: "Mac Studio",
        hostname: "mac-studio.local",
        workerVersion: "2026.08.15.120000",
        architecture: "arm64",
        cpuCount: 12,
        maxConcurrentJobs: 2,
        ocrLanguages: ["deu", "eng"],
        capabilities: [OCRWorkerCapability.cropPDFPages]
    )
}
