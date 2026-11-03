// Credits: usage credits, which carry a profile on past its plan limits. Read from Anthropic's usage reply ("spend",
// or the older "extra_usage"). Shown only while they're being spent: credits are on and a plan limit is full, or the
// amount spent went up within the last hour. The agent alerts once when a profile starts spending them, and once when
// they run out.

import AppKit
import SwiftUI

struct Credits: Codable, Equatable {
    var enabled: Bool
    var used: Double?          // spent so far, in the currency's units ($4.20)
    var cap: Double?           // the spending cap, when there is one
    var currency: String?
    var out: Bool              // none left, or the cap is reached
    var spentAt: Date? = nil   // when the agent last saw the amount go up

    /// spend: {enabled, disabled_reason, used: {amount_minor, currency, exponent}, limit}; extra_usage:
    /// {is_enabled, disabled_reason, spend_limit_reached}. Amounts are taken only where the unit is given.
    static func parse(_ j: [String: Any]) -> Credits? {
        func flag(_ v: Any?) -> Bool? { (v as? NSNumber)?.boolValue }
        func money(_ v: Any?) -> (amount: Double, currency: String?)? {
            guard let d = v as? [String: Any], let minor = (d["amount_minor"] as? NSNumber)?.doubleValue else { return nil }
            let exponent = (d["exponent"] as? NSNumber)?.intValue ?? 2
            return (minor / pow(10, Double(exponent)), d["currency"] as? String)
        }
        let extra = j["extra_usage"] as? [String: Any]
        let reachedCap = flag(extra?["spend_limit_reached"]) == true
        if let s = j["spend"] as? [String: Any] {
            let used = money(s["used"]), cap = money(s["limit"]) ?? money(s["cap"])
            return Credits(enabled: flag(s["enabled"]) ?? false, used: used?.amount, cap: cap?.amount,
                           currency: used?.currency ?? cap?.currency ?? (extra?["currency"] as? String),
                           out: (s["disabled_reason"] as? String) == "out_of_credits" || reachedCap)
        }
        guard let e = extra else { return nil }
        return Credits(enabled: flag(e["is_enabled"]) ?? false, used: nil, cap: nil, currency: e["currency"] as? String,
                       out: (e["disabled_reason"] as? String) == "out_of_credits" || reachedCap)
    }

    /// The new reading, keeping when the amount last went up.
    static func carry(_ new: Credits?, from old: Credits?, now: Date = Date()) -> Credits? {
        guard var c = new else { return nil }
        if let n = c.used, let o = old?.used, n > o + 0.001 { c.spentAt = now } else { c.spentAt = old?.spentAt }
        return c
    }

    /// Being spent now: on, and a plan limit is full or the amount went up within the hour.
    func inUse(fiveHour: Double?, weekly: Double?, now: Date = Date()) -> Bool {
        guard enabled, !out else { return false }
        if AtLimit.isFull(fiveHour) || AtLimit.isFull(weekly) { return true }
        return spentAt.map { now.timeIntervalSince($0) < 3600 } ?? false
    }

    func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency; f.locale = Locale(identifier: "en_US"); f.currencyCode = currency ?? "USD"
        return f.string(from: v as NSNumber) ?? String(format: "%.2f", v)
    }

    /// "$4.20 spent", "$4.20 of $50.00 spent".
    var spentWords: String? {
        guard let used else { return nil }
        return cap.map { "\(money(used)) of \(money($0)) spent" } ?? "\(money(used)) spent"
    }

    /// "Using usage credits · $4.20 spent".
    var line: String { "Using usage credits" + (spentWords.map { " · \($0)" } ?? "") }
}

/// The line under the limits while credits are being spent.
struct CreditsLine: View {
    let credits: Credits
    @Environment(\.face) private var face
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "creditcard.fill").font(.system(size: 10.5, weight: .semibold))
            Text(credits.line).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .foregroundStyle(face.active ? face.caution : Color(nsColor: .systemOrange))
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Claude Code goes on past the plan limits with usage credits, which are paid for. Anthropic's usage page has the details.")
    }
}
