import ScannerServerCore
import Testing

@Test("Heartbeat retains the button session every configured interval")
func buttonHeartbeatPacketAndPorts() async throws {
    let transport = ButtonFakeUDPTransport(boundPort: 55_264, receiveBehavior: .returnNil)
    let sleeper = ButtonFakeSleeper(behavior: .waitForCancellation)
    let heartbeat = ScanSnapButtonHeartbeatActor(
        udpTransportFactory: ButtonFakeUDPFactory(transport: transport),
        sleeper: sleeper
    )
    let configuration = ScanSnapButtonConfiguration(
        heartbeatIntervalMilliseconds: 500,
        registrationSourcePort: 55_264,
        registrationPort: 52_217
    )

    await heartbeat.start(scanner: buttonScannerConfiguration(), configuration: configuration)
    await transport.waitForSendCount(1)

    #expect(await transport.bindCalls == [
        ScanSnapSocketAddress(host: "192.168.1.10", port: 55_264),
    ])
    let send = try #require(await transport.sendCalls.first)
    let expectedHeartbeat = try ScanSnapPacketBuilder.heartbeat(
        clientIPAddress: "192.168.1.10",
        clientMACAddress: [2, 0x11, 0x22, 0x33, 0x44, 0x55]
    )
    #expect(send.remoteAddress == ScanSnapSocketAddress(host: "192.168.1.44", port: 52_217))
    #expect(send.bytes == expectedHeartbeat)
    #expect(await sleeper.delays == [500])

    await heartbeat.stop()
    #expect(await transport.isClosed)
}

@Test("Startup listener parses iX500 advertisements on UDP 53220")
func startupAdvertisementListener() async throws {
    let packet = startupAdvertisementPacket(
        scannerIPAddress: [192, 168, 1, 44],
        scannerMACAddress: [2, 0x11, 0x22, 0x33, 0x44, 0x55]
    )
    let transport = ButtonFakeUDPTransport(
        boundPort: 53_220,
        receiveBehavior: .datagrams([
            ScanSnapDatagram(
                bytes: packet,
                remoteAddress: ScanSnapSocketAddress(host: "192.168.1.44", port: 53_220)
            ),
        ])
    )
    let events = ButtonEventTimeline()
    let listener = ScanSnapStartupAdvertisementListener(
        udpTransportFactory: ButtonFakeUDPFactory(transport: transport)
    )

    #expect(try await listener.start { advertisement in
        await events.record("\(advertisement.scannerIPAddress)|\(advertisement.scannerMACAddress)")
    })
    #expect(await eventually {
        await events.events == ["192.168.1.44|02:11:22:33:44:55"]
    })
    #expect(await transport.bindCalls == [.anyIPv4(port: 53_220)])
    #expect(await transport.allowsBroadcastCalls == [false])

    await listener.stop()
    #expect(await transport.isClosed)
}

@Test("Startup parser rejects non-startup VENS commands")
func startupAdvertisementCommandValidation() {
    var packet = startupAdvertisementPacket(
        scannerIPAddress: [192, 168, 1, 44],
        scannerMACAddress: [2, 0x11, 0x22, 0x33, 0x44, 0x55]
    )
    packet[11] = 0x22

    #expect(throws: ScanSnapProtocolError.invalidCommand(expected: 0x21, actual: 0x22)) {
        try ScanSnapStartupAdvertisementParser.parse(packet)
    }
}

private func startupAdvertisementPacket(
    scannerIPAddress: [UInt8],
    scannerMACAddress: [UInt8]
) -> [UInt8] {
    var packet = [UInt8](repeating: 0, count: 48)
    packet[3] = 48
    packet.replaceSubrange(4..<8, with: Array("VENS".utf8))
    packet[11] = 0x21
    packet.replaceSubrange(20..<24, with: scannerIPAddress)
    packet.replaceSubrange(24..<30, with: scannerMACAddress)
    return packet
}
