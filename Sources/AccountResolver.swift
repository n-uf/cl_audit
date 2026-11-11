// AccountResolver: the one place that decides, for a profile, which account is active, whose numbers are shown and the one
// line of state (the operator's rule, 2026-11-10: every surface does the same job, so one answer). It runs in the agent's
// reader for each profile (UsageReader.save) and is written once into status/<profile>.json with its time; every surface
// (the menu bar, the Dock icon and its menu, the Dock panel, the dashboard card, Settings ▸ Accounts, the Switch page and
// quick chat's profile line) reads only that record, through AccountView, and never decides for itself.
//
// The rule:
// - the active account is the Claude app's signed-in account (AppSignIn: its config.json names it, its log after its
//   launch gives the organisation and whether it signed out), shown with the green lamp and "in use";
// - with the app signed out or not readable (or no Claude window), Claude Code's folder account is the active one, and for
//   a profile with a window a muted line says why;
// - the numbers are Claude Code's (they are read through its sign-in), and say whose when that isn't the active account
//   ("Usage: Claude Code on b…@example.com");
// - Claude Code's folder on another profile's account in use: that profile has those numbers (one profile per account);
//   the line says so and the lamp is off.
// - The numbers are labelled with the address they were read for (`loginEmail`), and "differs" compares that address with
//   the active account's, so a read from just before a sign-in changed and the resolver always agree.

import Foundation

/// What the resolver decided, as written into the profile's status record.
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
}

enum AccountResolver {
    /// The answer for one profile. `app`: the Claude app's sign-in (AppSignIn); `code`: Claude Code's folder account;
    /// `loginEmail`: the address the numbers were read for; `names`: addresses by account id (AccountList).
    /// `recordTooLarge`: Claude Code's .claude.json is there but too large to read (Account.recordTooLarge).
    static func resolve(_ e: AccountEntry, among accounts: [AccountEntry], app: AppSignIn.Login, code: Seat?, loginEmail: String?,
                        names: [String: String], recordTooLarge: Bool = false, now: Date = Date()) -> ResolvedAccount {
        let codeLabel = loginEmail ?? code?.email ?? code.map { "account \($0.account.prefix(8))" }
        let owner = code.flatMap { c in accounts.first { $0.id != e.id && ($0.seat.map { c.same($0) } ?? false) } }
        // without the app: Claude Code's folder account is the active one (its address from its record, else the numbers')
        var r = ResolvedAccount(account: code?.account.lowercased(), email: code?.email ?? loginEmail, fromApp: false,
                                numbersFor: codeLabel, differs: false, line: nil, lit: code != nil, clash: owner?.name, at: now)
        if e.claudeWindow, app.state == .known, let id = app.account?.lowercased() {
            let mine = ([e.seat] + e.standby.map(\.seat)).compactMap { $0 }.first { $0.account.lowercased() == id }
            r.account = id
            r.email = mine?.email ?? (code?.account.lowercased() == id ? (code?.email ?? loginEmail) : nil) ?? names[id]
            r.fromApp = true
            r.lit = true
        }
        // in every case: the numbers' own address decides when both are known; else the folder's id
        if let n = loginEmail?.lowercased(), let a = r.email?.lowercased() { r.differs = n != a }
        else if r.fromApp, let id = r.account { r.differs = code.map { $0.account.lowercased() != id } ?? false }
        if let o = owner {
            r.line = "Claude Code's folder is signed in to \(o.name)'s account: its numbers show on \(o.name)."
            r.lit = r.fromApp
        } else if r.differs, let c = codeLabel {
            r.line = "Usage: Claude Code on " + Privacy.masked(c)
        } else if e.claudeWindow, !r.fromApp, code != nil {
            // short enough for the card at 340; only when Claude Code has an account to show
            r.line = "Claude app signed out: Claude Code's account shows."
        }
        // its record too large to read: not known, and said so (never as signed out)
        if code == nil, recordTooLarge {
            r.recordTooLarge = true
            r.line = "Claude Code's .claude.json is too large to read: its account isn't known here."
        }
        return r
    }
}

/// What every surface shows of a profile's account, from its status record only (never a file, a log or a seat).
struct AccountView: Equatable {
    var label: String?              // the active account: its address, or "account <8>"; nil: none known
    var numbersOwner: String?       // whose the numbers are
    var line: String?               // the one line of state
    var lit: Bool                   // the green lamp and "in use"
    var clash: String?              // another profile's name, when Claude Code's folder is on its account
    /// The active account's id (lower case), from the record; nil for a record from before the resolver.
    var account: String? = nil
    /// The account isn't known because Claude Code's record is too large to read (never shown as "not signed in").
    var recordTooLarge = false

    static func of(_ s: IconStatus?) -> AccountView {
        guard let s else { return AccountView(label: nil, numbersOwner: nil, line: nil, lit: false, clash: nil) }
        if let r = s.resolved {
            return AccountView(label: r.email ?? r.account.map { "account \($0.prefix(8))" }, numbersOwner: r.numbersFor,
                               line: r.line, lit: r.lit, clash: r.clash, account: r.account, recordTooLarge: r.recordTooLarge == true)
        }
        // a record from before the resolver (or none written yet): the sign-in it was read for
        let who = s.loginEmail ?? s.expectedEmail
        return AccountView(label: who, numbersOwner: who, line: nil, lit: who != nil, clash: nil)
    }

    /// "ultra-1 · in use".
    var inUseLine: String? { label.map { "\(AccountNames.short($0)) · in use" } }
    var short: String? { label.map(AccountNames.short) }

    /// This standby account is the one the record names active (by its id, else its address): it is in use, so no list
    /// shows it on standby too.
    func isActive(_ s: StandbyAccount) -> Bool {
        if let a = account, let id = s.seat?.account.lowercased() { return id == a }
        if let l = label?.lowercased(), l.contains("@") { return (s.seat?.email ?? s.email).lowercased() == l }
        return false
    }
}

extension AccountEntry {
    /// The profile as every screen lists its accounts: its standby accounts without the one its record names active
    /// (AccountView.isActive), so an account is never shown in use and on standby at once.
    func listed(by v: AccountView) -> AccountEntry {
        var e = self
        e.standby.removeAll { v.isActive($0) }
        return e
    }
}
