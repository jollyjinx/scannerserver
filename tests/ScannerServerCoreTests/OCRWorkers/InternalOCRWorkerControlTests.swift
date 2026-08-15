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

        let first = InternalOCRWorkerControl(fileURL: fileURL)
        #expect(await first.isPaused == false)
        try await first.setPaused(true)
        #expect(await first.isPaused)

        let reloaded = InternalOCRWorkerControl(fileURL: fileURL)
        #expect(await reloaded.isPaused)
        try await reloaded.setPaused(false)
        #expect(await InternalOCRWorkerControl(fileURL: fileURL).isPaused == false)
    }
}
