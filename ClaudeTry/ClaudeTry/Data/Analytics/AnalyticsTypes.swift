import Foundation

// Pure value types for the analytics window: metrics, filters, query and view state.
// Nothing here touches UI or the main actor, so everything can be unit tested and
// evaluated off the main thread.

enum Granularity: String, Codable, CaseIterable, Hashable, Sendable {
    case hour, day, week

    var title: String {
        switch self {
        case .hour: return "Hour"
        case .day:  return "Day"
        case .week: return "Week"
        }
    }
    var component: Calendar.Component {
        switch self {
        case .hour: return .hour
        case .day:  return .day
        case .week: return .weekOfYear
        }
    }
    var unit: BucketUnit {
        switch self {
        case .hour: return .hour
        case .day:  return .day
        case .week: return .week
        }
    }
    /// Next coarser granularity (used when a window would produce too many buckets).
    var coarser: Granularity? {
        switch self {
        case .hour: return .day
        case .day:  return .week
        case .week: return nil
        }
    }
}

enum GroupBy: String, Codable, CaseIterable, Hashable, Sendable {
    case model, project, tool, profile
    var title: String { rawValue.capitalized }
}

enum AnalyticsMetric: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case cost, tokens, input, output, cacheRead, cacheWrite, cacheHit
    case linesAdded, linesRemoved, costPerLine
    case sessions, messages, tokensPerSession, avgSessionMinutes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cost: return "Cost"
        case .tokens: return "Total tokens"
        case .input: return "Input tokens"
        case .output: return "Output tokens"
        case .cacheRead: return "Cache read tokens"
        case .cacheWrite: return "Cache write tokens"
        case .cacheHit: return "Cache hit rate"
        case .linesAdded: return "Lines added"
        case .linesRemoved: return "Lines removed"
        case .costPerLine: return "Cost per line"
        case .sessions: return "Sessions"
        case .messages: return "Messages"
        case .tokensPerSession: return "Tokens per session"
        case .avgSessionMinutes: return "Avg session length"
        }
    }

    /// Ratios are not additive, so they cannot be stacked or accumulated.
    var isRatio: Bool {
        switch self {
        case .cacheHit, .costPerLine, .tokensPerSession, .avgSessionMinutes: return true
        default: return false
        }
    }

    /// For deltas: true when an increase is bad news (spend metrics).
    var risingIsBad: Bool { self == .cost || self == .costPerLine }

    func value(_ a: MetricAccumulator) -> Double {
        switch self {
        case .cost: return a.cost
        case .tokens: return a.totalTokens
        case .input: return a.input
        case .output: return a.output
        case .cacheRead: return a.cacheRead
        case .cacheWrite: return a.cacheWrite
        case .cacheHit:
            let d = a.input + a.cacheWrite + a.cacheRead
            return d > 0 ? a.cacheRead / d : 0
        case .linesAdded: return a.linesAdded
        case .linesRemoved: return a.linesRemoved
        case .costPerLine: return a.linesAdded > 0 ? a.cost / a.linesAdded : 0
        case .sessions: return a.sessions
        case .messages: return a.messages
        case .tokensPerSession: return a.sessions > 0 ? a.totalTokens / a.sessions : 0
        case .avgSessionMinutes: return a.sessions > 0 ? a.durationSec / a.sessions / 60 : 0
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .cost: return AnalyticsFormat.money(v)
        case .tokens, .input, .output, .cacheRead, .cacheWrite, .tokensPerSession: return AnalyticsFormat.tokens(v)
        case .cacheHit: return AnalyticsFormat.percent(v)
        case .linesAdded, .linesRemoved, .sessions, .messages: return AnalyticsFormat.number(v)
        case .costPerLine: return String(format: "$%.3f", v)
        case .avgSessionMinutes: return String(format: "%.1f min", v)
        }
    }
}

