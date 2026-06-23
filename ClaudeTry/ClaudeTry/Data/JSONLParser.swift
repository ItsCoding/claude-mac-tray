import Foundation

struct ParsedFile: Codable {
    let messages: [ClaudeMessage]
    let memoryEvents: [MemoryEvent]
    let projectPath: String
}

actor JSONLParser {
    private struct CacheEntry: Codable {
        let mtime: Date?
        let parsed: ParsedFile
    }
    private var cache: [URL: CacheEntry] = [:]
    private var diskCacheLoaded = false

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

    private var diskCacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("ClaudeTry")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions_v2.json")
    }

    private func loadDiskCache() {
        guard let data = try? Data(contentsOf: diskCacheURL),
              let loaded = try? JSONDecoder().decode([String: CacheEntry].self, from: data)
        else { return }
        for (urlStr, entry) in loaded {
            guard let url = URL(string: urlStr) else { continue }
            cache[url] = entry
        }
    }

    private func saveDiskCache() {
        let serializable = Dictionary(uniqueKeysWithValues: cache.map { ($0.key.absoluteString, $0.value) })
        guard let data = try? JSONEncoder().encode(serializable) else { return }
        try? data.write(to: diskCacheURL, options: .atomic)
    }

    func scan(rootURL: URL) async -> (sessions: [Session], memoryEvents: [MemoryEvent]) {
        if !diskCacheLoaded {
            loadDiskCache()
            diskCacheLoaded = true
        }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], []) }

        let fileURLs = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        let presentURLs = Set(fileURLs)
        cache = cache.filter { presentURLs.contains($0.key) }

        var cacheChanged = false
        for fileURL in fileURLs {
            let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let cached = cache[fileURL], let mtime, cached.mtime == mtime { continue }

            let fallbackPath = fileURL.deletingLastPathComponent().path
            let parsed = await parseFile(url: fileURL, projectPath: fallbackPath)
            cache[fileURL] = CacheEntry(mtime: mtime, parsed: parsed)
            cacheChanged = true
        }

        if cacheChanged { saveDiskCache() }

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
        var resolvedCwd: String?
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
            var msgLinesAdded = 0
            var msgLinesRemoved = 0

            if let contentBlocks = messageDict["content"] as? [[String: Any]] {
                for block in contentBlocks {
                    guard let type = block["type"] as? String, type == "tool_use",
                          let name = block["name"] as? String
                    else { continue }

                    // Strip large content args; count lines instead
                    var args: [String: String] = [:]
                    if let input = block["input"] as? [String: Any] {
                        for (k, v) in input {
                            let s = "\(v)"
                            switch (name, k) {
                            case ("Edit", "old_string"):
                                msgLinesRemoved += s.components(separatedBy: "\n").count
                            case ("Edit", "new_string"), ("Write", "content"):
                                msgLinesAdded += s.components(separatedBy: "\n").count
                            default:
                                args[k] = s
                            }
                        }
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
                isBedrock: isBedrock,
                linesAdded: msgLinesAdded,
                linesRemoved: msgLinesRemoved
            ))
        }

        return ParsedFile(messages: messages, memoryEvents: memoryEvents,
                          projectPath: resolvedCwd ?? fallbackPath)
    }
}
