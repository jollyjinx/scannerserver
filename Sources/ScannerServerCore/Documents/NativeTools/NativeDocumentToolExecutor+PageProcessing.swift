import Foundation

private enum NativePageProcessingFailure: Error {
    case process(ProcessResult)
    case diagnostic(String)
}

private struct NativeExtractedPageImage {
    let url: URL
    let dimensions: NativeDocumentImageDimensions
}

extension NativeDocumentToolExecutor {
    func removeBlankPages(
        options: NativeRemoveBlankPagesOptions,
        request: ProcessRequest
    ) async throws -> ProcessResult {
        do {
            let jsonResult = try await successfulProcess(
                executable: "qpdf",
                arguments: [
                    "--json-output=2",
                    "--json-stream-data=none",
                    "--json-key=pages",
                    options.pdfPath,
                ],
                request: request
            )
            let document: NativePDFJSONDocument
            do {
                document = try NativePDFJSONDocument(data: Data(jsonResult.standardOutput.utf8))
            } catch {
                throw NativePageProcessingFailure.diagnostic(
                    (error as? LocalizedError)?.errorDescription
                        ?? "qpdf returned malformed JSON v2 output."
                )
            }

            let pdfURL = resolvedURL(options.pdfPath, request: request, isDirectory: false)
            let stagingDirectory = try fileSystem.createTemporaryDirectory(
                in: pdfURL.deletingLastPathComponent()
            )
            defer { try? fileSystem.removeItemIfPresent(at: stagingDirectory) }

            var diagnostics = jsonResult.standardError
            var decisions: [NativeBlankPageDecision] = []
            if !document.pageReferences.isEmpty {
                for index in document.pageReferences.indices {
                    let page = index + 1
                    try Task.checkCancellation()
                    let extraction = try await extractLargestPageImage(
                        page: page,
                        pdfPath: options.pdfPath,
                        allowedReferences: try document.directImageReferences(
                            forPageAt: index
                        ),
                        prefix: "blank-page-\(paddedPageNumber(page))",
                        stagingDirectory: stagingDirectory,
                        request: request
                    )
                    diagnostics = joinedDiagnostics(diagnostics, extraction.diagnostics)
                    guard let image = extraction.image else {
                        decisions.append(NativeBlankPageDecision(
                            isBlank: false,
                            detail: "no image"
                        ))
                        continue
                    }

                    let statistics = try await blankStatistics(
                        image: image,
                        page: page,
                        whiteThreshold: options.whiteThreshold,
                        stagingDirectory: stagingDirectory,
                        request: request
                    )
                    diagnostics = joinedDiagnostics(diagnostics, statistics.diagnostics)
                    decisions.append(NativeBlankPageDecision.evaluate(
                        nonwhiteRatio: statistics.nonwhiteRatio,
                        mean: statistics.mean,
                        options: options
                    ))
                }
            }

            var keptPages = decisions.indices.filter { !decisions[$0].isBlank }.map { $0 + 1 }
            var removed = decisions.count - keptPages.count
            if options.keepOne, keptPages.isEmpty, !decisions.isEmpty {
                keptPages = [1]
                removed -= 1
            }

            if removed > 0 {
                try Task.checkCancellation()
                let stagedPDF = stagingDirectory.appendingPathComponent("blank-removed.pdf")
                let rewriteResult: ProcessResult
                if keptPages.isEmpty {
                    let updateURL = stagingDirectory.appendingPathComponent(
                        "empty-pages-update.json"
                    )
                    try fileSystem.writeData(
                        document.emptyPagesUpdateData(),
                        to: updateURL
                    )
                    rewriteResult = try await successfulProcess(
                        executable: "qpdf",
                        arguments: [
                            options.pdfPath,
                            "--update-from-json=\(updateURL.path)",
                            stagedPDF.path,
                        ],
                        request: request
                    )
                } else {
                    rewriteResult = try await successfulProcess(
                        executable: "qpdf",
                        arguments: [
                            options.pdfPath,
                            "--pages", ".", pageSelection(keptPages),
                            "--", stagedPDF.path,
                        ],
                        request: request
                    )
                }
                diagnostics = joinedDiagnostics(diagnostics, rewriteResult.standardError)
                try Task.checkCancellation()
                try fileSystem.replaceFileAtomically(at: pdfURL, with: stagedPDF)
            }

            var output = ""
            if options.debug {
                for (index, decision) in decisions.enumerated() {
                    output += "page \(index + 1): \(decision.isBlank ? "blank" : "keep") "
                    output += "\(decision.detail)\n"
                }
            }
            output += "Removed \(removed) blank page\(removed == 1 ? "" : "s").\n"
            return ProcessResult(
                exitStatus: 0,
                standardOutput: output,
                standardError: diagnostics
            )
        } catch NativePageProcessingFailure.process(let result) {
            return result
        } catch NativePageProcessingFailure.diagnostic(let diagnostic) {
            return generatedFailure(status: 2, diagnostic: diagnostic)
        }
    }

