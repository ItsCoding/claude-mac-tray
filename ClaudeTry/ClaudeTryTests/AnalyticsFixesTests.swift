import XCTest
@testable import ClaudeTry

final class AnalyticsFixesTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }
    private var now: Date { date(12, 12, 30) }

    private func msg(_ t: Date, bedrock: Bool = false, model: String = "claude-opus-4-5") -> ClaudeMessage {
        ClaudeMessage(timestamp: t, role: "assistant", model: model, inputTokens: 1000, outputTokens: 100,
                      cacheReadTokens: 0, cacheWriteTokens: 0, toolCalls: [], projectPath: "/w/a",
                      isBedrock: bedrock, linesAdded: 0, linesRemoved: 0,
                      isOpenCode: false, precomputedCostUSD: nil)
    }
    private func session(_ msgs: [ClaudeMessage]) -> Session {
        Session(id: UUID(), projectPath: "/w/a", startTime: msgs[0].timestamp, endTime: msgs.last!.timestamp, messages: msgs)
    }

    func test_sessionIDsAreStableAcrossRescans() {
        let msgs = [msg(date(12, 10)), msg(date(12, 11))]
        let a = AnalyticsDataset.build(from: [session(msgs)], pricing: .embedded, calendar: cal, now: now)
        let b = AnalyticsDataset.build(from: [session(msgs)], pricing: .embedded, calendar: cal, now: now)
        XCTAssertEqual(a.sessions[0].id, b.sessions[0].id)
        XCTAssertEqual(a.sessions[0].id.count, 16)
    }

    func test_bedrockMessagesAreExcludedFromPredictionCostPoints() {
        let ds = AnalyticsDataset.build(from: [session([msg(date(12, 10)), msg(date(12, 11), bedrock: true)])],
                                        pricing: .embedded, calendar: cal, now: now)
        XCTAssertEqual(ds.costPoints.count, 1)
        XCTAssertEqual(ds.fragments.reduce(0) { $0 + $1.messages }, 2)   // analytics still shows both
        XCTAssertNotNil(ds.costPoints[0].sonnetCost)                    // opus point carries a catalog Sonnet price
        XCTAssertLessThan(ds.costPoints[0].sonnetCost!, ds.costPoints[0].cost)
    }

    func test_rollingWindowIncludesTheWholeFirstBucket() {
        // window starts 12:30 on Oct 12 but a message was sent at 12:10 (same hour bucket)
        let ds = AnalyticsDataset.build(from: [session([msg(date(12, 12, 10))])], pricing: .embedded, calendar: cal, now: now)
        let q = AnalyticsQuery(window: DateInterval(start: date(12, 12, 20), end: now.addingTimeInterval(1)),
                               granularity: .hour, metric: .messages, groupBy: .model, filters: AnalyticsFilters())
        let r = AnalyticsEngine(dataset: ds, calendar: cal, now: now).run(q)
        XCTAssertEqual(r.windowTotal.messages, 1)
    }

    func test_hourFilterWrapsAroundMidnight() {
        var f = AnalyticsFilters(); f.hourFrom = 22; f.hourTo = 6
        XCTAssertTrue(f.containsHour(23)); XCTAssertTrue(f.containsHour(0)); XCTAssertTrue(f.containsHour(6))
        XCTAssertFalse(f.containsHour(12)); XCTAssertFalse(f.containsHour(21))
        let ds = AnalyticsDataset.build(from: [session([msg(date(11, 23)), msg(date(12, 3)), msg(date(12, 9))])],
                                        pricing: .embedded, calendar: cal, now: now)
        let q = AnalyticsQuery(window: DateInterval(start: date(10, 0), end: now), granularity: .day,
                               metric: .messages, groupBy: .model, filters: f)
        XCTAssertEqual(AnalyticsEngine(dataset: ds, calendar: cal, now: now).run(q).windowTotal.messages, 2)
    }

    func test_savedViewDecodingIsForgiving() throws {
        // Old/partial JSON with a missing key and an unknown enum value still decodes.
        let json = #"{"range":"30d","metric":"nonsense","filters":{"minCost":2},"overlays":{"forecast":true}}"#
        let s = try JSONDecoder().decode(AnalyticsViewState.self, from: Data(json.utf8))
        XCTAssertEqual(s.range, .month)
        XCTAssertEqual(s.metric, .cost)             // unknown value -> default
        XCTAssertEqual(s.filters.minCost, 2)
        XCTAssertEqual(s.filters.hourTo, 23)
        XCTAssertTrue(s.overlays.forecast)
        XCTAssertTrue(s.overlays.outliers)          // default preserved
    }

    @MainActor func test_savedViewsKeepGoodEntriesAndNeverOverwriteUnreadableStorage() {
        let suite = UserDefaults(suiteName: "AnalyticsFixesTests.\(UUID().uuidString)")!
        let good = #"{"name":"ok","state":{"range":"7d"}}"#
        let bad = #"{"state":{}}"#                  // no name
        suite.set(Data("[\(good),\(bad)]".utf8), forKey: "analytics.savedViews")
        let vm = AnalyticsViewModel(defaults: suite)
        XCTAssertEqual(vm.savedViews.map(\.name), ["ok"])
        XCTAssertNotNil(suite.data(forKey: "analytics.savedViews.backup"))

        let garbage = Data("not json".utf8)
        suite.set(garbage, forKey: "analytics.savedViews")
        let vm2 = AnalyticsViewModel(defaults: suite)
        vm2.saveCurrentView(named: "new")
        XCTAssertEqual(suite.data(forKey: "analytics.savedViews"), garbage)   // untouched
    }

    func test_csvNeutralisesFormulasAndUsesLocalTimestamps() {
        XCTAssertEqual(AnalyticsCSV.text("=SUM(A1)"), "\"'=SUM(A1)\"")
        XCTAssertEqual(AnalyticsCSV.text("@cmd"), "\"'@cmd\"")
        XCTAssertEqual(AnalyticsCSV.text("safe"), "\"safe\"")
        let row = SessionRow(id: "=x", start: date(12, 10), project: "-p", model: "m", profile: .anthropic, isSubagent: false,
                             messages: 1, toolCalls: 0, tokens: 1, cost: 1, linesAdded: 0, linesRemoved: 0, cacheHit: 0, durationSec: 1)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(secondsFromGMT: 7200)!
        let csv = AnalyticsCSV.sessions([row], calendar: local)
        XCTAssertTrue(csv.contains("2026-10-12T12:00:00+02:00"))
        XCTAssertTrue(csv.contains("\"'=x\""))
        XCTAssertTrue(csv.contains("\"'-p\""))
    }
}
