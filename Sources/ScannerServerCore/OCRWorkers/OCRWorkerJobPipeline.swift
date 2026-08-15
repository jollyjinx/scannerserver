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
        cropConfiguration: OCRWorkerCropConfiguration?
    ) async throws -> ProcessResult {
        let ocrResult = try await ocrExecutor.execute(ocrRequest)
        guard ocrResult.succeeded, let cropConfiguration else { return ocrResult }
        try Task.checkCancellation()
        return try await documentExecutor.execute(
            cropConfiguration.request(pdfPath: resultURL.path).command.processRequest(
                environment: ocrRequest.environment,
                workingDirectory: ocrRequest.workingDirectory
            )
        )
    }
}
