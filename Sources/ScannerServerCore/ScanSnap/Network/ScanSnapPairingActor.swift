public struct ScanSnapPairingConfiguration: Sendable, Hashable {
    public let scannerIPAddress: String
    public let clientIPAddress: String
    public let clientMACAddress: [UInt8]
    public let identity: ScanSnapIdentity
    public let registrationSourcePort: UInt16
    public let registrationPort: UInt16
    public let controlPort: UInt16
    public let dataPort: UInt16
    public let registrationRounds: Int
    public let registrationTimeoutMilliseconds: UInt64
    public let connectionTimeoutMilliseconds: UInt64
    public let retryPolicy: ScanSnapSessionRetryPolicy
    public let allowsSourcePortFallback: Bool

    public init(
        scannerIPAddress: String,
        clientIPAddress: String,
        clientMACAddress: [UInt8],
        identity: ScanSnapIdentity,
        registrationSourcePort: UInt16 = ScanSnapPacketBuilder.registrationSourcePort,
        registrationPort: UInt16 = ScanSnapPacketBuilder.registrationPort,
        controlPort: UInt16 = ScanSnapPacketBuilder.controlPort,
        dataPort: UInt16 = ScanSnapPacketBuilder.dataPort,
        registrationRounds: Int = 4,
        registrationTimeoutMilliseconds: UInt64 = 3_000,
        connectionTimeoutMilliseconds: UInt64 = 5_000,
        retryPolicy: ScanSnapSessionRetryPolicy = .pairingTest,
        allowsSourcePortFallback: Bool = true
    ) {
        self.scannerIPAddress = scannerIPAddress
        self.clientIPAddress = clientIPAddress
        self.clientMACAddress = clientMACAddress
        self.identity = identity
        self.registrationSourcePort = registrationSourcePort
        self.registrationPort = registrationPort
        self.controlPort = controlPort
        self.dataPort = dataPort
        self.registrationRounds = max(registrationRounds, 1)
        self.registrationTimeoutMilliseconds = registrationTimeoutMilliseconds
        self.connectionTimeoutMilliseconds = connectionTimeoutMilliseconds
        self.retryPolicy = retryPolicy
        self.allowsSourcePortFallback = allowsSourcePortFallback
    }
}

public struct ScanSnapPairingResult: Sendable, Hashable {
    public let status: ScanSnapPairingStatus
    public let device: ScanSnapDevice?
    public let attemptsMade: Int

    public var accepted: Bool { status == .accepted }

    public init(status: ScanSnapPairingStatus, device: ScanSnapDevice?, attemptsMade: Int) {
        self.status = status
        self.device = device
        self.attemptsMade = attemptsMade
    }
}

