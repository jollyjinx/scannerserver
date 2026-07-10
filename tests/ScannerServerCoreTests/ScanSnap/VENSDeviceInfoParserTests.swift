import ScannerServerCore
import Testing

@Test("VENS device info preserves every documented 132-byte field")
func parsesVENSDeviceInfo() throws {
    let packet = hexBytes(
        "56454e53000000000000000000000000000000000000cfe20000cfe3aabbccddeeff000001020304415752484330383132320020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020206958353030204f6666696365002020200a000005deadbeef01234567"
    )

    let device = try VENSDeviceInfoParser.parse(packet, remoteIPAddress: "192.168.1.44")

    #expect(device.id == "aa:bb:cc:dd:ee:ff@192.168.1.44")
    #expect(device.ipAddress == "192.168.1.44")
    #expect(device.macAddress == "aa:bb:cc:dd:ee:ff")
    #expect(device.serialNumber == "AWRHC08122")
    #expect(device.name == "iX500 Office")
    #expect(device.dataPort == 53_218)
    #expect(device.controlPort == 53_219)
    #expect(device.state == 0x0102_0304)
    #expect(device.clientIPAddress == "10.0.0.5")
    #expect(device.metadata == hexBytes("deadbeef01234567"))
}

@Test("Advertised addresses win and zero client addresses become nil")
func parsesAdvertisedAndEmptyClientAddresses() throws {
    var packet = [UInt8](repeating: 0, count: VENSDeviceInfoParser.packetLength)
    packet.replaceSubrange(0..<4, with: Array("VENS".utf8))
    packet.replaceSubrange(16..<20, with: [172, 16, 3, 9])

    let device = try VENSDeviceInfoParser.parse(packet, remoteIPAddress: "192.168.1.44")

    #expect(device.ipAddress == "172.16.3.9")
    #expect(device.clientIPAddress == nil)
    #expect(device.name == "ScanSnap")
}

@Test("Device info rejects short and incorrectly signed packets")
func rejectsMalformedVENSDeviceInfo() {
    #expect(throws: ScanSnapProtocolError.packetTooShort(minimum: 132, actual: 131)) {
        try VENSDeviceInfoParser.parse([UInt8](repeating: 0, count: 131))
    }

    var packet = [UInt8](repeating: 0, count: 132)
    packet.replaceSubrange(0..<4, with: Array("NOPE".utf8))
    #expect(throws: ScanSnapProtocolError.invalidSignature(
        expected: Array("VENS".utf8),
        actual: Array("NOPE".utf8)
    )) {
        try VENSDeviceInfoParser.parse(packet)
    }
}
