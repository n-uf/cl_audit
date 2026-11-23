// ProfileCore · headline: whose numbers a profile's headline may show, and how (the profile's own line, its icon, its
// panel, a widget). One rule for every such place, pure: who the accounts are, the sign-in state, when the numbers were
// read, the clock and the thresholds in; a small answer out. The app keeps reading and writing its own record and its
// words; it asks here what of the record may show.
//
// The rules:
// - numbers read for another account than the one they are labelled for, or than the one the sign-in is on now (a stale
//   reading), are no one's here: none show, nor when they were read, nor the plan;
// - the split: the account in use (known apart from the numbers' own sign-in) is another account than the sign-in that
//   reads the numbers. Then they aren't the profile's: none show, nor the plan; the caller says the line;
// - an expired sign-in, or none, shows no numbers at all;
// - numbers whose account couldn't be confirmed show as read, but never full and never act;
// - by age (the caller's thresholds): fresh numbers act (a full limit is full: a full face, an offer, an alert); older ones
//   are only last known, where a full limit is left out, or (when the caller keeps dated fulls) shows as last known until
//   its known reset; older than `hiddenAfter`, none show, except (when the caller keeps dated fulls) a full limit whose
//   known reset is still ahead, as last known until that reset;
// - a limit whose reset has passed shows no percent and no reset (Freshness.current).
//
// Identity: two accounts are the same by their ids when both have one, else by address and organisation
// (AccountIdentity.matches). A caller whose own resolver already compared the account in use with the numbers' (and wrote
// its answer down with the numbers) passes that answer as `differs`.

import Foundation

public enum Headline {
    /// How the age of the numbers counts. Every value is the caller's (Core/README.md has each app's).
    public struct Ages: Equatable {
        /// Numbers up to this old are fresh: they act (a full limit counts as full).
        public var freshFor: TimeInterval
        /// Numbers older than this show not at all; nil: never hidden by age.
        public var hiddenAfter: TimeInterval?
        /// A last-known full limit whose reset is known and still ahead stays, as last known, until that reset
        /// (AtLimit.full in `.display` mode), however old the reading, past `hiddenAfter` too; false: a last-known full
        /// limit is left out.
        public var datedFullStays: Bool
        /// Numbers older than this are drawn grey (stale); nil, or a value below `freshFor`: as soon as they are only last
        /// known (older than `freshFor`). ProfileDisplay's tier; the answer itself doesn't use it.
        public var greyAfter: TimeInterval?

        public init(freshFor: TimeInterval, hiddenAfter: TimeInterval? = nil, datedFullStays: Bool = false, greyAfter: TimeInterval? = nil) {
            self.freshFor = freshFor; self.hiddenAfter = hiddenAfter; self.datedFullStays = datedFullStays; self.greyAfter = greyAfter
        }
    }

    /// Whose the numbers are, as far as the caller knows.
    public struct Owner: Equatable {
        /// The account in use, when something other than the numbers' own sign-in says which it is (another app's
        /// sign-in; the profile's own account); nil: the sign-in's account is the one in use.
        public var inUse: AccountIdentity?
        /// The account of the sign-in that reads the numbers.
        public var signIn: AccountIdentity?
        /// The account the reading itself was for, when it says.
        public var reading: AccountIdentity?
        /// The account a saved record names for the numbers, when it names one.
        public var label: AccountIdentity?
        /// `inUse` against `signIn`, when the caller's resolver already decided it; nil: compared here.
        public var differs: Bool?
        /// The sign-in is on an account another profile has in use: its numbers show there, never as a split here.
        public var elsewhere: Bool
        /// The split is a switch waiting for the other app's sign-in.
        public var switchWaits: Bool
        /// The sign-in moved to another account after the reading.
        public var readStale: Bool
        /// The reading's account couldn't be confirmed.
        public var unconfirmed: Bool

        public init(inUse: AccountIdentity? = nil, signIn: AccountIdentity? = nil, reading: AccountIdentity? = nil,
                    label: AccountIdentity? = nil, differs: Bool? = nil, elsewhere: Bool = false, switchWaits: Bool = false,
                    readStale: Bool = false, unconfirmed: Bool = false) {
            self.inUse = inUse; self.signIn = signIn; self.reading = reading; self.label = label; self.differs = differs
            self.elsewhere = elsewhere; self.switchWaits = switchWaits; self.readStale = readStale; self.unconfirmed = unconfirmed
        }
    }

    /// The split: the account in use isn't the one whose sign-in reads the numbers.
    public struct Split: Equatable {
        /// A switch to the sign-in's account waits for the other app's sign-in (no key to sign in again then).
        public var switchWaits: Bool
        public init(switchWaits: Bool) { self.switchWaits = switchWaits }
    }

    /// How old the numbers are, by the caller's thresholds.
    public enum Age: Equatable {
        case fresh, lastKnown, hidden
        /// No read time: as fresh (a full limit counts), since nothing says they are old.
        case undated
    }

