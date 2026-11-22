// A profile's status record: what a reader last saw for a profile (its numbers, its sign-in state and the account answer),
// and its one codec. Every reader and writer of the record's bytes goes through `StatusCodec`: one shape (sorted keys,
// dates as seconds since 1970) that only ever gains fields (optional ones, left out when empty), so an older app reads a
// newer record during an update and a record from before a field decodes with it empty. Where records are kept, and the
// words for them, are the app's.
//
// What may be shown of a record is Headline's answer (`shown(_:)` applies it); `ProfileDisplay.of(_:)` turns a record into
// the one display value, and `StatusFace` the small picture's data from it.

import Foundation

/// What a reader last saw for a profile. No secrets.
public struct StatusRecord: Codable, Equatable {
    public var loginEmail: String?
    public var expectedEmail: String?
    public var state: String
    public var fiveHour: Double?
    public var weekly: Double?
    public var updatedAt: Date?
    public var renewNote: String?
    public var fiveHourResets: Date?
    public var weeklyResets: Date?
    public var plan: String?
    public var source: String? = nil          // where the numbers came from, in the reader's words
    public var problem: String? = nil         // why it couldn't update, in the reader's words
    public var renewing: Bool? = nil          // renewing the sign-in now
    public var scoped: [ScopedLimit]? = nil   // a model's own weekly limit
    public var credits: Credits? = nil        // usage credits
    public var noFiveHour: Bool? = nil        // the plan has no 5-hour limit: its 5-hour row is left out
    /// The one answer about the profile's account, written by the reader: every view of the profile shows this.
    public var resolved: ResolvedAccount? = nil
    /// The account these numbers were read for, from that very reading (the token's own profile, looked up for the token
    /// the numbers were read with); nil when the reading doesn't say (a status line file) or before it's known.
    public var numbersOwner: String? = nil
    /// That account's id, when the reading's lookup gave one (nil in a record from before it): the account answer compares
    /// it with Claude Code's folder account by the id, the one owner rule.
    public var numbersAccount: String? = nil
    /// That account's organisation id, when the lookup gave one: one login's personal and Team seats are told apart by it
    /// (nil: not known, never "none").
    public var numbersOrganization: String? = nil
    /// The numbers' account couldn't be confirmed (the token's lookup keeps failing): shown as read, with their age, but
    /// never full, alerted, offering a switch or deciding the split.
    public var ownerUnconfirmed: Bool? = nil

    public init(state: String) { self.state = state }

    /// The reading's own account: `numbersOwner`, else the sign-in's own address (a record from before `numbersOwner`, or a
    /// status line's numbers, which name none).
    public var readingOwner: String? { numbersOwner ?? loginEmail }
    /// `readingOwner`'s account id: only with `numbersOwner` (the sign-in's own address names no id here).
    public var readingAccount: String? { numbersOwner == nil ? nil : numbersAccount }
    /// `readingAccount`'s organisation id: only with it.
    public var readingOrganization: String? { readingAccount == nil ? nil : numbersOrganization }

    /// The account these numbers were read for: the sign-in's address, else the one its folder names.
    public var readFor: String? { (loginEmail ?? expectedEmail).map { $0.lowercased() } }

    /// Read for another account than `email`'s (both known): the numbers are that other account's.
    public func readForAnother(than email: String?) -> Bool {
        guard let want = email?.lowercased(), !want.isEmpty, let got = readFor, !got.isEmpty else { return false }
        return got != want
    }

    /// For `email`'s account only. Numbers read for another account (the one a profile was on before a switch, say) are
    /// dropped, so one account's limits never show under another's name; the state and any problem stay.
    public func only(for email: String?) -> StatusRecord {
        guard readForAnother(than: email) else { return self }
        var s = self
        s.fiveHour = nil; s.weekly = nil; s.fiveHourResets = nil; s.weeklyResets = nil
        s.scoped = nil; s.credits = nil; s.plan = nil; s.updatedAt = nil
        return s
    }

    /// No numbers at all (the state, the problem and the account answer stay).
    public mutating func dropNumbers() {
        fiveHour = nil; weekly = nil; fiveHourResets = nil; weeklyResets = nil
        scoped = nil; credits = nil
    }

    /// Claude Code's folder on another profile's account in use (a clash): the numbers and the plan are that profile's
    /// account's, so the record keeps none of them; `line` says why.
    public mutating func dropForClash(_ line: String?) {
        dropNumbers(); noFiveHour = nil; plan = nil
        problem = line
    }

    /// The sign-in needs the person: another account than the folder names, run out, or none.
    public var needsLogin: Bool { mismatch || state == "expired" || state == "noLogin" }

