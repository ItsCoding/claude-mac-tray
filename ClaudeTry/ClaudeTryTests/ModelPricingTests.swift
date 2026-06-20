import XCTest
@testable import ClaudeTry

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

    func test_cost_includesCacheTokens() {
        // 1M cache read tokens at $0.30/M = $0.30
        let tokens = TokenCount(input: 0, output: 0, cacheRead: 1_000_000, cacheWrite: 0)
        let cost = ModelPricing.cost(for: "claude-sonnet-4-6", tokens: tokens)
        XCTAssertEqual(cost!, 0.30, accuracy: 0.001)
    }
}
