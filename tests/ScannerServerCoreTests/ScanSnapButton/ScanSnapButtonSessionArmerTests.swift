import ScannerServerCore
import Testing

private let fixedButtonTimestamp = ScanSnapTimestamp(
    year: 2026,
    month: 7,
    day: 10,
    hour: 12,
    minute: 30,
    second: 0
)

@Test("Button armer uses busy retry policy and packet-builder initialization sequence")
func buttonArmingInitializationSequence() async throws {
    let pairing = ButtonFakePairing()
    let response = vensResponse()
    let timeline = ButtonEventTimeline()
    let dataConnection = ButtonFakeTCPConnection(
        label: "data",
        readChunks: [[UInt8](repeating: 0, count: 16)] + Array(repeating: response, count: 7),
        timeline: timeline
    )
    let control13 = ButtonFakeTCPConnection(
        label: "control13",
        readChunks: [[UInt8](repeating: 0, count: 16), response],
        timeline: timeline
    )
    let control30 = ButtonFakeTCPConnection(
        label: "control30",
        readChunks: [[UInt8](repeating: 0, count: 16), response],
        timeline: timeline
    )
    let tcpFactory = ButtonFakeTCPFactory(
        dataConnection: dataConnection,
        controlConnections: [control13, control30]
    )
    let armer = ScanSnapButtonSessionArmer(
        pairing: pairing,
        connectionFactory: tcpFactory,
        timestampProvider: { fixedButtonTimestamp }
    )
    let scanner = buttonScannerConfiguration()
    let configuration = ScanSnapButtonConfiguration(
        armTimeoutMilliseconds: 10_000,
        registrationSourcePort: 50_001,
        registrationPort: 50_002
    )

    try await armer.arm(scanner: scanner, configuration: configuration)

    let pairingConfiguration = try #require(await pairing.configurations.first)
    #expect(pairingConfiguration.retryPolicy == .buttonArming)
    #expect(pairingConfiguration.registrationSourcePort == 50_001)
    #expect(pairingConfiguration.registrationPort == 50_002)
    #expect(await pairing.timestamps == [fixedButtonTimestamp])
    #expect(await dataConnection.writes == (
        try ScanSnapPacketBuilder.buttonInitializationFrames(clientMACAddress: scanner.clientMACAddress)
    ))

    let controlWrites = await control13.writes + control30.writes
    let commands = try controlWrites.map { try ScanSnapByteCodec.readUInt32(from: $0, at: 8) }
    #expect(Set(commands) == Set(ScanSnapPacketBuilder.buttonHandshakeCommands))
    #expect(await tcpFactory.ports.filter { $0 == scanner.dataPort }.count == 1)
    #expect(await tcpFactory.ports.filter { $0 == scanner.controlPort }.count == 2)
    #expect(await dataConnection.isClosed)
    #expect(await control13.isClosed)
    #expect(await control30.isClosed)
    #expect(await timeline.events == [
        "data.connect",
        "data.read.0",
        "control13.connect",
        "control13.read.0",
        "control13.write.0",
        "control13.read.1",
        "control13.close",
        "data.write.0",
        "data.read.1",
        "control30.connect",
        "control30.read.0",
        "control30.write.0",
        "control30.read.1",
        "control30.close",
        "data.write.1",
        "data.read.2",
        "data.write.2",
        "data.read.3",
        "data.write.3",
        "data.read.4",
        "data.write.4",
        "data.read.5",
        "data.write.5",
        "data.read.6",
        "data.write.6",
        "data.read.7",
        "data.close",
    ])
}

@Test("Busy pairing exhaustion prevents data-port initialization")
func busyPairingDoesNotInitializeDataPort() async {
    let pairing = ButtonFakePairing(status: .sessionBusy)
    let dataConnection = ButtonFakeTCPConnection(readChunks: [])
    let tcpFactory = ButtonFakeTCPFactory(dataConnection: dataConnection, controlConnections: [])
    let armer = ScanSnapButtonSessionArmer(
        pairing: pairing,
        connectionFactory: tcpFactory,
        timestampProvider: { fixedButtonTimestamp }
    )

    do {
        try await armer.arm(
            scanner: buttonScannerConfiguration(),
            configuration: ScanSnapButtonConfiguration(armTimeoutMilliseconds: 10_000)
        )
        Issue.record("Expected busy pairing to reject button arming")
    } catch let error as ScanSnapButtonArmingError {
        #expect(error == .pairingRejected(.sessionBusy))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(await pairing.configurations.first?.retryPolicy == .buttonArming)
    #expect(await tcpFactory.ports.isEmpty)
}
