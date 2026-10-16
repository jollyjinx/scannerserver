/// Describes the implemented backend, rather than every feature of the physical scanner.
/// This metadata does not select commands or change acquisition/session behavior.
struct ScanSnapWiFiCapabilities: Equatable, Sendable {
    enum ColorMode: String, Sendable {
        case rgb = "RGB color"
    }

    enum ImageFormat: String, Sendable {
        case jpeg = "JPEG"
    }

    enum SimplexHandling: Equatable, Sendable {
        /// The scanner still transfers both sides; acquisition discards the backs.
        case discardBackSides
    }

    static let ix500 = Self()

    let modelName = "ScanSnap iX500"
    let resolutionDPI = 300
    let colorMode = ColorMode.rgb
    let imageFormat = ImageFormat.jpeg
    let simplexHandling = SimplexHandling.discardBackSides
    let supportsResolutionSelection = false
    let supportsColorModeSelection = false
    let supportsPhysicalButton = true

    private init() {}

    var acquisitionSummary: String {
        "\(resolutionDPI) dpi \(colorMode.rawValue)"
    }

    var acquisitionDescription: String {
        "The \(modelName) Wi-Fi backend captures \(acquisitionSummary) pages. "
            + "Resolution and color selections below apply to the SANE backend."
    }

    var sidesDescription: String {
        "Duplex keeps both sides; simplex keeps only the front pages."
    }
}
