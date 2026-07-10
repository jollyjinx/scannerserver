import Foundation

public struct ScanSnapDevice: Sendable, Hashable {
    public let ipAddress: String
    public let macAddress: String
    public let serialNumber: String
    public let name: String
    public let dataPort: UInt16
    public let controlPort: UInt16
    public let state: UInt32
    public let clientIPAddress: String?
    public let metadata: [UInt8]

    public var id: String { "\(macAddress)@\(ipAddress)" }

    public init(
        ipAddress: String,
        macAddress: String,
        serialNumber: String,
        name: String,
        dataPort: UInt16,
        controlPort: UInt16,
        state: UInt32,
        clientIPAddress: String?,
        metadata: [UInt8]
    ) {
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.serialNumber = serialNumber
        self.name = name
        self.dataPort = dataPort
        self.controlPort = controlPort
        self.state = state
        self.clientIPAddress = clientIPAddress
        self.metadata = metadata
    }
}

public enum ScanSnapProtocolError: Error, Sendable, Equatable {
    case packetTooShort(minimum: Int, actual: Int)
    case invalidSignature(expected: [UInt8], actual: [UInt8])
    case invalidByteCount(field: String, expected: Int, actual: Int)
    case invalidIPv4Address(String)
    case passwordTooLong(maximumCharacters: Int, actualCharacters: Int)
    case shortPairingResponse(actual: Int)
}

public struct ScanSnapIdentity: Sendable, Hashable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public static func derive(fromPassword password: String) throws -> ScanSnapIdentity {
        let passwordScalars = Array(password.unicodeScalars)
        let keyScalars = Array("pFusCANsNapFiPfu".unicodeScalars)
        guard passwordScalars.count <= keyScalars.count else {
            throw ScanSnapProtocolError.passwordTooLong(
                maximumCharacters: keyScalars.count,
                actualCharacters: passwordScalars.count
            )
        }

        let value = zip(passwordScalars, keyScalars)
            .map { String($0.value + $1.value + 11) }
            .joined()
        return ScanSnapIdentity(value)
    }

    var asciiBytes: [UInt8] {
        value.unicodeScalars.compactMap { scalar in
            scalar.value < 0x80 ? UInt8(scalar.value) : nil
        }
    }
}

public struct ScanSnapCredentials: Sendable, Hashable {
    public let password: String?
    public let identity: ScanSnapIdentity

    public init(identity: ScanSnapIdentity) {
        self.password = nil
        self.identity = identity
    }

    public init(password: String) throws {
        self.password = password
        self.identity = try ScanSnapIdentity.derive(fromPassword: password)
    }

    public static func factoryDefault(serialNumber: String) throws -> ScanSnapCredentials {
        var serial = serialNumber
        while serial.last == " " || serial.last == "\0" {
            serial.removeLast()
        }
        let password = String(serial.suffix(4))
        return try ScanSnapCredentials(password: password)
    }
}

public enum ScanSnapPairingStatus: Sendable, Hashable {
    case accepted
    case badPacket
    case serialMismatch
    case passwordRejected
    case sessionBusy
    case missingSerialData
    case pairedToDifferentClientIP
    case rejected(Int32)

    public init(code: Int32) {
        self = switch code {
        case 0: .accepted
        case -1: .badPacket
        case -2: .serialMismatch
        case -3: .passwordRejected
        case -4: .sessionBusy
        case -5: .missingSerialData
        case -7: .pairedToDifferentClientIP
        default: .rejected(code)
        }
    }

    public var code: Int32 {
        switch self {
        case .accepted: 0
        case .badPacket: -1
        case .serialMismatch: -2
        case .passwordRejected: -3
        case .sessionBusy: -4
        case .missingSerialData: -5
        case .pairedToDifferentClientIP: -7
        case let .rejected(code): code
        }
    }

    public static func parse(response: [UInt8]) throws -> ScanSnapPairingStatus {
        guard response.count >= 12 else {
            throw ScanSnapProtocolError.shortPairingResponse(actual: response.count)
        }
        let raw = try ScanSnapByteCodec.readUInt32(from: response, at: 8)
        return ScanSnapPairingStatus(code: Int32(bitPattern: raw))
    }
}

public struct ScanSnapSessionRetryPolicy: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        case stop
        case keepSession
        case releaseSession
        case releaseThenRetry(afterMilliseconds: UInt64)
        case releaseThenStop(afterMilliseconds: UInt64)
    }

    public let maximumAttempts: Int
    public let busyRetryDelayMilliseconds: UInt64
    public let releaseAfterAcceptance: Bool
    public let releaseAfterExhaustedBusy: Bool

    public static let pairingTest = ScanSnapSessionRetryPolicy(
        maximumAttempts: 4,
        busyRetryDelayMilliseconds: 1_000,
        releaseAfterAcceptance: true,
        releaseAfterExhaustedBusy: true
    )

    public static let buttonArming = ScanSnapSessionRetryPolicy(
        maximumAttempts: 9,
        busyRetryDelayMilliseconds: 1_000,
        releaseAfterAcceptance: false,
        releaseAfterExhaustedBusy: false
    )

    public init(
        maximumAttempts: Int,
        busyRetryDelayMilliseconds: UInt64,
        releaseAfterAcceptance: Bool,
        releaseAfterExhaustedBusy: Bool
    ) {
        precondition(maximumAttempts > 0)
        self.maximumAttempts = maximumAttempts
        self.busyRetryDelayMilliseconds = busyRetryDelayMilliseconds
        self.releaseAfterAcceptance = releaseAfterAcceptance
        self.releaseAfterExhaustedBusy = releaseAfterExhaustedBusy
    }

    public func action(after status: ScanSnapPairingStatus, attemptsMade: Int) -> Action {
        switch status {
        case .accepted:
            releaseAfterAcceptance ? .releaseSession : .keepSession
        case .sessionBusy where attemptsMade < maximumAttempts:
            .releaseThenRetry(afterMilliseconds: busyRetryDelayMilliseconds)
        case .sessionBusy where releaseAfterExhaustedBusy:
            .releaseThenStop(afterMilliseconds: busyRetryDelayMilliseconds)
        default:
            .stop
        }
    }
}
