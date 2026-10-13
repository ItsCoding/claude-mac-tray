import Foundation

/// Session-level facts, referenced by index from fragments.
struct SessionInfo: Sendable {
    let id: String
    let start: Date
    let end: Date
    let project: String
    let profile: ClaudeProfile
    let isSubagent: Bool
    let messages: Int
    let cost: Double
    let tools: Set<String>
    let primaryModel: String
    /// Lowercased haystack for free-text search (project, id, models, tools, profile, type).
    let searchText: String
}

/// All assistant messages of one session, one model, one local hour. Every
/// metric is a plain sum over fragments, so filtering and bucketing stay cheap
/// and exact (cost is attributed to the hour it was actually spent).
struct Fragment: Sendable {
    let session: Int
    let time: Date            // start of the local hour
    let hour: Int             // 0...23, local
    let weekday: Int          // 0 = Monday ... 6 = Sunday
    let model: String         // display name, e.g. "Sonnet 5.5"
    let cost: Double
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let linesAdded: Int
    let linesRemoved: Int
    let messages: Int
    let toolCounts: [String: Int]
    /// 1 on the fragment holding the session's first message, else 0.
    let sessionsStarted: Double
    /// Session wall time in seconds, carried by the same first fragment.
    let durationSec: Double

    var totalTokens: Int { input + output + cacheRead + cacheWrite }
}

/// One priced message, kept for the last few days so the runway predictor can
/// calibrate "% of limit per dollar" and measure the recent burn.
struct CostPoint: Sendable, Equatable {
    let time: Date
    let cost: Double
    let isOpus: Bool
    /// What the same tokens would cost on Sonnet (from the pricing catalog); only set for Opus.
    var sonnetCost: Double? = nil
}

struct AnalyticsDataset: Sendable {
    var sessions: [SessionInfo] = []
    var fragments: [Fragment] = []       // sorted by time
    var costPoints: [CostPoint] = []     // sorted by time, last ~8 days, non-Bedrock
    var costIndex = CostIndex()
    var minDate: Date? { fragments.first?.time }
    var isEmpty: Bool { fragments.isEmpty }

    static let costPointHistory: TimeInterval = 8 * 86_400

    /// Index range of fragments whose hour falls in `window`.
    func fragmentRange(in window: DateInterval) -> Range<Int> {
        let lo = lowerBound(window.start)
        let hi = lowerBound(window.end)
        return lo..<max(lo, hi)
    }

