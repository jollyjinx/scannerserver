import Foundation

public enum ScanOutputPathError: Error, Equatable, Sendable {
    case invalidFileName(ScanOutputFileNameError)
    case escapesOutputDirectory(String)
    case fileDoesNotExist(String)
    case notARegularFile(String)
}

public struct ScanOutputPathResolver: Sendable {
    public let outputDirectory: URL

    public init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory.standardizedFileURL
    }

    public func resolve(
        _ rawName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let fileName: ScanOutputFileName
        do {
            fileName = try ScanOutputFileName(rawValue: rawName)
        } catch let error as ScanOutputFileNameError {
            throw ScanOutputPathError.invalidFileName(error)
        }
        return try resolve(fileName, fileManager: fileManager)
    }

    public func resolve(
        _ fileName: ScanOutputFileName,
        fileManager: FileManager = .default
    ) throws -> URL {
        let resolvedRoot = outputDirectory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = outputDirectory
            .appendingPathComponent(fileName.rawValue, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL

        guard candidate.deletingLastPathComponent() == resolvedRoot else {
            throw ScanOutputPathError.escapesOutputDirectory(fileName.rawValue)
        }

        guard fileManager.fileExists(atPath: candidate.path) else {
            throw ScanOutputPathError.fileDoesNotExist(fileName.rawValue)
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: candidate.path)
        } catch {
            throw ScanOutputPathError.fileDoesNotExist(fileName.rawValue)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ScanOutputPathError.notARegularFile(fileName.rawValue)
        }

        return candidate
    }
}
