import Foundation

struct ParsedFile {
    let messages: [ClaudeMessage]
    let memoryEvents: [MemoryEvent]
}

actor JSONLParser {
    private var mtimeCache: [URL: Date] = [:]

    // Two formatters: Claude Code sometimes writes fractional seconds, sometimes not.
    // Stored as actor properties so they are allocated once, not on every parseFile call.
    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoWhole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func scan(rootURL: URL) async -> (sessions: [Session], memoryEvents: [MemoryEvent]) {
        var allSessions: [Session] = []
        var allMemoryEvents: [MemoryEvent] = []

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], []) }

        // Collect URLs synchronously before entering async iteration to avoid
        // Swift 6 sendability warning on NSEnumerator's makeIterator.
        let fileURLs = enumerator.compactMap { $0 as? URL }

        for fileURL in fileURLs {
            guard fileURL.pathExtension == "jsonl" else { continue }

            let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, mtimeCache[fileURL] == mtime { continue }
            if let mtime { mtimeCache[fileURL] = mtime }  // only cache when stat succeeded

            let projectPath = fileURL.deletingLastPathComponent().path
            let parsed = await parseFile(url: fileURL, projectPath: projectPath)

            guard !parsed.messages.isEmpty,
                  let startTime = parsed.messages.first?.timestamp,
                  let endTime = parsed.messages.last?.timestamp else {
                allMemoryEvents.append(contentsOf: parsed.memoryEvents)
                continue
            }
            let session = Session(
                id: UUID(),
                projectPath: projectPath,
                startTime: startTime,
                endTime: endTime,
                messages: parsed.messages
            )
            allSessions.append(session)
            allMemoryEvents.append(contentsOf: parsed.memoryEvents)
        }

        return (allSessions, allMemoryEvents)
    }

    func parseFile(url: URL, projectPath: String) async -> ParsedFile {
        let content: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: try? String(contentsOf: url, encoding: .utf8))
            }
        }
        guard let content else { return ParsedFile(messages: [], memoryEvents: []) }

        var messages: [ClaudeMessage] = []
        var memoryEvents: [MemoryEvent] = []
        var seenMemoryPaths = Set<String>()
        func parseDate(_ s: String) -> Date? { isoFractional.date(from: s) ?? isoWhole.date(from: s) }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            guard let messageDict = json["message"] as? [String: Any],
                  let role = messageDict["role"] as? String,
                  let timestampStr = json["timestamp"] as? String,
                  let timestamp = parseDate(timestampStr)
            else { continue }

            let model = messageDict["model"] as? String
            let usage = messageDict["usage"] as? [String: Any]
            let inputTokens      = usage?["input_tokens"] as? Int ?? 0
            let outputTokens     = usage?["output_tokens"] as? Int ?? 0
            let cacheReadTokens  = usage?["cache_read_input_tokens"] as? Int ?? 0
            let cacheWriteTokens = usage?["cache_creation_input_tokens"] as? Int ?? 0

            var toolCalls: [ToolCall] = []
            if let content = messageDict["content"] as? [[String: Any]] {
                for block in content {
                    guard let type = block["type"] as? String, type == "tool_use",
                          let name = block["name"] as? String
                    else { continue }

                    var args: [String: String] = [:]
                    if let input = block["input"] as? [String: Any] {
                        for (k, v) in input { args[k] = "\(v)" }
                    }
                    toolCalls.append(ToolCall(name: name, arguments: args))

                    let pathArg = args["file_path"] ?? args["path"] ?? ""
                    if pathArg.contains("/memory/") {
                        let isRead = name == "Read"
                        let isFirstSeen = !seenMemoryPaths.contains(pathArg)
                        if !isRead { seenMemoryPaths.insert(pathArg) }

                        let op: MemoryOperation
                        if isRead { op = .read }
                        else if isFirstSeen { op = .create }
                        else { op = .write }

                        memoryEvents.append(MemoryEvent(
                            id: UUID(),
                            timestamp: timestamp,
                            projectPath: projectPath,
                            memoryFilePath: pathArg,
                            operation: op
                        ))
                    }
                }
            }

            messages.append(ClaudeMessage(
                timestamp: timestamp,
                role: role,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                toolCalls: toolCalls,
                projectPath: projectPath
            ))
        }

        return ParsedFile(messages: messages, memoryEvents: memoryEvents)
    }
}