    func cropPDFPages(
        options: NativeCropPDFPagesOptions,
        request: ProcessRequest
    ) async throws -> ProcessResult {
        do {
            let jsonResult = try await successfulProcess(
                executable: "qpdf",
                arguments: [
                    "--json-output=2",
                    "--json-stream-data=none",
                    "--json-key=pages",
                    options.pdfPath,
                ],
                request: request
            )
            let document: NativePDFJSONDocument
            do {
                document = try NativePDFJSONDocument(
                    data: Data(jsonResult.standardOutput.utf8)
                )
            } catch {
                throw NativePageProcessingFailure.diagnostic(
                    (error as? LocalizedError)?.errorDescription
                        ?? "qpdf returned malformed JSON v2 output."
                )
            }

            let pdfURL = resolvedURL(options.pdfPath, request: request, isDirectory: false)
            let stagingDirectory = try fileSystem.createTemporaryDirectory(
                in: pdfURL.deletingLastPathComponent()
            )
            defer { try? fileSystem.removeItemIfPresent(at: stagingDirectory) }

            var diagnostics = jsonResult.standardError
            var cropBoxes: [Int: NativePDFBox] = [:]
            var details: [(status: String, detail: String)] = []
            for index in document.pageReferences.indices {
                try Task.checkCancellation()
                let page = index + 1
                let extraction = try await extractLargestPageImage(
                    page: page,
                    pdfPath: options.pdfPath,
                    allowedReferences: try document.directImageReferences(
                        forPageAt: index
                    ),
                    prefix: "crop-page-\(paddedPageNumber(page))",
                    stagingDirectory: stagingDirectory,
                    request: request
                )
                diagnostics = joinedDiagnostics(diagnostics, extraction.diagnostics)
                guard let image = extraction.image else {
                    details.append(("skipped", "no page image"))
                    continue
                }

                let content = try await cropContentAnalysis(
                    image: image,
                    page: page,
                    options: options,
                    stagingDirectory: stagingDirectory,
                    request: request
                )
                diagnostics = joinedDiagnostics(diagnostics, content.diagnostics)
                guard let boundingBox = content.boundingBox else {
                    details.append((
                        "skipped",
                        "no content background=\(content.background)"
                    ))
                    continue
                }

                let decision = NativeCropPageDecision.evaluate(
                    image: image.dimensions,
                    boundingBox: boundingBox,
                    density: content.density,
                    options: options
                )
                var detail = "bbox=(\(boundingBox.left), \(boundingBox.top), "
                detail += "\(boundingBox.right), \(boundingBox.bottom)) "
                detail += formatted("width_ratio=%.3f ", decision.widthRatio)
                detail += formatted("height_ratio=%.3f ", decision.heightRatio)
                detail += formatted("density=%.3f ", content.density)
                detail += "background=\(content.background)"
                guard decision.shouldCrop else {
                    details.append(("kept", detail))
                    continue
                }

                let mediaBox = try document.mediaBox(forPageAt: index)
                let cropBox = NativeCropPageDecision.cropBox(
                    mediaBox: mediaBox,
                    image: image.dimensions,
                    boundingBox: boundingBox,
                    marginPoints: options.marginPoints
                )
                cropBoxes[index] = cropBox
                detail += " crop_box=\(formatPDFBox(cropBox))"
                details.append(("cropped", detail))
            }

            if !cropBoxes.isEmpty {
                try Task.checkCancellation()
                let updateURL = stagingDirectory.appendingPathComponent("crop-update.json")
                let stagedPDF = stagingDirectory.appendingPathComponent("cropped.pdf")
                let updateData = try document.updateData(
                    cropBoxes: cropBoxes,
                    keepOriginalBoxes: options.keepOriginalBoxes
                )
                try fileSystem.writeData(updateData, to: updateURL)
                let updateResult = try await successfulProcess(
                    executable: "qpdf",
                    arguments: [
                        options.pdfPath,
                        "--update-from-json=\(updateURL.path)",
                        stagedPDF.path,
                    ],
                    request: request
                )
                diagnostics = joinedDiagnostics(diagnostics, updateResult.standardError)
                try Task.checkCancellation()
                try fileSystem.replaceFileAtomically(at: pdfURL, with: stagedPDF)
            }

            var output = ""
            if options.debug {
                for (index, detail) in details.enumerated() {
                    output += "page \(index + 1): \(detail.status) \(detail.detail)\n"
                }
            }
            output += "Cropped \(cropBoxes.count) page\(cropBoxes.count == 1 ? "" : "s").\n"
            return ProcessResult(
                exitStatus: 0,
                standardOutput: output,
                standardError: diagnostics
            )
        } catch NativePageProcessingFailure.process(let result) {
            return result
        } catch NativePageProcessingFailure.diagnostic(let diagnostic) {
            return generatedFailure(status: 2, diagnostic: diagnostic)
        } catch let error as NativePDFJSONError {
            return generatedFailure(status: 2, diagnostic: error.localizedDescription)
        }
    }

