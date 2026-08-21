import Foundation
import Hummingbird

public protocol OCRTextExtracting: Sendable {
    func extractText(from pdfURL: URL) async throws -> String
}

public enum OCRTextExtractionError: Error, Equatable, Sendable {
    case failed(String)
}

extension OCRTextExtractionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .failed(let diagnostic):
            diagnostic.isEmpty ? "Could not extract text from the OCR PDF." : diagnostic
        }
    }
}

/// Extracts the UTF-8 text layer produced by OCRmyPDF without rasterizing the PDF again.
public struct PDFToTextExtractor: OCRTextExtracting, Sendable {
    private let executor: any ProcessExecutor

    public init(executor: any ProcessExecutor = FoundationProcessExecutor()) {
        self.executor = executor
    }

    public func extractText(from pdfURL: URL) async throws -> String {
        let result = try await executor.execute(ProcessRequest(
            executable: "pdftotext",
            arguments: ["-layout", "-enc", "UTF-8", pdfURL.path, "-"]
        ))
        guard result.succeeded else {
            throw OCRTextExtractionError.failed(result.standardError)
        }
        return result.standardOutput
    }
}

private enum OCRAPIJobState: String, Encodable {
    case queued
    case processing
    case completed
    case failed
}

private struct OCRAPIJobLinks: Encodable {
    let status: String
    let searchablePDF: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case status
        case searchablePDF = "searchable_pdf"
        case text
    }
}

private struct OCRAPIJobResponse: Encodable {
    let id: String
    let state: OCRAPIJobState
    let filename: String
    let pageCount: Int?
    let queuedPages: Int
    let processingPages: Int
    let error: String?
    let links: OCRAPIJobLinks

    enum CodingKeys: String, CodingKey {
        case id
        case state
        case filename
        case pageCount = "page_count"
        case queuedPages = "queued_pages"
        case processingPages = "processing_pages"
        case error
        case links
    }
}

private struct OCRAPIPresetResponse: Encodable {
    let id: String
    let name: String
    let language: String
    let removeBlankPages: Bool
    let cropPages: Bool
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case language
        case removeBlankPages = "remove_blank_pages"
        case cropPages = "crop_pages"
        case isDefault = "is_default"
    }
}

private struct OCRAPIPresetsResponse: Encodable {
    let presets: [OCRAPIPresetResponse]
}

private struct OCRAPIErrorResponse: Encodable {
    let error: String
}

private struct OCRAPIResolvedJob {
    let id: String
    let sourceName: ScanOutputFileName
    let sourceURL: URL
    let outputName: ScanOutputFileName
    let outputURL: URL
}

private enum OCRAPISubmissionError: Error {
    case invalidFilename
    case conflict
    case unknownPreset
    case storage
    case preparation(String)
}

