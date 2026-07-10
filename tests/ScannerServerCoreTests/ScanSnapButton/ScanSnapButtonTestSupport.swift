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

actor ButtonFakeUDPTransport: ScanSnapUDPTransport {
    let boundPort: UInt16
    private(set) var bindCalls: [ScanSnapSocketAddress] = []
    private(set) var isClosed = false

    init(boundPort: UInt16) {
        self.boundPort = boundPort
    }

    func bind(to localAddress: ScanSnapSocketAddress, allowsBroadcast: Bool) -> UInt16 {
        bindCalls.append(localAddress)
        return boundPort
    }

    func send(_ bytes: [UInt8], to remoteAddress: ScanSnapSocketAddress) {}

    func receive(maximumBytes: Int, timeoutMilliseconds: UInt64) async throws -> ScanSnapDatagram? {
        try await Task.sleep(for: .seconds(60))
        return nil
    }

    func close() {
        isClosed = true
    }
}

actor ButtonFakeUDPFactory: ScanSnapUDPTransportFactory {
    let transport: ButtonFakeUDPTransport

    init(transport: ButtonFakeUDPTransport = ButtonFakeUDPTransport(boundPort: 55_265)) {
        self.transport = transport
    }

    func makeTransport() -> any ScanSnapUDPTransport { transport }
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

actor ButtonFakeTCPConnection: ScanSnapTCPConnection {
    private var readChunks: [[UInt8]]
    private(set) var writes: [[UInt8]] = []
    private(set) var isClosed = false

    init(readChunks: [[UInt8]]) {
        self.readChunks = readChunks
    }

    func read(maximumBytes: Int, timeoutMilliseconds: UInt64) -> [UInt8] {
        guard !readChunks.isEmpty else { return [] }
        let chunk = readChunks.removeFirst()
        guard chunk.count > maximumBytes else { return chunk }
        readChunks.insert(Array(chunk.dropFirst(maximumBytes)), at: 0)
        return Array(chunk.prefix(maximumBytes))
    }

    func write(_ bytes: [UInt8], timeoutMilliseconds: UInt64) -> Int {
        writes.append(bytes)
        return bytes.count
    }

    func close() {
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
    ) throws -> any ScanSnapTCPConnection {
        ports.append(remoteAddress.port)
        if remoteAddress.port == ScanSnapPacketBuilder.dataPort {
            return dataConnection
        }
        guard !controlConnections.isEmpty else { throw ButtonFakeError.expected }
        return controlConnections.removeFirst()
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
