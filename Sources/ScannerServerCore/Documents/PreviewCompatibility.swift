import Foundation

public enum PreviewSourceKind: String, Equatable, Sendable {
    case pdf
    case png
}

public enum PreviewNativeRenderingRequirement: String, Equatable, Sendable {
    case pdfImageExtraction
    case pngDecoding
}

public enum PreviewRenderingPlan: Equatable, Sendable {
    case nativeRenderingRequired(
        PreviewNativeRenderingRequirement,
        fallback: PreviewFallback
    )
}

public enum PreviewFallback: Equatable, Sendable {
    case neutralJPEG

    public var bytes: Data {
        switch self {
        case .neutralJPEG:
            PlaceholderPreview.jpegBytes
        }
    }
}

/// Captures the dimensions, quality, and fallback required by the preview contract.
public struct PreviewToolRequest: Equatable, Sendable {
    public let sourcePath: String
    public let destinationPath: String
    public let sourceKind: PreviewSourceKind
    public var maximumWidth: Int
    public var maximumHeight: Int
    public var renderedJPEGQuality: Int
    public var optimizeRenderedJPEG: Bool
    public var fallbackJPEGQuality: Int

    public init(
        sourcePath: String,
        destinationPath: String,
        sourceKind: PreviewSourceKind,
        maximumWidth: Int = 320,
        maximumHeight: Int = 420,
        renderedJPEGQuality: Int = 82,
        optimizeRenderedJPEG: Bool = true,
        fallbackJPEGQuality: Int = 75
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.sourceKind = sourceKind
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.renderedJPEGQuality = renderedJPEGQuality
        self.optimizeRenderedJPEG = optimizeRenderedJPEG
        self.fallbackJPEGQuality = fallbackJPEGQuality
    }

    public var renderingPlan: PreviewRenderingPlan {
        let requirement: PreviewNativeRenderingRequirement = switch sourceKind {
        case .pdf: .pdfImageExtraction
        case .png: .pngDecoding
        }
        return .nativeRenderingRequired(requirement, fallback: .neutralJPEG)
    }
}

public enum PlaceholderPreview {
    public static let width = 320
    public static let height = 420
    public static let rgb = (red: 0xf1, green: 0xf3, blue: 0xf4)
    public static let jpegQuality = 75

    /// Pillow's deterministic JPEG encoding of a 320x420 RGB image filled with #f1f3f4.
    public static let jpegBytes: Data = {
        let encoded = Data(base64Encoded: encodedJPEG)!
        var bytes = Data(encoded.prefix(632))
        for _ in 0..<538 {
            bytes.append(contentsOf: [0x02, 0x8a, 0x28, 0xa0])
        }
        bytes.append(contentsOf: [0x0f, 0xff, 0xd9])
        return bytes
    }()

    private static let encodedJPEG =
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAGkAUADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3OiiimIKKKKA="
}
