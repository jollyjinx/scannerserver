import Foundation

public actor NativeScanPreviewProvider: ScanPreviewProviding {
    private let executor: any ProcessExecutor
    private var inFlight: [URL: Task<Data, any Error>] = [:]

    public init(executor: any ProcessExecutor) {
        self.executor = executor
    }

    public func preview(for sourceURL: URL, outputDirectory: URL) async throws -> Data {
        let previewURL = outputDirectory
            .appendingPathComponent(PreviewOutputName.directoryName, isDirectory: true)
            .appendingPathComponent("\(sourceURL.lastPathComponent).jpg")
            .standardizedFileURL

        if let cached = Self.cachedPreview(for: sourceURL, at: previewURL) {
            return cached
        }
        if let task = inFlight[previewURL] {
            return try await task.value
        }

        let executor = executor
        let task = Task {
            try await Self.generatePreview(
                for: sourceURL,
                at: previewURL,
                executor: executor
            )
        }
        inFlight[previewURL] = task

        do {
            let data = try await task.value
            inFlight[previewURL] = nil
            return data
        } catch {
            inFlight[previewURL] = nil
            throw error
        }
    }

    private static func cachedPreview(for sourceURL: URL, at previewURL: URL) -> Data? {
        let fileManager = FileManager.default
        guard
            let sourceAttributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
            let sourceDate = sourceAttributes[.modificationDate] as? Date,
            let previewAttributes = try? fileManager.attributesOfItem(atPath: previewURL.path),
            let previewDate = previewAttributes[.modificationDate] as? Date,
            previewDate >= sourceDate,
            let data = try? Data(contentsOf: previewURL),
            !data.isEmpty
        else {
            return nil
        }
        return data
    }

    private static func generatePreview(
        for sourceURL: URL,
        at previewURL: URL,
        executor: any ProcessExecutor
    ) async throws -> Data {
        let fileManager = FileManager.default
        let sourceAttributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let sourceSize = (sourceAttributes[.size] as? NSNumber)?.uint64Value ?? 0
        let sourceKind = PreviewSourceKind(rawValue: sourceURL.pathExtension.lowercased())

        try fileManager.createDirectory(
            at: previewURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard sourceSize > 0, let sourceKind else {
            return try writePlaceholder(to: previewURL)
        }

        let temporaryURL = previewURL.deletingLastPathComponent().appendingPathComponent(
            ".\(previewURL.lastPathComponent).\(UUID().uuidString).tmp.jpg"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        do {
            let command = VIPSThumbnailCommand(
                sourceURL: sourceURL,
                destinationURL: temporaryURL,
                sourceKind: sourceKind
            )
            let result = try await executor.execute(command.processRequest)
            try Task.checkCancellation()

            guard result.succeeded,
                  let renderedData = try? Data(contentsOf: temporaryURL),
                  !renderedData.isEmpty
            else {
                return try writePlaceholder(to: previewURL)
            }

            try renderedData.write(to: previewURL, options: .atomic)
            return renderedData
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try writePlaceholder(to: previewURL)
        }
    }

    private static func writePlaceholder(to previewURL: URL) throws -> Data {
        let data = PlaceholderPreview.jpegBytes
        try data.write(to: previewURL, options: .atomic)
        return data
    }
}
