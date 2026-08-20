import Foundation

package protocol OCRExecuting: Sendable {
    func execute(_ request: OCRExecutionRequest) async throws -> OCRExecutionResult
}

package enum OCRDispatchPreference: Equatable, Sendable {
    case remoteFirst
    case reservedInternal
}

package struct OCRProcessingOptions: Equatable, Sendable {
    package let languages: [String]
    package let jobs: Int
    package let rotatePages: Bool
    package let rotatePagesThreshold: String
    package let deskew: Bool
    package let optimizationLevel: Int

    package init(
        languages: [String],
        jobs: Int,
        rotatePages: Bool = true,
        rotatePagesThreshold: String = "2.0",
        deskew: Bool = true,
        optimizationLevel: Int = 1
    ) {
        self.languages = languages.isEmpty ? ["eng"] : languages
        self.jobs = max(1, jobs)
        self.rotatePages = rotatePages
        self.rotatePagesThreshold = rotatePagesThreshold
        self.deskew = deskew
        self.optimizationLevel = optimizationLevel
    }

    package init(environment: [String: String]?, jobs: Int) {
        let language = environment?["SCAN_LANGUAGE"] ?? "deu+eng"
        self.init(
            languages: language.split(separator: "+").map(String.init),
            jobs: jobs,
            rotatePagesThreshold: environment?["SCAN_OCR_ROTATE_PAGES_THRESHOLD"] ?? "2.0"
        )
    }
}

package struct OCRProcessContext: Equatable, Sendable {
    package let environment: [String: String]?
    package let workingDirectory: URL?
    package let niceLevel: Int?

    package init(
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        niceLevel: Int? = nil
    ) {
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.niceLevel = niceLevel.map { min(max($0, 1), 19) }
    }
}

package struct OCRExecutionRequest: Equatable, Sendable {
    package let inputURL: URL
    package let outputURL: URL
    package let options: OCRProcessingOptions
    package let context: OCRProcessContext
    package let metadata: OCRWorkerJobMetadata?
    package let cropConfiguration: OCRWorkerCropConfiguration?
    package let blankPageConfiguration: OCRWorkerBlankPageConfiguration?
    package let dispatchPreference: OCRDispatchPreference

    package init(
        inputURL: URL,
        outputURL: URL,
        options: OCRProcessingOptions,
        context: OCRProcessContext = OCRProcessContext(),
        metadata: OCRWorkerJobMetadata? = nil,
        cropConfiguration: OCRWorkerCropConfiguration? = nil,
        blankPageConfiguration: OCRWorkerBlankPageConfiguration? = nil,
        dispatchPreference: OCRDispatchPreference = .remoteFirst
    ) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.options = options
        self.context = context
        self.metadata = metadata
        self.cropConfiguration = cropConfiguration
        self.blankPageConfiguration = blankPageConfiguration
        self.dispatchPreference = dispatchPreference
    }

    package var requiredWorkerCapabilities: [String] {
        var capabilities: [String] = []
        if cropConfiguration != nil { capabilities.append(OCRWorkerCapability.cropPDFPages) }
        if blankPageConfiguration != nil {
            capabilities.append(OCRWorkerCapability.removeBlankPDFPages)
        }
        return capabilities
    }
}

package enum OCRExecutionOutcome: Equatable, Sendable {
    case succeeded
    case failed(exitStatus: Int32)

    package var exitStatus: Int32 {
        switch self {
        case .succeeded: 0
        case .failed(let exitStatus): exitStatus
        }
    }
}

package enum OCRExecutionLocation: String, Equatable, Sendable {
    case local
    case remote
}

package struct OCRExecutionResult: Equatable, Sendable {
    package let outcome: OCRExecutionOutcome
    package let standardOutput: String
    package let standardError: String
    package let location: OCRExecutionLocation

    package init(
        outcome: OCRExecutionOutcome,
        standardOutput: String = "",
        standardError: String = "",
        location: OCRExecutionLocation
    ) {
        self.outcome = outcome
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.location = location
    }

    package var succeeded: Bool { outcome == .succeeded }
    package var exitStatus: Int32 { outcome.exitStatus }
}

package enum OCRmyPDFCommandBuilder {
    package static func arguments(
        options: OCRProcessingOptions,
        inputPath: String,
        outputPath: String
    ) -> [String] {
        var arguments = ["--language", options.languages.joined(separator: "+")]
        if options.rotatePages {
            arguments += ["--rotate-pages", "--rotate-pages-threshold", options.rotatePagesThreshold]
        }
        if options.deskew { arguments.append("--deskew") }
        arguments += ["--optimize", String(options.optimizationLevel)]
        arguments += ["--jobs", String(options.jobs)]
        arguments += [inputPath, outputPath]
        return arguments
    }
}

package struct LocalOCRProcessAdapter: OCRExecuting, Sendable {
    private let processExecutor: any ProcessExecutor
    private let documentExecutor: any ProcessExecutor

    package init(
        processExecutor: any ProcessExecutor,
        documentExecutor: (any ProcessExecutor)? = nil
    ) {
        self.processExecutor = processExecutor
        self.documentExecutor = documentExecutor
            ?? NativeDocumentToolExecutor(executor: processExecutor)
    }

    package func execute(_ request: OCRExecutionRequest) async throws -> OCRExecutionResult {
        let processResult = try await processExecutor.execute(processRequest(for: request))
        guard processResult.succeeded else { return result(processResult) }
        let postProcessor: any ProcessExecutor = if let niceLevel = request.context.niceLevel {
            NiceProcessExecutor(executor: documentExecutor, niceLevel: niceLevel)
        } else {
            documentExecutor
        }

        if let cropConfiguration = request.cropConfiguration {
            try Task.checkCancellation()
            let cropResult = try await postProcessor.execute(
                cropConfiguration.request(pdfPath: request.outputURL.path).command.processRequest(
                    environment: request.context.environment,
                    workingDirectory: request.context.workingDirectory
                )
            )
            guard cropResult.succeeded else { return result(cropResult) }
        }

        if let blankPageConfiguration = request.blankPageConfiguration {
            try Task.checkCancellation()
            let blankResult = try await postProcessor.execute(
                blankPageConfiguration.request(pdfPath: request.outputURL.path).command.processRequest(
                    environment: request.context.environment,
                    workingDirectory: request.context.workingDirectory
                )
            )
            guard blankResult.succeeded else { return result(blankResult) }
        }
        return result(processResult)
    }

    package func processRequest(for request: OCRExecutionRequest) -> ProcessRequest {
        ProcessRequest(
            executable: "ocrmypdf",
            arguments: OCRmyPDFCommandBuilder.arguments(
                options: request.options,
                inputPath: request.inputURL.path,
                outputPath: request.outputURL.path
            ),
            environment: request.context.environment,
            workingDirectory: request.context.workingDirectory,
            niceLevel: request.context.niceLevel
        )
    }

    private func result(_ processResult: ProcessResult) -> OCRExecutionResult {
        OCRExecutionResult(
            outcome: processResult.succeeded
                ? .succeeded
                : .failed(exitStatus: processResult.exitStatus),
            standardOutput: processResult.standardOutput,
            standardError: processResult.standardError,
            location: .local
        )
    }
}
