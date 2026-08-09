import Foundation

public struct ScanPipelineConfiguration: Equatable, Sendable {
    public static let settingKeys = [
        "SCAN_LANGUAGE",
        "SCAN_RESOLUTION",
        "SCAN_MODE",
        "SCAN_SOURCE",
        "SCAN_SIMPLEX",
        "SCAN_FORMAT",
        "SCAN_PAGE_MODE",
        "SCAN_OCR_ENABLED",
        "SCAN_REMOVE_BLANK_PAGES",
        "SCAN_CROP_PAGES",
        "SCAN_CROP_MARGIN_POINTS",
    ]

    public let language: String
    public let resolution: String
    public let mode: String
    public let source: String
    public let simplex: Bool
    public let format: String
    public let pageMode: String
    public let ocrEnabled: Bool
    public let removeBlankPages: Bool
    public let cropPages: Bool
    public let environment: [String: String]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        modeOverrides: [String: String] = [:]
    ) {
        func baseString(_ key: String, default defaultValue: String) -> String {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                return defaultValue
            }
            return value
        }

        func string(_ key: String, default defaultValue: String) -> String {
            let base = baseString(key, default: defaultValue)
            guard let override = modeOverrides[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !override.isEmpty
            else {
                return base
            }
            return override
        }

        func boolean(_ key: String, default defaultValue: Bool) -> Bool {
            if let override = modeOverrides[key] {
                return Self.isTruthy(override)
            }
            if let value = environment[key] {
                return Self.isTruthy(value)
            }
            return defaultValue
        }

        language = string("SCAN_LANGUAGE", default: "deu+eng")
        resolution = string("SCAN_RESOLUTION", default: "300")
        mode = string("SCAN_MODE", default: "Color")
        source = string("SCAN_SOURCE", default: "ADF Duplex")
        simplex = boolean("SCAN_SIMPLEX", default: false)
        ocrEnabled = boolean("SCAN_OCR_ENABLED", default: true)
        removeBlankPages = boolean("SCAN_REMOVE_BLANK_PAGES", default: true)
        cropPages = boolean("SCAN_CROP_PAGES", default: true)

        let requestedFormat = string("SCAN_FORMAT", default: "pdf").lowercased()
        switch requestedFormat {
        case "image", "images", "png":
            format = "png"
        case "pdf":
            format = "pdf"
        default:
            format = "pdf"
        }

        let requestedPageMode = string("SCAN_PAGE_MODE", default: "multi").lowercased()
        pageMode = ["multi", "single"].contains(requestedPageMode) ? requestedPageMode : "multi"

        var processEnvironment = environment
        processEnvironment.merge(modeOverrides) { _, override in override }
        processEnvironment["SCAN_LANGUAGE"] = language
        processEnvironment["SCAN_RESOLUTION"] = resolution
        processEnvironment["SCAN_MODE"] = mode
        processEnvironment["SCAN_SOURCE"] = source
        processEnvironment["SCAN_SIMPLEX"] = Self.boolText(simplex)
        processEnvironment["SCAN_FORMAT"] = format
        processEnvironment["SCAN_PAGE_MODE"] = pageMode
        processEnvironment["SCAN_OCR_ENABLED"] = Self.boolText(ocrEnabled)
        processEnvironment["SCAN_REMOVE_BLANK_PAGES"] = Self.boolText(removeBlankPages)
        processEnvironment["SCAN_CROP_PAGES"] = Self.boolText(cropPages)
        self.environment = processEnvironment
    }

    public static func isTruthy(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": true
        default: false
        }
    }

    private static func boolText(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}
