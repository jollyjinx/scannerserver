import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum NativeScanFileSystemError: Error, Equatable, LocalizedError, Sendable {
    case outputConflict(String)

    public var errorDescription: String? {
        switch self {
        case .outputConflict(let path):
            "Output file already exists: \(path)"
        }
    }
}

public protocol NativeScanFileSystem: Sendable {
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
    func removeItemIfPresent(at url: URL) throws
    func regularFileExists(at url: URL) -> Bool
    func regularFiles(
        in directory: URL,
        withPrefix prefix: String,
        pathExtension: String
    ) throws -> [URL]
    func placeFileExclusively(at source: URL, destination: URL) throws
}

public struct FoundationNativeScanFileSystem: NativeScanFileSystem {
    public init() {}

    public func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    public func removeItemIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func regularFileExists(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    public func regularFiles(
        in directory: URL,
        withPrefix prefix: String,
        pathExtension: String
    ) throws -> [URL] {
        return try FileManager.default
            .contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                guard url.lastPathComponent.hasPrefix(prefix),
                      url.pathExtension == pathExtension,
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                else {
                    return false
                }
                return values.isRegularFile == true
            }
            .map { directory.appendingPathComponent($0.lastPathComponent, isDirectory: false) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func placeFileExclusively(at source: URL, destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                link(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            let errorNumber = errno
            if errorNumber == EEXIST {
                throw NativeScanFileSystemError.outputConflict(destination.path)
            }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorNumber),
                userInfo: [NSFilePathErrorKey: destination.path]
            )
        }
    }
}
