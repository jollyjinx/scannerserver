import Foundation

public actor OCRWorkerRegistry {
    private struct StoredWorker: Codable, Sendable {
        var registration: OCRWorkerRegistrationRequest
        let registeredAt: Date
        var lastSeen: Date
        var runningJobs: Int
        var approved: Bool
        var enabled: Bool
        var paused: Bool?
    }

    private struct StoredWorkers: Codable, Sendable {
        var workers: [StoredWorker]
    }

    public nonisolated let webUpdates: WebUpdateNotifier
    public let fileURL: URL?
    public let heartbeatIntervalSeconds: Int
    public let offlineAfterSeconds: TimeInterval

    private var workers: [String: StoredWorker]

    public init(
        fileURL: URL? = nil,
        heartbeatIntervalSeconds: Int = 5,
        offlineAfterSeconds: TimeInterval = 20,
        webUpdates: WebUpdateNotifier = WebUpdateNotifier()
    ) {
        self.fileURL = fileURL
        self.heartbeatIntervalSeconds = max(1, heartbeatIntervalSeconds)
        self.offlineAfterSeconds = max(1, offlineAfterSeconds)
        self.webUpdates = webUpdates
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let stored = try? decoder.decode(StoredWorkers.self, from: data) {
            var loaded: [String: StoredWorker] = [:]
            for worker in stored.workers {
                loaded[worker.registration.workerID] = worker
            }
            workers = loaded
        } else {
            workers = [:]
        }
    }

    public static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let path = environment["SCAN_OCR_WORKERS_PATH"] {
            return URL(fileURLWithPath: path)
        }
        let outputDirectory = environment["SCAN_OUTPUT_DIR"] ?? "/scans"
        return URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent(".scannerserver-ocr-workers.json")
    }

    public func register(
        _ request: OCRWorkerRegistrationRequest,
        now: Date = Date()
    ) async throws -> OCRWorkerRegistrationResponse {
        try validate(request)
        if var existing = workers[request.workerID] {
            guard existing.registration.authenticationToken == request.authenticationToken else {
                throw OCRWorkerRegistryError.authenticationFailed
            }
            existing.registration = request
            existing.lastSeen = now
            workers[request.workerID] = existing
        } else {
            workers[request.workerID] = StoredWorker(
                registration: request,
                registeredAt: now,
                lastSeen: now,
                runningJobs: 0,
                approved: false,
                enabled: true,
                paused: false
            )
        }
        try persist()
        let response = try response(for: request.workerID, now: now)
        await webUpdates.notify()
        return response
    }

    public func heartbeat(
        workerID: String,
        request: OCRWorkerHeartbeatRequest,
        now: Date = Date()
    ) async throws -> OCRWorkerRegistrationResponse {
        guard var worker = workers[workerID] else {
            throw OCRWorkerRegistryError.unknownWorker
        }
        guard worker.registration.authenticationToken == request.authenticationToken else {
            throw OCRWorkerRegistryError.authenticationFailed
        }
        let previousAvailability = availability(worker, now: now)
        let previousRunningJobs = worker.runningJobs
        worker.lastSeen = now
        worker.runningJobs = min(max(0, request.runningJobs), worker.registration.maxConcurrentJobs)
        workers[workerID] = worker
        let response = try response(for: workerID, now: now)
        if response.availability != previousAvailability || worker.runningJobs != previousRunningJobs {
            await webUpdates.notify()
        }
        return response
    }

    @discardableResult
    public func approve(workerID: String, now: Date = Date()) async throws -> OCRWorkerSnapshot {
        guard var worker = workers[workerID] else {
            throw OCRWorkerRegistryError.unknownWorker
        }
        worker.approved = true
        workers[workerID] = worker
        try persist()
        let snapshot = snapshot(worker, now: now)
        await webUpdates.notify()
        return snapshot
    }

    @discardableResult
    public func setEnabled(
        _ enabled: Bool,
        workerID: String,
        now: Date = Date()
    ) async throws -> OCRWorkerSnapshot {
        guard var worker = workers[workerID] else {
            throw OCRWorkerRegistryError.unknownWorker
        }
        worker.enabled = enabled
        workers[workerID] = worker
        try persist()
        let snapshot = snapshot(worker, now: now)
        await webUpdates.notify()
        return snapshot
    }

    @discardableResult
    public func setPaused(
        _ paused: Bool,
        workerID: String,
        now: Date = Date()
    ) async throws -> OCRWorkerSnapshot {
        guard var worker = workers[workerID] else {
            throw OCRWorkerRegistryError.unknownWorker
        }
        worker.paused = paused
        workers[workerID] = worker
        try persist()
        let snapshot = snapshot(worker, now: now)
        await webUpdates.notify()
        return snapshot
    }

    @discardableResult
    public func remove(workerID: String, now: Date = Date()) async throws -> OCRWorkerSnapshot {
        guard let worker = workers.removeValue(forKey: workerID) else {
            throw OCRWorkerRegistryError.unknownWorker
        }
        do {
            try persist()
        } catch {
            workers[workerID] = worker
            throw error
        }
        let snapshot = snapshot(worker, now: now)
        await webUpdates.notify()
        return snapshot
    }

    public func snapshots(now: Date = Date()) -> [OCRWorkerSnapshot] {
        workers.values
            .map { snapshot($0, now: now) }
            .sorted {
                if $0.availability == $1.availability {
                    return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                return availabilityOrder($0.availability) < availabilityOrder($1.availability)
            }
    }

    public func authorizeJobRequest(
        workerID: String,
        authenticationToken: String,
        now: Date = Date(),
        requireCapacity: Bool = true
    ) throws -> OCRWorkerSnapshot {
        guard let worker = workers[workerID] else {
            throw OCRWorkerRegistryError.unknownWorker
        }
        guard worker.registration.authenticationToken == authenticationToken else {
            throw OCRWorkerRegistryError.authenticationFailed
        }
        guard worker.approved else { throw OCRWorkerRegistryError.approvalRequired }
        guard worker.enabled else { throw OCRWorkerRegistryError.workerDisabled }
        guard worker.paused != true else { throw OCRWorkerRegistryError.workerPaused }
        guard now.timeIntervalSince(worker.lastSeen) <= offlineAfterSeconds else {
            throw OCRWorkerRegistryError.workerOffline
        }
        if requireCapacity, worker.runningJobs >= worker.registration.maxConcurrentJobs {
            throw OCRWorkerRegistryError.workerAtCapacity
        }
        return snapshot(worker, now: now)
    }

    public func hasEligibleWorker(
        ocrLanguages: [String],
        now: Date = Date()
    ) -> Bool {
        let required = Set(ocrLanguages)
        return workers.values.contains { worker in
            worker.approved
                && worker.enabled
                && worker.paused != true
                && now.timeIntervalSince(worker.lastSeen) <= offlineAfterSeconds
                && required.isSubset(of: Set(worker.registration.ocrLanguages))
        }
    }

    public func hasPreferredWorker(ocrLanguages: [String]) -> Bool {
        let required = Set(ocrLanguages)
        return workers.values.contains { worker in
            worker.approved
                && worker.enabled
                && worker.paused != true
                && required.isSubset(of: Set(worker.registration.ocrLanguages))
        }
    }

    private func validate(_ request: OCRWorkerRegistrationRequest) throws {
        guard request.protocolVersion == OCRWorkerProtocol.currentVersion else {
            throw OCRWorkerRegistryError.unsupportedProtocolVersion(request.protocolVersion)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !request.workerID.isEmpty,
              request.workerID.count <= 128,
              request.workerID.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw OCRWorkerRegistryError.invalidWorkerID
        }
        guard request.authenticationToken.count >= 32,
              request.authenticationToken.count <= 512 else {
            throw OCRWorkerRegistryError.invalidAuthenticationToken
        }
        guard request.cpuCount > 0,
              request.maxConcurrentJobs > 0,
              request.maxConcurrentJobs <= request.cpuCount else {
            throw OCRWorkerRegistryError.invalidCapacity
        }
    }

    private func response(for workerID: String, now: Date) throws -> OCRWorkerRegistrationResponse {
        guard let worker = workers[workerID] else {
            throw OCRWorkerRegistryError.unknownWorker
        }
        return OCRWorkerRegistrationResponse(
            workerID: workerID,
            availability: availability(worker, now: now),
            heartbeatIntervalSeconds: heartbeatIntervalSeconds
        )
    }

    private func snapshot(_ worker: StoredWorker, now: Date) -> OCRWorkerSnapshot {
        OCRWorkerSnapshot(
            workerID: worker.registration.workerID,
            displayName: worker.registration.displayName,
            hostname: worker.registration.hostname,
            workerVersion: worker.registration.workerVersion,
            architecture: worker.registration.architecture,
            cpuCount: worker.registration.cpuCount,
            maxConcurrentJobs: worker.registration.maxConcurrentJobs,
            runningJobs: worker.runningJobs,
            ocrLanguages: worker.registration.ocrLanguages,
            approved: worker.approved,
            enabled: worker.enabled,
            paused: worker.paused ?? false,
            availability: availability(worker, now: now),
            registeredAt: worker.registeredAt,
            lastSeen: worker.lastSeen
        )
    }

    private func availability(_ worker: StoredWorker, now: Date) -> OCRWorkerAvailability {
        guard worker.approved else { return .pendingApproval }
        guard worker.enabled else { return .disabled }
        guard worker.paused != true else { return .paused }
        guard now.timeIntervalSince(worker.lastSeen) <= offlineAfterSeconds else { return .offline }
        return worker.runningJobs > 0 ? .busy : .online
    }

    private func availabilityOrder(_ value: OCRWorkerAvailability) -> Int {
        switch value {
        case .pendingApproval: 0
        case .busy: 1
        case .online: 2
        case .paused: 3
        case .offline: 4
        case .disabled: 5
        }
    }

    private func persist() throws {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = StoredWorkers(workers: workers.values.sorted {
            $0.registration.workerID < $1.registration.workerID
        })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(stored)
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
    }
}
