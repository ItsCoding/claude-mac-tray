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
                                  toolCalls: tc, projectPath: "/p", isBedrock: false)
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

    @MainActor func test_limits_bedrockMode_whenNoSnapshots() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("us-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = UsageStore(snapshots: SnapshotStore(directory: dir),
                               config: AppConfig(defaults: UserDefaults(suiteName: "us-\(UUID().uuidString)")!))
        store.sessions = makeSessions()
        XCTAssertEqual(store.limits.mode, .bedrock)
        // Session bar reflects the last-5h cost vs the $10 session budget; today's
        // sessions exist, so cost is >= 0 and the label is dollar-formatted.
        XCTAssertTrue(store.limits.session.primaryLabel.hasPrefix("$"))
    }

    @MainActor func test_limits_anthropicMode_whenSnapshotHasRateLimits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("us-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"session_id":"s","rate_limits":{"five_hour":{"used_percentage":50,"resets_at":4000000000},"seven_day":{"used_percentage":20,"resets_at":4000000000}}}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("s.json"))

        let snapshots = SnapshotStore(directory: dir)
        snapshots.reload()
        let store = UsageStore(snapshots: snapshots,
                               config: AppConfig(defaults: UserDefaults(suiteName: "us-\(UUID().uuidString)")!))
        store.sessions = makeSessions()
        XCTAssertEqual(store.limits.mode, .anthropic)
        XCTAssertEqual(store.limits.session.fraction, 0.5, accuracy: 0.0001)
        XCTAssertTrue(store.limits.session.isReal)
    }
}
