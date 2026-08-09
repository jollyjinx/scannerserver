import ScannerServerCore

actor FakeUDPTransport: ScanSnapUDPTransport {
    enum ReceiveBehavior: Sendable {
        case values([ScanSnapDatagram?])
        case waitForCancellation
    }

    private(set) var bindCalls: [(ScanSnapSocketAddress, Bool)] = []
    private(set) var sends: [ScanSnapDatagram] = []
    private(set) var receiveTimeouts: [UInt64] = []
    private(set) var isClosed = false
    private let boundPort: UInt16
    private var receiveBehavior: ReceiveBehavior

    init(boundPort: UInt16, receiveBehavior: ReceiveBehavior) {
        self.boundPort = boundPort
        self.receiveBehavior = receiveBehavior
    }

    func bind(to localAddress: ScanSnapSocketAddress, allowsBroadcast: Bool) -> UInt16 {
        bindCalls.append((localAddress, allowsBroadcast))
        return boundPort
    }

    func send(_ bytes: [UInt8], to remoteAddress: ScanSnapSocketAddress) {
        sends.append(ScanSnapDatagram(bytes: bytes, remoteAddress: remoteAddress))
    }

    func receive(maximumBytes: Int, timeoutMilliseconds: UInt64) async throws -> ScanSnapDatagram? {
        receiveTimeouts.append(timeoutMilliseconds)
        switch receiveBehavior {
        case var .values(values):
            guard !values.isEmpty else { return nil }
            let value = values.removeFirst()
            receiveBehavior = .values(values)
            return value
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(60))
            return nil
        }
    }

    func close() {
        isClosed = true
    }
}

actor FakeUDPTransportFactory: ScanSnapUDPTransportFactory {
    private var transports: [FakeUDPTransport]

    init(_ transports: [FakeUDPTransport]) {
        self.transports = transports
    }

    func makeTransport() throws -> any ScanSnapUDPTransport {
        guard !transports.isEmpty else {
            throw FakeTransportError.missingUDPTransport
        }
        return transports.removeFirst()
    }
}

actor FakeTCPConnection: ScanSnapTCPConnection {
    private var readChunks: [[UInt8]]
    private var writeLimits: [Int]
    private(set) var writeArguments: [[UInt8]] = []
    private(set) var writtenBytes: [UInt8] = []
    private(set) var didShutdownWriting = false
    private(set) var isClosed = false

    var remainingReadByteCount: Int {
        readChunks.reduce(0) { $0 + $1.count }
    }

    init(readChunks: [[UInt8]], writeLimits: [Int] = []) {
        self.readChunks = readChunks
        self.writeLimits = writeLimits
    }

    func read(maximumBytes: Int, timeoutMilliseconds: UInt64) throws -> [UInt8] {
        guard !readChunks.isEmpty else { return [] }
        let chunk = readChunks.removeFirst()
        guard chunk.count > maximumBytes else { return chunk }
        readChunks.insert(Array(chunk[maximumBytes...]), at: 0)
        return Array(chunk[..<maximumBytes])
    }

    func write(_ bytes: [UInt8], timeoutMilliseconds: UInt64) -> Int {
        writeArguments.append(bytes)
        let limit = writeLimits.isEmpty ? bytes.count : writeLimits.removeFirst()
        let count = min(limit, bytes.count)
        writtenBytes.append(contentsOf: bytes.prefix(count))
        return count
    }

    func shutdownWriting() {
        didShutdownWriting = true
    }

    func close() {
        isClosed = true
    }
}

actor FakeTCPConnectionFactory: ScanSnapTCPConnectionFactory {
    struct ConnectCall: Sendable, Hashable {
        let remoteAddress: ScanSnapSocketAddress
        let localAddress: ScanSnapSocketAddress?
        let timeoutMilliseconds: UInt64
    }

    private var connections: [FakeTCPConnection]
    private(set) var connectCalls: [ConnectCall] = []

    init(_ connections: [FakeTCPConnection]) {
        self.connections = connections
    }

    func connect(
        to remoteAddress: ScanSnapSocketAddress,
        binding localAddress: ScanSnapSocketAddress?,
        timeoutMilliseconds: UInt64
    ) throws -> any ScanSnapTCPConnection {
        connectCalls.append(ConnectCall(
            remoteAddress: remoteAddress,
            localAddress: localAddress,
            timeoutMilliseconds: timeoutMilliseconds
        ))
        guard !connections.isEmpty else {
            throw FakeTransportError.missingTCPConnection
        }
        return connections.removeFirst()
    }
}

actor RecordingSleeper: ScanSnapSleeper {
    private(set) var delays: [UInt64] = []

    func sleep(milliseconds: UInt64) {
        delays.append(milliseconds)
    }
}

enum FakeTransportError: Error {
    case missingUDPTransport
    case missingTCPConnection
}

func networkDevicePacket(
    ipAddress: [UInt8] = [0, 0, 0, 0],
    macAddress: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF],
    serialNumber: String = "AWRHC08122",
    name: String = "iX500",
    metadata: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4]
) -> [UInt8] {
    var packet = [UInt8](repeating: 0, count: VENSDeviceInfoParser.packetLength)
    packet.replaceSubrange(0..<4, with: Array("VENS".utf8))
    packet.replaceSubrange(16..<20, with: ipAddress)
    packet.replaceSubrange(22..<24, with: ScanSnapByteCodec.bigEndianBytes(ScanSnapPacketBuilder.dataPort))
    packet.replaceSubrange(26..<28, with: ScanSnapByteCodec.bigEndianBytes(ScanSnapPacketBuilder.controlPort))
    packet.replaceSubrange(28..<34, with: macAddress)
    packet.replaceSubrange(40..<(40 + serialNumber.utf8.count), with: serialNumber.utf8)
    packet.replaceSubrange(104..<(104 + name.utf8.count), with: name.utf8)
    packet.replaceSubrange(124..<132, with: metadata)
    return packet
}

func pairingResponse(_ status: Int32) -> [UInt8] {
    var response = [UInt8](repeating: 0, count: 12)
    response.replaceSubrange(8..<12, with: ScanSnapByteCodec.bigEndianBytes(status))
    return response
}
