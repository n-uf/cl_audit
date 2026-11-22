// AccountResolver: the one place that decides, for a profile, which account is active, whose numbers are shown and the one
// line of state (the operator's rule, 2026-11-10: every surface does the same job, so one answer). It runs in the agent's
// reader for each profile (UsageReader.save) and is written once into status/<profile>.json with its time; every surface
// (the menu bar, the Dock icon and its menu, the Dock panel, the dashboard card, Settings ▸ Accounts and the Switch page)
// reads only that record, through AccountView, and never decides for itself.
//
// The rule:
// - the active account is the Claude app's signed-in account (AppSignIn: its config.json names it, its log after its
//   launch gives the organisation and whether it signed out), shown with the green lamp and "in use";
// - with the app signed out or not readable (or no Claude window), Claude Code's folder account is the active one, and for
//   a profile with a window a muted line says why;
// - the numbers are Claude Code's (they are read through its sign-in), and say whose when that isn't the active account
//   ("Usage: Claude Code on <account>": the record keeps only the fact and the account, `codeUsageLine` and `codeName`, and
//   ResolvedAccount.lineText builds the sentence when a surface shows it, so it follows Show emails);
// - Claude Code's folder on another profile's account in use: that profile has those numbers (one profile per account);
//   the line says so and the lamp is off.
// - The numbers are labelled with the address they were read for (`loginEmail`), and "differs" compares that reading's
//   account with the active one (by the ids where both are known, else the addresses), so a read from just before a
//   sign-in changed and the resolver always agree.

import Foundation
import ProfileCore

// (ResolvedAccount, what the resolver decided as the status record keeps it: StatusRecord.swift)

