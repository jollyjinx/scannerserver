import Foundation

public struct OCRWorkerJobPipeline: Sendable {
    private let ocrExecutor: any ProcessExecutor
    private let documentExecutor: any ProcessExecutor

    public init(
        ocrExecutor: any ProcessExecutor,
        documentExecutor: (any ProcessExecutor)? = nil
    ) {
        self.ocrExecutor = ocrExecutor
        self.documentExecutor = documentExecutor
            ?? NativeDocumentToolExecutor(executor: ocrExecutor)
    }

    public func execute(
        ocrRequest: ProcessRequest,
        resultURL: URL,
        cropConfiguration: OCRWorkerCropConfiguration?,
        blankPageConfiguration: OCRWorkerBlankPageConfiguration? = nil
    ) async throws -> ProcessResult {
        let ocrResult = try await ocrExecutor.execute(ocrRequest)
        guard ocrResult.succeeded else { return ocrResult }
        if let cropConfiguration {
            try Task.checkCancellation()
            let cropResult = try await documentExecutor.execute(
                cropConfiguration.request(pdfPath: resultURL.path).command.processRequest(
                    environment: ocrRequest.environment,
                    workingDirectory: ocrRequest.workingDirectory
                )
            )
            guard cropResult.succeeded else { return cropResult }
        }
        guard let blankPageConfiguration else { return ocrResult }
        try Task.checkCancellation()
        let blankResult = try await documentExecutor.execute(
            blankPageConfiguration.request(pdfPath: resultURL.path).command.processRequest(
                environment: ocrRequest.environment,
                workingDirectory: ocrRequest.workingDirectory
            )
        )
        return blankResult.succeeded ? ocrResult : blankResult
    }
}
