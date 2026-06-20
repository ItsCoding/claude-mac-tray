import Foundation

enum MemoryOperation { case read, write, create }

enum TimePeriod: String, CaseIterable {
    case today = "Today"
    case thisWeek = "This Week"
    case thisMonth = "This Month"
    case allTime = "All Time"
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

    var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }

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
        modelBreakdown.max(by: { $0.value.input < $1.value.input })?.key
    }
}

struct ProjectSummary: Identifiable {
    let path: String
    let sessions: [Session]

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
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
