import Foundation

public enum ScanSnapButtonArmingError: Error, Sendable, Equatable {
    case pairingRejected(ScanSnapPairingStatus)
    case invalidResponseLength(Int)
    case invalidResponseSignature
    case timedOut(milliseconds: UInt64)
}

public struct ScanSnapButtonSessionArmer: ScanSnapButtonArming {
    private let pairing: any ScanSnapButtonPairing
    private let connectionFactory: any ScanSnapTCPConnectionFactory
    private let timestampProvider: @Sendable () -> ScanSnapTimestamp

    public init(
        pairing: any ScanSnapButtonPairing = ScanSnapPairingActor(),
        connectionFactory: any ScanSnapTCPConnectionFactory = POSIXScanSnapTCPConnectionFactory()
    ) {
        self.pairing = pairing
        self.connectionFactory = connectionFactory
        timestampProvider = { ScanSnapTimestamp.current() }
    }

    public init(
        pairing: any ScanSnapButtonPairing,
        connectionFactory: any ScanSnapTCPConnectionFactory,
        timestampProvider: @escaping @Sendable () -> ScanSnapTimestamp
    ) {
        self.pairing = pairing
        self.connectionFactory = connectionFactory
        self.timestampProvider = timestampProvider
    }

    public func arm(
        scanner: ScanSnapButtonScannerConfiguration,
        configuration: ScanSnapButtonConfiguration
    ) async throws {
        try await runWithTimeout(configuration.armTimeoutMilliseconds) {
            try await armWithoutTimeout(scanner: scanner, configuration: configuration)
        }
    }

    public func recoverAndArm(
        scanner: ScanSnapButtonScannerConfiguration,
        configuration: ScanSnapButtonConfiguration
    ) async throws {
        try await runWithTimeout(configuration.armTimeoutMilliseconds) {
            let recoveryResult = try await pairing.pair(
                configuration: pairingConfiguration(
                    scanner: scanner,
                    configuration: configuration,
                    retryPolicy: .pairingTest
                ),
                timestamp: timestampProvider()
            )
            guard recoveryResult.accepted else {
                throw ScanSnapButtonArmingError.pairingRejected(recoveryResult.status)
            }
            try await armWithoutTimeout(scanner: scanner, configuration: configuration)
        }
    }

