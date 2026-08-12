import Foundation
@testable import ScannerServerCore
import Testing

@Suite("OCR queue configuration")
struct OCRQueueConfigurationTests {
    @Test("CPU limit reserves one detected processor for acquisition and HTTP")
    func automaticCPUCount() {
        let configuration = OCRQueueConfiguration(
            environment: [:],
            detectedProcessorCount: 10
        )

        #expect(configuration.cpuLimit == 9)
        #expect(configuration.niceLevel == nil)
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
        ).cpuLimit == 9)
        #expect(OCRQueueConfiguration(
            environment: [:],
            detectedProcessorCount: 1
        ).cpuLimit == 1)
    }

    @Test("Nice mode can be disabled or assigned a safe positive level")
    func niceConfiguration() {
        #expect(OCRQueueConfiguration(
            environment: ["SCAN_OCR_NICE": "true"],
            detectedProcessorCount: 10
        ).niceLevel == 10)
        #expect(OCRQueueConfiguration(
            environment: ["SCAN_OCR_NICE": "false"],
            detectedProcessorCount: 10
        ).niceLevel == nil)
        #expect(OCRQueueConfiguration(
            environment: ["SCAN_OCR_NICE": "true", "SCAN_OCR_NICE_LEVEL": "15"],
            detectedProcessorCount: 10
        ).niceLevel == 15)
        #expect(OCRQueueConfiguration(
            environment: ["SCAN_OCR_NICE": "true", "SCAN_OCR_NICE_LEVEL": "99"],
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
