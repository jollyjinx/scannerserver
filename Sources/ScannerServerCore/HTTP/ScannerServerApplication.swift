import Foundation
import Hummingbird

public struct ScannerServerServiceConfiguration: Equatable, Sendable {
    public static let defaultHostname = "0.0.0.0"
    public static let defaultPort = 8080

    public let hostname: String
    public let port: Int

    public init(hostname: String = defaultHostname, port: Int = defaultPort) throws {
        guard (1...65_535).contains(port) else {
            throw ScannerServerConfigurationError.invalidPort(port)
        }
        self.hostname = hostname
        self.port = port
    }

    public init(environment: [String: String]) throws {
        let hostname = environment["WEB_HOST"] ?? Self.defaultHostname
        let port: Int
        if let value = environment["WEB_PORT"] {
            guard let parsedPort = Int(value) else {
                throw ScannerServerConfigurationError.invalidPortValue(value)
            }
            port = parsedPort
        } else {
            port = Self.defaultPort
        }
        try self.init(hostname: hostname, port: port)
    }

    public func overriding(hostname: String?, port: Int?) throws -> Self {
        try Self(hostname: hostname ?? self.hostname, port: port ?? self.port)
    }
}

public enum ScannerServerConfigurationError: Error, Equatable, Sendable {
    case invalidPort(Int)
    case invalidPortValue(String)
    case missingIndexResource
    case unreadableIndexResource
}

public enum ScannerServerApplication {
    public static func make(
        configuration: ScannerServerServiceConfiguration
    ) throws -> some ApplicationProtocol {
        let indexHTML = try loadIndexHTML()
        let router = Router()

        router.get("/") { _, _ -> Response in
            htmlResponse(indexHTML)
        }
        router.get("/health") { _, _ in
            "ok\n"
        }

        return Application(
            responder: router.buildResponder(),
            configuration: .init(
                address: .hostname(configuration.hostname, port: configuration.port),
                serverName: ScannerServerCore.productName
            )
        )
    }

    private static func loadIndexHTML() throws -> String {
        guard let url = Bundle.module.url(forResource: "index", withExtension: "html") else {
            throw ScannerServerConfigurationError.missingIndexResource
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw ScannerServerConfigurationError.unreadableIndexResource
        }
        return contents
    }

    private static func htmlResponse(_ contents: String) -> Response {
        let buffer = ByteBuffer(string: contents)
        return Response(
            status: .ok,
            headers: [
                .contentType: "text/html; charset=utf-8",
                .contentLength: "\(buffer.readableBytes)",
            ],
            body: .init(byteBuffer: buffer)
        )
    }
}
