import ScannerServerCore
import Testing

@Test("Button notices require configured source IP and VENS marker")
func buttonNoticeFiltering() async {
    let scannerProvider = ButtonFakeScannerProvider()
    let dispatcher = ButtonFakeScanDispatcher()
    let lifecycle = makeLifecycle(scannerProvider: scannerProvider, dispatcher: dispatcher)

    #expect(await lifecycle.processNotice(
        buttonNotice(source: "192.168.1.99"),
        atMilliseconds: 10_000
    ) == .ignored(.unexpectedSource))
    #expect(await lifecycle.processNotice(
        buttonNotice(bytes: [UInt8](repeating: 0, count: 12)),
        atMilliseconds: 10_000
    ) == .ignored(.invalidNotice))

    await scannerProvider.set(nil)
    #expect(await lifecycle.processNotice(
        buttonNotice(),
        atMilliseconds: 10_000
    ) == .ignored(.scannerNotConfigured))
    #expect(await dispatcher.startedModes.isEmpty)
}

@Test("Accepted notice dispatches default mode and enforces debounce and cooldown")
func acceptedButtonScanDebounceAndCooldown() async {
    let mode = buttonMode(id: "receipts")
    let dispatcher = ButtonFakeScanDispatcher()
    let lifecycle = makeLifecycle(
        configuration: ScanSnapButtonConfiguration(
            debounceMilliseconds: 3_000,
            cooldownMilliseconds: 1_000
        ),
        modeProvider: ButtonFakeModeProvider(mode: mode),
        dispatcher: dispatcher
    )

    #expect(await lifecycle.processNotice(
        buttonNotice(),
        atMilliseconds: 10_000
    ) == .scanStarted(modeID: "receipts"))
    #expect(await lifecycle.processNotice(
        buttonNotice(),
        atMilliseconds: 12_000
    ) == .ignored(.debounce))

    await lifecycle.scanDidFinish(atMilliseconds: 14_000)
    #expect(await lifecycle.processNotice(
        buttonNotice(),
        atMilliseconds: 14_500
    ) == .ignored(.cooldown))
    #expect(await lifecycle.processNotice(
        buttonNotice(),
        atMilliseconds: 15_000
    ) == .scanStarted(modeID: "receipts"))

    #expect(await dispatcher.startedModes.map(\.id) == ["receipts", "receipts"])
    #expect(await lifecycle.state.buttonScanInFlight)
}

@Test("Busy scans defer arming; unreachable scanners retry and post-scan hook rearms")
func busyReachabilityRetryAndRearm() async {
    let dispatcher = ButtonFakeScanDispatcher()
    await dispatcher.setBusy(true)
    let reachability = ButtonFakeReachability([false, true, true])
    let armer = ButtonFakeArmer()
    let clock = ButtonFakeClock(0)
    let configuration = ScanSnapButtonConfiguration(
        armIntervalMilliseconds: 60_000,
        reachabilityPort: 53_219,
        reachabilityTimeoutMilliseconds: 700,
        reachabilityIntervalMilliseconds: 3_000
    )
    let lifecycle = makeLifecycle(
        configuration: configuration,
        dispatcher: dispatcher,
        reachability: reachability,
        armer: armer,
        clock: clock
    )

    #expect(await lifecycle.processNotice(
        buttonNotice(),
        atMilliseconds: 1_000
    ) == .ignored(.scanRunning))
    await lifecycle.runMaintenance(atMilliseconds: 0)
    #expect(await reachability.calls.isEmpty)

    await dispatcher.setBusy(false)
    await lifecycle.runMaintenance(atMilliseconds: 0)
    #expect(await reachability.calls.count == 1)
    #expect(await lifecycle.state.nextReachabilityAtMilliseconds == 3_000)

    await lifecycle.runMaintenance(atMilliseconds: 2_999)
    #expect(await reachability.calls.count == 1)
    await clock.set(3_000)
    await lifecycle.runMaintenance(atMilliseconds: 3_000)
    #expect(await eventually { await lifecycle.state.isArmed })
    #expect(await armer.calls.count == 1)
    #expect(await reachability.calls.last?.port == 53_219)
    #expect(await reachability.calls.last?.timeoutMilliseconds == 700)

    #expect(await lifecycle.processNotice(
        buttonNotice(),
        atMilliseconds: 10_000
    ) == .scanStarted(modeID: "button-default"))
    await lifecycle.scanDidFinish(atMilliseconds: 12_000)
    #expect(await lifecycle.state.rearmRequested)
    await clock.set(12_000)
    await lifecycle.runMaintenance(atMilliseconds: 12_000)
    #expect(await eventually { await armer.calls.count == 2 })
    #expect(await eventually { await lifecycle.state.isArmed })
}

