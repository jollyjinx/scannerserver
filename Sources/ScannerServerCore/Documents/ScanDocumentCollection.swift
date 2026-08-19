import Foundation

/// The bytes and response metadata for one browser-visible scan output.
public struct ScanDocumentResource: Equatable, Sendable {
    public let fileName: ScanOutputFileName
    public let data: Data
    public let contentType: String

    public init(fileName: ScanOutputFileName, data: Data, contentType: String) {
        self.fileName = fileName
        self.data = data
        self.contentType = contentType
    }
}

/// Bridges document removal to work owned by the scan-processing actors.
public struct ScanDocumentWorkCanceller: Sendable {
    private let operation: @Sendable (String) async -> Void

    public init(operation: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.operation = operation
    }

    public func cancelWork(referencing path: String) async {
        await operation(path)
    }
}

/// Owns the browser-visible lifecycle of files in the scan output collection.
///
/// The actor serializes discovery, reads, previews, and removals initiated by HTTP routes. Scan and
/// OCR publishers retain their existing atomic publication contracts and become visible on the
/// next collection snapshot.
public actor ScanDocumentCollection {
    public nonisolated let outputDirectory: URL

    private let pathResolver: ScanOutputPathResolver
    private let previewProvider: any ScanPreviewProviding
    private let workCanceller: ScanDocumentWorkCanceller

    public init(
        outputDirectory: URL,
        previewProvider: any ScanPreviewProviding = CompatibleScanPreviewProvider(),
        workCanceller: ScanDocumentWorkCanceller = ScanDocumentWorkCanceller()
    ) {
        let pathResolver = ScanOutputPathResolver(outputDirectory: outputDirectory)
        self.outputDirectory = pathResolver.outputDirectory
        self.pathResolver = pathResolver
        self.previewProvider = previewProvider
        self.workCanceller = workCanceller
    }

    public func groups(timeZone: TimeZone = .current) -> [ScanDayGroup] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let files = urls.compactMap { url -> ScanFile? in
            guard let name = try? ScanOutputFileName(rawValue: url.lastPathComponent),
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true
            else {
                return nil
            }
            return ScanFile(
                name: name,
                modificationDate: values.contentModificationDate ?? .distantPast
            )
        }
        return ScanFileGrouping.groups(for: files, timeZone: timeZone)
    }

    public func resource(named rawName: String) -> ScanDocumentResource? {
        guard let fileURL = try? pathResolver.resolve(rawName),
              let fileName = try? ScanOutputFileName(rawValue: fileURL.lastPathComponent),
              let data = try? Data(contentsOf: fileURL)
        else {
            return nil
        }
        return ScanDocumentResource(
            fileName: fileName,
            data: data,
            contentType: Self.contentType(for: fileURL)
        )
    }

    public func preview(named rawName: String) async throws -> Data? {
        guard let sourceURL = try? pathResolver.resolve(rawName),
              ["pdf", "png"].contains(sourceURL.pathExtension.lowercased())
        else {
            return nil
        }
        return try await previewProvider.preview(
            for: sourceURL,
            outputDirectory: outputDirectory
        )
    }

    public func remove(named rawName: String) async {
        guard let fileURL = try? pathResolver.resolve(rawName),
              let fileName = try? ScanOutputFileName(rawValue: fileURL.lastPathComponent)
        else {
            return
        }

        await workCanceller.cancelWork(referencing: fileURL.path)

        let previewURL = outputDirectory.appendingPathComponent(
            PreviewOutputName(sourceFileName: fileName).relativePath,
            isDirectory: false
        )
        try? FileManager.default.removeItem(at: previewURL)
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "png": "image/png"
        default: "application/octet-stream"
        }
    }
}
