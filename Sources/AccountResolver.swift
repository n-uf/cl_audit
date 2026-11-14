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
    /// Claude Code's folder account's id (lower case), where known: the lists match its own row by it before its address.
    var codeAccount: String? = nil
    /// Claude Code's account as its rows and lines name it: the folder's address (else the numbers', else "account <8>").
    /// `numbersFor` is only ever the reading's own account; this one is for naming.
    var codeName: String? = nil
    /// The folder has signed in to another account since the numbers were read: they are that reading's, not Claude
    /// Code's now, and no surface shows them (Store.status(for:)) until a read for the new account.
    var readStale: Bool? = nil
}

enum AccountResolver {
    /// The answer for one profile. `app`: the Claude app's sign-in (AppSignIn); `code`: Claude Code's folder account;
    /// `loginEmail`: the account the numbers were read for, from that very reading (the token's own profile), or nil when
    /// the reading doesn't say (the status line file); `names`: addresses by account id (AccountList).
    /// `recordTooLarge`: Claude Code's .claude.json is there but too large to read (Account.recordTooLarge).
    static func resolve(_ e: AccountEntry, among accounts: [AccountEntry], app: AppSignIn.Login, code: Seat?, loginEmail: String?,
                        names: [String: String], recordTooLarge: Bool = false, now: Date = Date()) -> ResolvedAccount {
        // whose the numbers are: only ever the account the reading itself was for (never .claude.json, never a cached
        // answer). When Claude Code's folder has since signed in to another account (a switch, a log-in), the reading is
        // stale: its numbers are dropped (Store.status) until a read for the folder's account, and the folder's account is
        // the one Claude Code is on (for the rows and lines)
        let stale = loginEmail.map { l in code?.email.map { $0.lowercased() != l.lowercased() } ?? false } ?? false
        let codeLabel = (stale ? code?.email : loginEmail) ?? code?.email ?? code.map { "account \($0.account.prefix(8))" }
        let owner = code.flatMap { c in accounts.first { $0.id != e.id && ($0.seat.map { c.same($0) } ?? false) } }
        // without the app: Claude Code's folder account is the active one (its address from its record, else the numbers')
        var r = ResolvedAccount(account: code?.account.lowercased(), email: code?.email ?? loginEmail, fromApp: false,
                                numbersFor: loginEmail, differs: false, line: nil, lit: code != nil, clash: owner?.name, at: now,
                                codeAccount: code?.account.lowercased(), codeName: codeLabel, readStale: stale ? true : nil)
        if e.claudeWindow, app.state == .known, let id = app.account?.lowercased() {
            let mine = ([e.seat] + e.standby.map(\.seat)).compactMap { $0 }.first { $0.account.lowercased() == id }
            r.account = id
            r.email = mine?.email ?? (code?.account.lowercased() == id ? (code?.email ?? loginEmail) : nil) ?? names[id]
            r.fromApp = true
            r.lit = true
        }
        // in every case: the numbers' own address decides when both are known; else the folder's id
        if let n = (stale ? code?.email : loginEmail)?.lowercased(), let a = r.email?.lowercased() { r.differs = n != a }
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

/// The split: the Claude app (the account in use) on one account, Claude Code, whose sign-in reads the numbers, on another.
/// Then nothing headline shows Claude Code's numbers as the profile's (Store.status(for:) drops them: no bars, nothing full
/// or red, no countdown, no alert, no switch offer); every surface says the line instead, with one key to log Claude Code
/// in to the app's account. Claude Code's numbers stay only as one labelled secondary line (the card) and in its own row
/// in Settings ▸ Accounts.
struct SplitUsage: Equatable {
    let app: String                 // the account in use: the Claude app's
    let code: String                // Claude Code's

    static func of(_ s: IconStatus?) -> SplitUsage? {
        guard let r = s?.resolved, r.fromApp, r.differs, r.clash == nil, let code = r.codeName ?? r.numbersFor else { return nil }
        return SplitUsage(app: r.email ?? r.account.map { "account \($0.prefix(8))" } ?? "the Claude app's account", code: code)
    }

    /// "No usage for P@… yet: Claude Code here is signed in to M@…"
    var line: String { "No usage for \(Privacy.masked(app)) yet: Claude Code here is signed in to \(Privacy.masked(code))" }
    /// The key: the existing Log in (Claude Code's own sign-in in Terminal, with the app's address filled in). Not a switch.
    var key: String { "Log Claude Code in to \(Privacy.masked(app))" }
    /// The address the login fills in (none for an account known by its id only).
    var loginEmail: String? { app.contains("@") ? app : nil }

    /// "Claude Code in Terminal: M@… · Week 100%, back Sun 13:00": Claude Code's own numbers, from the record as read, or nil
    /// when it has none.
    func codeLine(_ raw: IconStatus?, now: Date = Date()) -> String? {
        guard let raw else { return nil }
        func part(_ name: String, _ p: Double?, _ resets: Date?) -> String? {
            guard let p else { return nil }
            let full = AtLimit.isFull(p)
            return "\(name) \(Int(p.rounded()))%" + (full ? resets.map { ", " + TimeWords.back($0, now: now) } ?? "" : "")
        }
        let parts = [raw.noFiveHour == true ? nil : part("5-hour", raw.fiveHour, raw.fiveHourResets), part("Week", raw.weekly, raw.weeklyResets)]
            .compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return "Claude Code in Terminal: \(Privacy.masked(code)) · " + parts.joined(separator: " · ")
    }
}

/// What every surface shows of a profile's account, from its status record only (never a file, a log or a seat).
struct AccountView: Equatable {
    var label: String?              // the active account: its address, or "account <8>"; nil: none known
    var numbersOwner: String?       // Claude Code's account, whose numbers they are (or will be, after a switch's first read)
    var line: String?               // the one line of state
    var lit: Bool                   // the green lamp and "in use"
    var clash: String?              // another profile's name, when Claude Code's folder is on its account
    /// The active account's id (lower case), from the record; nil for a record from before the resolver.
    var account: String? = nil
    /// The account isn't known because Claude Code's record is too large to read (never shown as "not signed in").
    var recordTooLarge = false
    /// The numbers aren't the active account's: they are Claude Code's, on `numbersOwner`.
    var differs = false
    /// Claude Code's folder account's id (lower case), where the record has it.
    var codeAccount: String? = nil

    static func of(_ s: IconStatus?) -> AccountView {
        guard let s else { return AccountView(label: nil, numbersOwner: nil, line: nil, lit: false, clash: nil) }
        if let r = s.resolved {
            return AccountView(label: r.email ?? r.account.map { "account \($0.prefix(8))" }, numbersOwner: r.codeName ?? r.numbersFor,
                               line: r.line, lit: r.lit, clash: r.clash, account: r.account, recordTooLarge: r.recordTooLarge == true,
                               differs: r.differs, codeAccount: r.codeAccount)
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

    /// Claude Code's account when it isn't the active one (the Claude app is still on another, e.g. right after a switch):
    /// Settings ▸ Accounts gives it a row of its own, with the numbers (they are its). nil when the numbers are the active
    /// account's, or when Claude Code's folder is on another profile's account (that profile has them).
    var codeRow: String? { differs && clash == nil ? numbersOwner : nil }

    /// Claude Code's own row is this account: by its id first (a row named "account <8>" has no address), else its address.
    func isCodeRow(id: String?, email: String?) -> Bool {
        guard codeRow != nil else { return false }
        if let c = codeAccount, let i = id?.lowercased() { return c == i }
        guard let e = email?.lowercased(), !e.isEmpty else { return false }
        return e == codeRow?.lowercased()
    }

    /// The last line of Claude Code's own row. On the account the profile's current switch went for: only the Claude app's
    /// sign-in is left. On another account (the browser signed in as someone else): the switch didn't finish, and how to
    /// finish or take it back. With no switch going (a sign-in by hand): only that Claude Code is on it.
    static func codeRowWords(code: String, target: String?) -> String {
        guard let t = target, !t.isEmpty else { return "Claude Code is on it." }
        guard t.lowercased() != code.lowercased() else { return "Claude Code is on it; sign the Claude app in to finish." }
        let c = AccountNames.short(code), w = AccountNames.short(t)
        return "Claude Code signed in as \(c), not \(w): the switch didn't finish. Sign Claude Code in as \(w) from the Switch page, or Undo it."
    }

    /// A note may call this account "on standby" only when no box shows it as the active account or as Claude Code's (by
    /// its id first, then its address).
    func mayCallStandby(_ email: String, id: String? = nil) -> Bool {
        if let i = id?.lowercased(), let a = account, i == a { return false }
        if isCodeRow(id: id, email: email) { return false }
        let e = email.lowercased()
        return e != label?.lowercased() && e != codeRow?.lowercased()
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

    /// Settings ▸ Accounts' standby rows: every account but the active one and Claude Code's while it has its own row
    /// (AccountView.codeRow), so each account of the profile is listed once.
    func standbyRows(by v: AccountView) -> [StandbyAccount] {
        listed(by: v).standby.filter { !v.isCodeRow(id: $0.seat?.account, email: $0.seat?.email ?? $0.email) }
    }

    /// The plan to show under the active account in Settings ▸ Accounts: the record's (the numbers' account) when they are
    /// its own; else, while Claude Code is on another account, the plan the profile remembers for the active one (nil when
    /// none), never Claude Code's.
    func activePlan(_ v: AccountView, recordPlan: String?) -> String? {
        guard v.codeRow != nil else { return recordPlan }
        return standby.first { v.isActive($0) }?.plan
    }
}
