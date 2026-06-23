import Foundation
import Observation

struct DailyBucket: Identifiable {
    let date: Date
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let modelTokens: [String: Int]
    var id: Date { date }
}

/// One (time bucket × model) cell: tokens and USD cost for that model in that
/// bucket. Flattened so SwiftUI `Charts` can stack bars/areas by model directly.
struct ModelBucket: Identifiable {
    let date: Date
    let model: String   // short display name (e.g. "Opus")
    let inputTokens: Int
    let outputTokens: Int
    let cost: Double
    var totalTokens: Int { inputTokens + outputTokens }
    var id: String { "\(date.timeIntervalSince1970)-\(model)" }
}

@Observable
@MainActor
final class UsageStore {
    var sessions: [Session] = []
    private(set) var isLoaded = false
    private var timer: Timer?
    private let parser = JSONLParser()
    private let snapshots: SnapshotStore
    private let config: AppConfig

    init(snapshots: SnapshotStore = .standard(), config: AppConfig = AppConfig()) {
        self.snapshots = snapshots
        self.config = config
    }

    /// Session (5h) + weekly (7d) limit bars and the API/wall-time readout.
    /// Anthropic mode when snapshots carry real `rate_limits`, else Bedrock budgets.
    var limits: LimitsModel {
        let now = Date()
        let cal = Calendar.current
        let fiveHourAgo = now.addingTimeInterval(-5 * 3600)
        let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: now) ?? now.addingTimeInterval(-7 * 86_400)
        let sessionCost = totalCost(in: DateInterval(start: fiveHourAgo, end: now.addingTimeInterval(60))) ?? 0
        let weeklyCost = totalCost(in: DateInterval(start: sevenDaysAgo, end: now.addingTimeInterval(60))) ?? 0
        return LimitsModel.make(
            freshest: snapshots.freshest, active: snapshots.active,
            sessionCostUSD: sessionCost, weeklyCostUSD: weeklyCost,
            budgets: config.budgets, now: now
        )
    }

    var projects: [ProjectSummary] {
        Dictionary(grouping: sessions, by: \.projectPath)
            .map { ProjectSummary(path: $0.key, sessions: $0.value) }
            .sorted { ($0.totalTokens.input + $0.totalTokens.output) > ($1.totalTokens.input + $1.totalTokens.output) }
    }

    func startPolling() {
        // Upgrade pricing from the live LiteLLM table, then (re)scan so any
        // price changes are reflected immediately.
        Task { @MainActor in
            await ModelPricing.refreshFromRemote()
            await refreshAsync()
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAsync() }
        }
    }

    func refresh() {
        Task { await refreshAsync() }
    }

    private func refreshAsync() async {
        let rootURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let result = await parser.scan(rootURL: rootURL)
        sessions = result.sessions.sorted { $0.startTime > $1.startTime }
        snapshots.reload()
        isLoaded = true
    }

    /// Cumulative cost over time for a single project — points are per-session
    /// running totals, sorted chronologically, for a cost-growth line chart.
    func cumulativeCost(for project: ProjectSummary) -> [(date: Date, cumulative: Double)] {
        let ordered = project.sessions.sorted { $0.startTime < $1.startTime }
        var running = 0.0
        return ordered.map { session in
            running += ModelPricing.cost(for: session) ?? 0
            return (date: session.startTime, cumulative: running)
        }
    }

    func filteredSessions(for period: TimePeriod) -> [Session] {
        sessions.filter { $0.startTime >= startDate(for: period) }
    }

    // MARK: - Interval-based queries (presets + custom ranges share these)

    func filteredSessions(in interval: DateInterval) -> [Session] {
        sessions.filter { interval.contains($0.startTime) }
    }

    /// Every message whose own timestamp falls in `interval`, regardless of when
    /// its session started. Totals key off this (not whole-session filtering by
    /// start time) so a session spanning midnight attributes each message's cost
    /// to the day it was actually spent — matching the per-message charts.
    func messages(in interval: DateInterval) -> [ClaudeMessage] {
        sessions.flatMap(\.messages).filter { interval.contains($0.timestamp) }
    }

    func tokenTotals(in interval: DateInterval) -> TokenCount {
        messages(in: interval).reduce(.zero) { acc, m in
            acc + TokenCount(input: m.inputTokens, output: m.outputTokens,
                             cacheRead: m.cacheReadTokens, cacheWrite: m.cacheWriteTokens)
        }
    }

    func totalCost(in interval: DateInterval) -> Double? {
        messages(in: interval).reduce(0.0) { acc, m in
            let tc = TokenCount(input: m.inputTokens, output: m.outputTokens,
                                cacheRead: m.cacheReadTokens, cacheWrite: m.cacheWriteTokens)
            return acc + (ModelPricing.cost(for: m.model ?? "", tokens: tc) ?? 0)
        }
    }

    /// Per-profile cost and session count for the interval. Returns nil when all
    /// sessions belong to a single profile (no breakdown to show).
    func profileBreakdown(in interval: DateInterval) -> [(profile: ClaudeProfile, cost: Double, sessions: Int)]? {
        var data: [ClaudeProfile: (cost: Double, sessions: Int)] = [:]
        for session in filteredSessions(in: interval) {
            let p = session.profile
            let c = ModelPricing.cost(for: session) ?? 0
            data[p] = (data[p].map { ($0.cost + c, $0.sessions + 1) }) ?? (c, 1)
        }
        guard data.count > 1 else { return nil }
        return data
            .map { (profile: $0.key, cost: $0.value.cost, sessions: $0.value.sessions) }
            .sorted { $0.profile == .anthropic && $1.profile != .anthropic }
    }

    /// Granularity for charts over this range, driven by interval duration so
    /// "Today" always buckets hourly and "Week" always buckets daily.
    func bucketUnit(in interval: DateInterval) -> BucketUnit {
        let days = interval.duration / 86_400
        if days <= 1.5 { return .hour }
        if days <= 92  { return .day }
        return .week
    }

    func bucketUnit(forSessions sessions: [Session]) -> BucketUnit {
        let dates = sessions.map(\.startTime)
        guard let first = dates.min(), let last = dates.max() else { return .day }
        let days = last.timeIntervalSince(first) / 86_400
        if days <= 1.5 { return .hour }
        if days <= 92  { return .day }
        return .week
    }

    /// Per-bucket, per-model tokens and cost over a range.
    func modelBuckets(in interval: DateInterval) -> [ModelBucket] {
        _modelBuckets(sessions: filteredSessions(in: interval), unit: bucketUnit(in: interval))
    }

    func modelBuckets(fromSessions sessions: [Session]) -> [ModelBucket] {
        _modelBuckets(sessions: sessions, unit: bucketUnit(forSessions: sessions))
    }

    private func _modelBuckets(sessions: [Session], unit: BucketUnit) -> [ModelBucket] {
        let cal = Calendar.current
        var tokens: [Date: [String: (Int, Int)]] = [:]
        var cost:   [Date: [String: Double]] = [:]
        for session in sessions {
            for msg in session.messages {
                guard let raw = msg.model else { continue }
                let bucket = truncate(msg.timestamp, to: unit, cal: cal)
                let short = shortModelName(raw)
                let tc = TokenCount(input: msg.inputTokens, output: msg.outputTokens,
                                    cacheRead: msg.cacheReadTokens, cacheWrite: msg.cacheWriteTokens)
                var byModel = tokens[bucket] ?? [:]
                var io = byModel[short] ?? (0, 0)
                io.0 += tc.input; io.1 += tc.output
                byModel[short] = io
                tokens[bucket] = byModel
                var byCost = cost[bucket] ?? [:]
                byCost[short, default: 0] += ModelPricing.cost(for: raw, tokens: tc) ?? 0
                cost[bucket] = byCost
            }
        }
        return tokens.flatMap { date, models in
            models.map { short, io in
                ModelBucket(date: date, model: short, inputTokens: io.0, outputTokens: io.1,
                            cost: cost[date]?[short] ?? 0)
            }
        }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            let order = ModelStyle.order
            let i0 = order.firstIndex(of: $0.model) ?? order.count
            let i1 = order.firstIndex(of: $1.model) ?? order.count
            return i0 < i1
        }
    }

    /// Per-bucket, per-profile cost over a range (uses the same ModelBucket shape
    /// so BucketBarChart can render it unchanged with profile names as "model").
    func profileBuckets(in interval: DateInterval) -> [ModelBucket] {
        let unit = bucketUnit(in: interval)
        let cal = Calendar.current
        var tokens: [Date: [String: (Int, Int)]] = [:]
        var cost:   [Date: [String: Double]] = [:]
        for session in filteredSessions(in: interval) {
            let name = session.profile.rawValue
            for msg in session.messages {
                let bucket = truncate(msg.timestamp, to: unit, cal: cal)
                let tc = TokenCount(input: msg.inputTokens, output: msg.outputTokens,
                                    cacheRead: msg.cacheReadTokens, cacheWrite: msg.cacheWriteTokens)
                var byProfile = tokens[bucket] ?? [:]
                var io = byProfile[name] ?? (0, 0)
                io.0 += tc.input; io.1 += tc.output
                byProfile[name] = io
                tokens[bucket] = byProfile
                var byCost = cost[bucket] ?? [:]
                byCost[name, default: 0] += ModelPricing.cost(for: msg.model ?? "", tokens: tc) ?? 0
                cost[bucket] = byCost
            }
        }
        return tokens.flatMap { date, profiles in
            profiles.map { name, io in
                ModelBucket(date: date, model: name, inputTokens: io.0, outputTokens: io.1,
                            cost: cost[date]?[name] ?? 0)
            }
        }.sorted { $0.date != $1.date ? $0.date < $1.date : $0.model < $1.model }
    }

    /// Per-bucket, per-tool call count. Reuses ModelBucket with count stored in
    /// inputTokens (outputTokens = 0, cost = 0) so BucketBarChart(.count) renders it.
    /// Capped to the top 6 tools by total calls to keep the legend readable.
    func toolBuckets(in interval: DateInterval) -> [ModelBucket] {
        let unit = bucketUnit(in: interval)
        let cal = Calendar.current
        var counts: [Date: [String: Int]] = [:]
        for session in filteredSessions(in: interval) {
            for msg in session.messages {
                let bucket = truncate(msg.timestamp, to: unit, cal: cal)
                for call in msg.toolCalls {
                    counts[bucket, default: [:]][call.name, default: 0] += 1
                }
            }
        }
        let totals = counts.values.reduce(into: [String: Int]()) { acc, d in
            d.forEach { acc[$0.key, default: 0] += $0.value }
        }
        let top = Set(totals.sorted { $0.value > $1.value }.prefix(6).map(\.key))
        return counts.flatMap { date, tools in
            tools.compactMap { name, count -> ModelBucket? in
                guard top.contains(name) else { return nil }
                return ModelBucket(date: date, model: name, inputTokens: count, outputTokens: 0, cost: 0)
            }
        }.sorted { $0.date != $1.date ? $0.date < $1.date : $0.model < $1.model }
    }

    /// Per-bucket lines added ("Added") and removed ("Removed") from Edit/Write calls.
    func lineBuckets(in interval: DateInterval) -> [ModelBucket] {
        let unit = bucketUnit(in: interval)
        let cal = Calendar.current
        var added: [Date: Int] = [:]
        var removed: [Date: Int] = [:]
        for session in filteredSessions(in: interval) {
            let bucket = truncate(session.startTime, to: unit, cal: cal)
            added[bucket, default: 0] += session.linesAdded
            removed[bucket, default: 0] += session.linesRemoved
        }
        var result: [ModelBucket] = []
        for date in Set(added.keys).union(Set(removed.keys)).sorted() {
            if let a = added[date], a > 0 {
                result.append(ModelBucket(date: date, model: "Added", inputTokens: a, outputTokens: 0, cost: 0))
            }
            if let r = removed[date], r > 0 {
                result.append(ModelBucket(date: date, model: "Removed", inputTokens: r, outputTokens: 0, cost: 0))
            }
        }
        return result
    }

    /// Per-bucket, per-project cost. Top 6 projects by total cost in the interval.
    func projectBuckets(in interval: DateInterval) -> [ModelBucket] {
        let unit = bucketUnit(in: interval)
        let cal = Calendar.current
        let sessions = filteredSessions(in: interval)
        var cost: [Date: [String: Double]] = [:]
        for session in sessions {
            let bucket = truncate(session.startTime, to: unit, cal: cal)
            cost[bucket, default: [:]][session.projectName, default: 0] += ModelPricing.cost(for: session) ?? 0
        }
        let totals = Dictionary(grouping: sessions, by: \.projectName)
            .mapValues { $0.reduce(0.0) { $0 + (ModelPricing.cost(for: $1) ?? 0) } }
        let top = Set(totals.sorted { $0.value > $1.value }.prefix(6).map(\.key))
        return cost.flatMap { date, projects in
            projects.compactMap { name, c -> ModelBucket? in
                guard top.contains(name) else { return nil }
                return ModelBucket(date: date, model: name, inputTokens: 0, outputTokens: 0, cost: c)
            }
        }.sorted { $0.date != $1.date ? $0.date < $1.date : $0.model < $1.model }
    }

    /// Running USD total across the range, one point per session, for an
    /// "is my spend accelerating?" cumulative area chart.
    func cumulativeCost(in interval: DateInterval) -> [(date: Date, cumulative: Double)] {
        let ordered = filteredSessions(in: interval).sorted { $0.startTime < $1.startTime }
        var running = 0.0
        return ordered.map { session in
            running += ModelPricing.cost(for: session) ?? 0
            return (date: session.startTime, cumulative: running)
        }
    }

    // MARK: - Extra session insights

    func topToolCalls(in interval: DateInterval) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for session in filteredSessions(in: interval) {
            for (name, count) in session.toolCallCounts { counts[name, default: 0] += count }
        }
        return counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    /// USD saved by prompt caching: what cache-read tokens would have cost at the
    /// full input rate, minus what they actually cost at the cache-read rate.
    func cacheSavings(in interval: DateInterval) -> Double {
        var saved = 0.0
        for session in filteredSessions(in: interval) {
            for msg in session.messages where msg.cacheReadTokens > 0 {
                guard let model = msg.model else { continue }
                let full = ModelPricing.cost(for: model, tokens: TokenCount(input: msg.cacheReadTokens, output: 0, cacheRead: 0, cacheWrite: 0)) ?? 0
                let actual = ModelPricing.cost(for: model, tokens: TokenCount(input: 0, output: 0, cacheRead: msg.cacheReadTokens, cacheWrite: 0)) ?? 0
                saved += full - actual
            }
        }
        return saved
    }

    /// Hour of day (0–23) with the highest spend, for "when do I burn the most?".
    func busiestHour(in interval: DateInterval) -> (hour: Int, cost: Double)? {
        let cal = Calendar.current
        var byHour: [Int: Double] = [:]
        for session in filteredSessions(in: interval) {
            let hour = cal.component(.hour, from: session.startTime)
            byHour[hour, default: 0] += ModelPricing.cost(for: session) ?? 0
        }
        return byHour.max { $0.value < $1.value }.map { (hour: $0.key, cost: $0.value) }
    }

    func avgSessionMinutes(in interval: DateInterval) -> Double? {
        let sessions = filteredSessions(in: interval)
        guard !sessions.isEmpty else { return nil }
        let total = sessions.reduce(0.0) { $0 + $1.endTime.timeIntervalSince($1.startTime) }
        return total / Double(sessions.count) / 60
    }

    private func truncate(_ date: Date, to unit: BucketUnit, cal: Calendar) -> Date {
        switch unit {
        case .hour: return cal.dateInterval(of: .hour, for: date)?.start ?? date
        case .day:  return cal.startOfDay(for: date)
        case .week: return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        }
    }

    func totalCost(for period: TimePeriod) -> Double? {
        // Attribute by message timestamp (same as `totalCost(in:)`) so the
        // menu-bar "today" total matches the Overview card and charts.
        totalCost(in: DateInterval(start: startDate(for: period),
                                   end: Date().addingTimeInterval(60)))
    }

    func dailyTokenBuckets(for period: TimePeriod) -> [DailyBucket] {
        let cal = Calendar.current
        var bucketMap: [Date: (Int, Int, [String: Int])] = [:]
        for session in filteredSessions(for: period) {
            let day = cal.startOfDay(for: session.startTime)
            var (inp, out, models) = bucketMap[day] ?? (0, 0, [:])
            inp += session.totalInputTokens
            out += session.totalOutputTokens
            for (model, tc) in session.modelBreakdown {
                models[model, default: 0] += tc.input
            }
            bucketMap[day] = (inp, out, models)
        }
        return bucketMap.map { day, entry in
            DailyBucket(date: day, totalInputTokens: entry.0,
                        totalOutputTokens: entry.1, modelTokens: entry.2)
        }.sorted { $0.date < $1.date }
    }

    func modelBreakdown(for period: TimePeriod) -> [String: TokenCount] {
        var result: [String: TokenCount] = [:]
        for session in filteredSessions(for: period) {
            for (model, tc) in session.modelBreakdown {
                result[model] = (result[model] ?? .zero) + tc
            }
        }
        return result
    }

    func topToolCalls(for period: TimePeriod) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for session in filteredSessions(for: period) {
            for (name, count) in session.toolCallCounts {
                counts[name, default: 0] += count
            }
        }
        return counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    private func startDate(for period: TimePeriod) -> Date {
        let cal = Calendar.current
        let now = Date()
        switch period {
        case .today:     return cal.startOfDay(for: now)
        case .thisWeek:  return cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))!
        case .thisMonth: return cal.date(byAdding: .month, value: -1, to: cal.startOfDay(for: now))!
        case .allTime:   return Date.distantPast
        }
    }
}
