import XCTest
@testable import ClaudeTry

final class ModelTests: XCTestCase {
    func test_session_totalInputTokens_sumsAllMessages() {
        let messages = [
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                          inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                          toolCalls: [], projectPath: "/test/project", isBedrock: false,
                          linesAdded: 0, linesRemoved: 0),
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                          inputTokens: 200, outputTokens: 80, cacheReadTokens: 10, cacheWriteTokens: 5,
                          toolCalls: [], projectPath: "/test/project", isBedrock: false,
                          linesAdded: 0, linesRemoved: 0)
        ]
        let session = Session(id: UUID(), projectPath: "/test/project",
                              startTime: messages[0].timestamp, endTime: messages[1].timestamp,
                              messages: messages)
        XCTAssertEqual(session.totalInputTokens, 300)
        XCTAssertEqual(session.totalOutputTokens, 130)
    }

    func test_session_modelBreakdown_groupsByModel() {
        let messages = [
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                          inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                          toolCalls: [], projectPath: "/test", isBedrock: false,
                          linesAdded: 0, linesRemoved: 0),
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-opus-4-8",
                          inputTokens: 200, outputTokens: 80, cacheReadTokens: 0, cacheWriteTokens: 0,
                          toolCalls: [], projectPath: "/test", isBedrock: false,
                          linesAdded: 0, linesRemoved: 0)
        ]
        let session = Session(id: UUID(), projectPath: "/test",
                              startTime: messages[0].timestamp, endTime: messages[1].timestamp,
                              messages: messages)
        XCTAssertEqual(session.modelBreakdown["claude-sonnet-4-6"]?.input, 100)
        XCTAssertEqual(session.modelBreakdown["claude-opus-4-8"]?.input, 200)
    }

    func test_shortModelName_showsFamilyAndVersion() {
        XCTAssertEqual(shortModelName("claude-sonnet-5-5"), "Sonnet 5.5")
        XCTAssertEqual(shortModelName("claude-opus-4-1-20250805"), "Opus 4.1")
        XCTAssertEqual(shortModelName("claude-3-7-sonnet-20250219"), "Sonnet 3.7")
        XCTAssertEqual(shortModelName("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(shortModelName("claude-future-unknown-99"), "claude-future-unknown-99")
    }
}
