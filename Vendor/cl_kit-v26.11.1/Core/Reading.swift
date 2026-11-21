// ProfileCore · reading: the rules for taking usage numbers in, as parameters, so each app keeps its own set (Core/README.md,
// "Differences from cl_quick"): which sources give a 0–1 fraction instead of a percent, what a partial or empty answer
// does, which window is the week, when the account is refused and when that lifts, and when a message's own text may say a
// limit. Also the reader's state words as data (`FetchState`) and a sign-in as read, without its token (`SignInRead`).
// ReaderMachine (ReaderMachine.swift) applies them.

import Foundation

/// How a profile's last read went. Kept in the status record as its description ("ok", "rateLimited",
/// "failed(\"HTTP 500\")"), so the case names are data: they must not change.
public enum FetchState: Equatable {
    case idle, ok, noLogin, expired, denied, unreadable, rateLimited, failed(String)
}

/// A sign-in as read, without its token: what the reader decides on. The app reads it and keeps the token itself; here it
/// is known by `key`, a short hash the app makes of it (two reads of one token have one key).
public enum SignInRead: Equatable {
    case token(key: String, expiresAt: Date?, plan: String?)
    /// No sign-in item for the folder.
    case notFound
    /// The read was refused or timed out.
    case denied
    /// An item is there, but its text isn't a sign-in in a known form.
    case unreadable

    /// The state a read that gave no token puts the profile in.
    public var failure: FetchState {
        switch self {
        case .denied: return .denied
        case .unreadable: return .unreadable
        default: return .noLogin
        }
    }

    /// No item, or one in an unknown form: a sign-in may be on its way (looked for again soon).
    public var waits: Bool {
        switch self {
        case .notFound, .unreadable: return true
        default: return false
        }
    }
}

/// The plan's two windows that hold the whole account back.
public enum UsageWindow: Hashable { case fiveHour, week }

/// One answer about the usage, as its source gave it (its scale, the windows it named).
public struct UsageAnswer: Equatable {
    /// Where numbers come from. The usage endpoint and a status line file give percents (0–100), a rate-limit event a
    /// fraction (0–1) (`ReadingRules.fractionSources`).
    public enum Source: Hashable { case usageEndpoint, statusLine, rateLimitEvent }
    public var source: Source
    /// The numbers, in the source's scale; nil: the answer gave none (`rate_limits: null`).
    public var usage: Usage?
    /// The windows the answer named (a window named is taken whole, its reset included).
    public var given: Set<UsageWindow>

    public init(source: Source, usage: Usage?, given: Set<UsageWindow>) { self.source = source; self.usage = usage; self.given = given }

    /// An answer whose windows are the ones it has a percent for.
    public init(source: Source, usage: Usage) {
        var given: Set<UsageWindow> = []
        if usage.fiveHour != nil { given.insert(.fiveHour) }
        if usage.weekly != nil { given.insert(.week) }
        self.init(source: source, usage: usage, given: given)
    }
}

/// The account refused (a limit reached): until when, when it was said, and which window refused it.
public struct Refusal: Equatable {
    /// The window that refused: the 5-hour one, the week, or not said.
    public enum On: Equatable { case fiveHour, week, unknown }
    public var until: Date?
    public var at: Date
    public var on: On

    public init(until: Date?, at: Date, on: On) { self.until = until; self.at = at; self.on = on }
}

/// A rate-limit event from a running claude (cl_quick reads them; cl_audit doesn't): one window, its use as a fraction, its
/// reset, and whether the account is allowed now.
public struct RateLimitEvent: Equatable {
    /// The window named: the plan's two, a model's or a spend window (which hold back only that model or that spend), or
    /// none named.
    public enum Window: Equatable {
        case fiveHour, week, scoped(String), unnamed

        /// From the event's own name: "five_hour", "seven_day" (the week, and only it), anything else a model's or a
        /// spend window ("seven_day_opus", "overage"); no name: unnamed.
        public static func named(_ name: String?) -> Window {
            switch name {
            case nil: return .unnamed
            case "five_hour"?: return .fiveHour
            case "seven_day"?: return .week
            case let other?: return .scoped(other)
            }
        }

        /// The window a refusal is on, or nil for one that never sets or lifts a refusal (a model's, a spend's).
        public var refusal: Refusal.On? {
            switch self {
            case .fiveHour: return .fiveHour
            case .week: return .week
            case .unnamed: return .unknown
            case .scoped: return nil
            }
        }
    }
    public enum Status: Equatable { case allowed, warning, rejected }

    public var window: Window
    public var utilization: Double?
    public var resetsAt: Date?
    public var status: Status

    public init(window: Window, utilization: Double?, resetsAt: Date?, status: Status) {
        self.window = window; self.utilization = utilization; self.resetsAt = resetsAt; self.status = status
    }
}

/// A message that says a limit was reached, as the app read its words: whether the message is an error, its model, the
/// window and the time it named.
public struct LimitMessage: Equatable {
    public var isError: Bool
    public var model: String?
    public var on: Refusal.On
    public var until: Date?

    public init(isError: Bool, model: String?, on: Refusal.On, until: Date?) {
        self.isError = isError; self.model = model; self.on = on; self.until = until
    }
}

