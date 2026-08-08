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
                    boundingBoxKind: content.boundingBoxKind,
                    options: options
                )
                var detail = "bbox=(\(boundingBox.left), \(boundingBox.top), "
                detail += "\(boundingBox.right), \(boundingBox.bottom)) "
                detail += formatted("width_ratio=%.3f ", decision.widthRatio)
                detail += formatted("height_ratio=%.3f ", decision.heightRatio)
                detail += formatted("density=%.3f ", content.density)
                detail += "background=\(content.background) "
                let detection = content.boundingBoxKind == .pageEdges
                    ? "page-edges"
                    : "content"
                detail += "detection=\(detection)"
                guard decision.shouldCrop else {
                    details.append(("kept", detail))
                    continue
                }

                let mediaBox = try document.mediaBox(forPageAt: index)
                let cropBox = NativeCropPageDecision.cropBox(
                    mediaBox: mediaBox,
                    image: image.dimensions,
                    boundingBox: boundingBox,
                    marginPoints: content.boundingBoxKind == .pageEdges
                        ? 0
                        : options.marginPoints
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
        let grayscale = stagingDirectory.appendingPathComponent("\(name)-gray.v")
        let rawGrayscale = stagingDirectory.appendingPathComponent("\(name)-gray.raw")
        var diagnostics = try await successfulProcess(
            executable: "vips",
            arguments: ["colourspace", image.url.path, grayscale.path, "b-w"],
            request: request
        ).standardError
        diagnostics = joinedDiagnostics(diagnostics, try await successfulProcess(
            executable: "vips",
            arguments: ["rawsave", grayscale.path, rawGrayscale.path],
            request: request
        ).standardError)
        let analysis = try blankPixelAnalysis(
            grayscale: fileSystem.readMappedData(at: rawGrayscale),
            width: Int(image.dimensions.width),
            height: Int(image.dimensions.height),
            whiteThreshold: whiteThreshold
        )

        return (
            analysis.nonwhiteRatio,
            analysis.mean,
            diagnostics
        )
    }

    func blankPixelAnalysis(
        grayscale: Data,
        width: Int,
        height: Int,
        whiteThreshold: Int
    ) throws -> NativeBlankPixelAnalysis {
        let pixelCount = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0,
              !pixelCount.overflow,
              pixelCount.partialValue <= 100_000_000,
              grayscale.count == pixelCount.partialValue
        else {
            throw NativePageProcessingFailure.diagnostic(
                "vips rawsave did not return valid single-channel 8-bit grayscale data."
            )
        }

        // ScanSnap images include a dark scanner border and edge shadows. Ignore the outer
        // three percent so those artifacts cannot turn an otherwise blank sheet into content.
        let insetX = width >= 16 ? max(1, width * 3 / 100) : 0
        let insetY = height >= 16 ? max(1, height * 3 / 100) : 0
        let xRange = insetX..<(width - insetX)
        let yRange = insetY..<(height - insetY)
        guard !xRange.isEmpty, !yRange.isEmpty else {
            throw NativePageProcessingFailure.diagnostic(
                "page image is too small for blank-page analysis."
            )
        }

        let xStride = max(1, xRange.count / 512)
        let yStride = max(1, yRange.count / 512)
        return grayscale.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            var samples = 0
            var nonwhite = 0
            var sum: Int64 = 0
            for y in stride(from: yRange.lowerBound, to: yRange.upperBound, by: yStride) {
                for x in stride(from: xRange.lowerBound, to: xRange.upperBound, by: xStride) {
                    let value = Int(bytes[y * width + x])
                    samples += 1
                    sum += Int64(value)
                    if value < whiteThreshold { nonwhite += 1 }
                }
            }
            return NativeBlankPixelAnalysis(
                nonwhiteRatio: Double(nonwhite) / Double(samples),
                mean: Double(sum) / Double(samples)
            )
        }
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
        boundingBoxKind: NativeCropBoundingBoxKind,
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
            analysis.boundingBoxKind,
            diagnostics
        )
    }

    func cropPixelAnalysis(
        rgb: Data,
        width: Int,
        height: Int,
        border: Int,
        backgroundDelta: Int
    ) throws -> NativeCropPixelAnalysis {
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
                return NativeCropPixelAnalysis(
                    boundingBox: nil,
                    background: background,
                    density: 0,
                    boundingBoxKind: .content
                )
            }

            var boundingBox = NativeImageBoundingBox(
                left: minimumX,
                top: minimumY,
                width: maximumX - minimumX + 1,
                height: maximumY - minimumY + 1
            )
            let density = Double(contentPixels)
                / Double(boundingBox.width * boundingBox.height)
            var boundingBoxKind = NativeCropBoundingBoxKind.content
            let reachesEveryEdge = boundingBox.left <= 1
                && boundingBox.top <= 1
                && boundingBox.right >= width - 1
                && boundingBox.bottom >= height - 1
            let coversAlmostEntireImage = boundingBox.width >= width * 9 / 10
                && boundingBox.height >= height * 9 / 10
            // Paper texture can pollute the content mask through the scanner border.
            // In that case, recover the physical sheet edges from whole-row/column medians.
            if (reachesEveryEdge || coversAlmostEntireImage),
               let pageBoundingBox = try detectedPageBoundingBox(
                   grayscale: grayscale,
                   width: width,
                   height: height,
                   border: border
               )
            {
                boundingBox = pageBoundingBox
                boundingBoxKind = .pageEdges
            }
            return NativeCropPixelAnalysis(
                boundingBox: boundingBox,
                background: background,
                density: density,
                boundingBoxKind: boundingBoxKind
            )
        }
    }

    private func detectedPageBoundingBox(
        grayscale: (_ x: Int, _ y: Int) -> Int,
        width: Int,
        height: Int,
        border: Int
    ) throws -> NativeImageBoundingBox? {
        guard width >= 16, height >= 16 else { return nil }
        // A bounded sample keeps full-resolution scans inexpensive while medians reject text.
        let rowStride = max(1, height / 512)
        let columnStride = max(1, width / 512)
        let columnMedians = try medianGrayscaleProfile(count: width) { column, histogram in
            for row in stride(from: 0, to: height, by: rowStride) {
                histogram[grayscale(column, row)] += 1
            }
        }
        let rowMedians = try medianGrayscaleProfile(count: height) { row, histogram in
            for column in stride(from: 0, to: width, by: columnStride) {
                histogram[grayscale(column, row)] += 1
            }
        }

        guard let left = pageEdge(
            in: columnMedians,
            searchRange: edgeSearchRange(count: width, border: border, leading: true),
            direction: 1
        ), let right = pageEdge(
            in: columnMedians,
            searchRange: edgeSearchRange(count: width, border: border, leading: false),
            direction: -1
        ), let top = pageEdge(
            in: rowMedians,
            searchRange: edgeSearchRange(count: height, border: border, leading: true),
            direction: 1
        ), let bottom = pageEdge(
            in: rowMedians,
            searchRange: edgeSearchRange(count: height, border: border, leading: false),
            direction: -1
        ), right > left, bottom > top,
              right - left >= width / 2,
              bottom - top >= height / 2
        else {
            return nil
        }
        return NativeImageBoundingBox(
            left: left,
            top: top,
            width: right - left,
            height: bottom - top
        )
    }

    private func medianGrayscaleProfile(
        count: Int,
        record: (_ index: Int, _ histogram: inout [Int]) -> Void
    ) throws -> [Int] {
        var profile = [Int](repeating: 0, count: count)
        var histogram = [Int](repeating: 0, count: 256)
        for index in 0..<count {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            histogram.withUnsafeMutableBufferPointer { buffer in
                buffer.initialize(repeating: 0)
            }
            record(index, &histogram)
            profile[index] = medianValue(in: histogram)
        }
        return profile
    }

    private func edgeSearchRange(count: Int, border: Int, leading: Bool) -> Range<Int> {
        let outerExclusion = min(8, max(2, count / 1000))
        let depth = min(count / 4, max(border * 2, outerExclusion + 2))
        if leading {
            return outerExclusion..<depth
        }
        return (count - depth)..<(count - outerExclusion)
    }

    private func pageEdge(
        in profile: [Int],
        searchRange: Range<Int>,
        direction: Int
    ) -> Int? {
        var bestCoordinate: Int?
        var bestStrength = 1
        for coordinate in searchRange where coordinate > 0 && coordinate < profile.count {
            let strength = direction * (profile[coordinate] - profile[coordinate - 1])
            if strength > bestStrength {
                bestStrength = strength
                bestCoordinate = coordinate
            }
        }
        return bestCoordinate
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
