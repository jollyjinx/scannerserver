import Foundation

public struct ScanSnapButtonConfiguration: Sendable, Hashable {
    public var isEnabled: Bool
    public var listenerPort: UInt16
    public var startupAdvertisementPort: UInt16
    public var debounceMilliseconds: UInt64
    public var cooldownMilliseconds: UInt64
    public var armIntervalMilliseconds: UInt64
    public var armTimeoutMilliseconds: UInt64
    public var heartbeatIntervalMilliseconds: UInt64
    public var healthCheckIntervalMilliseconds: UInt64
    public var startupRearmDebounceMilliseconds: UInt64
    public var reachabilityPort: UInt16
    public var reachabilityTimeoutMilliseconds: UInt64
    public var reachabilityIntervalMilliseconds: UInt64
    public var registrationSourcePort: UInt16
    public var registrationPort: UInt16
    public var listenerPollMilliseconds: UInt64

    public init(
        isEnabled: Bool = true,
        listenerPort: UInt16 = ScanSnapPacketBuilder.buttonNoticePort,
        startupAdvertisementPort: UInt16 = ScanSnapPacketBuilder.startupAdvertisementPort,
        debounceMilliseconds: UInt64 = 3_000,
        cooldownMilliseconds: UInt64 = 1_000,
        armIntervalMilliseconds: UInt64 = 0,
        armTimeoutMilliseconds: UInt64 = 45_000,
        heartbeatIntervalMilliseconds: UInt64 = 500,
        healthCheckIntervalMilliseconds: UInt64 = 10_000,
        startupRearmDebounceMilliseconds: UInt64 = 3_000,
        reachabilityPort: UInt16 = ScanSnapPacketBuilder.controlPort,
        reachabilityTimeoutMilliseconds: UInt64 = 1_000,
        reachabilityIntervalMilliseconds: UInt64 = 3_000,
        registrationSourcePort: UInt16 = ScanSnapPacketBuilder.registrationSourcePort,
        registrationPort: UInt16 = ScanSnapPacketBuilder.registrationPort,
        listenerPollMilliseconds: UInt64 = 1_000
    ) {
        self.isEnabled = isEnabled
        self.listenerPort = listenerPort
        self.startupAdvertisementPort = startupAdvertisementPort
        self.debounceMilliseconds = debounceMilliseconds
        self.cooldownMilliseconds = cooldownMilliseconds
        self.armIntervalMilliseconds = armIntervalMilliseconds
        self.armTimeoutMilliseconds = armTimeoutMilliseconds
        self.heartbeatIntervalMilliseconds = heartbeatIntervalMilliseconds
        self.healthCheckIntervalMilliseconds = healthCheckIntervalMilliseconds
        self.startupRearmDebounceMilliseconds = startupRearmDebounceMilliseconds
        self.reachabilityPort = reachabilityPort
        self.reachabilityTimeoutMilliseconds = reachabilityTimeoutMilliseconds
        self.reachabilityIntervalMilliseconds = reachabilityIntervalMilliseconds
        self.registrationSourcePort = registrationSourcePort
        self.registrationPort = registrationPort
        self.listenerPollMilliseconds = max(listenerPollMilliseconds, 1)
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        func seconds(_ key: String, default defaultValue: Double) -> UInt64 {
            guard let text = environment[key],
                  let value = Double(text),
                  value.isFinite,
                  value >= 0
            else {
                return UInt64(defaultValue * 1_000)
            }
            return UInt64(min(value * 1_000, Double(UInt64.max)))
        }

        func port(_ key: String, default defaultValue: UInt16) -> UInt16 {
            guard let text = environment[key], let value = UInt16(text) else { return defaultValue }
            return value
        }

        let armIntervalKey = environment["SCANSNAP_BUTTON_ARM_INTERVAL_SECONDS"] != nil
            ? "SCANSNAP_BUTTON_ARM_INTERVAL_SECONDS"
            : "SCANSNAP_BUTTON_REGISTRATION_INTERVAL_SECONDS"

        self.init(
            isEnabled: ModeSettings.isTruthy(environment["SCANSNAP_BUTTON_SCAN_ENABLED"] ?? "true"),
            listenerPort: port("SCANSNAP_BUTTON_PORT", default: ScanSnapPacketBuilder.buttonNoticePort),
            startupAdvertisementPort: port(
                "SCANSNAP_STARTUP_ADVERTISEMENT_PORT",
                default: ScanSnapPacketBuilder.startupAdvertisementPort
            ),
            debounceMilliseconds: seconds("SCANSNAP_BUTTON_DEBOUNCE_SECONDS", default: 3),
            cooldownMilliseconds: seconds("SCANSNAP_BUTTON_COOLDOWN_SECONDS", default: 1),
            armIntervalMilliseconds: seconds(armIntervalKey, default: 0),
            armTimeoutMilliseconds: seconds("SCANSNAP_BUTTON_ARM_TIMEOUT_SECONDS", default: 45),
            heartbeatIntervalMilliseconds: seconds("SCANSNAP_BUTTON_HEARTBEAT_INTERVAL_SECONDS", default: 0.5),
            healthCheckIntervalMilliseconds: seconds("SCANSNAP_BUTTON_HEALTH_INTERVAL_SECONDS", default: 10),
            startupRearmDebounceMilliseconds: seconds(
                "SCANSNAP_BUTTON_STARTUP_REARM_DEBOUNCE_SECONDS",
                default: 3
            ),
            reachabilityPort: port("SCANSNAP_BUTTON_REACHABILITY_PORT", default: ScanSnapPacketBuilder.controlPort),
            reachabilityTimeoutMilliseconds: seconds("SCANSNAP_BUTTON_REACHABILITY_TIMEOUT_SECONDS", default: 1),
            reachabilityIntervalMilliseconds: seconds("SCANSNAP_BUTTON_REACHABILITY_INTERVAL_SECONDS", default: 3),
            registrationSourcePort: port(
                "SCANSNAP_REGISTRATION_SOURCE_PORT",
                default: ScanSnapPacketBuilder.registrationSourcePort
            ),
            registrationPort: port("SCANSNAP_REGISTRATION_PORT", default: ScanSnapPacketBuilder.registrationPort)
        )
    }
}

