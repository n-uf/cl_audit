// AccountResolver: the one place that decides, for a profile, which account is active, whose numbers are shown and the one
// line of state (the operator's rule, 2026-11-10: every surface does the same job, so one answer). It runs in the agent's
// reader for each profile (UsageReader.save) and is written once into status/<profile>.json with its time; every surface
// (the menu bar, the Dock icon and its menu, the Dock panel, the dashboard card, Settings ▸ Accounts and the Switch page)
// reads only that record, through AccountView, and never decides for itself.
//
// The rule:
// - the active account is the Claude app's signed-in account (AppSignIn: its config.json names it, its log after its
//   launch gives the organisation and whether it signed out), shown with the green lamp and "in use";
// - with the app signed out or not readable (or no Claude window), Claude Code's account is the active one, and for a
//   profile with a window a muted line says why;
// - Claude Code's account is cl_kit's one answer (ClaudeAuth's FolderSignIn.answer, the platform's account rule): the
//   folder's .claude.json is only a guess, and a verified word beats it, Anthropic's reply for the Keychain sign-in the
//   numbers were read with between asks, or a short-lived claude's own `initialize` account when the reader asked it
//   (UsageReader.considerAsk); the Claude app's account stays this app's own question (two names, A4);
// - the numbers are Claude Code's (they are read through its sign-in), and say whose when that isn't the active account
//   ("Usage: Claude Code on <account>": the record keeps only the fact and the account, `codeUsageLine` and `codeName`, and
//   ResolvedAccount.lineText builds the sentence when a surface shows it, so it follows Show emails);
// - Claude Code's folder on an account another profile uses too (shared seats, operator 2026-11-22): the numbers are that
//   seat's, shown on every profile that has it (the record's old `clash` fields are only still decoded, never written).
// - The numbers are labelled with the address they were read for (`loginEmail`), and "differs" compares that reading's
//   account with the active one (by the ids where both are known, else the addresses), so a read from just before a
//   sign-in changed and the resolver always agree.

import ClaudeAuth
import Foundation
import ProfileCore

// (ResolvedAccount, what the resolver decided as the status record keeps it: StatusRecord.swift)

/// Claude Code's record as the resolver takes it: the one folder reader's account (Account.codeRecord: an account id or an
/// address, A1), or a saved seat (a check's, a profile's: always with its id).
protocol CodeRecord {
    /// The account the record names, as a guess; nil when it names nobody.
    var recordAccount: SignedInAccount? { get }
}

extension SignedInAccount: CodeRecord {
    var recordAccount: SignedInAccount? {
        guard names else { return nil }
        var r = self; r.origin = .record
        return r
    }
}

extension Seat: CodeRecord {
    var recordAccount: SignedInAccount? { SignedInAccount(self).recordAccount }
}

