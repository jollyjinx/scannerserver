import ScannerServerCore
import Testing

@Suite("OCR worker Bonjour metadata")
struct OCRWorkerBonjourTests {
    @Test("Compatible HTTP and HTTPS service records resolve", arguments: [
        "http://scannerserver.local:8080",
        "https://scanner.example.test",
    ])
    func compatibleURL(value: String) {
        #expect(OCRWorkerBonjourService.serverURL(fromTXTRecord: [
            "api": String(OCRWorkerProtocol.currentVersion),
            "url": value,
        ])?.absoluteString == value)
    }

    @Test("Incompatible and unsafe service records are ignored", arguments: [
        ["url": "http://scannerserver.local:8080"],
        ["api": "999", "url": "http://scannerserver.local:8080"],
        ["api": "1", "url": "ftp://scannerserver.local/file"],
        ["api": "1", "url": "http://user:password@scannerserver.local:8080"],
        ["api": "1", "url": "not a URL"],
    ])
    func ignored(values: [String: String]) {
        #expect(OCRWorkerBonjourService.serverURL(fromTXTRecord: values) == nil)
    }
}
