import Foundation

public actor InternalOCRWorkerControl {
    private struct StoredState: Codable, Sendable {
        let paused: Bool
    }

    public nonisolated let webUpdates: WebUpdateNotifier
    public let fileURL: URL?

    private var paused: Bool

    public init(
        fileURL: URL? = nil,
        webUpdates: WebUpdateNotifier = WebUpdateNotifier()
    ) {
        self.fileURL = fileURL
        self.webUpdates = webUpdates
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(StoredState.self, from: data) {
            paused = stored.paused
        } else {
            paused = false
        }
    }

    public static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let path = environment["SCAN_INTERNAL_OCR_WORKER_PATH"] {
            return URL(fileURLWithPath: path)
        }
        let outputDirectory = environment["SCAN_OUTPUT_DIR"] ?? "/scans"
        return URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent(".scannerserver-internal-ocr-worker.json")
    }

    public var isPaused: Bool { paused }

    public func setPaused(_ newValue: Bool) async throws {
        guard paused != newValue else { return }
        let previousValue = paused
        paused = newValue
        do {
            try persist()
        } catch {
            paused = previousValue
            throw error
        }
        await webUpdates.notify()
    }

    /// Waits for any scheduler-visible change while the internal worker is paused.
    /// Worker registration and approval share this notifier, allowing dispatch to
    /// be reconsidered immediately when remote capacity appears.
    public func waitForDispatchChange(after observedRevision: UInt64) async throws {
        guard paused else { return }
        try Task.checkCancellation()
        guard paused else { return }
        _ = await webUpdates.wait(after: observedRevision)
        try Task.checkCancellation()
    }

    public func waitUntilPaused() async throws {
        while !paused {
            try Task.checkCancellation()
            let revision = await webUpdates.currentRevision
            guard !paused else { break }
            _ = await webUpdates.wait(after: revision)
        }
        try Task.checkCancellation()
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(StoredState(paused: paused))
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
    }
}
