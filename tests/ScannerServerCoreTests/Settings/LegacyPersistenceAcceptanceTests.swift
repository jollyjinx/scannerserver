import Foundation
import ScannerServerCore
import Testing

@Suite("Legacy persistence acceptance")
struct LegacyPersistenceAcceptanceTests {
    @Test("Python state and existing outputs survive a Swift service restart unchanged")
    func legacyStateSurvivesRestart() async throws {
        let fixture = try LegacyPersistenceFixture()
        defer { fixture.remove() }

        let settingsBytes = try Data(contentsOf: fixture.settingsURL)
        let scannerBytes = try Data(contentsOf: fixture.scannerURL)
        let firstSettingsStore = ScanSettingsStore(environment: fixture.environment)
        let firstScannerStore = ScannerConfigStore(environment: fixture.environment)

        let firstSettings = try await firstSettingsStore.load()
        let firstScanner = try #require(await firstScannerStore.loadStored())

        try verifySettings(firstSettings)
        verifyScanner(firstScanner)
        #expect(try Data(contentsOf: fixture.settingsURL) == settingsBytes)
        #expect(try Data(contentsOf: fixture.scannerURL) == scannerBytes)

        let restartedSettingsStore = ScanSettingsStore(environment: fixture.environment)
        let restartedScannerStore = ScannerConfigStore(environment: fixture.environment)
        let restartedSettings = try await restartedSettingsStore.load()
        let restartedScanner = try #require(await restartedScannerStore.loadStored())

        #expect(restartedSettings == firstSettings)
        #expect(restartedScanner == firstScanner)
        #expect(try Data(contentsOf: fixture.settingsURL) == settingsBytes)
        #expect(try Data(contentsOf: fixture.scannerURL) == scannerBytes)
        try verifyLegacySchema(at: fixture.settingsURL, scannerURL: fixture.scannerURL)
        try verifyExistingOutputs(in: fixture.scanDirectory)
    }

    private func verifySettings(_ settings: ScanSettings) throws {
        #expect(settings.version == 1)
        #expect(settings.defaultModeID == "receipts")
        #expect(settings.modes.map(\.id) == ["receipts", "archive-photo"])
        #expect(settings.modes.map(\.name) == ["Receipt archive", "Archive photo"])

        let receipts = try #require(settings.mode(id: "receipts"))
        #expect(receipts.settings.language == "deu+eng")
        #expect(receipts.settings.resolution == "400")
        #expect(receipts.settings.mode == "Gray")
        #expect(receipts.settings.source == "ADF Duplex")
        #expect(!receipts.settings.simplex)
        #expect(receipts.settings.format == "pdf")
        #expect(receipts.settings.pageMode == "multi")
        #expect(receipts.settings.ocrEnabled)
        #expect(receipts.settings.ocrCPULimit == nil)
        #expect(receipts.settings.removeBlankPages)
        #expect(!receipts.settings.cropPages)
        #expect(receipts.settings.cropMarginPoints == 1.0)

        let archivePhoto = try #require(settings.mode(id: "archive-photo"))
        #expect(archivePhoto.settings.language == "eng")
        #expect(archivePhoto.settings.resolution == "600")
        #expect(archivePhoto.settings.mode == "Color")
        #expect(archivePhoto.settings.source == "ADF Simplex")
        #expect(archivePhoto.settings.simplex)
        #expect(archivePhoto.settings.format == "png")
        #expect(archivePhoto.settings.pageMode == "single")
        #expect(!archivePhoto.settings.ocrEnabled)
        #expect(archivePhoto.settings.ocrCPULimit == nil)
        #expect(!archivePhoto.settings.removeBlankPages)
        #expect(archivePhoto.settings.cropPages)
        #expect(archivePhoto.settings.cropMarginPoints == 1.0)
    }