    /// The sign-in is on another account than the folder names (both addresses known, any case).
    public var mismatch: Bool { loginEmail.flatMap { a in expectedEmail.map { a.lowercased() != $0.lowercased() } } ?? false }

    /// Signed in: not expired and not signed out (an expired sign-in, or none, shows no numbers at all).
    public var signedIn: Bool { state != "expired" && state != "noLogin" }

    /// The sign-in as the display takes it.
    public var signIn: ProfileDisplay.SignIn {
        state == "expired" ? .expired : state == "noLogin" ? .signedOut : state == "denied" || state == "unreadable" ? .unreadable : .ok
    }

    /// An account is in use: the account answer's lamp, else (a record from before it) a sign-in the reading names.
    public var inUse: Bool { resolved?.lit ?? ((loginEmail ?? expectedEmail) != nil) }

    /// What may be shown of the record now, the same rule wherever saved numbers are written, read or merged:
    /// - a limit whose reset time has passed has no percent and no reset (Freshness.current);
    /// - an expired sign-in, or none, shows no numbers at all, even ones read a moment ago; they come back with the next
    ///   good read.
    /// When they were read (`updatedAt`) stays.
    public func current(now: Date = Date()) -> StatusRecord {
        var s = self
        (s.fiveHour, s.fiveHourResets) = Freshness.current(s.fiveHour, resets: s.fiveHourResets, now: now)
        (s.weekly, s.weeklyResets) = Freshness.current(s.weekly, resets: s.weeklyResets, now: now)
        s.scoped = s.scoped.map { $0.map { $0.current(now: now) } }
        if !s.signedIn { s.dropNumbers() }
        return s
    }

    /// The numbers the record carries, as a Usage (nil without any); `source` names where they came from when the record
    /// doesn't (the caller's words).
    public func usage(source: String) -> Usage? {
        guard let at = updatedAt, fiveHour != nil || weekly != nil else { return nil }
        return Usage(fiveHour: fiveHour, fiveHourResets: fiveHourResets, weekly: weekly, weeklyResets: weeklyResets,
                     fetchedAt: at, source: self.source ?? source, scoped: scoped ?? [], credits: credits,
                     noFiveHour: noFiveHour == true)
    }

    // MARK: the headline

    /// Whose the numbers are, as the record says it: the account in use is the Claude app's (only when the account answer
    /// took it from the app), the sign-in's is Claude Code's, and the answer's own comparison of the two (`differs`, made
    /// as the reader read) decides the split.
    public var owner: Headline.Owner {
        let reading = readingOwner.map { AccountIdentity(account: nil, email: $0, organization: nil, source: .verified) }
        guard let r = resolved else { return Headline.Owner(reading: reading, unconfirmed: ownerUnconfirmed == true) }
        return r.owner(reading: reading, unconfirmed: ownerUnconfirmed == true)
    }

    /// The headline's answer for this record, with the profile's `ages`.
    public func headline(now: Date = Date(), ages: Headline.Ages) -> Headline.Answer {
        Headline.of(owner, signedIn: signedIn, readAt: updatedAt, now: now, ages: ages)
    }

    /// The record with only what the headline answer lets show. `split` false: Claude Code's own numbers in the split (its
    /// labelled line), every other rule the same.
    public func shown(_ a: Headline.Answer, split: Bool = true, now: Date = Date()) -> StatusRecord {
        var out = self
        if !a.readTime { out.updatedAt = nil }
        if !a.plan(split: split) { out.plan = nil }
        guard a.numbers(split: split) else { out.dropNumbers(); return out }
        // each limit as the answer lets it show: none past its reset, none full unless the numbers may act
        func limit(_ p: Double?, _ resets: Date?) -> (Double?, Date?) {
            a.limit(p, resets: resets, readAt: updatedAt, split: split, now: now).map { ($0.percent, $0.resets) } ?? (nil, nil)
        }
        (out.fiveHour, out.fiveHourResets) = limit(fiveHour, fiveHourResets)
        (out.weekly, out.weeklyResets) = limit(weekly, weeklyResets)
        out.scoped = scoped.map { $0.map { l in let s = limit(l.percent, l.resets); return ScopedLimit(name: l.name, percent: s.0, resets: s.1) } }
        return out
    }
}