enum AccountResolver {
    /// The answer for one profile. `app`: the Claude app's sign-in (AppSignIn); `code`: Claude Code's folder record (a guess);
    /// `loginEmail`: the account the numbers were read for, from that very reading (the token's own profile), or nil when
    /// the reading doesn't say (the status line file); `loginAccount`: that account's id, when the reading's lookup gave
    /// one (nil in a record from before it); `loginOrganization`: its organisation's id, when the reply gave one with the
    /// account's (nil: not known); `names`: addresses by account id (AccountList).
    /// `readingVerified`: the reading's sign-in is still the one the folder keeps, so Anthropic's reply for it is a verified
    /// word (false: after a sign-in change, a sign-in gone, or a window answering without the agent's reader).
    /// `process`: a short-lived claude's own `initialize` account (UsageReader's short ask), when it came after the reading.
    /// `recordTooLarge`: Claude Code's .claude.json is there but too large to read (Account.recordTooLarge).
    /// `newestSwitch`: the profile's newest switch receipt (SwitchEngine.receipts), for a split that is a switch waiting
    /// for the Claude app (`switchWaits`).
    static func resolve(_ e: AccountEntry, among accounts: [AccountEntry], app: AppSignIn.Login, code: (any CodeRecord)?, loginEmail: String?,
                        loginAccount: String? = nil, loginOrganization: String? = nil, loginOrganizationName: String? = nil,
                        readingVerified: Bool = true,
                        process: SignedInAccount? = nil, names: [String: String], recordTooLarge: Bool = false,
                        newestSwitch: SwitchReceipt? = nil, now: Date = Date()) -> ResolvedAccount {
        // Claude Code's account is ClaudeAuth's one answer (FolderSignIn.answer, the platform's account rule): the folder's
        // record (only a guess) under a verified word. The verified word: a short-lived claude's own `initialize` account
        // (`process`, which the caller passes only when it came after the reading), else Anthropic's reply for the Keychain
        // sign-in the numbers were read with (the reading's own account), while that sign-in is the one kept
        // (`readingVerified`). Signed in by an account id or an address (A1); a personal plan and a Team seat on one address
        // are two seats, told apart by the organisation (A2); a verified word beats the record, which may then name another
        // account (A3); organisation names in any case (A5). The Claude app's account is this app's own question, asked
        // apart below (A4).
        let record = code?.recordAccount
        let readID = loginAccount.flatMap { $0.isEmpty ? nil : $0 }
        // (the reading's organisation only with its account's id, as the reader keeps it)
        let readOrg = readID == nil ? nil : loginOrganization.flatMap { $0.isEmpty ? nil : $0 }
        // (its organisation's name too, where the reader kept it: the short ask's word names its organisation by name only)
        let read = SignedInAccount(accountID: readID, email: loginEmail, organizationID: readOrg,
                                   organizationName: readID == nil ? nil : loginOrganizationName, origin: .server)
        let reading = read.names ? read : nil
        let word = process.flatMap { $0.names && $0.origin != .record ? $0 : nil } ?? (readingVerified ? reading : nil)
        let answer = FolderSignIn.answer(record: record, verified: word)
        // Claude Code's account. A seat not known (only one side names an organisation) is still the same account: its id
        // and address are the account's (both seats share them), but no organisation is taken from the other side
        var codeAccount = answer.account
        if answer.verdict == .seatNotKnown, let r = answer.record, var c = codeAccount {
            c.accountID = c.accountID ?? r.accountID
            c.email = c.email ?? r.email
            codeAccount = c
        }
        // the record names Claude Code's very account (the same seat, or one not known): its address is the one shown
        let recordNamesIt = (answer.verdict == .verified && answer.record != nil) || answer.verdict == .seatNotKnown
        // Whose the numbers are is only ever the reading's own account (numbers belong to the source that gave them, never
        // to the record's account). They are stale only while Claude Code's account is another one than the reading's: a
        // newer verified word (the short ask) names another account, or the reading's sign-in isn't the kept one any more
        // and the record names another account. Stale numbers show nowhere (Store.status) until a read for Claude Code's
        // account, and a stale reading's address never names Claude Code's account (`readName`).
        // With no verified word (the reading's sign-in not the kept one) the ids' guard stays: a reading for the record's
        // address under another id is the same account (both ids and addresses known, no two organisations that differ),
        // kept as before, should the profile reply's account id ever differ from the record's for one account.
        let guarded: Bool = {
            guard word == nil, let r = reading, let c = codeAccount, let ri = r.accountID, let ci = c.accountID, !AccountID.same(ri, ci),
                  let re = r.email, let ce = c.email, re.lowercased() == ce.lowercased() else { return false }
            if let ro = r.organizationID, let co = c.organizationID { return AccountID.same(ro, co) }
            return true
        }()
        // Against a running claude's own word the seat must be told apart: a reading whose seat can't be (the word names its
        // organisation by name only, the reading by id only) isn't counted as that seat's, so a personal plan's numbers
        // never show for a Team seat on its address, or the other way round (the reader then reads the sign-in again).
        // (a word that names no organisation says nothing about the seat: only one that names it by name counts here)
        let processSaid = word?.origin == .process && word?.organizationName != nil
        let stale = reading.map { r in
            codeAccount.map { a in
                switch r.match(a) {
                case .seat: return false
                case .seatNotKnown: return processSaid
                case .different: return !guarded
                }
            } ?? false
        } ?? false
        // stale only because the seat isn't known yet (the same account, the organisation named on one side alone: A2, never
        // taken for a match): said as such, not as another account
        let seatUnknown = stale && reading.flatMap { r in codeAccount.map { r.match($0) == .seatNotKnown } } == true
        let readName = stale ? nil : loginEmail
        let codeLabel = (stale ? nil : reading?.email) ?? codeAccount?.email ?? codeAccount?.accountID.map { "account \($0.prefix(8))" }
        let codeEmail = (recordNamesIt ? answer.record?.email : nil) ?? codeAccount?.email
        // without the app: Claude Code's account is the active one (its record's address, else the verified word's)
        // (ids as AccountID keeps them: one normal form, one comparison)
        var r = ResolvedAccount(account: codeAccount?.accountID.map(AccountID.normal), email: codeEmail ?? readName, fromApp: false,
                                numbersFor: loginEmail, differs: false, line: nil, lit: codeAccount != nil, clash: nil, at: now,
                                codeAccount: codeAccount?.accountID.map(AccountID.normal), codeName: codeLabel, readStale: stale ? true : nil,
                                clashID: nil)
        // the seat's organisation in three states, so a reader of the record knows the seat in full: its id, Claude Code's
        // account's own (the verified word's when it names one, also when the record names none: the word knows the seat);
        // "" when the record names that very seat with none (no organizationUuid, null or empty); nil when it isn't known
        // (the word names no organisation id while the record names one: a seat not known; no account)
        r.codeOrganization = codeAccount.flatMap { c in
            if let o = c.organizationID { return AccountID.normal(o) }
            let recordsTheSeat = answer.verdict == .guessed || (answer.verdict == .verified && answer.record != nil)
            return recordsTheSeat && c.organizationName == nil ? "" : nil
        }
        if e.claudeWindow, app.state == .known, let id = app.account.map(AccountID.normal) {
            let mine = ([e.seat] + e.standby.map(\.seat)).compactMap { $0 }.first { byID(id).sameAccount(AccountIdentity($0).withoutOrganization) }
            r.account = id
            r.email = mine?.email ?? (codeAccount.map { byID(id).sameAccount(known($0)) } == true ? (codeEmail ?? readName) : nil) ?? names[id]
            r.fromApp = true
            r.lit = true
        }
        // the numbers aren't the active account's: the reading's own account (a stale reading's: Claude Code's, whose they
        // will be after its read; with no reading, the status line's numbers: Claude Code's) against the active one, by the
        // ids where both are known, else the addresses
        // (a guarded reading is the record's account by its address: Claude Code's account stands for it)
        if let n = stale || guarded ? codeAccount : (reading ?? codeAccount), let same = sameAccount(account: r.account, email: r.email, n) {
            r.differs = !same
        }
        if r.differs, codeLabel != nil {
            // (the sentence is built when a surface shows it, ResolvedAccount.lineText: the record holds no address text and
            // the line follows Show emails; codeName is the account)
            r.codeUsageLine = true
        } else if stale {
            // the numbers are hidden (read for another account than Claude Code's now: just after a sign-in, or the Keychain's
            // sign-in left behind) and nothing else says why: the way back, on every surface that shows the line
            r.line = seatUnknown ? seatUnknownWords : staleWords
        } else if e.claudeWindow, !r.fromApp, codeAccount != nil {
            // short enough for the card at 340; only when Claude Code has an account to show
            r.line = "Claude app signed out: Claude Code's account shows."
        }
        // its record too large to read and no verified word naming the account: not known, and said so (never as signed out)
        if codeAccount == nil, recordTooLarge {
            r.recordTooLarge = true
            r.line = "Claude Code's .claude.json is too large to read: its account isn't known here."
        }
        // the split as a switch waiting for the Claude app: the newest switch went to Claude Code's account (the same
        // rule as Settings' Claude Code row, AccountSettings.switchTarget), and the app is still on the account it left
        // (a switch linked more than a day ago waits no more: then it's a split by hand)
        if r.fromApp, r.differs, let n = newestSwitch, let id = r.account,
           AccountSettings.switchTarget(goal: nil, newest: n, standby: [], code: codeLabel, codeAccount: r.codeAccount, now: now) != nil,
           byID(id).sameAccount(byID(n.from.account)), n.linkedLately(now: now) ?? true {
            r.switchWaits = true
        }
        return r
    }

