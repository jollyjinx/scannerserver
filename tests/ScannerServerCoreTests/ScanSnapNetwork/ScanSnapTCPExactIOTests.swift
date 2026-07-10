import ScannerServerCore
import Testing

@Test("TCP exact reads combine partial socket reads")
func tcpExactReadCombinesChunks() async throws {
    let connection = FakeTCPConnection(readChunks: [[1], [2, 3, 4], [5, 6]])

    let bytes = try await connection.readExactly(6, timeoutMilliseconds: 250)

    #expect(bytes == [1, 2, 3, 4, 5, 6])
}

@Test("TCP exact reads report a closed connection")
func tcpExactReadReportsClosure() async {
    let connection = FakeTCPConnection(readChunks: [[1, 2], []])

    do {
        _ = try await connection.readExactly(4, timeoutMilliseconds: 250)
        Issue.record("Expected a connection-closed error")
    } catch {
        #expect(error as? ScanSnapSocketError == .connectionClosed(expectedBytes: 4, receivedBytes: 2))
    }
}

@Test("TCP write-all retries partial socket writes without reordering bytes")
func tcpWriteAllCombinesPartialWrites() async throws {
    let connection = FakeTCPConnection(readChunks: [], writeLimits: [2, 1, 3])

    try await connection.writeAll([1, 2, 3, 4, 5, 6], timeoutMilliseconds: 250)

    #expect(await connection.writtenBytes == [1, 2, 3, 4, 5, 6])
    #expect(await connection.writeArguments == [[1, 2, 3, 4, 5, 6], [3, 4, 5, 6], [4, 5, 6]])
}
