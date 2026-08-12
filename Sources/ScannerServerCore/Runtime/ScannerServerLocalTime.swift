import Foundation

/// The civil time used for user-visible timestamps and generated scan names.
public struct ScannerServerLocalTime: Sendable {
    public let timeZone: TimeZone

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallback: TimeZone = .current
    ) {
        let identifier = environment["TZ"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == ":" })
        if let identifier, !identifier.isEmpty,
           let configured = TimeZone(identifier: String(identifier)) {
            timeZone = configured
        } else {
            timeZone = fallback
        }
    }

    public func scanTimestamp(for date: Date) -> ScanTimestamp {
        ScanTimestamp(date: date, timeZone: timeZone)
    }

    public func statusTimestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
