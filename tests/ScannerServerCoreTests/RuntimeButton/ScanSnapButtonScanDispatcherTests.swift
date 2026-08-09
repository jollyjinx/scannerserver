import Foundation
import ScannerServerCore
import Testing

@Suite("Button scan dispatcher")
struct ScanSnapButtonScanDispatcherTests {
    @Test("Button dispatch merges scanner and mode environment and stays single-flight")
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
        let mode = ScanMode(
            id: "button-receipts",
            name: "Button Receipts",
            settings: ModeSettings(
                language: "eng",
                resolution: "400",
                format: "png",
                ocrEnabled: false,
                cropMarginPoints: 2.5
            )
        )
        let executor = RuntimeButtonProcessExecutor()
        let scanJobs = ScanJobActor(nativeScanner: ProcessBackedTestScanner(executor))
        let dispatcher = ScanJobButtonScanDispatcher(
            scanJobs: scanJobs,
            scannerStore: scannerStore,
            environment: environment
        )
        #expect(await dispatcher.startButtonScan(mode: mode))
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
        #expect(requestEnvironment["SCAN_CROP_MARGIN_POINTS"] == "2.5")
        await executor.complete()
        await scanJobs.waitUntilIdle()

        #expect(!(await dispatcher.isScanRunning()))
    }

    @Test("Failed button scan publishes a failed scan-job event")
    func failedScanPublishesEvent() async throws {
        let directory = try runtimeButtonTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = [
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
        let executor = RuntimeButtonProcessExecutor(result: ProcessResult(
            exitStatus: 1,
            standardError: "Error: no document in scanner\n"
        ))
        let scanJobs = ScanJobActor(nativeScanner: ProcessBackedTestScanner(executor))
        let dispatcher = ScanJobButtonScanDispatcher(
            scanJobs: scanJobs,
            scannerStore: scannerStore,
            environment: environment
        )
        let stream = await scanJobs.eventStream()
        let eventTask = Task {
            var iterator = stream.makeAsyncIterator()
            return [await iterator.next(), await iterator.next()].compactMap { $0 }
        }

        #expect(await dispatcher.startButtonScan(mode: buttonMode()))
        #expect(await runtimeButtonEventually { await executor.requests().count == 1 })
        await executor.complete()
        await scanJobs.waitUntilIdle()

        #expect(await eventTask.value == [
            .started(trigger: .scannerButton),
            .finished(succeeded: false),
        ])
    }
}
