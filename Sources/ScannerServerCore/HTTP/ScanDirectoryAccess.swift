import Foundation

public struct ScanDirectoryAccessIssue: Equatable, Sendable {
    public let directoryPath: String
    public let details: String

    public init(directoryPath: String, details: String) {
        self.directoryPath = directoryPath
        self.details = details
    }

    public static func check(
        directory: URL,
        fileManager: FileManager = .default
    ) -> ScanDirectoryAccessIssue? {
        let directory = directory.standardizedFileURL
        let probeURL = directory.appendingPathComponent(
            ".scannerserver-access-check-\(UUID().uuidString)",
            isDirectory: false
        )
        let probeData = Data("scannerserver access check\n".utf8)
        let updatedProbeData = Data("scannerserver updated access check\n".utf8)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try fileManager.contentsOfDirectory(atPath: directory.path)
            try probeData.write(to: probeURL, options: .atomic)
            guard try Data(contentsOf: probeURL) == probeData else {
                throw ScanDirectoryAccessCheckError.probeContentsChanged
            }
            try updatedProbeData.write(to: probeURL, options: .atomic)
            guard try Data(contentsOf: probeURL) == updatedProbeData else {
                throw ScanDirectoryAccessCheckError.probeContentsChanged
            }
            try fileManager.removeItem(at: probeURL)
            return nil
        } catch {
            try? fileManager.removeItem(at: probeURL)
            return ScanDirectoryAccessIssue(
                directoryPath: directory.path,
                details: error.localizedDescription
            )
        }
    }
}

private enum ScanDirectoryAccessCheckError: LocalizedError {
    case probeContentsChanged

    var errorDescription: String? {
        "The scan directory access-check file could not be read back correctly."
    }
}
