import ScannerServerCore
import Testing

@Test("Button environment honors every timing, port, and enable setting")
func buttonEnvironmentConfiguration() {
    let configuration = ScanSnapButtonConfiguration(environment: [
        "SCANSNAP_BUTTON_SCAN_ENABLED": "off",
        "SCANSNAP_BUTTON_PORT": "50001",
        "SCANSNAP_BUTTON_DEBOUNCE_SECONDS": "2.5",
        "SCANSNAP_BUTTON_COOLDOWN_SECONDS": "1.25",
        "SCANSNAP_BUTTON_ARM_INTERVAL_SECONDS": "42",
        "SCANSNAP_BUTTON_ARM_TIMEOUT_SECONDS": "7.5",
        "SCANSNAP_BUTTON_REACHABILITY_PORT": "50002",
        "SCANSNAP_BUTTON_REACHABILITY_TIMEOUT_SECONDS": "0.75",
        "SCANSNAP_BUTTON_REACHABILITY_INTERVAL_SECONDS": "4.5",
        "SCANSNAP_REGISTRATION_SOURCE_PORT": "50003",
        "SCANSNAP_REGISTRATION_PORT": "50004",
    ])

    #expect(!configuration.isEnabled)
    #expect(configuration.listenerPort == 50_001)
    #expect(configuration.debounceMilliseconds == 2_500)
    #expect(configuration.cooldownMilliseconds == 1_250)
    #expect(configuration.armIntervalMilliseconds == 42_000)
    #expect(configuration.armTimeoutMilliseconds == 7_500)
    #expect(configuration.reachabilityPort == 50_002)
    #expect(configuration.reachabilityTimeoutMilliseconds == 750)
    #expect(configuration.reachabilityIntervalMilliseconds == 4_500)
    #expect(configuration.registrationSourcePort == 50_003)
    #expect(configuration.registrationPort == 50_004)
}

@Test("Legacy registration interval remains the arm interval fallback")
func legacyButtonRegistrationInterval() {
    let defaults = ScanSnapButtonConfiguration(environment: [:])
    let legacy = ScanSnapButtonConfiguration(environment: [
        "SCANSNAP_BUTTON_REGISTRATION_INTERVAL_SECONDS": "17",
    ])
    let currentWins = ScanSnapButtonConfiguration(environment: [
        "SCANSNAP_BUTTON_ARM_INTERVAL_SECONDS": "11",
        "SCANSNAP_BUTTON_REGISTRATION_INTERVAL_SECONDS": "17",
    ])

    #expect(defaults.cooldownMilliseconds == 10_000)
    #expect(legacy.armIntervalMilliseconds == 17_000)
    #expect(currentWins.armIntervalMilliseconds == 11_000)
}