    private func lowerBound(_ date: Date) -> Int {
        var lo = 0, hi = fragments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if fragments[mid].time < date { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static let sonnetReferenceModel = "claude-sonnet-4-5"

    /// FNV-1a hash of project path + first message time: stable across rescans.
    static func stableID(project: String, first: Date) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in (project + "|" + String(Int(first.timeIntervalSince1970 * 1000))).utf8 {
            h = (h ^ UInt64(b)) &* 0x100000001b3
        }
        return String(h, radix: 16, uppercase: false).padding(toLength: 16, withPad: "0", startingAt: 0)
    }

    static func isSubagentPath(_ path: String) -> Bool {
        path.contains("/.claude/worktrees/") || path.contains("/.worktrees/")
    }

    static func build(from sessions: [Session], pricing: PricingCatalog,
                      calendar: Calendar = .current, now: Date = Date()) -> AnalyticsDataset {
        var infos: [SessionInfo] = []
        var fragments: [Fragment] = []
        var points: [CostPoint] = []
        var usedIDs = Set<String>()
        let pointCutoff = now.addingTimeInterval(-costPointHistory)

        // Hour-start cache: consecutive messages almost always share an hour.
        var cachedHour: DateInterval?
        var cachedParts = (hour: 0, weekday: 0)
        func hourStart(_ t: Date) -> (Date, Int, Int) {
            if let c = cachedHour, c.contains(t) { return (c.start, cachedParts.hour, cachedParts.weekday) }
            let iv = calendar.dateInterval(of: .hour, for: t) ?? DateInterval(start: t, duration: 3600)
            cachedHour = iv
            cachedParts = (calendar.component(.hour, from: iv.start),
                           (calendar.component(.weekday, from: iv.start) + 5) % 7)
            return (iv.start, cachedParts.hour, cachedParts.weekday)
        }

        struct Key: Hashable { let model: String; let hour: Date }
        struct Part {
            var cost = 0.0
            var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
            var added = 0, removed = 0, messages = 0
            var tools: [String: Int] = [:]
            var hourParts = (hour: 0, weekday: 0)
        }

        for session in sessions {
            let msgs = session.messages.filter { $0.model != nil }
            guard let first = msgs.min(by: { $0.timestamp < $1.timestamp }),
                  let last = msgs.max(by: { $0.timestamp < $1.timestamp }) else { continue }

            var parts: [Key: Part] = [:]
            var modelWeight: [String: Int] = [:]
            var tools = Set<String>()
            var total = 0.0
            for m in msgs {
                let raw = m.model ?? ""
                let name = shortModelName(raw)
                let tc = TokenCount(input: m.inputTokens, output: m.outputTokens,
                                    cacheRead: m.cacheReadTokens, cacheWrite: m.cacheWriteTokens)
                let cost = pricing.cost(forModel: raw, tokens: tc) ?? 0
                total += cost
                let (hs, h, wd) = hourStart(m.timestamp)
                var p = parts[Key(model: name, hour: hs)] ?? Part()
                p.hourParts = (h, wd)
                p.cost += cost
                p.input += m.inputTokens; p.output += m.outputTokens
                p.cacheRead += m.cacheReadTokens; p.cacheWrite += m.cacheWriteTokens
                p.added += m.linesAdded; p.removed += m.linesRemoved
                p.messages += 1
                for call in m.toolCalls { p.tools[call.name, default: 0] += 1; tools.insert(call.name) }
                parts[Key(model: name, hour: hs)] = p
                modelWeight[name, default: 0] += m.inputTokens + m.outputTokens + m.cacheReadTokens + m.cacheWriteTokens
                // Bedrock spend does not count against Claude.ai rate limits.
                if m.timestamp >= pointCutoff && !m.isBedrock {
                    let isOpus = ModelStyle.family(name) == "Opus"
                    let sonnet = isOpus ? pricing.cost(forModel: Self.sonnetReferenceModel, tokens: tc) : nil
                    points.append(CostPoint(time: m.timestamp, cost: cost, isOpus: isOpus, sonnetCost: sonnet))
                }
            }

            let idx = infos.count
            let primary = modelWeight.max { $0.value < $1.value }?.key ?? shortModelName(first.model ?? "")
            let profile: ClaudeProfile = session.messages.contains { $0.isBedrock } ? .bedrock : .anthropic
            let isSub = isSubagentPath(session.projectPath)
            let project = session.projectName
            // session.id is a fresh UUID on every scan; derive a stable id instead.
            var id = Self.stableID(project: session.projectPath, first: first.timestamp)
            if usedIDs.contains(id) { id += "-\(idx)" }
            usedIDs.insert(id)
            infos.append(SessionInfo(
                id: id, start: first.timestamp, end: last.timestamp, project: project,
                profile: profile, isSubagent: isSub, messages: msgs.count, cost: total, tools: tools,
                primaryModel: primary,
                searchText: ([project, id, profile.rawValue, isSub ? "subagent" : "main"]
                             + Array(modelWeight.keys) + Array(tools)).joined(separator: " ").lowercased()))

            // The fragment holding the first message carries the session count + duration.
            let (firstHour, _, _) = hourStart(first.timestamp)
            let firstModel = shortModelName(first.model ?? "")
            let duration = last.timestamp.timeIntervalSince(first.timestamp)
            for (key, p) in parts {
                let starts = key.hour == firstHour && key.model == firstModel
                fragments.append(Fragment(
                    session: idx, time: key.hour, hour: p.hourParts.hour, weekday: p.hourParts.weekday,
                    model: key.model, cost: p.cost, input: p.input, output: p.output,
                    cacheRead: p.cacheRead, cacheWrite: p.cacheWrite,
                    linesAdded: p.added, linesRemoved: p.removed, messages: p.messages,
                    toolCounts: p.tools, sessionsStarted: starts ? 1 : 0,
                    durationSec: starts ? duration : 0))
            }
        }
        fragments.sort { $0.time < $1.time }
        points.sort { $0.time < $1.time }
        return AnalyticsDataset(sessions: infos, fragments: fragments, costPoints: points,
                                costIndex: CostIndex(points: points))
    }
}