package func registerOCRAPIRoutes(
    _ router: Router<BasicRequestContext>,
    dependencies: ScannerServerDependencies
) {
    router.get("/api/v1/openapi.json") { _, _ -> Response in
        ocrAPIDataResponse(
            Data(ocrAPIOpenAPIDocument.utf8),
            contentType: "application/json; charset=utf-8"
        )
    }

    router.get("/api/v1/ocr/presets") { request, _ -> Response in
        guard ocrAPIAuthorized(request, environment: dependencies.environment) else {
            return ocrAPIUnauthorizedResponse()
        }
        do {
            let settings = try await dependencies.settingsStore.load()
            return ocrAPIJSONResponse(OCRAPIPresetsResponse(
                presets: settings.modes.map { mode in
                    OCRAPIPresetResponse(
                        id: mode.id,
                        name: mode.name,
                        language: mode.settings.language,
                        removeBlankPages: mode.settings.removeBlankPages,
                        cropPages: mode.settings.cropPages,
                        isDefault: mode.id == settings.defaultModeID
                    )
                }
            ))
        } catch {
            return ocrAPIJSONError("Could not load OCR presets.", status: .internalServerError)
        }
    }

    router.post("/api/v1/ocr/jobs") { request, _ -> Response in
        guard ocrAPIAuthorized(request, environment: dependencies.environment) else {
            return ocrAPIUnauthorizedResponse()
        }
        guard request.headers[.contentType]?.lowercased().hasPrefix("application/pdf") == true else {
            return ocrAPIJSONError("Only application/pdf uploads are supported.", status: .unsupportedMediaType)
        }

        let query = ocrAPIQueryValues(request.uri.query)
        let requestedName = query["filename"] ?? "ocr-request-\(UUID().uuidString.lowercased()).pdf"
        let data: Data
        do {
            let buffer = try await request.body.collect(
                upTo: ocrAPIUploadLimit(environment: dependencies.environment)
            )
            data = Data(buffer.readableBytesView)
        } catch {
            return ocrAPIJSONError(
                "PDF upload is too large.",
                status: HTTPResponse.Status(code: 413, reasonPhrase: "Content Too Large")
            )
        }
        guard data.count >= 5, data.prefix(5) == Data("%PDF-".utf8) else {
            return ocrAPIJSONError("Uploaded data is not a PDF.", status: .unsupportedMediaType)
        }

        do {
            let submission = try await submitOCRAPIJob(
                data: data,
                requestedName: requestedName,
                modeID: query["mode_id"],
                dependencies: dependencies
            )
            guard let response = await ocrAPIJobResponse(
                submission.job,
                pageCount: submission.pageCount,
                dependencies: dependencies
            ) else {
                return ocrAPIJSONError("OCR job disappeared during submission.", status: .conflict)
            }
            return ocrAPIJSONResponse(
                response,
                status: .accepted,
                additionalHeaders: [.location: response.links.status]
            )
        } catch OCRAPISubmissionError.invalidFilename {
            return ocrAPIJSONError("Invalid PDF filename.", status: .badRequest)
        } catch OCRAPISubmissionError.conflict {
            return ocrAPIJSONError(
                "A source or OCR file with that name already exists.",
                status: .conflict
            )
        } catch OCRAPISubmissionError.unknownPreset {
            return ocrAPIJSONError("Unknown OCR preset.", status: .badRequest)
        } catch OCRAPISubmissionError.storage {
            return ocrAPIJSONError("Could not store the PDF.", status: .conflict)
        } catch OCRAPISubmissionError.preparation(let diagnostic) {
            return ocrAPIJSONError(
                "Could not prepare PDF for OCR: \(diagnostic)",
                status: HTTPResponse.Status(code: 422, reasonPhrase: "Unprocessable Content")
            )
        } catch {
            return ocrAPIJSONError("Could not submit OCR job.", status: .internalServerError)
        }
    }

    router.get("/api/v1/ocr/jobs/:job") { request, context -> Response in
        guard ocrAPIAuthorized(request, environment: dependencies.environment) else {
            return ocrAPIUnauthorizedResponse()
        }
        guard let job = ocrAPIJob(context: context, dependencies: dependencies),
              let response = await ocrAPIJobResponse(job, dependencies: dependencies) else {
            return ocrAPIJSONError("OCR job not found.", status: .notFound)
        }
        return ocrAPIJSONResponse(response)
    }

    router.get("/api/v1/ocr/jobs/:job/document") { request, context -> Response in
        guard ocrAPIAuthorized(request, environment: dependencies.environment) else {
            return ocrAPIUnauthorizedResponse()
        }
        guard let job = ocrAPIJob(context: context, dependencies: dependencies) else {
            return ocrAPIJSONError("OCR job not found.", status: .notFound)
        }
        guard let resource = await dependencies.documentCollection.resource(
            named: job.outputName.rawValue
        ) else {
            return ocrAPIJSONError("OCR output is not ready.", status: .conflict)
        }
        return ocrAPIDataResponse(
            resource.data,
            contentType: resource.contentType,
            additionalHeaders: [
                .contentDisposition: "attachment; filename=\(resource.fileName.rawValue)",
                .cacheControl: "no-store",
            ]
        )
    }

    router.get("/api/v1/ocr/jobs/:job/text") { request, context -> Response in
        guard ocrAPIAuthorized(request, environment: dependencies.environment) else {
            return ocrAPIUnauthorizedResponse()
        }
        guard let job = ocrAPIJob(context: context, dependencies: dependencies) else {
            return ocrAPIJSONError("OCR job not found.", status: .notFound)
        }
        guard let outputURL = try? dependencies.outputPathResolver.resolve(job.outputName) else {
            return ocrAPIJSONError("OCR output is not ready.", status: .conflict)
        }
        do {
            let text = try await dependencies.ocrTextExtractor.extractText(from: outputURL)
            return ocrAPIDataResponse(
                Data(text.utf8),
                contentType: "text/plain; charset=utf-8",
                additionalHeaders: [.cacheControl: "no-store"]
            )
        } catch {
            return ocrAPIJSONError(
                "Could not extract OCR text: \(error.localizedDescription)",
                status: .internalServerError
            )
        }
    }

    router.delete("/api/v1/ocr/jobs/:job") { request, context -> Response in
        guard ocrAPIAuthorized(request, environment: dependencies.environment) else {
            return ocrAPIUnauthorizedResponse()
        }
        guard let job = ocrAPIJob(context: context, dependencies: dependencies),
              (try? dependencies.outputPathResolver.resolve(job.sourceName)) != nil
                || (try? dependencies.outputPathResolver.resolve(job.outputName)) != nil else {
            return ocrAPIJSONError("OCR job not found.", status: .notFound)
        }
        await dependencies.documentCollection.remove(named: job.sourceName.rawValue)
        await dependencies.documentCollection.remove(named: job.outputName.rawValue)
        return Response(status: .noContent)
    }
}