public actor ScanSnapPairingActor {
    private let udpTransportFactory: any ScanSnapUDPTransportFactory
    private let tcpConnectionFactory: any ScanSnapTCPConnectionFactory
    private let sleeper: any ScanSnapSleeper

    public init(
        udpTransportFactory: any ScanSnapUDPTransportFactory = POSIXScanSnapUDPTransportFactory(),
        tcpConnectionFactory: any ScanSnapTCPConnectionFactory = POSIXScanSnapTCPConnectionFactory(),
        sleeper: any ScanSnapSleeper = TaskScanSnapSleeper()
    ) {
        self.udpTransportFactory = udpTransportFactory
        self.tcpConnectionFactory = tcpConnectionFactory
        self.sleeper = sleeper
    }

    public func pair(
        configuration: ScanSnapPairingConfiguration,
        timestamp: ScanSnapTimestamp
    ) async throws -> ScanSnapPairingResult {
        var attemptsMade = 0
        var latestDevice: ScanSnapDevice?

        while attemptsMade < configuration.retryPolicy.maximumAttempts {
            try Task.checkCancellation()
            attemptsMade += 1
            let attempt = try await pairingAttempt(configuration: configuration, timestamp: timestamp)
            latestDevice = attempt.device ?? latestDevice

            switch configuration.retryPolicy.action(after: attempt.status, attemptsMade: attemptsMade) {
            case .stop, .keepSession:
                return ScanSnapPairingResult(
                    status: attempt.status,
                    device: latestDevice,
                    attemptsMade: attemptsMade
                )
            case .releaseSession:
                try await bestEffortRelease(configuration: configuration)
                return ScanSnapPairingResult(
                    status: attempt.status,
                    device: latestDevice,
                    attemptsMade: attemptsMade
                )
            case let .releaseThenRetry(delay):
                try await bestEffortRelease(configuration: configuration)
                try await sleeper.sleep(milliseconds: delay)
            case let .releaseThenStop(delay):
                try await bestEffortRelease(configuration: configuration)
                try await sleeper.sleep(milliseconds: delay)
                return ScanSnapPairingResult(
                    status: attempt.status,
                    device: latestDevice,
                    attemptsMade: attemptsMade
                )
            }
        }

        preconditionFailure("Pairing retry policy must stop at its maximum attempt count")
    }

    private func pairingAttempt(
        configuration: ScanSnapPairingConfiguration,
        timestamp: ScanSnapTimestamp
    ) async throws -> (status: ScanSnapPairingStatus, device: ScanSnapDevice?) {
        let device = try await register(configuration: configuration)
        let metadata = device?.metadata ?? [UInt8](repeating: 0, count: 8)
        let packet = try ScanSnapPacketBuilder.pairing(
            clientMACAddress: configuration.clientMACAddress,
            identity: configuration.identity,
            clientIPAddress: configuration.clientIPAddress,
            timestamp: timestamp,
            deviceMetadata: metadata
        )
        let connection = try await tcpConnectionFactory.connect(
            to: ScanSnapSocketAddress(host: configuration.scannerIPAddress, port: configuration.controlPort),
            binding: ScanSnapSocketAddress(host: configuration.clientIPAddress, port: 0),
            timeoutMilliseconds: configuration.connectionTimeoutMilliseconds
        )
        do {
            _ = try await connection.readExactly(
                16,
                timeoutMilliseconds: configuration.connectionTimeoutMilliseconds
            )
            try await connection.writeAll(
                packet,
                timeoutMilliseconds: configuration.connectionTimeoutMilliseconds
            )
            let response = try await connection.readExactly(
                12,
                timeoutMilliseconds: configuration.connectionTimeoutMilliseconds
            )
            await connection.close()
            return (try ScanSnapPairingStatus.parse(response: response), device)
        } catch {
            await connection.close()
            throw error
        }
    }

    private func register(configuration: ScanSnapPairingConfiguration) async throws -> ScanSnapDevice? {
        let transport = try await udpTransportFactory.makeTransport()
        do {
            do {
                _ = try await transport.bind(
                    to: ScanSnapSocketAddress(
                        host: configuration.clientIPAddress,
                        port: configuration.registrationSourcePort
                    ),
                    allowsBroadcast: false
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch where configuration.allowsSourcePortFallback && configuration.registrationSourcePort != 0 {
                _ = try await transport.bind(
                    to: ScanSnapSocketAddress(host: configuration.clientIPAddress, port: 0),
                    allowsBroadcast: false
                )
            }

            let packets = try ScanSnapPacketBuilder.registration(
                clientIPAddress: configuration.clientIPAddress,
                clientMACAddress: configuration.clientMACAddress
            ).all
            let remoteAddress = ScanSnapSocketAddress(
                host: configuration.scannerIPAddress,
                port: configuration.registrationPort
            )
            for _ in 0..<configuration.registrationRounds {
                for packet in packets {
                    try Task.checkCancellation()
                    try await transport.send(packet, to: remoteAddress)
                }
            }

            let datagram = try await transport.receive(
                maximumBytes: 256,
                timeoutMilliseconds: configuration.registrationTimeoutMilliseconds
            )
            await transport.close()
            guard let datagram,
                  datagram.bytes.count >= VENSDeviceInfoParser.packetLength
            else {
                return nil
            }
            return try? VENSDeviceInfoParser.parse(
                datagram.bytes,
                remoteIPAddress: datagram.remoteAddress.host
            )
        } catch {
            await transport.close()
            throw error
        }
    }

    private func bestEffortRelease(configuration: ScanSnapPairingConfiguration) async throws {
        do {
            try await release(configuration: configuration)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Release mirrors the Python transport's best-effort session cleanup.
        }
    }

    private func release(configuration: ScanSnapPairingConfiguration) async throws {
        let connection = try await tcpConnectionFactory.connect(
            to: ScanSnapSocketAddress(host: configuration.scannerIPAddress, port: configuration.dataPort),
            binding: ScanSnapSocketAddress(host: configuration.clientIPAddress, port: 0),
            timeoutMilliseconds: configuration.connectionTimeoutMilliseconds
        )
        do {
            _ = try await connection.readExactly(
                16,
                timeoutMilliseconds: configuration.connectionTimeoutMilliseconds
            )
            try await connection.writeAll(
                ScanSnapPacketBuilder.releaseFrame(clientMACAddress: configuration.clientMACAddress),
                timeoutMilliseconds: configuration.connectionTimeoutMilliseconds
            )
            _ = try await connection.readExactly(
                16,
                timeoutMilliseconds: configuration.connectionTimeoutMilliseconds
            )
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }
}
