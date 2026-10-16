import Foundation
import ScannerServerCore
import Testing

private typealias Wire = ScanSnapWiFiProtocolFixtures
private typealias Step = ScanSnapProtocolStep

@Suite("iX500 Wi-Fi protocol transcripts")
struct ScanSnapWiFiProtocolTranscriptTests {
    @Test("Fresh and retained sessions preserve complete command order and bytes",
          arguments: [false, true], [1, 7, Int.max])
    func acquisition(reusesArmedSession: Bool, fragmentSize: Int) async throws {
        let steps = (reusesArmedSession ? [] : armSession())
            + retainRegistration() + beginAcquisition()
            + sheet(front: Wire.jpegSide0, back: Wire.jpegSide1, status: Wire.feederEmpty)
            + finishAcquisition()
        let fixture = try WiFiTranscriptFixture(steps, fragmentSize: fragmentSize)
        defer { fixture.remove() }

        let result = try await fixture.acquire(reusesArmedSession: reusesArmedSession)

        #expect(result.pageCount == 2)
        try await fixture.expectPages([Wire.jpegSide0, Wire.jpegSide1])
        await fixture.script.assertFinished()
    }

    @Test("Simplex retains the duplex wire sequence and filters only the received backs",
          arguments: [false, true])
    func simplex(simplex: Bool) async throws {
        let fixture = try WiFiTranscriptFixture(
            retainRegistration() + beginAcquisition()
                + sheet(front: Wire.jpegSide0, back: Wire.jpegSide1, status: Wire.feederEmpty)
                + finishAcquisition()
        )
        defer { fixture.remove() }

        let result = try await fixture.acquire(simplex: simplex)
        let expected = simplex ? [Wire.jpegSide0] : [Wire.jpegSide0, Wire.jpegSide1]

        #expect(result.pageCount == expected.count)
        try await fixture.expectPages(expected)
        await fixture.script.assertFinished()
    }

    @Test("All-zero and unrelated nonzero status tails continue within the same transfer",
          arguments: [Wire.zeroStatus, Wire.nonterminalStatus])
    func nonterminalStatus(status: [UInt8]) async throws {
        let fixture = try WiFiTranscriptFixture(
            retainRegistration() + beginAcquisition()
                + sheet(front: Wire.jpegSide0, back: Wire.jpegSide1, status: status)
                + sheet(front: Wire.jpegSide2, back: Wire.jpegSide3,
                        status: Wire.feederEmpty, sideBase: 2)
                + finishAcquisition(),
            fragmentSize: 7
        )
        defer { fixture.remove() }

        let result = try await fixture.acquire()

        #expect(result.pageCount == 4)
        try await fixture.expectPages([Wire.jpegSide0, Wire.jpegSide1, Wire.jpegSide2, Wire.jpegSide3])
        await fixture.script.assertFinished()
    }

    @Test("A transfer boundary re-arms once and continues page numbering and simplex filtering",
          arguments: [false, true])
    func transferContinuation(simplex: Bool) async throws {
        let fixture = try WiFiTranscriptFixture(
            firstTransfer()
                + armSession() + retainRegistration() + beginAcquisition()
                + sheet(front: Wire.jpegSide2, back: Wire.jpegSide3, status: Wire.feederEmpty)
                + finishAcquisition(),
            fragmentSize: 7
        )
        defer { fixture.remove() }

        let result = try await fixture.acquire(simplex: simplex)
        let expected = simplex
            ? [Wire.jpegSide0, Wire.jpegSide2]
            : [Wire.jpegSide0, Wire.jpegSide1, Wire.jpegSide2, Wire.jpegSide3]

        #expect(result.pageCount == expected.count)
        try await fixture.expectPages(expected)
        await fixture.script.assertFinished()
    }

