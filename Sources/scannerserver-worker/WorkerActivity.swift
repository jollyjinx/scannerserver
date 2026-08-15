import Foundation

actor WorkerActivity {
    private var runningJobs = 0

    func beginJob() { runningJobs += 1 }
    func finishJob() { runningJobs = max(0, runningJobs - 1) }
    var count: Int { runningJobs }
}

enum WorkerSessionError: Error, LocalizedError {
    case noLongerAvailable

    var errorDescription: String? {
        "Worker is no longer enabled for job dispatch."
    }
}
