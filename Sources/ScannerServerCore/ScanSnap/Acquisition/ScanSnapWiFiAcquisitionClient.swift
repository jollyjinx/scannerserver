import Foundation

public struct ScanSnapWiFiAcquisitionClient: ScanSnapWiFiAcquiring {
    private struct Batch: Sendable {
        let pages: [Data]
        let feederEmpty: Bool
        let diagnostics: [String]
    }

    private let connectionFactory: any ScanSnapTCPConnectionFactory
    private let udpTransportFactory: any ScanSnapUDPTransportFactory
    private let sessionArmer: any ScanSnapButtonArming
    private let network: any ScanSnapSetupNetworkProviding
    private let sleeper: any ScanSnapSleeper
    private let pdfWriter: ScanSnapPDFWriter

    public init(
        connectionFactory: any ScanSnapTCPConnectionFactory = POSIXScanSnapTCPConnectionFactory(),
        udpTransportFactory: any ScanSnapUDPTransportFactory = POSIXScanSnapUDPTransportFactory(),
        sessionArmer: any ScanSnapButtonArming = ScanSnapButtonSessionArmer(),
        network: any ScanSnapSetupNetworkProviding = SystemScanSnapSetupNetworkProvider(),
        sleeper: any ScanSnapSleeper = TaskScanSnapSleeper(),
        pdfWriter: ScanSnapPDFWriter = ScanSnapPDFWriter()
    ) {
        self.connectionFactory = connectionFactory
        self.udpTransportFactory = udpTransportFactory
        self.sessionArmer = sessionArmer
        self.network = network
        self.sleeper = sleeper
        self.pdfWriter = pdfWriter
    }

    public func acquire(
        _ request: ScanSnapWiFiAcquisitionRequest
    ) async throws -> ScanSnapWiFiAcquisitionResult {
        let scannerIPAddress = try ScannerConfig.normalizeIPv4Address(request.scannerIPAddress)
        let clientIPAddress: String
        if let configured = request.clientIPAddress {
            clientIPAddress = configured
        } else {
            clientIPAddress = try await network.clientIPAddress(for: scannerIPAddress)
        }
        let clientMACAddress: [UInt8]
        if let configured = request.clientMACAddress {
            clientMACAddress = configured
        } else {
            clientMACAddress = try await network.clientMACAddress(
                preferredInterface: request.clientInterface
            )
        }
        let scanner = ScanSnapButtonScannerConfiguration(
            scannerIPAddress: scannerIPAddress,
            clientIPAddress: clientIPAddress,
            clientMACAddress: clientMACAddress,
            identity: request.identity
        )
        let sessionConfiguration = ScanSnapButtonConfiguration(
            registrationSourcePort: request.registrationSourcePort,
            registrationPort: request.registrationPort
        )

        if !request.reusesArmedSession {
            try await sessionArmer.arm(scanner: scanner, configuration: sessionConfiguration)
        }
        await bestEffortRetainRegistration(
            scanner: scanner,
            sourcePort: request.registrationSourcePort,
            destinationPort: request.registrationPort
        )

        var pages: [Data] = []
        var diagnostics: [String] = []
        var firstBatch = true
        while true {
            try Task.checkCancellation()
            if !firstBatch {
                try await sessionArmer.arm(scanner: scanner, configuration: sessionConfiguration)
                await bestEffortRetainRegistration(
                    scanner: scanner,
                    sourcePort: request.registrationSourcePort,
                    destinationPort: request.registrationPort
                )
            }

            do {
                let batch = try await acquireBatch(
                    scanner: scanner,
                    sessionConfiguration: sessionConfiguration,
                    debug: request.debug
                )
                diagnostics.append(contentsOf: batch.diagnostics)
                for (index, page) in batch.pages.enumerated()
                    where !request.simplex || index.isMultiple(of: 2)
                {
                    pages.append(page)
                }
                if batch.feederEmpty || batch.pages.isEmpty { break }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if pages.isEmpty { throw error }
                diagnostics.append("A later Wi-Fi transfer batch ended early: \(error.localizedDescription)")
                break
            }
            firstBatch = false
        }

        guard !pages.isEmpty else { throw ScanSnapAcquisitionError.noPages }
        try await pdfWriter.write(pages: pages, to: request.outputURL)
        diagnostics.append("Saved \(request.outputURL.path) (\(pages.count) pages)")
        return ScanSnapWiFiAcquisitionResult(
            pageCount: pages.count,
            diagnostics: diagnostics.joined(separator: "\n") + "\n"
        )
    }

