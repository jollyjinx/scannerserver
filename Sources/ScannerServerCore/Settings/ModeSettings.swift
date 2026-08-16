import Foundation

enum SettingsCoding {
    static let environmentUserInfoKey = CodingUserInfoKey(
        rawValue: "ScannerServerCore.Settings.environment"
    )!
}

public struct ModeSettings: Codable, Equatable, Sendable {
    public enum EnvironmentKey: String, CaseIterable, Sendable {
        case language = "SCAN_LANGUAGE"
        case resolution = "SCAN_RESOLUTION"
        case mode = "SCAN_MODE"
        case source = "SCAN_SOURCE"
        case simplex = "SCAN_SIMPLEX"
        case format = "SCAN_FORMAT"
        case pageMode = "SCAN_PAGE_MODE"
        case ocrEnabled = "SCAN_OCR_ENABLED"
        case ocrCPULimit = "SCAN_OCR_CPU_LIMIT"
        case ocrNice = "SCAN_OCR_NICE"
        case removeBlankPages = "SCAN_REMOVE_BLANK_PAGES"
        case cropPages = "SCAN_CROP_PAGES"
        case cropMarginPoints = "SCAN_CROP_MARGIN_POINTS"
        case ocrOnly = "SCAN_OCR_ONLY"
    }

    public static let truthyValues: Set<String> = ["1", "true", "yes", "on"]

    public var language: String
    public var resolution: String
    public var mode: String
    public var source: String
    public var simplex: Bool
    public var format: String
    public var pageMode: String
    public var ocrEnabled: Bool
    public var ocrCPULimit: Int?
    public var ocrNice: Bool
    public var removeBlankPages: Bool
    public var cropPages: Bool
    public var cropMarginPoints: Double
    public var ocrOnly: Bool

    public init(
        language: String = "deu+eng",
        resolution: String = "300",
        mode: String = "Color",
        source: String = "ADF Duplex",
        simplex: Bool = false,
        format: String = "pdf",
        pageMode: String = "multi",
        ocrEnabled: Bool = true,
        ocrCPULimit: Int? = nil,
        ocrNice: Bool = false,
        removeBlankPages: Bool = true,
        cropPages: Bool = true,
        cropMarginPoints: Double = 1.0,
        ocrOnly: Bool = true
    ) {
        self.language = language
        self.resolution = resolution
        self.mode = mode
        self.source = source
        self.simplex = simplex
        self.format = format
        self.pageMode = pageMode
        self.ocrEnabled = ocrEnabled
        self.ocrCPULimit = Self.validOCRCPULimit(ocrCPULimit)
        self.ocrNice = ocrNice
        self.removeBlankPages = removeBlankPages
        self.cropPages = cropPages
        self.cropMarginPoints = Self.validCropMarginPoints(
            cropMarginPoints,
            fallback: 1.0
        )
        self.ocrOnly = ocrOnly
    }

    public init(values: [String: String], defaults: ModeSettings = .standard) {
        func value(_ key: EnvironmentKey, fallback: String) -> String {
            guard let value = values[key.rawValue] else { return fallback }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        }

        language = value(.language, fallback: defaults.language)
        resolution = value(.resolution, fallback: defaults.resolution)
        mode = value(.mode, fallback: defaults.mode)
        source = value(.source, fallback: defaults.source)
        simplex = Self.isTruthy(values[EnvironmentKey.simplex.rawValue] ?? defaults.simplexText)

        let requestedFormat = value(.format, fallback: defaults.format).lowercased()
        let aliasedFormat = ["image", "images"].contains(requestedFormat) ? "png" : requestedFormat
        format = ["pdf", "png"].contains(aliasedFormat) ? aliasedFormat : defaults.validFormat

        let requestedPageMode = value(.pageMode, fallback: defaults.pageMode).lowercased()
        pageMode = ["multi", "single"].contains(requestedPageMode)
            ? requestedPageMode
            : defaults.validPageMode

        ocrEnabled = Self.isTruthy(values[EnvironmentKey.ocrEnabled.rawValue] ?? defaults.ocrEnabledText)
        if let rawCPULimit = values[EnvironmentKey.ocrCPULimit.rawValue] {
            let trimmed = rawCPULimit.trimmingCharacters(in: .whitespacesAndNewlines)
            ocrCPULimit = trimmed.isEmpty
                ? nil
                : Self.validOCRCPULimit(Int(trimmed)) ?? defaults.ocrCPULimit
        } else {
            ocrCPULimit = defaults.ocrCPULimit
        }
        ocrNice = Self.isTruthy(values[EnvironmentKey.ocrNice.rawValue] ?? defaults.ocrNiceText)
        removeBlankPages = Self.isTruthy(
            values[EnvironmentKey.removeBlankPages.rawValue] ?? defaults.removeBlankPagesText
        )
        cropPages = Self.isTruthy(values[EnvironmentKey.cropPages.rawValue] ?? defaults.cropPagesText)
        let requestedCropMargin = Double(value(
            .cropMarginPoints,
            fallback: defaults.cropMarginPointsText
        ))
        cropMarginPoints = Self.validCropMarginPoints(
            requestedCropMargin,
            fallback: defaults.cropMarginPoints
        )
        ocrOnly = Self.isTruthy(values[EnvironmentKey.ocrOnly.rawValue] ?? defaults.ocrOnlyText)
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(values: environment, defaults: .standard)
    }

