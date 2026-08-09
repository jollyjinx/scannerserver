import Foundation

public protocol NativeScanExecuting: Sendable {
    func scan(configuration: ScanPipelineConfiguration) async throws -> ProcessResult
}

public actor NativeScanPipeline: NativeScanExecuting {
    public typealias TimestampProvider = @Sendable () -> ScanTimestamp
    public typealias WorkDirectorySuffixProvider = @Sendable () -> String

    private let executor: any ProcessExecutor
    private let fileSystem: any NativeScanFileSystem
    private let timestampProvider: TimestampProvider
    private let workDirectorySuffixProvider: WorkDirectorySuffixProvider

    public init(
        executor: any ProcessExecutor,
        fileSystem: any NativeScanFileSystem = FoundationNativeScanFileSystem(),
        timestampProvider: @escaping TimestampProvider = { ScanTimestamp(date: Date()) },
        workDirectorySuffixProvider: @escaping WorkDirectorySuffixProvider = { UUID().uuidString }
    ) {
        self.executor = executor
        self.fileSystem = fileSystem
        self.timestampProvider = timestampProvider
        self.workDirectorySuffixProvider = workDirectorySuffixProvider
    }

    public func scan(configuration: ScanPipelineConfiguration) async throws -> ProcessResult {
        let environment = configuration.environment
        let outputDirectory = URL(
            fileURLWithPath: nonEmpty(environment["SCAN_OUTPUT_DIR"]) ?? "/scans",
            isDirectory: true
        ).standardizedFileURL

        do {
            try fileSystem.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            return failure(status: 1, message: "Could not create scan output directory: \(error.localizedDescription)")
        }

        let suffix = workDirectorySuffixProvider()
        guard isValidPathComponent(suffix) else {
            return failure(status: 64, message: "Invalid native scan work-directory suffix.")
        }
        let workDirectory = outputDirectory.appendingPathComponent(
            ".scan-work.\(suffix)",
            isDirectory: true
        )

        do {
            try fileSystem.createDirectory(at: workDirectory, withIntermediateDirectories: false)
        } catch {
            return failure(status: 1, message: "Could not create scan work directory: \(error.localizedDescription)")
        }
        defer { try? fileSystem.removeItemIfPresent(at: workDirectory) }

        let capturingExecutor = NativeScanCapturingExecutor(executor: executor)
        do {
            let timestamp = try scanTimestamp(environment: environment)
            let rawPDF = workDirectory.appendingPathComponent("raw.pdf", isDirectory: false)

            if let acquisitionFailure = try await acquireRawPDF(
                configuration: configuration,
                rawPDF: rawPDF,
                workDirectory: workDirectory,
                executor: capturingExecutor
            ) {
                return await completedFailure(acquisitionFailure, diagnosticsFrom: capturingExecutor)
            }

            guard fileSystem.regularFileExists(at: rawPDF) else {
                return await failure(
                    status: 2,
                    message: "No scan output was created by the scanner backend.",
                    diagnosticsFrom: capturingExecutor
                )
            }

            let options = try DocumentProcessingOptions(environment: environment)
            let outputPaths: [String]
            if configuration.format == "pdf", configuration.pageMode == "multi" {
                try await processForMultipagePDF(
                    rawPDF: rawPDF,
                    outputDirectory: outputDirectory,
                    timestamp: timestamp,
                    configuration: configuration,
                    options: options,
                    workDirectory: workDirectory,
                    executor: capturingExecutor
                )
                outputPaths = [outputDirectory
                    .appendingPathComponent("\(timestamp.rawValue).pdf", isDirectory: false)
                    .path]
            } else {
                outputPaths = try await processFinalOutputs(
                    rawPDF: rawPDF,
                    outputDirectory: outputDirectory,
                    timestamp: timestamp,
                    configuration: configuration,
                    options: options,
                    workDirectory: workDirectory,
                    executor: capturingExecutor
                )
            }

            guard !outputPaths.isEmpty,
                  outputPaths.allSatisfy({ fileSystem.regularFileExists(at: URL(fileURLWithPath: $0)) })
            else {
                return await failure(
                    status: 2,
                    message: "No output files were created.",
                    diagnosticsFrom: capturingExecutor
                )
            }

            return ProcessResult(
                exitStatus: 0,
                standardOutput: outputPaths.joined(separator: "\n") + "\n",
                standardError: await capturingExecutor.standardError
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NativeScanConfigurationError {
            return await failure(
                status: 64,
                message: error.localizedDescription,
                diagnosticsFrom: capturingExecutor
            )
        } catch let error as NativeScanFileSystemError {
            switch error {
            case .outputConflict:
                return await failure(
                    status: 73,
                    message: error.localizedDescription,
                    diagnosticsFrom: capturingExecutor
                )
            }
        } catch let error as DocumentProcessingError {
            return await failure(
                status: error.compatibleExitStatus,
                message: documentProcessingDiagnostic(error),
                diagnosticsFrom: capturingExecutor
            )
        } catch is NativeScanMissingOutputError {
            return await failure(
                status: 2,
                message: "No output files were created.",
                diagnosticsFrom: capturingExecutor
            )
        } catch let error as ProcessExecutorError {
            return await failure(
                status: 127,
                message: error.localizedDescription,
                diagnosticsFrom: capturingExecutor
            )
        } catch {
            return await failure(
                status: 1,
                message: error.localizedDescription,
                diagnosticsFrom: capturingExecutor
            )
        }
    }

    private func acquireRawPDF(
        configuration: ScanPipelineConfiguration,
        rawPDF: URL,
        workDirectory: URL,
        executor: NativeScanCapturingExecutor
    ) async throws -> ProcessResult? {
        let environment = configuration.environment
        switch nonEmpty(environment["SCAN_BACKEND"]) ?? "wifi" {
        case "sane":
            var arguments = [
                "--batch=\(workDirectory.appendingPathComponent("page-%04d.pnm").path)",
                "--format=pnm",
                "--resolution", configuration.resolution,
                "--mode", configuration.mode,
                "--source", configuration.source,
            ]
            if let device = nonEmpty(environment["SCAN_DEVICE"]) {
                arguments.insert(contentsOf: ["--device-name", device], at: 0)
            }
            let scanResult = try await executor.execute(ProcessRequest(
                executable: "scanimage",
                arguments: arguments,
                environment: environment,
                workingDirectory: workDirectory
            ))
            guard scanResult.succeeded else { return scanResult }

            let pages = try fileSystem.regularFiles(
                in: workDirectory,
                withPrefix: "page-",
                pathExtension: "pnm"
            )
            guard !pages.isEmpty else {
                return ProcessResult(
                    exitStatus: 2,
                    standardError: "No pages were scanned. Check that paper is loaded and SCAN_SOURCE matches the scanner options."
                )
            }

            let imageResult = try await executor.execute(ProcessRequest(
                executable: "img2pdf",
                arguments: pages.map(\.path) + ["-o", rawPDF.path],
                environment: environment,
                workingDirectory: workDirectory
            ))
            return imageResult.succeeded ? nil : imageResult

        case "wifi":
            guard let scannerIP = nonEmpty(environment["SCANNER_IP"]) else {
                throw NativeScanConfigurationError.message(
                    "SCAN_BACKEND=wifi requires SCANNER_IP from the live scanner setup."
                )
            }
            guard let pairingKey = nonEmpty(environment["SCAN_PAIRING_KEY"])
                    ?? nonEmpty(environment["SCANSNAP_PAIRING_KEY"])
            else {
                throw NativeScanConfigurationError.message(
                    "SCAN_BACKEND=wifi requires SCAN_PAIRING_KEY or SCANSNAP_PAIRING_KEY from the live scanner setup."
                )
            }

            var arguments = ["-s", scannerIP, "-k", pairingKey, "-o", rawPDF.path]
            if let clientIP = nonEmpty(environment["SCANSNAP_CLIENT_IP"]) {
                arguments += ["--client-ip", clientIP]
            }
            if configuration.simplex
                || configuration.source.contains("Simplex")
                || configuration.source.contains("simplex")
            {
                arguments.append("-1")
            }
            if environment["SCAN_WIFI_DEBUG"] == "true" {
                arguments.append("-d")
            }

            let result = try await executor.execute(ProcessRequest(
                executable: "scansnap-wifi",
                arguments: arguments,
                environment: environment,
                workingDirectory: workDirectory
            ))
            return result.succeeded ? nil : result

        case let backend:
            throw NativeScanConfigurationError.message("Unsupported SCAN_BACKEND: \(backend)")
        }
    }

    private func processForMultipagePDF(
        rawPDF: URL,
        outputDirectory: URL,
        timestamp: ScanTimestamp,
        configuration: ScanPipelineConfiguration,
        options: DocumentProcessingOptions,
        workDirectory: URL,
        executor: NativeScanCapturingExecutor
    ) async throws {
        if configuration.removeBlankPages && !configuration.ocrEnabled {
            try await executeDocumentStep(
                .removeBlankPages,
                command: options.removeBlankPagesRequest(pdfPath: rawPDF.path).command,
                environment: configuration.environment,
                workingDirectory: workDirectory,
                executor: executor
            )
        }
        if configuration.cropPages && !configuration.ocrEnabled {
            try await executeDocumentStep(
                .cropPages,
                command: options.cropPagesRequest(pdfPath: rawPDF.path).command,
                environment: configuration.environment,
                workingDirectory: workDirectory,
                executor: executor
            )
        }
        try await executeDocumentStep(
            .setCreatorMetadata,
            command: SetPDFCreatorRequest(pdfPath: rawPDF.path, creator: options.creator).command,
            environment: configuration.environment,
            workingDirectory: workDirectory,
            executor: executor
        )

        guard fileSystem.regularFileExists(at: rawPDF) else {
            throw NativeScanMissingOutputError()
        }
        try Task.checkCancellation()
        let destination = outputDirectory.appendingPathComponent(
            "\(timestamp.rawValue).pdf",
            isDirectory: false
        )
        try fileSystem.placeFileExclusively(at: rawPDF, destination: destination)
    }

    private func processFinalOutputs(
        rawPDF: URL,
        outputDirectory: URL,
        timestamp: ScanTimestamp,
        configuration: ScanPipelineConfiguration,
        options: DocumentProcessingOptions,
        workDirectory: URL,
        executor: NativeScanCapturingExecutor
    ) async throws -> [String] {
        let finalOutput: DocumentFinalOutputRequest
        if configuration.format == "png" {
            finalOutput = .exportImages(ExportScanImagesRequest(
                pdfPath: rawPDF.path,
                outputDirectory: outputDirectory.path,
                prefix: timestamp
            ))
        } else {
            finalOutput = .splitPDF(SplitPDFPagesRequest(
                pdfPath: rawPDF.path,
                outputDirectory: outputDirectory.path,
                prefix: timestamp
            ))
        }

        let plan = DocumentProcessingPlan(
            removeBlankPages: configuration.removeBlankPages
                ? options.removeBlankPagesRequest(pdfPath: rawPDF.path)
                : nil,
            cropPages: configuration.cropPages
                ? options.cropPagesRequest(pdfPath: rawPDF.path)
                : nil,
            creatorMetadata: SetPDFCreatorRequest(pdfPath: rawPDF.path, creator: options.creator),
            finalOutput: finalOutput,
            environment: configuration.environment,
            workingDirectory: workDirectory
        )
        return try await DocumentProcessingOrchestrator(executor: executor)
            .process(plan)
            .outputPaths
    }

    private func executeDocumentStep(
        _ step: DocumentProcessingStep,
        command: ExternalDocumentToolCommand,
        environment: [String: String],
        workingDirectory: URL,
        executor: NativeScanCapturingExecutor
    ) async throws {
        try Task.checkCancellation()
        let result = try await executor.execute(command.processRequest(
            environment: environment,
            workingDirectory: workingDirectory
        ))
        guard result.succeeded else {
            throw DocumentProcessingError.completedProcessFailure(
                step: step,
                command: command,
                result: result
            )
        }
    }

    private func scanTimestamp(environment: [String: String]) throws -> ScanTimestamp {
        guard let configuredTimestamp = nonEmpty(environment["SCAN_TIMESTAMP"]) else {
            return timestampProvider()
        }
        do {
            return try ScanTimestamp(rawValue: configuredTimestamp)
        } catch {
            throw NativeScanConfigurationError.message(
                "Invalid SCAN_TIMESTAMP: \(configuredTimestamp)"
            )
        }
    }

    private func completedFailure(
        _ result: ProcessResult,
        diagnosticsFrom executor: NativeScanCapturingExecutor
    ) async -> ProcessResult {
        var diagnostics: [String] = []
        for candidate in [await executor.standardError, result.standardError, result.standardOutput] {
            let detail = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !detail.isEmpty else { continue }
            guard !diagnostics.contains(where: { $0.contains(detail) }) else { continue }
            diagnostics.append(detail)
        }
        if diagnostics.isEmpty {
            diagnostics.append("Scanner command exited with status \(result.exitStatus).")
        }
        return failure(status: result.exitStatus, message: diagnostics.joined(separator: "\n"))
    }

    private func failure(status: Int32, message: String) -> ProcessResult {
        ProcessResult(
            exitStatus: status,
            standardError: message.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        )
    }

    private func failure(
        status: Int32,
        message: String,
        diagnosticsFrom executor: NativeScanCapturingExecutor
    ) async -> ProcessResult {
        let captured = await executor.standardError
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedDetail = captured.trimmingCharacters(in: .whitespacesAndNewlines)
        let additionalDetail = capturedDetail.contains(detail) ? "" : detail
        let standardError = [capturedDetail, additionalDetail]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return ProcessResult(exitStatus: status, standardError: standardError + "\n")
    }

    private func documentProcessingDiagnostic(_ error: DocumentProcessingError) -> String {
        if case .missingFinalOutput = error {
            return "No output files were created."
        }
        return error.processResult.standardError.isEmpty
            ? error.localizedDescription
            : error.processResult.standardError
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func isValidPathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }
}

enum NativeScanConfigurationError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

private struct NativeScanMissingOutputError: Error, LocalizedError {
    var errorDescription: String? { "No output files were created." }
}

struct DocumentProcessingOptions {
    let creator: String
    let whiteThreshold: Int
    let contentRatioThreshold: Double
    let meanThreshold: Double
    let blankDebug: Bool
    let backgroundDelta: Int
    let borderPixels: Int
    let marginPoints: Double
    let maximumWidthRatio: Double
    let maximumHeightRatio: Double
    let minimumDensity: Double
    let keepOriginalBoxes: Bool
    let cropDebug: Bool

    init(environment: [String: String]) throws {
        creator = Self.nonEmpty(environment["SCAN_RAW_PDF_CREATOR"]) ?? "ScanSnap"
        whiteThreshold = try Self.integer(environment, key: "SCAN_BLANK_WHITE_THRESHOLD", default: 230)
        contentRatioThreshold = try Self.double(
            environment,
            key: "SCAN_BLANK_CONTENT_RATIO_THRESHOLD",
            default: 0.003
        )
        meanThreshold = try Self.double(environment, key: "SCAN_BLANK_MEAN_THRESHOLD", default: 248.0)
        blankDebug = Self.nonEmpty(environment["SCAN_BLANK_DEBUG"]) != nil
        backgroundDelta = try Self.integer(environment, key: "SCAN_CROP_BACKGROUND_DELTA", default: 8)
        borderPixels = try Self.integer(environment, key: "SCAN_CROP_BORDER_PX", default: 64)
        marginPoints = try Self.double(environment, key: "SCAN_CROP_MARGIN_POINTS", default: 1.0)
        maximumWidthRatio = try Self.double(environment, key: "SCAN_CROP_MAX_WIDTH_RATIO", default: 0.80)
        maximumHeightRatio = try Self.double(environment, key: "SCAN_CROP_MAX_HEIGHT_RATIO", default: 0.80)
        minimumDensity = try Self.double(environment, key: "SCAN_CROP_MIN_DENSITY", default: 0.08)
        keepOriginalBoxes = Self.nonEmpty(environment["SCAN_CROP_KEEP_ORIGINAL_BOXES"]) != nil
        cropDebug = Self.nonEmpty(environment["SCAN_CROP_DEBUG"]) != nil
    }

    func removeBlankPagesRequest(pdfPath: String) -> RemoveBlankPagesRequest {
        RemoveBlankPagesRequest(
            pdfPath: pdfPath,
            whiteThreshold: whiteThreshold,
            contentRatioThreshold: contentRatioThreshold,
            meanThreshold: meanThreshold,
            debug: blankDebug
        )
    }

    func cropPagesRequest(pdfPath: String) -> CropPDFPagesRequest {
        CropPDFPagesRequest(
            pdfPath: pdfPath,
            backgroundDelta: backgroundDelta,
            borderPixels: borderPixels,
            marginPoints: marginPoints,
            maximumWidthRatio: maximumWidthRatio,
            maximumHeightRatio: maximumHeightRatio,
            minimumDensity: minimumDensity,
            keepOriginalBoxes: keepOriginalBoxes,
            debug: cropDebug
        )
    }

    private static func integer(
        _ environment: [String: String],
        key: String,
        default defaultValue: Int
    ) throws -> Int {
        guard let value = nonEmpty(environment[key]) else { return defaultValue }
        guard let result = Int(value) else {
            throw NativeScanConfigurationError.message("Invalid \(key): \(value)")
        }
        return result
    }

    private static func double(
        _ environment: [String: String],
        key: String,
        default defaultValue: Double
    ) throws -> Double {
        guard let value = nonEmpty(environment[key]) else { return defaultValue }
        guard let result = Double(value), result.isFinite else {
            throw NativeScanConfigurationError.message("Invalid \(key): \(value)")
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private actor NativeScanCapturingExecutor: ProcessExecutor {
    private let executor: any ProcessExecutor
    private var diagnostics: [String] = []

    init(executor: any ProcessExecutor) {
        self.executor = executor
    }

    var standardError: String {
        guard !diagnostics.isEmpty else { return "" }
        return diagnostics.joined(separator: "\n") + "\n"
    }

    func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = try await executor.execute(request)
        let error = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !error.isEmpty {
            diagnostics.append("\(request.executable): \(error)")
        }
        return result
    }
}
