public actor ScanSnapReachabilityState {
    private let webUpdates: WebUpdateNotifier?
    public private(set) var isReachable: Bool

    public init(
        isReachable: Bool = false,
        webUpdates: WebUpdateNotifier? = nil
    ) {
        self.isReachable = isReachable
        self.webUpdates = webUpdates
    }

    public func update(isReachable: Bool) async {
        guard isReachable != self.isReachable else { return }
        self.isReachable = isReachable
        await webUpdates?.notify()
    }
}