    @Test("A first-transfer rejection preserves the signed status and finalizes with D6")
    func initialRejection() async throws {
        let fixture = try WiFiTranscriptFixture(
            retainRegistration() + beginAcquisition()
                + [.write("acquisition", Wire.scanSide0), .read("acquisition", Wire.rejected)]
                + finishAcquisition()
        )
        defer { fixture.remove() }

        await #expect(throws: ScanSnapAcquisitionError.scannerRejected(status: -7)) {
            try await fixture.acquire()
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.outputURL.path))
        #expect(await fixture.pages.values.isEmpty)
        await fixture.script.assertFinished()
    }

    @Test("A later-transfer rejection keeps the already received document")
    func laterRejection() async throws {
        let fixture = try WiFiTranscriptFixture(
            firstTransfer()
                + armSession() + retainRegistration() + beginAcquisition()
                + [.write("acquisition", Wire.scanSide0), .read("acquisition", Wire.rejected)]
                + finishAcquisition()
        )
        defer { fixture.remove() }

        let result = try await fixture.acquire()

        #expect(result.pageCount == 2)
        #expect(result.diagnostics.contains("A later Wi-Fi transfer batch ended early:"))
        try await fixture.expectPages([Wire.jpegSide0, Wire.jpegSide1])
        await fixture.script.assertFinished()
    }

    @Test("Malformed setup acknowledgements abort acquisition and still finalize with D6",
          arguments: [
            "0000000f56454e530000000000000000",
            "0100000156454e530000000000000000",
            "000000104e4f50450000000000000000",
          ])
    func malformedAcknowledgement(response: String) async throws {
        let fixture = try WiFiTranscriptFixture(
            retainRegistration()
                + [.connect("acquisition", port: 53_218, timeout: 10_000),
                   .read("acquisition", Wire.hello),
                   .write("acquisition", Wire.setup0), .read("acquisition", hexBytes(response))]
                + finishAcquisition(),
            fragmentSize: 1
        )
        defer { fixture.remove() }

        await #expect(throws: ScanSnapAcquisitionError.invalidVENSResponse) {
            try await fixture.acquire()
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.outputURL.path))
        await fixture.script.assertFinished()
    }

    @Test("Cancellation during a partial JPEG publishes no PDF and finalizes with D6")
    func cancelledImageRead() async throws {
        let fixture = try WiFiTranscriptFixture(
            retainRegistration() + beginAcquisition()
                + [.write("acquisition", Wire.scanSide0),
                   .read("acquisition", Wire.hello + [0xFF, 0xD8]), .cancelRead("acquisition")]
                + finishAcquisition()
        )
        defer { fixture.remove() }

        await #expect(throws: CancellationError.self) {
            try await fixture.acquire()
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.outputURL.path))
        #expect(await fixture.pages.values.isEmpty)
        await fixture.script.assertFinished()
    }
}

private func retainRegistration() -> [Step] {
    [.openUDP("retain"), .bindUDP("retain")]
        + Array(repeating: [Step.sendUDP("retain", Wire.heartbeat),
                            .receiveUDP("retain", timeout: 2_000), .sleep(500)], count: 3).flatMap { $0 }
        + [.closeUDP("retain")]
}

private func armSession() -> [Step] {
    var steps: [Step] = [.openUDP("registration"), .bindUDP("registration")]
    for _ in 0..<4 {
        steps += [.sendUDP("registration", Wire.registrationVENS),
                  .sendUDP("registration", Wire.registrationSSNR),
                  .sendUDP("registration", Wire.registrationV2SS)]
    }
    steps += [.receiveUDP("registration", timeout: 3_000), .closeUDP("registration"),
              .connect("pairing", port: 53_219, timeout: 5_000), .read("pairing", Wire.hello),
              .write("pairing", Wire.pairing), .read("pairing", [UInt8](repeating: 0, count: 12)),
              .close("pairing"),
              .connect("initialization", port: 53_218, timeout: 5_000),
              .read("initialization", Wire.hello)]
    steps += controlHandshake("control13", frame: Wire.handshake13)
    steps += [.write("initialization", Wire.buttonInit0), .read("initialization", Wire.acknowledgement)]
    steps += controlHandshake("control30", frame: Wire.handshake30)
    for frame in [Wire.buttonInit1, Wire.buttonInit2, Wire.buttonInit3,
                  Wire.buttonInit4, Wire.buttonInit5, Wire.buttonInit6] {
        steps += [.write("initialization", frame), .read("initialization", Wire.acknowledgement)]
    }
    return steps + [.close("initialization")]
}

private func controlHandshake(_ channel: String, frame: [UInt8]) -> [Step] {
    [.connect(channel, port: 53_219, timeout: 5_000), .read(channel, Wire.hello),
     .write(channel, frame), .read(channel, Wire.acknowledgement), .close(channel)]
}

private func beginAcquisition() -> [Step] {
    var steps: [Step] = [.connect("acquisition", port: 53_218, timeout: 10_000),
                         .read("acquisition", Wire.hello)]
    for frame in [Wire.setup0, Wire.setup1, Wire.setup2, Wire.setup3,
                  Wire.setup4, Wire.setup5, Wire.statusCommand, Wire.endCommand] {
        steps += [.write("acquisition", frame), .read("acquisition", Wire.acknowledgement)]
    }
    return steps
}

