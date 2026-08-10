import Foundation
@testable import ScannerServerCore
import Testing

@Suite("OCR queue configuration")
struct OCRQueueConfigurationTests {
    @Test("CPU limit defaults to the detected container allowance")
    func automaticCPUCount() {
        let configuration = OCRQueueConfiguration(
            environment: [:],
            detectedProcessorCount: 10
        )

        #expect(configuration.cpuLimit == 10)
        #expect(configuration.niceLevel == 10)
    }

    @Test("Configured CPU limit can lower but not exceed the detected allowance")
    func configuredCPUCap() {
        #expect(OCRQueueConfiguration(
            environment: ["SCAN_OCR_CPU_LIMIT": "4"],
            detectedProcessorCount: 10
        ).cpuLimit == 4)
        #expect(OCRQueueConfiguration(
            environment: ["SCAN_OCR_CPU_LIMIT": "20"],
            detectedProcessorCount: 10
        ).cpuLimit == 10)
    }

    @Test("Nice mode can be disabled or assigned a safe positive level")
    func niceConfiguration() {
        #expect(OCRQueueConfiguration(
            environment: ["SCAN_OCR_NICE": "false"],
            detectedProcessorCount: 10
        ).niceLevel == nil)
        #expect(OCRQueueConfiguration(
            environment: ["SCAN_OCR_NICE_LEVEL": "15"],
            detectedProcessorCount: 10
        ).niceLevel == 15)
        #expect(OCRQueueConfiguration(
            environment: ["SCAN_OCR_NICE_LEVEL": "99"],
            detectedProcessorCount: 10
        ).niceLevel == 19)
    }

    @Test("Cgroup CPU quota and cpuset formats are parsed conservatively")
    func cgroupParsing() {
        #expect(OCRSystemProcessorCount.quotaLimit(cpuMax: "1000000 100000\n") == 10)
        #expect(OCRSystemProcessorCount.quotaLimit(cpuMax: "max 100000\n") == nil)
        #expect(OCRSystemProcessorCount.quotaLimit(quota: "50000", period: "100000") == 1)
        #expect(OCRSystemProcessorCount.cpusetLimit("0-3,8,10-11\n") == 7)
    }
}
