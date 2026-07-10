import Foundation

public protocol ScanSnapSetupDiscovering: Sendable {
    func discover(configuration: ScanSnapDiscoveryConfiguration) async throws -> [ScanSnapDevice]
}

extension ScanSnapDiscoveryActor: ScanSnapSetupDiscovering {}

public protocol ScanSnapSetupPairing: Sendable {
    func pair(
        configuration: ScanSnapPairingConfiguration,
        timestamp: ScanSnapTimestamp
    ) async throws -> ScanSnapPairingResult
}

extension ScanSnapPairingActor: ScanSnapSetupPairing {}

public enum ScanSnapSetupDiscoveryStatus: Equatable, Sendable {
    case idle
    case running
    case done
    case failed
}

public actor ScanSnapSetupService: ScannerSetupServing {
    private let store: ScannerConfigStore
    private let network: any ScanSnapSetupNetworkProviding
    private let discovery: any ScanSnapSetupDiscovering
    private let pairing: any ScanSnapSetupPairing
    private let environmentConfiguration: ScanSnapSetupEnvironmentConfiguration?
    private let environmentError: String
    private let now: @Sendable () -> Date

    private var status: ScanSnapSetupDiscoveryStatus = .idle
    private var discoveredDevices: [ScanSnapDevice] = []
    private var operationError = ""
    private var discoveryTask: Task<Void, Never>?
    private var discoveryGeneration = 0

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        store: ScannerConfigStore,
        network: any ScanSnapSetupNetworkProviding = SystemScanSnapSetupNetworkProvider(),
        discovery: any ScanSnapSetupDiscovering = ScanSnapDiscoveryActor(),
        pairing: any ScanSnapSetupPairing = ScanSnapPairingActor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.network = network
        self.discovery = discovery
        self.pairing = pairing
        self.now = now
        do {
            environmentConfiguration = try ScanSnapSetupEnvironmentConfiguration(environment: environment)
            environmentError = ""
        } catch {
            environmentConfiguration = nil
            environmentError = Self.message(for: error)
        }
    }

    public func state() async -> ScannerSetupState {
        let stored = await store.loadStored()
        let active = await store.activeConfiguration()
        let displayed = active ?? stored
        let lastError = Self.firstNonEmpty(
            displayed?.lastError,
            operationError,
            environmentError
        )
        return ScannerSetupState(
            serviceAvailable: true,
            configured: active?.status == .configured,
            needsPassword: stored?.status == .needsPassword,
            name: displayed?.name ?? "ScanSnap",
            ipAddress: displayed?.scannerIP ?? "",
            macAddress: displayed?.mac ?? "",
            serial: displayed?.serial ?? "",
            lastError: lastError,
            devices: discoveredDevices.map(Self.setupDevice),
            scannerEnvironment: active?.environmentOverrides ?? [:]
        )
    }

    public func discoveryStatus() -> ScanSnapSetupDiscoveryStatus {
        status
    }

    public func ensureDiscoveryStarted() async {
        guard status == .idle, discoveryTask == nil,
              await store.activeConfiguration() == nil
        else {
            return
        }
        _ = await discover()
    }

    public func discover() async -> ScannerSetupOutcome {
        guard discoveryTask == nil else { return .discoveryStarted }
        status = .running
        operationError = ""
        discoveredDevices = []
        discoveryGeneration += 1
        let generation = discoveryGeneration
        discoveryTask = Task { [weak self] in
            await self?.runDiscovery(generation: generation)
        }
        return .discoveryStarted
    }

    public func waitForDiscovery() async {
        let task = discoveryTask
        await task?.value
    }

    public func cancelDiscovery() async {
        let task = discoveryTask
        discoveryGeneration += 1
        discoveryTask = nil
        status = .idle
        operationError = ""
        task?.cancel()
        await task?.value
    }

    public func select(deviceID: String) async -> ScannerSetupOutcome {
        guard let device = discoveredDevices.first(where: { $0.id == deviceID }) else {
            return .noDevice
        }
        return await configure(SetupDeviceRecord(device))
    }

    public func configureManually(
        ipAddress: String,
        macAddress: String,
        serial: String
    ) async -> ScannerSetupOutcome {
        let normalizedIP: String
        let normalizedMAC: String
        do {
            normalizedIP = try ScannerConfig.normalizeIPv4Address(ipAddress)
            normalizedMAC = macAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : try ScannerConfig.normalizeMACAddress(macAddress)
        } catch {
            operationError = Self.message(for: error)
            return .manualInvalid
        }
        let serial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIP.isEmpty || !normalizedMAC.isEmpty else {
            operationError = "enter a scanner IP address or Ethernet address"
            return .manualInvalid
        }

        if normalizedIP.isEmpty {
            do {
                let device = try await device(withMACAddress: normalizedMAC)
                var record = SetupDeviceRecord(device)
                if record.serial.isEmpty { record.serial = serial }
                return await configure(record)
            } catch is CancellationError {
                return .unavailable
            } catch {
                operationError = Self.message(for: error)
                return .manualNotFound
            }
        }

        var record = SetupDeviceRecord(
            ipAddress: normalizedIP,
            macAddress: normalizedMAC,
            serial: serial,
            name: "ScanSnap"
        )
        do {
            if let found = try await directlyDiscover(scannerIPAddress: normalizedIP) {
                let discovered = SetupDeviceRecord(found)
                if !normalizedMAC.isEmpty, !discovered.macAddress.isEmpty,
                   discovered.macAddress != normalizedMAC {
                    operationError = "the scanner at that IP address answered with a different Ethernet address"
                    return .manualInvalid
                }
                record = discovered
                if record.macAddress.isEmpty { record.macAddress = normalizedMAC }
                if record.serial.isEmpty { record.serial = serial }
            }
        } catch is CancellationError {
            return .unavailable
        } catch {
            // Python setup accepts an IP-only record when direct lookup cannot wake the scanner.
        }
        return await configure(record)
    }

    public func savePassword(_ password: String) async -> ScannerSetupOutcome {
        guard var config = await store.loadStored(), !config.scannerIP.isEmpty else {
            return .setupRequired
        }

        var candidates: [(identity: ScanSnapIdentity, key: String, source: String)] = []
        if let identity = try? ScanSnapIdentity.derive(fromPassword: password) {
            candidates.append((identity, identity.value, "user-password"))
        }
        if !password.isEmpty, !candidates.contains(where: { $0.key == password }) {
            candidates.append((ScanSnapIdentity(password), password, "provided-pairing-key"))
        }

        var lastMessage = "no password was provided"
        for candidate in candidates {
            do {
                let result = try await testPairing(
                    scannerIPAddress: config.scannerIP,
                    identity: candidate.identity
                )
                lastMessage = Self.pairingMessage(result.status)
                guard result.accepted else { continue }
                if let device = result.device {
                    config = Self.merging(config, with: SetupDeviceRecord(device))
                }
                config.status = .configured
                config.pairingKey = candidate.key
                config.passwordSource = candidate.source
                config.lastError = ""
                return await save(config, success: .configured)
            } catch is CancellationError {
                return .unavailable
            } catch {
                lastMessage = Self.message(for: error)
            }
        }

        config.status = .needsPassword
        config.lastError = "Password was rejected: \(lastMessage)."
        return await save(config, success: .passwordFailed)
    }

    public func clear() async -> ScannerSetupOutcome {
        do {
            try await store.clear()
            operationError = ""
            return .cleared
        } catch {
            operationError = Self.message(for: error)
            return .unavailable
        }
    }

    private func runDiscovery(generation: Int) async {
        do {
            let configuration = try await makeDiscoveryConfiguration()
            let devices = try await discovery.discover(configuration: configuration)
            try Task.checkCancellation()
            finishDiscovery(devices, generation: generation)
        } catch is CancellationError {
            finishCancellation(generation: generation)
        } catch {
            finishDiscoveryFailure(error, generation: generation)
        }
    }

    private func finishDiscovery(_ devices: [ScanSnapDevice], generation: Int) {
        guard generation == discoveryGeneration else { return }
        discoveredDevices = Self.deduplicatedAndSorted(devices, prefixes: environmentConfiguration?.macPrefixes ?? [])
        status = .done
        operationError = discoveredDevices.isEmpty
            ? "No ScanSnap scanner was found. Use host networking or enter the scanner IP address manually."
            : ""
        discoveryTask = nil
    }

    private func finishDiscoveryFailure(_ error: any Error, generation: Int) {
        guard generation == discoveryGeneration else { return }
        discoveredDevices = []
        status = .failed
        operationError = Self.message(for: error)
        discoveryTask = nil
    }

    private func finishCancellation(generation: Int) {
        guard generation == discoveryGeneration else { return }
        status = .idle
        discoveryTask = nil
    }

    private func makeDiscoveryConfiguration() async throws -> ScanSnapDiscoveryConfiguration {
        let environment = try requireEnvironment()
        let interfaces = try await discoveryInterfaces(environment: environment)
        let neighbors = (try? await network.arpNeighbors()) ?? []
        let clientMAC: [UInt8]?
        if let configured = environment.clientMACAddress {
            clientMAC = configured
        } else {
            clientMAC = try? await network.clientMACAddress(preferredInterface: environment.clientInterface)
        }
        let routes = interfaces.map { interface in
            ScanSnapDiscoveryRoute(
                clientIPAddress: interface.ipAddress,
                targetIPAddresses: Self.discoveryTargets(
                    interface: interface,
                    neighbors: neighbors,
                    environment: environment
                )
            )
        }
        return ScanSnapDiscoveryConfiguration(
            routes: routes,
            clientMACAddress: clientMAC,
            sourcePort: environment.discoverySourcePort,
            registrationPort: environment.registrationPort,
            rounds: environment.discoveryRounds,
            timeoutMilliseconds: environment.discoveryTimeoutMilliseconds,
            allowsSourcePortFallback: true
        )
    }

    private func discoveryInterfaces(
        environment: ScanSnapSetupEnvironmentConfiguration
    ) async throws -> [ScanSnapSetupIPv4Interface] {
        if let address = environment.clientIPAddress {
            return [try ScanSnapSetupIPv4Interface(name: "configured", ipAddress: address, prefixLength: 24)]
        }
        let interfaces = try await network.ipv4Interfaces()
        guard !interfaces.isEmpty else { throw ScanSnapSetupConfigurationError.noIPv4Interface }
        return interfaces
    }

    private func directlyDiscover(scannerIPAddress: String) async throws -> ScanSnapDevice? {
        let environment = try requireEnvironment()
        let clientIPAddress = try await clientIPAddress(for: scannerIPAddress, environment: environment)
        let clientMAC = try await clientMACAddress(environment: environment)
        let devices = try await discovery.discover(configuration: ScanSnapDiscoveryConfiguration(
            routes: [ScanSnapDiscoveryRoute(
                clientIPAddress: clientIPAddress,
                targetIPAddresses: [scannerIPAddress]
            )],
            clientMACAddress: clientMAC,
            sourcePort: environment.registrationSourcePort,
            registrationPort: environment.registrationPort,
            rounds: 4,
            timeoutMilliseconds: 3_000,
            allowsSourcePortFallback: true
        ))
        return devices.first(where: { $0.ipAddress == scannerIPAddress }) ?? devices.first
    }

    private func device(withMACAddress macAddress: String) async throws -> ScanSnapDevice {
        if let current = discoveredDevices.first(where: { $0.macAddress.lowercased() == macAddress }) {
            return current
        }
        let configuration = try await makeDiscoveryConfiguration()
        let devices = try await discovery.discover(configuration: configuration)
        try Task.checkCancellation()
        discoveredDevices = Self.deduplicatedAndSorted(
            devices,
            prefixes: environmentConfiguration?.macPrefixes ?? []
        )
        status = .done
        guard let found = discoveredDevices.first(where: { $0.macAddress.lowercased() == macAddress }) else {
            throw ScanSnapSetupConfigurationError.systemLookupFailed(
                "no scanner with that Ethernet address was found"
            )
        }
        return found
    }

    private func configure(_ device: SetupDeviceRecord) async -> ScannerSetupOutcome {
        let password = ScannerConfig.password(fromSerial: device.serial)
        guard !password.isEmpty else {
            var config = device.config(status: .needsPassword)
            config.lastError = "Scanner serial was not available; enter the scanner password."
            return await save(config, success: .passwordNeeded)
        }

        let identity: ScanSnapIdentity
        do {
            identity = try ScanSnapIdentity.derive(fromPassword: password)
        } catch {
            var config = device.config(status: .needsPassword)
            config.lastError = Self.message(for: error)
            return await save(config, success: .passwordNeeded)
        }

        do {
            let result = try await testPairing(scannerIPAddress: device.ipAddress, identity: identity)
            guard result.accepted else {
                var config = device.config(status: .needsPassword)
                config.lastError = "Default password \(password.debugDescription) was rejected: \(Self.pairingMessage(result.status))."
                return await save(config, success: .passwordNeeded)
            }
            let configuredDevice = result.device.map(SetupDeviceRecord.init) ?? device
            var config = configuredDevice.config(status: .configured)
            config.pairingKey = identity.value
            config.status = .configured
            config.passwordSource = "serial-default"
            config.lastError = ""
            return await save(config, success: .configured)
        } catch is CancellationError {
            return .unavailable
        } catch {
            var config = device.config(status: .needsPassword)
            config.lastError = "Default password \(password.debugDescription) was rejected: \(Self.message(for: error))."
            return await save(config, success: .passwordNeeded)
        }
    }

    private func testPairing(
        scannerIPAddress: String,
        identity: ScanSnapIdentity
    ) async throws -> ScanSnapPairingResult {
        let environment = try requireEnvironment()
        let clientIPAddress = try await clientIPAddress(for: scannerIPAddress, environment: environment)
        let clientMAC = try await clientMACAddress(environment: environment)
        return try await pairing.pair(
            configuration: ScanSnapPairingConfiguration(
                scannerIPAddress: scannerIPAddress,
                clientIPAddress: clientIPAddress,
                clientMACAddress: clientMAC,
                identity: identity,
                registrationSourcePort: environment.registrationSourcePort,
                registrationPort: environment.registrationPort,
                controlPort: ScanSnapPacketBuilder.controlPort,
                dataPort: ScanSnapPacketBuilder.dataPort,
                registrationRounds: 4,
                registrationTimeoutMilliseconds: 3_000,
                connectionTimeoutMilliseconds: 5_000,
                retryPolicy: .pairingTest,
                allowsSourcePortFallback: true
            ),
            timestamp: Self.timestamp(now())
        )
    }

    private func clientIPAddress(
        for scannerIPAddress: String,
        environment: ScanSnapSetupEnvironmentConfiguration
    ) async throws -> String {
        if let configured = environment.clientIPAddress { return configured }
        return try await network.clientIPAddress(for: scannerIPAddress)
    }

    private func clientMACAddress(
        environment: ScanSnapSetupEnvironmentConfiguration
    ) async throws -> [UInt8] {
        if let configured = environment.clientMACAddress { return configured }
        return try await network.clientMACAddress(preferredInterface: environment.clientInterface)
    }

    private func requireEnvironment() throws -> ScanSnapSetupEnvironmentConfiguration {
        guard let environmentConfiguration else {
            throw ScanSnapSetupConfigurationError.systemLookupFailed(environmentError)
        }
        return environmentConfiguration
    }

    private func save(_ config: ScannerConfig, success: ScannerSetupOutcome) async -> ScannerSetupOutcome {
        do {
            _ = try await store.save(config, now: now())
            operationError = ""
            return success
        } catch {
            operationError = Self.message(for: error)
            return .unavailable
        }
    }

    private static func discoveryTargets(
        interface: ScanSnapSetupIPv4Interface,
        neighbors: [ScanSnapSetupARPNeighbor],
        environment: ScanSnapSetupEnvironmentConfiguration
    ) -> [String] {
        var targets = Set(environment.discoveryTargets)
        targets.insert("255.255.255.255")
        targets.insert(interface.broadcastAddress)
        if let scanner = environment.scannerIPAddress { targets.insert(scanner) }
        for neighbor in neighbors where interface.contains(neighbor.ipAddress) {
            let state = neighbor.state.uppercased()
            guard !state.contains("FAILED"), !state.contains("INCOMPLETE") else { continue }
            let matchesPrefix = environment.macPrefixes.contains {
                neighbor.macAddress.lowercased().hasPrefix($0)
            }
            if environment.includesAllARPNeighbors || matchesPrefix {
                targets.insert(neighbor.ipAddress)
            }
        }
        return targets.sorted()
    }

    private static func deduplicatedAndSorted(
        _ devices: [ScanSnapDevice],
        prefixes: [String]
    ) -> [ScanSnapDevice] {
        var byID: [String: ScanSnapDevice] = [:]
        for device in devices { byID[device.id] = device }
        return byID.values.sorted { lhs, rhs in
            let lhsMatches = prefixes.isEmpty || prefixes.contains { lhs.macAddress.lowercased().hasPrefix($0) }
            let rhsMatches = prefixes.isEmpty || prefixes.contains { rhs.macAddress.lowercased().hasPrefix($0) }
            if lhsMatches != rhsMatches { return lhsMatches }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            if lhs.ipAddress != rhs.ipAddress { return lhs.ipAddress < rhs.ipAddress }
            return lhs.macAddress < rhs.macAddress
        }
    }

    private static func setupDevice(_ device: ScanSnapDevice) -> ScannerSetupDevice {
        ScannerSetupDevice(
            id: device.id,
            name: device.name,
            ipAddress: device.ipAddress,
            macAddress: device.macAddress,
            serial: device.serialNumber
        )
    }

    private static func merging(_ config: ScannerConfig, with device: SetupDeviceRecord) -> ScannerConfig {
        var config = config
        config.scannerIP = device.ipAddress.isEmpty ? config.scannerIP : device.ipAddress
        config.mac = device.macAddress.isEmpty ? config.mac : device.macAddress
        config.serial = device.serial.isEmpty ? config.serial : device.serial
        config.name = device.name.isEmpty ? config.name : device.name
        return config
    }

    private static func pairingMessage(_ status: ScanSnapPairingStatus) -> String {
        switch status {
        case .accepted: "pairing accepted"
        case .badPacket: "bad pairing packet"
        case .serialMismatch: "scanner serial mismatch"
        case .passwordRejected: "password rejected"
        case .sessionBusy: "scanner session busy"
        case .missingSerialData: "scanner response did not include serial data"
        case .pairedToDifferentClientIP: "scanner is paired to a different client IP"
        case let .rejected(code): "pairing rejected with status \(code)"
        }
    }

    private static func timestamp(_ date: Date) -> ScanSnapTimestamp {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return ScanSnapTimestamp(
            year: UInt16(components.year ?? 1970),
            month: UInt8(components.month ?? 1),
            day: UInt8(components.day ?? 1),
            hour: UInt8(components.hour ?? 0),
            minute: UInt8(components.minute ?? 0),
            second: UInt8(components.second ?? 0)
        )
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        values.compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
    }

    private nonisolated static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

private struct SetupDeviceRecord: Sendable {
    var ipAddress: String
    var macAddress: String
    var serial: String
    var name: String

    init(ipAddress: String, macAddress: String, serial: String, name: String) {
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.serial = serial
        self.name = name.isEmpty ? "ScanSnap" : name
    }

    init(_ device: ScanSnapDevice) {
        self.init(
            ipAddress: device.ipAddress,
            macAddress: device.macAddress,
            serial: device.serialNumber,
            name: device.name
        )
    }

    func config(status: ScannerConfig.Status) -> ScannerConfig {
        ScannerConfig(
            status: status,
            scannerIP: ipAddress,
            mac: macAddress,
            serial: serial,
            name: name
        )
    }
}
