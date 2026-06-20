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

    /// USD cost for a whole session. Unknown-model messages contribute 0.
    static func cost(for session: Session) -> Double? {
        catalog.cost(forSession: session)
    }
}