    /// One limit as the headline shows it.
    public struct Limit: Equatable {
        public var percent: Double?
        public var resets: Date?
        /// Only last known: draw it so (a full one never acts).
        public var lastKnown: Bool
        public init(percent: Double?, resets: Date?, lastKnown: Bool) { self.percent = percent; self.resets = resets; self.lastKnown = lastKnown }
    }

    /// What the headline may show of a profile's numbers.
    public struct Answer: Equatable {
        /// Read for another account than the label's or the sign-in's now: no numbers, no read time, no plan.
        public var otherReading: Bool
        public var split: Split?
        public var unconfirmed: Bool
        public var signedIn: Bool
        public var age: Age
        public var datedFullStays: Bool

        public init(otherReading: Bool, split: Split?, unconfirmed: Bool, signedIn: Bool, age: Age, datedFullStays: Bool) {
            self.otherReading = otherReading; self.split = split; self.unconfirmed = unconfirmed; self.signedIn = signedIn
            self.age = age; self.datedFullStays = datedFullStays
        }

        /// Any numbers at all (`split` false: the sign-in's own numbers, for a line that names them as its).
        public func numbers(split: Bool = true) -> Bool {
            signedIn && !otherReading && !(split && self.split != nil) && age != .hidden
        }
        /// The plan may show (it is the reading's account's).
        public func plan(split: Bool = true) -> Bool { !otherReading && !(split && self.split != nil) }
        /// When the numbers were read may show.
        public var readTime: Bool { !otherReading }
        /// The numbers may act: a full limit is full (a full face, an offer, an alert).
        public var acts: Bool { !unconfirmed && (age == .fresh || age == .undated) }

        /// Past `hiddenAfter`, only a dated full limit may still show (the caller keeps dated fulls): `numbers()` is false,
        /// and `limit` gives only such a full limit, as last known.
        public func datedFullOnly(split: Bool = true) -> Bool {
            age == .hidden && datedFullStays && signedIn && !otherReading && !(split && self.split != nil)
        }

        /// One limit as read (`readAt`: when), as it may show: nil when it shows not at all.
        public func limit(_ percent: Double?, resets: Date?, readAt: Date?, split: Bool = true, now: Date) -> Limit? {
            let c = Freshness.current(percent, resets: resets, now: now)
            // past `hiddenAfter`, a caller that keeps dated fulls still sees a full limit whose known reset is ahead, as
            // last known, however old the reading: until that reset it is still full
            if datedFullOnly(split: split) {
                guard AtLimit.full(c.percent, resets: c.resets, readAt: readAt, mode: .display, now: now) else { return nil }
                return Limit(percent: c.percent, resets: c.resets, lastKnown: true)
            }
            guard numbers(split: split) else { return nil }
            // a full limit that may not act: left out, or (a caller that keeps dated fulls) kept as last known while its
            // known reset is ahead; a dateless one only last known (before hiddenAfter), with no reset to say
            let heldFull = AtLimit.isFull(c.percent) && !acts
            if heldFull {
                guard datedFullStays else { return nil }
                if AtLimit.full(c.percent, resets: c.resets, readAt: readAt, mode: .display, now: now) {
                    return Limit(percent: c.percent, resets: c.resets, lastKnown: true)
                }
                guard c.resets == nil, age == .lastKnown else { return nil }
                return Limit(percent: c.percent, resets: nil, lastKnown: true)
            }
            return Limit(percent: c.percent, resets: c.resets, lastKnown: age == .lastKnown || heldFull)
        }
    }

    /// The split, or nil: the account in use is known apart from the sign-in and isn't its account (the caller's
    /// `differs` when given, else by AccountIdentity.matches); never while the numbers' account isn't confirmed, nor when
    /// the sign-in's account is another profile's in use.
    public static func split(_ o: Owner) -> Split? {
        guard !o.unconfirmed, !o.elsewhere, let use = o.inUse, let sign = o.signIn else { return nil }
        return (o.differs ?? !use.matches(sign)) ? Split(switchWaits: o.switchWaits) : nil
    }

    /// The numbers are read for another account than the one they are labelled for, or the sign-in has moved on since.
    public static func otherReading(_ o: Owner) -> Bool {
        if o.readStale { return true }
        guard let l = o.label, let r = o.reading else { return false }
        return !l.matches(r)
    }

    /// How old numbers read at `readAt` are now.
    public static func age(_ readAt: Date?, now: Date, ages: Ages) -> Age {
        guard let at = readAt else { return .undated }
        let age = now.timeIntervalSince(at)
        if let h = ages.hiddenAfter, age > h { return .hidden }
        return age > ages.freshFor ? .lastKnown : .fresh
    }

    /// The answer for one profile's numbers.
    public static func of(_ o: Owner, signedIn: Bool, readAt: Date?, now: Date, ages: Ages) -> Answer {
        let other = otherReading(o)
        // (numbers no one's here have no read time either: their age decides nothing)
        return Answer(otherReading: other, split: split(o), unconfirmed: o.unconfirmed, signedIn: signedIn,
                      age: other ? .undated : age(readAt, now: now, ages: ages), datedFullStays: ages.datedFullStays)
    }
}
