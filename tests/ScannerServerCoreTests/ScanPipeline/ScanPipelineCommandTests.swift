import Foundation
import ScannerServerCore
import Testing

@Suite("Scan pipeline commands")
struct ScanPipelineCommandTests {
    @Test("Commands use the installed script entry points")
    func commandConstruction() {
        let directory = URL(fileURLWithPath: "/tmp/work", isDirectory: true)
        let configuration = ScanPipelineConfiguration(
            environment: ["PATH": "/usr/local/bin", "SCAN_LANGUAGE": "nld"]
        )

        let scan = ScanPipelineCommands.scan(configuration: configuration, workingDirectory: directory)
        #expect(scan.executable == "scan-once")
        #expect(scan.arguments.isEmpty)
        #expect(scan.environment?["SCAN_LANGUAGE"] == "nld")
        #expect(scan.environment?["PATH"] == "/usr/local/bin")
        #expect(scan.workingDirectory == directory)

        let ocr = ScanPipelineCommands.ocr(
            inputPath: "/scans/input.pdf",
            environment: configuration.environment
        )
        #expect(ocr.executable == "ocr-scan")
        #expect(ocr.arguments == ["/scans/input.pdf"])
        #expect(ocr.environment?["SCAN_LANGUAGE"] == "nld")

        let list = ScanPipelineCommands.listScanners(environment: ["PATH": "/sbin"])
        #expect(list.executable == "list-scanners")
        #expect(list.arguments.isEmpty)
        #expect(list.environment == ["PATH": "/sbin"])
    }
}
