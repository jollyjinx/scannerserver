import JLog

public protocol ScanSnapButtonHeartbeatControlling: Sendable {
    func start(
        scanner: ScanSnapButtonScannerConfiguration,
        configuration: ScanSnapButtonConfiguration
    ) async
    func stop() async
}

public actor NoopScanSnapButtonHeartbeat: ScanSnapButtonHeartbeatControlling {
    public init() {}

    public func start(
        scanner: ScanSnapButtonScannerConfiguration,
        configuration: ScanSnapButtonConfiguration
    ) {}

    public func stop() {}
}

public actor ScanSnapButtonHeartbeatActor: ScanSnapButtonHeartbeatControlling {
    private let udpTransportFactory: any ScanSnapUDPTransportFactory
    private let sleeper: any ScanSnapSleeper

    private var task: Task<Void, Never>?
    private var transport: (any ScanSnapUDPTransport)?
    private var generation: UInt64 = 0

    public init(
        udpTransportFactory: any ScanSnapUDPTransportFactory = POSIXScanSnapUDPTransportFactory(),
        sleeper: any ScanSnapSleeper = TaskScanSnapSleeper()
    ) {
        self.udpTransportFactory = udpTransportFactory
        self.sleeper = sleeper
    }

    public func start(
        scanner: ScanSnapButtonScannerConfiguration,
        configuration: ScanSnapButtonConfiguration
    ) async {
        await stop()
        guard configuration.heartbeatIntervalMilliseconds > 0 else { return }

        generation &+= 1
        let generation = generation
        task = Task { [weak self] in
            await self?.supervise(
                scanner: scanner,
                configuration: configuration,
                generation: generation
            )
        }
    }

    public func stop() async {
        generation &+= 1
        let runningTask = task
        let activeTransport = transport
        task = nil
        transport = nil
        runningTask?.cancel()
        await activeTransport?.close()
        await runningTask?.value
    }

    private func supervise(
        scanner: ScanSnapButtonScannerConfiguration,
        configuration: ScanSnapButtonConfiguration,
        generation: UInt64
    ) async {
        let packet: [UInt8]
        do {
            packet = try ScanSnapPacketBuilder.heartbeat(
                clientIPAddress: scanner.clientIPAddress,
                clientMACAddress: scanner.clientMACAddress
            )
        } catch {
            JLog.warning("ScanSnap button heartbeat packet creation failed: \(error)")
            return
        }

        let destination = ScanSnapSocketAddress(
            host: scanner.scannerIPAddress,
            port: configuration.registrationPort
        )
        var activeTransport: (any ScanSnapUDPTransport)?

        while !Task.isCancelled, generation == self.generation {
            if activeTransport == nil {
                do {
                    activeTransport = try await makeBoundTransport(
                        scanner: scanner,
                        configuration: configuration
                    )
                    transport = activeTransport
                } catch is CancellationError {
                    break
                } catch {
                    JLog.warning("ScanSnap button heartbeat socket failed: \(error)")
                    do {
                        try await sleeper.sleep(milliseconds: configuration.reachabilityIntervalMilliseconds)
                    } catch {
                        break
                    }
                    continue
                }
            }

            guard let currentTransport = activeTransport else { continue }
            do {
                try await currentTransport.send(packet, to: destination)
                try await sleeper.sleep(milliseconds: configuration.heartbeatIntervalMilliseconds)
            } catch is CancellationError {
                break
            } catch {
                JLog.warning("ScanSnap button heartbeat failed; recreating socket: \(error)")
                await currentTransport.close()
                self.transport = nil
                activeTransport = nil
            }
        }

        await activeTransport?.close()
        if generation == self.generation {
            transport = nil
            task = nil
        }
    }

    private func makeBoundTransport(
        scanner: ScanSnapButtonScannerConfiguration,
        configuration: ScanSnapButtonConfiguration
    ) async throws -> any ScanSnapUDPTransport {
        let preferred = try await udpTransportFactory.makeTransport()
        do {
            _ = try await preferred.bind(
                to: ScanSnapSocketAddress(
                    host: scanner.clientIPAddress,
                    port: configuration.registrationSourcePort
                ),
                allowsBroadcast: false
            )
            return preferred
        } catch is CancellationError {
            await preferred.close()
            throw CancellationError()
        } catch where scanner.allowsRegistrationSourcePortFallback
            && configuration.registrationSourcePort != 0
        {
            await preferred.close()
            let fallback = try await udpTransportFactory.makeTransport()
            do {
                _ = try await fallback.bind(
                    to: ScanSnapSocketAddress(host: scanner.clientIPAddress, port: 0),
                    allowsBroadcast: false
                )
                return fallback
            } catch {
                await fallback.close()
                throw error
            }
        } catch {
            await preferred.close()
            throw error
        }
    }
}
