import XCTest
import SQLite3
@testable import ClaudeTry

final class OpenCodeParserTests: XCTestCase {
    var parser: OpenCodeParser!
    var dbURL: URL!

    override func setUp() {
        super.setUp()
        parser = OpenCodeParser()
        dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("ocp-\(UUID().uuidString).db")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dbURL)
        super.tearDown()
    }

    /// Creates a throwaway SQLite DB with the same `message`/`part` schema
    /// OpenCodeParser reads, and inserts the given rows. Test data is fully
    /// controlled (no untrusted input), so plain string-interpolated SQL is
    /// fine here — no need for prepared/bound statements in a test fixture.
    private func makeDB(messages: [(id: String, sessionID: String, data: String)],
                         parts: [(messageID: String, data: String)] = []) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, data TEXT);
            """, nil, nil, nil), SQLITE_OK)
        for (i, m) in messages.enumerated() {
            let escaped = m.data.replacingOccurrences(of: "'", with: "''")
            let sql = "INSERT INTO message (id, session_id, time_created, data) VALUES ('\(m.id)', '\(m.sessionID)', \(i), '\(escaped)');"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        for (i, p) in parts.enumerated() {
            let escaped = p.data.replacingOccurrences(of: "'", with: "''")
            let sql = "INSERT INTO part (id, message_id, data) VALUES ('prt_\(i)', '\(p.messageID)', '\(escaped)');"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    func test_scan_assistantMessage_extractsCostTokensModel() async {
        makeDB(messages: [(
            id: "msg_1", sessionID: "ses_1",
            data: #"{"role":"assistant","cost":0.75,"tokens":{"input":100,"output":200,"reasoning":10,"cache":{"read":5,"write":2}},"modelID":"claude-sonnet-5","providerID":"anthropic","path":{"cwd":"/Users/x/proj"},"time":{"created":1700000000000}}"#
        )])
        let result = await parser.scan(dbPath: dbURL)
        XCTAssertEqual(result.sessions.count, 1)
        let session = result.sessions[0]
        XCTAssertEqual(session.messages.count, 1)
        let msg = session.messages[0]
        XCTAssertEqual(msg.inputTokens, 100)
        XCTAssertEqual(msg.outputTokens, 210, "reasoning tokens fold into output")
        XCTAssertEqual(msg.cacheReadTokens, 5)
        XCTAssertEqual(msg.cacheWriteTokens, 2)
        XCTAssertEqual(msg.model, "claude-sonnet-5")
        XCTAssertEqual(msg.projectPath, "/Users/x/proj")
        XCTAssertTrue(msg.isOpenCode)
        XCTAssertEqual(msg.precomputedCostUSD, 0.75)
    }

    func test_scan_userMessage_excluded() async {
        makeDB(messages: [(id: "msg_1", sessionID: "ses_1", data: #"{"role":"user"}"#)])
        let result = await parser.scan(dbPath: dbURL)
        XCTAssertTrue(result.sessions.isEmpty)
    }

    func test_scan_missingDB_returnsEmpty() async {
        // dbURL was never created by makeDB — the file doesn't exist.
        let result = await parser.scan(dbPath: dbURL)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.memoryEvents.isEmpty)
    }

    func test_scan_malformedJSON_skipsRowWithoutCrashing() async {
        makeDB(messages: [(id: "msg_1", sessionID: "ses_1", data: "{not valid json")])
        let result = await parser.scan(dbPath: dbURL)
        XCTAssertTrue(result.sessions.isEmpty)
    }

    private let baseAssistantData = #"{"role":"assistant","cost":0.1,"tokens":{"input":10,"output":10,"reasoning":0,"cache":{"read":0,"write":0}},"modelID":"claude-sonnet-5","path":{"cwd":"/p"},"time":{"created":1700000000000}}"#

    func test_scan_editWithDiffMetadata_usesExactLineCounts() async {
        makeDB(
            messages: [(id: "msg_1", sessionID: "ses_1", data: baseAssistantData)],
            parts: [(messageID: "msg_1", data: #"{"type":"tool","tool":"edit","state":{"input":{"filePath":"/a.txt","oldString":"x","newString":"y"},"metadata":{"diff":{"additions":3,"deletions":1}}}}"#)]
        )
        let result = await parser.scan(dbPath: dbURL)
        let session = result.sessions[0]
        XCTAssertEqual(session.linesAdded, 3, "must use diff metadata, not oldString/newString line counts (1 each)")
        XCTAssertEqual(session.linesRemoved, 1)
    }

    func test_scan_editWithoutDiffMetadata_fallsBackToCountingStrings() async {
        makeDB(
            messages: [(id: "msg_1", sessionID: "ses_1", data: baseAssistantData)],
            parts: [(messageID: "msg_1", data: #"{"type":"tool","tool":"edit","state":{"input":{"filePath":"/a.txt","oldString":"line1\nline2","newString":"line1\nline2\nline3"}}}"#)]
        )
        let result = await parser.scan(dbPath: dbURL)
        let session = result.sessions[0]
        XCTAssertEqual(session.linesRemoved, 2)
        XCTAssertEqual(session.linesAdded, 3)
    }

    func test_scan_writeTool_countsContentLinesAsAdded() async {
        makeDB(
            messages: [(id: "msg_1", sessionID: "ses_1", data: baseAssistantData)],
            parts: [(messageID: "msg_1", data: #"{"type":"tool","tool":"write","state":{"input":{"filePath":"/new.txt","content":"a\nb\nc"}}}"#)]
        )
        let result = await parser.scan(dbPath: dbURL)
        let session = result.sessions[0]
        XCTAssertEqual(session.linesAdded, 3)
        XCTAssertEqual(session.linesRemoved, 0)
    }

    func test_scan_toolCall_isRecordedWithNativeToolName() async {
        makeDB(
            messages: [(id: "msg_1", sessionID: "ses_1", data: baseAssistantData)],
            parts: [(messageID: "msg_1", data: #"{"type":"tool","tool":"bash","state":{"input":{"command":"ls"}}}"#)]
        )
        let result = await parser.scan(dbPath: dbURL)
        XCTAssertEqual(result.sessions[0].toolCallCounts["bash"], 1, "OpenCode's native lowercase tool name, not aliased to Claude Code's casing")
    }

    func test_scan_memoryPathInFilePath_extractsReadEvent() async {
        makeDB(
            messages: [(id: "msg_1", sessionID: "ses_1", data: baseAssistantData)],
            parts: [(messageID: "msg_1", data: #"{"type":"tool","tool":"read","state":{"input":{"filePath":"/p/memory/notes.md"}}}"#)]
        )
        let result = await parser.scan(dbPath: dbURL)
        XCTAssertEqual(result.memoryEvents.count, 1)
        XCTAssertEqual(result.memoryEvents[0].operation, .read)
        XCTAssertTrue(result.memoryEvents[0].memoryFilePath.contains("notes.md"))
    }

    func test_scan_memoryPathFirstWriteThenSecondWrite_createThenWrite() async {
        makeDB(
            messages: [
                (id: "msg_1", sessionID: "ses_1", data: baseAssistantData),
                (id: "msg_2", sessionID: "ses_1", data: baseAssistantData),
            ],
            parts: [
                (messageID: "msg_1", data: #"{"type":"tool","tool":"write","state":{"input":{"filePath":"/p/memory/notes.md","content":"v1"}}}"#),
                (messageID: "msg_2", data: #"{"type":"tool","tool":"write","state":{"input":{"filePath":"/p/memory/notes.md","content":"v2"}}}"#),
            ]
        )
        let result = await parser.scan(dbPath: dbURL)
        XCTAssertEqual(result.memoryEvents.count, 2)
        XCTAssertEqual(result.memoryEvents[0].operation, .create)
        XCTAssertEqual(result.memoryEvents[1].operation, .write)
    }
}
