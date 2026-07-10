import Foundation

public enum ScanPipelineCommands {
    public static func scan(
        configuration: ScanPipelineConfiguration,
        workingDirectory: URL? = nil
    ) -> ProcessRequest {
        ProcessRequest(
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
        ProcessRequest(
            executable: "ocr-scan",
            arguments: [inputPath],
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
