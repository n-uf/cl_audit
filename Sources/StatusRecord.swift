// The status record: what the agent last saw for a profile, status/<profile>.json, and its one codec. Every reader and
// writer of that JSON goes through `StatusCodec` (the agent's reader, Store's reads and writes, the widget): one shape, the
// one the agent has always written (sorted keys, dates as seconds since 1970). Older Dock icons read a newer file during an
// update, so the shape only ever gains fields (optional ones, left out when empty); a file from before a field decodes with
// it empty.
//
// What the profile's headline surfaces may show of a record is ProfileCore's Headline; `shown(_:)` applies its answer.
//
// Foundation and ProfileCore only, with no paths: the widget (an app extension) compiles this file too (build.sh). Where the
// files are is the caller's (Store in the app, AgentFiles in the widget).

import Foundation
import ProfileCore

/// What the agent last saw for a profile, for its Dock icon and the cl_audit window. No secrets.
struct IconStatus: Codable {
    var loginEmail: String?
    var expectedEmail: String?
    var state: String
    var fiveHour: Double?
    var weekly: Double?
    var updatedAt: Date?
    var renewNote: String?
    var fiveHourResets: Date?
    var weeklyResets: Date?
    var plan: String?
    var source: String? = nil          // where the numbers came from ("Anthropic", "Claude Code status line")
    var problem: String? = nil         // why it couldn't update, in words
    var renewing: Bool? = nil          // renewing the sign-in through Claude Code now
    var scoped: [ScopedLimit]? = nil   // a model's own weekly limit (Fable)
    var credits: Credits? = nil        // usage credits
    var noFiveHour: Bool? = nil        // the plan has no 5-hour limit (Ultra): its 5-hour row is left out
    /// The one answer about the profile's account (AccountResolver), written by the agent: every surface shows this.
    var resolved: ResolvedAccount? = nil
    /// The account these numbers were read for, from that very reading (the token's own profile, looked up for the token
    /// the numbers were read with); nil when the reading doesn't say (the status line file) or before it's known.
    var numbersOwner: String? = nil
    /// The numbers' account couldn't be confirmed (the token's lookup keeps failing): shown as read, with their age, but
    /// never full, alerted, offering a switch or deciding the split (Store.status(for:)).
    var ownerUnconfirmed: Bool? = nil

    /// The reading's own account, for answering the record again (Settings) and for checking the record's label:
    /// `numbersOwner`, else the sign-in's own address (the token's profile; a record from before `numbersOwner`, or the
    /// status line's numbers, which name none).
    var readingOwner: String? { numbersOwner ?? loginEmail }

    /// The account these numbers were read for: the sign-in's address, else the one its folder names.
    var readFor: String? { (loginEmail ?? expectedEmail).map { $0.lowercased() } }

    /// Read for another account than `email`'s (both known): the numbers are that other account's.
    func readForAnother(than email: String?) -> Bool {
        guard let want = email?.lowercased(), !want.isEmpty, let got = readFor, !got.isEmpty else { return false }
        return got != want
    }

    /// For `email`'s account only. Numbers read for another account (the one a profile was on before a switch, say)
    /// are dropped, so one account's limits never show under another's name; the state and any problem stay.
    func only(for email: String?) -> IconStatus {
        guard readForAnother(than: email) else { return self }
        var s = self
        s.fiveHour = nil; s.weekly = nil; s.fiveHourResets = nil; s.weeklyResets = nil
        s.scoped = nil; s.credits = nil; s.plan = nil; s.updatedAt = nil
        return s
    }

    /// No numbers at all (the state, the problem and the account answer stay).
    mutating func dropNumbers() {
        fiveHour = nil; weekly = nil; fiveHourResets = nil; weeklyResets = nil
        scoped = nil; credits = nil
    }

    /// Claude Code's folder on another profile's account in use (a clash): the numbers and the plan are that profile's
    /// account's, so the record keeps none of them (every reader of it, the widget too, shows none); `line` says why.
    mutating func dropForClash(_ line: String?) {
        dropNumbers(); noFiveHour = nil; plan = nil
        problem = line
    }

    /// The sign-in needs the person: another account than the folder names, run out, or none. Every surface then shows
    /// one key, Sign in… (the card's needsLogin, the Dock menu's and the menu bar's).
    var needsLogin: Bool { mismatch || state == "expired" || state == "noLogin" }

    /// The sign-in is on another account than the folder names (both addresses known, any case).
    var mismatch: Bool { loginEmail.flatMap { a in expectedEmail.map { a.lowercased() != $0.lowercased() } } ?? false }

    /// Signed in: not expired and not signed out (an expired sign-in, or none, shows no numbers at all).
    var signedIn: Bool { state != "expired" && state != "noLogin" }

    /// The card's words for it, which quick chat's line says too: "sign-in expired", or nil when the sign-in is fine.
    var loginWords: String? {
        guard needsLogin else { return nil }
        return state == "expired" ? "sign-in expired" : state == "noLogin" ? "no Claude Code sign-in" : "sign-in is a different account"
    }

    /// What may be shown of the record now, the same rule wherever saved numbers are written, read or merged:
    /// - a limit whose reset time has passed has no percent and no reset (never a number "in 0 min": Freshness.current);
    /// - an expired sign-in, or none (signed out), shows no numbers at all, even ones read a moment ago: no bars, never
    ///   old numbers; they come back with the next good read (state ok).
    /// When they were read (`updatedAt`) stays, for "last read" lines.
    func current(now: Date = Date()) -> IconStatus {
        var s = self
        (s.fiveHour, s.fiveHourResets) = Freshness.current(s.fiveHour, resets: s.fiveHourResets, now: now)
        (s.weekly, s.weeklyResets) = Freshness.current(s.weekly, resets: s.weeklyResets, now: now)
        s.scoped = s.scoped.map { $0.map { $0.current(now: now) } }
        if !s.signedIn { s.dropNumbers() }
        return s
    }