    private func extractLargestPageImage(
        page: Int,
        pdfPath: String,
        allowedReferences: Set<String>,
        prefix: String,
        stagingDirectory: URL,
        request: ProcessRequest
    ) async throws -> (image: NativeExtractedPageImage?, diagnostics: String) {
        let listResult = try await successfulProcess(
            executable: "pdfimages",
            arguments: [
                "-f", String(page),
                "-l", String(page),
                "-list",
                pdfPath,
            ],
            request: request
        )
        let list: NativePDFImagesList
        do {
            list = try NativePDFImagesList(output: listResult.standardOutput)
        } catch {
            throw NativePageProcessingFailure.diagnostic(
                (error as? LocalizedError)?.errorDescription
                    ?? "pdfimages -list returned malformed output."
            )
        }
        let candidates = list.rows.filter {
            $0.page == page
                && $0.type == "image"
                && allowedReferences.contains($0.objectReference)
        }
        guard !candidates.isEmpty else {
            return (nil, listResult.standardError)
        }

        let root = stagingDirectory.appendingPathComponent(prefix)
        let extractionResult = try await successfulProcess(
            executable: "pdfimages",
            arguments: [
                "-f", String(page),
                "-l", String(page),
                "-png",
                pdfPath,
                root.path,
            ],
            request: request
        )
        let files = candidates.map { row in
            stagingDirectory.appendingPathComponent(
                "\(prefix)-\(String(format: "%03d", row.number)).png"
            )
        }
        guard files.allSatisfy({ fileSystem.itemExists(at: $0) }) else {
            throw NativePageProcessingFailure.diagnostic(
                "pdfimages did not produce every listed direct page image."
            )
        }
        guard let largest = try largestPNG(in: files),
              let dimensions = try fileSystem.pngDimensions(at: largest)
        else {
            throw NativePageProcessingFailure.diagnostic(
                "pdfimages produced a malformed direct page image."
            )
        }
        return (
            NativeExtractedPageImage(url: largest, dimensions: dimensions),
            joinedDiagnostics(listResult.standardError, extractionResult.standardError)
        )
    }

