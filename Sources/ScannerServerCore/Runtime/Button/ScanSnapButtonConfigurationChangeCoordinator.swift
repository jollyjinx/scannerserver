public actor ScanSnapButtonConfigurationChangeCoordinator: ScanSnapSetupConfigurationChangeNotifying {
    private weak var lifecycle: ScanSnapButtonLifecycleActor?

    public init() {}

    public func attach(lifecycle: ScanSnapButtonLifecycleActor) {
        self.lifecycle = lifecycle
    }

    public func detach() {
        lifecycle = nil
    }

    public func scannerConfigurationDidChange() async {
        await lifecycle?.scannerConfigurationDidChange()
    }
}
