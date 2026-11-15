// ProfileCore · display: one "what to show" value per profile, derived once from what the caller read (the numbers, the
// sign-in's state, the account in use) and the headline's answer. Every place that draws a profile's headline (its icon,
// its menu, its panels) draws this value and decides nothing itself: the numbers or why there are none, how old they are
// (fresh, last known, grey), the full limit that holds the profile back, the lamp, the one key, the line of state and the
// profile whose account it clashes with. Pure: the clock and the thresholds are parameters, and no words: each app says
// the value in its own.
//
// The rules (the headline's, Headline.swift, plus):
// - the tiers: fresh numbers act; older than `Ages.freshFor` they are last known (a full limit may not act); older than
//   `Ages.greyAfter` (when given, else at once) they are drawn grey. A `greyAfter` below `freshFor` counts as `freshFor`
//   (grey as soon as last known, never while fresh). No read time counts as fresh;
// - full: only numbers that act have a full limit (AtLimit.blocker over what may show);
// - the lamp (the account in use, and nothing in the way): lit for a known account in use, unless its sign-in needs the
//   person or can't be read, or the sign-in is on another profile's account; in the split the lamp is the account in
//   use's (lit: the sign-in that reads the numbers is the other account's matter);
// - the one key: log in when the sign-in is on another account than the folder's or on another profile's account in use
//   (the clash: the caller fills in the profile's own account, never the folder's), ran out or is gone; else, in the split,
//   log the sign-in in to the account in use (only when its address is known, and never while a switch waits for the
//   other app); else none;
// - the line: numbers whose account couldn't be confirmed say so first, then the split, then the caller's own line.

import Foundation

public struct ProfileDisplay: Equatable {
    /// The sign-in that reads the numbers.
    public enum SignIn: Equatable {
        case ok
        case expired
        case signedOut
        /// Signed in, but the sign-in can't be read (refused, or in a form not known).
        case unreadable
    }

    /// Why no numbers show.
    public enum NoNumbers: Equatable {
        /// Nothing read yet, or nothing left (every limit's reset has passed).
        case notRead
        case expired, signedOut
        /// Read for another account than the one they are labelled for, or the sign-in moved on since.
        case otherReading
        /// The split: the numbers are the sign-in's, not the account in use's.
        case split
        /// Older than the caller hides.
        case hidden
    }

    /// How old the numbers are, for drawing them.
    public enum Tier: Equatable {
        /// They act (a full limit is full).
        case fresh
        /// Only last known: drawn as usual, but a full limit may not act.
        case lastKnown
        /// Old: drawn grey.
        case stale
    }

    /// The one key the profile's sign-in needs.
    public enum Key: Equatable {
        /// Log in again (the profile's own account: the folder's, or in a clash the one the profile has in use).
        case logIn
        /// The split: log the sign-in in to the account in use, this address filled in.
        case logInCode(to: String)
    }

    /// The one line of state.
    public enum Line: Equatable {
        /// The numbers' account couldn't be confirmed.
        case unconfirmed
        case split(Headline.Split)
        /// The caller's own line, carried as given.
        case given(String)
    }

    /// Another profile has the sign-in's account in use: that profile has the numbers.
    public struct Clash: Equatable {
        /// That profile's id; nil when the caller's record doesn't name it (then only its name is known).
        public var id: String?
        public var name: String
        public init(id: String?, name: String) { self.id = id; self.name = name }
    }

    /// The numbers as they may show (each limit by the headline's answer), or nil: none (`none` says why).
    public var usage: Usage?
    public var none: NoNumbers?
    /// When the numbers were read, when that may show.
    public var readAt: Date?
    public var tier: Tier
    /// The full limit that holds the profile back now (only numbers that act), or nil.
    public var full: FullLimit?
    public var lamp: Bool
    public var key: Key?
    public var line: Line?
    public var clash: Clash?
    public var split: Headline.Split?
    public var sign: SignIn
    /// The sign-in is on another account than the folder names.
    public var otherAccount: Bool

    public init(usage: Usage?, none: NoNumbers?, readAt: Date?, tier: Tier, full: FullLimit?, lamp: Bool, key: Key?, line: Line?,
                clash: Clash?, split: Headline.Split?, sign: SignIn, otherAccount: Bool) {
        self.usage = usage; self.none = none; self.readAt = readAt; self.tier = tier; self.full = full; self.lamp = lamp
        self.key = key; self.line = line; self.clash = clash; self.split = split; self.sign = sign; self.otherAccount = otherAccount
    }