    private func blankStatistics(
        image: NativeExtractedPageImage,
        page: Int,
        whiteThreshold: Int,
        stagingDirectory: URL,
        request: ProcessRequest
    ) async throws -> (nonwhiteRatio: Double, mean: Double, diagnostics: String) {
        let name = "blank-analysis-\(paddedPageNumber(page))"
        let thumbnail = stagingDirectory.appendingPathComponent("\(name)-thumbnail.v")
        let grayscale = stagingDirectory.appendingPathComponent("\(name)-gray.v")
        let mask = stagingDirectory.appendingPathComponent("\(name)-mask.v")
        var diagnostics = ""

        diagnostics = joinedDiagnostics(diagnostics, try await successfulProcess(
            executable: "vips",
            arguments: [
                "thumbnail", image.url.path, thumbnail.path, "512",
                "--height", "512", "--size", "down",
            ],
            request: request
        ).standardError)
        diagnostics = joinedDiagnostics(diagnostics, try await successfulProcess(
            executable: "vips",
            arguments: ["colourspace", thumbnail.path, grayscale.path, "b-w"],
            request: request
        ).standardError)
        diagnostics = joinedDiagnostics(diagnostics, try await successfulProcess(
            executable: "vips",
            arguments: [
                "relational_const", grayscale.path, mask.path,
                "less", String(whiteThreshold),
            ],
            request: request
        ).standardError)
        let ratioResult = try await successfulProcess(
            executable: "vips",
            arguments: ["avg", mask.path],
            request: request
        )
        diagnostics = joinedDiagnostics(diagnostics, ratioResult.standardError)
        let meanResult = try await successfulProcess(
            executable: "vips",
            arguments: ["avg", grayscale.path],
            request: request
        )
        diagnostics = joinedDiagnostics(diagnostics, meanResult.standardError)

        return (
            try numericOutput(ratioResult, operation: "vips avg") / 255.0,
            try numericOutput(meanResult, operation: "vips avg"),
            diagnostics
        )
    }

    private func cropContentAnalysis(
        image: NativeExtractedPageImage,
        page: Int,
        options: NativeCropPDFPagesOptions,
        stagingDirectory: URL,
        request: ProcessRequest
    ) async throws -> (
        boundingBox: NativeImageBoundingBox?,
        background: Int,
        density: Double,
        diagnostics: String
    ) {
        guard options.borderPixels >= 0 else {
            throw NativePageProcessingFailure.diagnostic("border-px must not be negative.")
        }
        let width = Int(image.dimensions.width)
        let height = Int(image.dimensions.height)
        let border = min(options.borderPixels, max(1, width / 4), max(1, height / 4))
        guard border > 0 else {
            throw NativePageProcessingFailure.diagnostic("page image has invalid dimensions.")
        }

        let name = "crop-analysis-\(paddedPageNumber(page))"
        let sRGB = stagingDirectory.appendingPathComponent("\(name)-srgb.v")
        let rawRGB = stagingDirectory.appendingPathComponent("\(name)-rgb.raw")
        var diagnostics = try await successfulProcess(
            executable: "vips",
            arguments: ["colourspace", image.url.path, sRGB.path, "srgb"],
            request: request
        ).standardError
        diagnostics = joinedDiagnostics(diagnostics, try await successfulProcess(
            executable: "vips",
            arguments: ["rawsave", sRGB.path, rawRGB.path],
            request: request
        ).standardError)
        let analysis = try cropPixelAnalysis(
            rgb: fileSystem.readMappedData(at: rawRGB),
            width: width,
            height: height,
            border: border,
            backgroundDelta: options.backgroundDelta
        )
        return (
            analysis.boundingBox,
            analysis.background,
            analysis.density,
            diagnostics
        )
    }

