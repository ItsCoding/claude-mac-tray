import XCTest
@testable import ClaudeTry

final class AppConfigTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "appconfig-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func test_budgets_defaultsWhenUnset() {
        let cfg = AppConfig(defaults: freshDefaults())
        XCTAssertEqual(cfg.budgets, Budgets(weeklyUSD: 50, sessionUSD: 10))
    }

    func test_budgets_persistAndReadBack() {
        let d = freshDefaults()
        AppConfig(defaults: d).budgets = Budgets(weeklyUSD: 80, sessionUSD: 15)
        XCTAssertEqual(AppConfig(defaults: d).budgets, Budgets(weeklyUSD: 80, sessionUSD: 15))
    }

    func test_budgets_zeroIsPreserved() {
        let d = freshDefaults()
        AppConfig(defaults: d).budgets = Budgets(weeklyUSD: 0, sessionUSD: 0)
        XCTAssertEqual(AppConfig(defaults: d).budgets, Budgets(weeklyUSD: 0, sessionUSD: 0))
    }

    func test_previousStatusLine_roundTripsAndClears() {
        let d = freshDefaults()
        let cfg = AppConfig(defaults: d)
        XCTAssertNil(cfg.previousStatusLine)
        cfg.previousStatusLine = #"{"type":"command","command":"foo"}"#
        XCTAssertEqual(AppConfig(defaults: d).previousStatusLine, #"{"type":"command","command":"foo"}"#)
        cfg.previousStatusLine = nil
        XCTAssertNil(AppConfig(defaults: d).previousStatusLine)
    }
}
