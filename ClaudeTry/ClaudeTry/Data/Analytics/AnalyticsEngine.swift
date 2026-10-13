import Foundation

struct SeriesData: Sendable {
    let key: String
    let buckets: [MetricAccumulator]
}

struct SessionRow: Identifiable, Sendable {
    let id: String
    let start: Date
    let project: String
    let model: String
    let profile: ClaudeProfile
    let isSubagent: Bool
    let messages: Int
    let toolCalls: Int
    let tokens: Int
    let cost: Double
    let linesAdded: Int
    let linesRemoved: Int
    let cacheHit: Double
    let durationSec: Double
    var shortID: String { String(id.prefix(8)) }
}

struct MiniSeries: Sendable {
    var starts: [Date] = []
    var values: [Double] = []
}

struct AnalyticsResult: Sendable {
    var query: AnalyticsQuery
    /// Granularity actually used (coarsened if the window had too many buckets).
    var granularity: Granularity
    var starts: [Date] = []
    var series: [SeriesData] = []
    var totals: [MetricAccumulator] = []
    var previous: [MetricAccumulator] = []   // aligned to `starts`
    var heat: [[MetricAccumulator]] = []     // [weekday 0=Mon][hour]
    var sessions: [SessionRow] = []
    var mini = MiniSeries()
    var bucketEnds: [Date] = []

    var metric: AnalyticsMetric { query.metric }
    var bucketCount: Int { starts.count }

    var totalValues: [Double] { totals.map(metric.value) }
    var previousValues: [Double] { previous.map(metric.value) }
    func values(of s: SeriesData) -> [Double] { s.buckets.map(metric.value) }

    var windowTotal: MetricAccumulator { .sum(totals) }
    var previousTotal: MetricAccumulator { .sum(previous) }

    var movingAverage: [Double] {
        let w = max(2, granularity == .hour ? 6 : granularity == .day ? 7 : 2)
        return AnalyticsMath.movingAverage(totalValues, window: w)
    }
    var forecastCount: Int { max(3, Int((Double(bucketCount) * 0.25).rounded())) }
    var forecast: [Double] { AnalyticsMath.linearForecast(totalValues, count: forecastCount) }
    var outliers: [Int] { AnalyticsMath.outliers(totalValues) }
}

