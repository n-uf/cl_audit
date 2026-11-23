// ProfileCore · limits: the usage numbers, when saved numbers still count, when a limit is full and which one holds the
// profile back, a model's own weekly limit, and usage credits.
//
// Full means 100% (Anthropic's usage reply has no separate "refusing" flag; at 100% it refuses). A full limit whose
// reset time has passed no longer counts.

import Foundation

// MARK: - Usage data

public struct Usage: Equatable {
    public var fiveHour: Double?
    public var fiveHourResets: Date?
    public var weekly: Double?
    public var weeklyResets: Date?
    public var fetchedAt: Date
    public var source: String
    public var scoped: [ScopedLimit] = []       // weekly limits of one model (Fable on Max, Ultra, premium seats), beside the two
    public var credits: Credits? = nil          // usage credits
    public var noFiveHour = false               // the plan has no 5-hour limit (Ultra): only the week counts

    public init(fiveHour: Double? = nil, fiveHourResets: Date? = nil, weekly: Double? = nil, weeklyResets: Date? = nil,
                fetchedAt: Date, source: String, scoped: [ScopedLimit] = [], credits: Credits? = nil, noFiveHour: Bool = false) {
        self.fiveHour = fiveHour; self.fiveHourResets = fiveHourResets; self.weekly = weekly; self.weeklyResets = weeklyResets
        self.fetchedAt = fetchedAt; self.source = source; self.scoped = scoped; self.credits = credits; self.noFiveHour = noFiveHour
    }

    /// Without the limits whose reset time has passed (their percent and reset both): a percent from before a reset is
    /// no one's now, so it is never shown as "in 0 min".
    public func current(now: Date = Date()) -> Usage {
        var u = self
        (u.fiveHour, u.fiveHourResets) = Freshness.current(u.fiveHour, resets: u.fiveHourResets, now: now)
        (u.weekly, u.weeklyResets) = Freshness.current(u.weekly, resets: u.weeklyResets, now: now)
        u.scoped = u.scoped.map { $0.current(now: now) }
        return u
    }
}

/// When saved numbers still count. The thresholds are a caller's (they differ per app and per use); the defaults are the
/// ones a Claude Code status line file is held to.
public enum Freshness {
    /// Numbers written longer ago than this are old (the default `within`: a status line file's 15 minutes).
    public static let window: TimeInterval = 15 * 60
    /// A clock a little ahead of this Mac's (the default `skew`).
    public static let skew: TimeInterval = 60

    /// Written in the last `within` (15 minutes unless given), not in the future beyond `skew`.
    public static func isFresh(_ at: Date?, now: Date = Date(), within: TimeInterval = Freshness.window,
                               skew: TimeInterval = Freshness.skew) -> Bool {
        guard let at else { return false }
        let age = now.timeIntervalSince(at)
        return age <= within && age >= -skew
    }

    /// A limit's reset time that has passed.
    public static func passed(_ resets: Date?, now: Date = Date()) -> Bool { resets.map { $0 <= now } ?? false }

    /// One limit as it may be shown now, the one "reset passed" rule: once its reset time has passed it has no percent and
    /// no reset (a percent from before a reset is no one's now, never a number "in 0 min"); else as read.
    public static func current(_ percent: Double?, resets: Date?, now: Date = Date()) -> (percent: Double?, resets: Date?) {
        passed(resets, now: now) ? (nil, nil) : (percent, resets)
    }
}

/// A weekly limit of its own for one model: "Fable" may use up to a share of the week. Full, it holds back only that
/// model; the profile can still work with the others, so it never takes the full-limit box or the countdown face.
public struct ScopedLimit: Codable, Equatable {
    public var name: String                     // "Fable"
    public var percent: Double?
    public var resets: Date?

    public init(name: String, percent: Double?, resets: Date?) { self.name = name; self.percent = percent; self.resets = resets }

    /// A stable key for the limit, kept in saved marks (so not wording): "mfable".
    public var key: String { "m" + name.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// As it may be shown now (Freshness.current): past its reset it keeps its name only.
    public func current(now: Date = Date()) -> ScopedLimit {
        let c = Freshness.current(percent, resets: resets, now: now)
        return ScopedLimit(name: name, percent: c.percent, resets: c.resets)
    }
}

// MARK: - The week-only rule

extension Usage {
    /// The 5-hour row shows: the one week-only rule, in its exact form, from the raw numbers (never `current()`'s, which drop
    /// a 5-hour number past its reset, an idle 5-hour account's case too):
    /// `fiveHour != nil || week == nil || refusedOn == .fiveHour || heldBack?.window == .fiveHour`.
    /// So it hides only for an account with a week that has never had a 5-hour number, and an old 5-hour number is never
    /// dropped. A plan without the window (`noFiveHour`, whose reader never keeps a 5-hour number) falls out of it too.
    public static func hasFiveHour(fiveHour: Double?, week: Double?, refusedOn: Refusal.On?, heldBack: HeldBack?) -> Bool {
        fiveHour != nil || week == nil || refusedOn == .fiveHour || heldBack?.window == .fiveHour
    }

