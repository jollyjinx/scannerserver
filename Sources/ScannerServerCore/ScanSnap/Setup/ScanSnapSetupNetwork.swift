import Foundation

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
    func clientIPAddress(for scannerIPAddress: String) async throws -> String
    func clientMACAddress(preferredInterface: String) async throws -> [UInt8]
}

public struct SystemScanSnapSetupNetworkProvider: ScanSnapSetupNetworkProviding {
    public init() {}

    public func ipv4Interfaces() async throws -> [ScanSnapSetupIPv4Interface] {
        if let data = try? Self.run("ip", ["-j", "-4", "addr", "show", "scope", "global"]),
           let interfaces = try? Self.parseInterfaces(data), !interfaces.isEmpty {
            return interfaces
        }
        return try Self.parseIfconfig(Self.run("ifconfig", []))
    }

    public func arpNeighbors() async throws -> [ScanSnapSetupARPNeighbor] {
        if let data = try? Self.run("ip", ["-j", "-4", "neigh", "show"]),
           let neighbors = try? Self.parseNeighbors(data) {
            return neighbors
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "/proc/net/arp")) {
            return Self.parseProcARP(data)
        }
        return []
    }

    public func clientIPAddress(for scannerIPAddress: String) async throws -> String {
        let scannerIPAddress = try ScannerConfig.normalizeIPv4Address(scannerIPAddress)
        if let data = try? Self.run("ip", ["-j", "-4", "route", "get", scannerIPAddress]),
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
            if let output = try? Self.run("ifconfig", [name]),
               let text = String(data: output, encoding: .utf8),
               let token = text.split(whereSeparator: \.isWhitespace)
                    .drop(while: { $0 != "ether" }).dropFirst().first,
               let bytes = try? ScanSnapSetupEnvironmentConfiguration.macBytes(String(token)) {
                return bytes
            }
        }
        throw ScanSnapSetupConfigurationError.noClientMACAddress
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ScanSnapSetupConfigurationError.systemLookupFailed(
                "\(executable) \(arguments.joined(separator: " ")) failed"
            )
        }
        return data
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

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
