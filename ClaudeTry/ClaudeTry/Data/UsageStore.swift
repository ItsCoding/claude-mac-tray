import Foundation
import Observation

struct DailyBucket: Identifiable {
    let date: Date
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let modelTokens: [String: Int]
    var id: Date { date }
}

@Observable
@MainActor
final class UsageStore {
    var sessions: [Session] = []
    private var timer: Timer?
    private let parser = JSONLParser()

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

    func totalCost(for period: TimePeriod) -> Double? {
        var total = 0.0
        for session in filteredSessions(for: period) {
            guard let cost = ModelPricing.cost(for: session) else { return nil }
            total += cost
        }
        return total
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
