import Foundation

public struct VIPSThumbnailCommand: Equatable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let sourceKind: PreviewSourceKind

    public init(
        sourceURL: URL,
        destinationURL: URL,
        sourceKind: PreviewSourceKind
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.sourceKind = sourceKind
    }

    public var processRequest: ProcessRequest {
        let inputPath = switch sourceKind {
        case .pdf:
            "\(sourceURL.path)[page=0]"
        case .png:
            sourceURL.path
        }

        return ProcessRequest(
            executable: "vipsthumbnail",
            arguments: [
                inputPath,
                "--size", "320x420",
                "--output", "\(destinationURL.path)[Q=82,optimize_coding]",
            ]
        )
    }
}
