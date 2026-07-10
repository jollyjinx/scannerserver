import ScannerServerCore
import Testing

@Test("Discovery honors source and destination ports, packet order, and receive timeout")
func discoveryPreservesSendOrderAndPorts() async throws {
    let transport = FakeUDPTransport(boundPort: 55_264, receiveBehavior: .values([nil]))
    let actor = ScanSnapDiscoveryActor(transportFactory: FakeUDPTransportFactory([transport]))
    let configuration = ScanSnapDiscoveryConfiguration(
        routes: [ScanSnapDiscoveryRoute(
            clientIPAddress: "192.168.1.10",
            targetIPAddresses: ["192.168.1.255"]
        )],
        clientMACAddress: [2, 0x11, 0x22, 0x33, 0x44, 0x55],
        sourcePort: 55_264,
        registrationPort: 52_217,
        rounds: 1,
        timeoutMilliseconds: 777,
        allowsSourcePortFallback: false,
        token: [1, 2, 3, 4, 5, 6, 0, 0]
    )

    let devices = try await actor.discover(configuration: configuration)

    #expect(devices.isEmpty)
    let binds = await transport.bindCalls
    #expect(binds.count == 1)
    #expect(binds.first?.0 == .anyIPv4(port: 55_264))
    #expect(binds.first?.1 == true)
    let sends = await transport.sends
    #expect(sends.map { String(decoding: $0.bytes.prefix(4), as: UTF8.self) } == [
        "VENS", "ssNR", "VENS", "ssNR", "V2ss",
    ])
    #expect(sends.allSatisfy { $0.remoteAddress == ScanSnapSocketAddress(host: "192.168.1.255", port: 52_217) })
    #expect(await transport.receiveTimeouts == [777])
    #expect(await transport.isClosed)
}

@Test("Discovery deduplicates repeated VENS responses by device identity")
func discoveryDeduplicatesDevices() async throws {
    let remote = ScanSnapSocketAddress(host: "192.168.1.44", port: 52_217)
    let transport = FakeUDPTransport(
        boundPort: 55_264,
        receiveBehavior: .values([
            ScanSnapDatagram(bytes: networkDevicePacket(name: "First Name"), remoteAddress: remote),
            ScanSnapDatagram(bytes: networkDevicePacket(name: "Updated Name"), remoteAddress: remote),
            nil,
        ])
    )
    let actor = ScanSnapDiscoveryActor(transportFactory: FakeUDPTransportFactory([transport]))

    let devices = try await actor.discover(configuration: ScanSnapDiscoveryConfiguration(
        routes: [ScanSnapDiscoveryRoute(clientIPAddress: "192.168.1.10", targetIPAddresses: [remote.host])],
        rounds: 1,
        timeoutMilliseconds: 10,
        token: [1, 2, 3, 4, 5, 6, 0, 0]
    ))

    #expect(devices.count == 1)
    #expect(devices.first?.name == "Updated Name")
    #expect(devices.first?.id == "aa:bb:cc:dd:ee:ff@192.168.1.44")
}

@Test("Discovery separates retry rounds with bounded receive windows")
func discoverySeparatesRetryRoundsWithReceiveWindows() async throws {
    let transport = SequencedDiscoveryUDPTransport(receiveValues: [nil, nil])
    let actor = ScanSnapDiscoveryActor(
        transportFactory: SequencedDiscoveryUDPTransportFactory(transport: transport)
    )

    let devices = try await actor.discover(configuration: ScanSnapDiscoveryConfiguration(
        routes: [ScanSnapDiscoveryRoute(
            clientIPAddress: "192.168.1.10",
            targetIPAddresses: ["192.168.1.255"]
        )],
        rounds: 2,
        timeoutMilliseconds: 800,
        allowsSourcePortFallback: false,
        token: [1, 2, 3, 4, 5, 6, 0, 0]
    ))

    #expect(devices.isEmpty)
    let events = await transport.events
    #expect(events.map(\.kind) == [
        .send("VENS", "192.168.1.255"),
        .send("ssNR", "192.168.1.255"),
        .receive,
        .send("VENS", "192.168.1.255"),
        .send("ssNR", "192.168.1.255"),
        .receive,
    ])
    let receiveTimeouts = events.compactMap(\.receiveTimeoutMilliseconds)
    #expect(receiveTimeouts.count == 2)
    #expect(receiveTimeouts[0] > 0)
    #expect(receiveTimeouts[0] <= 400)
    #expect(receiveTimeouts[1] > 0)
    #expect(receiveTimeouts[1] <= 800)
}

