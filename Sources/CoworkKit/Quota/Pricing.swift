import Foundation

/// Claude's API list prices, used to weigh one model's tokens against another's.
///
/// Plan limits aren't published as a formula, so these only estimate each conversation's
/// share of what was used; they're the fairest common unit, since a token of Fable costs
/// what five of Sonnet do. Prices as of September 2026, per million tokens.
public enum Pricing {

    public struct Rate: Sendable, Equatable {
        public let input: Double
        public let output: Double
        /// Cache reads as a fraction of the input price.
        public let cacheReadFactor: Double
    }

    /// Most specific prefix first.
    static let table: [(prefix: String, rate: Rate)] = [
        ("claude-fable-5", Rate(input: 10, output: 50, cacheReadFactor: 0.025)),
        ("claude-mythos-5", Rate(input: 10, output: 50, cacheReadFactor: 0.025)),
        ("claude-opus-5-5", Rate(input: 4, output: 20, cacheReadFactor: 0.05)),
        ("claude-opus-5", Rate(input: 5, output: 25, cacheReadFactor: 0.1)),
        ("claude-opus-4-8", Rate(input: 5, output: 25, cacheReadFactor: 0.1)),
        ("claude-opus-4-7", Rate(input: 5, output: 25, cacheReadFactor: 0.1)),
        ("claude-opus-4-6", Rate(input: 5, output: 25, cacheReadFactor: 0.1)),
        ("claude-opus-4-5", Rate(input: 5, output: 25, cacheReadFactor: 0.1)),
        ("claude-opus-4", Rate(input: 15, output: 75, cacheReadFactor: 0.1)),
        ("claude-sonnet-5", Rate(input: 2, output: 10, cacheReadFactor: 0.1)),
        ("claude-sonnet-4", Rate(input: 3, output: 15, cacheReadFactor: 0.1)),
        ("claude-3-7-sonnet", Rate(input: 3, output: 15, cacheReadFactor: 0.1)),
        ("claude-haiku-4", Rate(input: 1, output: 5, cacheReadFactor: 0.1)),
        ("claude-3-5-haiku", Rate(input: 0.8, output: 4, cacheReadFactor: 0.1)),
    ]

    /// The rate for a model id, or Opus 5's when it's one this table doesn't know yet — a
    /// middle-of-the-range guess beats counting a new model as free.
    public static func rate(for model: String) -> Rate {
        let id = model.lowercased().split(separator: "[").first.map(String.init) ?? model
        return table.first { id.hasPrefix($0.prefix) }?.rate ?? Rate(input: 5, output: 25, cacheReadFactor: 0.1)
    }

    /// Whether the table has this model's own price, rather than the guess.
    public static func knows(_ model: String) -> Bool {
        let id = model.lowercased().split(separator: "[").first.map(String.init) ?? model
        return table.contains { id.hasPrefix($0.prefix) }
    }

    /// What one reply would cost at list price, in dollars.
    public static func cost(model: String, input: Int64, output: Int64, cacheRead: Int64,
                            cacheWrite5m: Int64, cacheWrite1h: Int64) -> Double {
        let rate = rate(for: model)
        let perToken = 1.0 / 1_000_000
        return (Double(input) * rate.input
                + Double(output) * rate.output
                + Double(cacheRead) * rate.input * rate.cacheReadFactor
                + Double(cacheWrite5m) * rate.input * 1.25
                + Double(cacheWrite1h) * rate.input * 2) * perToken
    }
}