private func submitOCRAPIJob(
    data: Data,
    requestedName: String,
    modeID: String?,
    dependencies: ScannerServerDependencies
) async throws -> (job: OCRAPIResolvedJob, pageCount: Int) {
    let sourceName: ScanOutputFileName
    do {
        sourceName = try ocrAPIImportedPDFFileName(requestedName)
    } catch {
        throw OCRAPISubmissionError.invalidFilename
    }
    let id = ocrAPIEncodeJobID(sourceName.rawValue)
    guard let job = ocrAPIResolvedJob(id: id, sourceName: sourceName, dependencies: dependencies) else {
        throw OCRAPISubmissionError.invalidFilename
    }
    guard !FileManager.default.fileExists(atPath: job.sourceURL.path),
          !FileManager.default.fileExists(atPath: job.outputURL.path) else {
        throw OCRAPISubmissionError.conflict
    }

    let settings = try await dependencies.settingsStore.load()
    let mode: ScanMode
    if let modeID {
        guard let selected = settings.mode(id: modeID) else {
            throw OCRAPISubmissionError.unknownPreset
        }
        mode = selected
    } else {
        mode = settings.defaultMode
    }

    let stagingURL = dependencies.outputPathResolver.outputDirectory.appendingPathComponent(
        ".ocr-api-upload.\(UUID().uuidString)",
        isDirectory: false
    )
    defer { try? FileManager.default.removeItem(at: stagingURL) }
    do {
        try data.write(to: stagingURL, options: .atomic)
        try FoundationNativeScanFileSystem().placeFileExclusively(
            at: stagingURL,
            destination: job.sourceURL
        )
    } catch {
        throw OCRAPISubmissionError.storage
    }

    var environment = dependencies.environment
    environment.merge(settings.environment(for: mode, trigger: "ocr-api")) {
        _, selected in selected
    }
    environment["SCAN_FORMAT"] = "pdf"
    environment["SCAN_PAGE_MODE"] = "multi"
    environment["SCAN_OCR_ENABLED"] = "true"
    let workDirectory = dependencies.outputPathResolver.outputDirectory.appendingPathComponent(
        ".ocr-api-work.\(UUID().uuidString)",
        isDirectory: true
    )
    do {
        let pageCount = try await dependencies.ocrQueue.enqueueImportedPDF(
            ImportedPDFOCRRequest(
                sourcePath: job.sourceURL.path,
                documentName: sourceName.rawValue,
                finalOutputPath: job.outputURL.path,
                workDirectory: workDirectory,
                environment: environment,
                removeBlankPages: mode.settings.removeBlankPages,
                cropPages: mode.settings.cropPages,
                replaceExistingText: true
            )
        )
        await dependencies.webUpdates.notify()
        return (job, pageCount)
    } catch {
        try? FileManager.default.removeItem(at: job.sourceURL)
        throw OCRAPISubmissionError.preparation(error.localizedDescription)
    }
}

