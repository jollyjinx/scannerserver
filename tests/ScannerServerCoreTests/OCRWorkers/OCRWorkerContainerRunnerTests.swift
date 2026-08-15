import Foundation
import ScannerServerCore
import Testing

@Suite("OCR worker container runner")
struct OCRWorkerContainerRunnerTests {
    @Test("Apple container request bounds CPU and memory and mounts only the job workspace")
    func request() throws {
        let workspace = URL(fileURLWithPath: "/tmp/worker job", isDirectory: true)
        let configuration = OCRWorkerContainerConfiguration(
            runtime: "container",
            image: "scannerserver:test",
            cpusPerJob: 11,
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
            "--cpus", "11",
            "--memory", "12G",
            "--uid", "501",
            "--gid", "20",
            "--env", "SCAN_OUTPUT_DIR=/work",
            "--env", "TMPDIR=/work/.tmp",
            "--volume", "/tmp/worker job:/work",
            "scannerserver:test",
            "ocrmypdf",
            "--language", "deu+eng",
            "--jobs", "11",
            "/work/source.pdf", "/work/result.pdf",
        ])
        #expect(request.workingDirectory == workspace)
    }
}

private func testContainerLease() -> OCRWorkerJobLease {
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
            removeBlankPages: false,
            cropPages: false,
            containerArguments: [
                "--language", "deu+eng",
                "--jobs", "11",
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
