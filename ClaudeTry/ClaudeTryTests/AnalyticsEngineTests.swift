import XCTest
@testable import ClaudeTry

final class AnalyticsEngineTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }()

    private func date(_ d: Int, _ h: Int, _ m: Int = 0, month: Int = 10) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: d, hour: h, minute: m))!
    }
    private var now: Date { date(12, 12) }

    private func msg(_ t: Date, _ model: String, i: Int = 0, o: Int = 0, cr: Int = 0, cw: Int = 0,
                     tools: [String] = [], added: Int = 0, removed: Int = 0, bedrock: Bool = false,
                     path: String = "/w/alpha") -> ClaudeMessage {
        ClaudeMessage(timestamp: t, role: "assistant", model: model, inputTokens: i, outputTokens: o,
                      cacheReadTokens: cr, cacheWriteTokens: cw,
                      toolCalls: tools.map { ToolCall(name: $0, arguments: [:]) }, projectPath: path,
                      isBedrock: bedrock, linesAdded: added, linesRemoved: removed,
                      isOpenCode: false, precomputedCostUSD: nil)
    }
    private func session(_ path: String, _ msgs: [ClaudeMessage]) -> Session {
        Session(id: UUID(), projectPath: path, startTime: msgs.first!.timestamp,
                endTime: msgs.last!.timestamp, messages: msgs)
    }

    /// A: alpha / opus, 2 hours, Oct 11.  B: beta / sonnet, bedrock, Oct 12.  C: alpha subagent / haiku, Oct 5.
    private func dataset() -> AnalyticsDataset {
        let a = session("/w/alpha", [
            msg(date(11, 10, 5), "claude-opus-4-1", i: 1000, o: 100, tools: ["Bash"], added: 10, path: "/w/alpha"),
            msg(date(11, 10, 20), "claude-opus-4-1", i: 1000, o: 100, cr: 8000, tools: ["Edit", "Bash"], removed: 4, path: "/w/alpha"),
            msg(date(11, 11, 10), "claude-opus-4-1", i: 500, o: 50, path: "/w/alpha")])
        let b = session("/w/beta", [
            msg(date(12, 9, 30), "claude-sonnet-4-5", i: 2000, o: 200, bedrock: true, path: "/w/beta"),
            msg(date(12, 9, 40), "claude-sonnet-4-5", i: 2000, o: 200, bedrock: true, path: "/w/beta")])
        let c = session("/w/alpha/.claude/worktrees/agent-1", [
            msg(date(5, 14, 0), "claude-haiku-4-5", i: 4000, o: 400, path: "/w/alpha/.claude/worktrees/agent-1")])
        return AnalyticsDataset.build(from: [a, b, c], pricing: .embedded, calendar: cal, now: now)
    }

    private func query(_ ds: AnalyticsDataset, metric: AnalyticsMetric = .cost, g: Granularity = .day,
                       by: GroupBy = .model, filters: AnalyticsFilters = AnalyticsFilters(),
                       from: Date? = nil, to: Date? = nil) -> AnalyticsResult {
        let q = AnalyticsQuery(window: DateInterval(start: from ?? date(4, 0), end: to ?? now),
                               granularity: g, metric: metric, groupBy: by, filters: filters)
        return AnalyticsEngine(dataset: ds, calendar: cal, now: now).run(q)
    }

    private let eps = 1e-9
    private func opusCost(i: Int, o: Int, cr: Int = 0) -> Double { Double(i) * 15e-6 + Double(o) * 75e-6 + Double(cr) * 1.5e-6 }

    // MARK: dataset

    func test_build_groupsMessagesIntoHourFragmentsAndCountsSessionsOnce() {
        let ds = dataset()
        XCTAssertEqual(ds.sessions.count, 3)
        // A spans two hours (10:xx, 11:xx); B one hour; C one hour.
        XCTAssertEqual(ds.fragments.count, 4)
        XCTAssertEqual(ds.fragments.map(\.sessionsStarted).reduce(0, +), 3, accuracy: eps)
        XCTAssertEqual(ds.sessions.filter(\.isSubagent).count, 1)
        XCTAssertEqual(ds.sessions.filter { $0.project == "alpha" }.count, 2) // worktree maps to parent project
        XCTAssertEqual(ds.fragments.map(\.time), ds.fragments.map(\.time).sorted())
    }

    // MARK: metrics

    func test_cost_totalsMatchPricing() {
        let r = query(dataset())
        let expectedA = opusCost(i: 2500, o: 250, cr: 8000)
        let sonnet = Double(4000) * 3e-6 + Double(400) * 15e-6
        let haiku = Double(4000) * 1e-6 + Double(400) * 5e-6
        XCTAssertEqual(r.windowTotal.cost, expectedA + sonnet + haiku, accuracy: 1e-9)
    }

    func test_cacheHit_isCacheReadOverAllInputSide() {
        let r = query(dataset(), metric: .cacheHit, filters: AnalyticsFilters(models: ["Opus 4.1"]))
        XCTAssertEqual(AnalyticsMetric.cacheHit.value(r.windowTotal), 8000.0 / (2500 + 8000), accuracy: eps)
    }

    func test_sessionsAndMessagesAndDuration() {
        let r = query(dataset())
        XCTAssertEqual(AnalyticsMetric.sessions.value(r.windowTotal), 3, accuracy: eps)
        XCTAssertEqual(AnalyticsMetric.messages.value(r.windowTotal), 6, accuracy: eps)
        // durations: A 65 min, B 10 min, C 0 -> avg 25 min
        XCTAssertEqual(AnalyticsMetric.avgSessionMinutes.value(r.windowTotal), 25, accuracy: eps)
        XCTAssertEqual(AnalyticsMetric.tokensPerSession.value(r.windowTotal), r.windowTotal.totalTokens / 3, accuracy: eps)
    }

    func test_costPerLine_andLines() {
        let r = query(dataset(), by: .project)
        XCTAssertEqual(r.windowTotal.linesAdded, 10, accuracy: eps)
        XCTAssertEqual(r.windowTotal.linesRemoved, 4, accuracy: eps)
        XCTAssertEqual(AnalyticsMetric.costPerLine.value(r.windowTotal), r.windowTotal.cost / 10, accuracy: eps)
        XCTAssertEqual(AnalyticsMetric.costPerLine.value(MetricAccumulator()), 0)
    }

    // MARK: filtering

    func test_filter_byModel_projectProfileAgent() {
        let ds = dataset()
        var f = AnalyticsFilters(); f.models = ["Sonnet 4.5"]
        XCTAssertEqual(query(ds, filters: f).windowTotal.messages, 2, accuracy: eps)
        f = AnalyticsFilters(); f.projects = ["alpha"]
        XCTAssertEqual(query(ds, filters: f).windowTotal.messages, 4, accuracy: eps) // main + subagent
        f.agent = .subagent
        XCTAssertEqual(query(ds, filters: f).windowTotal.messages, 1, accuracy: eps)
        f = AnalyticsFilters(); f.profile = .bedrock
        XCTAssertEqual(query(ds, filters: f).windowTotal.sessions, 1, accuracy: eps)
        f.profile = .anthropic
        XCTAssertEqual(query(ds, filters: f).windowTotal.sessions, 2, accuracy: eps)
    }

    func test_filter_toolSizeMinCostHourWeekdayAndSearch() {
        let ds = dataset()
        var f = AnalyticsFilters(); f.tools = ["Edit"]
        XCTAssertEqual(query(ds, filters: f).windowTotal.sessions, 1, accuracy: eps)
        f = AnalyticsFilters(); f.size = .small
        XCTAssertEqual(query(ds, filters: f).windowTotal.sessions, 3, accuracy: eps)
        f.size = .large
        XCTAssertEqual(query(ds, filters: f).windowTotal.sessions, 0, accuracy: eps)
        f = AnalyticsFilters(); f.minCost = 0.01
        XCTAssertEqual(query(ds, filters: f).windowTotal.sessions, 2, accuracy: eps) // A (0.068) and B (0.018) pass, C (0.0064) not
        f = AnalyticsFilters(); f.hourFrom = 9; f.hourTo = 10
        XCTAssertEqual(query(ds, filters: f).windowTotal.messages, 4, accuracy: eps) // A's 10:xx pair + B's 9:xx pair
        f = AnalyticsFilters(); f.weekday = .weekend // Oct 11 2026 is a Sunday, Oct 12 Monday, Oct 5 Monday
        XCTAssertEqual(query(ds, filters: f).windowTotal.messages, 3, accuracy: eps)
        f = AnalyticsFilters(); f.search = "BEDROCK"
        XCTAssertEqual(query(ds, filters: f).windowTotal.sessions, 1, accuracy: eps)
        f.search = "nothing-matches"
        XCTAssertEqual(query(ds, filters: f).windowTotal.sessions, 0, accuracy: eps)
    }

    func test_windowExcludesOutsideFragments() {
        let r = query(dataset(), from: date(11, 0), to: date(12, 0))
        XCTAssertEqual(r.windowTotal.messages, 3, accuracy: eps)
    }

    // MARK: bucketing

    func test_dayBuckets_alignToMidnightAndSumToTotal() {
        let r = query(dataset(), from: date(4, 0), to: date(13, 0))
        XCTAssertEqual(r.starts.count, 9)
        XCTAssertEqual(r.starts.first, date(4, 0))
        let idx11 = r.starts.firstIndex(of: date(11, 0))!
        XCTAssertEqual(r.totals[idx11].messages, 3, accuracy: eps)
        XCTAssertEqual(r.totals.reduce(0) { $0 + $1.cost }, r.windowTotal.cost, accuracy: eps)
    }

    func test_hourBuckets_splitSessionAcrossHours() {
        let r = query(dataset(), g: .hour, from: date(11, 0), to: date(12, 0))
        XCTAssertEqual(r.starts.count, 24)
        XCTAssertEqual(r.totals[10].messages, 2, accuracy: eps)
        XCTAssertEqual(r.totals[11].messages, 1, accuracy: eps)
        // the session is counted only in the hour of its first message
        XCTAssertEqual(r.totals[10].sessions, 1, accuracy: eps)
        XCTAssertEqual(r.totals[11].sessions, 0, accuracy: eps)
    }

    func test_weekBuckets_startOnMonday() {
        let r = query(dataset(), g: .week, from: date(5, 0), to: date(13, 0))
        XCTAssertEqual(r.starts, [date(5, 0), date(12, 0)])
        XCTAssertEqual(r.totals[0].messages, 4, accuracy: eps) // Oct 5 (C) + Oct 11 (A, Sunday)
        XCTAssertEqual(r.totals[1].messages, 2, accuracy: eps)
    }

    func test_granularityCoarsensWhenTooManyBuckets() {
        let r = query(dataset(), g: .hour, from: date(1, 0, month: 1), to: now)
        XCTAssertNotEqual(r.granularity, .hour)
        XCTAssertLessThanOrEqual(r.starts.count, AnalyticsEngine.maxBuckets)
    }

    // MARK: grouping

    func test_groupByModel_seriesSumToTotalAndOrderByFamily() {
        let r = query(dataset())
        XCTAssertEqual(r.series.map(\.key), ["Opus 4.1", "Sonnet 4.5", "Haiku 4.5"])
        let sum = r.series.reduce(0.0) { $0 + MetricAccumulator.sum($1.buckets).cost }
        XCTAssertEqual(sum, r.windowTotal.cost, accuracy: eps)
    }

    func test_groupByTool_weightsByCallShareAndKeepsTotals() {
        let r = query(dataset(), by: .tool)
        XCTAssertTrue(r.series.contains { $0.key == "Bash" })
        XCTAssertTrue(r.series.contains { $0.key == AnalyticsEngine.noToolKey })
        let sum = r.series.reduce(0.0) { $0 + MetricAccumulator.sum($1.buckets).cost }
        XCTAssertEqual(sum, r.windowTotal.cost, accuracy: 1e-9)
    }

    func test_groupByProject_andProfile() {
        XCTAssertEqual(Set(query(dataset(), by: .project).series.map(\.key)), ["alpha", "beta"])
        XCTAssertEqual(Set(query(dataset(), by: .profile).series.map(\.key)), ["Claude.ai", "Bedrock"])
    }

    func test_longTailCollapsesIntoOther() {
        var sessions: [Session] = []
        for i in 0..<12 {
            sessions.append(session("/w/p\(i)", [msg(date(11, 10), "claude-opus-4-1", i: 1000 * (i + 1), path: "/w/p\(i)")]))
        }
        let ds = AnalyticsDataset.build(from: sessions, pricing: .embedded, calendar: cal, now: now)
        let r = query(ds, by: .project)
        XCTAssertEqual(r.series.count, AnalyticsEngine.maxSeries)
        XCTAssertEqual(r.series.last?.key, AnalyticsEngine.otherKey)
        XCTAssertEqual(r.series.first?.key, "p11") // biggest first
        let sum = r.series.reduce(0.0) { $0 + MetricAccumulator.sum($1.buckets).cost }
        XCTAssertEqual(sum, r.windowTotal.cost, accuracy: 1e-9)
    }

    // MARK: period comparison

    func test_previousPeriod_isEqualLengthAndAligned() {
        // window Oct 11 00:00 .. Oct 13 00:00 (2 days); previous = Oct 9..Oct 11 (nothing); shift to cover Oct 5.
        let r = query(dataset(), from: date(11, 0), to: date(13, 0))
        XCTAssertEqual(r.previous.count, r.starts.count)
        XCTAssertEqual(r.previousTotal.messages, 0, accuracy: eps)
        let r2 = query(dataset(), from: date(6, 0), to: date(8, 0)) // previous = Oct 4..6 contains C (Oct 5)
        XCTAssertEqual(r2.previous[1].messages, 1, accuracy: eps)
        XCTAssertEqual(r2.previousTotal.cost, Double(4000) * 1e-6 + Double(400) * 5e-6, accuracy: eps)
    }

    // MARK: sessions & mini

    func test_sessionRows_matchFilteredWindow() {
        var f = AnalyticsFilters(); f.models = ["Opus 4.1"]
        let r = query(dataset(), filters: f)
        XCTAssertEqual(r.sessions.count, 1)
        XCTAssertEqual(r.sessions[0].messages, 3)
        XCTAssertEqual(r.sessions[0].toolCalls, 3)
        XCTAssertEqual(r.sessions[0].cost, opusCost(i: 2500, o: 250, cr: 8000), accuracy: eps)
        XCTAssertEqual(r.sessions[0].durationSec, 65 * 60, accuracy: eps)
    }

    func test_heatmap_cellsByWeekdayAndHour() {
        let r = query(dataset())
        // Oct 11 2026 is a Sunday (index 6), 10:xx
        XCTAssertEqual(r.heat[6][10].messages, 2, accuracy: eps)
        XCTAssertEqual(r.heat[0][9].messages, 2, accuracy: eps) // Monday Oct 12 09:xx
    }

    func test_mini_usesSessionsForRatioMetrics() {
        let r = query(dataset(), metric: .cacheHit)
        XCTAssertEqual(r.mini.values.reduce(0, +), 3, accuracy: eps)
        XCTAssertEqual(r.mini.starts.count, r.mini.values.count)
    }

    // MARK: overlays math

    func test_movingAverage() {
        XCTAssertEqual(AnalyticsMath.movingAverage([2, 4, 6, 8], window: 2), [2, 3, 5, 7])
    }

    func test_linearForecast_extendsTrendAndClampsAtZero() {
        let up = AnalyticsMath.linearForecast([1, 2, 3, 4, 5], count: 2)
        XCTAssertEqual(up[0], 6, accuracy: 1e-9)
        XCTAssertEqual(up[1], 7, accuracy: 1e-9)
        XCTAssertEqual(AnalyticsMath.linearForecast([3, 2, 1], count: 3), [0, 0, 0])
        XCTAssertTrue(AnalyticsMath.linearForecast([1, 2], count: 3).isEmpty)
    }

    func test_outliers_flagValuesAboveTwoSigma() {
        var v = Array(repeating: 1.0, count: 12)
        v[5] = 30
        XCTAssertEqual(AnalyticsMath.outliers(v), [5])
        XCTAssertTrue(AnalyticsMath.outliers([1, 1, 50]).isEmpty) // too few buckets
        XCTAssertTrue(AnalyticsMath.outliers(Array(repeating: 2.0, count: 10)).isEmpty)
    }

    // MARK: state + csv

    func test_viewState_windowResolution() {
        var s = AnalyticsViewState()
        s.range = .day
        let w = s.window(now: now, dataStart: nil, calendar: cal)
        XCTAssertEqual(w.duration, 86_401, accuracy: 1)
        s.range = .all
        XCTAssertEqual(s.window(now: now, dataStart: date(5, 14), calendar: cal).start, date(5, 0))
        s.range = .custom; s.customFrom = date(3, 9); s.customTo = date(4, 20)
        let c = s.window(now: now, dataStart: nil, calendar: cal)
        XCTAssertEqual(c.start, date(3, 0)); XCTAssertEqual(c.end, date(5, 0))
    }

    func test_viewState_roundTripsThroughJSON() throws {
        var s = AnalyticsViewState()
        s.metric = .cacheHit; s.filters.models = ["Opus 4.1"]; s.overlays.forecast = true
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(AnalyticsViewState.self, from: data), s)
    }

    func test_csv_bucketsAndSessions() {
        let r = query(dataset(), from: date(10, 0), to: date(13, 0))
        let lines = AnalyticsCSV.buckets(r, calendar: cal).split(separator: "\n")
        XCTAssertEqual(lines.count, 1 + r.starts.count)
        XCTAssertTrue(lines[0].contains("\"Opus 4.1\""))
        XCTAssertTrue(lines[0].hasSuffix("\"total\""))
        let sess = AnalyticsCSV.sessions(r.sessions).split(separator: "\n")
        XCTAssertEqual(sess.count, 1 + r.sessions.count)
        XCTAssertEqual(AnalyticsCSV.quote("a\"b"), "\"a\"\"b\"")
    }

    func test_formatters() {
        XCTAssertEqual(AnalyticsFormat.tokens(1_500_000), "1.5M")
        XCTAssertEqual(AnalyticsFormat.money(3.456), "$3.46")
        XCTAssertEqual(AnalyticsFormat.percent(0.256), "25.6%")
        XCTAssertEqual(AnalyticsFormat.duration(seconds: 125), "2m 05s")
    }
}