    /// The rule for these numbers, a standing refusal's window, and what holds them back now (AtLimit.heldBack). A plan
    /// without the window (`noFiveHour`) never shows it.
    public func hasFiveHour(refusal: Refusal? = nil, now: Date = Date()) -> Bool {
        !noFiveHour && Usage.hasFiveHour(fiveHour: fiveHour, week: weekly, refusedOn: refusal?.on,
                          heldBack: AtLimit.heldBack(fiveHour: fiveHour, fiveHourResets: fiveHourResets, weekly: weekly,
                                                     weeklyResets: weeklyResets, refusal: refusal, now: now))
    }
}

// MARK: - Full limits

/// What holds a profile back now: a full limit (FullLimit), or a refusal standing while the numbers show none full. A
/// refusal's window is the one the numbers leave: the week when only the 5-hour number is known (below 100), the 5-hour
/// one when only the week is; `any` when both are known (not known which); with neither known, the window the refusal
/// named, else `any`. Data only.
public struct HeldBack: Equatable {
    public enum Window: Equatable { case fiveHour, week, any }
    public let window: Window
    public let resets: Date?
    /// With a full limit: the other one, when both are full.
    public let alsoFull: FullLimit.Kind?
    /// Held back by a refusal, not by a number at 100%.
    public let refused: Bool

    public init(window: Window, resets: Date?, alsoFull: FullLimit.Kind? = nil, refused: Bool) {
        self.window = window; self.resets = resets; self.alsoFull = alsoFull; self.refused = refused
    }

    public init(_ f: FullLimit) {
        self.init(window: f.kind == .fiveHour ? .fiveHour : .week, resets: f.resets, alsoFull: f.alsoFull, refused: false)
    }

    /// The full limit, when a number holds it back.
    public var full: FullLimit? {
        guard !refused else { return nil }
        switch window {
        case .fiveHour: return FullLimit(kind: .fiveHour, resets: resets, alsoFull: alsoFull)
        case .week: return FullLimit(kind: .week, resets: resets, alsoFull: alsoFull)
        case .any: return nil
        }
    }
}

/// The full limit that holds a profile back: of the full ones, the one that resets last (an unknown reset counts as
/// last). `alsoFull` is the other limit, when both are full. Data only: each app names the limits and words the times.
public struct FullLimit: Equatable {
    /// Which of the plan's two limits.
    public enum Kind: Equatable { case fiveHour, week }
    public let kind: Kind
    public let resets: Date?
    public let alsoFull: Kind?

    public init(kind: Kind, resets: Date?, alsoFull: Kind? = nil) { self.kind = kind; self.resets = resets; self.alsoFull = alsoFull }

    /// Whole minutes until the reset (rounded up), or nil when the reset time isn't known.
    public func minutesLeft(_ now: Date = Date()) -> Int? { resets.map { TimeWords.minutesLeft($0, now: now) } }
}

public enum AtLimit {
    /// 100% as a person reads it (rounded).
    public static func isFull(_ p: Double?) -> Bool { p.map { $0.rounded() >= 100 } ?? false }

    /// Full and not yet reset.
    public static func holding(_ p: Double?, _ resets: Date?, now: Date = Date()) -> Bool {
        isFull(p) && (resets.map { $0 > now } ?? true)
    }

    /// The full limit that holds the profile back, or nil when nothing is full.
    public static func blocker(fiveHour: Double?, fiveHourResets: Date?, weekly: Double?, weeklyResets: Date?,
                               now: Date = Date()) -> FullLimit? {
        let five = holding(fiveHour, fiveHourResets, now: now), week = holding(weekly, weeklyResets, now: now)
        switch (five, week) {
        case (false, false): return nil
        case (true, false): return FullLimit(kind: .fiveHour, resets: fiveHourResets)
        case (false, true): return FullLimit(kind: .week, resets: weeklyResets)
        case (true, true):
            // the one that resets last; unknown counts as last, and the week wins a tie
            let fiveLater = (fiveHourResets ?? .distantFuture) > (weeklyResets ?? .distantFuture)
            return fiveLater ? FullLimit(kind: .fiveHour, resets: fiveHourResets, alsoFull: .week)
                             : FullLimit(kind: .week, resets: weeklyResets, alsoFull: .fiveHour)
        }
    }

