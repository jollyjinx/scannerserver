@testable import ScannerServerCore
import Testing

@Suite("iX500 Wi-Fi capabilities")
struct ScanSnapWiFiCapabilitiesTests {
    @Test("Capabilities describe the existing acquisition path without claiming USB features")
    func existingBackend() {
        let capabilities = ScanSnapWiFiCapabilities.ix500
        #expect(capabilities.modelName == "ScanSnap iX500")
        #expect(capabilities.resolutionDPI == 300)
        #expect(capabilities.colorMode == .rgb)
        #expect(capabilities.imageFormat == .jpeg)
        #expect(capabilities.simplexHandling == .discardBackSides)
        #expect(!capabilities.supportsResolutionSelection)
        #expect(!capabilities.supportsColorModeSelection)
        #expect(capabilities.supportsPhysicalButton)
    }
}
