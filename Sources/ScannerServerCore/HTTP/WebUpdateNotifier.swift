import Foundation

/// Suspends web requests until server-visible state changes, without polling.
public actor WebUpdateNotifier {
    private var revision: UInt64 = 0
    private var waiters: [UUID: CheckedContinuation<UInt64, Never>] = [:]

    public init() {}

    public var currentRevision: UInt64 { revision }

    @discardableResult
    public func notify() -> UInt64 {
        revision &+= 1
        let resumedRevision = revision
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: resumedRevision)
        }
        return resumedRevision
    }

    public func wait(after observedRevision: UInt64) async -> UInt64 {
        guard observedRevision >= revision else { return revision }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: revision)
    }
}
