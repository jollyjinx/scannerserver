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

private func makeLifecycle(
    configuration: ScanSnapButtonConfiguration = ScanSnapButtonConfiguration(),
    udpFactory: any ScanSnapUDPTransportFactory = ButtonFakeUDPFactory(),
    scannerProvider: any ScanSnapButtonScannerConfigurationProviding = ButtonFakeScannerProvider(),
    modeProvider: any ScanSnapButtonModeProviding = ButtonFakeModeProvider(),
    dispatcher: any ScanSnapButtonScanDispatching = ButtonFakeScanDispatcher(),
    reachability: any ScanSnapButtonReachabilityChecking = ButtonFakeReachability(),
    armer: any ScanSnapButtonArming = ButtonFakeArmer(),
    clock: any ScanSnapButtonClock = ButtonFakeClock()
) -> ScanSnapButtonLifecycleActor {
    ScanSnapButtonLifecycleActor(
        configuration: configuration,
        udpTransportFactory: udpFactory,
        scannerProvider: scannerProvider,
        modeProvider: modeProvider,
        scanDispatcher: dispatcher,
        reachability: reachability,
        armer: armer,
        clock: clock
    )
}