    /// The line while the numbers are another account's than Claude Code's (stale): they are hidden, and this says the way
    /// back. True right after a sign-in (the new sign-in's first read is on its way) and when the Keychain's sign-in stays on
    /// another account than Claude Code's (only a sign-in helps then).
    static let staleWords = "Numbers for another account: if this stays, sign in to read again."

    /// The line while the numbers are Claude Code's account's but its seat isn't known yet (a running claude names its
    /// organisation by name, the reading by id alone, and no name has come to tell them apart): held back, never another
    /// account's, until a read brings the name.
    static let seatUnknownWords = "Numbers held back: which plan Claude Code is on isn't known yet."

    /// The active account (its id, its address) and an account a source names are the same: by the ids where both have
    /// one, else by the addresses (sameAddress); nil when neither pair is known.
    static func sameAccount(account: String?, email: String?, _ n: SignedInAccount) -> Bool? {
        if let a = account, let id = n.accountID { return byID(a).sameAccount(byID(id)) }
        if let a = email, let ne = n.email { return sameAddress(ne, a) }
        return nil
    }

    /// Two addresses (a reading's, an account's) name one account: the one owner rule's address-only part; with either
    /// empty, the plain comparison as before (two empty addresses are not "another account", so nothing goes stale).
    static func sameAddress(_ a: String, _ b: String) -> Bool {
        a.isEmpty || b.isEmpty ? a.lowercased() == b.lowercased() : AccountIdentity.address(a).sameAccount(.address(b))
    }

