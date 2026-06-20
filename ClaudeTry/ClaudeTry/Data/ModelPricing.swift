import Foundation

struct PricingEntry {
    let inputPerMillion: Double
    let outputPerMillion: Double
    let cacheReadPerMillion: Double
    let cacheWritePerMillion: Double
}

enum ModelPricing {
    // Prices in USD per million tokens as of 2026-06
    // Update when Anthropic changes pricing
    private static let table: [(prefix: String, entry: PricingEntry)] = [
        ("claude-opus-4",    PricingEntry(inputPerMillion: 15.0,  outputPerMillion: 75.0,  cacheReadPerMillion: 1.50,  cacheWritePerMillion: 18.75)),
        ("claude-sonnet-4",  PricingEntry(inputPerMillion: 3.0,   outputPerMillion: 15.0,  cacheReadPerMillion: 0.30,  cacheWritePerMillion: 3.75)),
        ("claude-haiku-4",   PricingEntry(inputPerMillion: 0.80,  outputPerMillion: 4.0,   cacheReadPerMillion: 0.08,  cacheWritePerMillion: 1.0)),
        ("claude-fable-5",   PricingEntry(inputPerMillion: 3.0,   outputPerMillion: 15.0,  cacheReadPerMillion: 0.30,  cacheWritePerMillion: 3.75)),
    ]

    static func cost(for modelID: String, tokens: TokenCount) -> Double? {
        guard let entry = table.first(where: { modelID.contains($0.prefix) })?.entry else { return nil }
        let inputCost  = Double(tokens.input)      / 1_000_000 * entry.inputPerMillion
        let outputCost = Double(tokens.output)     / 1_000_000 * entry.outputPerMillion
        let cacheRead  = Double(tokens.cacheRead)  / 1_000_000 * entry.cacheReadPerMillion
        let cacheWrite = Double(tokens.cacheWrite) / 1_000_000 * entry.cacheWritePerMillion
        return inputCost + outputCost + cacheRead + cacheWrite
    }

    static func cost(for session: Session) -> Double? {
        var total = 0.0
        for msg in session.messages {
            guard let model = msg.model else { return nil }
            let tokens = TokenCount(input: msg.inputTokens, output: msg.outputTokens,
                                     cacheRead: msg.cacheReadTokens, cacheWrite: msg.cacheWriteTokens)
            guard let c = cost(for: model, tokens: tokens) else { return nil }
            total += c
        }
        return total
    }
}
