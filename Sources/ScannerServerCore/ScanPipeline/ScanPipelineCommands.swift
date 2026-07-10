import Foundation

public enum ScanPipelineCommands {
    public static func scan(
        configuration: ScanPipelineConfiguration,
        workingDirectory: URL? = nil
    ) -> ProcessRequest {
        return ProcessRequest(
            executable: "scan-once",
            environment: configuration.environment,
            workingDirectory: workingDirectory
        )
    }

    public static func ocr(
        inputPath: String,
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) -> ProcessRequest {
        let language = environment?["SCAN_LANGUAGE"] ?? "deu+eng"
        let rotatePagesThreshold = environment?["SCAN_OCR_ROTATE_PAGES_THRESHOLD"] ?? "2.0"
        return ProcessRequest(
            executable: "ocrmypdf",
            arguments: [
                "--language", language,
                "--rotate-pages",
                "--rotate-pages-threshold", rotatePagesThreshold,
                "--deskew",
                "--optimize", "1",
                inputPath,
                OCRInputPath.outputPath(for: inputPath) ?? inputPath,
            ],
            environment: environment,
            workingDirectory: workingDirectory
        )
    }

    public static func listScanners(
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) -> ProcessRequest {
        ProcessRequest(
            executable: "list-scanners",
            environment: environment,
            workingDirectory: workingDirectory
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
