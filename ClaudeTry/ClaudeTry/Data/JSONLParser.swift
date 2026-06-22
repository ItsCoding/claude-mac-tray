import Foundation

struct ParsedFile {
    let messages: [ClaudeMessage]
    let memoryEvents: [MemoryEvent]
    /// Working directory reported by Claude Code (`cwd`), used as the project
    /// identity. Falls back to the file's parent directory when absent.
    let projectPath: String
}

actor JSONLParser {
    /// Persistent cache of parsed results keyed by file, with the mtime they
    /// were parsed at. Unchanged files are reused; every scan returns the FULL
    /// set so the store never loses sessions between polls.
    private struct CacheEntry {
        let mtime: Date?
        let parsed: ParsedFile
    }
    private var cache: [URL: CacheEntry] = [:]

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
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], []) }

        // Collect URLs synchronously before entering async iteration to avoid
        // Swift 6 sendability warning on NSEnumerator's makeIterator.
        let fileURLs = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        let presentURLs = Set(fileURLs)

        // Drop cache entries for files that no longer exist.
        cache = cache.filter { presentURLs.contains($0.key) }

        for fileURL in fileURLs {
            let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            // Reuse the cached parse when the file is unchanged.
            if let cached = cache[fileURL], let mtime, cached.mtime == mtime { continue }

            let fallbackPath = fileURL.deletingLastPathComponent().path
            let parsed = await parseFile(url: fileURL, projectPath: fallbackPath)
            cache[fileURL] = CacheEntry(mtime: mtime, parsed: parsed)
        }

        // Aggregate the FULL cache, not just this scan's deltas.
        var allSessions: [Session] = []
        var allMemoryEvents: [MemoryEvent] = []
        for entry in cache.values {
            let parsed = entry.parsed
            allMemoryEvents.append(contentsOf: parsed.memoryEvents)
            guard !parsed.messages.isEmpty,
                  let startTime = parsed.messages.first?.timestamp,
                  let endTime = parsed.messages.last?.timestamp else { continue }
            allSessions.append(Session(
                id: UUID(),
                projectPath: parsed.projectPath,
                startTime: startTime,
                endTime: endTime,
                messages: parsed.messages
            ))
        }

        return (allSessions, allMemoryEvents)
    }

    func parseFile(url: URL, projectPath fallbackPath: String) async -> ParsedFile {
        let content: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: try? String(contentsOf: url, encoding: .utf8))
            }
        }
        guard let content else {
            return ParsedFile(messages: [], memoryEvents: [], projectPath: fallbackPath)
        }

        var messages: [ClaudeMessage] = []
        var memoryEvents: [MemoryEvent] = []
        var seenMemoryPaths = Set<String>()
        var resolvedCwd: String?  // first non-empty cwd becomes the project identity
        func parseDate(_ s: String) -> Date? { isoFractional.date(from: s) ?? isoWhole.date(from: s) }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if resolvedCwd == nil, let cwd = json["cwd"] as? String, !cwd.isEmpty {
                resolvedCwd = cwd
            }

            guard let messageDict = json["message"] as? [String: Any],
                  let role = messageDict["role"] as? String,
                  let timestampStr = json["timestamp"] as? String,
                  let timestamp = parseDate(timestampStr)
            else { continue }

            let model = messageDict["model"] as? String
            let messageID = messageDict["id"] as? String
            let isBedrock = messageID?.hasPrefix("msg_bdrk_") == true
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
                            projectPath: resolvedCwd ?? fallbackPath,
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
                projectPath: resolvedCwd ?? fallbackPath,
                isBedrock: isBedrock
            ))
        }

        return ParsedFile(messages: messages, memoryEvents: memoryEvents,
                          projectPath: resolvedCwd ?? fallbackPath)
    }
}
