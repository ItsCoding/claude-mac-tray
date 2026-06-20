import XCTest
@testable import ClaudeTry

final class JSONLParserTests: XCTestCase {
    var parser: JSONLParser!
    var fixturesURL: URL!

    override func setUp() {
        super.setUp()
        parser = JSONLParser()
        fixturesURL = Bundle(for: type(of: self)).resourceURL!
            .appendingPathComponent("Fixtures")
    }

    func test_parse_simpleSession_extractsMessages() async throws {
        let url = fixturesURL.appendingPathComponent("simple_session.jsonl")
        let result = await parser.parseFile(url: url, projectPath: "/test/project")
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertEqual(result.messages[0].inputTokens, 150)
        XCTAssertEqual(result.messages[1].toolCalls.first?.name, "Bash")
        XCTAssertEqual(result.messages[1].cacheReadTokens, 50)
        XCTAssertEqual(result.messages[1].cacheWriteTokens, 20)
    }

    func test_parse_malformedLines_skipsAndContinues() async throws {
        let url = fixturesURL.appendingPathComponent("malformed_lines.jsonl")
        let result = await parser.parseFile(url: url, projectPath: "/test")
        XCTAssertEqual(result.messages.count, 2)
    }

    func test_parse_memoryOps_extractsMemoryEvents() async throws {
        let url = fixturesURL.appendingPathComponent("memory_ops.jsonl")
        let result = await parser.parseFile(url: url, projectPath: "/Users/alex/.claude/projects/myproject")
        XCTAssertEqual(result.memoryEvents.count, 2)
        let readEvent = result.memoryEvents.first { $0.operation == .read }
        let writeEvent = result.memoryEvents.first { $0.operation == .write || $0.operation == .create }
        XCTAssertNotNil(readEvent)
        XCTAssertNotNil(writeEvent)
        XCTAssertTrue(readEvent!.memoryFilePath.contains("user_prefs.md"))
    }

    func test_parse_unknownModel_stillParsesTokens() async throws {
        let url = fixturesURL.appendingPathComponent("unknown_model.jsonl")
        let result = await parser.parseFile(url: url, projectPath: "/test")
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].inputTokens, 300)
        XCTAssertEqual(result.messages[0].model, "claude-future-unknown-99")
    }

    func test_parse_emptyFile_returnsEmptyResult() async throws {
        let url = fixturesURL.appendingPathComponent("empty_file.jsonl")
        let result = await parser.parseFile(url: url, projectPath: "/test")
        XCTAssertEqual(result.messages.count, 0)
        XCTAssertEqual(result.memoryEvents.count, 0)
    }

    func test_parse_fractionalSecondTimestamp_parsesCorrectly() async throws {
        let url = fixturesURL.appendingPathComponent("unknown_model.jsonl")
        let result = await parser.parseFile(url: url, projectPath: "/test")
        XCTAssertEqual(result.messages.count, 1, "Fractional-second timestamp must parse successfully")
    }
}
