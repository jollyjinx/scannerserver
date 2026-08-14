import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ScannerServerCore
import Testing

@Suite("Foundation process executor", .serialized)
struct FoundationProcessExecutorTests {
    @Test("Long-running subprocess I/O does not starve unrelated Swift tasks")
    func subprocessDoesNotStarveCooperativeExecutor() async throws {
        let executor = FoundationProcessExecutor()
        let processCount = max(ProcessInfo.processInfo.activeProcessorCount, 2)
        let processes = (0..<processCount).map { _ in
            Task {
                try await executor.execute(ProcessRequest(
                    executable: "/bin/sleep",
                    arguments: ["1"]
                ))
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let startedAt = clock.now
        try await Task.sleep(for: .milliseconds(10))
        let unrelatedTaskDelay = startedAt.duration(to: clock.now)

        for process in processes {
            _ = try await process.value
        }
        #expect(unrelatedTaskDelay < .milliseconds(500))
    }

    @Test("Drains stdout and stderr concurrently")
    func drainsBothStreams() async throws {
        let result = try await FoundationProcessExecutor().execute(ProcessRequest(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "i=0; while [ $i -lt 5000 ]; do echo output-$i; echo error-$i >&2; i=$((i + 1)); done",
            ],
            timeoutMilliseconds: 5_000
        ))

        #expect(result.exitStatus == 0)
        #expect(result.standardOutput.contains("output-4999"))
        #expect(result.standardError.contains("error-4999"))
    }

    @Test("Applies nice priority when spawning a subprocess")
    func appliesNicePriority() async throws {
        let result = try await FoundationProcessExecutor().execute(ProcessRequest(
            executable: "/bin/sh",
            arguments: ["-c", "ps -o ni= -p $$"],
            niceLevel: 10
        ))

        let reportedNiceLevel = Int(
            result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        #expect(result.exitStatus == 0)
        #expect(reportedNiceLevel != nil)
        #expect((reportedNiceLevel ?? 0) >= 10)
    }

    @Test("Cancellation kills a TERM-ignoring process group and pipe-holding descendant")
    func cancellationKillsProcessTree() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let leaderFile = directory.appendingPathComponent("leader.pid")
        let childFile = directory.appendingPathComponent("child.pid")
        let executor = FoundationProcessExecutor(terminationGracePeriodMilliseconds: 75)
        let task = Task {
            try await executor.execute(ProcessRequest(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' TERM; (trap '' TERM; while :; do /bin/sleep 60; done) & "
                        + "echo $$ > leader.pid; echo $! > child.pid; wait",
                ],
                workingDirectory: directory
            ))
        }

        try await waitForFile(leaderFile)
        try await waitForFile(childFile)
        let leader = try processID(in: leaderFile)
        let child = try processID(in: childFile)
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected process execution cancellation")
        } catch is CancellationError {
            // Expected.
        }

        #expect(start.duration(to: clock.now) < .seconds(10))
        try await waitUntilGone(leader)
        try await waitUntilGone(child)
    }

    @Test("Timeout escalates from TERM to KILL")
    func timeoutEscalates() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let leaderFile = directory.appendingPathComponent("leader.pid")
        let executor = FoundationProcessExecutor(terminationGracePeriodMilliseconds: 75)
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await executor.execute(ProcessRequest(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; echo $$ > leader.pid; while :; do /bin/sleep 60; done"],
                workingDirectory: directory,
                timeoutMilliseconds: 75
            ))
            Issue.record("Expected process timeout")
        } catch let error as ProcessExecutorError {
            #expect(error == .timedOut(milliseconds: 75))
        }

        #expect(start.duration(to: clock.now) < .seconds(10))
        let leader = try processID(in: leaderFile)
        try await waitUntilGone(leader)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoundationProcessExecutorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForFile(_ url: URL) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: url.path) {
            guard clock.now < deadline else {
                throw TestProcessError.markerNotCreated(url.path)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func processID(in url: URL) throws -> pid_t {
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let processID = pid_t(value) else {
            throw TestProcessError.invalidProcessID(value)
        }
        return processID
    }

    private func waitUntilGone(_ processID: pid_t) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while isRunning(processID) {
            guard clock.now < deadline else {
                throw TestProcessError.processStillRunning(processID)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func isRunning(_ processID: pid_t) -> Bool {
        #if canImport(Glibc)
        if let stat = try? String(contentsOfFile: "/proc/\(processID)/stat", encoding: .utf8),
           let closingParenthesis = stat.lastIndex(of: ")") {
            let state = stat[stat.index(after: closingParenthesis)...]
                .drop(while: \.isWhitespace)
                .first
            if state == "Z" { return false }
        }
        #endif
        return kill(processID, 0) == 0 || errno != ESRCH
    }
}

private enum TestProcessError: Error {
    case markerNotCreated(String)
    case invalidProcessID(String)
    case processStillRunning(pid_t)
}
