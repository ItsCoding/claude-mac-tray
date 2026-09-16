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

    /// USD cost for a single message. OpenCode's own precomputed cost wins
    /// whenever it's nonzero — OpenCode covers many providers/models this
    /// catalog has no data for, and it's usually the more accurate source.
    /// But some of OpenCode's own custom/internal providers (e.g. a private
    /// gateway) carry no pricing metadata anywhere, so OpenCode reports a
    /// real, honest `0` despite real token usage. When that happens, fall
    /// back to this catalog — it's sourced from the same public LiteLLM
    /// data OpenCode's own catalog draws from, so it often still has the
    /// real rate for that exact model under a different provider.
    static func cost(for message: ClaudeMessage) -> Double? {
        let tokens = TokenCount(input: message.inputTokens, output: message.outputTokens,
                                cacheRead: message.cacheReadTokens, cacheWrite: message.cacheWriteTokens)
        if message.isOpenCode {
            if let precomputed = message.precomputedCostUSD, precomputed > 0 { return precomputed }
            return cost(for: message.model ?? "", tokens: tokens) ?? 0
        }
        return cost(for: message.model ?? "", tokens: tokens)
    }

    /// USD cost for a whole session — sums per-message cost so mixed
    /// Claude Code + OpenCode sessions total correctly.
    static func cost(for session: Session) -> Double? {
        session.messages.reduce(0.0) { $0 + (cost(for: $1) ?? 0) }
    }
}
