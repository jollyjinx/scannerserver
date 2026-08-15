import ScannerServerCore
import Testing

@Suite("Local OCR capacity pool")
struct OCRLocalCapacityPoolTests {
    @Test("Weighted permits never exceed the scanner host CPU budget")
    func weightedPermits() async {
        let pool = OCRLocalCapacityPool(capacity: 3)

        #expect(await pool.tryAcquire(2) == 2)
        #expect(await pool.tryAcquire(2) == nil)
        #expect(await pool.tryAcquire(1) == 1)
        #expect(await pool.availableCPUs == 0)

        await pool.release(2)
        #expect(await pool.tryAcquire(2) == 2)
        #expect(await pool.availableCPUs == 0)
    }
}
