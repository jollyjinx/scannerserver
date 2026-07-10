import ScannerServerCore
import Testing

@Suite("Scan pipeline configuration")
struct ScanPipelineConfigurationTests {
    @Test("Defaults match the shell scripts")
    func defaults() {
        let configuration = ScanPipelineConfiguration(environment: [:])

        #expect(configuration.language == "deu+eng")
        #expect(configuration.resolution == "300")
        #expect(configuration.mode == "Color")
        #expect(configuration.source == "ADF Duplex")
        #expect(!configuration.simplex)
        #expect(configuration.format == "pdf")
        #expect(configuration.pageMode == "multi")
        #expect(configuration.ocrEnabled)
        #expect(configuration.removeBlankPages)
        #expect(configuration.cropPages)
    }

    @Test("All supported truthy spellings normalize to true", arguments: ["1", "true", "TRUE", " yes ", "On"])
    func truthy(value: String) {
        let configuration = ScanPipelineConfiguration(
            environment: [:],
            modeOverrides: ["SCAN_SIMPLEX": value]
        )

        #expect(configuration.simplex)
        #expect(configuration.environment["SCAN_SIMPLEX"] == "true")
    }

    @Test("Mode overrides normalize aliases and invalid page modes")
    func normalizedOverrides() {
        let configuration = ScanPipelineConfiguration(
            environment: [
                "SCAN_PAGE_MODE": "single",
                "SCAN_OCR_ENABLED": "yes",
                "SCANNER_IP": "192.0.2.10",
            ],
            modeOverrides: [
                "SCAN_FORMAT": "Images",
                "SCAN_PAGE_MODE": "booklet",
                "SCAN_OCR_ENABLED": "off",
                "SCAN_TRIGGER": "button",
            ]
        )

        #expect(configuration.format == "png")
        #expect(configuration.pageMode == "multi")
        #expect(!configuration.ocrEnabled)
        #expect(configuration.environment["SCAN_FORMAT"] == "png")
        #expect(configuration.environment["SCAN_PAGE_MODE"] == "multi")
        #expect(configuration.environment["SCAN_OCR_ENABLED"] == "false")
        #expect(configuration.environment["SCANNER_IP"] == "192.0.2.10")
        #expect(configuration.environment["SCAN_TRIGGER"] == "button")
    }
}
