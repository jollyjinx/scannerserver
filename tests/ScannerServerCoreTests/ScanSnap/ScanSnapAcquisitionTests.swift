import Foundation
@testable import ScannerServerCore
import Testing

@Suite("Native ScanSnap acquisition")
struct ScanSnapAcquisitionTests {
    @Test("Scan commands encode side and back-face fields")
    func scanCommandFields() {
        let front = ScanSnapAcquisitionPacketBuilder.scanStart(side: 0)
        let back = ScanSnapAcquisitionPacketBuilder.scanStart(side: 7)
        let done = ScanSnapAcquisitionPacketBuilder.doneQuery(side: 7)

        #expect(front.count == 32)
        #expect(front[21] == 0)
        #expect(front[26] == 0)
        #expect(back[21] == 0x80)
        #expect(back[26] == 7)
        #expect(done[26] == 7)
    }

    @Test("Only the captured terminal status reports an empty feeder")
    func feederEmptyStatus() {
        let terminal = [UInt8](repeating: 0, count: 24)
            + ScanSnapAcquisitionPacketBuilder.feederEmptyStatus
        var unrelated = terminal
        unrelated[unrelated.count - 1] = 1

        #expect(ScanSnapAcquisitionPacketBuilder.reportsFeederEmpty(terminal))
        #expect(!ScanSnapAcquisitionPacketBuilder.reportsFeederEmpty(unrelated))
        #expect(!ScanSnapAcquisitionPacketBuilder.reportsFeederEmpty([UInt8](repeating: 0, count: 64)))
    }

    @Test("VENS error status keeps its signed value")
    func scannerErrorStatus() throws {
        var response = [UInt8](repeating: 0, count: 16)
        response.replaceSubrange(4..<8, with: Array("VENS".utf8))
        response.replaceSubrange(8..<12, with: ScanSnapByteCodec.bigEndianBytes(Int32(-7)))

        #expect(try ScanSnapAcquisitionPacketBuilder.scannerStatus(in: response) == -7)
        response.replaceSubrange(8..<12, with: [0, 0, 0, 0])
        #expect(try ScanSnapAcquisitionPacketBuilder.scannerStatus(in: response) == nil)
        response.replaceSubrange(4..<8, with: Array("JPEG".utf8))
        #expect(try ScanSnapAcquisitionPacketBuilder.scannerStatus(in: response) == nil)
    }

    @Test("Fragmented JPEGs are extracted without consuming the next response")
    func fragmentedJPEGStream() throws {
        var stream = ScanSnapJPEGBuffer(bytes: [0, 1, 0xFF])
        #expect(try stream.extractJPEG() == nil)
        try stream.append([0xD8, 3, 4, 0xFF])
        #expect(try stream.extractJPEG() == nil)
        try stream.append([0xD9, 9, 8, 7])

        #expect(try stream.extractJPEG() == Data([0xFF, 0xD8, 3, 4, 0xFF, 0xD9]))
        #expect(stream.bytes == [9, 8, 7])
    }

    @Test("JPEG buffering enforces the acquisition safety limit")
    func jpegSafetyLimit() {
        var stream = ScanSnapJPEGBuffer(bytes: [1, 2], maximumBytes: 3)
        #expect(throws: ScanSnapAcquisitionError.imageTooLarge(maximumBytes: 3)) {
            try stream.append([3, 4])
        }
    }

    @Test("Swift PDF writer embeds scanner JPEG pages at 300 DPI")
    func pdfWriter() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scansnap-pdf-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("scan.pdf")
        let jpeg = fixtureJPEG(width: 2_480, height: 3_507)

        try await ScanSnapPDFWriter().write(pages: [jpeg, jpeg], to: output)

        let data = try Data(contentsOf: output)
        let text = String(decoding: data, as: UTF8.self)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect(data.starts(with: Data("%PDF-1.4\n".utf8)))
        #expect(text.contains("/Count 2"))
        #expect(text.contains("/Width 2480 /Height 3507"))
        #expect(text.contains("/MediaBox [0 0 595.20 841.68]"))
        #expect(text.hasSuffix("%%EOF\n"))
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test("Native client acquires a duplex batch from the handed-off session")
    func nativeClientDuplexBatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scansnap-client-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("scan.pdf")
        let jpeg = [UInt8](fixtureJPEG(width: 2_480, height: 3_507))

        var reads: [[UInt8]] = [vensResponse()]
        reads.append(contentsOf: Array(repeating: vensResponse(), count: 8))
        reads.append(vensResponse() + jpeg)
        reads.append(vensResponse())
        reads.append(vensResponse() + jpeg)
        reads.append(contentsOf: Array(repeating: vensResponse(), count: 4))
        reads.append(vensResponse(payload: ScanSnapAcquisitionPacketBuilder.feederEmptyStatus))
        let connection = FakeTCPConnection(readChunks: reads)
        let connectionFactory = FakeTCPConnectionFactory([connection])
        let udp = FakeUDPTransport(boundPort: 55_264, receiveBehavior: .values([nil, nil, nil]))
        let armer = ButtonFakeArmer()
        let sleeper = RecordingSleeper()
        let client = ScanSnapWiFiAcquisitionClient(
            connectionFactory: connectionFactory,
            udpTransportFactory: FakeUDPTransportFactory([udp]),
            sessionArmer: armer,
            sleeper: sleeper
        )

        let result = try await client.acquire(ScanSnapWiFiAcquisitionRequest(
            scannerIPAddress: "192.0.2.20",
            identity: ScanSnapIdentity("pairing-key"),
            clientIPAddress: "192.0.2.30",
            clientMACAddress: [0x02, 0x11, 0x22, 0x33, 0x44, 0x55],
            simplex: false,
            reusesArmedSession: true,
            debug: true,
            outputURL: output
        ))

        #expect(result.pageCount == 2)
        #expect(result.diagnostics.contains("sheet 1 front"))
        #expect(result.diagnostics.contains("sheet 1 back"))
        #expect(try Data(contentsOf: output).starts(with: Data("%PDF-1.4\n".utf8)))
        #expect(await armer.calls.isEmpty)
        #expect(await armer.releaseCalls.count == 1)
        #expect(await udp.sends.count == 3)
        #expect(await connection.didShutdownWriting)
        #expect(await connection.isClosed)
    }

    private func fixtureJPEG(width: Int, height: Int) -> Data {
        Data([
            0xFF, 0xD8,
            0xFF, 0xC0,
            0x00, 0x11, 0x08,
            UInt8(height >> 8), UInt8(truncatingIfNeeded: height),
            UInt8(width >> 8), UInt8(truncatingIfNeeded: width),
            0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00,
            0xFF, 0xD9,
        ])
    }

    private func vensResponse(payload: [UInt8] = []) -> [UInt8] {
        var response = [UInt8](repeating: 0, count: 16 + payload.count)
        response.replaceSubrange(
            0..<4,
            with: ScanSnapByteCodec.bigEndianBytes(UInt32(response.count))
        )
        response.replaceSubrange(4..<8, with: Array("VENS".utf8))
        response.replaceSubrange(16..<response.count, with: payload)
        return response
    }
}
