import ScannerServerCore
import Testing

@Suite("Live ScanSnap setup environment")
struct ScanSnapSetupEnvironmentTests {
    @Test("Environment contract parses overrides, timeout, rounds, targets, and ports")
    func parsesEnvironmentContract() throws {
        let configuration = try ScanSnapSetupEnvironmentConfiguration(environment: [
            "SCANSNAP_CLIENT_IP": " 10.20.30.40 ",
            "SCANSNAP_CLIENT_MAC": "02-11-22-33-44-55",
            "SCANSNAP_CLIENT_INTERFACE": "en7",
            "SCANSNAP_DISCOVERY_TARGETS": "10.20.30.255, 10.20.30.9",
            "SCANSNAP_DISCOVERY_ARP_ALL": "yes",
            "SCANSNAP_DISCOVERY_TIMEOUT_SECONDS": "1.25",
            "SCANSNAP_DISCOVERY_ROUNDS": "3",
            "SCANSNAP_DISCOVERY_SOURCE_PORT": "60000",
            "SCANSNAP_REGISTRATION_SOURCE_PORT": "60001",
            "SCANSNAP_REGISTRATION_PORT": "60002",
            "SCANNER_IP": "10.20.30.8",
        ])

        #expect(configuration.clientIPAddress == "10.20.30.40")
        #expect(configuration.clientMACAddress == [2, 0x11, 0x22, 0x33, 0x44, 0x55])
        #expect(configuration.clientInterface == "en7")
        #expect(configuration.discoveryTargets == ["10.20.30.255", "10.20.30.9"])
        #expect(configuration.includesAllARPNeighbors)
        #expect(configuration.discoveryTimeoutMilliseconds == 1_250)
        #expect(configuration.discoveryRounds == 3)
        #expect(configuration.discoverySourcePort == 60_000)
        #expect(configuration.registrationSourcePort == 60_001)
        #expect(configuration.registrationPort == 60_002)
        #expect(configuration.scannerIPAddress == "10.20.30.8")
    }

    @Test("Environment contract rejects malformed values")
    func rejectsMalformedEnvironment() {
        #expect(throws: ScanSnapSetupConfigurationError.invalidPort(
            name: "SCANSNAP_REGISTRATION_PORT",
            value: "70000"
        )) {
            try ScanSnapSetupEnvironmentConfiguration(environment: ["SCANSNAP_REGISTRATION_PORT": "70000"])
        }
        #expect(throws: SettingsValidationError.invalidMACAddress) {
            try ScanSnapSetupEnvironmentConfiguration(environment: ["SCANSNAP_CLIENT_MAC": "bad"])
        }
        #expect(throws: ScanSnapSetupConfigurationError.invalidNumber(
            name: "SCANSNAP_DISCOVERY_TIMEOUT_SECONDS",
            value: "soon"
        )) {
            try ScanSnapSetupEnvironmentConfiguration(environment: ["SCANSNAP_DISCOVERY_TIMEOUT_SECONDS": "soon"])
        }
    }

    @Test("IPv4 interface derives network membership and broadcast")
    func interfaceNetworkMath() throws {
        let interface = try ScanSnapSetupIPv4Interface(
            name: "eth0",
            ipAddress: "192.168.12.34",
            prefixLength: 23
        )

        #expect(interface.broadcastAddress == "192.168.13.255")
        #expect(interface.contains("192.168.13.200"))
        #expect(!interface.contains("192.168.14.1"))
    }
}

