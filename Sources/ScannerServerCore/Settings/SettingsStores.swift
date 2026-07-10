import Foundation

public actor ScanSettingsStore {
    public let fileURL: URL
    private let environment: [String: String]

    public init(
        fileURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileURL = fileURL
        self.environment = environment
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        fileURL = Self.defaultFileURL(environment: environment)
        self.environment = environment
    }

    public static func defaultFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["SCAN_SETTINGS_PATH"] {
            return URL(fileURLWithPath: path)
        }
        let outputDirectory = environment["SCAN_OUTPUT_DIR"] ?? "/scans"
        return URL(fileURLWithPath: outputDirectory).appendingPathComponent(".scanner-settings.json")
    }

    public func load() throws -> ScanSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let settings = ScanSettings.defaults(environment: environment)
            try write(settings)
            return settings
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.userInfo[SettingsCoding.environmentUserInfoKey] = environment
            return try decoder.decode(ScanSettings.self, from: data).normalized(environment: environment)
        } catch {
            return ScanSettings.defaults(environment: environment)
        }
    }

    @discardableResult
    public func save(_ settings: ScanSettings) throws -> ScanSettings {
        let settings = settings.normalized(environment: environment)
        try write(settings)
        return settings
    }

    private func write(_ settings: ScanSettings) throws {
        try AtomicJSONFile.write(settings, to: fileURL)
    }
}

public actor ScannerConfigStore {
    public let fileURL: URL
    private let environment: [String: String]

    public init(
        fileURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileURL = fileURL
        self.environment = environment
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        fileURL = Self.defaultFileURL(environment: environment)
        self.environment = environment
    }

    public static func defaultFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["SCANNER_CONFIG_PATH"] {
            return URL(fileURLWithPath: path)
        }
        let outputDirectory = environment["SCAN_OUTPUT_DIR"] ?? "/scans"
        return URL(fileURLWithPath: outputDirectory).appendingPathComponent(".scannerserver-scanner.json")
    }

    public func loadStored() -> ScannerConfig? {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(ScannerConfig.self, from: data)
        else {
            return nil
        }
        return config.normalized()
    }

    public func activeConfiguration() -> ScannerConfig? {
        ScannerConfig.fromEnvironment(environment) ?? loadStored()
    }

    @discardableResult
    public func save(_ config: ScannerConfig, now: Date = Date()) throws -> ScannerConfig {
        var config = config.normalized(source: "stored")
        config.updatedAt = Self.timestamp(now)
        try AtomicJSONFile.write(config, to: fileURL)
        return config
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private enum AtomicJSONFile {
    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}
