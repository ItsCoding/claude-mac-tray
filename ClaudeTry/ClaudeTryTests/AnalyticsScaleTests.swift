import XCTest
@testable import ClaudeTry

/// Chart shaping (ChartPlot) and engine throughput on a large synthetic history.
final class AnalyticsScaleTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func bigSessions(count: Int, messagesEach: Int) -> [Session] {
        let models = ["claude-opus-4-1", "claude-sonnet-4-5", "claude-haiku-4-5"]
        return (0..<count).map { s in
            let start = now.addingTimeInterval(-Double(s) * 1800 - 100)
            let msgs = (0..<messagesEach).map { m in
                ClaudeMessage(timestamp: start.addingTimeInterval(Double(m) * 60), role: "assistant",
                              model: models[(s + m) % 3], inputTokens: 1000 + m, outputTokens: 100,
                              cacheReadTokens: 5000, cacheWriteTokens: 200,
                              toolCalls: m % 4 == 0 ? [ToolCall(name: "Bash", arguments: [:])] : [],
                              projectPath: "/w/p\(s % 40)", isBedrock: s % 9 == 0, linesAdded: m % 5, linesRemoved: 0)
            }
            return Session(id: UUID(), projectPath: "/w/p\(s % 40)", startTime: start,
                           endTime: start.addingTimeInterval(Double(messagesEach) * 60), messages: msgs)
        }
    }

    func test_largeHistory_buildsAndQueriesQuickly() {
        let sessions = bigSessions(count: 4000, messagesEach: 25)   // 100k messages
        let built = Date()
        let ds = AnalyticsDataset.build(from: sessions, pricing: .embedded, calendar: cal, now: now)
        XCTAssertLessThan(Date().timeIntervalSince(built), 10.0, "dataset build for 100k messages")
        XCTAssertEqual(ds.sessions.count, 4000)
        let start = Date()
        let q = AnalyticsQuery(window: DateInterval(start: now.addingTimeInterval(-90 * 86_400), end: now.addingTimeInterval(1)),
                               granularity: .hour, metric: .cost, groupBy: .project, filters: AnalyticsFilters())
        let r = AnalyticsEngine(dataset: ds, calendar: cal, now: now).run(q)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "a query over 100k messages must stay interactive")
        XCTAssertLessThanOrEqual(r.starts.count, AnalyticsEngine.maxBuckets)
        XCTAssertLessThanOrEqual(r.series.count, AnalyticsEngine.maxSeries)
        XCTAssertEqual(r.sessions.count, 4000)
        XCTAssertEqual(r.windowTotal.messages, 100_000, accuracy: 0.5)
    }

    private func result(metric: AnalyticsMetric) -> AnalyticsResult {
        let ds = AnalyticsDataset.build(from: bigSessions(count: 30, messagesEach: 4), pricing: .embedded, calendar: cal, now: now)
        let q = AnalyticsQuery(window: DateInterval(start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(1)),
                               granularity: .hour, metric: metric, groupBy: .model, filters: AnalyticsFilters())
        return AnalyticsEngine(dataset: ds, calendar: cal, now: now).run(q)
    }

    func test_plot_shareStacksToOneAndUsesPercentTicks() {
        let r = result(metric: .cost)
        let plot = ChartPlot(result: r, kind: .share, hidden: [], logScale: false, overlays: Overlays())
        XCTAssertEqual(plot.yTop, 1)
        XCTAssertEqual(plot.yTicks, [0, 0.25, 0.5, 0.75, 1])
        XCTAssertEqual(plot.yLabel(0.5), "50%")
        for i in 0..<r.starts.count where r.totals[i].cost > 0 {
            let sum = plot.points.filter { $0.date == r.starts[i] }.reduce(0) { $0 + $1.y }
            XCTAssertEqual(sum, 1, accuracy: 1e-9)
        }
        XCTAssertFalse(plot.showOverlays)
    }

    func test_plot_cumulativeEndsAtSeriesTotal() {
        let r = result(metric: .cost)
        let plot = ChartPlot(result: r, kind: .cumulative, hidden: [], logScale: false, overlays: Overlays())
        let first = r.series[0]
        let last = plot.points.filter { $0.series == first.key }.last!.y
        XCTAssertEqual(last, MetricAccumulator.sum(first.buckets).cost, accuracy: 1e-9)
    }

    func test_plot_hiddenSeriesAreDropped_andLogUsesDecadeTicks() {
        let r = result(metric: .tokens)
        let hide = r.series[0].key
        let plot = ChartPlot(result: r, kind: .lines, hidden: [hide], logScale: true, overlays: Overlays())
        XCTAssertFalse(plot.points.contains { $0.series == hide })
        XCTAssertTrue(plot.log)
        XCTAssertEqual(plot.yTicks.first, 0)
        XCTAssertEqual(plot.yLabel(0), "0")
        XCTAssertEqual(plot.yTicks, plot.yTicks.indices.map(Double.init))
    }

    func test_plot_overlaysOnlyForAdditiveKinds_andForecastExtendsDomain() {
        let r = result(metric: .cost)
        var o = Overlays(); o.comparePrevious = true; o.movingAverage = true; o.forecast = true
        let stacked = ChartPlot(result: r, kind: .stacked, hidden: [], logScale: false, overlays: o)
        XCTAssertNotNil(stacked.previous)
        XCTAssertNotNil(stacked.movingAverage)
        XCTAssertEqual(stacked.futureDates.count, r.forecastCount)
        XCTAssertGreaterThan(stacked.allDates.count, r.starts.count)
        let cum = ChartPlot(result: r, kind: .cumulative, hidden: [], logScale: false, overlays: o)
        XCTAssertNil(cum.previous)
        XCTAssertTrue(cum.futureDates.isEmpty)
    }
}
