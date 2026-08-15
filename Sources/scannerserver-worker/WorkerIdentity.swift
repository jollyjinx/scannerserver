import Foundation

struct WorkerIdentity: Codable, Sendable {
    let workerID: String
    let authenticationToken: String

    static func loadOrCreate(at fileURL: URL) throws -> WorkerIdentity {
        if let data = try? Data(contentsOf: fileURL),
           let identity = try? JSONDecoder().decode(WorkerIdentity.self, from: data) {
            return identity
        }
        let identity = WorkerIdentity(
            workerID: UUID().uuidString.lowercased(),
            authenticationToken: UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(identity)
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
        return identity
    }

    static var defaultFileURL: URL {
        let configuredHome = ProcessInfo.processInfo.environment["HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let homeDirectory = configuredHome.flatMap { home in
            home.isEmpty ? nil : URL(fileURLWithPath: home, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
        return homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("scannerserver-worker", isDirectory: true)
            .appendingPathComponent("identity.json", isDirectory: false)
    }
}