enum AccountResolver {
    /// The answer for one profile. `app`: the Claude app's sign-in (AppSignIn); `code`: Claude Code's folder account;
    /// `loginEmail`: the account the numbers were read for, from that very reading (the token's own profile), or nil when
    /// the reading doesn't say (the status line file); `loginAccount`: that account's id, when the reading's lookup gave
    /// one (nil in a record from before it); `loginOrganization`: its organisation's id, when the reply gave one with the
    /// account's (nil: not known); `names`: addresses by account id (AccountList).
    /// `recordTooLarge`: Claude Code's .claude.json is there but too large to read (Account.recordTooLarge).
    /// `newestSwitch`: the profile's newest switch receipt (SwitchEngine.receipts), for a split that is a switch waiting
    /// for the Claude app (`switchWaits`).
    static func resolve(_ e: AccountEntry, among accounts: [AccountEntry], app: AppSignIn.Login, code: Seat?, loginEmail: String?,
                        loginAccount: String? = nil, loginOrganization: String? = nil, names: [String: String], recordTooLarge: Bool = false,
                        newestSwitch: SwitchReceipt? = nil, now: Date = Date()) -> ResolvedAccount {
        // whose the numbers are: only ever the account the reading itself was for (never .claude.json, never a cached
        // answer). When Claude Code's folder has since signed in to another account (a switch, a log-in), the reading is
        // stale: its numbers are dropped (Store.status) until a read for the folder's account, and the folder's account is
        // the one Claude Code is on (for the rows and lines)
        // (every "the same account" below is the one owner rule, AccountIdentity.sameAccount: a reading with its account's
        // id is known by the id, and then the ids decide, never the addresses; a reading without one by its address; the
        // Claude app's account by its id only, `byID`).
        // A folder record with an id but no address (nil, as with an empty one) can't be compared with a reading known by
        // its address only: whose the numbers are isn't known (`ownerUnknown`, said so), so the reading is stale too (never
        // the profile's numbers), and a stale reading's address never names the folder's account (`readName`).
        // A guard on the ids: should the profile reply's account.uuid ever differ from .claude.json's accountUuid for one
        // account, every reading would go stale; so two ids that differ over two known addresses that are the same keep
        // the reading (the address, the proof before the ids). Another id and another address: stale.
        // The seat too: one login's personal and Team seats share the account id and the address, so only the organisation
        // tells them apart (the Keychain still on the old seat for a moment after a switch between them). The reading's
        // organisation (the profile reply's organization.uuid, kept with its account id) and the folder's (.claude.json's
        // organizationUuid, which Claude Code writes from that same reply) both known and not the same: stale, whatever the
        // address says. Either one not known (nil or empty): never a mismatch.
        let readID = loginAccount.flatMap { $0.isEmpty ? nil : $0 }
        let readOrg = readID == nil ? nil : loginOrganization.flatMap { $0.isEmpty ? nil : $0 }
        let otherSeat = readOrg.map { o in (code?.organization).map { !$0.isEmpty && !AccountID.sameOrganization(o, $0) } ?? false } ?? false
        let idMatch = code.flatMap { c in readID.map { byID($0).sameAccount(known(c)) } }
        let stale: Bool
        if otherSeat { stale = true }
        else if loginEmail != nil, let match = idMatch {
            let addressMatch = loginEmail.map { l in !l.isEmpty && !(code?.email ?? "").isEmpty && sameAddress(code?.email ?? "", l) } ?? false
            stale = !match && !addressMatch
        } else { stale = loginEmail.map { l in code.map { !sameAddress($0.email ?? "", l) } ?? false } ?? false }
        let ownerUnknown = stale && readID == nil && (code?.email ?? "").isEmpty && !(loginEmail ?? "").isEmpty
        let readName = stale ? nil : loginEmail
        let codeLabel = (stale ? code?.email : loginEmail) ?? code?.email ?? code.map { "account \($0.account.prefix(8))" }
        let owner = code.flatMap { c in accounts.first { $0.id != e.id && ($0.seat.map { c.sameAccount($0) } ?? false) } }
        // without the app: Claude Code's folder account is the active one (its address from its record, else the numbers')
        // (ids as AccountID keeps them: one normal form, one comparison)
        var r = ResolvedAccount(account: code.map { AccountID.normal($0.account) }, email: code?.email ?? readName, fromApp: false,
                                numbersFor: loginEmail, differs: false, line: nil, lit: code != nil, clash: owner?.name, at: now,
                                codeAccount: code.map { AccountID.normal($0.account) }, codeName: codeLabel, readStale: stale ? true : nil,
                                clashID: owner?.id)
        // the folder's organisation in three states, so a reader of the record knows the seat in full: its id; "" when the
        // record names the seat with none (no organizationUuid, null or empty: ClaudeFiles.Record keeps each as nil or "");
        // nil only with no seat (and in a record from before this field): not known
        r.codeOrganization = code.map { AccountID.normal($0.organization ?? "") }
        if e.claudeWindow, app.state == .known, let id = app.account.map(AccountID.normal) {
            let mine = ([e.seat] + e.standby.map(\.seat)).compactMap { $0 }.first { byID(id).sameAccount(known($0)) }
            r.account = id
            r.email = mine?.email ?? (code.map { byID(id).sameAccount(known($0)) } == true ? (code?.email ?? readName) : nil) ?? names[id]
            r.fromApp = true
            r.lit = true
        }
        // in every case: the reading's own id against the active account's when both are known and the id isn't one the
        // folder's record disagrees with (the guard above); a stale reading is the folder's account's, so its id against
        // the active account's; else the numbers' own address when both are known; else the folder's id
        if !stale, idMatch != false, let n = readID, let a = r.account { r.differs = !byID(a).sameAccount(byID(n)) }
        else if stale, let c = code, !c.account.isEmpty, let a = r.account { r.differs = !byID(a).sameAccount(known(c)) }
        else if let n = stale ? code?.email : loginEmail, let a = r.email { r.differs = !sameAddress(n, a) }
        else if r.fromApp, let id = r.account { r.differs = code.map { !byID(id).sameAccount(known($0)) } ?? false }
        if let o = owner {
            // ("is on": true signed in or signed out, when the folder's record still names the account it was last on)
            r.line = "Claude Code's folder is on \(o.name)'s account: its numbers show on \(o.name)."
            r.lit = r.fromApp
        } else if ownerUnknown {
            // the numbers are hidden (stale) and nothing else says why: the one line, on every surface that shows it
            r.line = ownerUnknownWords
        } else if r.differs, codeLabel != nil {
            // (the sentence is built when a surface shows it, ResolvedAccount.lineText: the record holds no address text and
            // the line follows Show emails; codeName is the account)
            r.codeUsageLine = true
        } else if stale {
            // the numbers are hidden (read for another account than the folder's record names: just after a switch, or the
            // Keychain's sign-in on another account) and nothing else says why: the way back, on every surface that shows the line
            r.line = staleWords
        } else if e.claudeWindow, !r.fromApp, code != nil {
            // short enough for the card at 340; only when Claude Code has an account to show
            r.line = "Claude app signed out: Claude Code's account shows."
        }
        // its record too large to read: not known, and said so (never as signed out)
        if code == nil, recordTooLarge {
            r.recordTooLarge = true
            r.line = "Claude Code's .claude.json is too large to read: its account isn't known here."
        }
        // the split as a switch waiting for the Claude app: the newest switch went to Claude Code's account (the same
        // rule as Settings' Claude Code row, AccountSettings.switchTarget), and the app is still on the account it left
        // (a switch linked more than a day ago waits no more: then it's a split by hand)
        if r.fromApp, r.differs, r.clash == nil, let n = newestSwitch, let id = r.account,
           AccountSettings.switchTarget(goal: nil, newest: n, standby: [], code: codeLabel, codeAccount: code.map { AccountID.normal($0.account) }, now: now) != nil,
           byID(id).sameAccount(byID(n.from.account)), n.linkedLately(now: now) ?? true {
            r.switchWaits = true
        }
        return r
    }

