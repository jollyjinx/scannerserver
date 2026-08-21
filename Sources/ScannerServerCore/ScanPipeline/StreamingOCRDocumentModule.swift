import Foundation

package struct StreamingOCRDocumentID: Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package enum StreamingOCRFailurePolicy: Equatable, Sendable {
    case sourceAlreadyPublished
    case preserveImportedSource(URL)
    case publishRawOnFailure(source: URL, destination: URL)
}

package struct StreamingOCRDocumentRequest: Equatable, Sendable {
    package let documentName: String
    package let finalOutputURL: URL
    package let workDirectory: URL
    package let environment: [String: String]
    package let removeBlankPages: Bool
    package let cropPages: Bool
    package let replaceExistingText: Bool
    package let failurePolicy: StreamingOCRFailurePolicy

    package init(
        documentName: String,
        finalOutputURL: URL,
        workDirectory: URL,
        environment: [String: String],
        removeBlankPages: Bool,
        cropPages: Bool,
        replaceExistingText: Bool = false,
        failurePolicy: StreamingOCRFailurePolicy
    ) {
        self.documentName = documentName
        self.finalOutputURL = finalOutputURL
        self.workDirectory = workDirectory
        self.environment = environment
        self.removeBlankPages = removeBlankPages
        self.cropPages = cropPages
        self.replaceExistingText = replaceExistingText
        self.failurePolicy = failurePolicy
    }
}

package struct StreamingOCRPageReservation: Hashable, Sendable {
    package let documentID: StreamingOCRDocumentID
    package let pageNumber: Int
    package let inputURL: URL
    fileprivate let generation: UUID
}

package struct StreamingOCRPageWork: Sendable {
    package let reservation: StreamingOCRPageReservation
    package let environment: [String: String]
    package let removeBlankPages: Bool
    package let cropPages: Bool
    package let replaceExistingText: Bool
    package let metadata: OCRWorkerJobMetadata
}

package enum StreamingOCRPageOutcome: Equatable, Sendable {
    case succeeded(outputURL: URL)
    case failed(status: String, diagnostic: String)
    case cancelled
}

package enum StreamingOCRTerminationReason: Equatable, Sendable {
    case failed(String)
    case cancelled
}

package struct StreamingOCRCancellationHandle: Hashable, Sendable {
    fileprivate let rawValue: UUID
}

package struct StreamingOCRTerminationResult: Equatable, Sendable {
    package let workspaceRemoved: Bool
    package let publishedFallbackPath: String?
    package let diagnostic: String
}

package struct StreamingOCRDocumentCompletion: Equatable, Sendable {
    package let documentID: StreamingOCRDocumentID
    package let finished: Date
    package let status: String
    package let output: String
    package let error: String
}

package struct StreamingOCRDocumentModuleState: Equatable, Sendable {
    package let activeDocumentIDs: Set<StreamingOCRDocumentID>
    package let finalizingJobs: [OCRQueueJobSnapshot]
    package let latestCompletion: StreamingOCRDocumentCompletion?
}

