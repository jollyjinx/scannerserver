public struct ScanSnapDiscoveryRoute: Sendable, Hashable {
    public let clientIPAddress: String
    public let targetIPAddresses: [String]

    public init(clientIPAddress: String, targetIPAddresses: [String]) {
        self.clientIPAddress = clientIPAddress
        self.targetIPAddresses = targetIPAddresses
    }
}

public struct ScanSnapDiscoveryConfiguration: Sendable, Hashable {
    public let routes: [ScanSnapDiscoveryRoute]
    public let clientMACAddress: [UInt8]?
    public let sourcePort: UInt16
    public let registrationPort: UInt16
    public let rounds: Int
    public let timeoutMilliseconds: UInt64
    public let allowsSourcePortFallback: Bool
    public let token: [UInt8]

    public init(
        routes: [ScanSnapDiscoveryRoute],
        clientMACAddress: [UInt8]? = nil,
        sourcePort: UInt16 = ScanSnapPacketBuilder.registrationSourcePort,
        registrationPort: UInt16 = ScanSnapPacketBuilder.registrationPort,
        rounds: Int = 2,
        timeoutMilliseconds: UInt64 = 4_000,
        allowsSourcePortFallback: Bool = true,
        token: [UInt8] = ScanSnapDiscoveryConfiguration.randomToken()
    ) {
        self.routes = routes
        self.clientMACAddress = clientMACAddress
        self.sourcePort = sourcePort
        self.registrationPort = registrationPort
        self.rounds = max(rounds, 1)
        self.timeoutMilliseconds = timeoutMilliseconds
        self.allowsSourcePortFallback = allowsSourcePortFallback
        self.token = token
    }

    public static func randomToken() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<6).map { _ in UInt8.random(in: .min ... .max, using: &generator) } + [0, 0]
    }
}

public actor ScanSnapDiscoveryActor {
    private let transportFactory: any ScanSnapUDPTransportFactory

    public init(transportFactory: any ScanSnapUDPTransportFactory = POSIXScanSnapUDPTransportFactory()) {
        self.transportFactory = transportFactory
    }

    public func discover(configuration: ScanSnapDiscoveryConfiguration) async throws -> [ScanSnapDevice] {
        try Task.checkCancellation()
        let transport = try await transportFactory.makeTransport()
        do {
            let clientPort = try await bind(
                transport,
                address: .anyIPv4(port: configuration.sourcePort),
                allowsFallback: configuration.allowsSourcePortFallback
            )
            let sendPlan = try makeSendPlan(configuration: configuration, clientPort: clientPort)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(
                by: .milliseconds(Int64(clamping: configuration.timeoutMilliseconds))
            )
            var devicesByID: [String: ScanSnapDevice] = [:]

            for roundIndex in 0..<configuration.rounds {
                guard scanSnapRemainingMilliseconds(until: deadline, clock: clock) > 0 else {
                    break
                }
                for item in sendPlan {
                    do {
                        for packet in item.packets {
                            try Task.checkCancellation()
                            try await transport.send(packet, to: item.address)
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        continue
                    }
                }

                let remaining = scanSnapRemainingMilliseconds(until: deadline, clock: clock)
                guard remaining > 0 else { break }
                let roundsRemaining = UInt64(configuration.rounds - roundIndex)
                let receiveWindow = max(remaining / roundsRemaining, 1)
                let windowDeadline = clock.now.advanced(
                    by: .milliseconds(Int64(clamping: receiveWindow))
                )
                let receiveDeadline = min(deadline, windowDeadline)

                while true {
                    let receiveRemaining = scanSnapRemainingMilliseconds(
                        until: receiveDeadline,
                        clock: clock
                    )
                    guard receiveRemaining > 0,
                      let datagram = try await transport.receive(
                          maximumBytes: 512,
                          timeoutMilliseconds: receiveRemaining
                      )
                    else {
                        break
                    }
                    try Task.checkCancellation()
                    guard datagram.bytes.count >= VENSDeviceInfoParser.packetLength,
                          let device = try? VENSDeviceInfoParser.parse(
                              datagram.bytes,
                              remoteIPAddress: datagram.remoteAddress.host
                          )
                    else {
                        continue
                    }
                    devicesByID[device.id] = device
                }
            }

            await transport.close()
            return devicesByID.values.sorted(by: deviceSortOrder)
        } catch {
            await transport.close()
            throw error
        }
    }

    private func bind(
        _ transport: any ScanSnapUDPTransport,
        address: ScanSnapSocketAddress,
        allowsFallback: Bool
    ) async throws -> UInt16 {
        do {
            return try await transport.bind(to: address, allowsBroadcast: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch where allowsFallback && address.port != 0 {
            return try await transport.bind(
                to: ScanSnapSocketAddress(host: address.host, port: 0),
                allowsBroadcast: true
            )
        }
    }

    private func makeSendPlan(
        configuration: ScanSnapDiscoveryConfiguration,
        clientPort: UInt16
    ) throws -> [(address: ScanSnapSocketAddress, packets: [[UInt8]])] {
        try configuration.routes.flatMap { route in
            let discovery = try ScanSnapPacketBuilder.discovery(
                clientIPAddress: route.clientIPAddress,
                clientPort: clientPort,
                token: configuration.token
            )
            var packets = [discovery.vens, discovery.ssnr]
            if let clientMACAddress = configuration.clientMACAddress {
                packets += try ScanSnapPacketBuilder.registration(
                    clientIPAddress: route.clientIPAddress,
                    clientMACAddress: clientMACAddress
                ).all
            }
            return route.targetIPAddresses.map { target in
                (
                    ScanSnapSocketAddress(host: target, port: configuration.registrationPort),
                    packets
                )
            }
        }
    }
}

private func deviceSortOrder(_ lhs: ScanSnapDevice, _ rhs: ScanSnapDevice) -> Bool {
    if lhs.name != rhs.name { return lhs.name < rhs.name }
    if lhs.ipAddress != rhs.ipAddress { return lhs.ipAddress < rhs.ipAddress }
    return lhs.macAddress < rhs.macAddress
}
