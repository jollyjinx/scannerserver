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
