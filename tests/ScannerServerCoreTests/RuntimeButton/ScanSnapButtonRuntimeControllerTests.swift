import Foundation
import ScannerServerCore
import Testing

@Suite("Button runtime controller")
struct ScanSnapButtonRuntimeControllerTests {
    @Test("Disabled and SANE runtimes do not create or bind a listener")
    func ineligibleRuntimeIsNoOp() async throws {
        for environment in [
            ["SCAN_BACKEND": "wifi", "SCANSNAP_BUTTON_SCAN_ENABLED": "false"],
            ["SCAN_BACKEND": "sane", "SCANSNAP_BUTTON_SCAN_ENABLED": "true"],
        ] {
            let directory = try runtimeButtonTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let scannerStore = ScannerConfigStore(
                fileURL: directory.appendingPathComponent("scanner.json"),
                environment: environment
            )
            let settingsStore = ScanSettingsStore(
                fileURL: directory.appendingPathComponent("settings.json"),
                environment: environment
            )
            let factory = RuntimeButtonFakeUDPFactory()
            let controller = ScanSnapButtonRuntimeFactory.live(
                environment: environment,
                scannerStore: scannerStore,
                settingsStore: settingsStore,
                scanJobs: ScanJobActor(
                    nativeScanner: ProcessBackedTestScanner(RuntimeButtonProcessExecutor())
                ),
                network: RuntimeButtonFakeNetwork(),
                udpTransportFactory: factory,
                reachability: RuntimeButtonUnreachable(),
                armer: RuntimeButtonNoopArmer()
            )

            #expect(!controller.isEligible)
            #expect(!(try await controller.start()))
            #expect(await factory.makeCallCount == 0)
            #expect(!(await controller.state().isRunning))
            await controller.stop()
        }
    }

    @Test("Eligible Wi-Fi runtime starts and cleanly stops its lifecycle")
    func startAndStop() async throws {
        let directory = try runtimeButtonTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = [
            "SCAN_BACKEND": "wifi",
            "SCANSNAP_BUTTON_SCAN_ENABLED": "true",
            "SCANSNAP_BUTTON_PORT": "50001",
        ]
        let transport = RuntimeButtonFakeUDPTransport(boundPort: 50_555)
        let factory = RuntimeButtonFakeUDPFactory(transport: transport)
        let controller = ScanSnapButtonRuntimeFactory.live(
            environment: environment,
            scannerStore: ScannerConfigStore(
                fileURL: directory.appendingPathComponent("scanner.json"),
                environment: environment
            ),
            settingsStore: ScanSettingsStore(
                fileURL: directory.appendingPathComponent("settings.json"),
                environment: environment
            ),
            scanJobs: ScanJobActor(
                nativeScanner: ProcessBackedTestScanner(RuntimeButtonProcessExecutor())
            ),
            network: RuntimeButtonFakeNetwork(),
            udpTransportFactory: factory,
            reachability: RuntimeButtonUnreachable(),
            armer: RuntimeButtonNoopArmer()
        )

        #expect(controller.isEligible)
        #expect(try await controller.start())
        #expect(await factory.makeCallCount == 1)
        #expect(await transport.bindCalls == [.anyIPv4(port: 50_001)])
        #expect(await controller.state().isRunning)
        #expect(await controller.state().boundPort == 50_555)

        await controller.stop()

        #expect(await transport.isClosed)
        let state = await controller.state()
        #expect(!state.isRunning)
        #expect(state.boundPort == nil)
    }

    @Test("Setup configuration changes arm the attached button lifecycle before returning")
    func setupConfigurationChangeArmsButtonLifecycle() async throws {
        let directory = try runtimeButtonTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = [
            "SCAN_BACKEND": "wifi",
            "SCANSNAP_BUTTON_SCAN_ENABLED": "true",
            "SCANSNAP_CLIENT_IP": "192.168.50.10",
            "SCANSNAP_CLIENT_MAC": "02:11:22:33:44:55",
        ]
        let scannerStore = ScannerConfigStore(
            fileURL: directory.appendingPathComponent("scanner.json"),
            environment: environment
        )
        let coordinator = ScanSnapButtonConfigurationChangeCoordinator()
        let controller = ScanSnapButtonRuntimeFactory.live(
            environment: environment,
            scannerStore: scannerStore,
            settingsStore: ScanSettingsStore(
                fileURL: directory.appendingPathComponent("settings.json"),
                environment: environment
            ),
            scanJobs: ScanJobActor(
                nativeScanner: ProcessBackedTestScanner(RuntimeButtonProcessExecutor())
            ),
            network: RuntimeButtonFakeNetwork(),
            udpTransportFactory: RuntimeButtonFakeUDPFactory(),
            reachability: ButtonFakeReachability([true]),
            armer: RuntimeButtonNoopArmer(),
            configurationChangeCoordinator: coordinator
        )

        #expect(try await controller.start())
        _ = try await scannerStore.save(ScannerConfig(
            status: .configured,
            scannerIP: "192.168.50.44",
            pairingKey: "pairing-key"
        ))

        await coordinator.scannerConfigurationDidChange()

        #expect(await controller.state().isArmed)
        await controller.stop()
    }
}