    public static let standard = ModeSettings(language: "deu+eng")

    public static func isTruthy(_ value: String) -> Bool {
        truthyValues.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func booleanText(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    public static func source(forSimplex simplex: Bool) -> String {
        simplex ? "ADF Simplex" : "ADF Duplex"
    }

    public var environment: [String: String] {
        [
            EnvironmentKey.language.rawValue: language,
            EnvironmentKey.resolution.rawValue: resolution,
            EnvironmentKey.mode.rawValue: mode,
            EnvironmentKey.source.rawValue: source,
            EnvironmentKey.simplex.rawValue: simplexText,
            EnvironmentKey.format.rawValue: format,
            EnvironmentKey.pageMode.rawValue: pageMode,
            EnvironmentKey.ocrEnabled.rawValue: ocrEnabledText,
            EnvironmentKey.ocrCPULimit.rawValue: ocrCPULimitText,
            EnvironmentKey.ocrNice.rawValue: ocrNiceText,
            EnvironmentKey.removeBlankPages.rawValue: removeBlankPagesText,
            EnvironmentKey.cropPages.rawValue: cropPagesText,
            EnvironmentKey.cropMarginPoints.rawValue: cropMarginPointsText,
            EnvironmentKey.ocrOnly.rawValue: ocrOnlyText,
        ]
    }

    public func normalized(defaults: ModeSettings) -> ModeSettings {
        ModeSettings(values: environment, defaults: defaults)
    }

    public var simplexText: String { Self.booleanText(simplex) }
    public var ocrEnabledText: String { Self.booleanText(ocrEnabled) }
    public var ocrCPULimitText: String { ocrCPULimit.map(String.init) ?? "" }
    public var ocrNiceText: String { Self.booleanText(ocrNice) }
    public var removeBlankPagesText: String { Self.booleanText(removeBlankPages) }
    public var cropPagesText: String { Self.booleanText(cropPages) }
    public var ocrOnlyText: String { Self.booleanText(ocrOnly) }
    public var cropMarginPointsText: String {
        String(
            format: "%.12g",
            locale: Locale(identifier: "en_US_POSIX"),
            cropMarginPoints
        )
    }

    private static func validCropMarginPoints(_ value: Double?, fallback: Double) -> Double {
        guard let value, value.isFinite, value >= 0 else { return fallback }
        return value
    }

    private static func validOCRCPULimit(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private var validFormat: String {
        ["pdf", "png"].contains(format) ? format : "pdf"
    }

    private var validPageMode: String {
        ["multi", "single"].contains(pageMode) ? pageMode : "multi"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var values: [String: String] = [:]
        for key in CodingKeys.allCases {
            if let value = try container.compatibleStringIfPresent(forKey: key) {
                values[key.rawValue] = value
            }
        }
        if values[EnvironmentKey.ocrCPULimit.rawValue] == nil {
            values[EnvironmentKey.ocrCPULimit.rawValue] = ""
        }
        let defaults = (decoder.userInfo[SettingsCoding.environmentUserInfoKey] as? [String: String])
            .map(ModeSettings.init(environment:))
            ?? .standard
        self.init(values: values, defaults: defaults)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        for key in CodingKeys.allCases {
            try container.encode(environment[key.rawValue]!, forKey: key)
        }
    }

    fileprivate enum CodingKeys: String, CodingKey, CaseIterable {
        case language = "SCAN_LANGUAGE"
        case resolution = "SCAN_RESOLUTION"
        case mode = "SCAN_MODE"
        case source = "SCAN_SOURCE"
        case simplex = "SCAN_SIMPLEX"
        case format = "SCAN_FORMAT"
        case pageMode = "SCAN_PAGE_MODE"
        case ocrEnabled = "SCAN_OCR_ENABLED"
        case ocrCPULimit = "SCAN_OCR_CPU_LIMIT"
        case ocrNice = "SCAN_OCR_NICE"
        case removeBlankPages = "SCAN_REMOVE_BLANK_PAGES"
        case cropPages = "SCAN_CROP_PAGES"
        case cropMarginPoints = "SCAN_CROP_MARGIN_POINTS"
        case ocrOnly = "SCAN_OCR_ONLY"
    }
}

private extension KeyedDecodingContainer where Key == ModeSettings.CodingKeys {
    func compatibleStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Bool.self, forKey: key) { return value ? "true" : "false" }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        return nil
    }
}