    /// An account as the Claude app's config.json and the status record name it: by its id only (neither names an
    /// organisation), compared by the one owner rule.
    static func byID(_ id: String?) -> AccountIdentity { AccountIdentity(account: id, email: nil, organization: nil, source: .verified) }

    /// An account as compared with one named by its id only: its organisation left out (one not known there isn't "none").
    static func known(_ a: SignedInAccount) -> AccountIdentity { AccountIdentity(account: a.accountID, email: a.email, organization: nil, source: .guessed) }
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

    /// The split by hand in two names only, the Claude app and Terminal: Settings ▸ Accounts' band headline, and the line on
    /// every surface that says it in full (Claude Code inside the Claude app runs on the app's own sign-in, so the app's
    /// account is the one in use; only Terminal's sign-in, the one cl_audit reads with, is on another). No address: the rows
    /// under it name the accounts. A switch waiting for the app, the card's words on every surface (Settings, menu bar,
    /// widget, Dock panel): "Switching to M@…: one step left. Sign the Claude app in to M@… to finish."
    var line: String { line(blur: nil) }
    /// `line` for a given "Show emails" setting (nil: the app's own): what a check hands in.
    func line(blur: Bool?) -> String {
        switched ? "\(Self.switchingHead(code, blur: blur)). Sign the Claude app in to \(AddressSettings.words(code, blur: blur)) to finish."
                 : Self.bandHead
    }
    /// Settings ▸ Accounts' amber band around both rows of the split: its amber headline and the two lines under it.
    static let bandHead = "The Claude app and Terminal are signed in to different accounts."
    static let bandWhy = "cl_audit can read usage only through Terminal's sign-in, so the Claude app's account shows no numbers."
    static let bandFix = "Use the key on either account to put both on the same account."
    /// The one amber line on the dashboard card, the menu bar row and the Dock panel while the split is by hand: a link to
    /// the band.
    static let windowLine = "Claude window on another account"
    /// The keys of the band's two rows: on Terminal's account (it opens the Switch page) and on the Claude app's (Terminal's
    /// own sign-in, the app's address filled in when known).
    static let appSignInKey = "Sign the app in"
    static let terminalSignInKey = "Sign Terminal in"
    /// The Dock panel's compact key in the split: Terminal's sign-in to the window's account.
    static let panelSignInKey = "Sign in"
    /// In place of "Sign Terminal in" while the Claude app's account is known by its id only (no address to sign in to).
    static let appUnknownWords = "Open the Claude window once, so cl_audit learns its account."
    /// The short form where space is short: a switch waiting for the app, its first clause, "Switching to M@…: one step
    /// left"; the split by hand, the line itself (the surfaces short of room draw the amber link in its place).
    var shortLine: String { switched ? Self.switchingHead(code) : line }
    /// The after-switch heading, the same on the card (UsageNotice) and every other surface.
    static func switchingHead(_ to: String, blur: Bool? = nil) -> String { "Switching to \(AddressSettings.words(to, blur: blur)): one step left" }
    /// Under the line, in place of "No numbers yet": what gives the numbers. Nil while a switch waits for the app (nothing
    /// to sign in to then).
    var numbersHint: String? {
        // (no address in a sentence: "the Claude app's account" names it)
        switched ? nil : "Sign Terminal in to the Claude app's account to see its numbers."
    }
    /// The key: the existing Sign in (Claude Code's own sign-in in Terminal, with the app's address filled in), the Claude
    /// app's row's key in Settings ▸ Accounts. Not a switch. None while a switch waits for the app, and none when the app's
    /// account is known by its id only: the key only ever fills in the app's own address (never Claude Code's), so then
    /// Settings says `appUnknownWords` instead.
    var key: String? { loginEmail.map { _ in Self.terminalSignInKey } }
    /// The address the login fills in: the app's own, when it is known (not while a switch waits for the app).
    var loginEmail: String? { !switched && app.contains("@") ? app : nil }
}