private func ocrAPIJobResponse(
    _ job: OCRAPIResolvedJob,
    pageCount: Int? = nil,
    dependencies: ScannerServerDependencies
) async -> OCRAPIJobResponse? {
    let sourceExists = (try? dependencies.outputPathResolver.resolve(job.sourceName)) != nil
    let outputExists = (try? dependencies.outputPathResolver.resolve(job.outputName)) != nil
    guard sourceExists || outputExists else { return nil }

    let queue = await dependencies.ocrQueue.state
    let waiting = queue.waitingJobs.filter { $0.documentName == job.sourceName.rawValue }
    let processing = (queue.processingJobs + queue.finalizingJobs).filter {
        $0.documentName == job.sourceName.rawValue
    }
    let state: OCRAPIJobState
    let diagnostic: String?
    if outputExists {
        state = .completed
        diagnostic = nil
    } else if !processing.isEmpty {
        state = .processing
        diagnostic = nil
    } else if !waiting.isEmpty {
        state = .queued
        diagnostic = nil
    } else {
        state = .failed
        diagnostic = "OCR processing did not produce a searchable PDF. The source PDF was preserved."
    }

    return OCRAPIJobResponse(
        id: job.id,
        state: state,
        filename: job.sourceName.rawValue,
        pageCount: pageCount,
        queuedPages: waiting.count,
        processingPages: processing.count,
        error: diagnostic,
        links: OCRAPIJobLinks(
            status: "/api/v1/ocr/jobs/\(job.id)",
            searchablePDF: "/api/v1/ocr/jobs/\(job.id)/document",
            text: "/api/v1/ocr/jobs/\(job.id)/text"
        )
    )
}

private func ocrAPIJob(
    context: some RequestContext,
    dependencies: ScannerServerDependencies
) -> OCRAPIResolvedJob? {
    guard let rawID = context.parameters.get("job")?.removingPercentEncoding,
          let filename = ocrAPIDecodeJobID(rawID),
          let sourceName = try? ocrAPIImportedPDFFileName(filename) else { return nil }
    return ocrAPIResolvedJob(id: rawID, sourceName: sourceName, dependencies: dependencies)
}

private func ocrAPIResolvedJob(
    id: String,
    sourceName: ScanOutputFileName,
    dependencies: ScannerServerDependencies
) -> OCRAPIResolvedJob? {
    let sourceURL = dependencies.outputPathResolver.outputDirectory.appendingPathComponent(
        sourceName.rawValue,
        isDirectory: false
    )
    guard let outputPath = OCRInputPath.outputPath(for: sourceURL.path),
          let outputName = try? ScanOutputFileName(
            rawValue: URL(fileURLWithPath: outputPath).lastPathComponent
          ) else { return nil }
    return OCRAPIResolvedJob(
        id: id,
        sourceName: sourceName,
        sourceURL: sourceURL,
        outputName: outputName,
        outputURL: URL(fileURLWithPath: outputPath)
    )
}

private func ocrAPIImportedPDFFileName(_ requestedName: String) throws -> ScanOutputFileName {
    let validated = try ScanOutputFileName(rawValue: requestedName)
    guard URL(fileURLWithPath: validated.rawValue).pathExtension.lowercased() == "pdf",
          !validated.rawValue.lowercased().hasSuffix(".ocr.pdf") else {
        throw ScanOutputFileNameError.unsupportedExtension(
            URL(fileURLWithPath: validated.rawValue).pathExtension
        )
    }
    let stem = String(validated.rawValue.dropLast(4))
    guard !stem.isEmpty else {
        throw ScanOutputFileNameError.invalidComponent(requestedName)
    }
    return try ScanOutputFileName(rawValue: "\(stem).pdf")
}

