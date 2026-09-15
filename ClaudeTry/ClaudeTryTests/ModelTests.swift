import XCTest
@testable import ClaudeTry

final class ModelTests: XCTestCase {
    func test_session_totalInputTokens_sumsAllMessages() {
        let messages = [
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                          inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                          toolCalls: [], projectPath: "/test/project", isBedrock: false,
                          linesAdded: 0, linesRemoved: 0, isOpenCode: false, precomputedCostUSD: nil),
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                          inputTokens: 200, outputTokens: 80, cacheReadTokens: 10, cacheWriteTokens: 5,
                          toolCalls: [], projectPath: "/test/project", isBedrock: false,
                          linesAdded: 0, linesRemoved: 0, isOpenCode: false, precomputedCostUSD: nil)
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
                          linesAdded: 0, linesRemoved: 0, isOpenCode: false, precomputedCostUSD: nil),
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-opus-4-8",
                          inputTokens: 200, outputTokens: 80, cacheReadTokens: 0, cacheWriteTokens: 0,
                          toolCalls: [], projectPath: "/test", isBedrock: false,
                          linesAdded: 0, linesRemoved: 0, isOpenCode: false, precomputedCostUSD: nil)
        ]
        let session = Session(id: UUID(), projectPath: "/test",
                              startTime: messages[0].timestamp, endTime: messages[1].timestamp,
                              messages: messages)
        XCTAssertEqual(session.modelBreakdown["claude-sonnet-4-6"]?.input, 100)
        XCTAssertEqual(session.modelBreakdown["claude-opus-4-8"]?.input, 200)
    }

    func test_session_profile_opencodeMessage_returnsOpenCodeProfile() {
        let message = ClaudeMessage(timestamp: Date(), role: "assistant", model: "gpt-5.6-luna",
                                     inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                                     toolCalls: [], projectPath: "/test", isBedrock: false,
                                     linesAdded: 0, linesRemoved: 0,
                                     isOpenCode: true, precomputedCostUSD: 1.23)
        let session = Session(id: UUID(), projectPath: "/test",
                              startTime: message.timestamp, endTime: message.timestamp,
                              messages: [message])
        XCTAssertEqual(session.profile, .opencode)
    }

    func test_session_profile_bedrockMessage_stillReturnsBedrock_whenNotOpenCode() {
        let message = ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                                     inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                                     toolCalls: [], projectPath: "/test", isBedrock: true,
                                     linesAdded: 0, linesRemoved: 0,
                                     isOpenCode: false, precomputedCostUSD: nil)
        let session = Session(id: UUID(), projectPath: "/test",
                              startTime: message.timestamp, endTime: message.timestamp,
                              messages: [message])
        XCTAssertEqual(session.profile, .bedrock)
    }
}
