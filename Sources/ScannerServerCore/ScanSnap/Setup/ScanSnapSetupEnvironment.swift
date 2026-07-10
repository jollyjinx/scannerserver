import Foundation

public enum ScanSnapSetupConfigurationError: Error, Equatable, Sendable, LocalizedError {
    case invalidInteger(name: String, value: String)
    case invalidNumber(name: String, value: String)
    case invalidPort(name: String, value: String)
    case invalidPrefixLength(Int)
    case noIPv4Interface
    case noClientMACAddress
    case noRouteToScanner(String)
    case systemLookupFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidInteger(name, value):
            "invalid \(name) value \(value.debugDescription)"
        case let .invalidNumber(name, value):
            "invalid \(name) value \(value.debugDescription)"
        case let .invalidPort(name, value):
            "invalid \(name) port \(value.debugDescription)"
        case let .invalidPrefixLength(value):
            "invalid IPv4 prefix length \(value)"
        case .noIPv4Interface:
            "no local IPv4 interface found"
        case .noClientMACAddress:
            "could not determine client MAC address; set SCANSNAP_CLIENT_MAC"
        case let .noRouteToScanner(address):
            "could not determine client IP address for scanner \(address)"
        case let .systemLookupFailed(message):
            message
        }
    }
}

public struct ScanSnapSetupEnvironmentConfiguration: Equatable, Sendable {
    public let clientIPAddress: String?
    public let clientMACAddress: [UInt8]?
    public let clientInterface: String
    public let discoveryTargets: [String]
    public let includesAllARPNeighbors: Bool
    public let macPrefixes: [String]
    public let scannerIPAddress: String?
    public let discoverySourcePort: UInt16
    public let registrationSourcePort: UInt16
    public let registrationPort: UInt16
    public let discoveryRounds: Int
    public let discoveryTimeoutMilliseconds: UInt64

    public init(environment: [String: String]) throws {
        let configuredClientIP = try Self.optionalIPv4(environment["SCANSNAP_CLIENT_IP"])
        clientIPAddress = configuredClientIP

        let configuredMAC = (environment["SCANSNAP_CLIENT_MAC"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        clientMACAddress = configuredMAC.isEmpty ? nil : try Self.macBytes(configuredMAC)
        clientInterface = Self.nonEmpty(environment["SCANSNAP_CLIENT_INTERFACE"], fallback: "eth0")

        discoveryTargets = try Self.commaSeparated(environment["SCANSNAP_DISCOVERY_TARGETS"])
            .map(ScannerConfig.normalizeIPv4Address)
        includesAllARPNeighbors = Self.truthy(environment["SCANSNAP_DISCOVERY_ARP_ALL"])
        macPrefixes = ScannerConfig.macPrefixes(environment: environment)
        scannerIPAddress = try Self.optionalIPv4(environment["SCANNER_IP"])

        discoverySourcePort = try Self.port(
            environment["SCANSNAP_DISCOVERY_SOURCE_PORT"],
            name: "SCANSNAP_DISCOVERY_SOURCE_PORT",
            fallback: ScanSnapPacketBuilder.registrationSourcePort,
            allowsZero: true
        )
        registrationSourcePort = try Self.port(
            environment["SCANSNAP_REGISTRATION_SOURCE_PORT"],
            name: "SCANSNAP_REGISTRATION_SOURCE_PORT",
            fallback: ScanSnapPacketBuilder.registrationSourcePort,
            allowsZero: true
        )
        registrationPort = try Self.port(
            environment["SCANSNAP_REGISTRATION_PORT"],
            name: "SCANSNAP_REGISTRATION_PORT",
            fallback: ScanSnapPacketBuilder.registrationPort,
            allowsZero: false
        )
        discoveryRounds = try Self.positiveInteger(
            environment["SCANSNAP_DISCOVERY_ROUNDS"],
            name: "SCANSNAP_DISCOVERY_ROUNDS",
            fallback: 2
        )
        discoveryTimeoutMilliseconds = try Self.timeoutMilliseconds(
            environment["SCANSNAP_DISCOVERY_TIMEOUT_SECONDS"],
            name: "SCANSNAP_DISCOVERY_TIMEOUT_SECONDS",
            fallbackSeconds: 4
        )
    }

    public static func macBytes(_ value: String) throws -> [UInt8] {
        let normalized = try ScannerConfig.normalizeMACAddress(value)
        return normalized.split(separator: ":").map { UInt8($0, radix: 16)! }
    }

    private static func optionalIPv4(_ value: String?) throws -> String? {
        let normalized = try ScannerConfig.normalizeIPv4Address(value ?? "")
        return normalized.isEmpty ? nil : normalized
    }

    private static func commaSeparated(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func nonEmpty(_ value: String?, fallback: String) -> String {
        let value = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }

    private static func truthy(_ value: String?) -> Bool {
        ["1", "true", "yes", "on"].contains((value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func positiveInteger(_ value: String?, name: String, fallback: Int) throws -> Int {
        guard let value else { return fallback }
        guard let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ScanSnapSetupConfigurationError.invalidInteger(name: name, value: value)
        }
        return max(parsed, 1)
    }

    private static func port(
        _ value: String?,
        name: String,
        fallback: UInt16,
        allowsZero: Bool
    ) throws -> UInt16 {
        guard let value else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed), (allowsZero ? 0...65_535 : 1...65_535).contains(parsed) else {
            throw ScanSnapSetupConfigurationError.invalidPort(name: name, value: value)
        }
        return UInt16(parsed)
    }

    private static func timeoutMilliseconds(
        _ value: String?,
        name: String,
        fallbackSeconds: Double
    ) throws -> UInt64 {
        guard let value else { return UInt64(fallbackSeconds * 1_000) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = Double(trimmed), seconds.isFinite, seconds >= 0,
              seconds <= Double(UInt64.max) / 1_000
        else {
            throw ScanSnapSetupConfigurationError.invalidNumber(name: name, value: value)
        }
        return UInt64(seconds * 1_000)
    }
}

