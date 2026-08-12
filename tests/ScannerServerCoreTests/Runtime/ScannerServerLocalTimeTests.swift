import Foundation
import ScannerServerCore
import Testing

@Suite("Scanner server local time")
struct ScannerServerLocalTimeTests {
    @Test("TZ controls both document names and displayed status timestamps")
    func configuredTimeZone() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let date = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 12,
            hour: 12,
            minute: 34,
            second: 56
        )))
        let localTime = ScannerServerLocalTime(
            environment: ["TZ": "Europe/Berlin"],
            fallback: utc
        )

        #expect(localTime.scanTimestamp(for: date).rawValue == "2026-08-12.143456")
        #expect(localTime.statusTimestamp(for: date) == "2026-08-12T14:34:56+02:00")
    }

    @Test("Missing or invalid TZ uses the process-local fallback")
    func fallbackTimeZone() {
        let fallback = TimeZone(identifier: "America/New_York")!

        #expect(ScannerServerLocalTime(environment: [:], fallback: fallback).timeZone == fallback)
        #expect(
            ScannerServerLocalTime(environment: ["TZ": "not/a-zone"], fallback: fallback).timeZone
                == fallback
        )
    }
}
