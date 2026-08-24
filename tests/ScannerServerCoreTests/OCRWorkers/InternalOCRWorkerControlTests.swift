import Foundation
import ScannerServerCore
import Testing

@Suite("Internal OCR worker control")
struct InternalOCRWorkerControlTests {
    @Test("Pause state persists across service restarts")
    func persistence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("internal-worker.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = InternalOCRWorkerControl(
            fileURL: fileURL,
            maximumCPUs: 8,
            defaultReducedPriority: false,
            niceLevel: 14
        )
        #expect(await first.isPaused == false)
        #expect(await first.settings.cpuLimit == 8)
        try await first.setPaused(true)
        try await first.setSettings(cpuLimit: 3, priority: .fallbackOnly)
        #expect(await first.isPaused)

        let reloaded = InternalOCRWorkerControl(
            fileURL: fileURL,
            maximumCPUs: 8,
            defaultReducedPriority: false,
            niceLevel: 14
        )
        #expect(await reloaded.isPaused)
        #expect(await reloaded.settings == InternalOCRWorkerSettings(
            configuredCPULimit: 3,
            maximumCPUs: 8,
            priority: .fallbackOnly,
            niceLevel: 14
        ))
        try await reloaded.setPaused(false)
        #expect(await InternalOCRWorkerControl(fileURL: fileURL).isPaused == false)
    }

    @Test("Older pause-only state adopts worker defaults")
    func legacyPersistence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("internal-worker.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"paused":true}"#.utf8).write(to: fileURL)

        let control = InternalOCRWorkerControl(
            fileURL: fileURL,
            maximumCPUs: 6,
            defaultReducedPriority: true,
            niceLevel: 11
        )
        #expect(await control.isPaused)
        #expect(await control.settings.cpuLimit == 6)
        #expect(await control.settings.configuredCPULimit == nil)
        #expect(await control.settings.priority == .niced)
        #expect(await control.settings.niceLevel == 11)
    }

    @Test("Legacy reduced-priority state migrates to niced priority")
    func legacyReducedPriorityPersistence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("internal-worker.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"paused":false,"cpuLimit":2,"reducedPriority":true}"#.utf8)
            .write(to: fileURL)

        let control = InternalOCRWorkerControl(
            fileURL: fileURL,
            maximumCPUs: 6,
            defaultReducedPriority: false,
            niceLevel: 11
        )

        #expect(await control.settings.configuredCPULimit == 2)
        #expect(await control.settings.priority == .niced)
    }
}