/// Small numeric helpers, split out so they can be tested directly.
enum AnalyticsMath {
    static func movingAverage(_ v: [Double], window w: Int) -> [Double] {
        v.indices.map { i in
            let slice = v[max(0, i - w + 1)...i]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    /// Least-squares line over the last (up to) 12 values, projected `count` steps ahead.
    static func linearForecast(_ v: [Double], count: Int) -> [Double] {
        let m = min(12, v.count)
        guard m >= 3, count > 0 else { return [] }
        let xs = Array(v.suffix(m))
        let mx = Double(m - 1) / 2, my = xs.reduce(0, +) / Double(m)
        var num = 0.0, den = 0.0
        for (i, y) in xs.enumerated() { num += (Double(i) - mx) * (y - my); den += pow(Double(i) - mx, 2) }
        let slope = den > 0 ? num / den : 0
        return (1...count).map { j in max(0, my + slope * (Double(m - 1) - mx + Double(j))) }
    }

    /// Indices more than 2 standard deviations above the mean (needs >= 8 buckets).
    static func outliers(_ v: [Double]) -> [Int] {
        guard v.count >= 8 else { return [] }
        let mu = v.reduce(0, +) / Double(v.count)
        let sd = (v.reduce(0) { $0 + pow($1 - mu, 2) } / Double(v.count)).squareRoot()
        guard sd > 0 else { return [] }
        return v.indices.filter { v[$0] > mu + 2 * sd }
    }
}

/// filter -> bucket -> metric. Pure and Sendable: run it off the main thread.
struct AnalyticsEngine: Sendable {
    let dataset: AnalyticsDataset
    var calendar: Calendar = .current
    var now: Date = Date()

    static let maxBuckets = 1200
    static let maxSeries = 8
    static let otherKey = "Other"
    static let noToolKey = "No tools"

    // MARK: Buckets

    func bucketStart(_ date: Date, _ g: Granularity) -> Date {
        calendar.dateInterval(of: g.component, for: date)?.start ?? date
    }

    func bucketStarts(for window: DateInterval, _ g: Granularity) -> [Date] {
        var out: [Date] = []
        var c = bucketStart(window.start, g)
        while c < window.end {
            out.append(c)
            guard let n = calendar.date(byAdding: g.component, value: 1, to: c), n > c else { break }
            c = n
            if out.count > 100_000 { break }
        }
        return out
    }

    /// Coarsens the granularity until the bucket count is sane.
    func plan(window: DateInterval, granularity: Granularity) -> (Granularity, [Date]) {
        var g = granularity
        var starts = bucketStarts(for: window, g)
        while starts.count > Self.maxBuckets, let c = g.coarser {
            g = c
            starts = bucketStarts(for: window, g)
        }
        return (g, starts)
    }

    private func index(of date: Date, in starts: [Date]) -> Int? {
        guard let first = starts.first, date >= first else { return nil }
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= date { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    // MARK: Filtering

    /// Session-level predicate results (project, tool, profile, agent type, size, cost, search).
    func sessionMask(_ f: AnalyticsFilters) -> [Bool] {
        let needle = f.search.trimmingCharacters(in: .whitespaces).lowercased()
        return dataset.sessions.map { s in
            if !f.projects.isEmpty && !f.projects.contains(s.project) { return false }
            if !f.tools.isEmpty && f.tools.isDisjoint(with: s.tools) { return false }
            switch f.profile {
            case .all: break
            case .anthropic: if s.profile != .anthropic { return false }
            case .bedrock: if s.profile != .bedrock { return false }
            }
            switch f.agent {
            case .all: break
            case .main: if s.isSubagent { return false }
            case .subagent: if !s.isSubagent { return false }
            }
            if !f.size.matches(messages: s.messages) { return false }
            if s.cost < f.minCost { return false }
            if !needle.isEmpty && !s.searchText.contains(needle) { return false }
            return true
        }
    }

    func passes(_ frag: Fragment, _ f: AnalyticsFilters, mask: [Bool]) -> Bool {
        guard mask[frag.session] else { return false }
        if !f.models.isEmpty && !f.models.contains(frag.model) { return false }
        if f.hoursActive && !f.containsHour(frag.hour) { return false }
        switch f.weekday {
        case .all: break
        case .weekdays: if frag.weekday >= 5 { return false }
        case .weekend: if frag.weekday < 5 { return false }
        }
        return true
    }

    // MARK: Grouping

    private func forEachGroup(_ frag: Fragment, by dim: GroupBy, _ body: (String, Double) -> Void) {
        switch dim {
        case .model: body(frag.model, 1)
        case .project: body(dataset.sessions[frag.session].project, 1)
        case .profile: body(dataset.sessions[frag.session].profile.rawValue, 1)
        case .tool:
            let total = frag.toolCounts.values.reduce(0, +)
            if total == 0 { body(Self.noToolKey, 1) }
            else { for (k, c) in frag.toolCounts { body(k, Double(c) / Double(total)) } }
        }
    }

    // MARK: Run

    func run(_ q: AnalyticsQuery) -> AnalyticsResult {
        let (g, starts) = plan(window: q.window, granularity: q.granularity)
        // Rolling windows start mid-bucket; include the whole first bucket.
        let window = DateInterval(start: min(q.window.start, starts.first ?? q.window.start), end: q.window.end)
        var result = AnalyticsResult(query: q, granularity: g)
        result.starts = starts
        let mask = sessionMask(q.filters)
        let n = starts.count

        // Current period: per-group, per-bucket accumulators + totals + heatmap + session rows.
        var groups: [String: [MetricAccumulator]] = [:]
        var totals = Array(repeating: MetricAccumulator(), count: n)
        var heat = Array(repeating: Array(repeating: MetricAccumulator(), count: 24), count: 7)
        var rowAcc: [Int: (acc: MetricAccumulator, tools: Int)] = [:]
        let range = dataset.fragmentRange(in: window)
        for i in range {
            let f = dataset.fragments[i]
            guard passes(f, q.filters, mask: mask), let b = index(of: f.time, in: starts) else { continue }
            totals[b].add(f)
            heat[f.weekday][f.hour].add(f)
            forEachGroup(f, by: q.groupBy) { key, w in
                groups[key, default: Array(repeating: MetricAccumulator(), count: n)][b].add(f, weight: w)
            }
            var row = rowAcc[f.session] ?? (MetricAccumulator(), 0)
            row.acc.add(f)
            row.tools += f.toolCounts.values.reduce(0, +)
            rowAcc[f.session] = row
        }
        result.totals = totals
        result.heat = heat
        result.series = rankedSeries(groups, dim: q.groupBy)

        // Previous period of equal length, aligned bucket-by-bucket.
        let len = window.duration
        let prevWindow = DateInterval(start: window.start.addingTimeInterval(-len), end: window.start)
        let prevStarts = bucketStarts(for: prevWindow, g)
        var prev = Array(repeating: MetricAccumulator(), count: n)
        for i in dataset.fragmentRange(in: prevWindow) {
            let f = dataset.fragments[i]
            guard passes(f, q.filters, mask: mask), let b = index(of: f.time, in: prevStarts), b < n else { continue }
            prev[b].add(f)
        }
        result.previous = prev

        result.sessions = rowAcc.map { idx, v in
            let s = dataset.sessions[idx]
            let denom = v.acc.input + v.acc.cacheWrite + v.acc.cacheRead
            return SessionRow(id: s.id, start: s.start, project: s.project, model: s.primaryModel,
                              profile: s.profile, isSubagent: s.isSubagent, messages: Int(v.acc.messages),
                              toolCalls: v.tools, tokens: Int(v.acc.totalTokens), cost: v.acc.cost,
                              linesAdded: Int(v.acc.linesAdded), linesRemoved: Int(v.acc.linesRemoved),
                              cacheHit: denom > 0 ? v.acc.cacheRead / denom : 0,
                              durationSec: s.end.timeIntervalSince(s.start))
        }
        result.mini = miniSeries(metric: q.metric, filters: q.filters, mask: mask)
        return result
    }

    /// Stable series ordering; long tails (projects, tools) collapse into "Other".
    private func rankedSeries(_ groups: [String: [MetricAccumulator]], dim: GroupBy) -> [SeriesData] {
        var entries = groups.map { (key: $0.key, buckets: $0.value, weight: MetricAccumulator.sum($0.value)) }
        switch dim {
        case .model, .profile:
            entries.sort { (ModelStyle.rank($0.key), $0.key) < (ModelStyle.rank($1.key), $1.key) }
            return entries.map { SeriesData(key: $0.key, buckets: $0.buckets) }
        case .project, .tool:
            entries.sort { rankWeight($0.weight) > rankWeight($1.weight) }
            guard entries.count > Self.maxSeries else { return entries.map { SeriesData(key: $0.key, buckets: $0.buckets) } }
            let head = entries.prefix(Self.maxSeries - 1)
            var other = Array(repeating: MetricAccumulator(), count: entries[0].buckets.count)
            for e in entries.dropFirst(Self.maxSeries - 1) {
                for i in other.indices { other[i] = other[i] + e.buckets[i] }
            }
            return head.map { SeriesData(key: $0.key, buckets: $0.buckets) } + [SeriesData(key: Self.otherKey, buckets: other)]
        }
    }

    private func rankWeight(_ a: MetricAccumulator) -> Double { a.cost * 1_000_000 + a.totalTokens + a.messages }

    /// Daily totals over the dataset's full span (for the brush timeline). Ratio
    /// metrics fall back to session counts, which is what a brush wants to show.
    private func miniSeries(metric: AnalyticsMetric, filters: AnalyticsFilters, mask: [Bool]) -> MiniSeries {
        guard let first = dataset.minDate else { return MiniSeries() }
        let startFloor = now.addingTimeInterval(-365 * 86_400)
        let window = DateInterval(start: max(first, startFloor), end: now.addingTimeInterval(1))
        let starts = bucketStarts(for: window, .day)
        guard !starts.isEmpty else { return MiniSeries() }
        var acc = Array(repeating: MetricAccumulator(), count: starts.count)
        for i in dataset.fragmentRange(in: window) {
            let f = dataset.fragments[i]
            guard passes(f, filters, mask: mask), let b = index(of: f.time, in: starts) else { continue }
            acc[b].add(f)
        }
        let m = metric.isRatio ? AnalyticsMetric.sessions : metric
        return MiniSeries(starts: starts, values: acc.map(m.value))
    }
}
