import ScannerServerCore
import Testing

private let pairingTimestamp = ScanSnapTimestamp(
    year: 2026,
    month: 7,
    day: 10,
    hour: 12,
    minute: 30,
    second: 0
)

@Test("Pairing releases a busy session, retries, then releases an accepted probe")
func pairingRetriesBusyAndReleasesAcceptedSession() async throws {
    let remote = ScanSnapSocketAddress(host: "192.168.1.44", port: 52_217)
    let registrationOne = FakeUDPTransport(
        boundPort: 55_264,
        receiveBehavior: .values([ScanSnapDatagram(bytes: networkDevicePacket(), remoteAddress: remote)])
    )
    let registrationTwo = FakeUDPTransport(
        boundPort: 55_264,
        receiveBehavior: .values([ScanSnapDatagram(bytes: networkDevicePacket(), remoteAddress: remote)])
    )
    let busyControl = FakeTCPConnection(readChunks: [[UInt8](repeating: 0, count: 16), pairingResponse(-4)])
    let busyRelease = FakeTCPConnection(readChunks: [[UInt8](repeating: 0, count: 16), [UInt8](repeating: 0, count: 16)])
    let acceptedControl = FakeTCPConnection(readChunks: [[UInt8](repeating: 0, count: 16), pairingResponse(0)])
    let acceptedRelease = FakeTCPConnection(readChunks: [[UInt8](repeating: 0, count: 16), [UInt8](repeating: 0, count: 16)])
    let tcpFactory = FakeTCPConnectionFactory([
        busyControl,
        busyRelease,
        acceptedControl,
        acceptedRelease,
    ])
    let sleeper = RecordingSleeper()
    let actor = ScanSnapPairingActor(
        udpTransportFactory: FakeUDPTransportFactory([registrationOne, registrationTwo]),
        tcpConnectionFactory: tcpFactory,
        sleeper: sleeper
    )

    let result = try await actor.pair(configuration: pairingConfiguration(), timestamp: pairingTimestamp)

    #expect(result.status == .accepted)
    #expect(result.attemptsMade == 2)
    #expect(result.device?.metadata == [0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4])
    #expect(await sleeper.delays == [1_000])
    let calls = await tcpFactory.connectCalls
    #expect(calls.map(\.remoteAddress.port) == [53_219, 53_218, 53_219, 53_218])
    #expect(calls.allSatisfy { $0.localAddress == ScanSnapSocketAddress(host: "192.168.1.10", port: 0) })
    #expect(await busyRelease.writtenBytes == (try ScanSnapPacketBuilder.releaseFrame(clientMACAddress: [2, 0x11, 0x22, 0x33, 0x44, 0x55])))
    #expect(await acceptedRelease.writtenBytes == (try ScanSnapPacketBuilder.releaseFrame(clientMACAddress: [2, 0x11, 0x22, 0x33, 0x44, 0x55])))
    #expect(await registrationOne.sends.count == 12)
    #expect(await registrationOne.sends.map { String(decoding: $0.bytes.prefix(4), as: UTF8.self) } == [
        "VENS", "ssNR", "V2ss",
        "VENS", "ssNR", "V2ss",
        "VENS", "ssNR", "V2ss",
        "VENS", "ssNR", "V2ss",
    ])
}

@Test("Button arming policy retains an accepted session without release")
func pairingCanRetainAcceptedSession() async throws {
    let registration = FakeUDPTransport(boundPort: 55_264, receiveBehavior: .values([nil]))
    let control = FakeTCPConnection(readChunks: [[UInt8](repeating: 0, count: 16), pairingResponse(0)])
    let tcpFactory = FakeTCPConnectionFactory([control])
    let actor = ScanSnapPairingActor(
        udpTransportFactory: FakeUDPTransportFactory([registration]),
        tcpConnectionFactory: tcpFactory,
        sleeper: RecordingSleeper()
    )
    let configuration = pairingConfiguration(retryPolicy: .buttonArming)

    let result = try await actor.pair(configuration: configuration, timestamp: pairingTimestamp)

    #expect(result.accepted)
    #expect(await tcpFactory.connectCalls.map(\.remoteAddress.port) == [53_219])
}

@Test("Session release consumes the complete VENS response and waits for the iX500 close")
func releaseConsumesCompleteVENSResponseAndWaitsForClose() async throws {
    let hello = [UInt8](repeating: 0, count: 16)
    let hardwareResponse = [0x00, 0x00, 0x00, 0x28] + Array("VENS".utf8)
        + [UInt8](repeating: 0, count: 32)
    let release = FakeTCPConnection(readChunks: [hello, hardwareResponse])
    let actor = ScanSnapPairingActor(
        udpTransportFactory: FakeUDPTransportFactory([]),
        tcpConnectionFactory: FakeTCPConnectionFactory([release]),
        sleeper: RecordingSleeper()
    )

    try await actor.releaseSession(configuration: pairingConfiguration())

    #expect(await release.remainingReadByteCount == 0)
    #expect(await release.didShutdownWriting)
    #expect(await release.isClosed)
}

private func pairingConfiguration(
    retryPolicy: ScanSnapSessionRetryPolicy = .pairingTest
) -> ScanSnapPairingConfiguration {
    ScanSnapPairingConfiguration(
        scannerIPAddress: "192.168.1.44",
        clientIPAddress: "192.168.1.10",
        clientMACAddress: [2, 0x11, 0x22, 0x33, 0x44, 0x55],
        identity: ScanSnapIdentity("179130178176"),
        registrationSourcePort: 55_264,
        registrationPort: 52_217,
        controlPort: 53_219,
        dataPort: 53_218,
        registrationRounds: 4,
        registrationTimeoutMilliseconds: 300,
        connectionTimeoutMilliseconds: 500,
        retryPolicy: retryPolicy,
        allowsSourcePortFallback: false
    )
}