public struct ScanSnapButtonScannerConfiguration: Sendable, Hashable {
    public var scannerIPAddress: String
    public var clientIPAddress: String
    public var clientMACAddress: [UInt8]
    public var identity: ScanSnapIdentity
    public var controlPort: UInt16
    public var dataPort: UInt16
    public var registrationRounds: Int
    public var registrationTimeoutMilliseconds: UInt64
    public var connectionTimeoutMilliseconds: UInt64
    public var allowsRegistrationSourcePortFallback: Bool

    public init(
        scannerIPAddress: String,
        clientIPAddress: String,
        clientMACAddress: [UInt8],
        identity: ScanSnapIdentity,
        controlPort: UInt16 = ScanSnapPacketBuilder.controlPort,
        dataPort: UInt16 = ScanSnapPacketBuilder.dataPort,
        registrationRounds: Int = 4,
        registrationTimeoutMilliseconds: UInt64 = 3_000,
        connectionTimeoutMilliseconds: UInt64 = 5_000,
        allowsRegistrationSourcePortFallback: Bool = true
    ) {
        self.scannerIPAddress = scannerIPAddress
        self.clientIPAddress = clientIPAddress
        self.clientMACAddress = clientMACAddress
        self.identity = identity
        self.controlPort = controlPort
        self.dataPort = dataPort
        self.registrationRounds = max(registrationRounds, 1)
        self.registrationTimeoutMilliseconds = registrationTimeoutMilliseconds
        self.connectionTimeoutMilliseconds = connectionTimeoutMilliseconds
        self.allowsRegistrationSourcePortFallback = allowsRegistrationSourcePortFallback
    }
}