    private func acquireBatch(
        scanner: ScanSnapButtonScannerConfiguration,
        sessionConfiguration: ScanSnapButtonConfiguration,
        debug: Bool
    ) async throws -> Batch {
        let connection = try await connectionFactory.connect(
            to: ScanSnapSocketAddress(host: scanner.scannerIPAddress, port: scanner.dataPort),
            binding: ScanSnapSocketAddress(host: scanner.clientIPAddress, port: 0),
            timeoutMilliseconds: 10_000
        )
        do {
            let batch = try await transferBatch(connection: connection, scanner: scanner, debug: debug)
            await finishBatch(
                connection: connection,
                scanner: scanner,
                configuration: sessionConfiguration
            )
            return batch
        } catch {
            await finishBatch(
                connection: connection,
                scanner: scanner,
                configuration: sessionConfiguration
            )
            throw error
        }
    }

    private func transferBatch(
        connection: any ScanSnapTCPConnection,
        scanner: ScanSnapButtonScannerConfiguration,
        debug: Bool
    ) async throws -> Batch {
        _ = try await connection.readExactly(16, timeoutMilliseconds: 10_000)
        for command in ScanSnapAcquisitionPacketBuilder.setupCommands {
            _ = try await sendCommand(command, connection: connection, scanner: scanner)
        }

        try await sendWithoutResponse(
            ScanSnapAcquisitionPacketBuilder.scanStart(side: 0),
            connection: connection,
            scanner: scanner
        )
        let initial = try await connection.read(maximumBytes: 4_096, timeoutMilliseconds: 15_000)
        guard !initial.isEmpty else { throw ScanSnapAcquisitionError.noDocument }
        if let status = try ScanSnapAcquisitionPacketBuilder.scannerStatus(in: initial) {
            throw ScanSnapAcquisitionError.scannerRejected(status: status)
        }

        var stream = ScanSnapJPEGBuffer(bytes: initial)
        var pages: [Data] = []
        var diagnostics: [String] = []
        var side: UInt8 = 0
        var feederEmpty = false

        while pages.count < ScanSnapAcquisitionPacketBuilder.maximumSidesPerBatch {
            let jpeg: Data
            do {
                jpeg = try await nextJPEG(from: &stream, connection: connection)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if pages.isEmpty { throw error }
                break
            }
            pages.append(jpeg)
            if debug {
                let face = side.isMultiple(of: 2) ? "front" : "back"
                diagnostics.append("sheet \(Int(side) / 2 + 1) \(face) \(jpeg.count / 1_024) KB")
            }

            if side == UInt8.max { break }
            do {
                if side.isMultiple(of: 2) {
                    _ = try await sendCommand(
                        ScanSnapAcquisitionPacketBuilder.statusCommand,
                        connection: connection,
                        scanner: scanner
                    )
                } else {
                    _ = try await sendCommand(
                        ScanSnapAcquisitionPacketBuilder.statusCommand,
                        connection: connection,
                        scanner: scanner
                    )
                    _ = try await sendCommand(
                        ScanSnapAcquisitionPacketBuilder.doneQuery(side: side),
                        connection: connection,
                        scanner: scanner
                    )
                    _ = try await sendCommand(
                        ScanSnapAcquisitionPacketBuilder.stateCommand,
                        connection: connection,
                        scanner: scanner
                    )
                    _ = try await sendCommand(
                        ScanSnapAcquisitionPacketBuilder.endCommand,
                        connection: connection,
                        scanner: scanner
                    )
                    let status = try await sendCommand(
                        ScanSnapAcquisitionPacketBuilder.statusCommand,
                        connection: connection,
                        scanner: scanner
                    )
                    if debug {
                        diagnostics.append("sheet \(Int(side) / 2 + 1) status tail \(hex(status.suffix(12)))")
                    }
                    if ScanSnapAcquisitionPacketBuilder.reportsFeederEmpty(status) {
                        feederEmpty = true
                        break
                    }
                }

                side &+= 1
                try await sendWithoutResponse(
                    ScanSnapAcquisitionPacketBuilder.scanStart(side: side),
                    connection: connection,
                    scanner: scanner
                )
                let response = try await connection.read(
                    maximumBytes: 4_096,
                    timeoutMilliseconds: side.isMultiple(of: 2) ? 15_000 : 10_000
                )
                guard !response.isEmpty else { break }
                if let status = try ScanSnapAcquisitionPacketBuilder.scannerStatus(in: response) {
                    diagnostics.append("scan ended before side \(Int(side) + 1) with scanner status \(status)")
                    break
                }
                try stream.append(response)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                diagnostics.append("scan transfer ended after \(pages.count) sides: \(error.localizedDescription)")
                break
            }
        }
        return Batch(pages: pages, feederEmpty: feederEmpty, diagnostics: diagnostics)
    }