/// What every surface shows of a profile's account, from its status record only (never a file, a log or a seat).
struct AccountView: Equatable {
    var label: String?              // the active account: its address, or "account <8>"; nil: none known
    var numbersOwner: String?       // Claude Code's account, whose numbers they are (or will be, after a switch's first read)
    var lit: Bool                 // the green lamp and "in use"
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
    /// Claude Code's account's organisation (lower case; "" none; nil not known), where the record has it: with
    /// `codeAccount`, one seat (a personal plan and a Team seat share the account id).
    var codeOrganization: String? = nil

    /// The one line of state, built now (ResolvedAccount.lineText: an address in it follows Show emails as it is at this read).
    var line: String? { resolved?.lineText() }

    static func of(_ s: IconStatus?) -> AccountView {
        guard let s else { return AccountView(label: nil, numbersOwner: nil, lit: false) }
        if let r = s.resolved {
            return AccountView(label: r.email ?? r.account.map { "account \($0.prefix(8))" }, numbersOwner: r.codeName ?? r.numbersFor,
                               lit: r.lit, account: r.account, recordTooLarge: r.recordTooLarge == true,
                               differs: r.differs, codeAccount: r.codeAccount, resolved: r, codeOrganization: r.codeOrganization)
        }
        // a record from before the resolver (or none written yet): the sign-in it was read for
        let who = s.loginEmail ?? s.expectedEmail
        return AccountView(label: who, numbersOwner: who, lit: who != nil)
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
    /// account's.
    var codeRow: String? { differs ? numbersOwner : nil }

    /// This seat is Claude Code's account: its id, and its organisation (a personal plan and a Team seat share the id). Fails
    /// closed: with Claude Code's organisation not known there (nil: a seat not known, an older record), only a seat that
    /// names none itself is taken.
    func isCodeSeat(_ s: Seat) -> Bool {
        guard AccountID.same(codeAccount, s.account) else { return false }
        guard let o = codeOrganization else { return (s.organization ?? "").isEmpty }
        return AccountID.sameOrganization(o, s.organization)
    }

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
