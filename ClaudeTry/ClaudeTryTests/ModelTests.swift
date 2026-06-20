import XCTest
@testable import ClaudeTry

final class ModelTests: XCTestCase {
    func test_session_totalInputTokens_sumsAllMessages() {
        let messages = [
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                          inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                          toolCalls: [], projectPath: "/test/project"),
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                          inputTokens: 200, outputTokens: 80, cacheReadTokens: 10, cacheWriteTokens: 5,
                          toolCalls: [], projectPath: "/test/project")
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
                          toolCalls: [], projectPath: "/test"),
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-opus-4-8",
                          inputTokens: 200, outputTokens: 80, cacheReadTokens: 0, cacheWriteTokens: 0,
                          toolCalls: [], projectPath: "/test")
        ]
        let session = Session(id: UUID(), projectPath: "/test",
                              startTime: messages[0].timestamp, endTime: messages[1].timestamp,
                              messages: messages)
        XCTAssertEqual(session.modelBreakdown["claude-sonnet-4-6"]?.input, 100)
        XCTAssertEqual(session.modelBreakdown["claude-opus-4-8"]?.input, 200)
    }
}
