import Foundation

public enum OCRWorkerProtocol {
    public static let currentVersion = 1
}

public struct OCRWorkerRegistrationRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let workerID: String
    public let authenticationToken: String
    public let displayName: String
    public let hostname: String
    public let workerVersion: String
    public let architecture: String
    public let cpuCount: Int
    public let maxConcurrentJobs: Int
    public let ocrLanguages: [String]

    public init(
        protocolVersion: Int = OCRWorkerProtocol.currentVersion,
        workerID: String,
        authenticationToken: String,
        displayName: String,
        hostname: String,
        workerVersion: String,
        architecture: String,
        cpuCount: Int,
        maxConcurrentJobs: Int,
        ocrLanguages: [String]
    ) {
        self.protocolVersion = protocolVersion
        self.workerID = workerID
        self.authenticationToken = authenticationToken
        self.displayName = displayName
        self.hostname = hostname
        self.workerVersion = workerVersion
        self.architecture = architecture
        self.cpuCount = cpuCount
        self.maxConcurrentJobs = maxConcurrentJobs
        self.ocrLanguages = ocrLanguages
    }
}

public struct OCRWorkerHeartbeatRequest: Codable, Equatable, Sendable {
    public let authenticationToken: String
    public let runningJobs: Int

    public init(authenticationToken: String, runningJobs: Int) {
        self.authenticationToken = authenticationToken
        self.runningJobs = runningJobs
    }
}

public enum OCRWorkerAvailability: String, Codable, Equatable, Sendable {
    case pendingApproval = "pending-approval"
    case online
    case busy
    case paused
    case offline
    case disabled
}

public struct OCRWorkerRegistrationResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let workerID: String
    public let availability: OCRWorkerAvailability
    public let heartbeatIntervalSeconds: Int

    public init(
        protocolVersion: Int = OCRWorkerProtocol.currentVersion,
        workerID: String,
        availability: OCRWorkerAvailability,
        heartbeatIntervalSeconds: Int
    ) {
        self.protocolVersion = protocolVersion
        self.workerID = workerID
        self.availability = availability
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
    }
}

public struct OCRWorkerSnapshot: Codable, Equatable, Sendable {
    public let workerID: String
    public let displayName: String
    public let hostname: String
    public let workerVersion: String
    public let architecture: String
    public let cpuCount: Int
    public let maxConcurrentJobs: Int
    public let runningJobs: Int
    public let ocrLanguages: [String]
    public let approved: Bool
    public let enabled: Bool
    public let paused: Bool
    public let availability: OCRWorkerAvailability
    public let registeredAt: Date
    public let lastSeen: Date
}

public enum OCRWorkerRegistryError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedProtocolVersion(Int)
    case invalidWorkerID
    case invalidAuthenticationToken
    case invalidCapacity
    case authenticationFailed
    case unknownWorker
    case approvalRequired
    case workerDisabled
    case workerPaused
    case workerOffline
    case workerAtCapacity

    public var errorDescription: String? {
        switch self {
        case .unsupportedProtocolVersion(let version):
            "Unsupported OCR worker protocol version: \(version)"
        case .invalidWorkerID:
            "Worker ID must contain only letters, numbers, periods, underscores, or hyphens."
        case .invalidAuthenticationToken:
            "Worker authentication token is invalid."
        case .invalidCapacity:
            "Worker CPU and concurrent-job capacity must be positive."
        case .authenticationFailed:
            "OCR worker authentication failed."
        case .unknownWorker:
            "OCR worker is not registered."
        case .approvalRequired:
            "OCR worker is waiting for approval."
        case .workerDisabled:
            "OCR worker is disabled."
        case .workerPaused:
            "OCR worker is paused."
        case .workerOffline:
            "OCR worker heartbeat is stale."
        case .workerAtCapacity:
            "OCR worker is already at its configured job capacity."
        }
    }
}
