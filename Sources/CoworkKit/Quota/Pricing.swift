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
        /// Tokens the model can read at once.
        public var contextWindow: Int = 1_000_000
    }

    /// Most specific prefix first: a model's point releases come before the model.
    static let table: [(prefix: String, rate: Rate)] = [
        ("claude-fable-5-1", Rate(input: 10, output: 50, cacheReadFactor: 0.025)),
        ("claude-mythos-5-1", Rate(input: 10, output: 50, cacheReadFactor: 0.025)),
        ("claude-fable-5", Rate(input: 10, output: 50, cacheReadFactor: 0.1)),
        ("claude-mythos-5", Rate(input: 10, output: 50, cacheReadFactor: 0.1)),
        ("claude-opus-5-5", Rate(input: 4, output: 20, cacheReadFactor: 0.05)),
        ("claude-opus-5", Rate(input: 5, output: 25, cacheReadFactor: 0.1)),
        ("claude-opus-4-8", Rate(input: 5, output: 25, cacheReadFactor: 0.1)),
        ("claude-opus-4-7", Rate(input: 5, output: 25, cacheReadFactor: 0.1)),
        ("claude-opus-4-6", Rate(input: 5, output: 25, cacheReadFactor: 0.1)),
        ("claude-opus-4-5", Rate(input: 5, output: 25, cacheReadFactor: 0.1, contextWindow: 200_000)),
        ("claude-opus-4", Rate(input: 15, output: 75, cacheReadFactor: 0.1, contextWindow: 200_000)),
        ("claude-sonnet-5", Rate(input: 2, output: 10, cacheReadFactor: 0.1)),
        ("claude-sonnet-4-6", Rate(input: 3, output: 15, cacheReadFactor: 0.1)),
        ("claude-sonnet-4", Rate(input: 3, output: 15, cacheReadFactor: 0.1, contextWindow: 200_000)),
        ("claude-3-7-sonnet", Rate(input: 3, output: 15, cacheReadFactor: 0.1, contextWindow: 200_000)),
        ("claude-3-5-sonnet", Rate(input: 3, output: 15, cacheReadFactor: 0.1, contextWindow: 200_000)),
        ("claude-haiku-4", Rate(input: 1, output: 5, cacheReadFactor: 0.1, contextWindow: 200_000)),
        ("claude-3-5-haiku", Rate(input: 0.8, output: 4, cacheReadFactor: 0.1, contextWindow: 200_000)),
        ("claude-3-opus", Rate(input: 15, output: 75, cacheReadFactor: 0.1, contextWindow: 200_000)),
        ("claude-3-haiku", Rate(input: 0.25, output: 1.25, cacheReadFactor: 0.1, contextWindow: 200_000)),
    ]

    /// For a model the table doesn't know yet: a middle-of-the-range guess beats counting a
    /// new model as free.
    static let fallback = Rate(input: 5, output: 25, cacheReadFactor: 0.1)

    /// The Anthropic model id inside the forms other platforms and settings use:
    /// "claude-opus-4-8[1m]", Bedrock's "us.anthropic.claude-opus-4-1-20250805-v1:0",
    /// Vertex's "claude-opus-4-5@20251101".
    public static func baseID(_ model: String) -> String {
        var id = model.lowercased().trimmingCharacters(in: .whitespaces)
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
        if let range = id.range(of: "anthropic.") { id = String(id[range.upperBound...]) }
        if let range = id.range(of: #"-v\d+(:\d+)?$"#, options: .regularExpression) { id.removeSubrange(range) }
        return id
    }

    static func entry(for model: String) -> Rate? {
        let id = baseID(model)
        return table.first { id.hasPrefix($0.prefix) }?.rate
    }

    /// The rate for a model id, or the fallback when it's one this table doesn't know yet.
    public static func rate(for model: String) -> Rate { entry(for: model) ?? fallback }

    /// Whether the table has this model's own price, rather than the guess.
    public static func knows(_ model: String) -> Bool { entry(for: model) != nil }

    /// The model's context window. A "[1m]" model, or a conversation that has already read
    /// more than 200K, has the million-token one.
    public static func contextWindow(for model: String, peak: Int = 0) -> Int {
        if model.lowercased().contains("[1m]") || peak > 200_000 { return 1_000_000 }
        return rate(for: model).contextWindow
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

    /// A dollar amount as the app shows it: "$0" for nothing, "under 1¢" for a fraction of a
    /// cent, cents below $100 and whole dollars from there.
    public static func dollars(_ value: Double, locale: Locale = .current) -> String {
        let currency = FloatingPointFormatStyle<Double>.Currency(code: "USD", locale: locale)
        if value == 0 { return value.formatted(currency.precision(.fractionLength(0))) }
        if abs(value) < 0.01 { return "under 1¢" }
        return value.formatted(currency.precision(.fractionLength(abs(value) < 100 ? 2 : 0)))
    }
}
