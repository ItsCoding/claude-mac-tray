import Foundation

enum MemoryOperation { case read, write, create }

enum TimePeriod: String, CaseIterable {
    case today = "Today"
    case thisWeek = "This Week"
    case thisMonth = "This Month"
    case allTime = "All Time"
}

/// Segmented options for the range picker. The first four are presets; `.custom`
/// reveals two date pickers that drive `RangeState.customStart`/`customEnd`.
enum RangeMode: String, CaseIterable, Hashable {
    case today = "Today"
    case week = "Week"
    case month = "Month"
    case all = "All"
    case custom = "Custom"
}

/// The selected reporting window. Held as one `@State` per tab; resolves to a
/// `DateInterval` that every store query keys off of, so presets and arbitrary
/// custom ranges share a single code path.
struct RangeState: Equatable {
    var mode: RangeMode
    var customStart: Date
    var customEnd: Date

    init(mode: RangeMode = .today) {
        let cal = Calendar.current
        self.mode = mode
        self.customEnd = Date()
        self.customStart = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date())) ?? Date()
    }

    var interval: DateInterval {
        let cal = Calendar.current
        let now = Date()
        let end = now.addingTimeInterval(60) // include the just-now edge
        switch mode {
        case .today:  return DateInterval(start: cal.startOfDay(for: now), end: end)
        case .week:   return DateInterval(start: cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))!, end: end)
        case .month:  return DateInterval(start: cal.date(byAdding: .month, value: -1, to: cal.startOfDay(for: now))!, end: end)
        case .all:    return DateInterval(start: .distantPast, end: end)
        case .custom:
            let s = cal.startOfDay(for: customStart)
            let e = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: customEnd)) ?? customEnd // inclusive end day
            return DateInterval(start: s, end: max(e, s.addingTimeInterval(1)))
        }
    }
}

/// Chart bucket granularity, chosen from how wide the data actually spans (not
/// the nominal range) so "Today" buckets hourly and "All Time" buckets weekly.
enum BucketUnit {
    case hour, day, week

    var calendarComponent: Calendar.Component {
        switch self {
        case .hour: return .hour
        case .day:  return .day
        case .week: return .weekOfYear
        }
    }

    var label: String {
        switch self {
        case .hour: return "Hour"
        case .day:  return "Day"
        case .week: return "Week"
        }
    }
}

/// Which Claude deployment produced a session — detected from the message `id`
/// field in the JSONL. Bedrock message IDs start with `msg_bdrk_`; everything
/// else is the Claude.ai / direct-API path.
enum ClaudeProfile: String, CaseIterable {
    case anthropic = "Claude.ai"
    case bedrock   = "Bedrock"
}

/// Friendly model name for legends. Collapses dated/undated ids to one family.
func shortModelName(_ model: String) -> String {
    if model == "<synthetic>" || model.isEmpty { return "Synthetic" }
    if model.contains("opus")   { return "Opus" }
    if model.contains("sonnet") { return "Sonnet" }
    if model.contains("haiku")  { return "Haiku" }
    if model.contains("fable")  { return "Fable" }
    return model
}

extension Int {
    /// Compact form for stat cards / axes: 1_500 -> "1.5K", 2_700_000 -> "2.7M".
    var abbrev: String {
        let n = Double(self)
        switch abs(n) {
        case 1_000_000...: return String(format: "%.1fM", n / 1_000_000)
        case 1_000...:     return String(format: "%.1fK", n / 1_000)
        default:           return "\(self)"
        }
    }
}

struct ToolCall: Hashable {
    let name: String
    let arguments: [String: String]
}

struct TokenCount {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int

    static let zero = TokenCount(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)

    static func + (lhs: TokenCount, rhs: TokenCount) -> TokenCount {
        TokenCount(input: lhs.input + rhs.input,
                   output: lhs.output + rhs.output,
                   cacheRead: lhs.cacheRead + rhs.cacheRead,
                   cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }
}

struct ClaudeMessage {
    let timestamp: Date
    let role: String
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let toolCalls: [ToolCall]
    let projectPath: String
    /// Bedrock message IDs start with "msg_bdrk_"; nil means unknown (treated as Claude.ai).
    let isBedrock: Bool
}

struct Session: Identifiable {
    let id: UUID
    let projectPath: String
    let startTime: Date
    let endTime: Date
    let messages: [ClaudeMessage]

    var totalInputTokens: Int { messages.reduce(0) { $0 + $1.inputTokens } }
    var totalOutputTokens: Int { messages.reduce(0) { $0 + $1.outputTokens } }
    var totalCacheReadTokens: Int { messages.reduce(0) { $0 + $1.cacheReadTokens } }
    var totalCacheWriteTokens: Int { messages.reduce(0) { $0 + $1.cacheWriteTokens } }

    var projectName: String { (projectPath as NSString).lastPathComponent }

    var modelBreakdown: [String: TokenCount] {
        var result: [String: TokenCount] = [:]
        for msg in messages {
            guard let model = msg.model else { continue }
            let existing = result[model] ?? .zero
            result[model] = existing + TokenCount(input: msg.inputTokens, output: msg.outputTokens,
                                                   cacheRead: msg.cacheReadTokens, cacheWrite: msg.cacheWriteTokens)
        }
        return result
    }

    var toolCallCounts: [String: Int] {
        var result: [String: Int] = [:]
        for msg in messages {
            for call in msg.toolCalls {
                result[call.name, default: 0] += 1
            }
        }
        return result
    }

    var primaryModel: String? {
        modelBreakdown.max(by: { ($0.value.input + $0.value.output) < ($1.value.input + $1.value.output) })?.key
    }

    var profile: ClaudeProfile {
        messages.contains { $0.isBedrock } ? .bedrock : .anthropic
    }
}

struct ProjectSummary: Identifiable {
    let path: String
    let sessions: [Session]

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var lastActive: Date? { sessions.map(\.endTime).max() }
    var totalSessions: Int { sessions.count }

    var totalTokens: TokenCount {
        sessions.reduce(.zero) { acc, s in
            acc + TokenCount(input: s.totalInputTokens, output: s.totalOutputTokens,
                             cacheRead: s.totalCacheReadTokens, cacheWrite: s.totalCacheWriteTokens)
        }
    }
}

struct MemoryEvent: Identifiable {
    let id: UUID
    let timestamp: Date
    let projectPath: String
    let memoryFilePath: String
    let operation: MemoryOperation
}
