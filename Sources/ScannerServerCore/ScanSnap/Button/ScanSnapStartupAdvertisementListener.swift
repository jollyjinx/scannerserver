import JLog

public actor ScanSnapStartupAdvertisementListener {
    public typealias Handler = @Sendable (ScanSnapStartupAdvertisement) async -> Void

    private let port: UInt16
    private let pollMilliseconds: UInt64
    private let udpTransportFactory: any ScanSnapUDPTransportFactory
    private let sleeper: any ScanSnapSleeper

    private var task: Task<Void, Never>?
    private var transport: (any ScanSnapUDPTransport)?
    private var generation: UInt64 = 0

    public init(
        port: UInt16 = ScanSnapPacketBuilder.startupAdvertisementPort,
        pollMilliseconds: UInt64 = 1_000,
        udpTransportFactory: any ScanSnapUDPTransportFactory = POSIXScanSnapUDPTransportFactory(),
        sleeper: any ScanSnapSleeper = TaskScanSnapSleeper()
    ) {
        self.port = port
        self.pollMilliseconds = max(pollMilliseconds, 1)
        self.udpTransportFactory = udpTransportFactory
        self.sleeper = sleeper
    }

    @discardableResult
    public func start(handler: @escaping Handler) async throws -> Bool {
        guard task == nil else { return false }

        let newTransport = try await udpTransportFactory.makeTransport()
        do {
            _ = try await newTransport.bind(
                to: .anyIPv4(port: port),
                allowsBroadcast: false
            )
        } catch {
            await newTransport.close()
            throw error
        }

        generation &+= 1
        let generation = generation
        transport = newTransport
        task = Task { [weak self] in
            await self?.supervise(
                startingWith: newTransport,
                generation: generation,
                handler: handler
            )
        }
        JLog.notice("ScanSnap startup advertisement listener active on UDP \(port)")
        return true
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
        startingWith initialTransport: any ScanSnapUDPTransport,
        generation: UInt64,
        handler: @escaping Handler
    ) async {
        var activeTransport: (any ScanSnapUDPTransport)? = initialTransport
        var consecutiveFailures = 0

        while !Task.isCancelled, generation == self.generation {
            if activeTransport == nil {
                do {
                    try await sleeper.sleep(milliseconds: retryDelay(after: consecutiveFailures))
                    try Task.checkCancellation()
                    let replacement = try await udpTransportFactory.makeTransport()
                    do {
                        _ = try await replacement.bind(
                            to: .anyIPv4(port: port),
                            allowsBroadcast: false
                        )
                        activeTransport = replacement
                        transport = replacement
                    } catch {
                        await replacement.close()
                        throw error
                    }
                } catch is CancellationError {
                    break
                } catch {
                    consecutiveFailures = min(consecutiveFailures + 1, 64)
                    JLog.warning("ScanSnap startup listener restart failed: \(error)")
                    continue
                }
            }

            guard let currentTransport = activeTransport else { continue }
            do {
                let datagram = try await currentTransport.receive(
                    maximumBytes: 256,
                    timeoutMilliseconds: pollMilliseconds
                )
                consecutiveFailures = 0
                guard let datagram,
                      let advertisement = try? ScanSnapStartupAdvertisementParser.parse(
                          datagram.bytes,
                          remoteIPAddress: datagram.remoteAddress.host
                      )
                else {
                    continue
                }
                await handler(advertisement)
            } catch is CancellationError {
                break
            } catch {
                consecutiveFailures = min(consecutiveFailures + 1, 64)
                JLog.warning("ScanSnap startup listener failed; retrying: \(error)")
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

    private func retryDelay(after failureCount: Int) -> UInt64 {
        let exponent = min(max(failureCount - 1, 0), 5)
        return min(100 << exponent, 3_000)
    }
}
