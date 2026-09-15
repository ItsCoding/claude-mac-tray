import Foundation
import SQLite3

/// Reads OpenCode's local SQLite session store and produces the same
/// `[Session]`/`[MemoryEvent]` shapes `JSONLParser` produces for Claude Code,
/// so every existing `UsageStore` query/chart picks up OpenCode usage with no
/// further changes. Re-queries the whole DB on every `scan()` call — no
/// incremental cache like `JSONLParser`'s mtime cache — because the `message`/
/// `part` tables are small (thousands of rows) and indexed by session/message
/// id, so a full read is cheap.
/// ponytail: if this ever measurably slows the 30s poll down (very large
/// OpenCode history), add an mtime/rowid-based incremental cache like
/// JSONLParser's.
actor OpenCodeParser {
    private struct RawMessage {
        let id: String
        let sessionID: String
        let timestamp: Date
        let model: String?
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
        let cost: Double
        let projectPath: String
    }

    func scan(dbPath: URL) async -> (sessions: [Session], memoryEvents: [MemoryEvent]) {
        guard FileManager.default.fileExists(atPath: dbPath.path) else { return ([], []) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return ([], [])
        }
        defer { sqlite3_close(db) }

        let rawMessages = readMessages(db)

        var messagesBySession: [String: [ClaudeMessage]] = [:]
        for raw in rawMessages {
            let message = ClaudeMessage(
                timestamp: raw.timestamp, role: "assistant", model: raw.model,
                inputTokens: raw.inputTokens, outputTokens: raw.outputTokens,
                cacheReadTokens: raw.cacheReadTokens, cacheWriteTokens: raw.cacheWriteTokens,
                toolCalls: [], projectPath: raw.projectPath,
                isBedrock: false, linesAdded: 0, linesRemoved: 0,
                isOpenCode: true, precomputedCostUSD: raw.cost
            )
            messagesBySession[raw.sessionID, default: []].append(message)
        }

        let sessions: [Session] = messagesBySession.values.compactMap { msgs in
            guard let start = msgs.map(\.timestamp).min(), let end = msgs.map(\.timestamp).max() else { return nil }
            return Session(id: UUID(), projectPath: msgs[0].projectPath, startTime: start, endTime: end, messages: msgs)
        }

        return (sessions, [])
    }

    private func readMessages(_ db: OpaquePointer) -> [RawMessage] {
        let sql = "SELECT id, session_id, time_created, data FROM message ORDER BY session_id, time_created"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var result: [RawMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0), let sidC = sqlite3_column_text(stmt, 1),
                  let dataC = sqlite3_column_text(stmt, 3) else { continue }
            let fallbackCreated = sqlite3_column_int64(stmt, 2)
            guard let json = decodeJSON(String(cString: dataC)),
                  json["role"] as? String == "assistant" else { continue }

            let tokens = json["tokens"] as? [String: Any]
            let cache = tokens?["cache"] as? [String: Any]
            let reasoning = tokens?["reasoning"] as? Int ?? 0
            let createdMs = (json["time"] as? [String: Any])?["created"] as? Double ?? Double(fallbackCreated)
            let cwd = (json["path"] as? [String: Any])?["cwd"] as? String

            result.append(RawMessage(
                id: String(cString: idC), sessionID: String(cString: sidC),
                timestamp: Date(timeIntervalSince1970: createdMs / 1000),
                model: json["modelID"] as? String,
                inputTokens: tokens?["input"] as? Int ?? 0,
                outputTokens: (tokens?["output"] as? Int ?? 0) + reasoning,
                cacheReadTokens: cache?["read"] as? Int ?? 0,
                cacheWriteTokens: cache?["write"] as? Int ?? 0,
                cost: json["cost"] as? Double ?? 0,
                projectPath: cwd ?? "unknown"
            ))
        }
        return result
    }

    private func decodeJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
