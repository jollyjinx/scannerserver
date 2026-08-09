import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct ScanSnapSetupIPv4Interface: Equatable, Hashable, Sendable {
    public let name: String
    public let ipAddress: String
    public let prefixLength: Int

    public init(name: String, ipAddress: String, prefixLength: Int) throws {
        guard (0...32).contains(prefixLength) else {
            throw ScanSnapSetupConfigurationError.invalidPrefixLength(prefixLength)
        }
        self.name = name
        self.ipAddress = try ScannerConfig.normalizeIPv4Address(ipAddress)
        self.prefixLength = prefixLength
    }

    public var broadcastAddress: String {
        let value = Self.ipv4Value(ipAddress)
        let mask: UInt32 = prefixLength == 0 ? 0 : UInt32.max << (32 - UInt32(prefixLength))
        return Self.ipv4String(value | ~mask)
    }

    public func contains(_ address: String) -> Bool {
        guard let normalized = try? ScannerConfig.normalizeIPv4Address(address) else { return false }
        let mask: UInt32 = prefixLength == 0 ? 0 : UInt32.max << (32 - UInt32(prefixLength))
        return Self.ipv4Value(ipAddress) & mask == Self.ipv4Value(normalized) & mask
    }

    private static func ipv4Value(_ address: String) -> UInt32 {
        address.split(separator: ".").reduce(0) { ($0 << 8) | UInt32($1)! }
    }

    private static func ipv4String(_ value: UInt32) -> String {
        [24, 16, 8, 0].map { String((value >> UInt32($0)) & 0xFF) }.joined(separator: ".")
    }
}

public struct ScanSnapSetupARPNeighbor: Equatable, Hashable, Sendable {
    public let ipAddress: String
    public let macAddress: String
    public let state: String
    public let interfaceName: String

    public init(ipAddress: String, macAddress: String, state: String, interfaceName: String) throws {
        self.ipAddress = try ScannerConfig.normalizeIPv4Address(ipAddress)
        self.macAddress = try ScannerConfig.normalizeMACAddress(macAddress)
        self.state = state
        self.interfaceName = interfaceName
    }
}

public protocol ScanSnapSetupNetworkProviding: Sendable {
    func ipv4Interfaces() async throws -> [ScanSnapSetupIPv4Interface]
    func arpNeighbors() async throws -> [ScanSnapSetupARPNeighbor]
    func resolveScannerIPv4Address(_ addressOrName: String) async throws -> String
    func clientIPAddress(for scannerIPAddress: String) async throws -> String
    func clientMACAddress(preferredInterface: String) async throws -> [UInt8]
}

public extension ScanSnapSetupNetworkProviding {
    func resolveScannerIPv4Address(_ addressOrName: String) async throws -> String {
        try ScannerConfig.normalizeIPv4Address(addressOrName)
    }
}

public struct SystemScanSnapSetupNetworkProvider: ScanSnapSetupNetworkProviding {
    private let executor: any ProcessExecutor
    private let commandTimeoutMilliseconds: UInt64
    private let commandEnvironment: [String: String]?

    public init(
        executor: any ProcessExecutor = FoundationProcessExecutor(),
        commandTimeoutMilliseconds: UInt64 = 2_000,
        commandEnvironment: [String: String]? = nil
    ) {
        self.executor = executor
        self.commandTimeoutMilliseconds = commandTimeoutMilliseconds
        self.commandEnvironment = commandEnvironment
    }

    public func ipv4Interfaces() async throws -> [ScanSnapSetupIPv4Interface] {
        if let data = try await optionalRun("ip", ["-j", "-4", "addr", "show", "scope", "global"]),
           let interfaces = try? Self.parseInterfaces(data), !interfaces.isEmpty {
            return interfaces
        }
        return try Self.parseIfconfig(try await run("ifconfig", []))
    }

