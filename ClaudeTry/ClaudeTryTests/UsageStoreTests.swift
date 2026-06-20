import XCTest
@testable import ClaudeTry

final class UsageStoreTests: XCTestCase {
    func makeSessions() -> [Session] {
        let cal = Calendar.current
        let now = Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let lastWeek = cal.date(byAdding: .day, value: -8, to: now)!

        func msg(_ tokens: Int, _ model: String, _ date: Date, _ toolName: String? = nil) -> ClaudeMessage {
            let tc = toolName.map { [ToolCall(name: $0, arguments: [:])] } ?? []
            return ClaudeMessage(timestamp: date, role: "assistant", model: model,
                                  inputTokens: tokens, outputTokens: 0,
                                  cacheReadTokens: 0, cacheWriteTokens: 0,
                                  toolCalls: tc, projectPath: "/p")
        }

        return [
            Session(id: UUID(), projectPath: "/p", startTime: now, endTime: now,
                    messages: [msg(1000, "claude-sonnet-4-6", now, "Bash"), msg(500, "claude-sonnet-4-6", now)]),
            Session(id: UUID(), projectPath: "/p", startTime: yesterday, endTime: yesterday,
                    messages: [msg(2000, "claude-opus-4-8", yesterday)]),
            Session(id: UUID(), projectPath: "/q", startTime: lastWeek, endTime: lastWeek,
                    messages: [msg(3000, "claude-sonnet-4-6", lastWeek)]),
        ]
    }

    @MainActor func test_sessions_today_returnsOnlyTodaysSessions() {
        let store = UsageStore()
        store.sessions = makeSessions()
        let todaySessions = store.filteredSessions(for: .today)
        XCTAssertEqual(todaySessions.count, 1)
        XCTAssertEqual(todaySessions[0].totalInputTokens, 1500)
    }

    @MainActor func test_sessions_thisWeek_excludesLastWeek() {
        let store = UsageStore()
        store.sessions = makeSessions()
        let weekSessions = store.filteredSessions(for: .thisWeek)
        XCTAssertEqual(weekSessions.count, 2)
    }

    @MainActor func test_dailyTokenBuckets_allTime_hasEntryPerDay() {
        let store = UsageStore()
        store.sessions = makeSessions()
        let buckets = store.dailyTokenBuckets(for: .allTime)
        XCTAssertGreaterThanOrEqual(buckets.count, 2)
        let totalTokens = buckets.reduce(0) { $0 + $1.totalInputTokens }
        XCTAssertEqual(totalTokens, 6500)
    }

    @MainActor func test_topToolCalls_countsAcrossSessions() {
        let store = UsageStore()
        store.sessions = makeSessions()
        let tools = store.topToolCalls(for: .allTime)
        XCTAssertEqual(tools.first?.name, "Bash")
        XCTAssertEqual(tools.first?.count, 1)
    }
}
