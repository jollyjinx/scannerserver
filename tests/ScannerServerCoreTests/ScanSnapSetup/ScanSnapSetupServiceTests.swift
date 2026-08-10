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

    @Test("Automatic discovery keeps retrying and skips configured scanners")
    func automaticDiscoveryGuard() async throws {
        let discovery = FakeScanSnapSetupDiscovery([
            .devices([]),
            .waitForCancellation,
        ])
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: ["SCANSNAP_CLIENT_IP": "192.168.1.10"],
            store: store,
            network: FakeScanSnapSetupNetwork(),
            discovery: discovery,
            pairing: FakeScanSnapSetupPairing([]),
            discoveryRetryDelay: .zero
        )

        await service.ensureDiscoveryStarted()
        await service.waitForDiscovery()
        while await discovery.configurations.count < 2 { await Task.yield() }
        #expect(await discovery.configurations.count == 2)
        await service.shutdown()

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

    @Test("A sole discovered scanner is configured with its serial-derived password")
    func soleScannerConfiguresAutomatically() async throws {
        let device = setupDevice()
        let discovery = FakeScanSnapSetupDiscovery([.devices([device])])
        let pairing = FakeScanSnapSetupPairing([acceptedPairing(device: device)])
        let notifier = FakeScanSnapSetupConfigurationChangeNotifier()
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: ["SCANSNAP_CLIENT_IP": "192.168.1.10"],
            store: store,
            network: FakeScanSnapSetupNetwork(),
            discovery: discovery,
            pairing: pairing,
            configurationChangeNotifier: notifier,
            now: { fixedSetupDate }
        )

        await service.ensureDiscoveryStarted()
        await service.waitForDiscovery()

        let config = try #require(await store.loadStored())
        #expect(config.status == .configured)
        #expect(config.scannerIP == device.ipAddress)
        #expect(config.pairingKey == "179130178176")
        #expect(config.passwordSource == "serial-default")
        #expect(await pairing.calls.count == 1)
        #expect(await notifier.callCount == 1)
        #expect(!(await service.discoveryInProgress()))
    }

    @Test("A rejected serial-derived password pauses discovery for user input")
    func soleScannerWaitsForChangedPassword() async throws {
        let device = setupDevice()
        let discovery = FakeScanSnapSetupDiscovery([.devices([device])])
        let pairing = FakeScanSnapSetupPairing([
            rejectedPairing(.passwordRejected),
            acceptedPairing(device: device),
        ])
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: ["SCANSNAP_CLIENT_IP": "192.168.1.10"],
            store: store,
            network: FakeScanSnapSetupNetwork(),
            discovery: discovery,
            pairing: pairing,
            now: { fixedSetupDate },
            discoveryRetryDelay: .zero
        )

        await service.ensureDiscoveryStarted()
        await service.waitForDiscovery()

        var config = try #require(await store.loadStored())
        #expect(config.status == .needsPassword)
        #expect(config.scannerIP == device.ipAddress)
        #expect(config.lastError.contains("Default password \"8122\" was rejected"))
        await service.ensureDiscoveryStarted()
        #expect(await discovery.configurations.count == 1)

        #expect(await service.configureManually(
            ipAddress: device.ipAddress,
            credential: "2468"
        ) == .configured)
        config = try #require(await store.loadStored())
        #expect(config.status == .configured)
        #expect(config.passwordSource == "user-password")
        #expect(await pairing.calls.count == 2)
    }

    @Test("Transient automatic pairing failures keep discovery running")
    func transientAutomaticPairingFailureRetries() async throws {
        let device = setupDevice()
        let discovery = FakeScanSnapSetupDiscovery([
            .devices([device]),
            .devices([device]),
        ])
        let pairing = FakeScanSnapSetupPairing([
            rejectedPairing(.sessionBusy),
            acceptedPairing(device: device),
        ])
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: ["SCANSNAP_CLIENT_IP": "192.168.1.10"],
            store: store,
            network: FakeScanSnapSetupNetwork(),
            discovery: discovery,
            pairing: pairing,
            now: { fixedSetupDate },
            discoveryRetryDelay: .zero
        )

        await service.ensureDiscoveryStarted()
        while await pairing.calls.count < 2 { await Task.yield() }
        while await service.discoveryInProgress() { await Task.yield() }

        let config = try #require(await store.loadStored())
        #expect(config.status == .configured)
        #expect(config.passwordSource == "serial-default")
        #expect(await discovery.configurations.count == 2)
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
        let secondDevice = setupDevice(
            ipAddress: "192.168.1.45",
            macAddress: "84:25:3f:00:11:23",
            serial: "AWRHC08123",
            name: "Zebra"
        )
        let discovery = FakeScanSnapSetupDiscovery([.devices([original, updated, secondDevice])])
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

        #expect(await service.discoveryStatus() == .running)
        let state = await service.state()
        #expect(state.serviceAvailable)
        #expect(state.devices.count == 2)
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
        await service.shutdown()
    }

    @Test("Selecting a device derives the serial password and persists compatible JSON")
    func selectionConfiguresAndPersists() async throws {
        let device = setupDevice()
        let otherDevice = setupDevice(
            ipAddress: "192.168.1.45",
            macAddress: "84:25:3f:00:11:23",
            serial: "AWRHC08123"
        )
        let discovery = FakeScanSnapSetupDiscovery([.devices([device, otherDevice])])
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

    @Test("Successful setup notifies and awaits the physical-button handoff")
    func successfulSetupNotifiesButtonRuntime() async throws {
        let device = setupDevice()
        let otherDevice = setupDevice(
            ipAddress: "192.168.1.45",
            macAddress: "84:25:3f:00:11:23",
            serial: "AWRHC08123"
        )
        let discovery = FakeScanSnapSetupDiscovery([.devices([device, otherDevice])])
        let notifier = FakeScanSnapSetupConfigurationChangeNotifier()
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
            pairing: FakeScanSnapSetupPairing([acceptedPairing(device: device)]),
            configurationChangeNotifier: notifier,
            now: { fixedSetupDate }
        )

        #expect(await service.discover() == .discoveryStarted)
        await service.waitForDiscovery()
        #expect(await service.select(deviceID: device.id) == .configured)
        #expect(await notifier.callCount == 1)

        #expect(await service.clear() == .cleared)
        #expect(await notifier.callCount == 2)
        await service.shutdown()
    }

    @Test("Manual setup resolves a scanner host name and persists its IPv4 address")
    func manualSetupWithHostName() async throws {
        let discovery = FakeScanSnapSetupDiscovery([.failure(.discoveryFailed)])
        let pairing = FakeScanSnapSetupPairing([acceptedPairing()])
        let network = FakeScanSnapSetupNetwork(
            routeIPAddress: "10.20.30.10",
            resolvedScannerAddresses: ["office-scanner.local": "192.0.2.44"]
        )
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: [:],
            store: store,
            network: network,
            discovery: discovery,
            pairing: pairing,
            now: { fixedSetupDate }
        )

        #expect(await service.configureManually(
            ipAddress: " office-scanner.local ",
            credential: "AWRHC08122"
        ) == .configured)

        let config = try #require(await store.loadStored())
        #expect(config.scannerIP == "192.0.2.44")
        #expect(await network.scannerAddressLookups == ["office-scanner.local"])
        #expect(await network.routeLookups == ["192.0.2.44", "192.0.2.44"])
        let discoveryConfiguration = try #require(await discovery.configurations.first)
        #expect(discoveryConfiguration.routes.first?.targetIPAddresses == ["192.0.2.44"])
        let pairingCall = try #require(await pairing.calls.first)
        #expect(pairingCall.configuration.scannerIPAddress == "192.0.2.44")
    }

    @Test("Unified manual credential derives the factory password from a serial number")
    func unifiedManualSerialNumber() async throws {
        let discovery = FakeScanSnapSetupDiscovery([.failure(.discoveryFailed)])
        let pairing = FakeScanSnapSetupPairing([acceptedPairing()])
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: [:],
            store: store,
            network: FakeScanSnapSetupNetwork(routeIPAddress: "10.20.30.10"),
            discovery: discovery,
            pairing: pairing,
            now: { fixedSetupDate }
        )

        #expect(await service.configureManually(
            ipAddress: "192.0.2.44",
            credential: "AWRHC08122"
        ) == .configured)

        let config = try #require(await store.loadStored())
        #expect(config.serial == "AWRHC08122")
        #expect(config.pairingKey == "179130178176")
        #expect(config.passwordSource == "serial-default")
        let call = try #require(await pairing.calls.first)
        #expect(call.configuration.identity.value == "179130178176")
    }

    @Test("Unified manual credential falls back from a serial-derived default to the full password")
    func unifiedManualPassword() async throws {
        let discovery = FakeScanSnapSetupDiscovery([.failure(.discoveryFailed)])
        let pairing = FakeScanSnapSetupPairing([
            rejectedPairing(.passwordRejected),
            acceptedPairing(),
        ])
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: [:],
            store: store,
            network: FakeScanSnapSetupNetwork(routeIPAddress: "10.20.30.10"),
            discovery: discovery,
            pairing: pairing,
            now: { fixedSetupDate }
        )

        #expect(await service.configureManually(
            ipAddress: "192.0.2.44",
            credential: "office-secret"
        ) == .configured)

        let expectedPasswordIdentity = try ScanSnapIdentity.derive(fromPassword: "office-secret").value
        let expectedSerialSuffixIdentity = try ScanSnapIdentity.derive(fromPassword: "cret").value
        let config = try #require(await store.loadStored())
        #expect(config.serial.isEmpty)
        #expect(config.pairingKey == expectedPasswordIdentity)
        #expect(config.passwordSource == "user-password")
        let calls = await pairing.calls
        #expect(calls.map(\.configuration.identity.value) == [
            expectedSerialSuffixIdentity,
            expectedPasswordIdentity,
        ])
    }

    @Test("Rejected unified credentials retain the target without persisting the raw credential")
    func rejectedUnifiedManualCredential() async throws {
        let discovery = FakeScanSnapSetupDiscovery([.failure(.discoveryFailed)])
        let pairing = FakeScanSnapSetupPairing([
            rejectedPairing(.passwordRejected),
            rejectedPairing(.passwordRejected),
        ])
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: [:],
            store: store,
            network: FakeScanSnapSetupNetwork(
                routeIPAddress: "10.20.30.10",
                resolvedScannerAddresses: ["scanner.example.net": "192.0.2.44"]
            ),
            discovery: discovery,
            pairing: pairing,
            now: { fixedSetupDate }
        )

        #expect(await service.configureManually(
            ipAddress: "scanner.example.net",
            credential: "wrong-password"
        ) == .passwordFailed)

        let config = try #require(await store.loadStored())
        #expect(config.status == .needsPassword)
        #expect(config.scannerIP == "192.0.2.44")
        #expect(config.serial.isEmpty)
        #expect(config.pairingKey.isEmpty)
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

    @Test("Clear prevents a suspended selected-device pairing from restoring setup")
    func clearInvalidatesSuspendedSelection() async throws {
        let device = setupDevice()
        let otherDevice = setupDevice(
            ipAddress: "192.168.1.45",
            macAddress: "84:25:3f:00:11:23",
            serial: "AWRHC08123"
        )
        let discovery = FakeScanSnapSetupDiscovery([.devices([device, otherDevice])])
        let pairing = SuspendedFirstScanSnapSetupPairing(firstResult: acceptedPairing(device: device))
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: ["SCANSNAP_CLIENT_IP": "192.168.1.10"],
            store: store,
            network: FakeScanSnapSetupNetwork(),
            discovery: discovery,
            pairing: pairing,
            now: { fixedSetupDate }
        )
        #expect(await service.discover() == .discoveryStarted)
        await service.waitForDiscovery()

        let selection = Task { await service.select(deviceID: device.id) }
        await pairing.waitUntilFirstCallIsSuspended()
        #expect(await service.clear() == .cleared)
        await pairing.resumeFirstCall()

        #expect(await selection.value == .unavailable)
        #expect(await store.loadStored() == nil)
        await service.shutdown()
    }

    @Test("Automatic setup cannot supersede manual pairing already in progress")
    func manualPairingWinsOverAutomaticSetup() async throws {
        let automaticDevice = setupDevice(
            ipAddress: "192.168.1.45",
            macAddress: "84:25:3f:00:11:23",
            serial: "AWRHC08123"
        )
        let discovery = FakeScanSnapSetupDiscovery([
            .suspendedDevices([automaticDevice]),
            .failure(.discoveryFailed),
        ])
        let pairing = SuspendedFirstScanSnapSetupPairing(firstResult: acceptedPairing())
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: ["SCANSNAP_CLIENT_IP": "192.168.1.10"],
            store: store,
            network: FakeScanSnapSetupNetwork(),
            discovery: discovery,
            pairing: pairing,
            now: { fixedSetupDate }
        )

        await service.ensureDiscoveryStarted()
        await discovery.waitUntilSuspended()
        let manualSetup = Task {
            await service.configureManually(
                ipAddress: "192.168.1.44",
                credential: "AWRHC08122"
            )
        }
        await pairing.waitUntilFirstCallIsSuspended()
        await discovery.resumeSuspendedDiscovery()
        await service.waitForDiscovery()
        #expect(await pairing.calls.count == 1)

        await pairing.resumeFirstCall()
        #expect(await manualSetup.value == .configured)
        let stored = try #require(await store.loadStored())
        #expect(stored.scannerIP == "192.168.1.44")
        #expect(stored.serial == "AWRHC08122")
        await service.shutdown()
    }

    @Test("Clear prevents suspended manual pairing from restoring setup")
    func clearInvalidatesSuspendedManualSetup() async throws {
        let pairing = SuspendedFirstScanSnapSetupPairing(firstResult: acceptedPairing())
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: [:],
            store: store,
            network: FakeScanSnapSetupNetwork(),
            discovery: FakeScanSnapSetupDiscovery([.failure(.discoveryFailed)]),
            pairing: pairing,
            now: { fixedSetupDate }
        )

        let manualSetup = Task {
            await service.configureManually(
                ipAddress: "192.168.1.44",
                credential: "AWRHC08122"
            )
        }
        await pairing.waitUntilFirstCallIsSuspended()
        #expect(await service.clear() == .cleared)
        await pairing.resumeFirstCall()

        #expect(await manualSetup.value == .unavailable)
        #expect(await store.loadStored() == nil)
    }

    @Test("A suspended setup cannot overwrite a newer setup")
    func newerSetupWinsOverSuspendedSetup() async throws {
        let newerDevice = setupDevice(
            ipAddress: "192.168.1.45",
            macAddress: "84:25:3f:00:11:23",
            serial: "AWRHC08123"
        )
        let pairing = SuspendedFirstScanSnapSetupPairing(
            firstResult: acceptedPairing(),
            subsequentResults: [acceptedPairing(device: newerDevice)]
        )
        let (store, directory) = setupStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScanSnapSetupService(
            environment: [:],
            store: store,
            network: FakeScanSnapSetupNetwork(),
            discovery: FakeScanSnapSetupDiscovery([
                .failure(.discoveryFailed),
                .failure(.discoveryFailed),
            ]),
            pairing: pairing,
            now: { fixedSetupDate }
        )

        let olderSetup = Task {
            await service.configureManually(
                ipAddress: "192.168.1.44",
                credential: "AWRHC08122"
            )
        }
        await pairing.waitUntilFirstCallIsSuspended()

        #expect(await service.configureManually(
            ipAddress: newerDevice.ipAddress,
            credential: newerDevice.serialNumber
        ) == .configured)
        await pairing.resumeFirstCall()

        #expect(await olderSetup.value == .unavailable)
        let stored = try #require(await store.loadStored())
        #expect(stored.scannerIP == newerDevice.ipAddress)
        #expect(stored.mac == newerDevice.macAddress)
        #expect(stored.serial == newerDevice.serialNumber)
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
