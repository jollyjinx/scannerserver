import JLog

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
    private let sleeper: any ScanSnapSleeper

    private var listenerTask: Task<Void, Never>?
    private var armingTask: Task<Void, Never>?
    private var listenerTransport: (any ScanSnapUDPTransport)?
    private var lifecycleGeneration: UInt64 = 0
    private var listenerGeneration: UInt64 = 0
    private var armingGeneration: UInt64 = 0
    private var scannerConfigurationGeneration: UInt64 = 0
    private var acceptsLifecycleOperations = true
    private var isStarting = false
    private var isStopping = false

    private var isRunning = false
    private var boundPort: UInt16?
    private var isArmed = false
    private var isArming = false
    private var buttonScanInFlight = false
    private var rearmRequested = false
    private var recoveryArmRequested = false
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
        clock: any ScanSnapButtonClock = SystemScanSnapButtonClock(),
        sleeper: any ScanSnapSleeper = TaskScanSnapSleeper()
    ) {
        self.configuration = configuration
        self.udpTransportFactory = udpTransportFactory
        self.scannerProvider = scannerProvider
        self.modeProvider = modeProvider
        self.scanDispatcher = scanDispatcher
        self.reachability = reachability
        self.armer = armer
        self.clock = clock
        self.sleeper = sleeper
    }

    @discardableResult
    public func start() async throws -> Bool {
        guard configuration.isEnabled else { return false }
        guard listenerTask == nil, !isStarting, !isStopping else { return false }

        lifecycleGeneration &+= 1
        let lifecycleGeneration = lifecycleGeneration
        acceptsLifecycleOperations = true
        isStarting = true
        scannerConfigurationGeneration &+= 1

        var transport: (any ScanSnapUDPTransport)?
        do {
            let newTransport = try await udpTransportFactory.makeTransport()
            transport = newTransport
            guard isCurrentLifecycle(lifecycleGeneration), isStarting else {
                await newTransport.close()
                return false
            }
            listenerTransport = newTransport

            let port = try await newTransport.bind(
                to: .anyIPv4(port: configuration.listenerPort),
                allowsBroadcast: false
            )
            guard isCurrentLifecycle(lifecycleGeneration), isStarting else {
                await newTransport.close()
                return false
            }
            let now = await clock.nowMilliseconds()
            guard isCurrentLifecycle(lifecycleGeneration), isStarting else {
                await newTransport.close()
                return false
            }

            listenerGeneration &+= 1
            let listenerGeneration = listenerGeneration
            boundPort = port
            isRunning = true
            isStarting = false
            nextReachabilityAtMilliseconds = now
            listenerTask = Task { [weak self] in
                await self?.superviseListener(
                    startingWith: newTransport,
                    listenerGeneration: listenerGeneration,
                    lifecycleGeneration: lifecycleGeneration
                )
            }
            return true
        } catch {
            let shouldThrow = isCurrentLifecycle(lifecycleGeneration)
            if shouldThrow {
                isStarting = false
                listenerTransport = nil
                boundPort = nil
                isRunning = false
            }
            await transport?.close()
            guard shouldThrow else { return false }
            throw error
        }
    }

    public func stop() async {
        if isStopping {
            await listenerTask?.value
            await armingTask?.value
            return
        }

        isStopping = true
        acceptsLifecycleOperations = false
        lifecycleGeneration &+= 1
        listenerGeneration &+= 1
        armingGeneration &+= 1
        scannerConfigurationGeneration &+= 1
        let listener = listenerTask
        let arming = armingTask
        let transport = listenerTransport
        isStarting = false
        isRunning = false
        isArming = false
        isArmed = false
        buttonScanInFlight = false
        rearmRequested = false
        recoveryArmRequested = false
        nextArmAtMilliseconds = nil
        lastScannerConfiguration = nil
        listener?.cancel()
        arming?.cancel()
        await transport?.close()
        await listener?.value
        await arming?.value
        listenerTask = nil
        armingTask = nil
        listenerTransport = nil
        boundPort = nil
        isStopping = false
    }

    public func processNotice(_ datagram: ScanSnapDatagram) async -> ScanSnapButtonNoticeResult {
        let lifecycleGeneration = lifecycleGeneration
        let now = await clock.nowMilliseconds()
        return await processNotice(
            datagram,
            atMilliseconds: now,
            lifecycleGeneration: lifecycleGeneration
        )
    }

    public func processNotice(
        _ datagram: ScanSnapDatagram,
        atMilliseconds now: UInt64
    ) async -> ScanSnapButtonNoticeResult {
        await processNotice(
            datagram,
            atMilliseconds: now,
            lifecycleGeneration: lifecycleGeneration
        )
    }

    private func processNotice(
        _ datagram: ScanSnapDatagram,
        atMilliseconds now: UInt64,
        lifecycleGeneration: UInt64
    ) async -> ScanSnapButtonNoticeResult {
        guard configuration.isEnabled, isCurrentLifecycle(lifecycleGeneration) else {
            return .ignored(.disabled)
        }

        let scanner: ScanSnapButtonScannerConfiguration
        do {
            guard let configuredScanner = try await scannerProvider.currentButtonScannerConfiguration() else {
                return .ignored(.scannerNotConfigured)
            }
            scanner = configuredScanner
        } catch {
            return .ignored(.dependencyFailure)
        }
        guard isCurrentLifecycle(lifecycleGeneration) else { return .ignored(.disabled) }

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
        let scanIsRunning = await scanDispatcher.isScanRunning()
        guard isCurrentLifecycle(lifecycleGeneration) else { return .ignored(.disabled) }
        if scanIsRunning {
            return .ignored(.scanRunning)
        }

        let mode: ScanMode
        do {
            mode = try await modeProvider.currentButtonDefaultMode()
        } catch {
            return .ignored(.dependencyFailure)
        }
        guard isCurrentLifecycle(lifecycleGeneration) else { return .ignored(.disabled) }

        lastButtonStartedAtMilliseconds = now
        buttonScanInFlight = true
        let scanStarted = await scanDispatcher.startButtonScan(mode: mode)
        guard isCurrentLifecycle(lifecycleGeneration) else { return .ignored(.disabled) }
        guard scanStarted else {
            buttonScanInFlight = false
            return .ignored(.scanStartRejected)
        }

        isArmed = false
        nextArmAtMilliseconds = nil
        cancelArming()
        return .scanStarted(modeID: mode.id)
    }

    public func runMaintenance() async {
        let lifecycleGeneration = lifecycleGeneration
        let now = await clock.nowMilliseconds()
        await runMaintenance(atMilliseconds: now, lifecycleGeneration: lifecycleGeneration)
    }

    public func runMaintenance(atMilliseconds now: UInt64) async {
        await runMaintenance(atMilliseconds: now, lifecycleGeneration: lifecycleGeneration)
    }

    private func runMaintenance(
        atMilliseconds now: UInt64,
        lifecycleGeneration: UInt64
    ) async {
        guard isCurrentLifecycle(lifecycleGeneration) else { return }

        let scanner: ScanSnapButtonScannerConfiguration
        do {
            guard let configuredScanner = try await scannerProvider.currentButtonScannerConfiguration() else {
                guard isCurrentLifecycle(lifecycleGeneration) else { return }
                resetForMissingScanner(retryAt: adding(configuration.reachabilityIntervalMilliseconds, to: now))
                return
            }
            scanner = configuredScanner
        } catch {
            guard isCurrentLifecycle(lifecycleGeneration) else { return }
            nextReachabilityAtMilliseconds = adding(configuration.reachabilityIntervalMilliseconds, to: now)
            return
        }
        guard isCurrentLifecycle(lifecycleGeneration) else { return }

        if let previous = lastScannerConfiguration, previous != scanner {
            resetForScannerChange(atMilliseconds: now)
        }
        lastScannerConfiguration = scanner

        guard !buttonScanInFlight, !isArming else { return }
        let scanIsRunning = await scanDispatcher.isScanRunning()
        guard isCurrentLifecycle(lifecycleGeneration), !scanIsRunning else { return }

        if rearmRequested {
            rearmRequested = false
            await checkReachabilityAndArm(
                scanner: scanner,
                now: now,
                lifecycleGeneration: lifecycleGeneration
            )
            return
        }
        if isArmed, let nextArmAtMilliseconds, now >= nextArmAtMilliseconds {
            beginArming(scanner: scanner, lifecycleGeneration: lifecycleGeneration)
            return
        }
        if !isArmed, now >= nextReachabilityAtMilliseconds {
            await checkReachabilityAndArm(
                scanner: scanner,
                now: now,
                lifecycleGeneration: lifecycleGeneration
            )
        }
    }

    public func scanDidFinish(succeeded: Bool = true) async {
        let lifecycleGeneration = lifecycleGeneration
        let now = await clock.nowMilliseconds()
        guard isCurrentLifecycle(lifecycleGeneration) else { return }
        scanDidFinish(succeeded: succeeded, atMilliseconds: now)
    }

    public func scanDidFinish(succeeded: Bool = true, atMilliseconds now: UInt64) {
        guard acceptsLifecycleOperations else { return }
        buttonScanInFlight = false
        lastScanCompletedAtMilliseconds = now
        isArmed = false
        nextArmAtMilliseconds = nil
        rearmRequested = true
        recoveryArmRequested = recoveryArmRequested || !succeeded
    }

    public func scannerConfigurationDidChange() async {
        let lifecycleGeneration = lifecycleGeneration
        let now = await clock.nowMilliseconds()
        guard isCurrentLifecycle(lifecycleGeneration) else { return }
        resetForScannerChange(atMilliseconds: now)
    }

    public func requestRearm() {
        guard acceptsLifecycleOperations else { return }
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

    private func superviseListener(
        startingWith initialTransport: any ScanSnapUDPTransport,
        listenerGeneration: UInt64,
        lifecycleGeneration: UInt64
    ) async {
        var transport: (any ScanSnapUDPTransport)? = initialTransport
        var consecutiveFailures = 0

        while !Task.isCancelled, isCurrentListener(
            listenerGeneration: listenerGeneration,
            lifecycleGeneration: lifecycleGeneration
        ) {
            if transport == nil {
                do {
                    try await sleeper.sleep(
                        milliseconds: listenerRetryDelayMilliseconds(after: consecutiveFailures)
                    )
                    try Task.checkCancellation()
                    guard isCurrentListener(
                        listenerGeneration: listenerGeneration,
                        lifecycleGeneration: lifecycleGeneration
                    ) else { break }

                    let replacement = try await udpTransportFactory.makeTransport()
                    guard isCurrentListener(
                        listenerGeneration: listenerGeneration,
                        lifecycleGeneration: lifecycleGeneration
                    ) else {
                        await replacement.close()
                        break
                    }
                    do {
                        let port = try await replacement.bind(
                            to: .anyIPv4(port: configuration.listenerPort),
                            allowsBroadcast: false
                        )
                        guard isCurrentListener(
                            listenerGeneration: listenerGeneration,
                            lifecycleGeneration: lifecycleGeneration
                        ) else {
                            await replacement.close()
                            break
                        }
                        transport = replacement
                        listenerTransport = replacement
                        boundPort = port
                        isRunning = true
                    } catch {
                        await replacement.close()
                        throw error
                    }
                } catch is CancellationError {
                    break
                } catch {
                    consecutiveFailures = min(consecutiveFailures + 1, 64)
                    JLog.warning("ScanSnap button listener restart failed: \(error)")
                    continue
                }
            }

            guard let activeTransport = transport else { continue }
            do {
                let now = await clock.nowMilliseconds()
                guard isCurrentListener(
                    listenerGeneration: listenerGeneration,
                    lifecycleGeneration: lifecycleGeneration
                ) else { break }
                await runMaintenance(
                    atMilliseconds: now,
                    lifecycleGeneration: lifecycleGeneration
                )
                guard isCurrentListener(
                    listenerGeneration: listenerGeneration,
                    lifecycleGeneration: lifecycleGeneration
                ) else { break }

                let datagram = try await activeTransport.receive(
                    maximumBytes: 2_048,
                    timeoutMilliseconds: configuration.listenerPollMilliseconds
                )
                guard isCurrentListener(
                    listenerGeneration: listenerGeneration,
                    lifecycleGeneration: lifecycleGeneration
                ) else { break }
                consecutiveFailures = 0
                if let datagram {
                    _ = await processNotice(
                        datagram,
                        atMilliseconds: await clock.nowMilliseconds(),
                        lifecycleGeneration: lifecycleGeneration
                    )
                }
            } catch is CancellationError {
                break
            } catch {
                consecutiveFailures = min(consecutiveFailures + 1, 64)
                JLog.warning("ScanSnap button listener failed; retrying: \(error)")
                await activeTransport.close()
                transport = nil
                listenerTransport = nil
                boundPort = nil
                isRunning = false
            }
        }

        await transport?.close()
        finishListener(
            listenerGeneration: listenerGeneration,
            lifecycleGeneration: lifecycleGeneration
        )
    }

    private func finishListener(listenerGeneration: UInt64, lifecycleGeneration: UInt64) {
        guard isCurrentListener(
            listenerGeneration: listenerGeneration,
            lifecycleGeneration: lifecycleGeneration
        ) else { return }
        listenerTask = nil
        listenerTransport = nil
        boundPort = nil
        isRunning = false
    }

    private func checkReachabilityAndArm(
        scanner: ScanSnapButtonScannerConfiguration,
        now: UInt64,
        lifecycleGeneration: UInt64
    ) async {
        guard isCurrentLifecycle(lifecycleGeneration) else { return }
        nextReachabilityAtMilliseconds = adding(configuration.reachabilityIntervalMilliseconds, to: now)
        let scannerConfigurationGeneration = scannerConfigurationGeneration
        let reachable = await reachability.isReachable(
            scanner: scanner,
            port: configuration.reachabilityPort,
            timeoutMilliseconds: configuration.reachabilityTimeoutMilliseconds
        )
        guard isCurrentLifecycle(lifecycleGeneration),
              scannerConfigurationGeneration == self.scannerConfigurationGeneration,
              scanner == lastScannerConfiguration
        else {
            return
        }
        guard reachable else {
            isArmed = false
            return
        }
        beginArming(scanner: scanner, lifecycleGeneration: lifecycleGeneration)
    }

    private func beginArming(
        scanner: ScanSnapButtonScannerConfiguration,
        lifecycleGeneration: UInt64
    ) {
        guard isCurrentLifecycle(lifecycleGeneration), !isArming else { return }
        isArming = true
        nextArmAtMilliseconds = nil
        armingGeneration &+= 1
        let generation = armingGeneration
        let isRecovery = recoveryArmRequested
        armingTask = Task { [weak self, armer, configuration] in
            let succeeded: Bool
            do {
                if isRecovery {
                    try await armer.recoverAndArm(scanner: scanner, configuration: configuration)
                } else {
                    try await armer.arm(scanner: scanner, configuration: configuration)
                }
                succeeded = true
            } catch is CancellationError {
                succeeded = false
            } catch {
                JLog.warning("ScanSnap button \(isRecovery ? "recovery " : "")arming failed: \(error)")
                succeeded = false
            }
            await self?.finishArming(
                succeeded: succeeded,
                generation: generation,
                lifecycleGeneration: lifecycleGeneration
            )
        }
    }

    private func finishArming(
        succeeded: Bool,
        generation: UInt64,
        lifecycleGeneration: UInt64
    ) async {
        guard isCurrentLifecycle(lifecycleGeneration), generation == armingGeneration else { return }
        let now = await clock.nowMilliseconds()
        guard isCurrentLifecycle(lifecycleGeneration), generation == armingGeneration else { return }
        armingTask = nil
        isArming = false
        isArmed = succeeded
        if succeeded {
            recoveryArmRequested = false
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
        recoveryArmRequested = false
    }

    private func isWithin(_ interval: UInt64, of earlier: UInt64?, at now: UInt64) -> Bool {
        guard interval > 0, let earlier, now >= earlier else { return false }
        return now - earlier < interval
    }

    private func adding(_ interval: UInt64, to instant: UInt64) -> UInt64 {
        let (result, overflow) = instant.addingReportingOverflow(interval)
        return overflow ? .max : result
    }

    private func isCurrentLifecycle(_ generation: UInt64) -> Bool {
        acceptsLifecycleOperations && generation == lifecycleGeneration
    }

    private func isCurrentListener(
        listenerGeneration: UInt64,
        lifecycleGeneration: UInt64
    ) -> Bool {
        listenerGeneration == self.listenerGeneration && isCurrentLifecycle(lifecycleGeneration)
    }

    private func listenerRetryDelayMilliseconds(after failureCount: Int) -> UInt64 {
        let exponent = min(max(failureCount - 1, 0), 5)
        return min(100 << exponent, 3_000)
    }
}
