// A profile as its headline surfaces show it (ProfileCore step 3a: the menu bar icon with its row and menu, the Dock icon
// with its face, its menu and its panel; step 3b: the dashboard card and the palette's row): ProfileCore's one "what to
// show" value (ProfileDisplay), made once from the profile's status record, and cl_audit's words for it. The surfaces draw
// this and decide nothing themselves: not whether the numbers show, how old they are, what is full, the lamp, the key, the
// line or the split.

import Foundation
import ProfileCore

struct ProfileShow {
    let entry: AccountEntry
    /// The one value.
    let display: ProfileDisplay
    /// The record as the headline surfaces read it (Store.status(for:)): its plan, problem, renew note and addresses.
    let record: StatusRecord?
    /// The account's names: the active account for the account line, and the standby lists without it.
    let view: AccountView
    /// The split's words (SplitUsage), only while the display says the split.
    let splitWords: SplitUsage?

    /// The value for `raw`, the record as read (Store.status(_:)), at `now`.
    static func of(_ e: AccountEntry, raw read: StatusRecord?, now: Date = Date()) -> ProfileShow {
        let raw = read?.current(now: now)
        let ages = Store.ages(e, resolved: raw?.resolved)       // (in the split, Terminal's numbers only when the record names them)               // (Store.status(_:) has done it already; once more changes nothing)
        let shown = raw.map { Store.shown($0, for: e, now: now) }
        guard let raw else {
            let d = ProfileDisplay.make(Headline.of(Headline.Owner(), signedIn: true, readAt: nil, now: now, ages: ages), read: nil,
                                        sign: .ok, inUse: false, ages: ages, now: now)
            return ProfileShow(entry: e, display: d, record: nil, view: AccountView.of(nil), splitWords: nil)
        }
        let sign: ProfileDisplay.SignIn = raw.state == "expired" ? .expired : raw.state == "noLogin" ? .signedOut
            : raw.state == "denied" || raw.state == "unreadable" ? .unreadable : .ok
        let view = AccountView.of(shown)
        let r = raw.resolved
        var d = ProfileDisplay.make(raw.headline(now: now, ages: ages), read: Usage.of(raw), sign: sign, otherAccount: raw.mismatch,
                                    inUse: view.lit, note: r?.lineText(), splitTo: r?.email.flatMap { $0.contains("@") ? $0 : nil }, ages: ages, now: now)
        // a record from before the resolver has no line to say it in (Store.shown neither): no "account not confirmed" there
        if r == nil, d.line == .unconfirmed { d.line = nil }
        return ProfileShow(entry: e, display: d, record: shown, view: view, splitWords: SplitUsage.words(raw, d.split))
    }

    /// The profile's value now, from its saved record.
    static func load(_ e: AccountEntry, now: Date = Date()) -> ProfileShow { of(e, raw: Store.status(e.id), now: now) }

    var usage: Usage? { display.usage }
    var needsLogin: Bool { display.needsLogin }

    /// The one line of state; `short` where room is short (the menu bar row, the Dock panel: the split's two short lines).
    func lineWords(short: Bool) -> String? {
        switch display.line {
        case .none: return nil
        case .unconfirmed: return Store.unconfirmedWords
        // (signed out or expired: a split by hand's "signed in to M" names the last reading's account, no sign-in now; the
        // age line and the key say it instead. A switch waiting for the app keeps its words: they stay true)
        case .split:
            if display.sign == .signedOut || display.sign == .expired, splitWords?.switched != true { return nil }
            return (short ? splitWords?.shortLine : splitWords?.line) ?? record?.resolved?.lineText()
        case .given(let s):
            // "Usage: Claude Code on <address>": `display` holds the sentence as it was when the value was made, so it is built
            // again now from the record's fact (Show emails may have changed since); any other given line has no address
            if let r = record?.resolved, r.line == nil, r.codeUsageLine == true, let now = r.lineText() { return now }
            return s
        }
    }

    /// Under the line when there are no numbers, in place of "No numbers yet": in the split, what gives the numbers.
    var numbersHint: String? { splitWords?.numbersHint }

    /// The Dock panel's age line when the sign-in is why there are no numbers ("Sign-in expired", "Signed out"), else nil.
    var noNumbersWords: String? {
        if display.none == .expired { return "Sign-in expired" }
        if display.none == .signedOut { return "Signed out" }
        // with no read time to show: in the split the numbers read are never this account's, and a reading for another
        // account than the folder's isn't either (its line says the way back), so never "Reading usage…" for good
        if display.readAt == nil, display.none == .split || display.none == .otherReading { return "Not read for this account" }
        return nil
    }

    /// The plan every surface shows beside the account in use (the card's badge and its ticked row, the Switch page's
    /// in-use box, the Dock panel and the Dock menu's title): the record's.
    var plan: String? { record?.plan }

    /// The address a Sign in fills in: in the split only the app's own (nil: none filled in, never Claude Code's); else the
    /// folder's. Every Sign in takes it here (the menus, the card, Settings ▸ Accounts' in-use box).
    var loginAddress: String? {
        if display.split != nil { return splitWords?.loginEmail }
        return record?.expectedEmail
    }
}