    private func verifyScanner(_ scanner: ScannerConfig) {
        #expect(scanner.version == 1)
        #expect(scanner.status == .configured)
        #expect(scanner.source == "stored")
        #expect(scanner.scannerIP == "192.0.2.44")
        #expect(scanner.mac == "84:25:3f:aa:bb:cc")
        #expect(scanner.serial == "TEST00001234")
        #expect(scanner.name == "ScanSnap iX500 Fixture")
        #expect(scanner.pairingKey == "179130178176")
        #expect(scanner.pairingKeyMasked == "17...76")
        #expect(scanner.passwordSource == "serial-suffix")
        #expect(scanner.lastError.isEmpty)
        #expect(scanner.updatedAt == "2026-01-02T03:04:05+00:00")
        #expect(scanner.environmentOverrides == [
            "SCANNER_IP": "192.0.2.44",
            "SCANSNAP_PAIRING_KEY": "179130178176",
        ])
    }

    private func verifyLegacySchema(at settingsURL: URL, scannerURL: URL) throws {
        let settingsObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        #expect(Set(settingsObject.keys) == ["default_mode_id", "modes", "version"])
        let modes = try #require(settingsObject["modes"] as? [[String: Any]])
        #expect(modes.count == 2)
        #expect(modes.allSatisfy { Set($0.keys) == ["id", "name", "settings"] })
        let expectedSettingKeys = Set(
            ModeSettings.EnvironmentKey.allCases
                .filter { $0 != .cropMarginPoints && $0 != .ocrCPULimit }
                .map(\.rawValue)
        )
        for mode in modes {
            let values = try #require(mode["settings"] as? [String: Any])
            #expect(Set(values.keys) == expectedSettingKeys)
            #expect(values.values.allSatisfy { $0 is String })
        }

        let scannerObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: scannerURL)) as? [String: Any]
        )
        #expect(Set(scannerObject.keys) == [
            "last_error",
            "mac",
            "name",
            "pairing_key",
            "pairing_key_masked",
            "password_source",
            "scanner_ip",
            "serial",
            "source",
            "status",
            "updated_at",
            "version",
        ])
    }

    private func verifyExistingOutputs(in scanDirectory: URL) throws {
        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(
            at: scanDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let files = try urls.compactMap { url -> ScanFile? in
            guard let name = try? ScanOutputFileName(rawValue: url.lastPathComponent) else {
                return nil
            }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            return ScanFile(name: name, modificationDate: values.contentModificationDate ?? .distantPast)
        }

        let groups = ScanFileGrouping.groups(for: files, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(groups.map(\.day) == ["Sunday, 2026-02-15", "Saturday, 2026-02-14"])
        #expect(groups.flatMap(\.files).map(\.title) == [
            "2026-02-15.101112.png",
            "2026-02-14.093015.pdf",
        ])

        let resolver = ScanOutputPathResolver(outputDirectory: scanDirectory)
        for document in groups.flatMap(\.files) {
            let resolved = try resolver.resolve(document.viewName)
            #expect(resolved.lastPathComponent == document.viewName)

            let previewName = PreviewOutputName(
                sourceFileName: try ScanOutputFileName(rawValue: document.previewName)
            )
            #expect(
                fileManager.fileExists(
                    atPath: scanDirectory.appendingPathComponent(previewName.relativePath).path
                )
            )
        }

        let documents = groups.flatMap(\.files)
        #expect(documents[0].files.map(\.name) == [
            "2026-02-15.101112-page-0001.png",
            "2026-02-15.101112-page-0002.png",
        ])
        #expect(documents[0].viewName == "2026-02-15.101112-page-0001.png")
        #expect(documents[0].previewName == "2026-02-15.101112-page-0001.png")
        #expect(documents[1].files.map(\.name) == [
            "2026-02-14.093015.pdf",
            "2026-02-14.093015.ocr.pdf",
        ])
        #expect(documents[1].viewName == "2026-02-14.093015.ocr.pdf")
        #expect(documents[1].previewName == "2026-02-14.093015.ocr.pdf")
    }
}

private struct LegacyPersistenceFixture {
    let root: URL
    let scanDirectory: URL
    let settingsURL: URL
    let scannerURL: URL
    let environment: [String: String]

    init() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "LegacyPersistenceAcceptanceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        scanDirectory = root.appendingPathComponent("scans", isDirectory: true)
        settingsURL = scanDirectory.appendingPathComponent(".scanner-settings.json")
        scannerURL = scanDirectory.appendingPathComponent(".scannerserver-scanner.json")
        environment = ["SCAN_OUTPUT_DIR": scanDirectory.path]

        try fileManager.createDirectory(at: scanDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: Self.fixtureURL(named: "legacy-scanner-settings.json"),
            to: settingsURL
        )
        try fileManager.copyItem(
            at: Self.fixtureURL(named: "legacy-scannerserver-scanner.json"),
            to: scannerURL
        )

        let outputNames = [
            "2026-02-14.093015.pdf",
            "2026-02-14.093015.ocr.pdf",
            "2026-02-15.101112-page-0001.png",
            "2026-02-15.101112-page-0002.png",
        ]
        for name in outputNames {
            try Data("legacy output: \(name)".utf8).write(
                to: scanDirectory.appendingPathComponent(name)
            )
        }

        let previewDirectory = scanDirectory.appendingPathComponent(
            PreviewOutputName.directoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        for name in [
            "2026-02-14.093015.ocr.pdf.jpg",
            "2026-02-15.101112-page-0001.png.jpg",
        ] {
            try Data("legacy preview: \(name)".utf8).write(
                to: previewDirectory.appendingPathComponent(name)
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func fixtureURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/\(name)")
    }
}