/// Owns the ordering-sensitive lifecycle and publication policy for page-oriented OCR documents.
package actor StreamingOCRDocumentModule {
    package typealias PageYield = @Sendable (StreamingOCRPageWork) async throws -> Void
    package typealias CancellationDispatch = @Sendable (StreamingOCRDocumentID) async -> Void

    private enum PageState: Sendable {
        case reserved
        case succeeded(URL)
        case failed(status: String, diagnostic: String)
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .reserved: false
            case .succeeded, .failed, .cancelled: true
            }
        }
    }

    private struct Page: Sendable {
        let reservation: StreamingOCRPageReservation
        var state: PageState
    }

    private enum DocumentPhase: Sendable {
        case accepting
        case sealed(expectedPageCount: Int)
        case finalizing(token: UUID, started: Date)
    }

    private struct Document: Sendable {
        let request: StreamingOCRDocumentRequest
        var pages: [Int: Page]
        var phase: DocumentPhase
    }

    private struct FinalizationPlan: Sendable {
        let request: StreamingOCRDocumentRequest
        let pages: [Page]
    }

    private enum FinalizationResult: Sendable {
        case staged(URL)
        case failed(String)
        case cancelled
    }

    private struct Finalization: Sendable {
        let token: UUID
        let task: Task<FinalizationResult, Never>
    }

    private struct PendingTermination: Sendable {
        let documentID: StreamingOCRDocumentID
        let document: Document
        let reason: StreamingOCRTerminationReason
        let finalizationTask: Task<FinalizationResult, Never>?
    }

    private let documentExecutor: any ProcessExecutor
    private let pageWriter: any StreamingPagePDFWriting
    private let fileSystem: any NativeScanFileSystem
    private let webUpdates: WebUpdateNotifier
    private var documents: [StreamingOCRDocumentID: Document] = [:]
    private var finalizations: [StreamingOCRDocumentID: Finalization] = [:]
    private var pendingTerminations: [UUID: PendingTermination] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var latestCompletion: StreamingOCRDocumentCompletion?

    package init(
        documentExecutor: any ProcessExecutor,
        pageWriter: any StreamingPagePDFWriting = ScanSnapPDFWriter(),
        fileSystem: any NativeScanFileSystem = FoundationNativeScanFileSystem(),
        webUpdates: WebUpdateNotifier = WebUpdateNotifier()
    ) {
        self.documentExecutor = documentExecutor
        self.pageWriter = pageWriter
        self.fileSystem = fileSystem
        self.webUpdates = webUpdates
    }

    package var state: StreamingOCRDocumentModuleState {
        let finalizingJobs = documents.values.compactMap { document -> OCRQueueJobSnapshot? in
            guard case .finalizing(_, let started) = document.phase else { return nil }
            return OCRQueueJobSnapshot(
                input: document.request.finalOutputURL.path,
                documentName: document.request.documentName,
                pageNumber: nil,
                operations: ["assemble OCR pages", "publish searchable PDF"],
                phase: .finalizing,
                started: started
            )
        }
        .sorted { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) }
        let activeDocumentIDs = Set(documents.keys).union(
            pendingTerminations.values.map(\.documentID)
        )
        return StreamingOCRDocumentModuleState(
            activeDocumentIDs: activeDocumentIDs,
            finalizingJobs: finalizingJobs,
            latestCompletion: latestCompletion
        )
    }

    package func begin(_ request: StreamingOCRDocumentRequest) -> StreamingOCRDocumentID {
        let documentID = StreamingOCRDocumentID()
        documents[documentID] = Document(request: request, pages: [:], phase: .accepting)
        return documentID
    }

    package func reserveJPEGPage(
        documentID: StreamingOCRDocumentID,
        page: ScanSnapAcquiredPage
    ) async throws -> StreamingOCRPageWork {
        let inputURL = try reservePage(documentID: documentID, pageNumber: page.pageNumber)
        let reservation = try reservation(
            documentID: documentID,
            pageNumber: page.pageNumber,
            inputURL: inputURL
        )
        do {
            try await pageWriter.write(pages: [page.jpegData], to: inputURL)
            try Task.checkCancellation()
        } catch {
            rollback(reservation)
            try? fileSystem.removeItemIfPresent(at: inputURL)
            throw error
        }
        guard isCurrent(reservation) else {
            try? fileSystem.removeItemIfPresent(at: inputURL)
            throw StreamingScanError.unknownBatch
        }
        await webUpdates.notify()
        return work(for: reservation)
    }

    package func reservePreparedPDFPage(
        documentID: StreamingOCRDocumentID,
        pageNumber: Int,
        inputURL: URL
    ) throws -> StreamingOCRPageWork {
        let reservedURL = try reservePage(
            documentID: documentID,
            pageNumber: pageNumber,
            preparedInputURL: inputURL
        )
        let reservation = try reservation(
            documentID: documentID,
            pageNumber: pageNumber,
            inputURL: reservedURL
        )
        return work(for: reservation)
    }

    package func seal(
        _ documentID: StreamingOCRDocumentID,
        expectedPageCount: Int
    ) async throws {
        guard var document = documents[documentID] else {
            throw StreamingScanError.unknownBatch
        }
        guard case .accepting = document.phase else {
            throw StreamingScanError.unknownBatch
        }
        guard expectedPageCount == document.pages.count else {
            throw StreamingScanError.pageCountMismatch(
                expected: expectedPageCount,
                received: document.pages.count
            )
        }
        document.phase = .sealed(expectedPageCount: expectedPageCount)
        documents[documentID] = document
        startFinalizationIfReady(documentID)
        await webUpdates.notify()
    }

    package func completePage(
        _ reservation: StreamingOCRPageReservation,
        outcome: StreamingOCRPageOutcome
    ) async {
        guard var document = documents[reservation.documentID],
              var page = document.pages[reservation.pageNumber],
              page.reservation == reservation,
              case .reserved = page.state
        else { return }

        switch outcome {
        case .succeeded(let outputURL): page.state = .succeeded(outputURL)
        case let .failed(status, diagnostic): page.state = .failed(status: status, diagnostic: diagnostic)
        case .cancelled: page.state = .cancelled
        }
        document.pages[reservation.pageNumber] = page
        documents[reservation.documentID] = document
        startFinalizationIfReady(reservation.documentID)
        await webUpdates.notify()
    }

    package func invalidate(
        _ documentID: StreamingOCRDocumentID,
        reason: StreamingOCRTerminationReason
    ) -> StreamingOCRCancellationHandle? {
        guard let document = documents.removeValue(forKey: documentID) else { return nil }
        let finalization = finalizations.removeValue(forKey: documentID)
        finalization?.task.cancel()
        let handle = StreamingOCRCancellationHandle(rawValue: UUID())
        pendingTerminations[handle.rawValue] = PendingTermination(
            documentID: documentID,
            document: document,
            reason: reason,
            finalizationTask: finalization?.task
        )
        return handle
    }

    package func invalidateAll(
        reason: StreamingOCRTerminationReason
    ) -> [StreamingOCRCancellationHandle] {
        Array(documents.keys).compactMap { invalidate($0, reason: reason) }
    }

    package func finishCancellation(
        _ handle: StreamingOCRCancellationHandle
    ) async -> StreamingOCRTerminationResult {
        guard let pending = pendingTerminations[handle.rawValue] else {
            return StreamingOCRTerminationResult(
                workspaceRemoved: true,
                publishedFallbackPath: nil,
                diagnostic: ""
            )
        }
        pending.finalizationTask?.cancel()
        _ = await pending.finalizationTask?.value
        guard pendingTerminations.removeValue(forKey: handle.rawValue) != nil else {
            return StreamingOCRTerminationResult(
                workspaceRemoved: true,
                publishedFallbackPath: nil,
                diagnostic: ""
            )
        }
        let result = terminate(pending.document, reason: pending.reason)
        recordCompletion(
            documentID: pending.documentID,
            document: pending.document,
            reason: pending.reason,
            result: result
        )
        resumeIdleWaitersIfIdle()
        await webUpdates.notify()
        return result
    }

    package func documentIDs(referencing path: String) -> Set<StreamingOCRDocumentID> {
        Set(documents.compactMap { documentID, document in
            references(document.request, path: path) ? documentID : nil
        })
    }

    package func waitUntilIdle() async {
        guard !documents.isEmpty || !pendingTerminations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    package func prepareImportedPDF(
        _ imported: ImportedPDFOCRRequest,
        yieldPage: @escaping PageYield,
        cancelScheduledPages: @escaping CancellationDispatch
    ) async throws -> Int {
        try fileSystem.createDirectory(at: imported.workDirectory, withIntermediateDirectories: false)
        let sourceURL = URL(fileURLWithPath: imported.sourcePath)
        let documentID = begin(StreamingOCRDocumentRequest(
            documentName: imported.documentName,
            finalOutputURL: URL(fileURLWithPath: imported.finalOutputPath),
            workDirectory: imported.workDirectory,
            environment: imported.environment,
            removeBlankPages: imported.removeBlankPages,
            cropPages: imported.cropPages,
            replaceExistingText: imported.replaceExistingText,
            failurePolicy: .preserveImportedSource(sourceURL)
        ))

        do {
            let pageCountResult = try await documentExecutor.execute(ProcessRequest(
                executable: "qpdf",
                arguments: ["--show-npages", imported.sourcePath],
                environment: imported.environment,
                workingDirectory: imported.workDirectory
            ))
            guard pageCountResult.succeeded,
                  let pageCount = Int(
                    pageCountResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                  ),
                  pageCount > 0 else {
                throw StreamingScanError.importPreparationFailed(
                    pageCountResult.standardError.isEmpty
                        ? "The uploaded PDF has no readable pages."
                        : pageCountResult.standardError
                )
            }

            for pageNumber in 1...pageCount {
                try Task.checkCancellation()
                guard let document = documents[documentID] else {
                    throw StreamingScanError.unknownBatch
                }
                let pageURL = document.request.workDirectory.appendingPathComponent(
                    String(format: "page-%04d.pdf", pageNumber),
                    isDirectory: false
                )
                let splitResult = try await documentExecutor.execute(ProcessRequest(
                    executable: "qpdf",
                    arguments: [
                        imported.sourcePath,
                        "--pages", ".", String(pageNumber), "--", pageURL.path,
                    ],
                    environment: imported.environment,
                    workingDirectory: imported.workDirectory
                ))
                guard splitResult.succeeded, fileSystem.regularFileExists(at: pageURL) else {
                    throw StreamingScanError.importPreparationFailed(
                        splitResult.standardError.isEmpty
                            ? "Could not extract page \(pageNumber)."
                            : splitResult.standardError
                    )
                }
                let work = try reservePreparedPDFPage(
                    documentID: documentID,
                    pageNumber: pageNumber,
                    inputURL: pageURL
                )
                try await yieldPage(work)
            }

            try await seal(documentID, expectedPageCount: pageCount)
            return pageCount
        } catch {
            if let handle = invalidate(documentID, reason: .failed(error.localizedDescription)) {
                await cancelScheduledPages(documentID)
                _ = await finishCancellation(handle)
            }
            throw error
        }
    }

    private func reservePage(
        documentID: StreamingOCRDocumentID,
        pageNumber: Int,
        preparedInputURL: URL? = nil
    ) throws -> URL {
        guard var document = documents[documentID], case .accepting = document.phase else {
            throw StreamingScanError.unknownBatch
        }
        guard pageNumber > 0, document.pages[pageNumber] == nil else {
            throw StreamingScanError.invalidPageNumber
        }
        let inputURL = preparedInputURL ?? document.request.workDirectory.appendingPathComponent(
            String(format: "page-%04d.pdf", pageNumber),
            isDirectory: false
        )
        let reservation = StreamingOCRPageReservation(
            documentID: documentID,
            pageNumber: pageNumber,
            inputURL: inputURL,
            generation: UUID()
        )
        document.pages[pageNumber] = Page(reservation: reservation, state: .reserved)
        documents[documentID] = document
        return inputURL
    }

    private func reservation(
        documentID: StreamingOCRDocumentID,
        pageNumber: Int,
        inputURL: URL
    ) throws -> StreamingOCRPageReservation {
        guard let reservation = documents[documentID]?.pages[pageNumber]?.reservation,
              reservation.inputURL == inputURL else {
            throw StreamingScanError.unknownBatch
        }
        return reservation
    }

    private func work(for reservation: StreamingOCRPageReservation) -> StreamingOCRPageWork {
        let request = documents[reservation.documentID]!.request
        var operations: [String] = []
        if request.removeBlankPages { operations.append("remove blank pages") }
        if request.cropPages { operations.append("trim/crop") }
        let language = request.environment["SCAN_LANGUAGE"] ?? "deu+eng"
        operations.append("OCR (\(language))")
        return StreamingOCRPageWork(
            reservation: reservation,
            environment: request.environment,
            removeBlankPages: request.removeBlankPages,
            cropPages: request.cropPages,
            replaceExistingText: request.replaceExistingText,
            metadata: OCRWorkerJobMetadata(
                documentName: request.documentName,
                batchID: reservation.documentID.rawValue.uuidString.lowercased(),
                pageNumber: reservation.pageNumber,
                operations: operations
            )
        )
    }

    private func isCurrent(_ reservation: StreamingOCRPageReservation) -> Bool {
        documents[reservation.documentID]?.pages[reservation.pageNumber]?.reservation == reservation
    }

    private func rollback(_ reservation: StreamingOCRPageReservation) {
        guard var document = documents[reservation.documentID],
              document.pages[reservation.pageNumber]?.reservation == reservation,
              case .reserved = document.pages[reservation.pageNumber]?.state
        else { return }
        document.pages.removeValue(forKey: reservation.pageNumber)
        documents[reservation.documentID] = document
    }

    private func startFinalizationIfReady(_ documentID: StreamingOCRDocumentID) {
        guard var document = documents[documentID],
              case .sealed(let expectedPageCount) = document.phase,
              document.pages.count == expectedPageCount,
              document.pages.values.allSatisfy({ $0.state.isTerminal })
        else { return }

        let token = UUID()
        document.phase = .finalizing(token: token, started: Date())
        documents[documentID] = document
        let plan = FinalizationPlan(
            request: document.request,
            pages: document.pages.values.sorted {
                $0.reservation.pageNumber < $1.reservation.pageNumber
            }
        )
        let documentExecutor = self.documentExecutor
        let task = Task {
            await Self.stageFinalizedDocument(plan, documentExecutor: documentExecutor)
        }
        finalizations[documentID] = Finalization(token: token, task: task)
        Task { [weak self] in
            let result = await task.value
            await self?.receiveFinalization(result, documentID: documentID, token: token)
        }
    }

    private func receiveFinalization(
        _ result: FinalizationResult,
        documentID: StreamingOCRDocumentID,
        token: UUID
    ) async {
        guard let document = documents[documentID],
              case .finalizing(let currentToken, _) = document.phase,
              currentToken == token,
              finalizations[documentID]?.token == token
        else {
            if case .staged(let stagingURL) = result {
                try? fileSystem.removeItemIfPresent(at: stagingURL)
            }
            return
        }
        documents.removeValue(forKey: documentID)
        finalizations.removeValue(forKey: documentID)

        switch result {
        case .staged(let stagingURL):
            do {
                try fileSystem.placeFileExclusively(
                    at: stagingURL,
                    destination: document.request.finalOutputURL
                )
                try? fileSystem.removeItemIfPresent(at: document.request.workDirectory)
                latestCompletion = StreamingOCRDocumentCompletion(
                    documentID: documentID,
                    finished: Date(),
                    status: "done",
                    output: document.request.finalOutputURL.path,
                    error: ""
                )
            } catch {
                let termination = terminate(document, reason: .failed(error.localizedDescription))
                recordCompletion(
                    documentID: documentID,
                    document: document,
                    reason: .failed(error.localizedDescription),
                    result: termination
                )
            }
        case .failed(let diagnostic):
            let termination = terminate(document, reason: .failed(diagnostic))
            recordCompletion(
                documentID: documentID,
                document: document,
                reason: .failed(diagnostic),
                result: termination
            )
        case .cancelled:
            let termination = terminate(document, reason: .cancelled)
            recordCompletion(
                documentID: documentID,
                document: document,
                reason: .cancelled,
                result: termination
            )
        }
        resumeIdleWaitersIfIdle()
        await webUpdates.notify()
    }

    private nonisolated static func stageFinalizedDocument(
        _ plan: FinalizationPlan,
        documentExecutor: any ProcessExecutor
    ) async -> FinalizationResult {
        do {
            try Task.checkCancellation()
            let failedPages = plan.pages.compactMap { page -> Int? in
                switch page.state {
                case .succeeded: nil
                case .reserved, .failed, .cancelled: page.reservation.pageNumber
                }
            }
            guard failedPages.isEmpty else {
                return .failed(StreamingScanError.pageProcessingFailed(failedPages).localizedDescription)
            }

            var outputURLs = plan.pages.compactMap { page -> URL? in
                guard case .succeeded(let outputURL) = page.state else { return nil }
                return outputURL
            }
            let stagingURL = plan.request.workDirectory.appendingPathComponent("assembled.ocr.pdf")
            if plan.request.removeBlankPages {
                var retained: [URL] = []
                for outputURL in outputURLs {
                    try Task.checkCancellation()
                    let pageCount = try await documentExecutor.execute(ProcessRequest(
                        executable: "qpdf",
                        arguments: ["--show-npages", outputURL.path],
                        environment: plan.request.environment,
                        workingDirectory: plan.request.workDirectory
                    ))
                    guard pageCount.succeeded,
                          let count = Int(
                            pageCount.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                          ) else {
                        return .failed(StreamingScanError.assemblyFailed(
                            pageCount.standardError
                        ).localizedDescription)
                    }
                    if count > 0 { retained.append(outputURL) }
                }
                outputURLs = retained
            }

            try Task.checkCancellation()
            if outputURLs.isEmpty {
                guard plan.request.removeBlankPages,
                      let firstPage = plan.pages.first else {
                    return .failed(StreamingScanError.pageProcessingFailed(
                        plan.pages.map(\.reservation.pageNumber)
                    ).localizedDescription)
                }
                try FileManager.default.copyItem(at: firstPage.reservation.inputURL, to: stagingURL)
            } else {
                let merge = try await documentExecutor.execute(ProcessRequest(
                    executable: "qpdf",
                    arguments: ["--empty", "--pages"] + outputURLs.map(\.path) + ["--", stagingURL.path],
                    environment: plan.request.environment,
                    workingDirectory: plan.request.workDirectory
                ))
                guard merge.succeeded else {
                    return .failed(StreamingScanError.assemblyFailed(
                        merge.standardError
                    ).localizedDescription)
                }
            }

            try Task.checkCancellation()
            let options = try DocumentProcessingOptions(environment: plan.request.environment)
            let metadata = try await documentExecutor.execute(
                SetPDFCreatorRequest(
                    pdfPath: stagingURL.path,
                    creator: options.creator
                ).command.processRequest(
                    environment: plan.request.environment,
                    workingDirectory: plan.request.workDirectory
                )
            )
            guard metadata.succeeded else {
                return .failed(StreamingScanError.assemblyFailed(
                    metadata.standardError
                ).localizedDescription)
            }
            try Task.checkCancellation()
            return .staged(stagingURL)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func terminate(
        _ document: Document,
        reason: StreamingOCRTerminationReason
    ) -> StreamingOCRTerminationResult {
        let diagnostic: String
        switch reason {
        case .cancelled:
            diagnostic = ""
            try? fileSystem.removeItemIfPresent(at: document.request.workDirectory)
            return StreamingOCRTerminationResult(
                workspaceRemoved: true,
                publishedFallbackPath: nil,
                diagnostic: diagnostic
            )
        case .failed(let message):
            diagnostic = message
        }

        if case let .publishRawOnFailure(source, destination) = document.request.failurePolicy,
           fileSystem.regularFileExists(at: source) {
            do {
                try fileSystem.placeFileExclusively(at: source, destination: destination)
                try? fileSystem.removeItemIfPresent(at: document.request.workDirectory)
                return StreamingOCRTerminationResult(
                    workspaceRemoved: true,
                    publishedFallbackPath: destination.path,
                    diagnostic: diagnostic
                )
            } catch {
                return StreamingOCRTerminationResult(
                    workspaceRemoved: false,
                    publishedFallbackPath: nil,
                    diagnostic: diagnostic + retentionNote(document.request.workDirectory)
                )
            }
        }

        try? fileSystem.removeItemIfPresent(at: document.request.workDirectory)
        return StreamingOCRTerminationResult(
            workspaceRemoved: true,
            publishedFallbackPath: nil,
            diagnostic: diagnostic
        )
    }

    private func recordCompletion(
        documentID: StreamingOCRDocumentID,
        document: Document,
        reason: StreamingOCRTerminationReason,
        result: StreamingOCRTerminationResult
    ) {
        let status: String
        switch reason {
        case .cancelled: status = "cancelled"
        case .failed: status = "failed"
        }
        latestCompletion = StreamingOCRDocumentCompletion(
            documentID: documentID,
            finished: Date(),
            status: status,
            output: result.publishedFallbackPath ?? "",
            error: result.diagnostic
        )
    }

    private func references(_ request: StreamingOCRDocumentRequest, path: String) -> Bool {
        let candidate = standardizedPath(path)
        if standardizedPath(request.finalOutputURL.path) == candidate { return true }
        if request.documentName == URL(fileURLWithPath: candidate).lastPathComponent { return true }
        switch request.failurePolicy {
        case .sourceAlreadyPublished:
            return OCRInputPath.outputPath(for: path).map(standardizedPath)
                == standardizedPath(request.finalOutputURL.path)
        case .preserveImportedSource(let source):
            return standardizedPath(source.path) == candidate
        case let .publishRawOnFailure(source, destination):
            return standardizedPath(source.path) == candidate
                || standardizedPath(destination.path) == candidate
        }
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func retentionNote(_ workDirectory: URL) -> String {
        "\nThe scan was retained in \(workDirectory.path) because publishing the raw fallback failed."
    }

    private func resumeIdleWaitersIfIdle() {
        guard documents.isEmpty, pendingTerminations.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