    private func nextJPEG(
        from stream: inout ScanSnapJPEGBuffer,
        connection: any ScanSnapTCPConnection
    ) async throws -> Data {
        while true {
            try Task.checkCancellation()
            if let jpeg = try stream.extractJPEG() { return jpeg }
            let bytes = try await connection.read(maximumBytes: 65_536, timeoutMilliseconds: 30_000)
            guard !bytes.isEmpty else { throw ScanSnapAcquisitionError.invalidJPEG }
            try stream.append(bytes)
        }
    }

    private func sendCommand(
        _ command: [UInt8],
        connection: any ScanSnapTCPConnection,
        scanner: ScanSnapButtonScannerConfiguration
    ) async throws -> [UInt8] {
        try await sendWithoutResponse(command, connection: connection, scanner: scanner)
        return try await receiveVENS(from: connection, timeoutMilliseconds: 5_000)
    }

    private func sendWithoutResponse(
        _ command: [UInt8],
        connection: any ScanSnapTCPConnection,
        scanner: ScanSnapButtonScannerConfiguration
    ) async throws {
        try await connection.writeAll(
            ScanSnapPacketBuilder.vensFrame(
                clientMACAddress: scanner.clientMACAddress,
                command: command
            ),
            timeoutMilliseconds: 5_000
        )
    }

    private func receiveVENS(
        from connection: any ScanSnapTCPConnection,
        timeoutMilliseconds: UInt64
    ) async throws -> [UInt8] {
        var response = try await connection.readExactly(16, timeoutMilliseconds: timeoutMilliseconds)
        let packetLength = Int(try ScanSnapByteCodec.readUInt32(from: response, at: 0))
        guard (16...ScanSnapAcquisitionPacketBuilder.maximumImageBytes).contains(packetLength),
              Array(response[4..<8]) == Array("VENS".utf8)
        else {
            throw ScanSnapAcquisitionError.invalidVENSResponse
        }
        if packetLength > response.count {
            response.append(contentsOf: try await connection.readExactly(
                packetLength - response.count,
                timeoutMilliseconds: timeoutMilliseconds
            ))
        }
        return response
    }

    private func finishBatch(
        connection: any ScanSnapTCPConnection,
        scanner: ScanSnapButtonScannerConfiguration,
        configuration: ScanSnapButtonConfiguration
    ) async {
        try? await connection.shutdownWriting()
        _ = try? await connection.read(maximumBytes: 1_024, timeoutMilliseconds: 2_000)
        await connection.close()
        try? await sleeper.sleep(milliseconds: 1_000)
        try? await sessionArmer.releaseSession(scanner: scanner, configuration: configuration)
    }

    private func bestEffortRetainRegistration(
        scanner: ScanSnapButtonScannerConfiguration,
        sourcePort: UInt16,
        destinationPort: UInt16
    ) async {
        guard let transport = try? await udpTransportFactory.makeTransport() else { return }
        do {
            _ = try await transport.bind(
                to: ScanSnapSocketAddress(host: scanner.clientIPAddress, port: sourcePort),
                allowsBroadcast: false
            )
            let packet = try ScanSnapPacketBuilder.heartbeat(
                clientIPAddress: scanner.clientIPAddress,
                clientMACAddress: scanner.clientMACAddress
            )
            let destination = ScanSnapSocketAddress(
                host: scanner.scannerIPAddress,
                port: destinationPort
            )
            for _ in 0..<3 {
                try Task.checkCancellation()
                try await transport.send(packet, to: destination)
                _ = try? await transport.receive(maximumBytes: 256, timeoutMilliseconds: 2_000)
                try? await sleeper.sleep(milliseconds: 500)
            }
        } catch {
            // The original client treats this acquisition re-registration as best effort.
        }
        await transport.close()
    }

    private func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
