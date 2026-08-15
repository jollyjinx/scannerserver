import Foundation
import JLog

public struct OCRWorkerBonjourPublisherConfiguration: Equatable, Sendable {
    public let enabled: Bool
    public let serviceName: String
    public let advertisedURL: URL
    public let port: Int

    public init(
        environment: [String: String],
        serviceConfiguration: ScannerServerServiceConfiguration
    ) {
        enabled = Self.isTruthy(environment["SCAN_OCR_WORKER_BONJOUR_ENABLED"] ?? "false")
        serviceName = Self.nonEmpty(environment["SCANNERSERVER_BONJOUR_NAME"])
            ?? ScannerServerCore.productName
        port = serviceConfiguration.port

        if let configured = Self.nonEmpty(environment["SCANNERSERVER_BONJOUR_URL"]),
           let url = URL(string: configured),
           ["http", "https"].contains(url.scheme?.lowercased()),
           url.host != nil {
            advertisedURL = url
        } else {
            let hostname = Self.nonEmpty(environment["SCANNERSERVER_BONJOUR_HOST"])
                ?? ProcessInfo.processInfo.hostName
            var components = URLComponents()
            components.scheme = "http"
            components.host = hostname
            components.port = serviceConfiguration.port
            advertisedURL = components.url
                ?? URL(string: "http://localhost:\(serviceConfiguration.port)")!
        }
    }

    public var publicationRequest: ProcessRequest {
        ProcessRequest(
            executable: "avahi-publish-service",
            arguments: [
                "--no-fail",
                serviceName,
                OCRWorkerBonjourService.type,
                String(port),
                "api=\(OCRWorkerProtocol.currentVersion)",
                "url=\(advertisedURL.absoluteString)",
            ]
        )
    }

    private static func isTruthy(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": true
        default: false
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

public actor OCRWorkerBonjourPublisher {
    private let executor: any ProcessExecutor
    private let environment: [String: String]
    private var publicationTask: Task<Void, Never>?

    public init(
        executor: any ProcessExecutor = FoundationProcessExecutor(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executor = executor
        self.environment = environment
    }

    public func start(serviceConfiguration: ScannerServerServiceConfiguration) {
        guard publicationTask == nil else { return }
        let configuration = OCRWorkerBonjourPublisherConfiguration(
            environment: environment,
            serviceConfiguration: serviceConfiguration
        )
        guard configuration.enabled else { return }

        let executor = executor
        publicationTask = Task {
            do {
                JLog.notice(
                    "Advertising OCR worker API at \(configuration.advertisedURL.absoluteString) through Bonjour"
                )
                let result = try await executor.execute(configuration.publicationRequest)
                guard !Task.isCancelled else { return }
                let diagnostic = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = "Bonjour publication stopped with status \(result.exitStatus)"
                    + (diagnostic.isEmpty ? "" : ": \(diagnostic)")
                JLog.warning("\(message)")
            } catch is CancellationError {
                return
            } catch {
                JLog.warning("Bonjour publication failed: \(error.localizedDescription)")
            }
        }
    }

    public func stop() async {
        let task = publicationTask
        publicationTask = nil
        task?.cancel()
        await task?.value
    }
}
