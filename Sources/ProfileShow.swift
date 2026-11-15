// A profile as its headline surfaces show it (ProfileCore step 3a: the menu bar icon with its row and menu, the Dock icon
// with its face, its menu and its panel): ProfileCore's one "what to show" value (ProfileDisplay), made once from the
// profile's status record, and cl_audit's words for it. The surfaces draw this and decide nothing themselves: not whether
// the numbers show, how old they are, what is full, the lamp, the key or the line.

import Foundation
import ProfileCore

struct ProfileShow {
    let entry: AccountEntry
    /// The one value.
    let display: ProfileDisplay
    /// The record as the headline surfaces read it (Store.status(for:)): its plan, problem, renew note and addresses.
    let record: IconStatus?
    /// The account's names: the active account for the account line, and the standby lists without it.
    let view: AccountView
    /// The split's words (SplitUsage), only while the display says the split.
    private let splitWords: SplitUsage?

    /// The value for `raw`, the record as read (Store.status(_:)), at `now`.
    static func of(_ e: AccountEntry, raw read: IconStatus?, now: Date = Date()) -> ProfileShow {
        let ages = Store.ages(e)
        let raw = read?.current(now: now)               // (Store.status(_:) has done it already; once more changes nothing)
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
                                    inUse: view.lit, clash: r?.clash.map { ProfileDisplay.Clash(id: r?.clashID, name: $0) },
                                    note: r?.line, splitTo: r?.email.flatMap { $0.contains("@") ? $0 : nil }, ages: ages, now: now)
        // a record from before the resolver has no line to say it in (Store.shown neither): no "account not confirmed" there
        if r == nil, d.line == .unconfirmed { d.line = nil }
        return ProfileShow(entry: e, display: d, record: shown, view: view, splitWords: d.split != nil ? SplitUsage.of(raw) : nil)
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
        case .split: return (short ? splitWords?.shortLine : splitWords?.line) ?? record?.resolved?.line
        case .given(let s): return s
        }
    }

    /// The one key's title: Log in…, or in the split Claude Code's own sign-in to the app's account (`short`: the Dock
    /// panel's fixed width).
    func keyWords(short: Bool) -> String? {
        switch display.key {
        case .none: return nil
        case .logIn: return "Log in…"
        case .logInCode: return short ? splitWords?.shortKey : splitWords?.key
        }
    }

    /// Under the line when there are no numbers, in place of "No numbers yet": in the split, what gives the numbers.
    var numbersHint: String? { splitWords?.numbersHint }

    /// The Dock panel's age line when the sign-in is why there are no numbers ("Login expired", "Signed out"), else nil.
    var noNumbersWords: String? {
        display.none == .expired ? "Login expired" : display.none == .signedOut ? "Signed out" : nil
    }

    /// The address a Log in fills in: in the split only the app's own (nil: none filled in, never Claude Code's), else the
    /// folder's (SplitUsage.loginAddress over the same record).
    var loginAddress: String? { display.split != nil ? splitWords?.loginEmail : record?.expectedEmail }
}