    private func runWithTimeout(
        _ timeout: UInt64,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(Int64(clamping: timeout)))
                throw ScanSnapButtonArmingError.timedOut(milliseconds: timeout)
            }

            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func armWithoutTimeout(
        scanner: ScanSnapButtonScannerConfiguration,
        configuration: ScanSnapButtonConfiguration
    ) async throws {
        let result = try await pairing.pair(
            configuration: pairingConfiguration(
                scanner: scanner,
                configuration: configuration,
                retryPolicy: .buttonArming
            ),
            timestamp: timestampProvider()
        )
        guard result.accepted else {
            throw ScanSnapButtonArmingError.pairingRejected(result.status)
        }

        try await initializeDataSession(scanner: scanner)
    }

    private func pairingConfiguration(
        scanner: ScanSnapButtonScannerConfiguration,
        configuration: ScanSnapButtonConfiguration,
        retryPolicy: ScanSnapSessionRetryPolicy
    ) -> ScanSnapPairingConfiguration {
        ScanSnapPairingConfiguration(
            scannerIPAddress: scanner.scannerIPAddress,
            clientIPAddress: scanner.clientIPAddress,
            clientMACAddress: scanner.clientMACAddress,
            identity: scanner.identity,
            registrationSourcePort: configuration.registrationSourcePort,
            registrationPort: configuration.registrationPort,
            controlPort: scanner.controlPort,
            dataPort: scanner.dataPort,
            registrationRounds: scanner.registrationRounds,
            registrationTimeoutMilliseconds: scanner.registrationTimeoutMilliseconds,
            connectionTimeoutMilliseconds: scanner.connectionTimeoutMilliseconds,
            retryPolicy: retryPolicy,
            allowsSourcePortFallback: scanner.allowsRegistrationSourcePortFallback
        )
    }

    private func initializeDataSession(scanner: ScanSnapButtonScannerConfiguration) async throws {
        let connection = try await connectionFactory.connect(
            to: ScanSnapSocketAddress(host: scanner.scannerIPAddress, port: scanner.dataPort),
            binding: ScanSnapSocketAddress(host: scanner.clientIPAddress, port: 0),
            timeoutMilliseconds: scanner.connectionTimeoutMilliseconds
        )

        do {
            _ = try await connection.readExactly(
                16,
                timeoutMilliseconds: scanner.connectionTimeoutMilliseconds
            )
            let frames = try ScanSnapPacketBuilder.buttonInitializationFrames(
                clientMACAddress: scanner.clientMACAddress
            )

            for step in ScanSnapPacketBuilder.buttonInitializationSequence {
                try Task.checkCancellation()
                switch step {
                case let .handshakeCommand(command):
                    // The scanner requires each control handshake to complete before
                    // the following data frame is sent on the other connection.
                    try await sendHandshakeCommand(command, scanner: scanner)
                case let .initializationFrame(index):
                    guard frames.indices.contains(index) else {
                        throw ScanSnapButtonArmingError.invalidResponseLength(index)
                    }
                    try await connection.writeAll(
                        frames[index],
                        timeoutMilliseconds: scanner.connectionTimeoutMilliseconds
                    )
                    try await receiveVENS(
                        from: connection,
                        timeoutMilliseconds: scanner.connectionTimeoutMilliseconds
                    )
                }
            }
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    private func sendHandshakeCommand(
        _ command: UInt32,
        scanner: ScanSnapButtonScannerConfiguration
    ) async throws {
        let connection = try await connectionFactory.connect(
            to: ScanSnapSocketAddress(host: scanner.scannerIPAddress, port: scanner.controlPort),
            binding: ScanSnapSocketAddress(host: scanner.clientIPAddress, port: 0),
            timeoutMilliseconds: scanner.connectionTimeoutMilliseconds
        )
        do {
            _ = try await connection.readExactly(
                16,
                timeoutMilliseconds: scanner.connectionTimeoutMilliseconds
            )
            try await connection.writeAll(
                ScanSnapPacketBuilder.handshakeCommand(command, clientMACAddress: scanner.clientMACAddress),
                timeoutMilliseconds: scanner.connectionTimeoutMilliseconds
            )
            try await receiveVENS(
                from: connection,
                timeoutMilliseconds: scanner.connectionTimeoutMilliseconds
            )
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    private func receiveVENS(
        from connection: any ScanSnapTCPConnection,
        timeoutMilliseconds: UInt64
    ) async throws {
        let header = try await connection.readExactly(16, timeoutMilliseconds: timeoutMilliseconds)
        let packetLength = Int(try ScanSnapByteCodec.readUInt32(from: header, at: 0))
        guard (16...(1024 * 1024)).contains(packetLength) else {
            throw ScanSnapButtonArmingError.invalidResponseLength(packetLength)
        }
        guard Array(header[4..<8]) == Array("VENS".utf8) else {
            throw ScanSnapButtonArmingError.invalidResponseSignature
        }
        if packetLength > header.count {
            _ = try await connection.readExactly(
                packetLength - header.count,
                timeoutMilliseconds: timeoutMilliseconds
            )
        }
    }
}

private extension ScanSnapTimestamp {
    static func current(date: Date = Date(), calendar: Calendar = .current) -> ScanSnapTimestamp {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return ScanSnapTimestamp(
            year: UInt16(clamping: components.year ?? 0),
            month: UInt8(clamping: components.month ?? 0),
            day: UInt8(clamping: components.day ?? 0),
            hour: UInt8(clamping: components.hour ?? 0),
            minute: UInt8(clamping: components.minute ?? 0),
            second: UInt8(clamping: components.second ?? 0)
        )
    }
}
