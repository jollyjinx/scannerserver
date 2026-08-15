import Foundation

public enum OCRWorkerJobStatus: String, Codable, Equatable, Sendable {
    case queued
    case leased
    case succeeded
    case failed
    case cancelled
}

public struct OCRWorkerJobMetadata: Codable, Equatable, Sendable {
    public let documentName: String
    public let batchID: String?
    public let pageNumber: Int?
    public let operations: [String]

    public init(
        documentName: String,
        batchID: String? = nil,
        pageNumber: Int? = nil,
        operations: [String] = []
    ) {
        self.documentName = documentName
        self.batchID = batchID
        self.pageNumber = pageNumber
        self.operations = operations
    }
}

public struct OCRWorkerJobManifest: Codable, Equatable, Sendable {
    public let jobID: String
    public let sourcePath: String
    public let outputPath: String
    public let sourceByteCount: Int64
    public let sourceSHA256: String
    public let ocrLanguages: [String]
    public let ocrEnabled: Bool
    public let removeBlankPages: Bool
    public let cropPages: Bool
    public let containerArguments: [String]?
    public let metadata: OCRWorkerJobMetadata?
    public let createdAt: Date

    public init(
        jobID: String = UUID().uuidString.lowercased(),
        sourcePath: String,
        outputPath: String,
        sourceByteCount: Int64,
        sourceSHA256: String,
        ocrLanguages: [String],
        ocrEnabled: Bool,
        removeBlankPages: Bool,
        cropPages: Bool,
        containerArguments: [String]? = nil,
        metadata: OCRWorkerJobMetadata? = nil,
        createdAt: Date = Date()
    ) {
        self.jobID = jobID
        self.sourcePath = sourcePath
        self.outputPath = outputPath
        self.sourceByteCount = sourceByteCount
        self.sourceSHA256 = sourceSHA256
        self.ocrLanguages = ocrLanguages
        self.ocrEnabled = ocrEnabled
        self.removeBlankPages = removeBlankPages
        self.cropPages = cropPages
        self.containerArguments = containerArguments
        self.metadata = metadata
        self.createdAt = createdAt
    }
}

public struct OCRWorkerJobResult: Codable, Equatable, Sendable {
    public let outputByteCount: Int64
    public let outputSHA256: String

    public init(outputByteCount: Int64, outputSHA256: String) {
        self.outputByteCount = outputByteCount
        self.outputSHA256 = outputSHA256
    }
}

public struct OCRWorkerJobLease: Codable, Equatable, Sendable {
    public let manifest: OCRWorkerJobManifest
    public let workerID: String
    public let leaseToken: String
    public let leasedAt: Date
    public let expiresAt: Date
    public let attempt: Int

    public init(
        manifest: OCRWorkerJobManifest,
        workerID: String,
        leaseToken: String,
        leasedAt: Date,
        expiresAt: Date,
        attempt: Int
    ) {
        self.manifest = manifest
        self.workerID = workerID
        self.leaseToken = leaseToken
        self.leasedAt = leasedAt
        self.expiresAt = expiresAt
        self.attempt = attempt
    }
}

public struct OCRWorkerJobPollRequest: Codable, Equatable, Sendable {
    public let authenticationToken: String
    public let waitSeconds: Int

    public init(authenticationToken: String, waitSeconds: Int = 20) {
        self.authenticationToken = authenticationToken
        self.waitSeconds = waitSeconds
    }
}

public struct OCRWorkerJobLeaseRequest: Codable, Equatable, Sendable {
    public let authenticationToken: String
    public let leaseToken: String

    public init(authenticationToken: String, leaseToken: String) {
        self.authenticationToken = authenticationToken
        self.leaseToken = leaseToken
    }
}

public struct OCRWorkerJobFailureRequest: Codable, Equatable, Sendable {
    public let authenticationToken: String
    public let leaseToken: String
    public let failure: String

    public init(authenticationToken: String, leaseToken: String, failure: String) {
        self.authenticationToken = authenticationToken
        self.leaseToken = leaseToken
        self.failure = failure
    }
}

public struct OCRWorkerJobSnapshot: Codable, Equatable, Sendable {
    public let manifest: OCRWorkerJobManifest
    public let status: OCRWorkerJobStatus
    public let attemptCount: Int
    public let leasedWorkerID: String?
    public let leasedAt: Date?
    public let leaseExpiresAt: Date?
    public let result: OCRWorkerJobResult?
    public let failure: String?
    public let updatedAt: Date
}

public enum OCRWorkerJobStoreError: Error, Equatable, LocalizedError, Sendable {
    case duplicateJob(String)
    case invalidManifest
    case invalidResult
    case unknownJob(String)
    case invalidLease
    case leaseExpired
    case invalidTransition(from: OCRWorkerJobStatus, to: OCRWorkerJobStatus)

    public var errorDescription: String? {
        switch self {
        case .duplicateJob(let jobID):
            "OCR worker job already exists: \(jobID)"
        case .invalidManifest:
            "OCR worker job manifest is invalid."
        case .invalidResult:
            "OCR worker job result is invalid."
        case .unknownJob(let jobID):
            "OCR worker job does not exist: \(jobID)"
        case .invalidLease:
            "OCR worker job lease authentication failed."
        case .leaseExpired:
            "OCR worker job lease has expired."
        case .invalidTransition(let from, let to):
            "OCR worker job cannot transition from \(from.rawValue) to \(to.rawValue)."
        }
    }
}
