import Foundation
import ScannerServerCore

actor FakeScanSnapSetupNetwork: ScanSnapSetupNetworkProviding {
    let interfaces: [ScanSnapSetupIPv4Interface]
    let neighbors: [ScanSnapSetupARPNeighbor]
    let routeIPAddress: String
    let macAddress: [UInt8]
    private(set) var routeLookups: [String] = []
    private(set) var preferredInterfaces: [String] = []

    init(
        interfaces: [ScanSnapSetupIPv4Interface] = [],
        neighbors: [ScanSnapSetupARPNeighbor] = [],
        routeIPAddress: String = "192.168.1.10",
        macAddress: [UInt8] = [2, 0x11, 0x22, 0x33, 0x44, 0x55]
    ) {
        self.interfaces = interfaces
        self.neighbors = neighbors
        self.routeIPAddress = routeIPAddress
        self.macAddress = macAddress
    }

    func ipv4Interfaces() -> [ScanSnapSetupIPv4Interface] { interfaces }
    func arpNeighbors() -> [ScanSnapSetupARPNeighbor] { neighbors }

    func clientIPAddress(for scannerIPAddress: String) -> String {
        routeLookups.append(scannerIPAddress)
        return routeIPAddress
    }

    func clientMACAddress(preferredInterface: String) -> [UInt8] {
        preferredInterfaces.append(preferredInterface)
        return macAddress
    }
}

actor FakeScanSnapSetupDiscovery: ScanSnapSetupDiscovering {
    enum Behavior: Sendable {
        case devices([ScanSnapDevice])
        case failure(FakeScanSnapSetupError)
        case suspendedDevices([ScanSnapDevice])
        case waitForCancellation
    }

    private var behaviors: [Behavior]
    private(set) var configurations: [ScanSnapDiscoveryConfiguration] = []
    private(set) var observedCancellation = false
    private var suspendedContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ behaviors: [Behavior]) {
        self.behaviors = behaviors
    }

    func discover(configuration: ScanSnapDiscoveryConfiguration) async throws -> [ScanSnapDevice] {
        configurations.append(configuration)
        guard !behaviors.isEmpty else { throw FakeScanSnapSetupError.missingDiscoveryBehavior }
        switch behaviors.removeFirst() {
        case let .devices(devices):
            return devices
        case let .failure(error):
            throw error
        case let .suspendedDevices(devices):
            await withCheckedContinuation { continuation in
                suspendedContinuation = continuation
                let waiters = suspensionWaiters
                suspensionWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
            return devices
        case .waitForCancellation:
            do {
                try await Task.sleep(for: .seconds(60))
                return []
            } catch is CancellationError {
                observedCancellation = true
                throw CancellationError()
            }
        }
    }

    func waitUntilSuspended() async {
        guard suspendedContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resumeSuspendedDiscovery() {
        suspendedContinuation?.resume()
        suspendedContinuation = nil
    }
}

actor FakeScanSnapSetupPairing: ScanSnapSetupPairing {
    struct Call: Sendable {
        let configuration: ScanSnapPairingConfiguration
        let timestamp: ScanSnapTimestamp
    }

    private var results: [ScanSnapPairingResult]
    private(set) var calls: [Call] = []

    init(_ results: [ScanSnapPairingResult]) {
        self.results = results
    }

    func pair(
        configuration: ScanSnapPairingConfiguration,
        timestamp: ScanSnapTimestamp
    ) throws -> ScanSnapPairingResult {
        calls.append(Call(configuration: configuration, timestamp: timestamp))
        guard !results.isEmpty else { throw FakeScanSnapSetupError.missingPairingResult }
        return results.removeFirst()
    }
}

actor FakeScanSnapSetupConfigurationChangeNotifier: ScanSnapSetupConfigurationChangeNotifying {
    private(set) var callCount = 0

    func scannerConfigurationDidChange() {
        callCount += 1
    }
}

actor SuspendedFirstScanSnapSetupPairing: ScanSnapSetupPairing {
    typealias Call = FakeScanSnapSetupPairing.Call

    private let firstResult: ScanSnapPairingResult
    private var subsequentResults: [ScanSnapPairingResult]
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls: [Call] = []

    init(
        firstResult: ScanSnapPairingResult,
        subsequentResults: [ScanSnapPairingResult] = []
    ) {
        self.firstResult = firstResult
        self.subsequentResults = subsequentResults
    }

    func pair(
        configuration: ScanSnapPairingConfiguration,
        timestamp: ScanSnapTimestamp
    ) async throws -> ScanSnapPairingResult {
        calls.append(Call(configuration: configuration, timestamp: timestamp))
        if calls.count == 1 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
                let waiters = suspensionWaiters
                suspensionWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
            return firstResult
        }
        guard !subsequentResults.isEmpty else {
            throw FakeScanSnapSetupError.missingPairingResult
        }
        return subsequentResults.removeFirst()
    }

    func waitUntilFirstCallIsSuspended() async {
        guard firstContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resumeFirstCall() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

enum FakeScanSnapSetupError: Error, Sendable {
    case discoveryFailed
    case missingDiscoveryBehavior
    case missingPairingResult
}

func setupDevice(
    ipAddress: String = "192.168.1.44",
    macAddress: String = "84:25:3f:00:11:22",
    serial: String = "AWRHC08122",
    name: String = "iX500"
) -> ScanSnapDevice {
    ScanSnapDevice(
        ipAddress: ipAddress,
        macAddress: macAddress,
        serialNumber: serial,
        name: name,
        dataPort: ScanSnapPacketBuilder.dataPort,
        controlPort: ScanSnapPacketBuilder.controlPort,
        state: 0,
        clientIPAddress: nil,
        metadata: [0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4]
    )
}

func acceptedPairing(device: ScanSnapDevice? = nil) -> ScanSnapPairingResult {
    ScanSnapPairingResult(status: .accepted, device: device, attemptsMade: 1)
}

func rejectedPairing(_ status: ScanSnapPairingStatus = .passwordRejected) -> ScanSnapPairingResult {
    ScanSnapPairingResult(status: status, device: nil, attemptsMade: 1)
}

func setupStore(environment: [String: String] = [:]) -> (ScannerConfigStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScanSnapSetupTests-\(UUID().uuidString)", isDirectory: true)
    return (
        ScannerConfigStore(fileURL: directory.appendingPathComponent("scanner.json"), environment: environment),
        directory
    )
}

let fixedSetupDate = Date(timeIntervalSince1970: 1_700_000_000)
