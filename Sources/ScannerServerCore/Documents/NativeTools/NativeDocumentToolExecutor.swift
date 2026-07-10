import Foundation

public struct NativeDocumentToolExecutor: ProcessExecutor, Sendable {
    private struct StagedOutput {
        let source: URL
        let destination: URL
    }

    let executor: any ProcessExecutor
    let fileSystem: any NativeDocumentFileSystem

    public init(
        executor: any ProcessExecutor,
        fileSystem: any NativeDocumentFileSystem = FoundationNativeDocumentFileSystem()
    ) {
        self.executor = executor
        self.fileSystem = fileSystem
    }

    public func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        try Task.checkCancellation()

        switch request.executable {
        case "remove-blank-pages":
            do {
                return try await removeBlankPages(
                    options: NativeRemoveBlankPagesOptions(arguments: request.arguments),
                    request: request
                )
            } catch NativeDocumentCommandOptionsError.invalidArguments {
                return generatedFailure(
                    status: 2,
                    diagnostic: "remove-blank-pages: invalid arguments"
                )
            }
        case "crop-pdf-pages":
            do {
                return try await cropPDFPages(
                    options: NativeCropPDFPagesOptions(arguments: request.arguments),
                    request: request
                )
            } catch NativeDocumentCommandOptionsError.invalidArguments {
                return generatedFailure(
                    status: 2,
                    diagnostic: "crop-pdf-pages: invalid arguments"
                )
            }
        case "set-pdf-creator":
            guard request.arguments.count == 3, request.arguments[1] == "--creator" else {
                return try await executor.execute(request)
            }
            return try await setPDFCreator(
                pdfPath: request.arguments[0],
                creator: request.arguments[2],
                request: request
            )
        case "split-pdf-pages":
            guard request.arguments.count == 3 else {
                return try await executor.execute(request)
            }
            return try await splitPDFPages(
                pdfPath: request.arguments[0],
                outputDirectoryPath: request.arguments[1],
                prefix: request.arguments[2],
                request: request
            )
        case "export-scan-images":
            guard request.arguments.count == 3 else {
                return try await executor.execute(request)
            }
            return try await exportScanImages(
                pdfPath: request.arguments[0],
                outputDirectoryPath: request.arguments[1],
                prefix: request.arguments[2],
                request: request
            )
        default:
            return try await executor.execute(request)
        }
    }

    private func setPDFCreator(
        pdfPath: String,
        creator: String,
        request: ProcessRequest
    ) async throws -> ProcessResult {
        let producerRequest = nativeRequest(
            executable: "exiftool",
            arguments: ["-s3", "-XMP-pdf:Producer", pdfPath],
            inheriting: request
        )
        let producerResult = try await executor.execute(producerRequest)
        guard producerResult.succeeded else { return producerResult }
        try Task.checkCancellation()

        let existingProducer = producerResult.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let producer = existingProducer.isEmpty ? "ScanSnap Linux" : existingProducer
        let arguments = [
            "-overwrite_original",
            "-PDF:Creator=\(creator)",
            "-XMP-xmp:CreatorTool=\(creator)",
            "-PDF:Producer=\(producer)",
            "-XMP-pdf:Producer=\(producer)",
            pdfPath,
        ]

        let updateResult = try await executor.execute(nativeRequest(
            executable: "exiftool",
            arguments: arguments,
            inheriting: request
        ))
        try Task.checkCancellation()
        guard updateResult.succeeded else { return updateResult }

        return ProcessResult(
            exitStatus: 0,
            standardError: joinedDiagnostics(producerResult.standardError, updateResult.standardError)
        )
    }

    private func splitPDFPages(
        pdfPath: String,
        outputDirectoryPath: String,
        prefix: String,
        request: ProcessRequest
    ) async throws -> ProcessResult {
        let outputDirectory = resolvedURL(outputDirectoryPath, request: request, isDirectory: true)
        try fileSystem.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let pageCountResult = try await pageCount(pdfPath: pdfPath, request: request)
        guard pageCountResult.result.succeeded else { return pageCountResult.result }
        guard pageCountResult.count > 0 else {
            return generatedFailure(status: 2, diagnostic: "PDF has no pages.")
        }

        let destinations = (1...pageCountResult.count).map { page in
            outputDirectory.appendingPathComponent(
                "\(prefix)-page-\(paddedPage(page)).pdf",
                isDirectory: false
            )
        }
        if let conflict = destinations.first(where: { fileSystem.itemExists(at: $0) }) {
            return outputConflict(at: conflict)
        }

        let stagingDirectory = try fileSystem.createTemporaryDirectory(in: outputDirectory)
        defer { try? fileSystem.removeItemIfPresent(at: stagingDirectory) }

        var outputs: [StagedOutput] = []
        var diagnostics = pageCountResult.result.standardError
        for (page, destination) in zip(1...pageCountResult.count, destinations) {
            try Task.checkCancellation()
            let staged = stagingDirectory.appendingPathComponent(
                destination.lastPathComponent,
                isDirectory: false
            )
            let splitResult = try await executor.execute(nativeRequest(
                executable: "qpdf",
                arguments: [pdfPath, "--pages", ".", String(page), "--", staged.path],
                inheriting: request
            ))
            guard splitResult.succeeded else { return splitResult }
            diagnostics = joinedDiagnostics(diagnostics, splitResult.standardError)
            outputs.append(StagedOutput(source: staged, destination: destination))
        }

        return try publish(outputs, diagnostics: diagnostics)
    }

    private func exportScanImages(
        pdfPath: String,
        outputDirectoryPath: String,
        prefix: String,
        request: ProcessRequest
    ) async throws -> ProcessResult {
        let outputDirectory = resolvedURL(outputDirectoryPath, request: request, isDirectory: true)
        try fileSystem.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let pageCountResult = try await pageCount(pdfPath: pdfPath, request: request)
        guard pageCountResult.result.succeeded else { return pageCountResult.result }
        guard pageCountResult.count > 0 else {
            return generatedFailure(status: 2, diagnostic: "No page images were exported.")
        }

        let stagingDirectory = try fileSystem.createTemporaryDirectory(in: outputDirectory)
        defer { try? fileSystem.removeItemIfPresent(at: stagingDirectory) }

        var outputs: [StagedOutput] = []
        var diagnostics = pageCountResult.result.standardError
        for page in 1...pageCountResult.count {
            try Task.checkCancellation()
            let extractionName = "page-\(paddedPage(page))"
            let extractionRoot = stagingDirectory.appendingPathComponent(
                extractionName,
                isDirectory: false
            )
            let extractionResult = try await executor.execute(nativeRequest(
                executable: "pdfimages",
                arguments: [
                    "-f", String(page),
                    "-l", String(page),
                    "-png",
                    pdfPath,
                    extractionRoot.path,
                ],
                inheriting: request
            ))
            guard extractionResult.succeeded else { return extractionResult }
            diagnostics = joinedDiagnostics(diagnostics, extractionResult.standardError)

            let extractedFiles = try fileSystem.regularFiles(
                in: stagingDirectory,
                withPrefix: "\(extractionName)-",
                pathExtension: "png"
            )
            guard let source = try largestPNG(in: extractedFiles) else {
                diagnostics = joinedDiagnostics(
                    diagnostics,
                    "Page \(page) has no embedded image.\n"
                )
                continue
            }

            let destination = outputDirectory.appendingPathComponent(
                "\(prefix)-page-\(paddedPage(page)).png",
                isDirectory: false
            )
            if fileSystem.itemExists(at: destination) {
                return outputConflict(at: destination)
            }

            let rotationResult = try await pageRotation(
                page: page,
                pdfPath: pdfPath,
                request: request
            )
            guard rotationResult.result.succeeded else { return rotationResult.result }
            diagnostics = joinedDiagnostics(diagnostics, rotationResult.result.standardError)

            let publishSource: URL
            if rotationResult.degrees == 0 {
                publishSource = source
            } else {
                try Task.checkCancellation()
                let rotated = stagingDirectory.appendingPathComponent(
                    "rotated-\(extractionName).png",
                    isDirectory: false
                )
                let rotateResult = try await executor.execute(nativeRequest(
                    executable: "vips",
                    arguments: [
                        "rot",
                        source.path,
                        rotated.path,
                        "d\(rotationResult.degrees)",
                    ],
                    inheriting: request
                ))
                guard rotateResult.succeeded else { return rotateResult }
                try Task.checkCancellation()
                diagnostics = joinedDiagnostics(diagnostics, rotateResult.standardError)
                publishSource = rotated
            }

            outputs.append(StagedOutput(source: publishSource, destination: destination))
        }

        guard !outputs.isEmpty else {
            return generatedFailure(
                status: 2,
                diagnostic: joinedDiagnostics(diagnostics, "No page images were exported.\n")
            )
        }
        return try publish(outputs, diagnostics: diagnostics)
    }

    private func pageCount(
        pdfPath: String,
        request: ProcessRequest
    ) async throws -> (count: Int, result: ProcessResult) {
        let result = try await executor.execute(nativeRequest(
            executable: "qpdf",
            arguments: ["--show-npages", pdfPath],
            inheriting: request
        ))
        guard result.succeeded else { return (0, result) }
        try Task.checkCancellation()

        let value = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(value), count >= 0 else {
            return (
                0,
                generatedFailure(status: 2, diagnostic: "qpdf did not return a valid page count.")
            )
        }
        return (count, result)
    }

    private func pageRotation(
        page: Int,
        pdfPath: String,
        request: ProcessRequest
    ) async throws -> (degrees: Int, result: ProcessResult) {
        let result = try await executor.execute(nativeRequest(
            executable: "pdfinfo",
            arguments: ["-f", String(page), "-l", String(page), pdfPath],
            inheriting: request
        ))
        guard result.succeeded else { return (0, result) }
        try Task.checkCancellation()

        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            guard let marker = line.range(of: "rot:") else { continue }
            let value = line[marker.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            guard let reportedDegrees = Int(value) else { continue }

            let normalizedDegrees = ((reportedDegrees % 360) + 360) % 360
            guard [0, 90, 180, 270].contains(normalizedDegrees) else { break }
            return (normalizedDegrees, result)
        }

        return (
            0,
            generatedFailure(
                status: 2,
                diagnostic: "pdfinfo did not return a valid rotation for page \(page)."
            )
        )
    }

    func largestPNG(in files: [URL]) throws -> URL? {
        var largest: (url: URL, pixels: UInt64)?
        for file in files {
            guard let dimensions = try fileSystem.pngDimensions(at: file) else { continue }
            if largest == nil || dimensions.pixelCount > largest!.pixels {
                largest = (file, dimensions.pixelCount)
            }
        }
        return largest?.url
    }

    private func publish(
        _ outputs: [StagedOutput],
        diagnostics: String
    ) throws -> ProcessResult {
        var published: [URL] = []
        do {
            for output in outputs {
                try Task.checkCancellation()
                try fileSystem.placeFileExclusively(
                    at: output.source,
                    destination: output.destination
                )
                published.append(output.destination)
            }
            try Task.checkCancellation()
        } catch {
            for destination in published.reversed() {
                try? fileSystem.removeItemIfPresent(at: destination)
            }
            if let conflict = error as? NativeDocumentFileSystemError,
               case .outputConflict(let path) = conflict
            {
                return outputConflict(at: URL(fileURLWithPath: path))
            }
            throw error
        }

        let standardOutput = outputs
            .map(\.destination.path)
            .joined(separator: "\n") + "\n"
        return ProcessResult(
            exitStatus: 0,
            standardOutput: standardOutput,
            standardError: diagnostics
        )
    }

    func nativeRequest(
        executable: String,
        arguments: [String],
        inheriting request: ProcessRequest
    ) -> ProcessRequest {
        ProcessRequest(
            executable: executable,
            arguments: arguments,
            environment: request.environment,
            workingDirectory: request.workingDirectory
        )
    }

    func resolvedURL(
        _ path: String,
        request: ProcessRequest,
        isDirectory: Bool
    ) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: isDirectory)
        }
        if let workingDirectory = request.workingDirectory {
            return workingDirectory.appendingPathComponent(path, isDirectory: isDirectory)
        }
        return URL(fileURLWithPath: path, isDirectory: isDirectory)
    }

    private func paddedPage(_ page: Int) -> String {
        String(format: "%04d", page)
    }

    private func outputConflict(at url: URL) -> ProcessResult {
        generatedFailure(
            status: 73,
            diagnostic: "Output file already exists: \(url.path)"
        )
    }

    func generatedFailure(status: Int32, diagnostic: String) -> ProcessResult {
        ProcessResult(
            exitStatus: status,
            standardError: diagnostic.hasSuffix("\n") ? diagnostic : "\(diagnostic)\n"
        )
    }

    func joinedDiagnostics(_ first: String, _ second: String) -> String {
        guard !first.isEmpty else { return second }
        guard !second.isEmpty else { return first }
        return first.hasSuffix("\n") ? first + second : first + "\n" + second
    }
}
