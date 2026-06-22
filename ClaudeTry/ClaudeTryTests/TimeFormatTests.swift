import XCTest
@testable import ClaudeTry

final class TimeFormatTests: XCTestCase {
    func test_compactDuration_secondsOnly() {
        XCTAssertEqual(TimeFormat.compactDuration(ms: 0), "0s")
        XCTAssertEqual(TimeFormat.compactDuration(ms: 45_000), "45s")
    }

    func test_compactDuration_minutesAndSeconds() {
        XCTAssertEqual(TimeFormat.compactDuration(ms: 78_000), "1m 18s")
    }

    func test_compactDuration_wholeMinutesDropSeconds() {
        XCTAssertEqual(TimeFormat.compactDuration(ms: 1_860_000), "31m")
    }

    func test_compactDuration_hoursAndMinutes() {
        XCTAssertEqual(TimeFormat.compactDuration(ms: 3_840_000), "1h 4m")
    }

    func test_resetCountdown_hoursAndMinutes() {
        let from = Date(timeIntervalSince1970: 0)
        let to = Date(timeIntervalSince1970: 2 * 3600 + 14 * 60)
        XCTAssertEqual(TimeFormat.resetCountdown(to: to, from: from), "resets in 2h 14m")
    }

    func test_resetCountdown_daysAndHours() {
        let from = Date(timeIntervalSince1970: 0)
        let to = Date(timeIntervalSince1970: 3 * 86_400 + 4 * 3600)
        XCTAssertEqual(TimeFormat.resetCountdown(to: to, from: from), "resets in 3d 4h")
    }

    func test_resetCountdown_pastIsResetting() {
        let from = Date(timeIntervalSince1970: 100)
        let to = Date(timeIntervalSince1970: 50)
        XCTAssertEqual(TimeFormat.resetCountdown(to: to, from: from), "resetting…")
    }
}