/// What the account answer decided, as written into the profile's status record.
public struct ResolvedAccount: Codable, Equatable {
    public var account: String?            // the active account's id (lower case); nil: none known
    public var email: String?              // its address, where one is known on this Mac
    public var fromApp: Bool               // the Claude app's sign-in decided it
    public var numbersFor: String?         // the account the numbers were read for (Claude Code's): its address, or "account <8>"
    public var differs: Bool               // the numbers aren't the active account's
    public var line: String?               // the one line of state, in the app's words, or nil
    public var lit: Bool                   // an account is in use and its numbers may show
    public var clash: String?              // another profile's name: Claude Code's folder is on its account in use
    public var at: Date
    /// Claude Code's .claude.json is too large to read: its account isn't known (said so, never "signed out").
    public var recordTooLarge: Bool? = nil
    /// Claude Code's folder account's id (lower case), where known.
    public var codeAccount: String? = nil
    /// Claude Code's account as its rows and lines name it: the folder's address (else the numbers', else "account <8>").
    /// `numbersFor` is only ever the reading's own account; this one is for naming.
    public var codeName: String? = nil
    /// The folder has signed in to another account since the numbers were read: they are that reading's, not Claude
    /// Code's now, and nothing shows them until a read for the new account.
    public var readStale: Bool? = nil
    /// The split is a switch waiting for the Claude app: the profile's newest switch went to Claude Code's account and the
    /// app is still on the account it left.
    public var switchWaits: Bool? = nil
    /// The id of the profile `clash` names (names needn't be unique: this one says which); nil in a record from before it.
    public var clashID: String? = nil
    /// Claude Code's folder account's organisation id (lower case), with `codeAccount`: one seat. "": the folder's record
    /// names the seat with no organisation; nil: not known.
    public var codeOrganization: String? = nil
    /// The one line is "Usage: Claude Code on <codeName>" (the numbers are another account's than the one in use). Only the
    /// fact is stored, not the sentence: the app builds it when it shows it (after `usageOnPrefix`), so the sentence follows
    /// whether addresses are hidden and the record never holds an address as text. A record from before it holds the sentence
    /// in `line`: `StatusCodec.drawable` turns it into this.
    public var codeUsageLine: Bool? = nil
    /// The one line is the split's sentence (the app can't read the account in use's usage: Claude Code's sign-in is on
    /// another account, or a switch waits for the Claude app). Set only on the value a view is shown (never written), and,
    /// like `codeUsageLine`, only the fact is kept: the app builds the sentence from the accounts the record names when it
    /// draws it, so no record holds a sentence with an address in it.
    public var splitLine: Bool? = nil

    /// The start of the sentence `codeUsageLine` stands for; an older record holds it whole in `line`.
    public static let usageOnPrefix = "Usage: Claude Code on "

    public init(account: String?, email: String?, fromApp: Bool, numbersFor: String?, differs: Bool, line: String?, lit: Bool,
                clash: String?, at: Date, recordTooLarge: Bool? = nil, codeAccount: String? = nil, codeName: String? = nil,
                readStale: Bool? = nil, switchWaits: Bool? = nil, clashID: String? = nil, codeOrganization: String? = nil) {
        self.account = account; self.email = email; self.fromApp = fromApp; self.numbersFor = numbersFor; self.differs = differs
        self.line = line; self.lit = lit; self.clash = clash; self.at = at; self.recordTooLarge = recordTooLarge
        self.codeAccount = codeAccount; self.codeName = codeName; self.readStale = readStale; self.switchWaits = switchWaits
        self.clashID = clashID; self.codeOrganization = codeOrganization
    }

    /// Whose the numbers are (Headline.Owner): the app's account in use, when the app decided it; Claude Code's account
    /// (its name, else the numbers'); the label `numbersFor` when it is an address; `reading`: the reading's own account.
    public func owner(reading: AccountIdentity?, unconfirmed: Bool) -> Headline.Owner {
        func identity(_ account: String?, _ name: String?) -> AccountIdentity {
            AccountIdentity(account: account, email: name.flatMap { $0.contains("@") ? $0 : nil }, organization: nil, source: .verified)
        }
        let label = numbersFor.flatMap { $0.contains("@") ? identity(nil, $0) : nil }
        return Headline.Owner(inUse: fromApp ? identity(account, email) : nil,
                              signIn: (codeName ?? numbersFor).map { identity(codeAccount, $0) }, reading: reading, label: label,
                              differs: differs, elsewhere: clash != nil, switchWaits: switchWaits == true,
                              readStale: readStale == true, unconfirmed: unconfirmed)
    }
}