    // MARK: the headline (ProfileCore's Headline)

    /// Whose the numbers are, as the record says it: the account in use is the Claude app's (only when the resolver took
    /// it from the app), the sign-in's is Claude Code's, and the resolver's own comparison of the two (`differs`, made as
    /// the agent read) decides the split.
    var owner: Headline.Owner {
        let reading = readingOwner.map { AccountIdentity(account: nil, email: $0, organization: nil, source: .verified) }
        guard let r = resolved else { return Headline.Owner(reading: reading, unconfirmed: ownerUnconfirmed == true) }
        return r.owner(reading: reading, unconfirmed: ownerUnconfirmed == true)
    }

    /// The headline's answer for this record: `ages` are the profile's (Store.ages in the app).
    func headline(now: Date = Date(), ages: Headline.Ages) -> Headline.Answer {
        Headline.of(owner, signedIn: signedIn, readAt: updatedAt, now: now, ages: ages)
    }

    /// The record with only what the headline answer lets show. `split` false: Claude Code's own numbers in the split (its
    /// labelled line), every other rule the same.
    func shown(_ a: Headline.Answer, split: Bool = true, now: Date = Date()) -> IconStatus {
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

/// What the resolver decided, as written into the profile's status record (AccountResolver.resolve).
struct ResolvedAccount: Codable, Equatable {
    var account: String?            // the active account's id (lower case); nil: none known
    var email: String?              // its address, where one is known on this Mac
    var fromApp: Bool               // the Claude app's sign-in decided it
    var numbersFor: String?         // the account the numbers were read for (Claude Code's): its address, or "account <8>"
    var differs: Bool               // the numbers aren't the active account's
    var line: String?               // the one line of state, or nil
    var lit: Bool                   // the green lamp: an account is in use and its numbers may show
    var clash: String?              // another profile's name: Claude Code's folder is on its account in use
    var at: Date
    /// Claude Code's .claude.json is too large to read: its account isn't known (said so, never "signed out").
    var recordTooLarge: Bool? = nil
    /// Claude Code's folder account's id (lower case), where known: the lists match its own row by it before its address.
    var codeAccount: String? = nil
    /// Claude Code's account as its rows and lines name it: the folder's address (else the numbers', else "account <8>").
    /// `numbersFor` is only ever the reading's own account; this one is for naming.
    var codeName: String? = nil
    /// The folder has signed in to another account since the numbers were read: they are that reading's, not Claude
    /// Code's now, and no surface shows them (Store.status(for:)) until a read for the new account.
    var readStale: Bool? = nil
    /// The split is a switch waiting for the Claude app: the profile's newest switch went to Claude Code's account, it is
    /// still open or linked (not undone, not left as it is), and the app is still on the account it left. Then the line
    /// asks for the app's sign-in and there is no key to log Claude Code back in (SplitUsage.switched).
    var switchWaits: Bool? = nil
    /// The id of the profile `clash` names (names needn't be unique: this one says which); nil in a record from before it.
    var clashID: String? = nil
    /// Claude Code's folder account's organisation id (lower case), with `codeAccount`: one seat (a login's personal and
    /// Team seats are two). nil: none recorded, or a record from before it.
    var codeOrganization: String? = nil

    /// Whose the numbers are (ProfileCore's Headline.Owner): the app's account in use, when the app decided it; Claude
    /// Code's account (its name, else the numbers'); the label `numbersFor` when it is an address; `reading`: the
    /// reading's own account.
    func owner(reading: AccountIdentity?, unconfirmed: Bool) -> Headline.Owner {
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

/// cl_audit's thresholds for how old a profile's numbers are (Core/README.md), the one formula the app (Store.ages) and the
/// widget use, from the profile's read interval in minutes.
enum StatusAges {
    /// How old numbers may be and still act (a full limit is full): the read interval, 5 minutes at least, plus a minute for
    /// the read itself (6 minutes by default).
    static func freshFor(pollMinutes: Int) -> TimeInterval { TimeInterval(max(pollMinutes, 5) * 60 + 60) }
    /// Older than this, numbers are drawn grey: three missed reads, 30 minutes at least (the Dock icon's rule, now everyone's).
    static func greyAfter(pollMinutes: Int) -> TimeInterval { max(TimeInterval(max(pollMinutes, 1) * 60 * 3), 30 * 60) }
    /// The headline's and the display's thresholds: never hidden by age; a last-known full limit is left out.
    static func of(pollMinutes: Int) -> Headline.Ages {
        Headline.Ages(freshFor: freshFor(pollMinutes: pollMinutes), hiddenAfter: nil, datedFullStays: false,
                      greyAfter: greyAfter(pollMinutes: pollMinutes))
    }
}

/// The one reader and writer of status/<profile>.json's bytes.
enum StatusCodec {
    /// The record in a file's bytes, or nil when they aren't one. Keys it doesn't know are skipped; keys it knows but the
    /// file lacks are empty.
    static func decode(_ data: Data) -> IconStatus? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(IconStatus.self, from: data)
    }

    /// The bytes for a record: sorted keys, dates as seconds since 1970, empty fields left out.
    static func encode(_ s: IconStatus) -> Data? {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = [.sortedKeys]
        return try? enc.encode(s)
    }
}
