import Foundation
import ScannerServerCore
import Testing

@Suite("Button scan dispatcher")
struct ScanSnapButtonScanDispatcherTests {
    @Test("Button dispatch merges scanner and mode environment, stays single-flight, and rearms")
    func dispatchAndCompletion() async throws {
        let directory = try runtimeButtonTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = [
            "SCAN_LANGUAGE": "deu+eng",
            "SCAN_OUTPUT_DIR": directory.path,
            "SCANSNAP_CLIENT_IP": "192.168.60.10",
            "SCANSNAP_CLIENT_MAC": "02:11:22:33:44:55",
        ]
        let scannerStore = ScannerConfigStore(
            fileURL: directory.appendingPathComponent("scanner.json"),
            environment: environment
        )
        _ = try await scannerStore.save(ScannerConfig(
            status: .configured,
            scannerIP: "192.168.60.44",
            pairingKey: "active-key"
        ))
        let settingsStore = ScanSettingsStore(
            fileURL: directory.appendingPathComponent("settings.json"),
            environment: environment
        )
        let mode = ScanMode(
            id: "button-receipts",
            name: "Button Receipts",
            settings: ModeSettings(
                language: "eng",
                resolution: "400",
                format: "png",
                ocrEnabled: false
            )
        )
        _ = try await settingsStore.save(ScanSettings(
            defaultModeID: mode.id,
            modes: [mode],
            environment: environment
        ))
        let executor = RuntimeButtonProcessExecutor()
        let scanJobs = ScanJobActor(executor: executor)
        let dispatcher = ScanJobButtonScanDispatcher(
            scanJobs: scanJobs,
            scannerStore: scannerStore,
            environment: environment
        )
        let lifecycle = ScanSnapButtonLifecycleActor(
            scannerProvider: StoreBackedScanSnapButtonScannerConfigurationProvider(
                store: scannerStore,
                environment: environment,
                network: RuntimeButtonFakeNetwork()
            ),
            modeProvider: StoreBackedScanSnapButtonModeProvider(store: settingsStore),
            scanDispatcher: dispatcher,
            reachability: RuntimeButtonUnreachable(),
            armer: RuntimeButtonNoopArmer()
        )
        await dispatcher.attach(lifecycle: lifecycle)

        let noticeResult = await lifecycle.processNotice(
            runtimeButtonNotice(source: "192.168.60.44"),
            atMilliseconds: 10_000
        )
        #expect(noticeResult == .scanStarted(modeID: mode.id))
        #expect(await runtimeButtonEventually { await executor.requests().count == 1 })
        #expect(!(await dispatcher.startButtonScan(mode: mode)))

        let request = try #require(await executor.requests().first)
        let requestEnvironment = try #require(request.environment)
        #expect(requestEnvironment["SCANNER_IP"] == "192.168.60.44")
        #expect(requestEnvironment["SCANSNAP_PAIRING_KEY"] == "active-key")
        #expect(requestEnvironment["SCAN_TRIGGER"] == "button")
        #expect(requestEnvironment["SCAN_PROFILE_ID"] == mode.id)
        #expect(requestEnvironment["SCAN_PROFILE_NAME"] == mode.name)
        #expect(requestEnvironment["SCAN_LANGUAGE"] == "eng")
        #expect(requestEnvironment["SCAN_RESOLUTION"] == "400")
        #expect(requestEnvironment["SCAN_FORMAT"] == "png")
        #expect(requestEnvironment["SCAN_OCR_ENABLED"] == "false")
        #expect(await lifecycle.state.buttonScanInFlight)

        await executor.complete()
        await scanJobs.waitUntilIdle()

        #expect(await runtimeButtonEventually { await lifecycle.state.rearmRequested })
        #expect(!(await lifecycle.state.buttonScanInFlight))
        #expect(!(await dispatcher.isScanRunning()))
    }
}
