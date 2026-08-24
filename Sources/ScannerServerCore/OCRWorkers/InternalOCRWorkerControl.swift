import Foundation

public enum InternalOCRWorkerPriority: String, Codable, CaseIterable, Equatable, Sendable {
    case normal
    case niced
    case fallbackOnly = "fallback-only"

    public var usesReducedProcessPriority: Bool {
        self != .normal
    }
}

public struct InternalOCRWorkerSettings: Equatable, Sendable {
    public let configuredCPULimit: Int?
    public let cpuLimit: Int
    public let maximumCPUs: Int
    public let priority: InternalOCRWorkerPriority
    public let niceLevel: Int?

    public var reducedPriority: Bool { priority.usesReducedProcessPriority }
    public var fallbackOnly: Bool { priority == .fallbackOnly }

    public init(
        configuredCPULimit: Int?,
        maximumCPUs: Int,
        priority: InternalOCRWorkerPriority,
        niceLevel: Int
    ) {
        let maximumCPUs = max(1, maximumCPUs)
        let configuredCPULimit = configuredCPULimit.map { min(max(1, $0), maximumCPUs) }
        self.configuredCPULimit = configuredCPULimit
        self.cpuLimit = configuredCPULimit ?? maximumCPUs
        self.maximumCPUs = maximumCPUs
        self.priority = priority
        self.niceLevel = priority.usesReducedProcessPriority
            ? min(max(niceLevel, 1), 19)
            : nil
    }

    public init(
        configuredCPULimit: Int?,
        maximumCPUs: Int,
        reducedPriority: Bool,
        niceLevel: Int
    ) {
        self.init(
            configuredCPULimit: configuredCPULimit,
            maximumCPUs: maximumCPUs,
            priority: reducedPriority ? .niced : .normal,
            niceLevel: niceLevel
        )
    }
}

public actor InternalOCRWorkerControl {
    private struct StoredState: Codable, Sendable {
        let paused: Bool
        let cpuLimit: Int?
        let priority: InternalOCRWorkerPriority?
        let reducedPriority: Bool?
    }

    public nonisolated let webUpdates: WebUpdateNotifier
    public let fileURL: URL?

    private var paused: Bool
    private var configuredCPULimit: Int?
    private var priority: InternalOCRWorkerPriority
    private let maximumCPUs: Int
    private let niceLevel: Int

    public init(
        fileURL: URL? = nil,
        maximumCPUs: Int = OCRQueueConfiguration().cpuLimit,
        defaultReducedPriority: Bool = OCRQueueConfiguration().niceLevel != nil,
        niceLevel: Int = OCRQueueConfiguration().niceLevel ?? 10,
        webUpdates: WebUpdateNotifier = WebUpdateNotifier()
    ) {
        let resolvedMaximumCPUs = max(1, maximumCPUs)
        self.fileURL = fileURL
        self.webUpdates = webUpdates
        self.maximumCPUs = resolvedMaximumCPUs
        self.niceLevel = min(max(niceLevel, 1), 19)
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(StoredState.self, from: data) {
            paused = stored.paused
            configuredCPULimit = stored.cpuLimit.map { min(max(1, $0), resolvedMaximumCPUs) }
            priority = stored.priority
                ?? ((stored.reducedPriority ?? defaultReducedPriority) ? .niced : .normal)
        } else {
            paused = false
            configuredCPULimit = nil
            priority = defaultReducedPriority ? .niced : .normal
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

    public var settings: InternalOCRWorkerSettings {
        InternalOCRWorkerSettings(
            configuredCPULimit: configuredCPULimit,
            maximumCPUs: maximumCPUs,
            priority: priority,
            niceLevel: niceLevel
        )
    }

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

    public func setSettings(
        cpuLimit: Int?,
        priority newPriority: InternalOCRWorkerPriority
    ) async throws {
        let newCPULimit = cpuLimit.map { min(max(1, $0), maximumCPUs) }
        guard configuredCPULimit != newCPULimit || priority != newPriority else {
            return
        }
        let previousCPULimit = configuredCPULimit
        let previousPriority = priority
        configuredCPULimit = newCPULimit
        priority = newPriority
        do {
            try persist()
        } catch {
            configuredCPULimit = previousCPULimit
            priority = previousPriority
            throw error
        }
        await webUpdates.notify()
    }

    public func setSettings(cpuLimit: Int?, reducedPriority: Bool) async throws {
        try await setSettings(
            cpuLimit: cpuLimit,
            priority: reducedPriority ? .niced : .normal
        )
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
        var data = try encoder.encode(StoredState(
            paused: paused,
            cpuLimit: configuredCPULimit,
            priority: priority,
            reducedPriority: nil
        ))
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
    }
}