@Test("Configuration-change hook disarms and schedules an immediate reachable rearm")
func configurationChangeRearmHook() async {
    let reachability = ButtonFakeReachability([true, true])
    let armer = ButtonFakeArmer()
    let clock = ButtonFakeClock(2_000)
    let lifecycle = makeLifecycle(reachability: reachability, armer: armer, clock: clock)

    await lifecycle.runMaintenance(atMilliseconds: 2_000)
    #expect(await eventually { await lifecycle.state.isArmed })

    await lifecycle.scannerConfigurationDidChange()
    #expect(!(await lifecycle.state.isArmed))
    #expect(await lifecycle.state.nextReachabilityAtMilliseconds == 2_000)
    await lifecycle.runMaintenance(atMilliseconds: 2_000)
    #expect(await eventually { await armer.calls.count == 2 })
}

@Test("Stop cancels listener and in-progress arming and closes UDP transport")
func buttonLifecycleCancellationAndShutdown() async throws {
    let transport = ButtonFakeUDPTransport(boundPort: 50_555)
    let factory = ButtonFakeUDPFactory(transport: transport)
    let armer = ButtonFakeArmer(behavior: .waitForCancellation)
    let lifecycle = makeLifecycle(
        configuration: ScanSnapButtonConfiguration(listenerPort: 50_001),
        udpFactory: factory,
        reachability: ButtonFakeReachability([true]),
        armer: armer
    )

    #expect(try await lifecycle.start())
    #expect(await eventually { await lifecycle.state.isArming })
    #expect(await lifecycle.state.boundPort == 50_555)
    #expect(await transport.bindCalls == [.anyIPv4(port: 50_001)])

    await lifecycle.stop()

    #expect(await transport.isClosed)
    #expect(await armer.wasCancelled)
    let state = await lifecycle.state
    #expect(!state.isRunning)
    #expect(!state.isArming)
    #expect(state.boundPort == nil)
}

@Test("Stop invalidates suspended notice processing and restart accepts new work")
func stopInvalidatesSuspendedNoticeProcessing() async throws {
    let gate = ButtonAsyncGate()
    let scannerProvider = ButtonGatedScannerProvider(gate: gate)
    let dispatcher = ButtonFakeScanDispatcher()
    let transport = ButtonFakeUDPTransport(boundPort: 55_265)
    let lifecycle = makeLifecycle(
        udpFactory: ButtonFakeUDPFactory(transport: transport),
        scannerProvider: scannerProvider,
        dispatcher: dispatcher
    )

    let noticeTask = Task {
        await lifecycle.processNotice(buttonNotice(), atMilliseconds: 10_000)
    }
    #expect(await eventually { await gate.waiterCount == 1 })

    await lifecycle.stop()
    await gate.releaseAll()

    #expect(await noticeTask.value == .ignored(.disabled))
    #expect(await dispatcher.startedModes.isEmpty)

    #expect(try await lifecycle.start())
    #expect(await lifecycle.processNotice(
        buttonNotice(),
        atMilliseconds: 20_000
    ) == .scanStarted(modeID: "button-default"))
    #expect(await dispatcher.startedModes.map(\.id) == ["button-default"])
    await lifecycle.stop()
}

@Test("Stop invalidates suspended maintenance without poisoning restart arming")
func stopInvalidatesSuspendedMaintenance() async throws {
    let gate = ButtonAsyncGate()
    let scannerProvider = ButtonGatedScannerProvider(gate: gate)
    let armer = ButtonFakeArmer()
    let lifecycle = makeLifecycle(
        udpFactory: ButtonFakeUDPFactory(),
        scannerProvider: scannerProvider,
        armer: armer
    )

    let maintenanceTask = Task {
        await lifecycle.runMaintenance(atMilliseconds: 1_000)
    }
    #expect(await eventually { await gate.waiterCount == 1 })

    await lifecycle.stop()
    await gate.releaseAll()
    await maintenanceTask.value

    #expect(await armer.calls.isEmpty)
    #expect(try await lifecycle.start())
    #expect(await eventually(attempts: 500) { await armer.calls.count == 1 })
    #expect(await eventually { await lifecycle.state.isArmed })
    await lifecycle.stop()
}

