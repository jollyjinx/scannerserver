public enum ScanSnapAcquisitionSessionMode: Sendable, Hashable {
    case registerFresh
    case reuseArmed
}

/// Transfers ownership of an already-armed ScanSnap session to the next Wi-Fi
/// acquisition. The transfer is one-shot so a later scan cannot accidentally
/// reuse stale protocol state.
public actor ScanSnapAcquisitionSessionCoordinator {
    private var nextMode: ScanSnapAcquisitionSessionMode = .registerFresh

    public init() {}

    public func prepareForAcquisition(reusingArmedSession: Bool) {
        nextMode = reusingArmedSession ? .reuseArmed : .registerFresh
    }

    public func consumeForAcquisition() -> ScanSnapAcquisitionSessionMode {
        let mode = nextMode
        nextMode = .registerFresh
        return mode
    }
}
