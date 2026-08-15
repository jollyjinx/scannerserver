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

    public init(serverURL: URL, session: URLSession = .shared) throws {
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

    private func post<RequestBody: Encodable, ResponseBody: Decodable>(
        _ body: RequestBody,
        path: String,
        response: ResponseBody.Type
    ) async throws -> ResponseBody {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, urlResponse) = try await session.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw OCRWorkerHTTPClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data).error)
                ?? String(decoding: data, as: UTF8.self)
            throw OCRWorkerHTTPClientError.serverRejected(
                status: httpResponse.statusCode,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try JSONDecoder().decode(response, from: data)
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