@Test("A stale arming completion cannot poison a restarted lifecycle")
func staleArmingCompletionCannotPoisonRestart() async throws {
    let gate = ButtonAsyncGate()
    let armer = ButtonGatedArmer(firstCallGate: gate)
    let lifecycle = makeLifecycle(
        udpFactory: ButtonFakeUDPFactory(),
        reachability: ButtonFakeReachability([true, true]),
        armer: armer
    )

    await lifecycle.runMaintenance(atMilliseconds: 1_000)
    #expect(await eventually { await gate.waiterCount == 1 })
    #expect(await lifecycle.state.isArming)

    let stopTask = Task { await lifecycle.stop() }
    #expect(await eventually { !(await lifecycle.state.isArming) })
    await gate.releaseAll()
    await stopTask.value

    var state = await lifecycle.state
    #expect(!state.isArmed)
    #expect(!state.isArming)

    #expect(try await lifecycle.start())
    await armer.waitForCallCount(2)
    #expect(await eventually { await lifecycle.state.isArmed })
    state = await lifecycle.state
    #expect(state.isRunning)
    #expect(!state.isArming)
    await lifecycle.stop()
}

@Test("Listener retries transient failures with bounded backoff and a fresh transport")
func listenerRetriesTransientFailures() async throws {
    let failedTransports = (0..<8).map {
        ButtonFakeUDPTransport(boundPort: UInt16(50_000 + $0), receiveBehavior: .fail)
    }
    let replacement = ButtonFakeUDPTransport(boundPort: 55_265)
    let factory = ButtonFakeUDPFactory(transports: failedTransports + [replacement])
    let sleeper = ButtonFakeSleeper()
    let lifecycle = makeLifecycle(udpFactory: factory, sleeper: sleeper)

    #expect(try await lifecycle.start())
    await factory.waitForMakeCalls(9)
    await replacement.waitUntilBound()
    #expect(await lifecycle.state.boundPort == 55_265)
    #expect(await sleeper.delays == [100, 200, 400, 800, 1_600, 3_000, 3_000, 3_000])
    for transport in failedTransports {
        #expect(await transport.isClosed)
    }

    await lifecycle.stop()
    #expect(await replacement.isClosed)
}

@Test("Stopping during listener backoff cancels retry supervision")
func stopCancelsListenerBackoff() async throws {
    let failedTransport = ButtonFakeUDPTransport(boundPort: 50_001, receiveBehavior: .fail)
    let unusedReplacement = ButtonFakeUDPTransport(boundPort: 50_002)
    let factory = ButtonFakeUDPFactory(transports: [failedTransport, unusedReplacement])
    let sleeper = ButtonFakeSleeper(behavior: .waitForCancellation)
    let lifecycle = makeLifecycle(udpFactory: factory, sleeper: sleeper)

    #expect(try await lifecycle.start())
    await sleeper.waitForDelayCount(1)
    #expect(await sleeper.delays == [100])

    await lifecycle.stop()

    #expect(await sleeper.wasCancelled)
    #expect(await factory.makeCalls == 1)
    #expect(!(await lifecycle.state.isRunning))
}

private func makeLifecycle(
    configuration: ScanSnapButtonConfiguration = ScanSnapButtonConfiguration(),
    udpFactory: any ScanSnapUDPTransportFactory = ButtonFakeUDPFactory(),
    scannerProvider: any ScanSnapButtonScannerConfigurationProviding = ButtonFakeScannerProvider(),
    modeProvider: any ScanSnapButtonModeProviding = ButtonFakeModeProvider(),
    dispatcher: any ScanSnapButtonScanDispatching = ButtonFakeScanDispatcher(),
    reachability: any ScanSnapButtonReachabilityChecking = ButtonFakeReachability(),
    armer: any ScanSnapButtonArming = ButtonFakeArmer(),
    clock: any ScanSnapButtonClock = ButtonFakeClock(),
    sleeper: any ScanSnapSleeper = ButtonFakeSleeper()
) -> ScanSnapButtonLifecycleActor {
    ScanSnapButtonLifecycleActor(
        configuration: configuration,
        udpTransportFactory: udpFactory,
        scannerProvider: scannerProvider,
        modeProvider: modeProvider,
        scanDispatcher: dispatcher,
        reachability: reachability,
        armer: armer,
        clock: clock,
        sleeper: sleeper
    )
}
