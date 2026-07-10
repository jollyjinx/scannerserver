import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum NativeDocumentFileSystemError: Error, Equatable, LocalizedError, Sendable {
    case outputConflict(String)

    public var errorDescription: String? {
        switch self {
        case .outputConflict(let path):
            "Output file already exists: \(path)"
        }
    }
}

public struct NativeDocumentImageDimensions: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32

    public init(width: UInt32, height: UInt32) {
        self.width = width
        self.height = height
    }

    var pixelCount: UInt64 {
        UInt64(width) * UInt64(height)
    }
}

public protocol NativeDocumentFileSystem: Sendable {
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
    func createTemporaryDirectory(in directory: URL) throws -> URL
    func itemExists(at url: URL) -> Bool
    func removeItemIfPresent(at url: URL) throws
    func regularFiles(
        in directory: URL,
        withPrefix prefix: String,
        pathExtension: String
    ) throws -> [URL]
    func pngDimensions(at url: URL) throws -> NativeDocumentImageDimensions?
    func readData(at url: URL) throws -> Data
    func readMappedData(at url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL) throws
    func placeFileExclusively(at source: URL, destination: URL) throws
    func replaceFileAtomically(at destination: URL, with source: URL) throws
}

public extension NativeDocumentFileSystem {
    func readMappedData(at url: URL) throws -> Data {
        try readData(at: url)
    }
}

public struct FoundationNativeDocumentFileSystem: NativeDocumentFileSystem {
    public init() {}

    public func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    public func createTemporaryDirectory(in directory: URL) throws -> URL {
        let temporaryDirectory = directory.appendingPathComponent(
            ".native-document-tools-\(UUID().uuidString)",
            isDirectory: true
        )
        try createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        return temporaryDirectory
    }

    public func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func removeItemIfPresent(at url: URL) throws {
        guard itemExists(at: url) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func regularFiles(
        in directory: URL,
        withPrefix prefix: String,
        pathExtension: String
    ) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            guard url.lastPathComponent.hasPrefix(prefix),
                  url.pathExtension.lowercased() == pathExtension.lowercased(),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            else {
                return false
            }
            return values.isRegularFile == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func pngDimensions(at url: URL) throws -> NativeDocumentImageDimensions? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 24), data.count == 24 else { return nil }

        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard Array(data.prefix(8)) == signature,
              String(decoding: data[12..<16], as: UTF8.self) == "IHDR"
        else {
            return nil
        }

        return NativeDocumentImageDimensions(
            width: Self.bigEndianUInt32(data[16..<20]),
            height: Self.bigEndianUInt32(data[20..<24])
        )
    }

    public func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func readMappedData(at url: URL) throws -> Data {
        try Data(contentsOf: url, options: .mappedIfSafe)
    }

    public func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
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
                throw NativeDocumentFileSystemError.outputConflict(destination.path)
            }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorNumber),
                userInfo: [NSFilePathErrorKey: destination.path]
            )
        }
    }

    public func replaceFileAtomically(at destination: URL, with source: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        if let permissions = attributes[.posixPermissions] {
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: source.path
            )
        }

        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: destination.path]
            )
        }
    }

    private static func bigEndianUInt32(_ bytes: Data.SubSequence) -> UInt32 {
        bytes.reduce(0) { partialResult, byte in
            (partialResult << 8) | UInt32(byte)
        }
    }
}
