import XCTest
@testable import ClaudeTry

final class LimitsModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func snap(five: RateWindow? = nil, seven: RateWindow? = nil,
                      api: Int? = nil, wall: Int? = nil, id: String = "s") -> UsageSnapshot {
        UsageSnapshot(sessionID: id, writtenAt: now, costUSD: nil,
                      apiDurationMs: api, wallDurationMs: wall, fiveHour: five, sevenDay: seven)
    }

    func test_anthropicMode_whenRateLimitsPresent() {
        let s = snap(five: RateWindow(usedPercentage: 23.5, resetsAt: now.addingTimeInterval(3600)),
                     seven: RateWindow(usedPercentage: 41, resetsAt: now.addingTimeInterval(86_400)))
        let m = LimitsModel.make(freshest: s, active: [s], sessionCostUSD: 0, weeklyCostUSD: 0,
                                 budgets: Budgets(weeklyUSD: 50, sessionUSD: 10), now: now)
        XCTAssertEqual(m.mode, .anthropic)
        XCTAssertEqual(m.session.fraction, 0.235, accuracy: 0.0001)
        XCTAssertEqual(m.session.primaryLabel, "24%")          // rounded
        XCTAssertTrue(m.session.isReal)
        XCTAssertEqual(m.session.detailLabel, "resets in 1h 0m")
    }

    func test_bedrockMode_whenNoRateLimits() {
        let s = snap()
        let m = LimitsModel.make(freshest: s, active: [s], sessionCostUSD: 4, weeklyCostUSD: 25,
                                 budgets: Budgets(weeklyUSD: 50, sessionUSD: 10), now: now)
        XCTAssertEqual(m.mode, .bedrock)
        XCTAssertEqual(m.session.fraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(m.session.primaryLabel, "$4.00 / $10")
        XCTAssertFalse(m.session.isReal)
        XCTAssertEqual(m.weekly.fraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(m.weekly.primaryLabel, "$25.00 / $50")
    }

    func test_noSnapshots_isBedrock() {
        let m = LimitsModel.make(freshest: nil, active: [], sessionCostUSD: 0, weeklyCostUSD: 0,
                                 budgets: Budgets(weeklyUSD: 50, sessionUSD: 10), now: now)
        XCTAssertEqual(m.mode, .bedrock)
    }

    func test_partialRateLimits_fallBackPerWindow() {
        // Only the 5-hour window is real; the 7-day window falls back to Bedrock.
        let s = snap(five: RateWindow(usedPercentage: 10, resetsAt: now.addingTimeInterval(600)))
        let m = LimitsModel.make(freshest: s, active: [s], sessionCostUSD: 1, weeklyCostUSD: 30,
                                 budgets: Budgets(weeklyUSD: 60, sessionUSD: 10), now: now)
        XCTAssertEqual(m.mode, .anthropic)
        XCTAssertTrue(m.session.isReal)
        XCTAssertFalse(m.weekly.isReal)
        XCTAssertEqual(m.weekly.fraction, 0.5, accuracy: 0.0001)
    }

    func test_budgetZero_showsRawCostNoFill() {
        let m = LimitsModel.make(freshest: snap(), active: [], sessionCostUSD: 7, weeklyCostUSD: 0,
                                 budgets: Budgets(weeklyUSD: 0, sessionUSD: 0), now: now)
        XCTAssertEqual(m.session.fraction, 0)
        XCTAssertEqual(m.session.primaryLabel, "$7.00")
    }

    func test_timing_sumsActiveSnapshots() {
        let a = snap(api: 1000, wall: 5000, id: "a")
        let b = snap(api: 2000, wall: 7000, id: "b")
        let m = LimitsModel.make(freshest: a, active: [a, b], sessionCostUSD: 0, weeklyCostUSD: 0,
                                 budgets: Budgets(weeklyUSD: 50, sessionUSD: 10), now: now)
        XCTAssertEqual(m.timing, TimingReadout(apiMs: 3000, wallMs: 12000, activeSessions: 2))
    }
}
