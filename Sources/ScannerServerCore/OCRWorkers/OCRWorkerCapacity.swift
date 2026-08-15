public struct OCRWorkerCapacity: Equatable, Sendable {
    public let cpuCount: Int
    public let maximumConcurrentJobs: Int
    public let cpuLimitPerJob: Int

    public init(cpuCount: Int, maximumConcurrentJobs: Int? = nil) {
        let cpuCount = max(1, cpuCount)
        self.cpuCount = cpuCount
        self.maximumConcurrentJobs = min(
            max(1, maximumConcurrentJobs ?? cpuCount),
            cpuCount
        )
        cpuLimitPerJob = 1
    }
}
