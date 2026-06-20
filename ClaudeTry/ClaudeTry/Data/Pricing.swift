import Foundation

/// Per-token USD costs for a single model, matching LiteLLM's schema
/// (`*_cost_per_token` fields). All values are dollars per single token.
struct PricingEntry: Codable, Equatable {
    let inputPerToken: Double
    let outputPerToken: Double
    let cacheCreationPerToken: Double
    let cacheReadPerToken: Double
}

/// A catalog of model → pricing, sourced from LiteLLM (fetched at runtime,
/// cached to disk) with a baked-in embedded snapshot as offline fallback.
struct PricingCatalog {
    let entries: [String: PricingEntry]

    /// Cost in USD for a single model + token bundle.
    /// Returns 0 for Claude Code's `<synthetic>` messages (they are free),
    /// and `nil` for genuinely unknown models so callers can show "—".
    func cost(forModel modelID: String, tokens: TokenCount) -> Double? {
        if modelID == "<synthetic>" || modelID.isEmpty { return 0 }
        guard let e = entry(for: modelID) else { return nil }
        return Double(tokens.input)      * e.inputPerToken
             + Double(tokens.output)     * e.outputPerToken
             + Double(tokens.cacheRead)  * e.cacheReadPerToken
             + Double(tokens.cacheWrite) * e.cacheCreationPerToken
    }

    /// Sum cost across a session. Messages with unknown models contribute 0
    /// rather than poisoning the whole total — most ids resolve via the
    /// embedded snapshot, so this stays accurate in practice.
    func cost(forSession session: Session) -> Double {
        session.messages.reduce(0.0) { acc, msg in
            let tokens = TokenCount(input: msg.inputTokens, output: msg.outputTokens,
                                    cacheRead: msg.cacheReadTokens, cacheWrite: msg.cacheWriteTokens)
            return acc + (cost(forModel: msg.model ?? "", tokens: tokens) ?? 0)
        }
    }

    private func entry(for modelID: String) -> PricingEntry? {
        if let exact = entries[modelID] { return exact }
        // LiteLLM sometimes prefixes provider, e.g. "anthropic/claude-...".
        if let slash = modelID.split(separator: "/").last.map(String.init),
           let e = entries[slash] { return e }
        // Fall back to the longest catalog key contained in the model id.
        return entries
            .filter { modelID.contains($0.key) }
            .max(by: { $0.key.count < $1.key.count })?
            .value
    }
}

extension PricingCatalog {
    /// Baked-in snapshot of LiteLLM prices (USD per token) for the Claude
    /// families seen in Claude Code transcripts. Used offline and as the seed
    /// before the remote fetch completes. Update if Anthropic changes pricing.
    static let embedded = PricingCatalog(entries: [
        // Opus 4 (legacy): $15 / $75 in/out
        "claude-opus-4-20250514": PricingEntry(inputPerToken: 15e-6, outputPerToken: 75e-6, cacheCreationPerToken: 18.75e-6, cacheReadPerToken: 1.5e-6),
        "claude-opus-4-1":        PricingEntry(inputPerToken: 15e-6, outputPerToken: 75e-6, cacheCreationPerToken: 18.75e-6, cacheReadPerToken: 1.5e-6),
        // Opus 4.5+: $5 / $25 in/out
        "claude-opus-4-5": PricingEntry(inputPerToken: 5e-6, outputPerToken: 25e-6, cacheCreationPerToken: 6.25e-6, cacheReadPerToken: 0.5e-6),
        "claude-opus-4-6": PricingEntry(inputPerToken: 5e-6, outputPerToken: 25e-6, cacheCreationPerToken: 6.25e-6, cacheReadPerToken: 0.5e-6),
        "claude-opus-4-7": PricingEntry(inputPerToken: 5e-6, outputPerToken: 25e-6, cacheCreationPerToken: 6.25e-6, cacheReadPerToken: 0.5e-6),
        "claude-opus-4-8": PricingEntry(inputPerToken: 5e-6, outputPerToken: 25e-6, cacheCreationPerToken: 6.25e-6, cacheReadPerToken: 0.5e-6),
        // Sonnet 4 family: $3 / $15 in/out
        "claude-sonnet-4-20250514":      PricingEntry(inputPerToken: 3e-6, outputPerToken: 15e-6, cacheCreationPerToken: 3.75e-6, cacheReadPerToken: 0.3e-6),
        "claude-sonnet-4-5":             PricingEntry(inputPerToken: 3e-6, outputPerToken: 15e-6, cacheCreationPerToken: 3.75e-6, cacheReadPerToken: 0.3e-6),
        "claude-sonnet-4-5-20250929":    PricingEntry(inputPerToken: 3e-6, outputPerToken: 15e-6, cacheCreationPerToken: 3.75e-6, cacheReadPerToken: 0.3e-6),
        "claude-sonnet-4-6":             PricingEntry(inputPerToken: 3e-6, outputPerToken: 15e-6, cacheCreationPerToken: 3.75e-6, cacheReadPerToken: 0.3e-6),
        // Haiku 4.5: $1 / $5 in/out
        "claude-haiku-4-5":           PricingEntry(inputPerToken: 1e-6, outputPerToken: 5e-6, cacheCreationPerToken: 1.25e-6, cacheReadPerToken: 0.1e-6),
        "claude-haiku-4-5-20251001":  PricingEntry(inputPerToken: 1e-6, outputPerToken: 5e-6, cacheCreationPerToken: 1.25e-6, cacheReadPerToken: 0.1e-6),
    ])
}

/// Loads LiteLLM pricing: reads a disk cache (or embedded) synchronously for an
/// instant first paint, then refreshes from the network in the background.
enum PricingLoader {
    private static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    private static var cacheFileURL: URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let appDir = dir.appendingPathComponent("ClaudeTry", isDirectory: true)
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("litellm_pricing.json")
    }

    /// Synchronous best-effort: disk cache if present and parseable, else embedded.
    static func loadCachedOrEmbedded() -> PricingCatalog {
        if let url = cacheFileURL, let data = try? Data(contentsOf: url),
           let catalog = decode(data) {
            return catalog
        }
        return .embedded
    }

    /// Fetch the latest LiteLLM table, persist it to the disk cache, and return it.
    /// Returns nil on any failure (network/parse) so the caller keeps its current catalog.
    static func fetchRemote() async -> PricingCatalog? {
        do {
            let (data, response) = try await URLSession.shared.data(from: remoteURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let catalog = decode(data), !catalog.entries.isEmpty else { return nil }
            if let url = cacheFileURL { try? data.write(to: url) }
            return catalog
        } catch {
            return nil
        }
    }

    /// Parse the LiteLLM JSON (a flat map of model → cost fields), keeping only
    /// Anthropic Claude entries that carry input/output per-token costs.
    private static func decode(_ data: Data) -> PricingCatalog? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var entries: [String: PricingEntry] = [:]
        for (key, value) in raw {
            guard key.contains("claude"),
                  let obj = value as? [String: Any],
                  let input = obj["input_cost_per_token"] as? Double,
                  let output = obj["output_cost_per_token"] as? Double
            else { continue }
            entries[key] = PricingEntry(
                inputPerToken: input,
                outputPerToken: output,
                cacheCreationPerToken: (obj["cache_creation_input_token_cost"] as? Double) ?? 0,
                cacheReadPerToken: (obj["cache_read_input_token_cost"] as? Double) ?? 0
            )
        }
        return entries.isEmpty ? nil : PricingCatalog(entries: entries)
    }
}
