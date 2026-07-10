import Foundation
import ScannerServerCore
import Testing

@Suite("Runtime button composition")
struct ScannerServerRuntimeButtonTests {
    @Test("Runtime starts and stops its injected button controller")
    func startsAndStopsButtonRuntime() async {
        let fixture = RuntimeButtonCompositionFixture()
        let buttonRuntime = RuntimeButtonRecordingController()
        let runtime = ScannerServerRuntime(
            dependencies: fixture.dependencies,
            buttonRuntime: buttonRuntime
        )

        await runtime.startButtonRuntime()
        await runtime.shutdown()

        #expect(await buttonRuntime.startCount == 1)
        #expect(await buttonRuntime.stopCount == 1)
    }

    @Test("Button startup failure does not prevent runtime shutdown")
    func startupFailureIsNonfatal() async {
        let fixture = RuntimeButtonCompositionFixture()
        let buttonRuntime = RuntimeButtonRecordingController(shouldFailStart: true)
        let runtime = ScannerServerRuntime(
            dependencies: fixture.dependencies,
            buttonRuntime: buttonRuntime
        )

        await runtime.startButtonRuntime()
        await runtime.shutdown()

        #expect(await buttonRuntime.startCount == 1)
        #expect(await buttonRuntime.stopCount == 1)
    }

    @Test("Live runtime shares scanner and settings stores with button composition")
    func liveRuntimeUsesConfiguredStorePaths() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = [
            "SCAN_BACKEND": "sane",
            "SCAN_OUTPUT_DIR": root.path,
            "SCAN_SETTINGS_PATH": root.appendingPathComponent("settings.json").path,
            "SCANNER_CONFIG_PATH": root.appendingPathComponent("scanner.json").path,
        ]

        let runtime = ScannerServerRuntime.live(environment: environment)
        let settingsPath = await runtime.dependencies.settingsStore.fileURL.path
        let scannerPath = await runtime.dependencies.scannerStore.fileURL.path

        #expect(settingsPath == environment["SCAN_SETTINGS_PATH"])
        #expect(scannerPath == environment["SCANNER_CONFIG_PATH"])
    }
}

private enum RuntimeButtonCompositionError: Error {
    case startupFailed
}

private actor RuntimeButtonRecordingController: ScanSnapButtonRuntimeControlling {
    private let shouldFailStart: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(shouldFailStart: Bool = false) {
        self.shouldFailStart = shouldFailStart
    }

    func start() throws -> Bool {
        startCount += 1
        if shouldFailStart {
            throw RuntimeButtonCompositionError.startupFailed
        }
        return true
    }

    func stop() {
        stopCount += 1
    }
}

private struct RuntimeButtonCompositionFixture {
    let dependencies: ScannerServerDependencies

    init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = [
            "SCAN_BACKEND": "sane",
            "SCAN_OUTPUT_DIR": root.path,
            "SCAN_SETTINGS_PATH": root.appendingPathComponent("settings.json").path,
            "SCANNER_CONFIG_PATH": root.appendingPathComponent("scanner.json").path,
        ]
        let processExecutor = RuntimeButtonProcessExecutor()
        dependencies = ScannerServerDependencies(
            settingsStore: ScanSettingsStore(environment: environment),
            scannerStore: ScannerConfigStore(environment: environment),
            scanJobs: ScanJobActor(nativeScanner: ProcessBackedTestScanner(processExecutor)),
            ocrQueue: OCRQueueActor(executor: processExecutor),
            outputPathResolver: ScanOutputPathResolver(outputDirectory: root),
            scannerSetup: StoredScannerSetupService(
                store: ScannerConfigStore(environment: environment)
            ),
            environment: environment
        )
    }
}