private func sheet(front: [UInt8], back: [UInt8], status: [UInt8], sideBase: Int = 0) -> [Step] {
    [.write("acquisition", sideBase == 0 ? Wire.scanSide0 : Wire.scanSide2),
     .read("acquisition", Wire.hello + front),
     .write("acquisition", Wire.statusCommand), .read("acquisition", Wire.acknowledgement),
     .write("acquisition", sideBase == 0 ? Wire.scanSide1 : Wire.scanSide3),
     .read("acquisition", Wire.hello + back),
     .write("acquisition", Wire.statusCommand), .read("acquisition", Wire.acknowledgement),
     .write("acquisition", sideBase == 0 ? Wire.doneSide1 : Wire.doneSide3),
     .read("acquisition", Wire.acknowledgement),
     .write("acquisition", Wire.stateCommand), .read("acquisition", Wire.acknowledgement),
     .write("acquisition", Wire.endCommand), .read("acquisition", Wire.acknowledgement),
     .write("acquisition", Wire.statusCommand), .read("acquisition", status)]
}

private func finishAcquisition() -> [Step] {
    [.shutdown("acquisition"), .read("acquisition", []), .close("acquisition"), .sleep(1_000),
     .connect("finalization", port: 53_218, timeout: 5_000), .read("finalization", Wire.hello),
     .write("finalization", Wire.buttonInit6), .read("finalization", Wire.acknowledgement),
     .shutdown("finalization"), .read("finalization", [0x7F]), .read("finalization", []),
     .close("finalization")]
}

private func firstTransfer() -> [Step] {
    retainRegistration() + beginAcquisition()
        + sheet(front: Wire.jpegSide0, back: Wire.jpegSide1, status: Wire.nonterminalStatus)
        + [.write("acquisition", Wire.scanSide2), .read("acquisition", [])]
        + finishAcquisition()
}

private struct WiFiTranscriptFixture: Sendable {
    let outputURL: URL
    let script: ScanSnapProtocolScript
    let pages = TranscriptPages()
    private let client: ScanSnapWiFiAcquisitionClient

    init(_ steps: [Step], fragmentSize: Int = .max) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scansnap-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        outputURL = root.appendingPathComponent("scan.pdf")
        script = ScanSnapProtocolScript(steps, fragmentSize: fragmentSize)
        let network = ScriptedScanSnapNetwork(script: script)
        let pairing = ScanSnapPairingActor(
            udpTransportFactory: network, tcpConnectionFactory: network, sleeper: network
        )
        let armer = ScanSnapButtonSessionArmer(
            pairing: pairing, connectionFactory: network,
            timestampProvider: { ScanSnapTimestamp(year: 2026, month: 10, day: 16,
                                                  hour: 12, minute: 34, second: 56) }
        )
        client = ScanSnapWiFiAcquisitionClient(
            connectionFactory: network, udpTransportFactory: network,
            sessionArmer: armer, sleeper: network
        )
    }

    func acquire(simplex: Bool = false, reusesArmedSession: Bool = true) async throws -> ScanSnapWiFiAcquisitionResult {
        try await client.acquire(ScanSnapWiFiAcquisitionRequest(
            scannerIPAddress: "192.0.2.20", identity: ScanSnapIdentity("fixture-only"),
            clientIPAddress: "192.0.2.30", clientMACAddress: [2, 0x11, 0x22, 0x33, 0x44, 0x55],
            simplex: simplex, reusesArmedSession: reusesArmedSession, debug: true, outputURL: outputURL
        )) { page in
            #expect(!FileManager.default.fileExists(atPath: outputURL.path))
            await pages.append(page)
        }
    }

    func expectPages(_ expected: [[UInt8]]) async throws {
        let received = await pages.values
        #expect(received.map(\.pageNumber) == Array(1...expected.count))
        #expect(received.map(\.jpegData) == expected.map { Data($0) })
        let pdf = try Data(contentsOf: outputURL)
        #expect(String(decoding: pdf, as: UTF8.self).contains("/Count \(expected.count)"))
        let positions = try expected.map { bytes in
            try #require(pdf.range(of: Data(bytes))).lowerBound
        }
        #expect(positions == positions.sorted())
    }

    func remove() {
        try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
    }
}

private actor TranscriptPages {
    private(set) var values: [ScanSnapAcquiredPage] = []

    func append(_ page: ScanSnapAcquiredPage) {
        values.append(page)
    }
}
