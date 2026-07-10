import Foundation

public enum DocumentFinalOutputRequest: Equatable, Sendable {
    case splitPDF(SplitPDFPagesRequest)
    case exportImages(ExportScanImagesRequest)

    var stepAndCommand: (DocumentProcessingStep, ExternalDocumentToolCommand) {
        switch self {
        case .splitPDF(let request):
            (.splitPDFPages, request.command)
        case .exportImages(let request):
            (.exportScanImages, request.command)
        }
    }
}

public struct DocumentProcessingPlan: Equatable, Sendable {
    public var removeBlankPages: RemoveBlankPagesRequest?
    public var cropPages: CropPDFPagesRequest?
    public var creatorMetadata: SetPDFCreatorRequest
    public var finalOutput: DocumentFinalOutputRequest
    public var environment: [String: String]?
    public var workingDirectory: URL?

    public init(
        removeBlankPages: RemoveBlankPagesRequest? = nil,
        cropPages: CropPDFPagesRequest? = nil,
        creatorMetadata: SetPDFCreatorRequest,
        finalOutput: DocumentFinalOutputRequest,
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) {
        self.removeBlankPages = removeBlankPages
        self.cropPages = cropPages
        self.creatorMetadata = creatorMetadata
        self.finalOutput = finalOutput
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public struct DocumentProcessingResult: Equatable, Sendable {
    public let outputPaths: [String]

    public init(outputPaths: [String]) {
        self.outputPaths = outputPaths
    }
}

public struct DocumentProcessingOrchestrator: Sendable {
    private let executor: any ProcessExecutor

    public init(executor: any ProcessExecutor) {
        self.executor = executor
    }

    public func process(_ plan: DocumentProcessingPlan) async throws -> DocumentProcessingResult {
        if let request = plan.removeBlankPages {
            _ = try await execute(
                step: .removeBlankPages,
                command: request.command,
                plan: plan
            )
        }

        if let request = plan.cropPages {
            _ = try await execute(
                step: .cropPages,
                command: request.command,
                plan: plan
            )
        }

        _ = try await execute(
            step: .setCreatorMetadata,
            command: plan.creatorMetadata.command,
            plan: plan
        )

        let (step, command) = plan.finalOutput.stepAndCommand
        let result = try await execute(step: step, command: command, plan: plan)
        let outputPaths = DocumentToolOutputPaths.parse(result.standardOutput)
        guard !outputPaths.isEmpty else {
            throw DocumentProcessingError.missingFinalOutput(
                step: step,
                command: command,
                result: result
            )
        }

        return DocumentProcessingResult(outputPaths: outputPaths)
    }

    private func execute(
        step: DocumentProcessingStep,
        command: ExternalDocumentToolCommand,
        plan: DocumentProcessingPlan
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let result = try await executor.execute(command.processRequest(
            environment: plan.environment,
            workingDirectory: plan.workingDirectory
        ))
        guard result.succeeded else {
            throw DocumentProcessingError.completedProcessFailure(
                step: step,
                command: command,
                result: result
            )
        }
        return result
    }
}

public struct PreviewRenderingStep: Equatable, Sendable {
    public let request: PreviewToolRequest
    public let nativeRequirement: PreviewNativeRenderingRequirement
    public let fallback: PreviewFallback

    public init(request: PreviewToolRequest) {
        self.request = request
        switch request.renderingPlan {
        case .nativeRenderingRequired(let requirement, let fallback):
            nativeRequirement = requirement
            self.fallback = fallback
        }
    }
}

/// Implementations may bridge to a platform-native renderer or an external PDF/image tool.
public protocol PreviewNativeRendering: Sendable {
    func render(_ step: PreviewRenderingStep) async throws -> Bool
}

public enum PreviewFallbackReason: Equatable, Sendable {
    case rendererUnavailable
    case rendererDeclined
    case rendererFailed(String)
}

public enum PreviewRenderingOutcome: Equatable, Sendable {
    case rendered(destinationPath: String)
    case placeholderWritten(
        destinationPath: String,
        fallback: PreviewFallback,
        reason: PreviewFallbackReason
    )
}

public struct PreviewRenderingOrchestrator: Sendable {
    private let renderer: (any PreviewNativeRendering)?

    public init(renderer: (any PreviewNativeRendering)? = nil) {
        self.renderer = renderer
    }

    public func render(_ request: PreviewToolRequest) async throws -> PreviewRenderingOutcome {
        let step = PreviewRenderingStep(request: request)
        try Task.checkCancellation()

        let fallbackReason: PreviewFallbackReason
        if let renderer {
            do {
                if try await renderer.render(step) {
                    return .rendered(destinationPath: request.destinationPath)
                }
                fallbackReason = .rendererDeclined
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                fallbackReason = .rendererFailed(String(describing: error))
            }
        } else {
            fallbackReason = .rendererUnavailable
        }

        try Task.checkCancellation()
        let destination = URL(fileURLWithPath: request.destinationPath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try step.fallback.bytes.write(to: destination, options: .atomic)
        return .placeholderWritten(
            destinationPath: request.destinationPath,
            fallback: step.fallback,
            reason: fallbackReason
        )
    }
}
