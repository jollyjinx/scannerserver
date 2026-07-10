import ScannerServerCore
import Testing

@Test("Factory identity matches the documented iX500 fixture")
func derivesFactoryIdentity() throws {
    let credentials = try ScanSnapCredentials.factoryDefault(serialNumber: "AWRHC08122")

    #expect(credentials.password == "8122")
    #expect(credentials.identity.value == "179130178176")
}

@Test("Identity derivation rejects passwords longer than the protocol key")
func rejectsLongPassword() {
    #expect(throws: ScanSnapProtocolError.passwordTooLong(
        maximumCharacters: 16,
        actualCharacters: 17
    )) {
        try ScanSnapIdentity.derive(fromPassword: "12345678901234567")
    }
}

@Test("Pairing response decodes signed big-endian status", arguments: [
    (Int32(0), ScanSnapPairingStatus.accepted),
    (-4, .sessionBusy),
    (-7, .pairedToDifferentClientIP),
    (-42, .rejected(-42)),
])
func parsesPairingStatus(code: Int32, expected: ScanSnapPairingStatus) throws {
    var response = [UInt8](repeating: 0, count: 12)
    response.replaceSubrange(8..<12, with: ScanSnapByteCodec.bigEndianBytes(code))

    #expect(try ScanSnapPairingStatus.parse(response: response) == expected)
    #expect(expected.code == code)
}

@Test("Short pairing responses are explicit protocol errors")
func rejectsShortPairingStatus() {
    #expect(throws: ScanSnapProtocolError.shortPairingResponse(actual: 11)) {
        try ScanSnapPairingStatus.parse(response: [UInt8](repeating: 0, count: 11))
    }
}

@Test("Setup pairing retries busy sessions and releases accepted probes")
func pairingTestRetryPolicy() {
    let policy = ScanSnapSessionRetryPolicy.pairingTest

    #expect(policy.maximumAttempts == 4)
    #expect(policy.action(after: .sessionBusy, attemptsMade: 1) == .releaseThenRetry(afterMilliseconds: 1_000))
    #expect(policy.action(after: .sessionBusy, attemptsMade: 4) == .releaseThenStop(afterMilliseconds: 1_000))
    #expect(policy.action(after: .accepted, attemptsMade: 2) == .releaseSession)
}

@Test("Button arming permits eight busy retries and retains an accepted session")
func buttonArmingRetryPolicy() {
    let policy = ScanSnapSessionRetryPolicy.buttonArming

    #expect(policy.maximumAttempts == 9)
    #expect(policy.action(after: .sessionBusy, attemptsMade: 8) == .releaseThenRetry(afterMilliseconds: 1_000))
    #expect(policy.action(after: .sessionBusy, attemptsMade: 9) == .stop)
    #expect(policy.action(after: .accepted, attemptsMade: 9) == .keepSession)
    #expect(policy.action(after: .passwordRejected, attemptsMade: 1) == .stop)
}
