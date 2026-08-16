import Foundation

public enum ScanPipelineCommands {
    public static func ocr(
        inputPath: String,
        outputPath: String? = nil,
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        jobs: Int? = nil,
        niceLevel: Int? = nil,
        workerMetadata: OCRWorkerJobMetadata? = nil,
        workerCropConfiguration: OCRWorkerCropConfiguration? = nil,
        workerBlankPageConfiguration: OCRWorkerBlankPageConfiguration? = nil,
        executionPreference: OCRExecutionPreference = .automatic
    ) -> ProcessRequest {
        let language = environment?["SCAN_LANGUAGE"] ?? "deu+eng"
        let rotatePagesThreshold = environment?["SCAN_OCR_ROTATE_PAGES_THRESHOLD"] ?? "2.0"
        var arguments = [
            "--language", language,
            "--rotate-pages",
            "--rotate-pages-threshold", rotatePagesThreshold,
            "--deskew",
            "--optimize", "1",
        ]
        if let jobs {
            arguments += ["--jobs", String(max(1, jobs))]
        }
        arguments += [
            inputPath,
            outputPath ?? OCRInputPath.outputPath(for: inputPath) ?? inputPath,
        ]
        return ProcessRequest(
            executable: "ocrmypdf",
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            niceLevel: niceLevel,
            ocrWorkerMetadata: workerMetadata,
            ocrWorkerCropConfiguration: workerCropConfiguration,
            ocrWorkerBlankPageConfiguration: workerBlankPageConfiguration,
            ocrExecutionPreference: executionPreference
        )
    }

}

public enum OCRInputPath {
    public static func outputPath(for inputPath: String) -> String? {
        guard inputPath.hasSuffix(".pdf"), !inputPath.hasSuffix(".ocr.pdf") else {
            return nil
        }
        return String(inputPath.dropLast(4)) + ".ocr.pdf"
    }
}

public enum ScanOutputPaths {
    public static func candidates(from standardOutput: String) -> [String] {
        standardOutput
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func existing(from standardOutput: String, fileManager: FileManager = .default) -> [String] {
        candidates(from: standardOutput).filter { path in
            var isDirectory = ObjCBool(false)
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    public static func shouldEnqueueOCR(
        path: String,
        configuration: ScanPipelineConfiguration,
        fileManager: FileManager = .default
    ) -> Bool {
        guard configuration.ocrEnabled else { return false }

        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "pdf",
              !url.lastPathComponent.lowercased().hasSuffix(".ocr.pdf")
        else {
            return false
        }

        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
