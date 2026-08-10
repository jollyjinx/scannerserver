import Foundation
import ScannerServerCore
import Testing

@Suite("Mode settings")
struct ModeSettingsTests {
    @Test("Defaults preserve the legacy service contract")
    func defaults() {
        let settings = ModeSettings(environment: [:])

        #expect(settings.language == "deu+eng")
        #expect(settings.resolution == "300")
        #expect(settings.mode == "Color")
        #expect(settings.source == "ADF Duplex")
        #expect(settings.simplex == false)
        #expect(settings.format == "pdf")
        #expect(settings.pageMode == "multi")
        #expect(settings.ocrEnabled)
        #expect(settings.ocrCPULimit == nil)
        #expect(settings.removeBlankPages)
        #expect(settings.cropPages)
        #expect(settings.cropMarginPoints == 1.0)
    }

    @Test("Truthy values are accepted case-insensitively", arguments: ["1", "true", "TRUE", " yes ", "On"])
    func truthyValues(value: String) {
        #expect(ModeSettings.isTruthy(value))
    }

    @Test("Other values are false", arguments: ["", "0", "false", "no", "enabled"])
    func falseValues(value: String) {
        #expect(!ModeSettings.isTruthy(value))
    }

    @Test("Environment values normalize aliases, choices, and string booleans")
    func environmentNormalization() {
        let settings = ModeSettings(environment: [
            "SCAN_LANGUAGE": " eng ",
            "SCAN_RESOLUTION": " 600 ",
            "SCAN_MODE": " Gray ",
            "SCAN_SOURCE": " ADF Simplex ",
            "SCAN_SIMPLEX": "yes",
            "SCAN_FORMAT": "Images",
            "SCAN_PAGE_MODE": "SINGLE",
            "SCAN_OCR_ENABLED": "off",
            "SCAN_OCR_CPU_LIMIT": "4",
            "SCAN_REMOVE_BLANK_PAGES": "1",
            "SCAN_CROP_PAGES": "false",
            "SCAN_CROP_MARGIN_POINTS": "2.5",
        ])

        #expect(settings.language == "eng")
        #expect(settings.resolution == "600")
        #expect(settings.mode == "Gray")
        #expect(settings.source == "ADF Simplex")
        #expect(settings.simplex)
        #expect(settings.format == "png")
        #expect(settings.pageMode == "single")
        #expect(!settings.ocrEnabled)
        #expect(settings.ocrCPULimit == 4)
        #expect(settings.removeBlankPages)
        #expect(!settings.cropPages)
        #expect(settings.cropMarginPoints == 2.5)
        #expect(settings.environment["SCAN_CROP_MARGIN_POINTS"] == "2.5")
    }

    @Test("JSON uses exact environment keys and string booleans")
    func jsonCompatibility() throws {
        let data = try JSONEncoder().encode(ModeSettings(simplex: true, ocrEnabled: false))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(Set(object.keys) == Set(ModeSettings.EnvironmentKey.allCases.map(\.rawValue)))
        #expect(object["SCAN_SIMPLEX"] == "true")
        #expect(object["SCAN_OCR_ENABLED"] == "false")
        #expect(object["SCAN_OCR_CPU_LIMIT"] == "")
        #expect(object["SCAN_REMOVE_BLANK_PAGES"] == "true")
        #expect(object["SCAN_CROP_MARGIN_POINTS"] == "1")
    }

    @Test("Existing numeric and boolean JSON values remain readable")
    func legacyJSONScalars() throws {
        let data = Data(#"{"SCAN_RESOLUTION":600,"SCAN_SIMPLEX":true,"SCAN_FORMAT":"image","SCAN_CROP_MARGIN_POINTS":0.5}"#.utf8)
        let settings = try JSONDecoder().decode(ModeSettings.self, from: data)

        #expect(settings.resolution == "600")
        #expect(settings.simplex)
        #expect(settings.format == "png")
        #expect(settings.language == "deu+eng")
        #expect(settings.ocrCPULimit == nil)
        #expect(settings.cropMarginPoints == 0.5)
    }

    @Test("OCR CPU limits accept positive numbers and preserve automatic mode", arguments: ["", "0", "-1", "invalid"])
    func ocrCPULimit(value: String) {
        let settings = ModeSettings(
            values: ["SCAN_OCR_CPU_LIMIT": value],
            defaults: ModeSettings(ocrCPULimit: nil)
        )

        #expect(settings.ocrCPULimit == nil)
        #expect(settings.ocrCPULimitText.isEmpty)
    }

    @Test("Invalid crop margins fall back without making a scan mode unusable", arguments: ["-1", "nan", "invalid"])
    func invalidCropMargin(value: String) {
        let settings = ModeSettings(
            values: ["SCAN_CROP_MARGIN_POINTS": value],
            defaults: ModeSettings(cropMarginPoints: 2.0)
        )

        #expect(settings.cropMarginPoints == 2.0)
    }
}
