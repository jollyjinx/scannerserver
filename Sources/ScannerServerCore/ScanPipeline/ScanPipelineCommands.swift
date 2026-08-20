import Foundation

public enum OCRInputPath {
    public static func outputPath(for inputPath: String) -> String? {
        guard inputPath.hasSuffix(".pdf"), !inputPath.hasSuffix(".ocr.pdf") else {
            return nil
        }
        return String(inputPath.dropLast(4)) + ".ocr.pdf"
    }

    public static func outputPath(for inputPath: String, in outputDirectory: String) -> String? {
        guard let relative = outputPath(for: inputPath) else { return nil }
        return URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent(URL(fileURLWithPath: relative).lastPathComponent)
            .path
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
