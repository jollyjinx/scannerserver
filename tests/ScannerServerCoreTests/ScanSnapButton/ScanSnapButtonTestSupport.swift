import ScannerServerCore

actor ButtonFakeScannerProvider: ScanSnapButtonScannerConfigurationProviding {
    var configuration: ScanSnapButtonScannerConfiguration?

    init(_ configuration: ScanSnapButtonScannerConfiguration? = buttonScannerConfiguration()) {
        self.configuration = configuration
    }

    func currentButtonScannerConfiguration() -> ScanSnapButtonScannerConfiguration? {
        configuration
    }

    func set(_ configuration: ScanSnapButtonScannerConfiguration?) {
        self.configuration = configuration
    }
}

actor ButtonAsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { continuations.count }

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseAll() {
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

actor ButtonGatedScannerProvider: ScanSnapButtonScannerConfigurationProviding {
    private let gate: ButtonAsyncGate
    private let configuration: ScanSnapButtonScannerConfiguration?
    private var shouldWait = true

    init(
        gate: ButtonAsyncGate,
        configuration: ScanSnapButtonScannerConfiguration? = buttonScannerConfiguration()
    ) {
        self.gate = gate
        self.configuration = configuration
    }

    func currentButtonScannerConfiguration() async -> ScanSnapButtonScannerConfiguration? {
        if shouldWait {
            shouldWait = false
            await gate.wait()
        }
        return configuration
    }
}

actor ButtonFakeModeProvider: ScanSnapButtonModeProviding {
    var mode: ScanMode

    init(mode: ScanMode = buttonMode()) {
        self.mode = mode
    }

    func currentButtonDefaultMode() -> ScanMode { mode }
}

actor ButtonFakeScanDispatcher: ScanSnapButtonScanDispatching {
    var isBusy = false
    var acceptsStart = true
    private(set) var startedModes: [ScanMode] = []

    func isScanRunning() -> Bool { isBusy }

    func startButtonScan(mode: ScanMode) -> Bool {
        guard acceptsStart, !isBusy else { return false }
        startedModes.append(mode)
        return true
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
    }
}

actor ButtonFakeReachability: ScanSnapButtonReachabilityChecking {
    struct Call: Sendable, Hashable {
        let scanner: ScanSnapButtonScannerConfiguration
        let port: UInt16
        let timeoutMilliseconds: UInt64
    }

    private var outcomes: [Bool]
    private(set) var calls: [Call] = []

    init(_ outcomes: [Bool] = [true]) {
        self.outcomes = outcomes
    }

    func isReachable(
        scanner: ScanSnapButtonScannerConfiguration,
        port: UInt16,
        timeoutMilliseconds: UInt64
    ) -> Bool {
        calls.append(Call(scanner: scanner, port: port, timeoutMilliseconds: timeoutMilliseconds))
        return outcomes.isEmpty ? false : outcomes.removeFirst()
    }
}

actor ButtonFakeArmer: ScanSnapButtonArming {
    enum Behavior: Sendable {
        case succeed
        case fail
        case waitForCancellation
    }

    struct Call: Sendable, Hashable {
        let scanner: ScanSnapButtonScannerConfiguration
        let configuration: ScanSnapButtonConfiguration
    }

    let behavior: Behavior
    private(set) var calls: [Call] = []
    private(set) var recoveryCalls: [Call] = []
    private(set) var wasCancelled = false

    init(behavior: Behavior = .succeed) {
        self.behavior = behavior
    }

    func arm(
        scanner: ScanSnapButtonScannerConfiguration,
        configuration: ScanSnapButtonConfiguration
    ) async throws {
        calls.append(Call(scanner: scanner, configuration: configuration))
        switch behavior {
        case .succeed:
            return
        case .fail:
            throw ButtonFakeError.expected
        case .waitForCancellation:
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                wasCancelled = true
                throw CancellationError()
            }
        }
    }

    func recoverAndArm(
        scanner: ScanSnapButtonScannerConfiguration,
        configuration: ScanSnapButtonConfiguration
    ) async throws {
        recoveryCalls.append(Call(scanner: scanner, configuration: configuration))
        switch behavior {
        case .succeed:
            return
        case .fail:
            throw ButtonFakeError.expected
        case .waitForCancellation:
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                wasCancelled = true
                throw CancellationError()
            }
        }
    }
}