    /// The full limit that holds the profile back at `now`, the moment it is drawn: `full` until its reset passes (a value
    /// made a little earlier never counts down past the reset).
    public func full(now: Date) -> FullLimit? { full.flatMap { Freshness.passed($0.resets, now: now) ? nil : $0 } }

    /// Drawn grey: old numbers, or none at all.
    public var grey: Bool { tier == .stale || usage == nil }
    /// A limit's colour level, grey for old numbers.
    public func level(_ p: Double?) -> Level { Level.of(p, stale: tier == .stale) }
    /// The key is Log in (the sign-in needs the person).
    public var needsLogin: Bool { key == .logIn }

    /// The value for one profile. `answer`: the headline's (Headline.of) for the same reading; `read`: the numbers as read
    /// (nil: none, or no read time); `sign`: the state of the sign-in that reads them; `otherAccount`: that sign-in is on
    /// another account than the folder names; `inUse`: an account in use is known; `note`: the caller's own line;
    /// `splitTo`: the account in use's address, for the split's key; `ages`: the same thresholds the answer was made with.
    public static func make(_ answer: Headline.Answer, read: Usage?, sign: SignIn, otherAccount: Bool = false, inUse: Bool,
                            clash: Clash? = nil, note: String? = nil, splitTo: String? = nil, ages: Headline.Ages,
                            now: Date = Date()) -> ProfileDisplay {
        let readAt = answer.readTime ? read?.fetchedAt : nil
        // the numbers: each limit as the answer lets it show
        var usage: Usage? = nil
        if answer.numbers(), var u = read {
            func limit(_ p: Double?, _ resets: Date?) -> (Double?, Date?) {
                answer.limit(p, resets: resets, readAt: u.fetchedAt, now: now).map { ($0.percent, $0.resets) } ?? (nil, nil)
            }
            (u.fiveHour, u.fiveHourResets) = limit(u.fiveHour, u.fiveHourResets)
            (u.weekly, u.weeklyResets) = limit(u.weekly, u.weeklyResets)
            u.scoped = u.scoped.map { l in let s = limit(l.percent, l.resets); return ScopedLimit(name: l.name, percent: s.0, resets: s.1) }
            if u.fiveHour != nil || u.weekly != nil { usage = u }
        }
        let none: NoNumbers? = usage != nil ? nil
            : !answer.signedIn ? (sign == .expired ? .expired : .signedOut)
            : answer.otherReading ? .otherReading
            : answer.split != nil ? .split
            : answer.age == .hidden ? .hidden
            : .notRead
        // the tier: fresh while they act by age; grey past `greyAfter` (else as soon as last known)
        let tier: Tier
        switch answer.age {
        case .fresh, .undated: tier = .fresh
        case .hidden: tier = .stale
        case .lastKnown:
            // (greyAfter clamped to freshFor: below it, grey as soon as last known)
            let old = readAt.map { now.timeIntervalSince($0) > max(ages.greyAfter ?? ages.freshFor, ages.freshFor) } ?? false
            tier = old ? .stale : .lastKnown
        }
        let full = answer.acts ? usage.flatMap { u in
            AtLimit.blocker(fiveHour: u.fiveHour, fiveHourResets: u.fiveHourResets, weekly: u.weekly, weeklyResets: u.weeklyResets, now: now)
        } : nil
        let lamp = inUse && (answer.split != nil || (clash == nil && sign == .ok && !otherAccount))
        let key: Key? = otherAccount || clash != nil || sign == .expired || sign == .signedOut ? .logIn
            : answer.split.flatMap { s in s.switchWaits ? nil : splitTo.map { Key.logInCode(to: $0) } }
        let line: Line? = answer.unconfirmed ? .unconfirmed : answer.split.map { Line.split($0) } ?? note.map { Line.given($0) }
        return ProfileDisplay(usage: usage, none: none, readAt: readAt, tier: tier, full: full, lamp: lamp, key: key, line: line,
                              clash: clash, split: answer.split, sign: sign, otherAccount: otherAccount)
    }
}