/// How old a profile's numbers may be (Core/README.md), from its read interval in minutes: the one formula for every view.
public enum StatusAges {
    /// How old numbers may be and still act (a full limit is full): the read interval, 5 minutes at least, plus a minute for
    /// the read itself (6 minutes by default).
    public static func freshFor(pollMinutes: Int) -> TimeInterval { TimeInterval(max(minutes(pollMinutes), 5) * 60 + 60) }
    /// Older than this, numbers are drawn grey: three missed reads, 30 minutes at least.
    public static func greyAfter(pollMinutes: Int) -> TimeInterval { max(TimeInterval(minutes(pollMinutes) * 60 * 3), 30 * 60) }
    /// The read interval as the formula takes it: 1 minute to a day (a broken number never overflows).
    static func minutes(_ m: Int) -> Int { min(max(m, 1), 1440) }
    /// The headline's and the display's thresholds: never hidden by age; a last-known full limit is left out.
    public static func of(pollMinutes: Int) -> Headline.Ages {
        Headline.Ages(freshFor: freshFor(pollMinutes: pollMinutes), hiddenAfter: nil, datedFullStays: false,
                      greyAfter: greyAfter(pollMinutes: pollMinutes))
    }
}

/// The one reader and writer of a status record's bytes.
public enum StatusCodec {
    /// The record in a file's bytes, or nil when they aren't one. Keys it doesn't know are skipped; keys it knows but the
    /// bytes lack are empty. Only drawable numbers are kept (`drawable`).
    public static func decode(_ data: Data) -> StatusRecord? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode(StatusRecord.self, from: data)).map { drawable($0) }
    }

    /// The record with only numbers a view can draw: a percent outside 0–1,000 or a time more than 100 years from `now`
    /// is left out, as if not read. A broken or hostile record then never traps a view (a percent or a countdown made a
    /// whole number).
    public static func drawable(_ s: StatusRecord, now: Date = Date()) -> StatusRecord {
        func percent(_ p: Double?) -> Double? { p.flatMap { $0.isFinite && $0 >= 0 && $0 <= 1000 ? $0 : nil } }
        func time(_ d: Date?) -> Date? { d.flatMap { abs($0.timeIntervalSince(now)) < 100 * 365 * 86400 ? $0 : nil } }
        var s = s
        s.fiveHour = percent(s.fiveHour); s.weekly = percent(s.weekly)
        s.fiveHourResets = time(s.fiveHourResets); s.weeklyResets = time(s.weeklyResets); s.updatedAt = time(s.updatedAt)
        s.scoped = s.scoped?.map { ScopedLimit(name: $0.name, percent: percent($0.percent), resets: time($0.resets)) }
        s.resolved = s.resolved.map(migrated)
        return s
    }

    /// An older record holds "Usage: Claude Code on <account>" as text, an address in it as it was written: only the fact is
    /// kept, and the app builds the sentence when it shows it, so no address reaches a display value's note (with no name to
    /// build it from, the line is dropped: the reader writes the record again with its next read). `drawable` and
    /// `ProfileDisplay.of` both apply it, so a record that never went through the codec is migrated too.
    public static func migrated(_ r: ResolvedAccount) -> ResolvedAccount {
        guard r.line?.hasPrefix(ResolvedAccount.usageOnPrefix) == true else { return r }
        var m = r
        m.line = nil; m.codeUsageLine = r.codeName == nil ? nil : true
        return m
    }

    /// The bytes for a record: sorted keys, dates as seconds since 1970, empty fields left out.
    public static func encode(_ s: StatusRecord) -> Data? {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = [.sortedKeys]
        return try? enc.encode(s)
    }
}

extension ProfileDisplay {
    /// The one display value for a profile's record (nil: no record yet), with its `ages` (StatusAges) at `now`. `source`
    /// names where numbers came from when the record doesn't (the caller's words). A record from before the account answer
    /// has no line for an unconfirmed owner. `lineText` says the account answer's one line (the note) in the app's words: by
    /// default the record's own `line`; an app that builds the sentence from `codeUsageLine` or `splitLine` passes its builder,
    /// since the record holds the fact and never the sentence.
    public static func of(_ record: StatusRecord?, ages: Headline.Ages, source: String, now: Date = Date(),
                          lineText: (ResolvedAccount) -> String? = { $0.line }) -> ProfileDisplay {
        guard let raw = record?.current(now: now) else {
            return make(Headline.of(Headline.Owner(), signedIn: true, readAt: nil, now: now, ages: ages), read: nil,
                        sign: .ok, inUse: false, ages: ages, now: now)
        }
        let r = raw.resolved.map(StatusCodec.migrated)
        var d = make(raw.headline(now: now, ages: ages), read: raw.usage(source: source), sign: raw.signIn,
                     otherAccount: raw.mismatch, inUse: raw.inUse, clash: r?.clash.map { Clash(id: r?.clashID, name: $0) },
                     note: r.flatMap(lineText), splitTo: r?.email.flatMap { $0.contains("@") ? $0 : nil }, ages: ages, now: now)
        if r == nil, d.line == .unconfirmed { d.line = nil }
        return d
    }
}
