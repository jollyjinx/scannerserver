import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OCRWorkerHTTPClientError: Error, LocalizedError, Sendable {
    case invalidServerURL
    case invalidResponse
    case serverRejected(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "The scannerserver URL must use HTTP or HTTPS and include a host."
        case .invalidResponse:
            "Scannerserver returned an invalid worker API response."
        case let .serverRejected(status, message):
            "Scannerserver rejected the worker request (HTTP \(status)): \(message)"
        }
    }
}

public struct OCRWorkerHTTPClient: Sendable {
    public let serverURL: URL
    private let session: URLSession

    public init(serverURL: URL) throws {
        try self.init(
            serverURL: serverURL,
            session: URLSession(configuration: .default)
        )
    }

    public init(serverURL: URL, session: URLSession) throws {
        guard ["http", "https"].contains(serverURL.scheme?.lowercased()),
              serverURL.host != nil else {
            throw OCRWorkerHTTPClientError.invalidServerURL
        }
        self.serverURL = serverURL
        self.session = session
    }

    public func register(
        _ registration: OCRWorkerRegistrationRequest
    ) async throws -> OCRWorkerRegistrationResponse {
        try await post(
            registration,
            path: "api/ocr-workers/register",
            response: OCRWorkerRegistrationResponse.self
        )
    }

    public func heartbeat(
        workerID: String,
        request heartbeat: OCRWorkerHeartbeatRequest
    ) async throws -> OCRWorkerRegistrationResponse {
        let encodedID = workerID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ) ?? workerID
        return try await post(
            heartbeat,
            path: "api/ocr-workers/\(encodedID)/heartbeat",
            response: OCRWorkerRegistrationResponse.self
        )
    }

    public func leaseNextJob(
        workerID: String,
        request poll: OCRWorkerJobPollRequest
    ) async throws -> OCRWorkerJobLease? {
        var request = URLRequest(url: endpoint(workerJobPath(workerID: workerID, suffix: "lease")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(poll)
        let (data, response) = try await perform(request)
        if response.statusCode == 204 { return nil }
        try validate(response: response, data: data)
        return try decoder.decode(OCRWorkerJobLease.self, from: data)
    }

    public func downloadSource(
        workerID: String,
        authenticationToken: String,
        lease: OCRWorkerJobLease
    ) async throws -> Data {
        var request = URLRequest(url: endpoint(workerJobPath(
            workerID: workerID,
            jobID: lease.manifest.jobID,
            suffix: "source"
        )))
        request.setValue("Bearer \(authenticationToken)", forHTTPHeaderField: "Authorization")
        request.setValue(lease.leaseToken, forHTTPHeaderField: "If-Match")
        let (data, response) = try await perform(request)
        try validate(response: response, data: data)
        return data
    }

    public func renew(
        workerID: String,
        authenticationToken: String,
        lease: OCRWorkerJobLease
    ) async throws -> OCRWorkerJobLease {
        try await post(
            OCRWorkerJobLeaseRequest(
                authenticationToken: authenticationToken,
                leaseToken: lease.leaseToken
            ),
            path: workerJobPath(workerID: workerID, jobID: lease.manifest.jobID, suffix: "renew"),
            response: OCRWorkerJobLease.self
        )
    }

    public func reportFailure(
        workerID: String,
        authenticationToken: String,
        lease: OCRWorkerJobLease,
        failure: String
    ) async throws -> OCRWorkerJobSnapshot {
        try await post(
            OCRWorkerJobFailureRequest(
                authenticationToken: authenticationToken,
                leaseToken: lease.leaseToken,
                failure: failure
            ),
            path: workerJobPath(workerID: workerID, jobID: lease.manifest.jobID, suffix: "fail"),
            response: OCRWorkerJobSnapshot.self
        )
    }

    public func uploadResult(
        workerID: String,
        authenticationToken: String,
        lease: OCRWorkerJobLease,
        data: Data
    ) async throws -> OCRWorkerJobSnapshot {
        var request = URLRequest(url: endpoint(workerJobPath(
            workerID: workerID,
            jobID: lease.manifest.jobID,
            suffix: "result"
        )))
        request.httpMethod = "POST"
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authenticationToken)", forHTTPHeaderField: "Authorization")
        request.setValue(lease.leaseToken, forHTTPHeaderField: "If-Match")
        request.httpBody = data
        let (responseData, response) = try await perform(request)
        try validate(response: response, data: responseData)
        return try decoder.decode(OCRWorkerJobSnapshot.self, from: responseData)
    }

    private func post<RequestBody: Encodable, ResponseBody: Decodable>(
        _ body: RequestBody,
        path: String,
        response: ResponseBody.Type
    ) async throws -> ResponseBody {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, httpResponse) = try await perform(request)
        try validate(response: httpResponse, data: data)
        return try decoder.decode(response, from: data)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OCRWorkerHTTPClientError.invalidResponse
        }
        return (data, httpResponse)
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data).error)
                ?? String(decoding: data, as: UTF8.self)
            throw OCRWorkerHTTPClientError.serverRejected(
                status: response.statusCode,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func workerJobPath(workerID: String, jobID: String? = nil, suffix: String) -> String {
        var components = ["api", "ocr-workers", encodedPathComponent(workerID), "jobs"]
        if let jobID { components.append(encodedPathComponent(jobID)) }
        components.append(suffix)
        return components.joined(separator: "/")
    }

    private func encodedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ) ?? value
    }

    private func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(serverURL) { url, component in
            url.appendingPathComponent(String(component))
        }
    }
}

private struct ServerError: Decodable {
    let error: String
}
