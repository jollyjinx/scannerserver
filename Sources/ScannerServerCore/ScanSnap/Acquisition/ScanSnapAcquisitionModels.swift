import Foundation

public struct ScanSnapWiFiAcquisitionRequest: Sendable, Hashable {
    public let scannerIPAddress: String
    public let identity: ScanSnapIdentity
    public let clientIPAddress: String?
    public let clientMACAddress: [UInt8]?
    public let clientInterface: String
    public let simplex: Bool
    public let reusesArmedSession: Bool
    public let debug: Bool
    public let outputURL: URL
    public let registrationSourcePort: UInt16
    public let registrationPort: UInt16

    public init(
        scannerIPAddress: String,
        identity: ScanSnapIdentity,
        clientIPAddress: String? = nil,
        clientMACAddress: [UInt8]? = nil,
        clientInterface: String = "eth0",
        simplex: Bool,
        reusesArmedSession: Bool,
        debug: Bool,
        outputURL: URL,
        registrationSourcePort: UInt16 = ScanSnapPacketBuilder.registrationSourcePort,
        registrationPort: UInt16 = ScanSnapPacketBuilder.registrationPort
    ) {
        self.scannerIPAddress = scannerIPAddress
        self.identity = identity
        self.clientIPAddress = clientIPAddress
        self.clientMACAddress = clientMACAddress
        self.clientInterface = clientInterface
        self.simplex = simplex
        self.reusesArmedSession = reusesArmedSession
        self.debug = debug
        self.outputURL = outputURL
        self.registrationSourcePort = registrationSourcePort
        self.registrationPort = registrationPort
    }
}

public struct ScanSnapWiFiAcquisitionResult: Sendable, Hashable {
    public let pageCount: Int
    public let diagnostics: String

    public init(pageCount: Int, diagnostics: String = "") {
        self.pageCount = pageCount
        self.diagnostics = diagnostics
    }
}

public protocol ScanSnapWiFiAcquiring: Sendable {
    func acquire(_ request: ScanSnapWiFiAcquisitionRequest) async throws -> ScanSnapWiFiAcquisitionResult
}

public enum ScanSnapAcquisitionError: Error, Sendable, Equatable, LocalizedError {
    case noDocument
    case noPages
    case scannerRejected(status: Int32)
    case invalidVENSResponse
    case invalidJPEG
    case imageTooLarge(maximumBytes: Int)
    case tooManyPages
    case couldNotWritePDF(String)

    public var errorDescription: String? {
        switch self {
        case .noDocument:
            "No document in scanner."
        case .noPages:
            "No pages were scanned."
        case let .scannerRejected(status):
            "Scanner rejected acquisition with status \(status)."
        case .invalidVENSResponse:
            "Scanner returned an invalid VENS response."
        case .invalidJPEG:
            "Scanner returned invalid JPEG image data."
        case let .imageTooLarge(maximumBytes):
            "Scanner image exceeded the \(maximumBytes)-byte safety limit."
        case .tooManyPages:
            "Scanner transfer exceeded the 256-side protocol batch limit."
        case let .couldNotWritePDF(message):
            "Could not write scanned PDF: \(message)"
        }
    }
}
