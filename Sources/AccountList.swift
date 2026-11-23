// AccountList: the accounts a profile has, found on this Mac the way claude-transplant 4.2.1 finds them (transplant.js,
// logins() and accounts()), with no Add account: the union of (account, organisation) pairs from
//
// - the profile's Claude window: its data folder's claude-code-sessions/<account>/<org>/ and
//   local-agent-mode-sessions/<account>/<org>/ (with when a session was last written there);
// - the profile's Claude Code folder: its .claude.json oauthAccount and the backups Claude Code keeps of it, by Claude
//   Code's own names (.claude.json.backup, or .claude.json.backup.<digits>) in <folder>/backups/; for ~/.claude also in
//   the home folder;
// - the accountUuid in the folder's transcripts (the first 64 KB of each, at most 400 of them): an account id with no
//   organisation known is listed by its id alone;
// - for the profile on ~/.claude, also every ~/.claude* .claude.json and ~/.claude-switch/accounts/*/.claude.json
//   (claude-transplant reads them all for its one Claude app).
//
// Addresses and organisation names come from every oauthAccount block found (an organisationType that isn't team or
// enterprise is "Personal") and from the agent sessions' emailAddress; an account with none shows as "account <first 8>"
// until it is seen signed in. Only ids, dates and those named fields are read; never a token.
//
// Each of those sources is cl_kit's (ClaudeAuth's Discovery.swift and DiscoveryApp.swift: AccountSources.folderRecordFiles,
// homeRecordFiles, records, appSessions, transcriptAccounts; FoundAccounts puts them together), with its bounds (no link
// followed out of a folder, a FIFO or a device never waited on, records and heads read capped). This file picks the sources
// each profile reads and does the listing.
//
// A pair goes on a profile's standby list when no profile has it (in use or on standby) and the profile didn't forget it
// (Forget…). An account may be several profiles' (shared seats), but only by a sign-in in that profile: what is found here
// never adds another profile's account by itself (the ~/.claude profile reads every ~/.claude* record, so it would collect
// every profile's account).
//
// Adapted from claude-transplant, Copyright (c) 2026 Vitaliy Hayda, under the MIT License:
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
//   documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
//   rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
//   permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright
//   notice and this permission notice shall be included in all copies or substantial portions of the Software.
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
//   WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
//   COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
//   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import ClaudeAuth
import Foundation
import ProfileCore

enum AccountList {
    // (the sources are cl_kit's, ClaudeAuth's Discovery: AccountSources' functions, each giving FoundAccount sightings, put
    // together by FoundAccounts. What is cl_audit's here: which sources a profile reads, which profile an account goes to,
    // what is forgotten, and the words.)

    /// The records in `paths` (their oauthAccount blocks), read through ClaudeFiles' cached, bounded reader.
    static func records(_ paths: [String]) -> [FoundAccount] { AccountSources.records(paths, read: ClaudeFiles.oauthBlock(at:)) }

    /// A profile's Claude Code folder, as the kit's sources take it.
    static func folder(_ configDir: String, home: String) -> AuthFolder {
        AuthFolder(path: configDir, isDefault: Account.isDefault(configDir: configDir), home: home)
    }

