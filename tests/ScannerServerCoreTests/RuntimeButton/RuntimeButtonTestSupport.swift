import Foundation
import ScannerServerCore

actor RuntimeButtonFakeNetwork: ScanSnapSetupNetworkProviding {
    let derivedIPAddress: String
    let derivedMACAddress: [UInt8]
    private(set) var requestedScannerIPAddresses: [String] = []
    private(set) var requestedInterfaceNames: [String] = []

    init(
        derivedIPAddress: String = "192.168.50.10",
        derivedMACAddress: [UInt8] = [2, 0x11, 0x22, 0x33, 0x44, 0x55]
    ) {
        self.derivedIPAddress = derivedIPAddress
        self.derivedMACAddress = derivedMACAddress
    }

    func ipv4Interfaces() -> [ScanSnapSetupIPv4Interface] { [] }
    func arpNeighbors() -> [ScanSnapSetupARPNeighbor] { [] }

    func clientIPAddress(for scannerIPAddress: String) -> String {
        requestedScannerIPAddresses.append(scannerIPAddress)
        return derivedIPAddress
    }

    func clientMACAddress(preferredInterface: String) -> [UInt8] {
        requestedInterfaceNames.append(preferredInterface)
        return derivedMACAddress
    }
}

actor RuntimeButtonProcessExecutor: ProcessExecutor {
    private var recordedRequests: [ProcessRequest] = []
    private var executionContinuation: CheckedContinuation<Void, Never>?

    func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        recordedRequests.append(request)
        await withCheckedContinuation { continuation in
            executionContinuation = continuation
        }
        return ProcessResult(exitStatus: 0)
    }

    func requests() -> [ProcessRequest] {
        recordedRequests
    }

    func complete() {
        executionContinuation?.resume()
        executionContinuation = nil
    }
}

actor RuntimeButtonFakeUDPTransport: ScanSnapUDPTransport {
    let boundPort: UInt16
    private(set) var bindCalls: [ScanSnapSocketAddress] = []
    private(set) var isClosed = false

    init(boundPort: UInt16 = 55_265) {
        self.boundPort = boundPort
    }

    func bind(to localAddress: ScanSnapSocketAddress, allowsBroadcast: Bool) -> UInt16 {
        bindCalls.append(localAddress)
        return boundPort
    }

    func send(_ bytes: [UInt8], to remoteAddress: ScanSnapSocketAddress) {}

    func receive(maximumBytes: Int, timeoutMilliseconds: UInt64) async throws -> ScanSnapDatagram? {
        try await Task.sleep(for: .seconds(60))
        return nil
    }

    func close() {
        isClosed = true
    }
}

actor RuntimeButtonFakeUDPFactory: ScanSnapUDPTransportFactory {
    let transport: RuntimeButtonFakeUDPTransport
    private(set) var makeCallCount = 0

    init(transport: RuntimeButtonFakeUDPTransport = RuntimeButtonFakeUDPTransport()) {
        self.transport = transport
    }

    func makeTransport() -> any ScanSnapUDPTransport {
        makeCallCount += 1
        return transport
    }
}

struct RuntimeButtonUnreachable: ScanSnapButtonReachabilityChecking {
    func isReachable(
        scanner: ScanSnapButtonScannerConfiguration,
        port: UInt16,
        timeoutMilliseconds: UInt64
    ) -> Bool {
        false
    }
}

struct RuntimeButtonNoopArmer: ScanSnapButtonArming {
    func arm(
        scanner: ScanSnapButtonScannerConfiguration,
        configuration: ScanSnapButtonConfiguration
    ) {}
}

func runtimeButtonTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RuntimeButtonTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func runtimeButtonNotice(source: String) -> ScanSnapDatagram {
    var bytes = [UInt8](repeating: 0, count: 12)
    bytes.replaceSubrange(4..<8, with: Array("VENS".utf8))
    return ScanSnapDatagram(
        bytes: bytes,
        remoteAddress: ScanSnapSocketAddress(host: source, port: 52_217)
    )
}

func runtimeButtonEventually(
    attempts: Int = 200,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
