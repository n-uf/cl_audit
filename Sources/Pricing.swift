// Pricing: a cost estimate for the usage history at Anthropic's API list prices, in USD per million tokens, as read
// on 3 Nov 2026 from platform.claude.com/docs/en/about-claude/pricing. It's not a bill: use on a Pro, Max, Ultra or
// Team plan is paid for by the plan, and the estimate only says what the same tokens would cost on the API.
// Models without a published price are left out, never guessed.

import Foundation

enum Pricing {
    struct Rate {
        let input, output, write5m, write1h, read: Double
        init(_ input: Double, _ output: Double, _ write5m: Double, _ write1h: Double, _ read: Double) {
            self.input = input; self.output = output; self.write5m = write5m; self.write1h = write1h; self.read = read
        }
    }

    static let asOf = "3 Nov 2026"

    /// By model id; the longest id that starts the reply's model wins ("claude-opus-5-5" before "claude-opus-5").
    static let table: [(id: String, rate: Rate)] = [
        ("claude-fable-5-1", Rate(10, 50, 12.5, 20, 0.25)),
        ("claude-fable-5", Rate(10, 50, 12.5, 20, 1)),
        ("claude-mythos-5-1", Rate(10, 50, 12.5, 20, 0.25)),
        ("claude-mythos-5", Rate(10, 50, 12.5, 20, 1)),
        ("claude-opus-5-5", Rate(4, 20, 5, 8, 0.2)),
        ("claude-opus-5", Rate(5, 25, 6.25, 10, 0.5)),
        ("claude-opus-4-8", Rate(5, 25, 6.25, 10, 0.5)),
        ("claude-opus-4-7", Rate(5, 25, 6.25, 10, 0.5)),
        ("claude-opus-4-6", Rate(5, 25, 6.25, 10, 0.5)),
        ("claude-opus-4-5", Rate(5, 25, 6.25, 10, 0.5)),
        ("claude-opus-4-1", Rate(15, 75, 18.75, 30, 1.5)),
        ("claude-opus-4", Rate(15, 75, 18.75, 30, 1.5)),
        ("claude-sonnet-5-5", Rate(2, 10, 2.5, 4, 0.1)),
        ("claude-sonnet-5", Rate(2, 10, 2.5, 4, 0.2)),
        ("claude-sonnet-4-6", Rate(3, 15, 3.75, 6, 0.3)),
        ("claude-sonnet-4-5", Rate(3, 15, 3.75, 6, 0.3)),
        ("claude-sonnet-4", Rate(3, 15, 3.75, 6, 0.3)),
        ("claude-haiku-5-5", Rate(0.1, 0.5, 0.125, 0.2, 0.01)),
        ("claude-haiku-4-5", Rate(1, 5, 1.25, 2, 0.1)),
        ("claude-3-5-haiku", Rate(0.8, 4, 1, 1.6, 0.08)),
    ]
    /// Haiku 5.5 above 100K prompt tokens (input + cache reads + cache writes of that request).
    static let haiku55Long = Rate(0.5, 2.5, 0.625, 1, 0.05)
    /// Fast mode costs twice the standard price on the models that have it.
    static let fastModels = ["claude-opus-5-5", "claude-opus-5", "claude-opus-4-8"]

    static func rate(_ modelID: String) -> (id: String, rate: Rate)? {
        table.filter { modelID == $0.id || modelID.hasPrefix($0.id + "-") }.max { $0.id.count < $1.id.count }
    }

    /// What one reply would cost on the API, in USD, or nil for a model without a published price.
    static func cost(_ r: Reply) -> Double? {
        guard let (id, base) = rate(r.modelID) else { return nil }
        var rate = base
        if id == "claude-haiku-5-5", r.input + r.cacheRead + r.cacheWrite5m + r.cacheWrite1h > 100_000 { rate = haiku55Long }
        var usd = (Double(r.input) * rate.input + Double(r.output) * rate.output + Double(r.cacheWrite5m) * rate.write5m
                   + Double(r.cacheWrite1h) * rate.write1h + Double(r.cacheRead) * rate.read) / 1_000_000
        if r.fast, fastModels.contains(id) { usd *= 2 }
        if r.usOnly { usd *= 1.1 }                       // US-only inference
        return usd
    }

    /// "$1,234", "$56.20", "$0.42".
    static func words(_ usd: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency; f.locale = Locale(identifier: "en_US"); f.currencyCode = "USD"; f.roundingMode = .halfUp
        f.maximumFractionDigits = usd >= 1000 ? 0 : 2
        f.minimumFractionDigits = usd >= 1000 ? 0 : 2
        return f.string(from: usd as NSNumber) ?? String(format: "$%.2f", usd)
    }
}