actor ButtonGatedArmer: ScanSnapButtonArming {
    private let firstCallGate: ButtonAsyncGate
    private(set) var calls: [ButtonFakeArmer.Call] = []
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(firstCallGate: ButtonAsyncGate) {
        self.firstCallGate = firstCallGate
    }

    func arm(
        scanner: ScanSnapButtonScannerConfiguration,
        configuration: ScanSnapButtonConfiguration
    ) async throws {
        calls.append(ButtonFakeArmer.Call(scanner: scanner, configuration: configuration))
        resumeSatisfiedCallWaiters()
        if calls.count == 1 {
            await firstCallGate.wait()
        }
    }

    func waitForCallCount(_ count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedCallWaiters() {
        let satisfied = callWaiters.filter { calls.count >= $0.count }
        callWaiters.removeAll { calls.count >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}

actor ButtonFakeClock: ScanSnapButtonClock {
    var now: UInt64

    init(_ now: UInt64 = 0) {
        self.now = now
    }

    func nowMilliseconds() -> UInt64 { now }

    func set(_ now: UInt64) {
        self.now = now
    }
}

actor ButtonFakeSleeper: ScanSnapSleeper {
    enum Behavior: Sendable {
        case immediate
        case waitForCancellation
    }

    private let behavior: Behavior
    private(set) var delays: [UInt64] = []
    private(set) var wasCancelled = false
    private var delayWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(behavior: Behavior = .immediate) {
        self.behavior = behavior
    }

    func sleep(milliseconds: UInt64) async throws {
        delays.append(milliseconds)
        resumeSatisfiedDelayWaiters()
        switch behavior {
        case .immediate:
            try Task.checkCancellation()
            await Task.yield()
            try Task.checkCancellation()
        case .waitForCancellation:
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                wasCancelled = true
                throw CancellationError()
            }
        }
    }

    func waitForDelayCount(_ count: Int) async {
        guard delays.count < count else { return }
        await withCheckedContinuation { continuation in
            delayWaiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedDelayWaiters() {
        let satisfied = delayWaiters.filter { delays.count >= $0.count }
        delayWaiters.removeAll { delays.count >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}

actor ButtonFakeUDPTransport: ScanSnapUDPTransport {
    enum ReceiveBehavior: Sendable {
        case waitForCancellation
        case fail
    }

    let boundPort: UInt16
    let receiveBehavior: ReceiveBehavior
    private(set) var bindCalls: [ScanSnapSocketAddress] = []
    private(set) var isClosed = false
    private var bindWaiters: [CheckedContinuation<Void, Never>] = []

    init(boundPort: UInt16, receiveBehavior: ReceiveBehavior = .waitForCancellation) {
        self.boundPort = boundPort
        self.receiveBehavior = receiveBehavior
    }

    func bind(to localAddress: ScanSnapSocketAddress, allowsBroadcast: Bool) -> UInt16 {
        bindCalls.append(localAddress)
        let waiting = bindWaiters
        bindWaiters.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
        return boundPort
    }

    func waitUntilBound() async {
        guard bindCalls.isEmpty else { return }
        await withCheckedContinuation { continuation in
            bindWaiters.append(continuation)
        }
    }

    func send(_ bytes: [UInt8], to remoteAddress: ScanSnapSocketAddress) {}

    func receive(maximumBytes: Int, timeoutMilliseconds: UInt64) async throws -> ScanSnapDatagram? {
        switch receiveBehavior {
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(60))
            return nil
        case .fail:
            throw ButtonFakeError.expected
        }
    }

    func close() {
        isClosed = true
    }
}

actor ButtonFakeUDPFactory: ScanSnapUDPTransportFactory {
    private var transports: [ButtonFakeUDPTransport]
    private(set) var makeCalls = 0
    private var makeWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(transport: ButtonFakeUDPTransport = ButtonFakeUDPTransport(boundPort: 55_265)) {
        transports = [transport]
    }

    init(transports: [ButtonFakeUDPTransport]) {
        self.transports = transports
    }

    func makeTransport() throws -> any ScanSnapUDPTransport {
        makeCalls += 1
        resumeSatisfiedMakeWaiters()
        guard !transports.isEmpty else { throw ButtonFakeError.expected }
        return transports.removeFirst()
    }

    func waitForMakeCalls(_ count: Int) async {
        guard makeCalls < count else { return }
        await withCheckedContinuation { continuation in
            makeWaiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedMakeWaiters() {
        let satisfied = makeWaiters.filter { makeCalls >= $0.count }
        makeWaiters.removeAll { makeCalls >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}

actor ButtonFakePairing: ScanSnapButtonPairing {
    let result: ScanSnapPairingResult
    private(set) var configurations: [ScanSnapPairingConfiguration] = []
    private(set) var timestamps: [ScanSnapTimestamp] = []

    init(status: ScanSnapPairingStatus = .accepted) {
        result = ScanSnapPairingResult(status: status, device: nil, attemptsMade: 1)
    }

    func pair(
        configuration: ScanSnapPairingConfiguration,
        timestamp: ScanSnapTimestamp
    ) -> ScanSnapPairingResult {
        configurations.append(configuration)
        timestamps.append(timestamp)
        return result
    }
}

actor ButtonEventTimeline {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

actor ButtonFakeTCPConnection: ScanSnapTCPConnection {
    nonisolated let label: String

    private var readChunks: [[UInt8]]
    private(set) var writes: [[UInt8]] = []
    private(set) var isClosed = false
    private let timeline: ButtonEventTimeline?
    private var readCount = 0

    init(
        label: String = "connection",
        readChunks: [[UInt8]],
        timeline: ButtonEventTimeline? = nil
    ) {
        self.label = label
        self.readChunks = readChunks
        self.timeline = timeline
    }

    func read(maximumBytes: Int, timeoutMilliseconds: UInt64) async -> [UInt8] {
        await timeline?.record("\(label).read.\(readCount)")
        readCount += 1
        guard !readChunks.isEmpty else { return [] }
        let chunk = readChunks.removeFirst()
        guard chunk.count > maximumBytes else { return chunk }
        readChunks.insert(Array(chunk.dropFirst(maximumBytes)), at: 0)
        return Array(chunk.prefix(maximumBytes))
    }

    func write(_ bytes: [UInt8], timeoutMilliseconds: UInt64) async -> Int {
        await timeline?.record("\(label).write.\(writes.count)")
        writes.append(bytes)
        return bytes.count
    }

    func close() async {
        await timeline?.record("\(label).close")
        isClosed = true
    }
}

actor ButtonFakeTCPFactory: ScanSnapTCPConnectionFactory {
    let dataConnection: ButtonFakeTCPConnection
    private var controlConnections: [ButtonFakeTCPConnection]
    private(set) var ports: [UInt16] = []

    init(dataConnection: ButtonFakeTCPConnection, controlConnections: [ButtonFakeTCPConnection]) {
        self.dataConnection = dataConnection
        self.controlConnections = controlConnections
    }

    func connect(
        to remoteAddress: ScanSnapSocketAddress,
        binding localAddress: ScanSnapSocketAddress?,
        timeoutMilliseconds: UInt64
    ) async throws -> any ScanSnapTCPConnection {
        ports.append(remoteAddress.port)
        if remoteAddress.port == ScanSnapPacketBuilder.dataPort {
            await dataConnection.timelineEventForConnect()
            return dataConnection
        }
        guard !controlConnections.isEmpty else { throw ButtonFakeError.expected }
        let connection = controlConnections.removeFirst()
        await connection.timelineEventForConnect()
        return connection
    }
}

extension ButtonFakeTCPConnection {
    func timelineEventForConnect() async {
        await timeline?.record("\(label).connect")
    }
}

enum ButtonFakeError: Error {
    case expected
}

func buttonScannerConfiguration() -> ScanSnapButtonScannerConfiguration {
    ScanSnapButtonScannerConfiguration(
        scannerIPAddress: "192.168.1.44",
        clientIPAddress: "192.168.1.10",
        clientMACAddress: [2, 0x11, 0x22, 0x33, 0x44, 0x55],
        identity: ScanSnapIdentity("179130178176")
    )
}

func buttonMode(id: String = "button-default") -> ScanMode {
    ScanMode(id: id, name: "Button Default", settings: .standard)
}

func buttonNotice(source: String = "192.168.1.44", bytes: [UInt8]? = nil) -> ScanSnapDatagram {
    var notice = [UInt8](repeating: 0, count: 12)
    notice.replaceSubrange(4..<8, with: Array("VENS".utf8))
    return ScanSnapDatagram(
        bytes: bytes ?? notice,
        remoteAddress: ScanSnapSocketAddress(host: source, port: 52_217)
    )
}

func vensResponse() -> [UInt8] {
    var response = [UInt8](repeating: 0, count: 16)
    response.replaceSubrange(0..<4, with: ScanSnapByteCodec.bigEndianBytes(UInt32(16)))
    response.replaceSubrange(4..<8, with: Array("VENS".utf8))
    return response
}

func eventually(
    attempts: Int = 100,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