    public func arpNeighbors() async throws -> [ScanSnapSetupARPNeighbor] {
        if let data = try await optionalRun("ip", ["-j", "-4", "neigh", "show"]),
           let neighbors = try? Self.parseNeighbors(data) {
            return neighbors
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "/proc/net/arp")) {
            return Self.parseProcARP(data)
        }
        return []
    }

    @concurrent
    public func resolveScannerIPv4Address(_ addressOrName: String) async throws -> String {
        let addressOrName = addressOrName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try ScannerConfig.normalizeIPv4Address(addressOrName)
        } catch SettingsValidationError.invalidIPv4Address {
            guard !addressOrName.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else {
                throw SettingsValidationError.invalidIPv4Address
            }
            return try Self.resolveHostName(addressOrName)
        }
    }

    public func clientIPAddress(for scannerIPAddress: String) async throws -> String {
        let scannerIPAddress = try ScannerConfig.normalizeIPv4Address(scannerIPAddress)
        if let data = try await optionalRun("ip", ["-j", "-4", "route", "get", scannerIPAddress]),
           let address = Self.routeSourceAddress(data) {
            return address
        }
        if let matching = try await ipv4Interfaces().first(where: { $0.contains(scannerIPAddress) }) {
            return matching.ipAddress
        }
        throw ScanSnapSetupConfigurationError.noRouteToScanner(scannerIPAddress)
    }

    public func clientMACAddress(preferredInterface: String) async throws -> [UInt8] {
        var names = [preferredInterface]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: "/sys/class/net") {
            names.append(contentsOf: entries.filter { $0 != "lo" }.sorted())
        }
        for name in Self.unique(names) {
            let path = "/sys/class/net/\(name)/address"
            if let value = try? String(contentsOfFile: path, encoding: .utf8),
               let bytes = try? ScanSnapSetupEnvironmentConfiguration.macBytes(value),
               bytes != [UInt8](repeating: 0, count: 6) {
                return bytes
            }
            if let output = try await optionalRun("ifconfig", [name]),
               let text = String(data: output, encoding: .utf8),
               let token = text.split(whereSeparator: \.isWhitespace)
                    .drop(while: { $0 != "ether" }).dropFirst().first,
               let bytes = try? ScanSnapSetupEnvironmentConfiguration.macBytes(String(token)) {
                return bytes
            }
        }
        throw ScanSnapSetupConfigurationError.noClientMACAddress
    }

    private func optionalRun(_ executable: String, _ arguments: [String]) async throws -> Data? {
        do {
            return try await run(executable, arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        let result = try await executor.execute(ProcessRequest(
            executable: executable,
            arguments: arguments,
            environment: commandEnvironment,
            timeoutMilliseconds: commandTimeoutMilliseconds
        ))
        guard result.succeeded else {
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            throw ScanSnapSetupConfigurationError.systemLookupFailed(
                "\(executable) \(arguments.joined(separator: " ")) failed\(suffix)"
            )
        }
        return Data(result.standardOutput.utf8)
    }

    private static func parseInterfaces(_ data: Data) throws -> [ScanSnapSetupIPv4Interface] {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return try values.flatMap { item -> [ScanSnapSetupIPv4Interface] in
            let name = item["ifname"] as? String ?? ""
            let addresses = item["addr_info"] as? [[String: Any]] ?? []
            return try addresses.compactMap { address in
                guard address["family"] as? String == "inet",
                      let local = address["local"] as? String
                else { return nil }
                return try ScanSnapSetupIPv4Interface(
                    name: name,
                    ipAddress: local,
                    prefixLength: address["prefixlen"] as? Int ?? 24
                )
            }
        }
    }

    private static func parseNeighbors(_ data: Data) throws -> [ScanSnapSetupARPNeighbor] {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return values.compactMap { item in
            guard let ip = item["dst"] as? String,
                  let mac = item["lladdr"] as? String
            else { return nil }
            let state: String
            if let states = item["state"] as? [String] {
                state = states.joined(separator: ",")
            } else {
                state = item["state"] as? String ?? ""
            }
            return try? ScanSnapSetupARPNeighbor(
                ipAddress: ip,
                macAddress: mac,
                state: state,
                interfaceName: item["dev"] as? String ?? ""
            )
        }
    }

    private static func parseProcARP(_ data: Data) -> [ScanSnapSetupARPNeighbor] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 6 else { return nil }
            return try? ScanSnapSetupARPNeighbor(
                ipAddress: String(fields[0]),
                macAddress: String(fields[3]),
                state: String(fields[2]),
                interfaceName: String(fields[5])
            )
        }
    }

    private static func parseIfconfig(_ data: Data) throws -> [ScanSnapSetupIPv4Interface] {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        var currentName = ""
        var interfaces: [ScanSnapSetupIPv4Interface] = []
        for line in lines {
            if let first = line.first, !first.isWhitespace, let colon = line.firstIndex(of: ":") {
                currentName = String(line[..<colon])
            }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let inetIndex = fields.firstIndex(of: "inet"), fields.indices.contains(inetIndex + 1) else { continue }
            let address = String(fields[inetIndex + 1])
            guard address != "127.0.0.1" else { continue }
            let prefix = Self.ifconfigPrefix(fields: fields) ?? 24
            if let value = try? ScanSnapSetupIPv4Interface(name: currentName, ipAddress: address, prefixLength: prefix) {
                interfaces.append(value)
            }
        }
        guard !interfaces.isEmpty else { throw ScanSnapSetupConfigurationError.noIPv4Interface }
        return interfaces
    }

    private static func ifconfigPrefix(fields: [Substring]) -> Int? {
        guard let index = fields.firstIndex(of: "netmask"), fields.indices.contains(index + 1) else { return nil }
        let value = fields[index + 1].lowercased().replacingOccurrences(of: "0x", with: "")
        guard let mask = UInt32(value, radix: 16) else { return nil }
        return mask.nonzeroBitCount
    }

    private static func routeSourceAddress(_ data: Data) -> String? {
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let route = values.first
        else { return nil }
        for key in ["prefsrc", "src"] {
            if let value = route[key] as? String,
               let normalized = try? ScannerConfig.normalizeIPv4Address(value), !normalized.isEmpty {
                return normalized
            }
        }
        return nil
    }

    private static func resolveHostName(_ name: String) throws -> String {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var results: UnsafeMutablePointer<addrinfo>?
        let status = name.withCString { getaddrinfo($0, nil, &hints, &results) }
        guard status == 0, let first = results else {
            let message = gai_strerror(status).map(String.init(cString:)) ?? "name lookup failed"
            throw ScanSnapSetupConfigurationError.scannerNameResolutionFailed(
                name: name,
                message: message
            )
        }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        while let result = current {
            defer { current = result.pointee.ai_next }
            guard result.pointee.ai_family == AF_INET,
                  let address = result.pointee.ai_addr
            else {
                continue
            }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var rawAddress = ipv4.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let converted = buffer.withUnsafeMutableBufferPointer { pointer in
                inet_ntop(AF_INET, &rawAddress, pointer.baseAddress, socklen_t(pointer.count))
            }
            let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
            let addressString = String(
                decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            if converted != nil,
               let normalized = try? ScannerConfig.normalizeIPv4Address(addressString),
               !normalized.isEmpty {
                return normalized
            }
        }

        throw ScanSnapSetupConfigurationError.scannerNameResolutionFailed(
            name: name,
            message: "no IPv4 address was returned"
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
