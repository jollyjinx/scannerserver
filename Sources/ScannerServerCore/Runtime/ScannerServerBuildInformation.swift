import Foundation

public struct ScannerServerBuildInformation: Equatable, Sendable {
    public static let developmentVersion = "development"

    public let version: String
    public let revision: String?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        version = Self.nonempty(environment["SCANNERSERVER_VERSION"]) ?? Self.developmentVersion
        revision = Self.nonempty(environment["SCANNERSERVER_REVISION"])
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
