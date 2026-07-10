import Hummingbird
import HummingbirdTesting
import ScannerServerCore
import Testing

@Suite("Scanner server HTTP application")
struct ScannerServerApplicationTests {
    @Test("Service configuration preserves the container environment contract")
    func environmentConfiguration() throws {
        let defaults = try ScannerServerServiceConfiguration(environment: [:])
        #expect(defaults.hostname == "0.0.0.0")
        #expect(defaults.port == 8080)

        let configured = try ScannerServerServiceConfiguration(
            environment: ["WEB_HOST": "127.0.0.1", "WEB_PORT": "9090"]
        )
        #expect(configured.hostname == "127.0.0.1")
        #expect(configured.port == 9090)
    }

    @Test("Invalid ports fail during startup validation", arguments: ["invalid", "0", "65536"])
    func invalidPort(value: String) {
        #expect(throws: ScannerServerConfigurationError.self) {
            try ScannerServerServiceConfiguration(environment: ["WEB_PORT": value])
        }
    }

    @Test("Health and index routes are available")
    func baselineRoutes() async throws {
        let configuration = try ScannerServerServiceConfiguration(hostname: "127.0.0.1", port: 8080)
        let application = try ScannerServerApplication.make(configuration: configuration)

        try await application.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "ok\n")
            }
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/html; charset=utf-8")
                #expect(String(buffer: response.body).contains("ScanSnap scanner server"))
            }
        }
    }
}