/// The reading rules, each a parameter: cl_audit's set (`clAudit`, its behaviour as it always was) and cl_quick's
/// (`clQuick`, Core/README.md).
public struct ReadingRules: Equatable {
    /// What an answer that leaves windows out does: `replace` (the answer is the numbers, cl_audit's usage endpoint), or
    /// `keepLast` (a window not named keeps its last numbers; the read time moves on only when the answer named every
    /// window the last numbers had; an empty answer changes nothing).
    public enum Partial: Equatable { case replace, keepLast }
    /// Which window is the week in the usage endpoint's `limits[]` list: any kind naming "seven" or "week" (cl_audit's
    /// parser), or `seven_day` only (a model's or a spend window is never the week).
    public enum Week: Equatable { case sevenDayOrWeekly, sevenDayOnly }
    /// When a message's own text may say a limit (and "Prompt is too long"): never, or only when the message is an error or
    /// its model is "<synthetic>".
    public enum MessageText: Equatable { case never, errorOrSynthetic }
    /// Refusals kept as state: the usage endpoint lifts one only when it was said at least `liftAfter` ago and the answer
    /// names the window that refused, not full; a rate-limit event "allowed" lifts it at once. A model's or a spend
    /// window neither sets nor lifts one.
    public struct Refusals: Equatable {
        public var liftAfter: TimeInterval
        public init(liftAfter: TimeInterval) { self.liftAfter = liftAfter }
    }

    public var fractionSources: Set<UsageAnswer.Source>
    public var partial: Partial
    public var week: Week
    /// nil: no refusal is kept (cl_audit: full is 100% in the numbers, nothing else).
    public var refusals: Refusals?
    public var messageText: MessageText

    public init(fractionSources: Set<UsageAnswer.Source> = [.rateLimitEvent], partial: Partial, week: Week, refusals: Refusals?,
                messageText: MessageText) {
        self.fractionSources = fractionSources; self.partial = partial; self.week = week; self.refusals = refusals
        self.messageText = messageText
    }

    /// cl_audit's: each answer replaces the numbers, the week as its parser always took it, no refusals, no message text.
    public static let clAudit = ReadingRules(partial: .replace, week: .sevenDayOrWeekly, refusals: nil, messageText: .never)
    /// cl_quick's: partial answers keep the last numbers, the week is seven_day only, refusals with the 5-minute lift rule,
    /// limit words only from an error or a "<synthetic>" message.
    public static let clQuick = ReadingRules(partial: .keepLast, week: .sevenDayOnly, refusals: Refusals(liftAfter: 5 * 60),
                                             messageText: .errorOrSynthetic)

    /// Whether a message's text may be read for a limit (or "Prompt is too long").
    public func readsMessage(isError: Bool, model: String?) -> Bool {
        switch messageText {
        case .never: return false
        case .errorOrSynthetic: return isError || model == "<synthetic>"
        }
    }

    /// The answer's numbers in percent (0–100), whatever its source's scale.
    public func percents(_ a: UsageAnswer) -> Usage? {
        guard var u = a.usage else { return nil }
        guard fractionSources.contains(a.source) else { return u }
        u.fiveHour = u.fiveHour.map { $0 * 100 }
        u.weekly = u.weekly.map { $0 * 100 }
        u.scoped = u.scoped.map { ScopedLimit(name: $0.name, percent: $0.percent.map { $0 * 100 }, resets: $0.resets) }
        return u
    }

    /// The numbers after an answer, from the last ones (`partial`); nil: nothing to take (the last ones stay as they are).
    public func take(_ a: UsageAnswer, last: Usage?) -> Usage? {
        guard let u = percents(a) else { return nil }
        guard partial == .keepLast, let last else { return u }
        var out = last
        if a.given.contains(.fiveHour) { out.fiveHour = u.fiveHour; out.fiveHourResets = u.fiveHourResets }
        if a.given.contains(.week) { out.weekly = u.weekly; out.weeklyResets = u.weeklyResets }
        if !u.scoped.isEmpty { out.scoped = u.scoped }
        if let c = u.credits { out.credits = c }
        var had: Set<UsageWindow> = []
        if last.fiveHour != nil { had.insert(.fiveHour) }
        if last.weekly != nil { had.insert(.week) }
        if had.isSubset(of: a.given) { out.fetchedAt = u.fetchedAt; out.source = u.source }
        return out
    }

    /// Whether an answer from the usage endpoint lifts a refusal said `r.at`: long enough ago, and it names the window that
    /// refused (for one not said, the windows it names), none of them full.
    public func lifts(_ r: Refusal, with a: UsageAnswer, numbers u: Usage, now: Date) -> Bool {
        guard let rule = refusals, now.timeIntervalSince(r.at) >= rule.liftAfter else { return false }
        func room(_ w: UsageWindow) -> Bool {
            guard a.given.contains(w) else { return false }
            let p = w == .fiveHour ? u.fiveHour : u.weekly
            return p != nil && !AtLimit.isFull(p)
        }
        switch r.on {
        case .fiveHour: return room(.fiveHour)
        case .week: return room(.week)
        case .unknown: return !a.given.isEmpty && a.given.allSatisfy(room)
        }
    }
}
