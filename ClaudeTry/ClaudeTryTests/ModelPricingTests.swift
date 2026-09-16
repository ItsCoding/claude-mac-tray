import XCTest
@testable import ClaudeTry

@MainActor
final class ModelPricingTests: XCTestCase {
    func test_cost_knownModel_returnsCorrectCost() {
        // claude-sonnet-4-6: $3/M input, $15/M output, $0.30/M cache read, $3.75/M cache write
        let tokens = TokenCount(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)
        let cost = ModelPricing.cost(for: "claude-sonnet-4-6", tokens: tokens)
        XCTAssertEqual(cost!, 3.0, accuracy: 0.001)
    }

    func test_cost_unknownModel_returnsNil() {
        let tokens = TokenCount(input: 1000, output: 500, cacheRead: 0, cacheWrite: 0)
        XCTAssertNil(ModelPricing.cost(for: "some-unknown-model-xyz", tokens: tokens))
    }

    func test_cost_sonnet5_isFreeUntilRealPricingLands() {
        let tokens = TokenCount(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)
        XCTAssertEqual(ModelPricing.cost(for: "claude-sonnet-5", tokens: tokens), 0)
        XCTAssertEqual(ModelPricing.cost(for: "claude-sonnet-5-20260115", tokens: tokens), 0)
    }

    func test_cost_includesCacheTokens() {
        // 1M cache read tokens at $0.30/M = $0.30
        let tokens = TokenCount(input: 0, output: 0, cacheRead: 1_000_000, cacheWrite: 0)
        let cost = ModelPricing.cost(for: "claude-sonnet-4-6", tokens: tokens)
        XCTAssertEqual(cost!, 0.30, accuracy: 0.001)
    }

    func test_cost_openCodeMessage_usesPrecomputedCost_ignoresModelCatalog() {
        let msg = ClaudeMessage(timestamp: Date(), role: "assistant", model: "gpt-5.6-luna",
                                 inputTokens: 1_000_000, outputTokens: 1_000_000,
                                 cacheReadTokens: 0, cacheWriteTokens: 0,
                                 toolCalls: [], projectPath: "/p", isBedrock: false,
                                 linesAdded: 0, linesRemoved: 0,
                                 isOpenCode: true, precomputedCostUSD: 4.2)
        // "gpt-5.6-luna" has no entry in the Claude-only pricing catalog, so a
        // catalog-based lookup would return nil/0 — the precomputed value must win.
        XCTAssertEqual(ModelPricing.cost(for: msg), 4.2)
    }

    /// Uses a model name absent from both the embedded catalog and any real
    /// entries, and pins the catalog to the Claude-only embedded snapshot, so
    /// this stays deterministic regardless of what's cached on disk (unlike
    /// "gpt-5.6-luna", which — after the catalog fallback below — legitimately
    /// resolves to a real, nonzero cost once real GPT pricing is cached).
    func test_cost_openCodeMessage_missingPrecomputedCostAndUnknownModel_defaultsToZero() {
        let saved = ModelPricing.catalog
        defer { ModelPricing.catalog = saved }
        ModelPricing.catalog = .embedded

        let msg = ClaudeMessage(timestamp: Date(), role: "assistant", model: "totally-unpriced-model-xyz",
                                 inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                                 toolCalls: [], projectPath: "/p", isBedrock: false,
                                 linesAdded: 0, linesRemoved: 0,
                                 isOpenCode: true, precomputedCostUSD: nil)
        XCTAssertEqual(ModelPricing.cost(for: msg), 0)
    }

