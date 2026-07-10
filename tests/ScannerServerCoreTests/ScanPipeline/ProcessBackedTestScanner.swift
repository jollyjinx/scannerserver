import ScannerServerCore

actor ProcessBackedTestScanner: NativeScanExecuting {
    private let executor: any ProcessExecutor

    init(_ executor: any ProcessExecutor) {
        self.executor = executor
    }

    func scan(configuration: ScanPipelineConfiguration) async throws -> ProcessResult {
        try await executor.execute(ProcessRequest(
            executable: "test-native-scan",
            environment: configuration.environment
        ))
    }
}
