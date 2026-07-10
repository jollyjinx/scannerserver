import Foundation

public enum SettingsValidationError: Error, Equatable, Sendable, LocalizedError {
    case invalidMACAddress
    case invalidIPv4Address
    case ipv4Required
    case passwordTooLong(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidMACAddress:
            "enter a 12-digit Ethernet address"
        case .invalidIPv4Address:
            "enter a valid scanner IP address"
        case .ipv4Required:
            "enter an IPv4 scanner address"
        case let .passwordTooLong(maximum):
            "password too long; maximum is \(maximum) characters"
        }
    }
}

public struct ScannerConfig: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case configured
        case needsPassword = "needs_password"
    }

    public static let identityKey = "pFusCANsNapFiPfu"
    public static let defaultMACPrefixes = ["84:25:3f", "00:80:92", "00:40:17"]

    public var version: Int
    public var status: Status
    public var source: String
    public var scannerIP: String
    public var mac: String
    public var serial: String
    public var name: String
    public var pairingKey: String
    public var passwordSource: String
    public var lastError: String
    public var updatedAt: String

    public init(
        version: Int = 1,
        status: Status = .needsPassword,
        source: String = "stored",
        scannerIP: String = "",
        mac: String = "",
        serial: String = "",
        name: String = "ScanSnap",
        pairingKey: String = "",
        passwordSource: String = "",
        lastError: String = "",
        updatedAt: String = ""
    ) {
        let pairingKey = pairingKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.version = 1
        self.status = status == .configured && pairingKey.isEmpty ? .needsPassword : status
        self.source = Self.nonEmptyTrimmed(source, fallback: "stored")
        self.scannerIP = scannerIP.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mac = mac.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = Self.nonEmptyTrimmed(name, fallback: "ScanSnap")
        self.pairingKey = pairingKey
        self.passwordSource = passwordSource.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lastError = lastError.trimmingCharacters(in: .whitespacesAndNewlines)
        self.updatedAt = updatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var pairingKeyMasked: String {
        Self.maskedSecret(pairingKey)
    }

    public var environmentOverrides: [String: String] {
        guard status == .configured else { return [:] }
        var environment: [String: String] = [:]
        if !scannerIP.isEmpty { environment["SCANNER_IP"] = scannerIP }
        if !pairingKey.isEmpty { environment["SCANSNAP_PAIRING_KEY"] = pairingKey }
        return environment
    }

    public func normalized(source: String? = nil) -> ScannerConfig {
        ScannerConfig(
            status: status,
            source: source ?? self.source,
            scannerIP: scannerIP,
            mac: mac,
            serial: serial,
            name: name,
            pairingKey: pairingKey,
            passwordSource: passwordSource,
            lastError: lastError,
            updatedAt: updatedAt
        )
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> ScannerConfig? {
        let scannerIP = (environment["SCANNER_IP"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredKey = environment["SCANSNAP_PAIRING_KEY"]
        let selectedKey = preferredKey?.isEmpty == false ? preferredKey : environment["SCAN_PAIRING_KEY"]
        let pairingKey = (selectedKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scannerIP.isEmpty, !pairingKey.isEmpty else { return nil }
        return ScannerConfig(
            status: .configured,
            source: "env",
            scannerIP: scannerIP,
            pairingKey: pairingKey
        )
    }

    public static func password(fromSerial serial: String) -> String {
        var scalars = Array(serial.unicodeScalars)
        while let last = scalars.last, last.value == 0 || last.value == 32 {
            scalars.removeLast()
        }
        return String(scalars.suffix(4).map { Character(String($0)) })
    }

    public static func derivePairingKey(password: String) throws -> String {
        let password = Array(password.unicodeScalars)
        let identity = Array(identityKey.unicodeScalars)
        guard password.count <= identity.count else {
            throw SettingsValidationError.passwordTooLong(maximum: identity.count)
        }
        return zip(password, identity)
            .map { String($0.value + $1.value + 11) }
            .joined()
    }

    public static func normalizeMACAddress(_ value: String) throws -> String {
        let compact = value.unicodeScalars.filter {
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }
        guard compact.count == 12 else { throw SettingsValidationError.invalidMACAddress }
        let text = compact.map(String.init).joined().lowercased()
        return stride(from: 0, to: text.count, by: 2).map { offset in
            let start = text.index(text.startIndex, offsetBy: offset)
            let end = text.index(start, offsetBy: 2)
            return String(text[start..<end])
        }.joined(separator: ":")
    }

    public static func normalizeIPv4Address(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }
        if value.contains(":") { throw SettingsValidationError.ipv4Required }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { throw SettingsValidationError.invalidIPv4Address }
        var octets: [String] = []
        for component in components {
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isASCII && $0.isNumber }),
                  !(component.count > 1 && component.first == "0"),
                  let octet = UInt8(component)
            else {
                throw SettingsValidationError.invalidIPv4Address
            }
            octets.append(String(octet))
        }
        return octets.joined(separator: ".")
    }

    public static func normalizeMACPrefixes(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: ":") }
            .filter { !$0.isEmpty }
    }

    public static func macPrefixes(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        normalizeMACPrefixes(environment["SCANSNAP_MAC_PREFIXES"] ?? defaultMACPrefixes.joined(separator: ","))
    }

    public static func maskedSecret(_ value: String) -> String {
        if value.isEmpty { return "" }
        if value.count <= 4 { return "set" }
        return "\(value.prefix(2))...\(value.suffix(2))"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = Status(rawValue: try container.decodeIfPresent(String.self, forKey: .status) ?? "") ?? .needsPassword
        let scannerIP = try container.decodeIfPresent(String.self, forKey: .scannerIP)
            ?? container.decodeIfPresent(String.self, forKey: .ip)
            ?? ""
        self.init(
            status: status,
            source: try container.decodeIfPresent(String.self, forKey: .source) ?? "stored",
            scannerIP: scannerIP,
            mac: try container.decodeIfPresent(String.self, forKey: .mac) ?? "",
            serial: try container.decodeIfPresent(String.self, forKey: .serial) ?? "",
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "ScanSnap",
            pairingKey: try container.decodeIfPresent(String.self, forKey: .pairingKey) ?? "",
            passwordSource: try container.decodeIfPresent(String.self, forKey: .passwordSource) ?? "",
            lastError: try container.decodeIfPresent(String.self, forKey: .lastError) ?? "",
            updatedAt: try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(status.rawValue, forKey: .status)
        try container.encode(source, forKey: .source)
        try container.encode(scannerIP, forKey: .scannerIP)
        try container.encode(mac, forKey: .mac)
        try container.encode(serial, forKey: .serial)
        try container.encode(name, forKey: .name)
        try container.encode(pairingKey, forKey: .pairingKey)
        try container.encode(pairingKeyMasked, forKey: .pairingKeyMasked)
        try container.encode(passwordSource, forKey: .passwordSource)
        try container.encode(lastError, forKey: .lastError)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private static func nonEmptyTrimmed(_ value: String, fallback: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case status
        case source
        case scannerIP = "scanner_ip"
        case ip
        case mac
        case serial
        case name
        case pairingKey = "pairing_key"
        case pairingKeyMasked = "pairing_key_masked"
        case passwordSource = "password_source"
        case lastError = "last_error"
        case updatedAt = "updated_at"
    }
}
