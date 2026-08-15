import ScannerServerCore
import Testing

@Suite("OCR worker capacity")
struct OCRWorkerCapacityTests {
    @Test("CPU count becomes one concurrent one-CPU page per processor")
    func cpuDerivedCapacity() {
        let capacity = OCRWorkerCapacity(cpuCount: 11)

        #expect(capacity.cpuCount == 11)
        #expect(capacity.maximumConcurrentJobs == 11)
        #expect(capacity.cpuLimitPerJob == 1)
    }

    @Test("An optional concurrency cap leaves per-page CPU use unchanged")
    func safetyCap() {
        let capacity = OCRWorkerCapacity(cpuCount: 11, maximumConcurrentJobs: 4)

        #expect(capacity.cpuCount == 11)
        #expect(capacity.maximumConcurrentJobs == 4)
        #expect(capacity.cpuLimitPerJob == 1)
    }
}
