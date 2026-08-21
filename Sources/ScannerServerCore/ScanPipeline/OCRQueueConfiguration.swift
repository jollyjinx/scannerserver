import Foundation

public struct OCRQueueConfiguration: Equatable, Sendable {
    public let cpuLimit: Int
    public let niceLevel: Int?

    public init(cpuLimit: Int, niceLevel: Int? = nil) {
        self.cpuLimit = max(1, cpuLimit)
        self.niceLevel = niceLevel.map { min(max($0, 1), 19) }
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(
            environment: environment,
            detectedProcessorCount: OCRSystemProcessorCount.detect()
        )
    }

    /// The processor allowance visible to this process after cgroup quota and cpuset limits.
    public static var detectedProcessorCount: Int {
        OCRSystemProcessorCount.detect()
    }

    init(environment: [String: String], detectedProcessorCount: Int) {
        let detectedProcessorCount = max(1, detectedProcessorCount)
        let backgroundProcessorCount = max(1, detectedProcessorCount - 1)
        if let text = Self.nonEmpty(environment["SCAN_OCR_CPU_LIMIT"]),
           let configuredLimit = Int(text),
           configuredLimit > 0
        {
            cpuLimit = min(configuredLimit, backgroundProcessorCount)
        } else {
            cpuLimit = backgroundProcessorCount
        }

        let niceEnabled = environment["SCAN_OCR_NICE"].map(Self.isTruthy) ?? false
        if niceEnabled {
            let configuredLevel = Self.nonEmpty(environment["SCAN_OCR_NICE_LEVEL"])
                .flatMap(Int.init) ?? 10
            niceLevel = min(max(configuredLevel, 1), 19)
        } else {
            niceLevel = nil
        }
    }

    private static func isTruthy(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": true
        default: false
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }
}

enum OCRSystemProcessorCount {
    static func detect() -> Int {
        var limits = [max(1, ProcessInfo.processInfo.activeProcessorCount)]
        let fileManager = FileManager.default

        if let text = try? String(contentsOfFile: "/sys/fs/cgroup/cpu.max", encoding: .utf8),
           let limit = quotaLimit(cpuMax: text)
        {
            limits.append(limit)
        } else {
            let v1Roots = ["/sys/fs/cgroup/cpu", "/sys/fs/cgroup"]
            for root in v1Roots {
                let quotaPath = "\(root)/cpu.cfs_quota_us"
                let periodPath = "\(root)/cpu.cfs_period_us"
                guard fileManager.fileExists(atPath: quotaPath),
                      let quota = try? String(contentsOfFile: quotaPath, encoding: .utf8),
                      let period = try? String(contentsOfFile: periodPath, encoding: .utf8),
                      let limit = quotaLimit(quota: quota, period: period)
                else {
                    continue
                }
                limits.append(limit)
                break
            }
        }

        for path in [
            "/sys/fs/cgroup/cpuset.cpus.effective",
            "/sys/fs/cgroup/cpuset/cpuset.cpus",
        ] {
            guard fileManager.fileExists(atPath: path),
                  let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let limit = cpusetLimit(text)
            else {
                continue
            }
            limits.append(limit)
            break
        }

        return limits.min() ?? 1
    }

    static func quotaLimit(cpuMax: String) -> Int? {
        let fields = cpuMax.split(whereSeparator: \Character.isWhitespace)
        guard fields.count >= 2, fields[0] != "max" else { return nil }
        return quotaLimit(quota: String(fields[0]), period: String(fields[1]))
    }

    static func quotaLimit(quota: String, period: String) -> Int? {
        guard let quotaValue = Int64(quota.trimmingCharacters(in: .whitespacesAndNewlines)),
              let periodValue = Int64(period.trimmingCharacters(in: .whitespacesAndNewlines)),
              quotaValue > 0,
              periodValue > 0
        else {
            return nil
        }
        return max(1, Int(quotaValue / periodValue))
    }

    static func cpusetLimit(_ value: String) -> Int? {
        var processors = Set<Int>()
        for component in value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",") {
            let bounds = component.split(separator: "-", maxSplits: 1)
            guard let first = bounds.first.flatMap({ Int($0) }) else { return nil }
            let last = bounds.count == 2 ? Int(bounds[1]) : first
            guard let last, first >= 0, last >= first else { return nil }
            processors.formUnion(first...last)
        }
        return processors.isEmpty ? nil : processors.count
    }
}
