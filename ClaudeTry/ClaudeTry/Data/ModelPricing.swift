import Foundation

/// Thin facade over the live `PricingCatalog`. Seeded synchronously from the
/// disk cache / embedded snapshot, then upgraded once the remote LiteLLM table
/// is fetched. All access happens on the main actor (views + UsageStore).
@MainActor
enum ModelPricing {
    /// Current pricing data. Replaced wholesale when the remote fetch succeeds.
    static var catalog: PricingCatalog = PricingLoader.loadCachedOrEmbedded()

    /// Pull the latest LiteLLM table and swap it in. No-op on network failure.
    static func refreshFromRemote() async {
        if let remote = await PricingLoader.fetchRemote() {
            catalog = remote
        }
    }

    /// USD cost for a model + token bundle. `nil` only for genuinely unknown models.
    static func cost(for modelID: String, tokens: TokenCount) -> Double? {
        catalog.cost(forModel: modelID, tokens: tokens)
    }

    /// USD cost for a single message. OpenCode messages carry their own
    /// precomputed cost (OpenCode covers providers/models this Claude-only
    /// catalog has no pricing data for) and always win over a catalog lookup.
    static func cost(for message: ClaudeMessage) -> Double? {
        if message.isOpenCode { return message.precomputedCostUSD ?? 0 }
        let tokens = TokenCount(input: message.inputTokens, output: message.outputTokens,
                                cacheRead: message.cacheReadTokens, cacheWrite: message.cacheWriteTokens)
        return cost(for: message.model ?? "", tokens: tokens)
    }

    /// USD cost for a whole session — sums per-message cost so mixed
    /// Claude Code + OpenCode sessions total correctly.
    static func cost(for session: Session) -> Double? {
        session.messages.reduce(0.0) { $0 + (cost(for: $1) ?? 0) }
    }
}
