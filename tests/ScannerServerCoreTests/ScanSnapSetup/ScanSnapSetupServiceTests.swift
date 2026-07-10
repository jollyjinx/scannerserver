import Foundation
import ScannerServerCore
import Testing

@Suite("Live ScanSnap setup service")
struct ScanSnapSetupServiceTests {
    @Test("Live application dependencies expose the network setup service")
    func liveDependencyComposition() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanSnapSetupComposition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = [
            "SCAN_OUTPUT_DIR": directory.path,
            "SCAN_SETTINGS_PATH": directory.appendingPathComponent("settings.json").path,
            "SCANNER_CONFIG_PATH": directory.appendingPathComponent("scanner.json").path,
        ]

        let dependencies = ScannerServerDependencies.live(environment: environment)
        let state = await dependencies.scannerSetup.state()

        #expect(state.serviceAvailable)
        #expect(!state.configured)
    }

    @Test("Automatic discovery starts once and skips configured scanners")
    func automaticDiscoveryGuard() async throws {
        let discovery = FakeScanSnapSetupDiscovery([.devices([])])
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: ["SCANSNAP_CLIENT_IP": "192.168.1.10"],
            store: store,
            network: FakeScanSnapSetupNetwork(),
            discovery: discovery,
            pairing: FakeScanSnapSetupPairing([])
        )

        await service.ensureDiscoveryStarted()
        await service.waitForDiscovery()
        await service.ensureDiscoveryStarted()
        #expect(await discovery.configurations.count == 1)

        _ = try await store.save(ScannerConfig(
            status: .configured,
            scannerIP: "192.168.1.44",
            pairingKey: "configured-key"
        ))
        let configuredDiscovery = FakeScanSnapSetupDiscovery([])
        let configuredService = ScanSnapSetupService(
            environment: [:],
            store: store,
            network: FakeScanSnapSetupNetwork(),
            discovery: configuredDiscovery,
            pairing: FakeScanSnapSetupPairing([])
        )
        await configuredService.ensureDiscoveryStarted()
        #expect(await configuredDiscovery.configurations.isEmpty)
    }

    @Test("Discovery is asynchronous, derives routes, filters ARP, and deduplicates")
    func discoveryStateRoutesAndDeduplication() async throws {
        let interface = try ScanSnapSetupIPv4Interface(
            name: "eth0",
            ipAddress: "192.168.1.10",
            prefixLength: 24
        )
        let neighbors = [
            try ScanSnapSetupARPNeighbor(
                ipAddress: "192.168.1.44",
                macAddress: "84:25:3f:00:11:22",
                state: "REACHABLE",
                interfaceName: "eth0"
            ),
            try ScanSnapSetupARPNeighbor(
                ipAddress: "192.168.1.45",
                macAddress: "de:ad:be:ef:00:01",
                state: "REACHABLE",
                interfaceName: "eth0"
            ),
            try ScanSnapSetupARPNeighbor(
                ipAddress: "192.168.1.46",
                macAddress: "84:25:3f:00:11:23",
                state: "FAILED",
                interfaceName: "eth0"
            ),
        ]
        let network = FakeScanSnapSetupNetwork(interfaces: [interface], neighbors: neighbors)
        let original = setupDevice(name: "Original")
        let updated = setupDevice(name: "Updated")
        let discovery = FakeScanSnapSetupDiscovery([.devices([original, updated])])
        let pairing = FakeScanSnapSetupPairing([])
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: [
                "SCANSNAP_DISCOVERY_TARGETS": "192.168.1.99",
                "SCANNER_IP": "192.168.1.88",
                "SCANSNAP_DISCOVERY_ROUNDS": "3",
                "SCANSNAP_DISCOVERY_TIMEOUT_SECONDS": "0.75",
                "SCANSNAP_DISCOVERY_SOURCE_PORT": "60000",
                "SCANSNAP_REGISTRATION_PORT": "60001",
            ],
            store: store,
            network: network,
            discovery: discovery,
            pairing: pairing,
            now: { fixedSetupDate }
        )

        #expect(await service.discover() == .discoveryStarted)
        await service.waitForDiscovery()

        #expect(await service.discoveryStatus() == .done)
        let state = await service.state()
        #expect(state.serviceAvailable)
        #expect(state.devices.count == 1)
        #expect(state.devices.first?.name == "Updated")
        let configuration = try #require(await discovery.configurations.first)
        #expect(configuration.rounds == 3)
        #expect(configuration.timeoutMilliseconds == 750)
        #expect(configuration.sourcePort == 60_000)
        #expect(configuration.registrationPort == 60_001)
        #expect(configuration.routes == [ScanSnapDiscoveryRoute(
            clientIPAddress: "192.168.1.10",
            targetIPAddresses: [
                "192.168.1.255",
                "192.168.1.44",
                "192.168.1.88",
                "192.168.1.99",
                "255.255.255.255",
            ]
        )])
    }

    @Test("Selecting a device derives the serial password and persists compatible JSON")
    func selectionConfiguresAndPersists() async throws {
        let device = setupDevice()
        let discovery = FakeScanSnapSetupDiscovery([.devices([device])])
        let pairing = FakeScanSnapSetupPairing([acceptedPairing(device: device)])
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: [:],
            store: store,
            network: FakeScanSnapSetupNetwork(
                interfaces: [try ScanSnapSetupIPv4Interface(
                    name: "eth0", ipAddress: "192.168.1.10", prefixLength: 24
                )]
            ),
            discovery: discovery,
            pairing: pairing,
            now: { fixedSetupDate }
        )
        #expect(await service.discover() == .discoveryStarted)
        await service.waitForDiscovery()

        #expect(await service.select(deviceID: "missing") == .noDevice)
        #expect(await service.select(deviceID: device.id) == .configured)

        let config = try #require(await store.loadStored())
        #expect(config.status == .configured)
        #expect(config.scannerIP == device.ipAddress)
        #expect(config.mac == device.macAddress)
        #expect(config.serial == device.serialNumber)
        #expect(config.pairingKey == "179130178176")
        #expect(config.passwordSource == "serial-default")
        #expect(config.source == "stored")
        #expect(!config.updatedAt.isEmpty)
        let call = try #require(await pairing.calls.first)
        #expect(call.configuration.identity.value == "179130178176")
        #expect(call.configuration.scannerIPAddress == device.ipAddress)
    }

    @Test("Manual MAC and IP lookup preserve legacy outcomes")
    func manualLookupOutcomes() async throws {
        let found = setupDevice(serial: "")
        let discovery = FakeScanSnapSetupDiscovery([
            .devices([found]),
            .devices([setupDevice(macAddress: "84:25:3f:aa:bb:cc")]),
        ])
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: [:],
            store: store,
            network: FakeScanSnapSetupNetwork(
                interfaces: [try ScanSnapSetupIPv4Interface(
                    name: "eth0", ipAddress: "192.168.1.10", prefixLength: 24
                )]
            ),
            discovery: discovery,
            pairing: FakeScanSnapSetupPairing([acceptedPairing()]),
            now: { fixedSetupDate }
        )

        #expect(await service.configureManually(
            ipAddress: "",
            macAddress: "84-25-3F-00-11-22",
            serial: "AWRHC08122"
        ) == .configured)
        #expect(await service.configureManually(
            ipAddress: "192.168.1.44",
            macAddress: "84:25:3f:00:11:22",
            serial: "AWRHC08122"
        ) == .manualInvalid)
        #expect(await service.configureManually(
            ipAddress: "",
            macAddress: "de:ad:be:ef:00:01",
            serial: ""
        ) == .manualNotFound)
        #expect(await service.configureManually(
            ipAddress: "not-an-ip",
            macAddress: "",
            serial: ""
        ) == .manualInvalid)
    }

    @Test("Password candidates accept derived passwords or a provided pairing key")
    func passwordAcceptanceAndPrecedence() async throws {
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await store.save(ScannerConfig(
            status: .needsPassword,
            scannerIP: "192.168.1.44",
            serial: "AWRHC08122"
        ))
        let pairing = FakeScanSnapSetupPairing([
            rejectedPairing(),
            acceptedPairing(),
        ])
        let service = ScanSnapSetupService(
            environment: [:],
            store: store,
            network: FakeScanSnapSetupNetwork(),
            discovery: FakeScanSnapSetupDiscovery([]),
            pairing: pairing,
            now: { fixedSetupDate }
        )

        #expect(await service.savePassword("raw-pairing-key") == .configured)
        let config = try #require(await store.loadStored())
        #expect(config.pairingKey == "raw-pairing-key")
        #expect(config.passwordSource == "provided-pairing-key")
        let calls = await pairing.calls
        #expect(calls.count == 2)
        #expect(calls[0].configuration.identity.value != "raw-pairing-key")
        #expect(calls[1].configuration.identity.value == "raw-pairing-key")
    }

    @Test("Rejected passwords remain needs-password with the scanner status")
    func passwordRejection() async throws {
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await store.save(ScannerConfig(
            status: .needsPassword,
            scannerIP: "192.168.1.44"
        ))
        let service = ScanSnapSetupService(
            environment: [:],
            store: store,
            network: FakeScanSnapSetupNetwork(),
            discovery: FakeScanSnapSetupDiscovery([]),
            pairing: FakeScanSnapSetupPairing([
                rejectedPairing(.passwordRejected),
                rejectedPairing(.pairedToDifferentClientIP),
            ]),
            now: { fixedSetupDate }
        )

        #expect(await service.savePassword("8122") == .passwordFailed)
        let config = try #require(await store.loadStored())
        #expect(config.status == .needsPassword)
        #expect(config.lastError == "Password was rejected: scanner is paired to a different client IP.")
    }

    @Test("Clear removes stored setup but environment configuration keeps precedence")
    func clearAndEnvironmentPrecedence() async throws {
        let environment = [
            "SCANNER_IP": "10.0.0.8",
            "SCANSNAP_PAIRING_KEY": "environment-key",
        ]
        let (store, directory) = setupStore(environment: environment)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await store.save(ScannerConfig(
            status: .needsPassword,
            scannerIP: "192.168.1.44",
            lastError: "stored error"
        ))
        let service = ScanSnapSetupService(
            environment: environment,
            store: store,
            network: FakeScanSnapSetupNetwork(),
            discovery: FakeScanSnapSetupDiscovery([]),
            pairing: FakeScanSnapSetupPairing([])
        )

        let before = await service.state()
        #expect(before.configured)
        #expect(before.needsPassword)
        #expect(before.ipAddress == "10.0.0.8")
        #expect(await service.clear() == .cleared)
        #expect(await store.loadStored() == nil)
        let after = await service.state()
        #expect(after.configured)
        #expect(!after.needsPassword)
        #expect(after.scannerEnvironment["SCANSNAP_PAIRING_KEY"] == "environment-key")
    }

    @Test("Discovery cancellation is cooperative and does not report failure")
    func cancellation() async {
        let discovery = FakeScanSnapSetupDiscovery([.waitForCancellation])
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: ["SCANSNAP_CLIENT_IP": "192.168.1.10"],
            store: store,
            network: FakeScanSnapSetupNetwork(),
            discovery: discovery,
            pairing: FakeScanSnapSetupPairing([])
        )

        #expect(await service.discover() == .discoveryStarted)
        while await discovery.configurations.isEmpty { await Task.yield() }
        #expect(await service.discoveryStatus() == .running)
        await service.cancelDiscovery()

        #expect(await discovery.observedCancellation)
        #expect(await service.discoveryStatus() == .idle)
        #expect(await service.state().lastError.isEmpty)
    }
}
