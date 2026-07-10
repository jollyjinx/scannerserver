import Foundation

public struct ScanMode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var settings: ModeSettings

    public init(id: String, name: String, settings: ModeSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }

    public func environment(trigger: String) -> [String: String] {
        var values = settings.environment
        values["SCAN_TRIGGER"] = trigger
        values["SCAN_PROFILE_ID"] = id
        values["SCAN_PROFILE_NAME"] = name
        return values
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Scan mode"
        settings = try container.decodeIfPresent(ModeSettings.self, forKey: .settings) ?? .standard
    }
}

public struct ScanSettings: Codable, Equatable, Sendable {
    public var version: Int
    public var defaultModeID: String
    public var modes: [ScanMode]

    public init(
        version: Int = 1,
        defaultModeID: String = "",
        modes: [ScanMode] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let base = ModeSettings(environment: environment)
        let candidates = modes.isEmpty ? Self.builtInModes(environment: environment) : modes
        var normalizedModes: [ScanMode] = []
        var seen: Set<String> = []

        for (index, mode) in candidates.enumerated() {
            let name = Self.normalizedName(mode.name)
            var id = mode.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty {
                id = "mode-\(index + 1)"
            }
            if seen.contains(id) {
                id = Self.uniqueModeID(for: name, modes: normalizedModes)
            }
            seen.insert(id)
            normalizedModes.append(
                ScanMode(id: id, name: name, settings: mode.settings.normalized(defaults: base))
            )
        }

        self.version = 1
        self.modes = normalizedModes
        let requestedDefault = defaultModeID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultModeID = normalizedModes.contains { $0.id == requestedDefault }
            ? requestedDefault
            : normalizedModes[0].id
    }

    public static func defaults(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ScanSettings {
        ScanSettings(modes: builtInModes(environment: environment), environment: environment)
    }

    public static func builtInModes(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ScanMode] {
        let base = ModeSettings(environment: environment)

        func mode(_ id: String, _ name: String, _ overrides: [String: String] = [:]) -> ScanMode {
            ScanMode(id: id, name: name, settings: ModeSettings(values: overrides, defaults: base))
        }

        return [
            mode("duplex-pdf-ocr", "Duplex PDF + OCR"),
            mode("simplex-pdf-ocr", "Simplex PDF + OCR", [
                "SCAN_SOURCE": "ADF Simplex",
                "SCAN_SIMPLEX": "true",
                "SCAN_FORMAT": "pdf",
                "SCAN_PAGE_MODE": "multi",
                "SCAN_OCR_ENABLED": "true",
            ]),
            mode("photo-png", "Photo PNG", [
                "SCAN_SOURCE": "ADF Simplex",
                "SCAN_SIMPLEX": "true",
                "SCAN_RESOLUTION": "600",
                "SCAN_MODE": "Color",
                "SCAN_FORMAT": "png",
                "SCAN_PAGE_MODE": "single",
                "SCAN_OCR_ENABLED": "false",
                "SCAN_REMOVE_BLANK_PAGES": "false",
                "SCAN_CROP_PAGES": "false",
            ]),
            mode("duplex-pdf-no-ocr", "Duplex PDF", [
                "SCAN_FORMAT": "pdf",
                "SCAN_PAGE_MODE": "multi",
                "SCAN_OCR_ENABLED": "false",
            ]),
            mode("single-page-pdfs", "Single Page PDFs + OCR", [
                "SCAN_FORMAT": "pdf",
                "SCAN_PAGE_MODE": "single",
                "SCAN_OCR_ENABLED": "true",
            ]),
        ]
    }

    public var defaultMode: ScanMode {
        mode(id: defaultModeID) ?? modes[0]
    }

    public func mode(id: String) -> ScanMode? {
        modes.first { $0.id == id }
    }

    @discardableResult
    public mutating func setDefaultMode(id: String) -> Bool {
        guard mode(id: id) != nil else { return false }
        defaultModeID = id
        return true
    }

    @discardableResult
    public mutating func saveMode(
        name: String,
        settings: ModeSettings,
        existingID: String? = nil,
        setDefault: Bool = false
    ) -> String {
        let normalizedName = Self.normalizedName(name)
        let id: String
        if let existingID,
           let index = modes.firstIndex(where: { $0.id == existingID.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            id = modes[index].id
            modes[index] = ScanMode(id: id, name: normalizedName, settings: settings.normalized(defaults: .standard))
        } else {
            id = Self.uniqueModeID(for: normalizedName, modes: modes)
            modes.append(ScanMode(id: id, name: normalizedName, settings: settings.normalized(defaults: .standard)))
        }
        if setDefault {
            defaultModeID = id
        }
        return id
    }

    @discardableResult
    public mutating func deleteMode(id: String) -> Bool {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, modes.count > 1, let index = modes.firstIndex(where: { $0.id == id }) else {
            return false
        }
        modes.remove(at: index)
        if defaultModeID == id {
            defaultModeID = modes[0].id
        }
        return true
    }

    public func normalized(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ScanSettings {
        ScanSettings(version: version, defaultModeID: defaultModeID, modes: modes, environment: environment)
    }

    public static func slugifyModeName(_ name: String) -> String {
        var result = ""
        var pendingSeparator = false
        for scalar in name.lowercased().unicodeScalars {
            let isASCIIAlpha = (97...122).contains(scalar.value)
            let isASCIIDigit = (48...57).contains(scalar.value)
            if isASCIIAlpha || isASCIIDigit {
                if pendingSeparator, !result.isEmpty {
                    result.append("-")
                }
                result.unicodeScalars.append(scalar)
                pendingSeparator = false
            } else {
                pendingSeparator = true
            }
        }
        return result.isEmpty ? "scan-mode" : result
    }

    public static func uniqueModeID(
        for name: String,
        modes: [ScanMode],
        existingID: String? = nil
    ) -> String {
        let base = slugifyModeName(name)
        let used = Set(modes.lazy.filter { $0.id != existingID }.map(\.id))
        guard used.contains(base) else { return base }
        var index = 2
        while used.contains("\(base)-\(index)") {
            index += 1
        }
        return "\(base)-\(index)"
    }

    private static func normalizedName(_ name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Scan mode" : name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let defaultModeID = try container.decodeIfPresent(String.self, forKey: .defaultModeID) ?? ""
        let modes = try container.decodeIfPresent([ScanMode].self, forKey: .modes) ?? []
        let environment = decoder.userInfo[SettingsCoding.environmentUserInfoKey] as? [String: String] ?? [:]
        self.init(version: version, defaultModeID: defaultModeID, modes: modes, environment: environment)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case defaultModeID = "default_mode_id"
        case modes
    }
}