    /// The line while Claude Code's record names its account without an address and the reading by its address only: the
    /// numbers are hidden, and this says why and what fixes it (a sign-in writes the address again).
    static let ownerUnknownWords = "Claude Code's record has no address: sign in again in Claude Code."

    /// The line while the reading is for another account than the one Claude Code's record names (stale): the numbers are
    /// hidden, and this says the way back. True both right after a switch (the new sign-in's first read is on its way) and
    /// when the Keychain's sign-in stays on another account (only a sign-in helps then).
    static let staleWords = "Numbers for another account: if this stays, sign in to read again."

    /// Two addresses (a reading's, an account's) name one account: the one owner rule's address-only part; with either
    /// empty, the plain comparison as before (two empty addresses are not "another account", so nothing goes stale).
    static func sameAddress(_ a: String, _ b: String) -> Bool {
        a.isEmpty || b.isEmpty ? a.lowercased() == b.lowercased() : AccountIdentity.address(a).sameAccount(.address(b))
    }

    /// An account as the Claude app's config.json and the status record name it: by its id only (neither names an
    /// organisation), compared by the one owner rule.
    static func byID(_ id: String?) -> AccountIdentity { AccountIdentity(account: id, email: nil, organization: nil, source: .verified) }

    /// A seat as compared with an account named by its id only: its organisation left out (one not known there isn't "none").
    static func known(_ s: Seat) -> AccountIdentity { AccountIdentity(s).withoutOrganization }
}

extension ResolvedAccount {
    /// The one line of state as a surface says it now: `line`, else, when the numbers are another account's, "Usage: Claude Code
    /// on" and Claude Code's account (hidden while addresses are hidden: AddressSettings.words). `blur`: a test override.
    func lineText(blur: Bool? = nil) -> String? {
        if let line { return line }
        // the split's sentence (Store.shown marks it, `splitLine`): built here from the accounts the record names, so no record
        // holds a sentence with an address in it
        if splitLine == true { return SplitUsage.of(self, switched: switchWaits == true).line(blur: blur) }
        guard codeUsageLine == true, let name = codeName else { return nil }
        return Self.usageOnPrefix + AddressSettings.words(name, blur: blur)
    }
}

