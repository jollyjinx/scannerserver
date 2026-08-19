import Foundation
import ScannerServerCore
import Testing

@Suite("Scan settings")
struct ScanSettingsTests {
    @Test("Built-in modes and button default preserve the legacy contract")
    func builtIns() {
        let settings = ScanSettings.defaults(environment: [:])

        #expect(settings.version == 1)
        #expect(settings.modes.map(\.id) == [
            "duplex-pdf-ocr",
            "simplex-pdf-ocr",
            "photo-png",
            "duplex-pdf-no-ocr",
            "single-page-pdfs",
        ])
        #expect(settings.defaultModeID == "duplex-pdf-ocr")
        #expect(settings.defaultMode.name == "Duplex PDF + OCR")
        #expect(settings.mode(id: "photo-png")?.settings.resolution == "600")
        #expect(settings.mode(id: "photo-png")?.settings.format == "png")
        #expect(settings.mode(id: "photo-png")?.settings.ocrEnabled == false)
        #expect(settings.defaultMode.settings.cropMarginPoints == 1.0)
        #expect(settings.blankPageSettings == .standard)
    }

    @Test("Built-in modes inherit environment defaults")
    func environmentDefaults() {
        let settings = ScanSettings.defaults(environment: [
            "SCAN_LANGUAGE": "fra+eng",
            "SCAN_RESOLUTION": "400",
            "SCAN_CROP_PAGES": "false",
            "SCAN_CROP_MARGIN_POINTS": "3.5",
            "SCAN_OCR_CPU_LIMIT": "4",
            "SCAN_OCR_NICE": "true",
            "SCAN_BLANK_WHITE_THRESHOLD": "220",
            "SCAN_BLANK_CONTENT_RATIO_THRESHOLD": "0.005",
            "SCAN_BLANK_MEAN_THRESHOLD": "245.5",
        ])

        #expect(settings.defaultMode.settings.language == "fra+eng")
        #expect(settings.defaultMode.settings.resolution == "400")
        #expect(!settings.defaultMode.settings.cropPages)
        #expect(settings.defaultMode.settings.cropMarginPoints == 3.5)
        #expect(settings.defaultMode.settings.ocrCPULimit == nil)
        #expect(settings.defaultMode.settings.ocrNice)
        #expect(settings.mode(id: "photo-png")?.settings.resolution == "600")
        #expect(settings.blankPageSettings == BlankPageSettings(
            whiteThreshold: 220,
            contentRatioThreshold: 0.005,
            meanThreshold: 245.5
        ))
    }

    @Test("Existing settings JSON normalizes duplicate IDs and invalid values")
    func existingJSONShape() throws {
        let data = Data(#"""
        {
          "version": 1,
          "default_mode_id": "missing",
          "modes": [
            {
              "id": "receipt",
              "name": " Receipt ",
              "settings": {
                "SCAN_LANGUAGE": "eng",
                "SCAN_RESOLUTION": "300",
                "SCAN_MODE": "Gray",
                "SCAN_SOURCE": "ADF Duplex",
                "SCAN_SIMPLEX": "false",
                "SCAN_FORMAT": "images",
                "SCAN_PAGE_MODE": "invalid",
                "SCAN_OCR_ENABLED": "yes",
                "SCAN_REMOVE_BLANK_PAGES": "0",
                "SCAN_CROP_PAGES": "on"
              }
            },
            {
              "id": "receipt",
              "name": "Receipt",
              "settings": {}
            }
          ]
        }
        """#.utf8)

        let settings = try JSONDecoder().decode(ScanSettings.self, from: data)

        #expect(settings.modes.map(\.id) == ["receipt", "receipt-2"])
        #expect(settings.defaultModeID == "receipt")
        #expect(settings.modes[0].name == "Receipt")
        #expect(settings.modes[0].settings.format == "png")
        #expect(settings.modes[0].settings.pageMode == "multi")
        #expect(settings.modes[0].settings.ocrEnabled)
        #expect(!settings.modes[0].settings.removeBlankPages)
        #expect(settings.modes[0].settings.cropMarginPoints == 1.0)
        #expect(settings.blankPageSettings == .standard)
    }

    @Test("Save, update, delete, and default operations preserve IDs")
    func editingSemantics() {
        var settings = ScanSettings.defaults(environment: [:])
        let newID = settings.saveMode(
            name: " Receipts & Notes ",
            settings: ModeSettings(format: "png"),
            setDefault: true
        )

        #expect(newID == "receipts-notes")
        #expect(settings.defaultModeID == newID)
        let updatedID = settings.saveMode(name: "Renamed", settings: .standard, existingID: newID)
        #expect(updatedID == newID)
        #expect(settings.mode(id: newID)?.name == "Renamed")
        let setMissingDefault = settings.setDefaultMode(id: "missing")
        #expect(!setMissingDefault)
        let deleted = settings.deleteMode(id: newID)
        #expect(deleted)
        #expect(settings.defaultModeID == "duplex-pdf-ocr")
        #expect(settings.mode(id: newID) == nil)
    }

    @Test("Unique slugs use stable numeric suffixes")
    func uniqueSlugs() {
        var settings = ScanSettings.defaults(environment: [:])
        let first = settings.saveMode(name: "Ä / !", settings: .standard)
        let second = settings.saveMode(name: "Ä / !", settings: .standard)
        let third = settings.saveMode(name: "Ä / !", settings: .standard)

        #expect(first == "scan-mode")
        #expect(second == "scan-mode-2")
        #expect(third == "scan-mode-3")
    }

    @Test("Missing files create defaults and malformed files fall back")
    func persistenceFallbacks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanSettingsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".scanner-settings.json")
        let store = ScanSettingsStore(fileURL: file, environment: [:])

        let created = try await store.load()
        #expect(created == ScanSettings.defaults(environment: [:]))
        #expect(FileManager.default.fileExists(atPath: file.path))

        try Data("not json".utf8).write(to: file)
        let recovered = try await store.load()
        #expect(recovered == ScanSettings.defaults(environment: [:]))
    }

    @Test("Saved JSON round-trips with snake-case keys and no temporary residue")
    func persistenceRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanSettingsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = ScanSettingsStore(fileURL: file, environment: [:])
        var settings = ScanSettings.defaults(environment: [:])
        _ = settings.setDefaultMode(id: "photo-png")
        settings.blankPageSettings = BlankPageSettings(
            whiteThreshold: 215,
            contentRatioThreshold: 0.0045,
            meanThreshold: 244.5
        )

        let saved = try await store.save(settings)
        let loaded = try await store.load()
        let text = try String(contentsOf: file, encoding: .utf8)

        #expect(saved == loaded)
        #expect(text.contains(#""default_mode_id" : "photo-png""#))
        #expect(text.contains(#""blank_page_settings""#))
        #expect(text.contains(#""SCAN_BLANK_WHITE_THRESHOLD" : "215""#))
        #expect(!FileManager.default.fileExists(atPath: file.path + ".tmp"))
    }

    @Test("Store paths and partial JSON inherit the service environment")
    func environmentPathsAndPartialJSON() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanSettingsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("custom-settings.json")
        let environment = [
            "SCAN_OUTPUT_DIR": directory.path,
            "SCAN_SETTINGS_PATH": file.path,
            "SCAN_LANGUAGE": "nld+eng",
            "SCAN_OCR_CPU_LIMIT": "4",
            "SCAN_OCR_NICE": "true",
            "SCAN_BLANK_WHITE_THRESHOLD": "225",
            "SCAN_BLANK_CONTENT_RATIO_THRESHOLD": "0.002",
            "SCAN_BLANK_MEAN_THRESHOLD": "250",
        ]
        #expect(ScanSettingsStore.defaultFileURL(environment: environment) == file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"modes":[{"id":"custom","name":"Custom","settings":{"SCAN_FORMAT":"png"}}]}"#.utf8)
            .write(to: file)
        let store = ScanSettingsStore(environment: environment)

        let loaded = try await store.load()
        #expect(loaded.defaultModeID == "custom")
        #expect(loaded.defaultMode.settings.language == "nld+eng")
        #expect(loaded.defaultMode.settings.format == "png")
        #expect(loaded.defaultMode.settings.ocrCPULimit == nil)
        #expect(loaded.defaultMode.settings.ocrNice)
        #expect(loaded.blankPageSettings == BlankPageSettings(
            whiteThreshold: 225,
            contentRatioThreshold: 0.002,
            meanThreshold: 250
        ))
    }

    @Test("Shared blank-page thresholds override process values for every trigger")
    func sharedBlankPageEnvironment() {
        let settings = ScanSettings(
            blankPageSettings: BlankPageSettings(
                whiteThreshold: 210,
                contentRatioThreshold: 0.006,
                meanThreshold: 242
            ),
            environment: [:]
        )

        for trigger in ["web", "pdf-import", "button"] {
            let values = settings.environment(for: settings.defaultMode, trigger: trigger)
            #expect(values["SCAN_TRIGGER"] == trigger)
            #expect(values["SCAN_BLANK_WHITE_THRESHOLD"] == "210")
            #expect(values["SCAN_BLANK_CONTENT_RATIO_THRESHOLD"] == "0.006")
            #expect(values["SCAN_BLANK_MEAN_THRESHOLD"] == "242")
        }
    }

    @Test("Blank-page settings accept compatible JSON and reject invalid form values")
    func blankPageSettingsCompatibility() throws {
        let decoded = try JSONDecoder().decode(BlankPageSettings.self, from: Data(#"""
        {
          "SCAN_BLANK_WHITE_THRESHOLD": 205,
          "SCAN_BLANK_CONTENT_RATIO_THRESHOLD": "0.0075",
          "SCAN_BLANK_MEAN_THRESHOLD": 241.5
        }
        """#.utf8))

        #expect(decoded == BlankPageSettings(
            whiteThreshold: 205,
            contentRatioThreshold: 0.0075,
            meanThreshold: 241.5
        ))
        #expect(BlankPageSettings(
            validatingWhiteThreshold: 256,
            contentRatioThreshold: 0.003,
            meanThreshold: 248
        ) == nil)
        #expect(BlankPageSettings(
            validatingWhiteThreshold: 230,
            contentRatioThreshold: -0.01,
            meanThreshold: 248
        ) == nil)
    }

    @Test("Store updates shared blank-page thresholds without changing presets")
    func saveBlankPageSettings() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanSettingsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScanSettingsStore(
            fileURL: directory.appendingPathComponent("settings.json"),
            environment: [:]
        )
        let original = try await store.load()
        let blankPageSettings = BlankPageSettings(
            whiteThreshold: 208,
            contentRatioThreshold: 0.008,
            meanThreshold: 239
        )

        try await store.saveBlankPageSettings(blankPageSettings)
        let loaded = try await store.load()

        #expect(loaded.blankPageSettings == blankPageSettings)
        #expect(loaded.modes == original.modes)
        #expect(loaded.defaultModeID == original.defaultModeID)
    }

    @Test("Concurrent store mutations preserve every mode update")
    func concurrentMutations() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanSettingsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScanSettingsStore(
            fileURL: directory.appendingPathComponent("settings.json"),
            environment: [:]
        )

        _ = try await store.load()
        async let first = store.saveMode(
            name: "Receipts",
            settings: .standard,
            existingID: nil,
            setDefault: false
        )
        async let second = store.saveMode(
            name: "Letters",
            settings: .standard,
            existingID: nil,
            setDefault: false
        )
        let identifiers = try await [first, second]
        let loaded = try await store.load()

        #expect(Set(identifiers) == ["receipts", "letters"])
        #expect(loaded.mode(id: "receipts") != nil)
        #expect(loaded.mode(id: "letters") != nil)
    }
}