    /// "ultra-2@example.com · Personal", or "account 1a2b3c4d" for an account with no address known.
    static func label(_ s: Seat, _ l: FoundAccounts) -> String {
        guard let e = s.email ?? l.emails[AccountID.normal(s.account)] else { return "account \(s.account.prefix(8))" }
        return [e, s.organization.flatMap { l.orgWords(AccountID.normal($0)) }].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: the profiles' lists

    /// Where each profile's accounts were found: its window's pairs (with when last used), its folder's and its
    /// transcripts' accounts. Read off the main thread (the agent's look and the settings app's).
    struct Found: Equatable {
        /// What the records (every ~/.claude* one and each profile's folder and backups) say, by id; plus the addresses the
        /// windows' agent sessions name. Its seats are the records' own (never a window's folders).
        var logins = FoundAccounts()
        var window: [String: [SeatID: Date]] = [:]       // profile id → pair → last used (distantPast: unknown)
        var folder: [String: [SeatID]] = [:]
        var transcripts: [String: Set<String>] = [:]
    }

    static func find(_ accounts: [AccountEntry], home: String = NSHomeDirectory()) -> Found {
        var f = Found()
        // the addresses and organisations: every file claude-transplant reads, and each profile's own folder and backups
        let homeRecords = records(AccountSources.homeRecordFiles(home: home))
        f.logins.add(homeRecords)
        let folderRecords = accounts.map { records(AccountSources.folderRecordFiles(folder($0.configDir, home: home))) }
        folderRecords.forEach { f.logins.add($0) }
        for (e, own) in zip(accounts, folderRecords) {
            var one = FoundAccounts(own)
            if Account.isDefault(configDir: e.configDir) { one.add(homeRecords) }
            f.folder[e.id] = one.seats
            if e.claudeWindow {
                let dir = e.desktop == .standard ? expand(FolderKey.standardDataDir) : (Account(e).claudeUserDataDir ?? "")
                if !dir.isEmpty {
                    // its session folders (an agent session's record opened only for an account whose address isn't known yet)
                    let sessions = AccountSources.appSessions(dataDir: dir, knownAccounts: Set(f.logins.emails.keys))
                    var w: [SeatID: Date] = [:]
                    for s in sessions {
                        if f.logins.emails[s.accountID] == nil, let a = s.email { f.logins.emails[s.accountID] = a }
                        guard let seat = s.seat else { continue }
                        w[seat] = max(w[seat] ?? .distantPast, s.lastUsed ?? .distantPast)
                    }
                    f.window[e.id] = w
                }
            }
            f.transcripts[e.id] = Set(AccountSources.transcriptAccounts(folder: folder(e.configDir, home: home)).map(\.accountID))
        }
        return f
    }

    /// The profiles with every account found for them that no profile has yet, on standby (never one forgotten there).
    /// The address, plan and when it was last used come with it where known. Nothing else changes, but for a standby
    /// entry's organisation not known before (filled in once it is).
    ///
    /// One entry per account (its id), never one per account/organisation pair: the window's session folders can hold
    /// one account under several organisations (folders a move left behind, not memberships). Its organisation is the one
    /// its own oauthAccount record names (any .claude.json or backup read), else that of its newest-used
    /// claude-code-sessions/<account>/<org> folder; other pairs of it are ignored. An account any profile has, in use or
    /// on standby, in any organisation, is never added by itself (never twice in one profile, and another profile's only by
    /// a sign-in: shared seats); nor one forgotten here.
    static func adding(_ found: Found, to accounts: [AccountEntry], now: Date = Date()) -> [AccountEntry] {
        var out = accounts
        func taken(_ account: String) -> Bool { out.contains { $0.seats.contains { $0.account.lowercased() == account } } }
        // the organisation each account's own record names
        var recordOrg: [String: String] = [:]
        for p in found.logins.seats where recordOrg[p.account] == nil { recordOrg[p.account] = p.organization }
        for i in out.indices {
            let e = out[i]
            let window = found.window[e.id] ?? [:]
            for p in found.folder[e.id] ?? [] where recordOrg[p.account] == nil { recordOrg[p.account] = p.organization }
            // the accounts, newest-used window ones first, then the folder's, then a transcript's id alone
            var order: [String] = []
            func add(_ a: String) { if !order.contains(a) { order.append(a) } }
            window.sorted { $0.value > $1.value }.forEach { add($0.key.account) }
            (found.folder[e.id] ?? []).forEach { add($0.account) }
            (found.transcripts[e.id] ?? []).sorted().forEach { add($0) }
            for a in order {
                guard !taken(a), !out[i].forgotten.contains(where: { $0.hasPrefix(a + "/") }) else { continue }
                // its organisation: its record's, else its newest-used session folder's; a transcript's id alone has none
                let newest = window.filter { $0.key.account == a }.max { $0.value < $1.value }
                let org = recordOrg[a] ?? newest?.key.organization
                // last in use: when this profile's window last wrote a session under that pair
                let used = org.flatMap { window[SeatID(account: a, organization: $0)] }.flatMap { $0 == .distantPast ? nil : $0 }
                let email = found.logins.emails[a]
                let seat = Seat(account: a, organization: org, email: email)
                out[i].standby.append(StandbyAccount(email: email ?? "", seat: seat, addedAt: now, plan: found.logins.plans[a],
                                                     lastInUse: used.flatMap { AccountBook.sane($0, now: now) }))
            }
        }
        // a standby entry whose organisation isn't known yet (added from a transcript's id alone, or remembered before it
        // was): filled in once it is, by the same rule (its record's, else its newest-used session folder's in this
        // profile's window). Only a missing one, nil or "" (not known, as StandbyTidy reads it); a known one is never changed.
        // ("" on a standby entry means "not known" here, no longer "none, leave it": a move writes a missing organisation as "".)
        for i in out.indices {
            let window = found.window[out[i].id] ?? [:]
            for j in out[i].standby.indices {
                guard let s = out[i].standby[j].seat, (s.organization ?? "").isEmpty else { continue }
                let a = s.account.lowercased()
                guard let org = recordOrg[a] ?? window.filter({ $0.key.account == a }).max(by: { $0.value < $1.value })?.key.organization,
                      !org.isEmpty else { continue }
                out[i].standby[j].seat?.organization = org
                // cl_kit's saved-key rule (AccountKey.upgraded, `seatOfTheNumbers`): a seat that wasn't known takes an
                // organisation for its numbers only from the numbers' own source. A record or a window folder isn't that
                // source, so the week kept on the entry (read while it was in use, its seat not named then: maybe the other
                // seat on its address) isn't moved onto the seat found; it goes, and the next time in use reads it again
                out[i].standby[j].lastWeek = nil
                out[i].standby[j].lastWeekResets = nil
            }
        }
        return out
    }

    /// The organisation each account's own oauthAccount record names, from every .claude.json and backup `find` reads
    /// for these profiles (bounded reads; used only when a standby list needs tidying).
    static func recordOrgs(_ accounts: [AccountEntry], home: String = NSHomeDirectory()) -> [String: String] {
        var l = FoundAccounts(records(AccountSources.homeRecordFiles(home: home)))
        for e in accounts { l.add(records(AccountSources.folderRecordFiles(folder(e.configDir, home: home)))) }
        var out: [String: String] = [:]
        for p in l.seats where out[p.account] == nil { out[p.account] = p.organization }
        return out
    }

    /// The key Forget… keeps: "<account>/<organisation>".
    static func key(_ s: SeatID) -> String { "\(s.account.lowercased())/\(s.organization.lowercased())" }
    static func key(_ s: Seat) -> String { key(SeatID(s)) }

    /// Addresses by account id, from every file `find` reads (kept a minute: for the words that name an account).
    private static var namesMemo: (at: Date, names: [String: String])?
    private static let namesLock = NSLock()
    static func names(now: Date = Date()) -> [String: String] {
        namesLock.lock(); defer { namesLock.unlock() }
        if let m = namesMemo, now.timeIntervalSince(m.at) < 60 { return m.names }
        let home = NSHomeDirectory()
        var l = FoundAccounts(records(AccountSources.homeRecordFiles(home: home)))
        l.add(records(AccountSources.folderRecordFiles(folder("~/.claude", home: home))))
        namesMemo = (now, l.emails)
        return l.emails
    }
}

extension FoundAccounts {
    /// An organisation in cl_audit's words: "Personal" for a type that isn't team or enterprise, else its name
    /// (AccountFacts.orgWords), from the one record that named it first.
    func orgWords(_ organization: String) -> String? {
        AccountFacts.orgWords(type: organizationTypes[organization], name: organizationNames[organization])
    }
}

extension StandbyAccount {
    /// Its address, or "account <first 8>" while none is known (found by its id only).
    var label: String { email.isEmpty ? "account \(seat?.account.prefix(8) ?? id.prefix(8))" : email }
}
