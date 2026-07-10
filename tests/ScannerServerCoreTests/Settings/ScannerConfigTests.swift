import Foundation
import ScannerServerCore
import Testing

@Suite("Scanner configuration")
struct ScannerConfigTests {
    @Test("Environment configuration requires IP and key and honors key precedence")
    func environmentPrecedence() throws {
        #expect(ScannerConfig.fromEnvironment(["SCANNER_IP": "192.168.1.2"]) == nil)

        let legacy = try #require(ScannerConfig.fromEnvironment([
            "SCANNER_IP": " 192.168.1.2 ",
            "SCAN_PAIRING_KEY": " legacy ",
        ]))
        #expect(legacy.pairingKey == "legacy")

        let preferred = try #require(ScannerConfig.fromEnvironment([
            "SCANNER_IP": "192.168.1.2",
            "SCANSNAP_PAIRING_KEY": "preferred",
            "SCAN_PAIRING_KEY": "legacy",
        ]))
        #expect(preferred.source == "env")
        #expect(preferred.pairingKey == "preferred")
        #expect(preferred.environmentOverrides == [
            "SCANNER_IP": "192.168.1.2",
            "SCANSNAP_PAIRING_KEY": "preferred",
        ])
    }

    @Test("Legacy scanner JSON aliases ip and repairs configured-without-key")
    func legacyJSON() throws {
        let data = Data(#"""
        {
          "version": 8,
          "status": "configured",
          "ip": " 192.168.4.5 ",
          "mac": "84:25:3F:00:11:22",
          "serial": "ABC1234",
          "name": "",
          "pairing_key": ""
        }
        """#.utf8)
        let config = try JSONDecoder().decode(ScannerConfig.self, from: data)

        #expect(config.version == 1)
        #expect(config.status == .needsPassword)
        #expect(config.scannerIP == "192.168.4.5")
        #expect(config.name == "ScanSnap")
        #expect(config.pairingKeyMasked.isEmpty)
    }

    @Test("MAC normalization matches app.py")
    func macNormalization() throws {
        #expect(try ScannerConfig.normalizeMACAddress("84-25-3F 00.11.22") == "84:25:3f:00:11:22")
        #expect(throws: SettingsValidationError.invalidMACAddress) {
            try ScannerConfig.normalizeMACAddress("84:25:3f")
        }
        #expect(ScannerConfig.normalizeMACPrefixes(" 84-25-3F,00:80:92 ,, ") == ["84:25:3f", "00:80:92"])
    }

    @Test("IPv4 normalization rejects malformed, IPv6, and ambiguous leading zeros")
    func ipv4Normalization() throws {
        #expect(try ScannerConfig.normalizeIPv4Address(" 192.168.1.20 ") == "192.168.1.20")
        #expect(try ScannerConfig.normalizeIPv4Address("") == "")
        #expect(throws: SettingsValidationError.invalidIPv4Address) {
            try ScannerConfig.normalizeIPv4Address("192.168.001.20")
        }
        #expect(throws: SettingsValidationError.invalidIPv4Address) {
            try ScannerConfig.normalizeIPv4Address("192.168.1.256")
        }
        #expect(throws: SettingsValidationError.ipv4Required) {
            try ScannerConfig.normalizeIPv4Address("::1")
        }
    }

    @Test("Password and pairing key derivation match the iX500 protocol")
    func pairingKey() throws {
        #expect(ScannerConfig.identityKey == "pFusCANsNapFiPfu")
        #expect(ScannerConfig.password(fromSerial: "AWRHC08122 \0 ") == "8122")
        #expect(try ScannerConfig.derivePairingKey(password: "8122") == "179130178176")
        #expect(throws: SettingsValidationError.passwordTooLong(maximum: 16)) {
            try ScannerConfig.derivePairingKey(password: "12345678901234567")
        }
    }

    @Test("Stored config is atomic, normalized, and lower precedence than environment")
    func persistenceAndPrecedence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannerConfigTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".scannerserver-scanner.json")
        let environment = [
            "SCANNER_IP": "10.0.0.8",
            "SCANSNAP_PAIRING_KEY": "env-key",
        ]
        let store = ScannerConfigStore(fileURL: file, environment: environment)
        let saved = try await store.save(
            ScannerConfig(status: .configured, scannerIP: "10.0.0.7", pairingKey: "stored-key"),
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(saved.source == "stored")
        #expect(saved.updatedAt == "1970-01-01T00:00:00Z")
        let storedValue = await store.loadStored()
        let stored = try #require(storedValue)
        #expect(stored.scannerIP == "10.0.0.7")
        let activeValue = await store.activeConfiguration()
        let active = try #require(activeValue)
        #expect(active.source == "env")
        #expect(active.scannerIP == "10.0.0.8")

        try await store.clear()
        #expect(await store.loadStored() == nil)
    }

    @Test("Malformed scanner config falls back to no stored configuration")
    func malformedPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannerConfigTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("scanner.json")
        try Data("{".utf8).write(to: file)
        let store = ScannerConfigStore(fileURL: file, environment: [:])

        #expect(await store.loadStored() == nil)
        #expect(await store.activeConfiguration() == nil)
    }

    @Test("Scanner config path follows app.py environment precedence")
    func environmentPath() {
        #expect(
            ScannerConfigStore.defaultFileURL(environment: ["SCAN_OUTPUT_DIR": "/tmp/scans"]).path
                == "/tmp/scans/.scannerserver-scanner.json"
        )
        #expect(
            ScannerConfigStore.defaultFileURL(environment: [
                "SCAN_OUTPUT_DIR": "/ignored",
                "SCANNER_CONFIG_PATH": "/tmp/custom-scanner.json",
            ]).path == "/tmp/custom-scanner.json"
        )
    }
}
