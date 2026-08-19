import Foundation

public protocol ScanPreviewProviding: Sendable {
    func preview(for sourceURL: URL, outputDirectory: URL) async throws -> Data
}

/// Compatibility provider used by tests and callers that do not compose the native renderer.
public struct CompatibleScanPreviewProvider: ScanPreviewProviding {
    public init() {}

    public func preview(for sourceURL: URL, outputDirectory: URL) async throws -> Data {
        let previewDirectory = outputDirectory.appendingPathComponent(
            PreviewOutputName.directoryName,
            isDirectory: true
        )
        let previewURL = previewDirectory.appendingPathComponent("\(sourceURL.lastPathComponent).jpg")
        let fileManager = FileManager.default
        if let previewAttributes = try? fileManager.attributesOfItem(atPath: previewURL.path),
           let sourceAttributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
           let previewDate = previewAttributes[.modificationDate] as? Date,
           let sourceDate = sourceAttributes[.modificationDate] as? Date,
           previewDate >= sourceDate {
            return try Data(contentsOf: previewURL)
        }

        let data = PlaceholderPreview.jpegBytes
        try fileManager.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        try data.write(to: previewURL, options: .atomic)
        return data
    }
}
