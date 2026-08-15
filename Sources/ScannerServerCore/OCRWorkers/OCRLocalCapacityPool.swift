import Foundation

/// A non-blocking, weighted CPU permit pool shared by queue-owned local work and
/// distributed OCR's local fallback.
public actor OCRLocalCapacityPool {
    public nonisolated let webUpdates: WebUpdateNotifier
    public let capacity: Int

    private var reservedCPUs = 0

    public init(
        capacity: Int,
        webUpdates: WebUpdateNotifier = WebUpdateNotifier()
    ) {
        self.capacity = max(1, capacity)
        self.webUpdates = webUpdates
    }

    /// Returns the granted CPU count, or `nil` when the local worker is full.
    public func tryAcquire(_ requestedCPUs: Int) -> Int? {
        let requestedCPUs = min(max(1, requestedCPUs), capacity)
        guard reservedCPUs + requestedCPUs <= capacity else { return nil }
        reservedCPUs += requestedCPUs
        return requestedCPUs
    }

    public func release(_ cpus: Int) async {
        guard cpus > 0 else { return }
        reservedCPUs = max(0, reservedCPUs - cpus)
        await webUpdates.notify()
    }

    public var availableCPUs: Int { capacity - reservedCPUs }
}
