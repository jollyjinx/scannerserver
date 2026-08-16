import Foundation

/// Document work that starts after scanner acquisition has released its foreground lifecycle.
public struct DeferredScanProcessing: Equatable, Sendable {
    public let inputPath: String
    public let cleanupDirectory: URL
    public let plan: DocumentProcessingPlan
    public let ocrEnabled: Bool
    public let ocrOnly: Bool

    public init(
        inputPath: String,
        cleanupDirectory: URL,
        plan: DocumentProcessingPlan,
        ocrEnabled: Bool,
        ocrOnly: Bool = false
    ) {
        self.inputPath = inputPath
        self.cleanupDirectory = cleanupDirectory
        self.plan = plan
        self.ocrEnabled = ocrEnabled
        self.ocrOnly = ocrOnly
    }

    var validationError: String? {
        let cleanup = cleanupDirectory.resolvingSymlinksInPath().standardizedFileURL
        let input = URL(fileURLWithPath: inputPath, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let workDirectory = plan.workingDirectory?
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let workDirectoryName = cleanup.lastPathComponent

        guard workDirectoryName.hasPrefix(".scan-work."),
              workDirectoryName.count > ".scan-work.".count,
              input.lastPathComponent == "raw.pdf",
              input.deletingLastPathComponent() == cleanup,
              workDirectory == cleanup
        else {
            return "Deferred scan processing has an invalid work-directory scope."
        }

        let documentPaths = [
            plan.removeBlankPages?.pdfPath,
            plan.cropPages?.pdfPath,
            plan.creatorMetadata.pdfPath,
            finalOutputPDFPath,
        ].compactMap { $0 }
        guard documentPaths.allSatisfy({ standardizedPath($0) == input.path }) else {
            return "Deferred scan processing references a document outside its work directory."
        }

        let outputDirectory = URL(fileURLWithPath: finalOutputDirectory, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard outputDirectory == cleanup.deletingLastPathComponent()
            || (ocrOnly && outputDirectory == cleanup)
        else {
            return "Deferred scan processing references an unexpected output directory."
        }
        return nil
    }

    func removeCleanupDirectoryIfValid() {
        guard validationError == nil else { return }
        try? FileManager.default.removeItem(at: cleanupDirectory)
    }

    /// Publishes the raw PDF into the scan directory when only the OCR result was meant
    /// to be published and that publication did not happen (OCR/processing failed).
    func publishRawPDFFallback() {
        guard ocrOnly, validationError == nil, let rawFallbackName else { return }
        guard FileManager.default.fileExists(atPath: inputPath) else { return }
        let destination = cleanupDirectory.deletingLastPathComponent()
            .appendingPathComponent(rawFallbackName)
        try? FoundationNativeScanFileSystem().placeFileExclusively(
            at: URL(fileURLWithPath: inputPath),
            destination: destination
        )
    }

    private var rawFallbackName: String? {
        guard ocrOnly else { return nil }
        switch plan.finalOutput {
        case .splitPDF(let request): return "\(request.prefix.rawValue).pdf"
        case .exportImages: return nil
        }
    }

    private var finalOutputPDFPath: String {
        switch plan.finalOutput {
        case .splitPDF(let request): request.pdfPath
        case .exportImages(let request): request.pdfPath
        }
    }

    private var finalOutputDirectory: String {
        switch plan.finalOutput {
        case .splitPDF(let request): request.outputDirectory
        case .exportImages(let request): request.outputDirectory
        }
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}
