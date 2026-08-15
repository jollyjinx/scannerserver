import ScannerServerCore
import Testing

@Suite("OCR worker Bonjour publisher")
struct OCRWorkerBonjourPublisherTests {
    @Test("Publication is opt-in and advertises the worker API version and URL")
    func publicationRequest() throws {
        let service = try ScannerServerServiceConfiguration(hostname: "0.0.0.0", port: 8080)
        let disabled = OCRWorkerBonjourPublisherConfiguration(
            environment: [:],
            serviceConfiguration: service
        )
        #expect(disabled.enabled == false)

        let enabled = OCRWorkerBonjourPublisherConfiguration(
            environment: [
                "SCAN_OCR_WORKER_BONJOUR_ENABLED": "true",
                "SCANNERSERVER_BONJOUR_NAME": "Office Scanner",
                "SCANNERSERVER_BONJOUR_URL": "http://scanner.local:8080",
            ],
            serviceConfiguration: service
        )

        #expect(enabled.enabled == true)
        #expect(enabled.publicationRequest.executable == "avahi-publish-service")
        #expect(enabled.publicationRequest.arguments == [
            "--no-fail",
            "Office Scanner",
            "_scannerserver._tcp",
            "8080",
            "api=1",
            "url=http://scanner.local:8080",
        ])
    }

    @Test("Host overrides derive an HTTP advertisement when no URL is supplied")
    func derivedURL() throws {
        let service = try ScannerServerServiceConfiguration(hostname: "0.0.0.0", port: 80)
        let configuration = OCRWorkerBonjourPublisherConfiguration(
            environment: ["SCANNERSERVER_BONJOUR_HOST": "scanner.local"],
            serviceConfiguration: service
        )

        #expect(configuration.advertisedURL.absoluteString == "http://scanner.local:80")
    }
}