enum AnalyticsFormat {
    static func money(_ v: Double) -> String {
        let a = abs(v)
        if a >= 100 { return "$" + number(v) }
        return String(format: a >= 10 ? "$%.0f" : "$%.2f", v)
    }
    static func tokens(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1e9 { return String(format: "%.2fB", v / 1e9) }
        if a >= 1e6 { return String(format: "%.1fM", v / 1e6) }
        if a >= 1e3 { return String(format: "%.0fK", v / 1e3) }
        return String(format: "%.0f", v)
    }
    static func percent(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
    static func number(_ v: Double) -> String {
        numberFormatter.string(from: NSNumber(value: v.rounded())) ?? String(Int(v.rounded()))
    }
    static func duration(seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return "\(s / 60)m " + String(format: "%02d", s % 60) + "s"
    }
}

/// Additive sums behind every metric. Ratio metrics are derived from these, so
/// splits and totals always agree.
struct MetricAccumulator: Sendable, Equatable {
    var cost = 0.0, input = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite = 0.0
    var linesAdded = 0.0, linesRemoved = 0.0
    var sessions = 0.0, messages = 0.0, durationSec = 0.0

    var totalTokens: Double { input + output + cacheRead + cacheWrite }

    mutating func add(_ f: Fragment, weight w: Double = 1) {
        cost += f.cost * w
        input += Double(f.input) * w
        output += Double(f.output) * w
        cacheRead += Double(f.cacheRead) * w
        cacheWrite += Double(f.cacheWrite) * w
        linesAdded += Double(f.linesAdded) * w
        linesRemoved += Double(f.linesRemoved) * w
        sessions += f.sessionsStarted * w
        messages += Double(f.messages) * w
        durationSec += f.durationSec * w
    }

    static func + (l: MetricAccumulator, r: MetricAccumulator) -> MetricAccumulator {
        var o = l
        o.cost += r.cost; o.input += r.input; o.output += r.output
        o.cacheRead += r.cacheRead; o.cacheWrite += r.cacheWrite
        o.linesAdded += r.linesAdded; o.linesRemoved += r.linesRemoved
        o.sessions += r.sessions; o.messages += r.messages; o.durationSec += r.durationSec
        return o
    }

    static func sum(_ items: [MetricAccumulator]) -> MetricAccumulator {
        items.reduce(MetricAccumulator(), +)
    }
}

// MARK: - Filters

enum ProfileFilter: String, Codable, CaseIterable, Hashable, Sendable {
    case all = "All", anthropic = "Claude.ai", bedrock = "Bedrock"
}
enum AgentFilter: String, Codable, CaseIterable, Hashable, Sendable {
    case all = "All", main = "Main only", subagent = "Subagents only"
}
enum SizeFilter: String, Codable, CaseIterable, Hashable, Sendable {
    case any = "Any", small = "<10", medium = "10-39", large = "40+"
    func matches(messages: Int) -> Bool {
        switch self {
        case .any: return true
        case .small: return messages < 10
        case .medium: return messages >= 10 && messages < 40
        case .large: return messages >= 40
        }
    }
}
enum WeekdayFilter: String, Codable, CaseIterable, Hashable, Sendable {
    case all = "All", weekdays = "Mon-Fri", weekend = "Sat-Sun"
}

struct AnalyticsFilters: Codable, Hashable, Sendable {
    var models: Set<String> = []
    var projects: Set<String> = []
    var tools: Set<String> = []
    var profile: ProfileFilter = .all
    var agent: AgentFilter = .all
    var size: SizeFilter = .any
    var weekday: WeekdayFilter = .all
    var minCost: Double = 0
    var hourFrom: Int = 0
    var hourTo: Int = 23
    var search: String = ""