/// The split's words: the Claude app (the account in use) on one account, Claude Code, whose sign-in reads the numbers, on
/// another. Whether a record is the split is ProfileCore's one rule (Headline.split over the record's owner, which the
/// headline answer and the one value carry); this only says it. Then nothing headline shows Claude Code's numbers as the
/// profile's (Store.status(for:) drops them: no bars, nothing full or red, no countdown, no alert, no switch offer); every
/// surface says the line instead, with one key to log Claude Code in to the app's account. Claude Code's numbers stay only
/// in its own row in Settings ▸ Accounts.
struct SplitUsage: Equatable {
    let app: String                 // the account in use: the Claude app's
    let code: String                // Claude Code's
    /// A switch to Claude Code's account waiting for the Claude app (ResolvedAccount.switchWaits): the app is the one left to
    /// sign in, so there is no key to log Claude Code back in. Otherwise a split by hand.
    var switched = false

    /// The words for record `s` while its headline answer is the split (`split`: the answer's, Headline.split); nil when it
    /// isn't, or the record has no resolver answer to name the accounts.
    static func words(_ s: IconStatus?, _ split: Headline.Split?) -> SplitUsage? {
        guard let split, let r = s?.resolved else { return nil }
        return of(r, switched: split.switchWaits)
    }

    /// The split of a resolver answer: the app's account and Claude Code's, named as the record names them.
    /// (the split has Claude Code's account by its name or the numbers': Headline.split needs one of them)
    static func of(_ r: ResolvedAccount, switched: Bool) -> SplitUsage {
        SplitUsage(app: r.email ?? r.account.map { "account \($0.prefix(8))" } ?? "the Claude app's account",
                   code: r.codeName ?? r.numbersFor ?? "Claude Code's account", switched: switched)
    }

    /// "cl_audit can't read P@…'s usage: Claude Code in Terminal is signed in to M@…" (Claude Code inside the Claude app runs
    /// on the app's own sign-in, so the app's account is the one in use; only Terminal's login, the one cl_audit reads with,
    /// is on M); a switch waiting for the app, the card's words on every surface (Settings, menu bar, widget, Dock panel):
    /// "Switching to M@…: one step left. Sign the Claude app in to M@… to finish."
    var line: String { line(blur: nil) }
    /// `line` for a given "Show emails" setting (nil: the app's own): what a check hands in.
    func line(blur: Bool?) -> String {
        switched ? "\(Self.switchingHead(code, blur: blur)). Sign the Claude app in to \(AddressSettings.words(code, blur: blur)) to finish."
                 : "cl_audit can't read \(AddressSettings.words(app, blur: blur))'s usage: Claude Code in Terminal is signed in to \(AddressSettings.words(code, blur: blur))."
    }
    /// The short form where space is short: "Can't read P@…'s usage" over "Terminal: M@…"; a switch waiting for the app:
    /// its first clause, "Switching to M@…: one step left".
    var shortLine: String {
        switched ? Self.switchingHead(code) : "Can't read \(AddressSettings.words(app))'s usage\nTerminal: \(AddressSettings.words(code))"
    }
    /// The after-switch heading, the same on the card (UsageNotice) and every other surface.
    static func switchingHead(_ to: String, blur: Bool? = nil) -> String { "Switching to \(AddressSettings.words(to, blur: blur)): one step left" }
    /// Under the line, in place of "No numbers yet": what gives the numbers. Nil while a switch waits for the app (nothing
    /// to sign in to then).
    var numbersHint: String? {
        switched ? nil : "Sign Claude Code in Terminal in to \(loginEmail.map { AddressSettings.words($0) } ?? "the Claude app's account") to see its numbers."
    }
    /// The key: the existing Sign in (Claude Code's own sign-in in Terminal, with the app's address filled in). Not a switch.
    /// None while a switch waits for the app, and none when the app's account is known by its id only: the key only ever
    /// names and fills in the app's own address (never Claude Code's), so then `hint` says what to do instead.
    var key: String? { loginEmail.map { "Sign Claude Code in Terminal in to \(AddressSettings.words($0))…" } }
    /// The key where space is short (the Dock panel's fixed width): "Sign in to P@… in Terminal", as long as the old key.
    var shortKey: String? { loginEmail.map { "Sign in to \(AddressSettings.words($0)) in Terminal…" } }
    /// The address the login fills in: the app's own, when it is known (not while a switch waits for the app).
    var loginEmail: String? { !switched && app.contains("@") ? app : nil }
    /// In place of the key when the app's address isn't known.
    var hint: String? { !switched && loginEmail == nil ? "Sign Claude Code in Terminal in to the Claude app's account" : nil }
}