    private func cropPixelAnalysis(
        rgb: Data,
        width: Int,
        height: Int,
        border: Int,
        backgroundDelta: Int
    ) throws -> (boundingBox: NativeImageBoundingBox?, background: Int, density: Double) {
        let pixelCount = width.multipliedReportingOverflow(by: height)
        guard !pixelCount.overflow, pixelCount.partialValue <= 100_000_000 else {
            throw NativePageProcessingFailure.diagnostic(
                "page image exceeds the native crop analysis pixel limit."
            )
        }
        let expectedByteCount = pixelCount.partialValue.multipliedReportingOverflow(by: 3)
        guard !expectedByteCount.overflow, rgb.count == expectedByteCount.partialValue
        else {
            throw NativePageProcessingFailure.diagnostic(
                "vips rawsave did not return three-channel 8-bit RGB data."
            )
        }

        return try rgb.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            var borderHistogram = Array(repeating: 0, count: 256)

            @inline(__always)
            func grayscale(x: Int, y: Int) -> Int {
                let offset = (y * width + x) * 3
                return (
                    19_595 * Int(bytes[offset])
                        + 38_470 * Int(bytes[offset + 1])
                        + 7_471 * Int(bytes[offset + 2])
                        + 32_768
                ) >> 16
            }

            func record(xRange: Range<Int>, yRange: Range<Int>) {
                for y in yRange {
                    for x in xRange {
                        borderHistogram[grayscale(x: x, y: y)] += 1
                    }
                }
            }

            record(xRange: 0..<width, yRange: 0..<border)
            record(xRange: 0..<width, yRange: (height - border)..<height)
            record(xRange: 0..<border, yRange: 0..<height)
            record(xRange: (width - border)..<width, yRange: 0..<height)
            let background = medianValue(in: borderHistogram)

            var minimumX = width
            var minimumY = height
            var maximumX = -1
            var maximumY = -1
            var contentPixels = 0
            for y in 0..<height {
                if y.isMultiple(of: 128) { try Task.checkCancellation() }
                for x in 0..<width {
                    if abs(grayscale(x: x, y: y) - background) > backgroundDelta {
                        minimumX = min(minimumX, x)
                        minimumY = min(minimumY, y)
                        maximumX = max(maximumX, x)
                        maximumY = max(maximumY, y)
                        contentPixels += 1
                    }
                }
            }
            guard maximumX >= minimumX, maximumY >= minimumY else {
                return (nil, background, 0)
            }

            let boundingBox = NativeImageBoundingBox(
                left: minimumX,
                top: minimumY,
                width: maximumX - minimumX + 1,
                height: maximumY - minimumY + 1
            )
            let density = Double(contentPixels)
                / Double(boundingBox.width * boundingBox.height)
            return (boundingBox, background, density)
        }
    }

    private func medianValue(in histogram: [Int]) -> Int {
        let total = histogram.reduce(0, +)

        func value(at rank: Int) -> Int {
            var cumulative = 0
            for (value, count) in histogram.enumerated() {
                cumulative += count
                if cumulative > rank { return value }
            }
            return 255
        }

        let lower = value(at: (total - 1) / 2)
        let upper = value(at: total / 2)
        return (lower + upper) / 2
    }

    private func successfulProcess(
        executable: String,
        arguments: [String],
        request: ProcessRequest
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let result = try await executor.execute(nativeRequest(
            executable: executable,
            arguments: arguments,
            inheriting: request
        ))
        guard result.succeeded else {
            throw NativePageProcessingFailure.process(result)
        }
        try Task.checkCancellation()
        return result
    }

    private func numericOutput(_ result: ProcessResult, operation: String) throws -> Double {
        let value = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(value), number.isFinite else {
            throw NativePageProcessingFailure.diagnostic(
                "\(operation) did not return a valid number."
            )
        }
        return number
    }

    private func pageSelection(_ pages: [Int]) -> String {
        guard let first = pages.first else { return "" }
        var ranges: [String] = []
        var start = first
        var previous = first
        for page in pages.dropFirst() {
            if page == previous + 1 {
                previous = page
                continue
            }
            ranges.append(start == previous ? String(start) : "\(start)-\(previous)")
            start = page
            previous = page
        }
        ranges.append(start == previous ? String(start) : "\(start)-\(previous)")
        return ranges.joined(separator: ",")
    }

    private func paddedPageNumber(_ page: Int) -> String {
        String(format: "%04d", page)
    }

    private func formatted(_ format: String, _ value: Double) -> String {
        String(
            format: format,
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    private func formatPDFBox(_ box: NativePDFBox) -> String {
        "[\(box.left), \(box.bottom), \(box.right), \(box.top)]"
    }
}
