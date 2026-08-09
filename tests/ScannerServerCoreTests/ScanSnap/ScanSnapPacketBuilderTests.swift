import ScannerServerCore
import Testing

@Test("Discovery packets are byte-exact")
func buildsDiscoveryPackets() throws {
    let packets = try ScanSnapPacketBuilder.discovery(
        clientIPAddress: "192.168.1.10",
        clientPort: 55_264,
        token: hexBytes("0102030405060000")
    )

    #expect(packets.vens == hexBytes("56454e5300000000c0a8010a01020304050600000000d7e00010000000000000"))
    #expect(packets.ssnr == hexBytes("73734e5200000000c0a8010a01020304050600000000d7e00100000000000000"))
}

@Test("Registration packets are byte-exact")
func buildsRegistrationPackets() throws {
    let packets = try ScanSnapPacketBuilder.registration(
        clientIPAddress: "192.168.1.10",
        clientMACAddress: fixtureClientMAC
    )

    #expect(packets.vens == hexBytes("56454e5300000000c0a8010a02112233445500000000d7e00010000000000000"))
    #expect(packets.ssnr == hexBytes("73734e5200000000c0a8010a02112233445500000000d7e00100000000000000"))
    #expect(packets.v2ss == hexBytes("5632737300000001c0a8010a02112233445500000000d7e01000000000000000"))
}

@Test("Button heartbeat is byte-exact")
func buildsButtonHeartbeat() throws {
    #expect(try ScanSnapPacketBuilder.heartbeat(
        clientIPAddress: "192.168.1.10",
        clientMACAddress: fixtureClientMAC
    ) == hexBytes("56454e5300000001c0a8010a02112233445500000000d7e01000000000000000"))
}

@Test("Pairing request preserves every proven offset")
func buildsPairingPacket() throws {
    let packet = try ScanSnapPacketBuilder.pairing(
        clientMACAddress: fixtureClientMAC,
        identity: ScanSnapIdentity("179130178176"),
        clientIPAddress: "192.168.1.10",
        timestamp: ScanSnapTimestamp(year: 2026, month: 7, day: 10, hour: 14, minute: 5, second: 9),
        deviceMetadata: hexBytes("aabbccdd11223344")
    )

    #expect(packet == hexBytes(
        "0000008056454e5300000011000000000211223344550000000000000000000000061e000000000000000001c0a8010a0000d7e131373931333031373831373600000000000000000000000000000000000000000000000000000000000000000000000007ea070a0e050900aabbccdd11223344ffffe3e00000000000000000"
    ))
}

@Test("Pairing request preserves password identities longer than 16 bytes")
func buildsPairingPacketWithLongPasswordIdentity() throws {
    let identity = try ScanSnapIdentity.derive(fromPassword: "123456")
    let packet = try ScanSnapPacketBuilder.pairing(
        clientMACAddress: fixtureClientMAC,
        identity: identity,
        clientIPAddress: "192.168.1.10",
        timestamp: ScanSnapTimestamp(year: 2026, month: 7, day: 10, hour: 14, minute: 5, second: 9),
        deviceMetadata: hexBytes("aabbccdd11223344")
    )

    #expect(identity.value == "172131179178131130")
    #expect(Array(packet[52..<70]) == Array(identity.value.utf8))
    #expect(packet[70..<100].allSatisfy { $0 == 0 })
    #expect(Array(packet[100..<107]) == hexBytes("07ea070a0e0509"))
}

@Test("Handshake and release frames are byte-exact")
func buildsControlFrames() throws {
    #expect(try ScanSnapPacketBuilder.handshakeCommand(0x13, clientMACAddress: fixtureClientMAC) == hexBytes(
        "0000002056454e53000000130000000002112233445500000000000000000000"
    ))
    #expect(try ScanSnapPacketBuilder.handshakeCommand(0x30, clientMACAddress: fixtureClientMAC) == hexBytes(
        "0000002056454e53000000300000000002112233445500000000000000000000"
    ))
    #expect(try ScanSnapPacketBuilder.releaseFrame(clientMACAddress: fixtureClientMAC) == hexBytes("""
        0000004056454e53000000010000000002112233445500000000000000000000
        00000006000000000000000000000000d6000000000000000000000000000000
        """))
}

@Test("Button initialization payloads and interleaving are preserved")
func preservesButtonInitializationSequence() throws {
    let expectedCommands = [
        "0000000600000060000000000000000012000000600000000000000000000000",
        "0000000a0000000c0000000000000000e70001000000000c0000000000000000",
        "0000000a000000200000000000000000c2000000000000002000000000000000",
        "00000008000000040000000000000000e6000100000000040000000000000000",
        "00000008000000000000000400000000e6000000000400000000000000000000101e0000",
        "00000006000000080000000800000000d50000000808000000000000000000000000000000000000",
        "00000006000000000000000000000000d6000000000000000000000000000000",
    ].map(hexBytes)

    #expect(ScanSnapPacketBuilder.buttonInitializationCommands == expectedCommands)
    #expect(ScanSnapPacketBuilder.buttonInitializationSequence == [
        .handshakeCommand(0x13),
        .initializationFrame(index: 0),
        .handshakeCommand(0x30),
        .initializationFrame(index: 1),
        .initializationFrame(index: 2),
        .initializationFrame(index: 3),
        .initializationFrame(index: 4),
        .initializationFrame(index: 5),
        .initializationFrame(index: 6),
    ])

    let frames = try ScanSnapPacketBuilder.buttonInitializationFrames(clientMACAddress: fixtureClientMAC)
    #expect(frames.map(\.count) == [64, 64, 64, 64, 68, 72, 64])
    #expect(frames.map { Array($0[32...]) } == expectedCommands)
}

@Test("Builders reject malformed field sizes and IPv4 text")
func rejectsMalformedBuilderInput() {
    #expect(throws: ScanSnapProtocolError.invalidByteCount(
        field: "client MAC address",
        expected: 6,
        actual: 5
    )) {
        try ScanSnapPacketBuilder.registration(clientIPAddress: "192.168.1.10", clientMACAddress: [0, 1, 2, 3, 4])
    }
    #expect(throws: ScanSnapProtocolError.invalidByteCount(
        field: "discovery token",
        expected: 8,
        actual: 7
    )) {
        try ScanSnapPacketBuilder.discovery(clientIPAddress: "192.168.1.10", clientPort: 55_264, token: [UInt8](repeating: 0, count: 7))
    }
    #expect(throws: ScanSnapProtocolError.invalidIPv4Address("192.168.1.999")) {
        try ScanSnapPacketBuilder.discovery(clientIPAddress: "192.168.1.999", clientPort: 55_264, token: [UInt8](repeating: 0, count: 8))
    }
}

@Test("Big-endian helpers preserve signed and unsigned wire values")
func bigEndianCodec() throws {
    #expect(ScanSnapByteCodec.bigEndianBytes(UInt16(0xD7E0)) == [0xD7, 0xE0])
    #expect(ScanSnapByteCodec.bigEndianBytes(UInt32(0x0102_0304)) == [1, 2, 3, 4])
    #expect(ScanSnapByteCodec.bigEndianBytes(Int32(-4)) == [0xFF, 0xFF, 0xFF, 0xFC])
    #expect(try ScanSnapByteCodec.readUInt16(from: [0xD7, 0xE0], at: 0) == 0xD7E0)
    #expect(try ScanSnapByteCodec.readUInt32(from: [1, 2, 3, 4], at: 0) == 0x0102_0304)
}
