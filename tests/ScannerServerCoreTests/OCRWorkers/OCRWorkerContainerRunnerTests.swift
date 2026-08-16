import Foundation
import ScannerServerCore
import Testing

@Suite("OCR worker container runner")
struct OCRWorkerContainerRunnerTests {
    @Test("Apple container request gives a one-page job one CPU")
    func request() throws {
        let workspace = URL(fileURLWithPath: "/tmp/worker job", isDirectory: true)
        let configuration = OCRWorkerContainerConfiguration(
            runtime: "container",
            image: "scannerserver:test",
            cpuLimitPerJob: 1,
            memory: "12G",
            workspaceRoot: workspace.deletingLastPathComponent(),
            userID: 501,
            groupID: 20
        )
        let request = try configuration.processRequest(
            lease: testContainerLease(),
            workspace: workspace
        )

        #expect(request.executable == "container")
        #expect(request.arguments == [
            "run", "--rm",
            "--cpus", "1",
            "--memory", "12G",
            "--uid", "501",
            "--gid", "20",
            "--env", "HOME=/work",
            "--env", "SCAN_OUTPUT_DIR=/work",
            "--env", "TMPDIR=/work/.tmp",
            "--workdir", "/work",
            "--volume", "/tmp/worker job:/work",
            "scannerserver:test",
            "ocrmypdf",
            "--language", "deu+eng",
            "--jobs", "1",
            "/work/source.pdf", "/work/result.pdf",
        ])
        #expect(request.workingDirectory == workspace)
    }

    @Test("Direct execution runs OCRmyPDF in the current worker container")
    func directRequest() throws {
        let workspace = URL(fileURLWithPath: "/var/lib/scannerserver-worker/jobs/job-1")
        let configuration = OCRWorkerContainerConfiguration(
            runtime: "",
            image: "",
            cpuLimitPerJob: 1,
            memory: "",
            workspaceRoot: workspace.deletingLastPathComponent(),
            directExecution: true
        )

        let request = try configuration.processRequest(
            lease: testContainerLease(),
            workspace: workspace
        )

        #expect(request == ProcessRequest(
            executable: "ocrmypdf",
            arguments: [
                "--language", "deu+eng",
                "--jobs", "1",
                "/var/lib/scannerserver-worker/jobs/job-1/source.pdf",
                "/var/lib/scannerserver-worker/jobs/job-1/result.pdf",
            ],
            workingDirectory: workspace
        ))
    }

    @Test("Apple container runs OCR and autocrop inside the isolated worker job")
    func cropRequest() throws {
        let workspace = URL(fileURLWithPath: "/tmp/worker-job", isDirectory: true)
        let configuration = OCRWorkerContainerConfiguration(
            runtime: "container",
            image: "scannerserver:test",
            cpuLimitPerJob: 1,
            memory: "8G",
            workspaceRoot: workspace.deletingLastPathComponent(),
            userID: 501,
            groupID: 20
        )
        let request = try configuration.processRequest(
            lease: testContainerLease(
                cropConfiguration: OCRWorkerCropConfiguration(
                    backgroundDelta: 9,
                    borderPixels: 50,
                    marginPoints: 2.5,
                    maximumWidthRatio: 0.7,
                    maximumHeightRatio: 0.75,
                    minimumDensity: 0.1,
                    keepOriginalBoxes: true,
                    debug: true
                )
            ),
            workspace: workspace
        )

        #expect(request.arguments.suffix(25) == [
            "scannerserver:test",
            "scannerserver-worker", "process-job",
            "--crop-pages",
            "--crop-background-delta", "9",
            "--crop-border-pixels", "50",
            "--crop-margin-points", "2.5",
            "--crop-maximum-width-ratio", "0.7",
            "--crop-maximum-height-ratio", "0.75",
            "--crop-minimum-density", "0.1",
            "--crop-keep-original-boxes",
            "--crop-debug",
            "--",
            "--language", "deu+eng",
            "--jobs", "1",
            "/work/source.pdf", "/work/result.pdf",
        ])
    }

    @Test("Apple container runs per-page blank removal inside the isolated worker job")
    func blankPageRequest() throws {
        let workspace = URL(fileURLWithPath: "/tmp/worker-job", isDirectory: true)
        let configuration = OCRWorkerContainerConfiguration(
            runtime: "container",
            image: "scannerserver:test",
            cpuLimitPerJob: 1,
            memory: "8G",
            workspaceRoot: workspace.deletingLastPathComponent(),
            userID: 501,
            groupID: 20
        )
        let blank = OCRWorkerBlankPageConfiguration(
            whiteThreshold: 240,
            contentRatioThreshold: 0.004,
            meanThreshold: 249,
            debug: true
        )
        let request = try configuration.processRequest(
            lease: testContainerLease(blankPageConfiguration: blank),
            workspace: workspace
        )

        #expect(request.arguments.contains("--remove-blank-pages"))
        #expect(request.arguments.contains("--blank-white-threshold"))
        #expect(request.arguments.contains("240"))
        #expect(request.arguments.contains("--blank-debug"))
        #expect(!request.arguments.contains("--crop-pages"))
    }
}

private func testContainerLease(
    cropConfiguration: OCRWorkerCropConfiguration? = nil,
    blankPageConfiguration: OCRWorkerBlankPageConfiguration? = nil
) -> OCRWorkerJobLease {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return OCRWorkerJobLease(
        manifest: OCRWorkerJobManifest(
            jobID: "job-1",
            sourcePath: "/scans/source.pdf",
            outputPath: "/scans/source.ocr.pdf",
            sourceByteCount: 100,
            sourceSHA256: String(repeating: "a", count: 64),
            ocrLanguages: ["deu", "eng"],
            ocrEnabled: true,
            removeBlankPages: blankPageConfiguration != nil,
            blankPageConfiguration: blankPageConfiguration,
            cropPages: cropConfiguration != nil,
            cropConfiguration: cropConfiguration,
            containerArguments: [
                "--language", "deu+eng",
                "--jobs", "3",
                "/work/source.pdf", "/work/result.pdf",
            ],
            createdAt: now
        ),
        workerID: "worker-1",
        leaseToken: "lease-token",
        leasedAt: now,
        expiresAt: now.addingTimeInterval(60),
        attempt: 1
    )
}