private func ocrAPIEncodeJobID(_ filename: String) -> String {
    Data(filename.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func ocrAPIDecodeJobID(_ id: String) -> String? {
    var base64 = id.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 {
        base64 += String(repeating: "=", count: 4 - remainder)
    }
    guard let data = Data(base64Encoded: base64) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func ocrAPIQueryValues(_ query: String?) -> [String: String] {
    guard let query else { return [:] }
    var components = URLComponents()
    components.query = query
    var values: [String: String] = [:]
    for item in components.queryItems ?? [] where values[item.name] == nil {
        values[item.name] = item.value?.removingPercentEncoding ?? item.value
    }
    return values
}

private func ocrAPIUploadLimit(environment: [String: String]) -> Int {
    let defaultLimit = 1_073_741_824
    guard let value = environment["SCAN_PDF_UPLOAD_MAX_BYTES"],
          let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
          parsed > 0 else { return defaultLimit }
    return parsed
}

private func ocrAPIAuthorized(_ request: Request, environment: [String: String]) -> Bool {
    guard let configured = environment["SCAN_OCR_API_TOKEN"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !configured.isEmpty else { return true }
    guard let authorization = request.headers[.authorization],
          authorization.lowercased().hasPrefix("bearer ") else { return false }
    let supplied = authorization.dropFirst("bearer ".count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return ocrAPISecureEqual(supplied, configured)
}

private func ocrAPISecureEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    var difference = UInt(left.count ^ right.count)
    for index in 0..<max(left.count, right.count) {
        let leftByte = index < left.count ? left[index] : 0
        let rightByte = index < right.count ? right[index] : 0
        difference |= UInt(leftByte ^ rightByte)
    }
    return difference == 0
}

private func ocrAPIUnauthorizedResponse() -> Response {
    ocrAPIJSONError(
        "A valid bearer token is required.",
        status: .unauthorized,
        additionalHeaders: [.wwwAuthenticate: "Bearer"]
    )
}

private func ocrAPIDataResponse(
    _ data: Data,
    status: HTTPResponse.Status = .ok,
    contentType: String,
    additionalHeaders: HTTPFields = [:]
) -> Response {
    let buffer = ByteBuffer(bytes: data)
    var headers = additionalHeaders
    headers[.contentType] = contentType
    headers[.contentLength] = "\(buffer.readableBytes)"
    return Response(status: status, headers: headers, body: .init(byteBuffer: buffer))
}

private func ocrAPIJSONResponse<Value: Encodable>(
    _ value: Value,
    status: HTTPResponse.Status = .ok,
    additionalHeaders: HTTPFields = [:]
) -> Response {
    do {
        var headers = additionalHeaders
        if headers[.cacheControl] == nil {
            headers[.cacheControl] = "no-store"
        }
        return ocrAPIDataResponse(
            try JSONEncoder().encode(value),
            status: status,
            contentType: "application/json; charset=utf-8",
            additionalHeaders: headers
        )
    } catch {
        return ocrAPIDataResponse(
            Data(#"{"error":"Could not encode response."}"#.utf8),
            status: .internalServerError,
            contentType: "application/json; charset=utf-8"
        )
    }
}

private func ocrAPIJSONError(
    _ message: String,
    status: HTTPResponse.Status,
    additionalHeaders: HTTPFields = [:]
) -> Response {
    ocrAPIJSONResponse(
        OCRAPIErrorResponse(error: message),
        status: status,
        additionalHeaders: additionalHeaders
    )
}

private let ocrAPIOpenAPIDocument = #"""
{
  "openapi": "3.1.0",
  "info": {
    "title": "scannerserver OCR API",
    "version": "1.0.0",
    "description": "Submit PDFs to the existing scannerserver OCR queue and retrieve searchable PDFs or UTF-8 text. Pages are rasterized so existing OCR or text layers are discarded and replaced by fresh OCR."
  },
  "paths": {
    "/api/v1/ocr/presets": {
      "get": {
        "operationId": "listOCRPresets",
        "summary": "List OCR presets",
        "responses": {"200": {"description": "Available OCR presets", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Presets"}}}}}
      }
    },
    "/api/v1/ocr/jobs": {
      "post": {
        "operationId": "createOCRJob",
        "parameters": [
          {"name": "filename", "in": "query", "description": "Visible PDF filename; generated when omitted", "schema": {"type": "string"}},
          {"name": "mode_id", "in": "query", "description": "OCR preset ID; the default preset is used when omitted", "schema": {"type": "string"}}
        ],
        "requestBody": {"required": true, "description": "PDF input; pages are rasterized and any existing OCR or text layer is discarded and replaced", "content": {"application/pdf": {"schema": {"type": "string", "format": "binary"}}}},
        "responses": {"202": {"description": "OCR job accepted", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Job"}}}}}
      }
    },
    "/api/v1/ocr/jobs/{job}": {
      "get": {
        "operationId": "getOCRJob",
        "parameters": [{"name": "job", "in": "path", "required": true, "schema": {"type": "string"}}],
        "responses": {"200": {"description": "OCR job status", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Job"}}}}, "404": {"description": "Job not found"}}
      },
      "delete": {
        "operationId": "cancelAndDeleteOCRJob",
        "parameters": [{"name": "job", "in": "path", "required": true, "schema": {"type": "string"}}],
        "responses": {"204": {"description": "Job cancelled and files removed"}}
      }
    },
    "/api/v1/ocr/jobs/{job}/document": {
      "get": {
        "operationId": "downloadSearchablePDF",
        "parameters": [{"name": "job", "in": "path", "required": true, "schema": {"type": "string"}}],
        "responses": {"200": {"description": "Searchable PDF", "content": {"application/pdf": {"schema": {"type": "string", "format": "binary"}}}}, "409": {"description": "OCR is not complete"}}
      }
    },
    "/api/v1/ocr/jobs/{job}/text": {
      "get": {
        "operationId": "downloadOCRText",
        "parameters": [{"name": "job", "in": "path", "required": true, "schema": {"type": "string"}}],
        "responses": {"200": {"description": "UTF-8 OCR text", "content": {"text/plain": {"schema": {"type": "string"}}}}, "409": {"description": "OCR is not complete"}}
      }
    }
  },
  "components": {
    "securitySchemes": {"bearerAuth": {"type": "http", "scheme": "bearer"}},
    "schemas": {
      "JobLinks": {
        "type": "object",
        "required": ["status", "searchable_pdf", "text"],
        "properties": {
          "status": {"type": "string"},
          "searchable_pdf": {"type": "string"},
          "text": {"type": "string"}
        }
      },
      "Job": {
        "type": "object",
        "required": ["id", "state", "filename", "queued_pages", "processing_pages", "links"],
        "properties": {
          "id": {"type": "string"},
          "state": {"type": "string", "enum": ["queued", "processing", "completed", "failed"]},
          "filename": {"type": "string"},
          "page_count": {"type": ["integer", "null"], "minimum": 1},
          "queued_pages": {"type": "integer", "minimum": 0},
          "processing_pages": {"type": "integer", "minimum": 0},
          "error": {"type": ["string", "null"]},
          "links": {"$ref": "#/components/schemas/JobLinks"}
        }
      },
      "Preset": {
        "type": "object",
        "required": ["id", "name", "language", "remove_blank_pages", "crop_pages", "is_default"],
        "properties": {
          "id": {"type": "string"},
          "name": {"type": "string"},
          "language": {"type": "string"},
          "remove_blank_pages": {"type": "boolean"},
          "crop_pages": {"type": "boolean"},
          "is_default": {"type": "boolean"}
        }
      },
      "Presets": {
        "type": "object",
        "required": ["presets"],
        "properties": {"presets": {"type": "array", "items": {"$ref": "#/components/schemas/Preset"}}}
      }
    }
  },
  "security": [{"bearerAuth": []}, {}]
}
"""#
