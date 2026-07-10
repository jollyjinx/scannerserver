import Foundation

public struct ScanSnapButtonScannerEnvironmentConfiguration: Equatable, Sendable {
    public let clientIPAddress: String?
    public let clientMACAddress: [UInt8]?
    public let clientInterface: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let configuredIPAddress = try ScannerConfig.normalizeIPv4Address(
            environment["SCANSNAP_CLIENT_IP"] ?? ""
        )
        clientIPAddress = configuredIPAddress.isEmpty ? nil : configuredIPAddress

        let configuredMACAddress = (environment["SCANSNAP_CLIENT_MAC"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        clientMACAddress = configuredMACAddress.isEmpty
            ? nil
            : try ScanSnapSetupEnvironmentConfiguration.macBytes(configuredMACAddress)

        let configuredInterface = (environment["SCANSNAP_CLIENT_INTERFACE"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        clientInterface = configuredInterface.isEmpty ? "eth0" : configuredInterface
    }
}

public struct StoreBackedScanSnapButtonScannerConfigurationProvider:
    ScanSnapButtonScannerConfigurationProviding
{
    private let store: ScannerConfigStore
    private let environment: [String: String]
    private let network: any ScanSnapSetupNetworkProviding

    public init(
        store: ScannerConfigStore,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        network: any ScanSnapSetupNetworkProviding = SystemScanSnapSetupNetworkProvider()
    ) {
        self.store = store
        self.environment = environment
        self.network = network
    }

    public func currentButtonScannerConfiguration() async throws -> ScanSnapButtonScannerConfiguration? {
        guard let active = await store.activeConfiguration(),
              active.status == .configured,
              !active.scannerIP.isEmpty,
              !active.pairingKey.isEmpty
        else {
            return nil
        }

        let scannerIPAddress = try ScannerConfig.normalizeIPv4Address(active.scannerIP)
        let environmentConfiguration = try ScanSnapButtonScannerEnvironmentConfiguration(
            environment: environment
        )
        let clientIPAddress: String
        if let configured = environmentConfiguration.clientIPAddress {
            clientIPAddress = configured
        } else {
            clientIPAddress = try await network.clientIPAddress(for: scannerIPAddress)
        }

        let clientMACAddress: [UInt8]
        if let configured = environmentConfiguration.clientMACAddress {
            clientMACAddress = configured
        } else {
            clientMACAddress = try await network.clientMACAddress(
                preferredInterface: environmentConfiguration.clientInterface
            )
        }

        return ScanSnapButtonScannerConfiguration(
            scannerIPAddress: scannerIPAddress,
            clientIPAddress: clientIPAddress,
            clientMACAddress: clientMACAddress,
            identity: ScanSnapIdentity(active.pairingKey)
        )
    }
}

public struct StoreBackedScanSnapButtonModeProvider: ScanSnapButtonModeProviding {
    private let store: ScanSettingsStore

    public init(store: ScanSettingsStore) {
        self.store = store
    }

    public func currentButtonDefaultMode() async throws -> ScanMode {
        try await store.load().defaultMode
    }
}
