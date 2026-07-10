import ScannerServerCore
import Testing

@Test("The public product name matches the drop-in executable")
func productName() {
    #expect(ScannerServerCore.productName == "scannerserver")
}
