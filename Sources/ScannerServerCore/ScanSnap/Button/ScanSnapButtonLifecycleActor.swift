public enum ScanSnapButtonNoticeIgnoreReason: Sendable, Hashable {
    case disabled
    case scannerNotConfigured
    case unexpectedSource
    case invalidNotice
    case debounce
    case cooldown
    case scanRunning
    case scanStartRejected
    case dependencyFailure
}

public enum ScanSnapButtonNoticeResult: Sendable, Hashable {
    case ignored(ScanSnapButtonNoticeIgnoreReason)
    case scanStarted(modeID: String)
}

public struct ScanSnapButtonLifecycleState: Sendable, Hashable {
    public let isRunning: Bool
    public let boundPort: UInt16?
    public let isArmed: Bool
    public let isArming: Bool
    public let buttonScanInFlight: Bool
    public let rearmRequested: Bool
    public let nextArmAtMilliseconds: UInt64?
    public let nextReachabilityAtMilliseconds: UInt64
    public let lastButtonStartedAtMilliseconds: UInt64?
    public let lastScanCompletedAtMilliseconds: UInt64?
}

public actor ScanSnapButtonLifecycleActor {
    private let configuration: ScanSnapButtonConfiguration
    private let udpTransportFactory: any ScanSnapUDPTransportFactory
    private let scannerProvider: any ScanSnapButtonScannerConfigurationProviding
    private let modeProvider: any ScanSnapButtonModeProviding
    private let scanDispatcher: any ScanSnapButtonScanDispatching
    private let reachability: any ScanSnapButtonReachabilityChecking
    private let armer: any ScanSnapButtonArming
    private let clock: any ScanSnapButtonClock

    private var listenerTask: Task<Void, Never>?
    private var armingTask: Task<Void, Never>?
    private var listenerTransport: (any ScanSnapUDPTransport)?
    private var listenerGeneration: UInt64 = 0
    private var armingGeneration: UInt64 = 0
    private var scannerConfigurationGeneration: UInt64 = 0
    private var acceptsArmingResults = true

    private var isRunning = false
    private var boundPort: UInt16?
    private var isArmed = false
    private var isArming = false
    private var buttonScanInFlight = false
    private var rearmRequested = false
    private var nextArmAtMilliseconds: UInt64?
    private var nextReachabilityAtMilliseconds: UInt64 = 0
    private var lastButtonStartedAtMilliseconds: UInt64?
    private var lastScanCompletedAtMilliseconds: UInt64?
    private var lastScannerConfiguration: ScanSnapButtonScannerConfiguration?

    public init(
        configuration: ScanSnapButtonConfiguration = ScanSnapButtonConfiguration(),
        udpTransportFactory: any ScanSnapUDPTransportFactory = POSIXScanSnapUDPTransportFactory(),
        scannerProvider: any ScanSnapButtonScannerConfigurationProviding,
        modeProvider: any ScanSnapButtonModeProviding,
        scanDispatcher: any ScanSnapButtonScanDispatching,
        reachability: any ScanSnapButtonReachabilityChecking = ScanSnapButtonTCPReachabilityChecker(),
        armer: any ScanSnapButtonArming = ScanSnapButtonSessionArmer(),
        clock: any ScanSnapButtonClock = SystemScanSnapButtonClock()
    ) {
        self.configuration = configuration
        self.udpTransportFactory = udpTransportFactory
        self.scannerProvider = scannerProvider
        self.modeProvider = modeProvider
        self.scanDispatcher = scanDispatcher
        self.reachability = reachability
        self.armer = armer
        self.clock = clock
    }

    @discardableResult
    public func start() async throws -> Bool {
        guard configuration.isEnabled else { return false }
        guard listenerTask == nil else { return false }

        let transport = try await udpTransportFactory.makeTransport()
        do {
            let port = try await transport.bind(
                to: .anyIPv4(port: configuration.listenerPort),
                allowsBroadcast: false
            )
            listenerGeneration &+= 1
            let generation = listenerGeneration
            listenerTransport = transport
            boundPort = port
            isRunning = true
            acceptsArmingResults = true
            nextReachabilityAtMilliseconds = await clock.nowMilliseconds()
            listenerTask = Task { [weak self] in
                await self?.listen(using: transport, generation: generation)
            }
            return true
        } catch {
            await transport.close()
            throw error
        }
    }

    public func stop() async {
        acceptsArmingResults = false
        listenerGeneration &+= 1
        armingGeneration &+= 1
        let listener = listenerTask
        let arming = armingTask
        listenerTask = nil
        armingTask = nil
        isRunning = false
        isArming = false
        isArmed = false
        buttonScanInFlight = false
        nextArmAtMilliseconds = nil
        listener?.cancel()
        arming?.cancel()
        await listenerTransport?.close()
        await listener?.value
        await arming?.value
        listenerTransport = nil
        boundPort = nil
    }

    public func processNotice(_ datagram: ScanSnapDatagram) async -> ScanSnapButtonNoticeResult {
        await processNotice(datagram, atMilliseconds: clock.nowMilliseconds())
    }

    public func processNotice(
        _ datagram: ScanSnapDatagram,
        atMilliseconds now: UInt64
    ) async -> ScanSnapButtonNoticeResult {
        guard configuration.isEnabled else { return .ignored(.disabled) }

        let scanner: ScanSnapButtonScannerConfiguration
        do {
            guard let configuredScanner = try await scannerProvider.currentButtonScannerConfiguration() else {
                return .ignored(.scannerNotConfigured)
            }
            scanner = configuredScanner
        } catch {
            return .ignored(.dependencyFailure)
        }

        guard datagram.remoteAddress.host == scanner.scannerIPAddress else {
            return .ignored(.unexpectedSource)
        }
        guard Self.isButtonNotice(datagram.bytes) else {
            return .ignored(.invalidNotice)
        }
        if isWithin(
            configuration.debounceMilliseconds,
            of: lastButtonStartedAtMilliseconds,
            at: now
        ) {
            return .ignored(.debounce)
        }
        if isWithin(
            configuration.cooldownMilliseconds,
            of: lastScanCompletedAtMilliseconds,
            at: now
        ) {
            return .ignored(.cooldown)
        }
        if buttonScanInFlight {
            return .ignored(.scanRunning)
        }
        if await scanDispatcher.isScanRunning() {
            return .ignored(.scanRunning)
        }

        let mode: ScanMode
        do {
            mode = try await modeProvider.currentButtonDefaultMode()
        } catch {
            return .ignored(.dependencyFailure)
        }

        lastButtonStartedAtMilliseconds = now
        buttonScanInFlight = true
        guard await scanDispatcher.startButtonScan(mode: mode) else {
            buttonScanInFlight = false
            return .ignored(.scanStartRejected)
        }

        isArmed = false
        nextArmAtMilliseconds = nil
        cancelArming()
        return .scanStarted(modeID: mode.id)
    }

    public func runMaintenance() async {
        await runMaintenance(atMilliseconds: clock.nowMilliseconds())
    }

    public func runMaintenance(atMilliseconds now: UInt64) async {
        let scanner: ScanSnapButtonScannerConfiguration
        do {
            guard let configuredScanner = try await scannerProvider.currentButtonScannerConfiguration() else {
                resetForMissingScanner(retryAt: adding(configuration.reachabilityIntervalMilliseconds, to: now))
                return
            }
            scanner = configuredScanner
        } catch {
            nextReachabilityAtMilliseconds = adding(configuration.reachabilityIntervalMilliseconds, to: now)
            return
        }

        if let previous = lastScannerConfiguration, previous != scanner {
            resetForScannerChange(atMilliseconds: now)
        }
        lastScannerConfiguration = scanner

        guard !buttonScanInFlight, !(await scanDispatcher.isScanRunning()), !isArming else { return }

        if rearmRequested {
            rearmRequested = false
            await checkReachabilityAndArm(scanner: scanner, now: now)
            return
        }
        if isArmed, let nextArmAtMilliseconds, now >= nextArmAtMilliseconds {
            beginArming(scanner: scanner)
            return
        }
        if !isArmed, now >= nextReachabilityAtMilliseconds {
            await checkReachabilityAndArm(scanner: scanner, now: now)
        }
    }

    public func scanDidFinish() async {
        await scanDidFinish(atMilliseconds: clock.nowMilliseconds())
    }

    public func scanDidFinish(atMilliseconds now: UInt64) {
        buttonScanInFlight = false
        lastScanCompletedAtMilliseconds = now
        isArmed = false
        nextArmAtMilliseconds = nil
        rearmRequested = true
    }

    public func scannerConfigurationDidChange() async {
        resetForScannerChange(atMilliseconds: await clock.nowMilliseconds())
    }

    public func requestRearm() {
        rearmRequested = true
        isArmed = false
        nextArmAtMilliseconds = nil
    }

    public var state: ScanSnapButtonLifecycleState {
        ScanSnapButtonLifecycleState(
            isRunning: isRunning,
            boundPort: boundPort,
            isArmed: isArmed,
            isArming: isArming,
            buttonScanInFlight: buttonScanInFlight,
            rearmRequested: rearmRequested,
            nextArmAtMilliseconds: nextArmAtMilliseconds,
            nextReachabilityAtMilliseconds: nextReachabilityAtMilliseconds,
            lastButtonStartedAtMilliseconds: lastButtonStartedAtMilliseconds,
            lastScanCompletedAtMilliseconds: lastScanCompletedAtMilliseconds
        )
    }

    public static func isButtonNotice(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 12 && Array(bytes[4..<8]) == Array("VENS".utf8)
    }

    private func listen(using transport: any ScanSnapUDPTransport, generation: UInt64) async {
        do {
            while !Task.isCancelled {
                await runMaintenance()
                if let datagram = try await transport.receive(
                    maximumBytes: 2_048,
                    timeoutMilliseconds: configuration.listenerPollMilliseconds
                ) {
                    _ = await processNotice(datagram)
                }
            }
        } catch is CancellationError {
            // Normal service shutdown.
        } catch {
            // A transport failure ends this listener generation; integration may restart it.
        }
        await transport.close()
        finishListener(generation: generation)
    }

    private func finishListener(generation: UInt64) {
        guard generation == listenerGeneration else { return }
        listenerTask = nil
        listenerTransport = nil
        boundPort = nil
        isRunning = false
    }

    private func checkReachabilityAndArm(
        scanner: ScanSnapButtonScannerConfiguration,
        now: UInt64
    ) async {
        nextReachabilityAtMilliseconds = adding(configuration.reachabilityIntervalMilliseconds, to: now)
        let generation = scannerConfigurationGeneration
        let reachable = await reachability.isReachable(
            scanner: scanner,
            port: configuration.reachabilityPort,
            timeoutMilliseconds: configuration.reachabilityTimeoutMilliseconds
        )
        guard generation == scannerConfigurationGeneration,
              scanner == lastScannerConfiguration
        else {
            return
        }
        guard reachable else {
            isArmed = false
            return
        }
        beginArming(scanner: scanner)
    }

    private func beginArming(scanner: ScanSnapButtonScannerConfiguration) {
        guard !isArming else { return }
        isArming = true
        nextArmAtMilliseconds = nil
        armingGeneration &+= 1
        let generation = armingGeneration
        armingTask = Task { [weak self, armer, configuration] in
            let succeeded: Bool
            do {
                try await armer.arm(scanner: scanner, configuration: configuration)
                succeeded = true
            } catch {
                succeeded = false
            }
            await self?.finishArming(succeeded: succeeded, generation: generation)
        }
    }

    private func finishArming(succeeded: Bool, generation: UInt64) async {
        guard acceptsArmingResults, generation == armingGeneration else { return }
        armingTask = nil
        isArming = false
        isArmed = succeeded
        let now = await clock.nowMilliseconds()
        if succeeded {
            nextArmAtMilliseconds = adding(configuration.armIntervalMilliseconds, to: now)
        } else {
            nextArmAtMilliseconds = nil
            nextReachabilityAtMilliseconds = adding(configuration.reachabilityIntervalMilliseconds, to: now)
        }
    }

    private func cancelArming() {
        armingGeneration &+= 1
        armingTask?.cancel()
        armingTask = nil
        isArming = false
    }

    private func resetForMissingScanner(retryAt: UInt64) {
        scannerConfigurationGeneration &+= 1
        cancelArming()
        lastScannerConfiguration = nil
        isArmed = false
        nextArmAtMilliseconds = nil
        nextReachabilityAtMilliseconds = retryAt
    }

    private func resetForScannerChange(atMilliseconds now: UInt64) {
        scannerConfigurationGeneration &+= 1
        cancelArming()
        lastScannerConfiguration = nil
        isArmed = false
        nextArmAtMilliseconds = nil
        nextReachabilityAtMilliseconds = now
        rearmRequested = false
    }

    private func isWithin(_ interval: UInt64, of earlier: UInt64?, at now: UInt64) -> Bool {
        guard interval > 0, let earlier, now >= earlier else { return false }
        return now - earlier < interval
    }

    private func adding(_ interval: UInt64, to instant: UInt64) -> UInt64 {
        let (result, overflow) = instant.addingReportingOverflow(interval)
        return overflow ? .max : result
    }
}