    /// Root-cause regression test: OpenCode reports a real, honest `0` cost
    /// for models its own provider config has no pricing metadata for (e.g. a
    /// custom internal gateway), even though real tokens were spent. When
    /// ClaudeTry's own catalog *does* know that model's price, it must use it
    /// instead of silently displaying $0.
    func test_cost_openCodeMessage_zeroCostFromOpenCode_fallsBackToCatalogWhenKnown() {
        let saved = ModelPricing.catalog
        defer { ModelPricing.catalog = saved }
        ModelPricing.catalog = PricingCatalog(entries: [
            "gpt-6-astra": PricingEntry(inputPerToken: 10e-6, outputPerToken: 50e-6,
                                         cacheCreationPerToken: 12.5e-6, cacheReadPerToken: 1e-6)
        ])

        let msg = ClaudeMessage(timestamp: Date(), role: "assistant", model: "gpt-6-astra",
                                 inputTokens: 1000, outputTokens: 500, cacheReadTokens: 0, cacheWriteTokens: 0,
                                 toolCalls: [], projectPath: "/p", isBedrock: false,
                                 linesAdded: 0, linesRemoved: 0,
                                 isOpenCode: true, precomputedCostUSD: 0) // OpenCode's own honest-but-unpriced 0
        // 1000 * 10e-6 + 500 * 50e-6 = 0.01 + 0.025 = 0.035
        XCTAssertEqual(ModelPricing.cost(for: msg)!, 0.035, accuracy: 0.0000001)
    }

    /// A nonzero cost OpenCode DOES know (e.g. via a provider with real
    /// pricing) must never be overridden by a catalog estimate, even if the
    /// catalog also has an entry for that model.
    func test_cost_openCodeMessage_nonzeroPrecomputedCost_neverOverriddenByCatalog() {
        let saved = ModelPricing.catalog
        defer { ModelPricing.catalog = saved }
        ModelPricing.catalog = PricingCatalog(entries: [
            "gpt-6-astra": PricingEntry(inputPerToken: 10e-6, outputPerToken: 50e-6,
                                         cacheCreationPerToken: 12.5e-6, cacheReadPerToken: 1e-6)
        ])

        let msg = ClaudeMessage(timestamp: Date(), role: "assistant", model: "gpt-6-astra",
                                 inputTokens: 1000, outputTokens: 500, cacheReadTokens: 0, cacheWriteTokens: 0,
                                 toolCalls: [], projectPath: "/p", isBedrock: false,
                                 linesAdded: 0, linesRemoved: 0,
                                 isOpenCode: true, precomputedCostUSD: 9.99) // OpenCode's own real, nonzero cost
        XCTAssertEqual(ModelPricing.cost(for: msg), 9.99)
    }

    func test_cost_claudeCodeMessage_usesModelCatalog_ignoresPrecomputedCost() {
        let tokens = TokenCount(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)
        let msg = ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                                 inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
                                 toolCalls: [], projectPath: "/p", isBedrock: false,
                                 linesAdded: 0, linesRemoved: 0,
                                 isOpenCode: false, precomputedCostUSD: 999) // must be ignored
        XCTAssertEqual(ModelPricing.cost(for: msg)!, ModelPricing.cost(for: "claude-sonnet-4-6", tokens: tokens)!, accuracy: 0.001)
        XCTAssertEqual(ModelPricing.cost(for: msg)!, 3.0, accuracy: 0.001)
    }

    func test_cost_session_sumsAcrossClaudeAndOpenCodeMessages() {
        let now = Date()
        let claudeMsg = ClaudeMessage(timestamp: now, role: "assistant", model: "claude-sonnet-4-6",
                                       inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
                                       toolCalls: [], projectPath: "/p", isBedrock: false,
                                       linesAdded: 0, linesRemoved: 0,
                                       isOpenCode: false, precomputedCostUSD: nil) // costs $3.0
        let openCodeMsg = ClaudeMessage(timestamp: now, role: "assistant", model: "gpt-5.6-luna",
                                         inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
                                         toolCalls: [], projectPath: "/p", isBedrock: false,
                                         linesAdded: 0, linesRemoved: 0,
                                         isOpenCode: true, precomputedCostUSD: 2.5)
        let session = Session(id: UUID(), projectPath: "/p", startTime: now, endTime: now,
                              messages: [claudeMsg, openCodeMsg])
        XCTAssertEqual(ModelPricing.cost(for: session)!, 5.5, accuracy: 0.001)
    }
}
