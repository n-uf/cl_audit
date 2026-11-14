// ProfileCore · parsing: what a Claude Code sign-in item's text holds (never kept or logged), and Anthropic's usage and
// profile replies. Getting that text (the Keychain) and reading files stay in the app: the core never reads either.

import Foundation

public enum Login {
    case token(String, expiresAt: Date?, plan: String?)
    /// No Keychain item for the folder (`security` said "not found" for every account name tried).
    case notFound
    /// The read was refused or timed out (a locked Keychain, "Don't Allow", a prompt nobody answered).
    case denied
    /// An item is there and was read, but its text isn't a sign-in in a known form (not JSON, or JSON without
    /// claudeAiOauth.accessToken). Nothing of its content is kept or shown: only that it was there.
    case unreadable

    /// What `security -w` printed for an item that was read: the token, or `.unreadable`. Never logs or keeps the text.
    public static func parse(_ out: Data) -> Login {
        guard let data = decode(out),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return .unreadable }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return .token(token, expiresAt: expires, plan: oauth["subscriptionType"] as? String)
    }

    /// `security -w` prints the stored text, or hex when it isn't plain text.
    static func decode(_ raw: Data) -> Data? {
        guard let text = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if text.hasPrefix("{") { return Data(text.utf8) }
        guard text.count % 2 == 0, text.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = [UInt8]()
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 2)
            guard let b = UInt8(text[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        return Data(bytes)
    }
}

public enum UsageParser {
    public static func date(_ v: Any?) -> Date? {
        if let n = v as? NSNumber {
            let x = n.doubleValue
            return Date(timeIntervalSince1970: x > 1e12 ? x / 1000 : x)
        }
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    public static func percent(_ w: [String: Any]) -> Double? {
        for key in ["utilization", "used_percentage", "percent"] {
            if let n = w[key] as? NSNumber { return n.doubleValue }
        }
        return nil
    }

    /// Accepts {five_hour:{utilization,resets_at}, seven_day:{…}} and a {limits:[{type,percent,resets_at}]} variant.
    /// `now`: when it was read; `source`: how an app names where the numbers came from.
    public static func fromAPI(_ data: Data, now: Date = Date(), source: String = "Anthropic") -> Usage? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var u = Usage(fetchedAt: now, source: source)
        if let w = j["five_hour"] as? [String: Any] { u.fiveHour = percent(w); u.fiveHourResets = date(w["resets_at"]) }
        if let w = j["seven_day"] as? [String: Any] { u.weekly = percent(w); u.weeklyResets = date(w["resets_at"]) }
        if u.fiveHour == nil, u.weekly == nil, let limits = j["limits"] as? [[String: Any]] {
            for w in limits {
                let kind = ((w["type"] ?? w["name"] ?? w["window"]) as? String ?? "").lowercased()
                if kind.contains("five") || kind.contains("5h") || kind.contains("session") {
                    u.fiveHour = percent(w); u.fiveHourResets = date(w["resets_at"])
                } else if kind.contains("seven") || kind.contains("week") {
                    u.weekly = percent(w); u.weeklyResets = date(w["resets_at"])
                }
            }
        }
        guard u.fiveHour != nil || u.weekly != nil else { return nil }
        u.scoped = scoped(j)
        u.credits = Credits.parse(j)
        u.noFiveHour = noFiveHour(j)
        return u
    }

    /// The plan has no 5-hour limit at all (Ultra): no five_hour window and no "session" kind in limits[]. A plan
    /// that has one but no session open (Max) still lists the session limit, so it isn't taken for this.
    public static func noFiveHour(_ j: [String: Any]) -> Bool {
        guard j["five_hour"] as? [String: Any] == nil, let limits = j["limits"] as? [[String: Any]], !limits.isEmpty
        else { return false }
        return !limits.contains { ($0["kind"] as? String) == "session" || ($0["group"] as? String) == "session" }
    }

    /// The model limits in limits[]: {kind: "weekly_scoped", percent, resets_at, scope: {model: {display_name}}}.
    public static func scoped(_ j: [String: Any]) -> [ScopedLimit] {
        guard let limits = j["limits"] as? [[String: Any]] else { return [] }
        return limits.compactMap { w in
            guard (w["kind"] as? String) == "weekly_scoped",
                  let model = (w["scope"] as? [String: Any])?["model"] as? [String: Any],
                  let name = (model["display_name"] as? String) ?? (model["id"] as? String), !name.isEmpty
            else { return nil }
            return ScopedLimit(name: name, percent: percent(w), resets: date(w["resets_at"]))
        }
    }

    /// First e-mail address anywhere in the profile reply (it sits under account.email_address / email).
    public static func email(_ data: Data) -> String? {
        func find(_ v: Any) -> String? {
            if let d = v as? [String: Any] {
                for (k, x) in d where k.lowercased().contains("email") { if let s = x as? String, s.contains("@") { return s } }
                for (_, x) in d { if let s = find(x) { return s } }
            } else if let a = v as? [Any] {
                for x in a { if let s = find(x) { return s } }
            }
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)).flatMap(find)
    }
}