/// What every surface shows of a profile's account, from its status record only (never a file, a log or a seat).
struct AccountView: Equatable {
    var label: String?              // the active account: its address, or "account <8>"; nil: none known
    var numbersOwner: String?       // Claude Code's account, whose numbers they are (or will be, after a switch's first read)
    var lit: Bool                 // the green lamp and "in use"
    var clash: String?              // another profile's name, when Claude Code's folder is on its account
    /// The active account's id (lower case), from the record; nil for a record from before the resolver.
    var account: String? = nil
    /// The account isn't known because Claude Code's record is too large to read (never shown as "not signed in").
    var recordTooLarge = false
    /// The numbers aren't the active account's: they are Claude Code's, on `numbersOwner`.
    var differs = false
    /// Claude Code's folder account's id (lower case), where the record has it.
    var codeAccount: String? = nil
    /// What the resolver decided: the one line of state is built from it each time it is read (`line`), never kept as text.
    var resolved: ResolvedAccount? = nil

    /// The one line of state, built now (ResolvedAccount.lineText: an address in it follows Show emails as it is at this read).
    var line: String? { resolved?.lineText() }

    static func of(_ s: IconStatus?) -> AccountView {
        guard let s else { return AccountView(label: nil, numbersOwner: nil, lit: false, clash: nil) }
        if let r = s.resolved {
            return AccountView(label: r.email ?? r.account.map { "account \($0.prefix(8))" }, numbersOwner: r.codeName ?? r.numbersFor,
                               lit: r.lit, clash: r.clash, account: r.account, recordTooLarge: r.recordTooLarge == true,
                               differs: r.differs, codeAccount: r.codeAccount, resolved: r)
        }
        // a record from before the resolver (or none written yet): the sign-in it was read for
        let who = s.loginEmail ?? s.expectedEmail
        return AccountView(label: who, numbersOwner: who, lit: who != nil, clash: nil)
    }

    /// "ultra-1": the account in use with no label (showing it, with its lamp, says it's in use).
    var inUseLine: String? { short }
    var short: String? { label.map(AccountNames.short) }

    /// This standby account is the one the record names active (by its id, else its address: the one owner rule, the record
    /// naming no organisation): it is in use, so no list shows it on standby too.
    func isActive(_ s: StandbyAccount) -> Bool {
        AccountIdentity(account: account, email: label.flatMap { $0.contains("@") ? $0 : nil }, organization: nil, source: .guessed)
            .sameAccount(s.identity.withoutOrganization)
    }

    /// Claude Code's account when it isn't the active one (the Claude app is still on another, e.g. right after a switch):
    /// Settings ▸ Accounts gives it a row of its own, with the numbers (they are its). nil when the numbers are the active
    /// account's, or when Claude Code's folder is on another profile's account (that profile has them).
    var codeRow: String? { differs && clash == nil ? numbersOwner : nil }

    /// Claude Code's own row is this account: by its id first (a row named "account <8>" has no address), else its address
    /// (the one owner rule, the record naming no organisation).
    func isCodeRow(id: String?, email: String?) -> Bool {
        guard let row = codeRow else { return false }
        return AccountIdentity(account: codeAccount, email: row, organization: nil, source: .guessed)
            .sameAccount(AccountIdentity(account: id, email: email, organization: nil, source: .guessed))
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
