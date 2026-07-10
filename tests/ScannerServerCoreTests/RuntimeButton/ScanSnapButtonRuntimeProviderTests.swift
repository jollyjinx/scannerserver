import Foundation
import ScannerServerCore
import Testing

@Suite("Button runtime providers")
struct ScanSnapButtonRuntimeProviderTests {
    @Test("Stored scanner configuration is used with explicit client environment")
    func storedScannerConfiguration() async throws {
        let directory = try runtimeButtonTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = [
            "SCANSNAP_CLIENT_IP": " 192.168.20.10 ",
            "SCANSNAP_CLIENT_MAC": "02-11-22-33-44-55",
            "SCANSNAP_CLIENT_INTERFACE": "en7",
        ]
        let store = ScannerConfigStore(
            fileURL: directory.appendingPathComponent("scanner.json"),
            environment: environment
        )
        _ = try await store.save(ScannerConfig(
            status: .configured,
            scannerIP: "192.168.20.44",
            pairingKey: "stored-key"
        ))
        let network = RuntimeButtonFakeNetwork()
        let provider = StoreBackedScanSnapButtonScannerConfigurationProvider(
            store: store,
            environment: environment,
            network: network
        )

        let configuration = try #require(try await provider.currentButtonScannerConfiguration())

        #expect(configuration.scannerIPAddress == "192.168.20.44")
        #expect(configuration.identity.value == "stored-key")
        #expect(configuration.clientIPAddress == "192.168.20.10")
        #expect(configuration.clientMACAddress == [2, 0x11, 0x22, 0x33, 0x44, 0x55])
        #expect(await network.requestedScannerIPAddresses.isEmpty)
        #expect(await network.requestedInterfaceNames.isEmpty)
    }

    @Test("Complete scanner environment takes precedence over stored configuration")
    func environmentScannerConfiguration() async throws {
        let directory = try runtimeButtonTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = [
            "SCANNER_IP": "192.168.30.50",
            "SCANSNAP_PAIRING_KEY": "environment-key",
            "SCAN_PAIRING_KEY": "legacy-key",
            "SCANSNAP_CLIENT_IP": "192.168.30.10",
            "SCANSNAP_CLIENT_MAC": "02:aa:bb:cc:dd:ee",
        ]
        let store = ScannerConfigStore(
            fileURL: directory.appendingPathComponent("scanner.json"),
            environment: environment
        )
        _ = try await store.save(ScannerConfig(
            status: .configured,
            scannerIP: "192.168.30.44",
            pairingKey: "stored-key"
        ))
        let provider = StoreBackedScanSnapButtonScannerConfigurationProvider(
            store: store,
            environment: environment,
            network: RuntimeButtonFakeNetwork()
        )

        let configuration = try #require(try await provider.currentButtonScannerConfiguration())

        #expect(configuration.scannerIPAddress == "192.168.30.50")
        #expect(configuration.identity.value == "environment-key")
    }

    @Test("Client IP and MAC are derived through the injected setup network provider")
    func derivesClientNetworkIdentity() async throws {
        let directory = try runtimeButtonTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = ["SCANSNAP_CLIENT_INTERFACE": "scan0"]
        let store = ScannerConfigStore(
            fileURL: directory.appendingPathComponent("scanner.json"),
            environment: environment
        )
        _ = try await store.save(ScannerConfig(
            status: .configured,
            scannerIP: "192.168.40.44",
            pairingKey: "stored-key"
        ))
        let network = RuntimeButtonFakeNetwork(
            derivedIPAddress: "192.168.40.10",
            derivedMACAddress: [2, 1, 2, 3, 4, 5]
        )
        let provider = StoreBackedScanSnapButtonScannerConfigurationProvider(
            store: store,
            environment: environment,
            network: network
        )

        let configuration = try #require(try await provider.currentButtonScannerConfiguration())

        #expect(configuration.clientIPAddress == "192.168.40.10")
        #expect(configuration.clientMACAddress == [2, 1, 2, 3, 4, 5])
        #expect(await network.requestedScannerIPAddresses == ["192.168.40.44"])
        #expect(await network.requestedInterfaceNames == ["scan0"])
    }

    @Test("Mode provider reloads the stored default mode")
    func storedDefaultMode() async throws {
        let directory = try runtimeButtonTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScanSettingsStore(
            fileURL: directory.appendingPathComponent("settings.json"),
            environment: [:]
        )
        var settings = ScanSettings.defaults(environment: [:])
        _ = settings.setDefaultMode(id: "photo-png")
        _ = try await store.save(settings)
        let provider = StoreBackedScanSnapButtonModeProvider(store: store)

        let mode = try await provider.currentButtonDefaultMode()

        #expect(mode.id == "photo-png")
        #expect(mode.settings.format == "png")
        #expect(mode.settings.resolution == "600")
    }
}
