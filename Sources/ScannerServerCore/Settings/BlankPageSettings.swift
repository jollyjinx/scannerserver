import Foundation

public struct BlankPageSettings: Codable, Equatable, Sendable {
    public static let standard = BlankPageSettings()

    public var whiteThreshold: Int
    public var contentRatioThreshold: Double
    public var meanThreshold: Double

    public init(
        whiteThreshold: Int = 230,
        contentRatioThreshold: Double = 0.003,
        meanThreshold: Double = 248.0
    ) {
        self.whiteThreshold = Self.validWhiteThreshold(whiteThreshold) ?? 230
        self.contentRatioThreshold = Self.validRatio(contentRatioThreshold) ?? 0.003
        self.meanThreshold = Self.validMeanThreshold(meanThreshold) ?? 248.0
    }

    public init?(
        validatingWhiteThreshold whiteThreshold: Int,
        contentRatioThreshold: Double,
        meanThreshold: Double
    ) {
        guard let whiteThreshold = Self.validWhiteThreshold(whiteThreshold),
              let contentRatioThreshold = Self.validRatio(contentRatioThreshold),
              let meanThreshold = Self.validMeanThreshold(meanThreshold)
        else {
            return nil
        }
        self.whiteThreshold = whiteThreshold
        self.contentRatioThreshold = contentRatioThreshold
        self.meanThreshold = meanThreshold
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(
            whiteThreshold: Int(environment["SCAN_BLANK_WHITE_THRESHOLD"] ?? "") ?? 230,
            contentRatioThreshold: Double(
                environment["SCAN_BLANK_CONTENT_RATIO_THRESHOLD"] ?? ""
            ) ?? 0.003,
            meanThreshold: Double(environment["SCAN_BLANK_MEAN_THRESHOLD"] ?? "") ?? 248.0
        )
    }

    public var environment: [String: String] {
        [
            "SCAN_BLANK_WHITE_THRESHOLD": String(whiteThreshold),
            "SCAN_BLANK_CONTENT_RATIO_THRESHOLD": contentRatioThresholdText,
            "SCAN_BLANK_MEAN_THRESHOLD": meanThresholdText,
        ]
    }

    public var contentRatioThresholdText: String {
        Self.decimal(contentRatioThreshold)
    }

    public var meanThresholdText: String {
        Self.decimal(meanThreshold)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let environment = decoder.userInfo[SettingsCoding.environmentUserInfoKey]
            as? [String: String] ?? [:]
        let defaults = Self(environment: environment)
        let whiteThreshold = try container.compatibleIntIfPresent(forKey: .whiteThreshold)
        let contentRatioThreshold = try container.compatibleDoubleIfPresent(
            forKey: .contentRatioThreshold
        )
        let meanThreshold = try container.compatibleDoubleIfPresent(forKey: .meanThreshold)
        self.whiteThreshold = Self.validWhiteThreshold(whiteThreshold)
            ?? defaults.whiteThreshold
        self.contentRatioThreshold = Self.validRatio(contentRatioThreshold)
            ?? defaults.contentRatioThreshold
        self.meanThreshold = Self.validMeanThreshold(meanThreshold)
            ?? defaults.meanThreshold
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(String(whiteThreshold), forKey: .whiteThreshold)
        try container.encode(contentRatioThresholdText, forKey: .contentRatioThreshold)
        try container.encode(meanThresholdText, forKey: .meanThreshold)
    }

    private static func validWhiteThreshold(_ value: Int?) -> Int? {
        guard let value, (0...255).contains(value) else { return nil }
        return value
    }

    private static func validRatio(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    private static func validMeanThreshold(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...255).contains(value) else { return nil }
        return value
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case whiteThreshold = "SCAN_BLANK_WHITE_THRESHOLD"
        case contentRatioThreshold = "SCAN_BLANK_CONTENT_RATIO_THRESHOLD"
        case meanThreshold = "SCAN_BLANK_MEAN_THRESHOLD"
    }
}

private extension KeyedDecodingContainer where Key == BlankPageSettings.CodingKeys {
    func compatibleIntIfPresent(forKey key: Key) throws -> Int? {
        guard let text = try compatibleStringIfPresent(forKey: key) else { return nil }
        return Int(text)
    }

    func compatibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard let text = try compatibleStringIfPresent(forKey: key) else { return nil }
        return Double(text)
    }

    func compatibleStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        return nil
    }
}
