import Dispatch

public protocol ScanSnapButtonScannerConfigurationProviding: Sendable {
    func currentButtonScannerConfiguration() async throws -> ScanSnapButtonScannerConfiguration?
}

public protocol ScanSnapButtonModeProviding: Sendable {
    func currentButtonDefaultMode() async throws -> ScanMode
}

public protocol ScanSnapButtonScanDispatching: Sendable {
    func isScanRunning() async -> Bool
    func startButtonScan(mode: ScanMode) async -> Bool
}

public protocol ScanSnapButtonReachabilityChecking: Sendable {
    func isReachable(
        scanner: ScanSnapButtonScannerConfiguration,
        port: UInt16,
        timeoutMilliseconds: UInt64
    ) async -> Bool
}

public protocol ScanSnapButtonPairing: Sendable {
    func pair(
        configuration: ScanSnapPairingConfiguration,
        timestamp: ScanSnapTimestamp
    ) async throws -> ScanSnapPairingResult
}

extension ScanSnapPairingActor: ScanSnapButtonPairing {}

public protocol ScanSnapButtonArming: Sendable {
    func arm(
        scanner: ScanSnapButtonScannerConfiguration,
        configuration: ScanSnapButtonConfiguration
    ) async throws
}

public protocol ScanSnapButtonClock: Sendable {
    func nowMilliseconds() async -> UInt64
}

public struct SystemScanSnapButtonClock: ScanSnapButtonClock {
    public init() {}

    public func nowMilliseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }
}

public struct ScanSnapButtonTCPReachabilityChecker: ScanSnapButtonReachabilityChecking {
    private let connectionFactory: any ScanSnapTCPConnectionFactory

    public init(connectionFactory: any ScanSnapTCPConnectionFactory = POSIXScanSnapTCPConnectionFactory()) {
        self.connectionFactory = connectionFactory
    }

    public func isReachable(
        scanner: ScanSnapButtonScannerConfiguration,
        port: UInt16,
        timeoutMilliseconds: UInt64
    ) async -> Bool {
        do {
            let connection = try await connectionFactory.connect(
                to: ScanSnapSocketAddress(host: scanner.scannerIPAddress, port: port),
                binding: ScanSnapSocketAddress(host: scanner.clientIPAddress, port: 0),
                timeoutMilliseconds: timeoutMilliseconds
            )
            await connection.close()
            return true
        } catch {
            return false
        }
    }
}
