import Foundation

public protocol NativeScanExecuting: Sendable {
    func scan(configuration: ScanPipelineConfiguration) async throws -> ProcessResult
}

public actor NativeScanPipeline: NativeScanExecuting {
    public typealias TimestampProvider = @Sendable () -> ScanTimestamp
    public typealias WorkDirectorySuffixProvider = @Sendable () -> String

    private let executor: any ProcessExecutor
    private let wifiAcquirer: any ScanSnapWiFiAcquiring
    private let ocrQueue: OCRQueueActor?
    private let acquisitionSessions: ScanSnapAcquisitionSessionCoordinator
    private let fileSystem: any NativeScanFileSystem
    private let timestampProvider: TimestampProvider?
    private let workDirectorySuffixProvider: WorkDirectorySuffixProvider

    public init(
        executor: any ProcessExecutor,
        wifiAcquirer: any ScanSnapWiFiAcquiring = ScanSnapWiFiAcquisitionClient(),
        ocrQueue: OCRQueueActor? = nil,
        acquisitionSessions: ScanSnapAcquisitionSessionCoordinator = ScanSnapAcquisitionSessionCoordinator(),
        fileSystem: any NativeScanFileSystem = FoundationNativeScanFileSystem(),
        timestampProvider: TimestampProvider? = nil,
        workDirectorySuffixProvider: @escaping WorkDirectorySuffixProvider = { UUID().uuidString }
    ) {
        self.executor = executor
        self.wifiAcquirer = wifiAcquirer
        self.ocrQueue = ocrQueue
        self.acquisitionSessions = acquisitionSessions
        self.fileSystem = fileSystem
        self.timestampProvider = timestampProvider
        self.workDirectorySuffixProvider = workDirectorySuffixProvider
    }

    public func scan(configuration: ScanPipelineConfiguration) async throws -> ProcessResult {
        let acquisitionSessionMode = await acquisitionSessions.consumeForAcquisition()
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
        var pipelineOwnsWorkDirectory = true
        defer {
            if pipelineOwnsWorkDirectory {
                try? fileSystem.removeItemIfPresent(at: workDirectory)
            }
        }

        let capturingExecutor = NativeScanCapturingExecutor(executor: executor)
        var activeStreamingBatchID: UUID?
        do {
            let timestamp = try scanTimestamp(environment: environment)
            let rawPDF = workDirectory.appendingPathComponent("raw.pdf", isDirectory: false)
            let streamingBatchID: UUID?
            if let ocrQueue,
               (nonEmpty(environment["SCAN_BACKEND"]) ?? "wifi") == "wifi",
               configuration.format == "pdf",
               configuration.pageMode == "multi",
               configuration.ocrEnabled
            {
                streamingBatchID = await ocrQueue.beginStreamingScan(StreamingScanRequest(
                    documentName: "\(timestamp.rawValue).pdf",
                    finalOutputPath: outputDirectory
                        .appendingPathComponent("\(timestamp.rawValue).ocr.pdf")
                        .path,
                    workDirectory: workDirectory,
                    environment: environment,
                    removeBlankPages: configuration.removeBlankPages,
                    cropPages: configuration.cropPages
                ))
            } else {
                streamingBatchID = nil
            }
            activeStreamingBatchID = streamingBatchID

            let acquisition = try await acquireRawPDF(
                configuration: configuration,
                acquisitionSessionMode: acquisitionSessionMode,
                rawPDF: rawPDF,
                workDirectory: workDirectory,
                executor: capturingExecutor,
                streamingBatchID: streamingBatchID
            )
            if let acquisitionFailure = acquisition.failure {
                if let streamingBatchID, let ocrQueue {
                    await ocrQueue.cancelStreamingScan(batchID: streamingBatchID)
                    activeStreamingBatchID = nil
                }
                return await completedFailure(acquisitionFailure, diagnosticsFrom: capturingExecutor)
            }

            guard fileSystem.regularFileExists(at: rawPDF) else {
                if let streamingBatchID, let ocrQueue {
                    await ocrQueue.cancelStreamingScan(batchID: streamingBatchID)
                    activeStreamingBatchID = nil
                }
                return await failure(
                    status: 2,
                    message: "No scan output was created by the scanner backend.",
                    diagnosticsFrom: capturingExecutor
                )
            }

            let options = try DocumentProcessingOptions(environment: environment)
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
                let outputPath = outputDirectory
                    .appendingPathComponent("\(timestamp.rawValue).pdf", isDirectory: false)
                    .path
                guard fileSystem.regularFileExists(at: URL(fileURLWithPath: outputPath)) else {
                    if let streamingBatchID, let ocrQueue {
                        await ocrQueue.cancelStreamingScan(batchID: streamingBatchID)
                        activeStreamingBatchID = nil
                    }
                    return await failure(
                        status: 2,
                        message: "No output files were created.",
                        diagnosticsFrom: capturingExecutor
                    )
                }
                if let streamingBatchID, let ocrQueue {
                    pipelineOwnsWorkDirectory = false
                    do {
                        try await ocrQueue.finishStreamingScan(
                            batchID: streamingBatchID,
                            pageCount: acquisition.pageCount ?? 0
                        )
                    } catch {
                        await ocrQueue.cancelStreamingScan(batchID: streamingBatchID)
                        activeStreamingBatchID = nil
                        throw error
                    }
                    activeStreamingBatchID = nil
                }
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: outputPath + "\n",
                    standardError: await capturingExecutor.standardError,
                    postProcessingHandled: streamingBatchID != nil
                )
            }

            let deferredProcessing = deferredFinalOutputProcessing(
                rawPDF: rawPDF,
                outputDirectory: outputDirectory,
                timestamp: timestamp,
                configuration: configuration,
                options: options,
                workDirectory: workDirectory
            )
            pipelineOwnsWorkDirectory = false
            return ProcessResult(
                exitStatus: 0,
                standardError: await capturingExecutor.standardError,
                deferredScanProcessing: deferredProcessing
            )
        } catch is CancellationError {
            if let activeStreamingBatchID, let ocrQueue {
                await ocrQueue.cancelStreamingScan(batchID: activeStreamingBatchID)
            }
            throw CancellationError()
        } catch let error as NativeScanConfigurationError {
            if let activeStreamingBatchID, let ocrQueue {
                await ocrQueue.cancelStreamingScan(batchID: activeStreamingBatchID)
            }
            return await failure(
                status: 64,
                message: error.localizedDescription,
                diagnosticsFrom: capturingExecutor
            )
        } catch let error as NativeScanFileSystemError {
            if let activeStreamingBatchID, let ocrQueue {
                await ocrQueue.cancelStreamingScan(batchID: activeStreamingBatchID)
            }
            switch error {
            case .outputConflict:
                return await failure(
                    status: 73,
                    message: error.localizedDescription,
                    diagnosticsFrom: capturingExecutor
                )
            }
        } catch let error as DocumentProcessingError {
            if let activeStreamingBatchID, let ocrQueue {
                await ocrQueue.cancelStreamingScan(batchID: activeStreamingBatchID)
            }
            return await failure(
                status: error.compatibleExitStatus,
                message: documentProcessingDiagnostic(error),
                diagnosticsFrom: capturingExecutor
            )
        } catch is NativeScanMissingOutputError {
            if let activeStreamingBatchID, let ocrQueue {
                await ocrQueue.cancelStreamingScan(batchID: activeStreamingBatchID)
            }
            return await failure(
                status: 2,
                message: "No output files were created.",
                diagnosticsFrom: capturingExecutor
            )
        } catch let error as ProcessExecutorError {
            if let activeStreamingBatchID, let ocrQueue {
                await ocrQueue.cancelStreamingScan(batchID: activeStreamingBatchID)
            }
            return await failure(
                status: 127,
                message: error.localizedDescription,
                diagnosticsFrom: capturingExecutor
            )
        } catch {
            if let activeStreamingBatchID, let ocrQueue {
                await ocrQueue.cancelStreamingScan(batchID: activeStreamingBatchID)
            }
            return await failure(
                status: 1,
                message: error.localizedDescription,
                diagnosticsFrom: capturingExecutor
            )
        }
    }

    private func acquireRawPDF(
        configuration: ScanPipelineConfiguration,
        acquisitionSessionMode: ScanSnapAcquisitionSessionMode,
        rawPDF: URL,
        workDirectory: URL,
        executor: NativeScanCapturingExecutor,
        streamingBatchID: UUID?
    ) async throws -> (failure: ProcessResult?, pageCount: Int?) {
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
            guard scanResult.succeeded else { return (scanResult, nil) }

            let pages = try fileSystem.regularFiles(
                in: workDirectory,
                withPrefix: "page-",
                pathExtension: "pnm"
            )
            guard !pages.isEmpty else {
                return (
                    ProcessResult(
                        exitStatus: 2,
                        standardError: "No pages were scanned. Check that paper is loaded and SCAN_SOURCE matches the scanner options."
                    ),
                    nil
                )
            }

            let imageResult = try await executor.execute(ProcessRequest(
                executable: "img2pdf",
                arguments: pages.map(\.path) + ["-o", rawPDF.path],
                environment: environment,
                workingDirectory: workDirectory
            ))
            return imageResult.succeeded ? (nil, pages.count) : (imageResult, nil)

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

            let clientIPAddress: String?
            if let configured = nonEmpty(environment["SCANSNAP_CLIENT_IP"]) {
                do {
                    clientIPAddress = try ScannerConfig.normalizeIPv4Address(configured)
                } catch {
                    throw NativeScanConfigurationError.message(
                        "Invalid SCANSNAP_CLIENT_IP: \(configured)"
                    )
                }
            } else {
                clientIPAddress = nil
            }
            let clientMACAddress: [UInt8]?
            if let configured = nonEmpty(environment["SCANSNAP_CLIENT_MAC"]) {
                do {
                    clientMACAddress = try ScanSnapSetupEnvironmentConfiguration.macBytes(configured)
                } catch {
                    throw NativeScanConfigurationError.message(
                        "Invalid SCANSNAP_CLIENT_MAC: \(configured)"
                    )
                }
            } else {
                clientMACAddress = nil
            }
            let simplex = configuration.simplex
                || configuration.source.contains("Simplex")
                || configuration.source.contains("simplex")
            let buttonConfiguration = ScanSnapButtonConfiguration(environment: environment)
            let request = ScanSnapWiFiAcquisitionRequest(
                scannerIPAddress: scannerIP,
                identity: ScanSnapIdentity(pairingKey),
                clientIPAddress: clientIPAddress,
                clientMACAddress: clientMACAddress,
                clientInterface: nonEmpty(environment["SCANSNAP_CLIENT_INTERFACE"]) ?? "eth0",
                simplex: simplex,
                reusesArmedSession: acquisitionSessionMode == .reuseArmed,
                debug: environment["SCAN_WIFI_DEBUG"] == "true",
                outputURL: rawPDF,
                registrationSourcePort: buttonConfiguration.registrationSourcePort,
                registrationPort: buttonConfiguration.registrationPort
            )
            let result: ScanSnapWiFiAcquisitionResult
            if let streamingBatchID, let ocrQueue {
                result = try await wifiAcquirer.acquire(request) { page in
                    try await ocrQueue.submitStreamingPage(batchID: streamingBatchID, page: page)
                }
            } else {
                result = try await wifiAcquirer.acquire(request)
            }
            await executor.recordDiagnostic(result.diagnostics)
            return (nil, result.pageCount)

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

    private func deferredFinalOutputProcessing(
        rawPDF: URL,
        outputDirectory: URL,
        timestamp: ScanTimestamp,
        configuration: ScanPipelineConfiguration,
        options: DocumentProcessingOptions,
        workDirectory: URL
    ) -> DeferredScanProcessing {
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
        return DeferredScanProcessing(
            inputPath: rawPDF.path,
            cleanupDirectory: workDirectory,
            plan: plan,
            ocrEnabled: configuration.ocrEnabled && configuration.format == "pdf"
        )
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
            if let timestampProvider {
                return timestampProvider()
            }
            return ScannerServerLocalTime(environment: environment).scanTimestamp(for: Date())
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

    func recordDiagnostic(_ message: String) {
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty { diagnostics.append("ScanSnap: \(detail)") }
    }
}