    /// What holds the profile back now: the full limit (`blocker`), else a standing refusal (its `until` ahead, or not given:
    /// the caller lifts it), its window by what the numbers leave (HeldBack); nil when neither.
    public static func heldBack(fiveHour: Double?, fiveHourResets: Date?, weekly: Double?, weeklyResets: Date?, refusal: Refusal?,
                                now: Date = Date()) -> HeldBack? {
        if let b = blocker(fiveHour: fiveHour, fiveHourResets: fiveHourResets, weekly: weekly, weeklyResets: weeklyResets, now: now) {
            return HeldBack(b)
        }
        guard let r = refusal, r.until.map({ $0 > now }) ?? true else { return nil }
        // the numbers as they count now (a passed reset's number is no one's); none of them is full here
        let five = Freshness.current(fiveHour, resets: fiveHourResets, now: now).percent
        let week = Freshness.current(weekly, resets: weeklyResets, now: now).percent
        let window: HeldBack.Window
        switch (five != nil, week != nil, r.on) {
        case (true, false, _): window = .week
        case (false, true, _): window = .fiveHour
        // both known (both below 100): which one refuses isn't known, whatever the refusal named (cl_quick's rule)
        case (true, true, _): window = .any
        // neither known: the window the refusal named, else not known
        case (false, false, .fiveHour): window = .fiveHour
        case (false, false, .week): window = .week
        case (false, false, .unknown): window = .any
        }
        return HeldBack(window: window, resets: r.until, refused: true)
    }

    /// Whether a limit counts as full, in one of two modes (the thresholds are the caller's):
    /// - `.acts(freshFor:)`: full numbers read within `freshFor`, whose reset is ahead or unknown. Only these may act: a
    ///   full banner, an offer to switch, an alert.
    /// - `.display`: full and dated, its reset known and still ahead, however old the reading (a screen may show it grey
    ///   as "last known" until the reset). A dateless 100% doesn't count.
    /// (`holding`/`blocker` are the third rule: full while the reset is ahead or unknown; see Core/README.md.)
    public enum Mode: Equatable { case acts(freshFor: TimeInterval), display }

    public static func full(_ p: Double?, resets: Date?, readAt: Date?, mode: Mode, now: Date = Date()) -> Bool {
        guard isFull(p) else { return false }
        switch mode {
        case .acts(let freshFor):
            guard let at = readAt, now.timeIntervalSince(at) <= freshFor else { return false }
            return resets.map { $0 > now } ?? true
        case .display:
            return resets.map { $0 > now } ?? false
        }
    }
}

// MARK: - Usage credits

/// Usage credits, which carry a profile on past its plan limits. Read from Anthropic's usage reply ("spend", or the older
/// "extra_usage"). Shown only while they're being spent: credits are on and a plan limit is full, or the amount spent went
/// up within the last hour.
public struct Credits: Codable, Equatable {
    public var enabled: Bool
    public var used: Double?          // spent so far, in the currency's units ($4.20)
    public var cap: Double?           // the spending cap, when there is one
    public var currency: String?
    public var out: Bool              // none left, or the cap is reached
    public var spentAt: Date? = nil   // when the agent last saw the amount go up

    public init(enabled: Bool, used: Double?, cap: Double?, currency: String?, out: Bool, spentAt: Date? = nil) {
        self.enabled = enabled; self.used = used; self.cap = cap; self.currency = currency; self.out = out; self.spentAt = spentAt
    }

    /// spend: {enabled, disabled_reason, used: {amount_minor, currency, exponent}, limit}; extra_usage:
    /// {is_enabled, disabled_reason, spend_limit_reached}. Amounts are taken only where the unit is given.
    public static func parse(_ j: [String: Any]) -> Credits? {
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
    public static func carry(_ new: Credits?, from old: Credits?, now: Date = Date()) -> Credits? {
        guard var c = new else { return nil }
        if let n = c.used, let o = old?.used, n > o + 0.001 { c.spentAt = now } else { c.spentAt = old?.spentAt }
        return c
    }

    /// Being spent now: on, and a plan limit is full or the amount went up within the hour.
    public func inUse(fiveHour: Double?, weekly: Double?, now: Date = Date()) -> Bool {
        guard enabled, !out else { return false }
        if AtLimit.isFull(fiveHour) || AtLimit.isFull(weekly) { return true }
        return spentAt.map { now.timeIntervalSince($0) < 3600 } ?? false
    }

    /// An amount in the credits' currency ("$4.20").
    public func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency; f.locale = Locale(identifier: "en_US"); f.currencyCode = currency ?? "USD"
        return f.string(from: v as NSNumber) ?? String(format: "%.2f", v)
    }
}
