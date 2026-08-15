import Foundation
import ScannerServerCore

#if canImport(Network)
import Network

enum BonjourScannerServerDiscoveryError: Error, LocalizedError {
    case timedOut
    case stopped
    case browserFailed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "No compatible scannerserver was found through Bonjour."
        case .stopped:
            "Bonjour discovery stopped before finding scannerserver."
        case .browserFailed(let detail):
            "Bonjour discovery failed: \(detail)"
        }
    }
}

struct BonjourScannerServerDiscovery {
    func discover(timeout: Duration = .seconds(10)) async throws -> URL {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: OCRWorkerBonjourService.type,
                domain: OCRWorkerBonjourService.domain
            ),
            using: .tcp
        )
        defer { browser.cancel() }

        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await firstCompatibleURL(from: browser)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BonjourScannerServerDiscoveryError.timedOut
            }
            guard let url = try await group.next() else {
                throw BonjourScannerServerDiscoveryError.stopped
            }
            group.cancelAll()
            return url
        }
    }

    private func firstCompatibleURL(from browser: NWBrowser) async throws -> URL {
        let stream = AsyncThrowingStream<Set<NWBrowser.Result>, any Error> { continuation in
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    continuation.finish(
                        throwing: BonjourScannerServerDiscoveryError.browserFailed(error.debugDescription)
                    )
                case .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(results)
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: DispatchQueue(label: "eu.jinx.scannerserver.worker-bonjour"))
        }

        for try await results in stream {
            for result in results.sorted(by: { $0.endpoint.debugDescription < $1.endpoint.debugDescription }) {
                guard case .bonjour(let record) = result.metadata,
                      let url = OCRWorkerBonjourService.serverURL(fromTXTRecord: record.dictionary) else {
                    continue
                }
                return url
            }
        }
        throw BonjourScannerServerDiscoveryError.stopped
    }
}
#endif