    var isEmpty: Bool { self == AnalyticsFilters() }
    var hoursActive: Bool { hourFrom != 0 || hourTo != 23 }
    /// Inclusive hour range; from > to wraps past midnight (22 -> 6).
    func containsHour(_ h: Int) -> Bool {
        hourFrom <= hourTo ? (h >= hourFrom && h <= hourTo) : (h >= hourFrom || h <= hourTo)
    }
}

// MARK: - Range / view state

enum RangePreset: String, Codable, CaseIterable, Hashable, Sendable {
    case day = "24h", week = "7d", month = "30d", all = "All", custom = "Custom", zoom = "Zoom"
    /// Presets shown in the segmented control (zoom is set by the brush only).
    static var pickable: [RangePreset] { [.day, .week, .month, .all, .custom] }
}

enum ChartKind: String, Codable, CaseIterable, Hashable, Sendable {
    case stacked = "Stacked", bars = "Bars", share = "100%", lines = "Lines", cumulative = "Cumulative", heatmap = "Day x hour"
}

struct Overlays: Codable, Hashable, Sendable {
    var comparePrevious = false
    var movingAverage = false
    var forecast = false
    var outliers = true
}

/// Everything a saved view captures.
struct AnalyticsViewState: Codable, Hashable, Sendable {
    var range: RangePreset = .week
    var customFrom: Date = Date().addingTimeInterval(-7 * 86_400)
    var customTo: Date = Date()
    var zoomStart: Date? = nil
    var zoomEnd: Date? = nil
    var chart: ChartKind = .stacked
    var granularity: Granularity = .day
    var metric: AnalyticsMetric = .cost
    var groupBy: GroupBy = .model
    var logScale = false
    var overlays = Overlays()
    var filters = AnalyticsFilters()

    /// Resolve the concrete time window. `dataStart` is the earliest data point (for "All").
    func window(now: Date, dataStart: Date?, calendar: Calendar) -> DateInterval {
        let end = now.addingTimeInterval(1)
        switch range {
        case .day:   return DateInterval(start: now.addingTimeInterval(-86_400), end: end)
        case .week:  return DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: end)
        case .month: return DateInterval(start: now.addingTimeInterval(-30 * 86_400), end: end)
        case .all:
            let s = calendar.startOfDay(for: dataStart ?? now.addingTimeInterval(-30 * 86_400))
            return DateInterval(start: s, end: end)
        case .custom:
            let s = calendar.startOfDay(for: min(customFrom, customTo))
            let e = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(customFrom, customTo))) ?? end
            return DateInterval(start: s, end: max(e, s.addingTimeInterval(1)))
        case .zoom:
            let s = zoomStart ?? now.addingTimeInterval(-7 * 86_400)
            let e = zoomEnd ?? end
            return DateInterval(start: s, end: max(e, s.addingTimeInterval(1)))
        }
    }

    /// Reasonable default granularity for a freshly picked range.
    static func defaultGranularity(for range: RangePreset) -> Granularity {
        switch range {
        case .day: return .hour
        case .week, .month, .custom, .zoom: return .day
        case .all: return .week
        }
    }
}

struct AnalyticsQuery: Equatable, Sendable {
    var window: DateInterval
    var granularity: Granularity
    var metric: AnalyticsMetric
    var groupBy: GroupBy
    var filters: AnalyticsFilters
}

// MARK: - Forgiving decoding
// Saved views live in UserDefaults across app versions. Missing or unknown keys
// fall back to defaults instead of failing the whole decode.

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

extension Overlays {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        comparePrevious = c.value(.comparePrevious, false)
        movingAverage = c.value(.movingAverage, false)
        forecast = c.value(.forecast, false)
        outliers = c.value(.outliers, true)
    }
}

extension AnalyticsFilters {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = c.value(.models, [])
        projects = c.value(.projects, [])
        tools = c.value(.tools, [])
        profile = c.value(.profile, .all)
        agent = c.value(.agent, .all)
        size = c.value(.size, .any)
        weekday = c.value(.weekday, .all)
        minCost = c.value(.minCost, 0)
        hourFrom = min(23, max(0, c.value(.hourFrom, 0)))
        hourTo = min(23, max(0, c.value(.hourTo, 23)))
        search = c.value(.search, "")
    }
}

extension AnalyticsViewState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AnalyticsViewState()
        range = c.value(.range, d.range)
        customFrom = c.value(.customFrom, d.customFrom)
        customTo = c.value(.customTo, d.customTo)
        zoomStart = c.value(.zoomStart, d.zoomStart)
        zoomEnd = c.value(.zoomEnd, d.zoomEnd)
        chart = c.value(.chart, d.chart)
        granularity = c.value(.granularity, d.granularity)
        metric = c.value(.metric, d.metric)
        groupBy = c.value(.groupBy, d.groupBy)
        logScale = c.value(.logScale, d.logScale)
        overlays = c.value(.overlays, d.overlays)
        filters = c.value(.filters, d.filters)
    }
}