@Test("Discovery continues with remaining targets and interfaces after a destination send failure")
func discoveryContinuesAfterDestinationSendFailure() async throws {
    let transport = SequencedDiscoveryUDPTransport(
        receiveValues: [nil],
        failingDestinations: ["192.168.1.1"]
    )
    let actor = ScanSnapDiscoveryActor(
        transportFactory: SequencedDiscoveryUDPTransportFactory(transport: transport)
    )

    let devices = try await actor.discover(configuration: ScanSnapDiscoveryConfiguration(
        routes: [
            ScanSnapDiscoveryRoute(
                clientIPAddress: "192.168.1.10",
                targetIPAddresses: ["192.168.1.1", "192.168.1.255"]
            ),
            ScanSnapDiscoveryRoute(
                clientIPAddress: "10.112.10.6",
                targetIPAddresses: ["10.112.10.255"]
            ),
        ],
        rounds: 1,
        timeoutMilliseconds: 100,
        allowsSourcePortFallback: false,
        token: [1, 2, 3, 4, 5, 6, 0, 0]
    ))

    #expect(devices.isEmpty)
    #expect(await transport.events.map(\.kind) == [
        .send("VENS", "192.168.1.1"),
        .send("VENS", "192.168.1.255"),
        .send("ssNR", "192.168.1.255"),
        .send("VENS", "10.112.10.255"),
        .send("ssNR", "10.112.10.255"),
        .receive,
    ])
    #expect(await transport.isClosed)
}

@Test("Discovery cancellation closes the transport and propagates cancellation")
func discoveryPropagatesCancellation() async {
    let transport = FakeUDPTransport(boundPort: 55_264, receiveBehavior: .waitForCancellation)
    let actor = ScanSnapDiscoveryActor(transportFactory: FakeUDPTransportFactory([transport]))
    let task = Task {
        try await actor.discover(configuration: ScanSnapDiscoveryConfiguration(
            routes: [ScanSnapDiscoveryRoute(clientIPAddress: "192.168.1.10", targetIPAddresses: ["255.255.255.255"])],
            rounds: 1,
            token: [1, 2, 3, 4, 5, 6, 0, 0]
        ))
    }

    await Task.yield()
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Expected discovery cancellation")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(await transport.isClosed)
}

private enum SequencedDiscoveryEventKind: Sendable, Equatable {
    case send(String, String)
    case receive
}

private struct SequencedDiscoveryEvent: Sendable, Equatable {
    let kind: SequencedDiscoveryEventKind
    let receiveTimeoutMilliseconds: UInt64?
}

private actor SequencedDiscoveryUDPTransport: ScanSnapUDPTransport {
    private(set) var events: [SequencedDiscoveryEvent] = []
    private(set) var isClosed = false
    private var receiveValues: [ScanSnapDatagram?]
    private let failingDestinations: Set<String>

    init(
        receiveValues: [ScanSnapDatagram?],
        failingDestinations: Set<String> = []
    ) {
        self.receiveValues = receiveValues
        self.failingDestinations = failingDestinations
    }

    func bind(to localAddress: ScanSnapSocketAddress, allowsBroadcast: Bool) -> UInt16 {
        localAddress.port
    }

    func send(_ bytes: [UInt8], to remoteAddress: ScanSnapSocketAddress) throws {
        events.append(SequencedDiscoveryEvent(
            kind: .send(String(decoding: bytes.prefix(4), as: UTF8.self), remoteAddress.host),
            receiveTimeoutMilliseconds: nil
        ))
        if failingDestinations.contains(remoteAddress.host) {
            throw SequencedDiscoveryTransportError.sendFailed
        }
    }

    func receive(maximumBytes: Int, timeoutMilliseconds: UInt64) -> ScanSnapDatagram? {
        events.append(SequencedDiscoveryEvent(
            kind: .receive,
            receiveTimeoutMilliseconds: timeoutMilliseconds
        ))
        guard !receiveValues.isEmpty else { return nil }
        return receiveValues.removeFirst()
    }

    func close() {
        isClosed = true
    }
}

private struct SequencedDiscoveryUDPTransportFactory: ScanSnapUDPTransportFactory {
    let transport: SequencedDiscoveryUDPTransport

    func makeTransport() -> any ScanSnapUDPTransport {
        transport
    }
}

private enum SequencedDiscoveryTransportError: Error {
    case sendFailed
}
