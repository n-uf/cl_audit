// AccountList: the accounts a profile has, found on this Mac the way claude-transplant 4.2.1 finds them (transplant.js,
// logins() and accounts()), with no Add account: the union of (account, organisation) pairs from
//
// - the profile's Claude window: its data folder's claude-code-sessions/<account>/<org>/ and
//   local-agent-mode-sessions/<account>/<org>/ (with when a session was last written there);
// - the profile's Claude Code folder: its .claude.json oauthAccount and the backups Claude Code keeps of it
//   (<folder>/backups/.claude.json.backup*; for ~/.claude also ~/.claude.json.backup* and ~/.claude/backups/…);
// - the accountUuid in the folder's transcripts (the first 64 KB of each, at most 400 of them): an account id with no
//   organisation known is listed by its id alone;
// - for the profile on ~/.claude, also every ~/.claude* .claude.json and ~/.claude-switch/accounts/*/.claude.json
//   (claude-transplant reads them all for its one Claude app).
//
// Addresses and organisation names come from every oauthAccount block found (an organisationType that isn't team or
// enterprise is "Personal") and from the agent sessions' emailAddress; an account with none shows as "account <first 8>"
// until it is seen signed in. Only ids, dates and those named fields are read; never a token.
//
// A pair goes on a profile's standby list when no profile has it (in use or on standby: one account, one profile) and
// the profile didn't forget it (Forget…).
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

import Foundation

enum AccountList {
    /// What the oauthAccount blocks and agent sessions say, by id (claude-transplant's emails, orgs and pairs).
    struct Logins: Equatable {
        var emails: [String: String] = [:]       // account id → address
        var orgs: [String: String] = [:]         // organisation id → "Personal" or its name
        var plans: [String: String] = [:]        // account id → plan, as recorded
        var pairs: [SeatID] = []                 // every account/organisation pair seen in a block, in order

        mutating func take(claudeJSON path: String) {
            // bounded and non-blocking, parsed again only when the file changed (SafeRead)
            guard let o = SafeRead.oauthAccount(path) else { return }
            take(oauthAccount: o)
        }

        mutating func take(oauthAccount o: [String: Any]) {
            let account = (o["accountUuid"] as? String)?.lowercased(), org = (o["organizationUuid"] as? String)?.lowercased()
            if let a = account, let e = o["emailAddress"] as? String, !e.isEmpty, emails[a] == nil { emails[a] = e }
            if let g = org, orgs[g] == nil,
               let w = AccountFacts.orgWords(type: o["organizationType"] as? String, name: o["organizationName"] as? String) { orgs[g] = w }
            if let a = account, plans[a] == nil, let p = o["planDisplayName"] as? String, !p.isEmpty { plans[a] = p }
            if let a = account, let g = org, AccountDiscovery.isUUID(a), AccountDiscovery.isUUID(g) {
                let s = SeatID(account: a, organization: g)
                if !pairs.contains(s) { pairs.append(s) }
            }
        }
    }

    /// The .claude.json files of one Claude Code folder and the backups Claude Code keeps of it.
    static func folderFiles(_ configDir: String, home: String = NSHomeDirectory()) -> [String] {
        let dir = expand(configDir)
        var out = [Account.claudeJSON(configDir: configDir)]
        func backups(_ d: String) {
            for n in ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).sorted() where n.hasPrefix(".claude.json.backup") {
                out.append((d as NSString).appendingPathComponent(n))
            }
        }
        backups((dir as NSString).appendingPathComponent("backups"))
        if Account.isDefault(configDir: configDir) { backups(home) }
        return out
    }

    /// Every ~/.claude* .claude.json and ~/.claude-switch/accounts/*/.claude.json (claude-transplant's logins()).
    static func homeFiles(home: String = NSHomeDirectory()) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for n in ((try? fm.contentsOfDirectory(atPath: home)) ?? []).sorted() where n.hasPrefix(".claude") {
            let p = (home as NSString).appendingPathComponent(n)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            out.append(isDir.boolValue ? (p as NSString).appendingPathComponent(".claude.json") : p)
        }
        let sw = (home as NSString).appendingPathComponent(".claude-switch/accounts")
        for n in ((try? fm.contentsOfDirectory(atPath: sw)) ?? []).sorted() {
            out.append((sw as NSString).appendingPathComponent("\(n)/.claude.json"))
        }
        return out
    }

    /// A Claude window's pairs, with when a session was last written under each: claude-code-sessions and
    /// local-agent-mode-sessions (whose records may name the address: `logins` takes it).
    static func windowPairs(dataDir: String, logins: inout Logins) -> [(seat: SeatID, used: Date?)] {
        let fm = FileManager.default
        var out: [(SeatID, Date?)] = []
        for (kind, readsEmail) in [("claude-code-sessions", false), ("local-agent-mode-sessions", true)] {
            let root = (expand(dataDir) as NSString).appendingPathComponent(kind)
            for a in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() where AccountDiscovery.isUUID(a) {
                let adir = (root as NSString).appendingPathComponent(a)
                for o in ((try? fm.contentsOfDirectory(atPath: adir)) ?? []).sorted() where AccountDiscovery.isUUID(o) {
                    let odir = (adir as NSString).appendingPathComponent(o)
                    let files = ((try? fm.contentsOfDirectory(atPath: odir)) ?? []).filter { $0.hasSuffix(".json") }
                    let dates = files.compactMap { (try? fm.attributesOfItem(atPath: (odir as NSString).appendingPathComponent($0)))?[.modificationDate] as? Date }
                    let s = SeatID(account: a.lowercased(), organization: o.lowercased())
                    if let i = out.firstIndex(where: { $0.0 == s }) { out[i].1 = [out[i].1, dates.max()].compactMap { $0 }.max() }
                    else { out.append((s, dates.max())) }
                    if readsEmail, logins.emails[s.account] == nil {
                        for f in files.prefix(50) {
                            guard let j = SafeRead.jsonObject((odir as NSString).appendingPathComponent(f), max: SafeRead.recordMax),
                                  let e = j["emailAddress"] as? String, !e.isEmpty else { continue }
                            logins.emails[s.account] = e
                            break
                        }
                    }
                }
            }
        }
        return out
    }

    /// The account ids the folder's transcripts name ("accountUuid":"<uuid>"), from the first 64 KB of each, at most `cap`
    /// transcripts, newest first.
    static func transcriptAccounts(configDir: String, cap: Int = 400) -> Set<String> {
        let fm = FileManager.default
        let projects = (expand(configDir) as NSString).appendingPathComponent("projects")
        var files: [(String, Date)] = []
        for p in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
            let dir = (projects as NSString).appendingPathComponent(p)
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".jsonl") {
                let f = (dir as NSString).appendingPathComponent(n)
                files.append((f, ((try? fm.attributesOfItem(atPath: f))?[.modificationDate] as? Date) ?? .distantPast))
            }
        }
        let re = try! NSRegularExpression(pattern: #""accountUuid"\s*:\s*"([0-9a-fA-F-]{36})""#)
        var out: Set<String> = []
        for (f, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(cap) {
            guard let head = SafeRead.read(f, max: 64 << 10)?.data else { continue }   // a FIFO or device: skipped at once
            let s = String(decoding: head, as: UTF8.self)
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                if let r = Range(m.range(at: 1), in: s), AccountDiscovery.isUUID(String(s[r])) { out.insert(s[r].lowercased()) }
            }
        }
        return out
    }

    /// "ultra-2@example.com · Personal", or "account 1a2b3c4d" for an account with no address known.
    static func label(_ s: Seat, _ l: Logins) -> String {
        guard let e = s.email ?? l.emails[s.account.lowercased()] else { return "account \(s.account.prefix(8))" }
        return [e, s.organization.flatMap { l.orgs[$0.lowercased()] }].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: the profiles' lists

    /// Where each profile's accounts were found: its window's pairs (with when last used), its folder's and its
    /// transcripts' accounts. Read off the main thread (the agent's look and the settings app's).
    struct Found: Equatable {
        var logins = Logins()
        var window: [String: [SeatID: Date]] = [:]       // profile id → pair → last used (distantPast: unknown)
        var folder: [String: [SeatID]] = [:]
        var transcripts: [String: Set<String>] = [:]
    }

    static func find(_ accounts: [AccountEntry], home: String = NSHomeDirectory()) -> Found {
        var f = Found()
        // the addresses and organisations: every file claude-transplant reads, and each profile's own folder and backups
        for p in homeFiles(home: home) { f.logins.take(claudeJSON: p) }
        for e in accounts { for p in folderFiles(e.configDir, home: home) { f.logins.take(claudeJSON: p) } }
        for e in accounts {
            var one = Logins()
            for p in folderFiles(e.configDir, home: home) { one.take(claudeJSON: p) }
            if Account.isDefault(configDir: e.configDir) { for p in homeFiles(home: home) { one.take(claudeJSON: p) } }
            f.folder[e.id] = one.pairs
            if e.claudeWindow {
                let dir = e.desktop == .standard ? expand(FolderKey.standardDataDir) : (Account(e).claudeUserDataDir ?? "")
                if !dir.isEmpty {
                    var w: [SeatID: Date] = [:]
                    for (s, used) in windowPairs(dataDir: dir, logins: &f.logins) { w[s] = used ?? .distantPast }
                    f.window[e.id] = w
                }
            }
            f.transcripts[e.id] = transcriptAccounts(configDir: e.configDir)
        }
        return f
    }

    /// The profiles with every account found for them that no profile has yet, on standby (never one forgotten there).
    /// The address, plan and when it was last used come with it where known. Nothing else changes.
    static func adding(_ found: Found, to accounts: [AccountEntry], now: Date = Date()) -> [AccountEntry] {
        var out = accounts
        func taken(_ s: Seat) -> Bool { out.contains { $0.has(s) } }
        for i in out.indices {
            let e = out[i]
            var candidates: [(SeatID, Date?)] = (found.window[e.id] ?? [:]).sorted { $0.value > $1.value }
                .map { ($0.key, $0.value == .distantPast ? nil : $0.value) }
            candidates += (found.folder[e.id] ?? []).map { ($0, nil) }
            // a transcript's account id with no organisation seen anywhere: by its id alone
            let known = Set(candidates.map(\.0.account) + found.logins.pairs.map(\.account))
            candidates += (found.transcripts[e.id] ?? []).subtracting(known).sorted().map { (SeatID(account: $0, organization: ""), nil) }
            for (s, used) in candidates {
                let email = found.logins.emails[s.account]
                let seat = Seat(account: s.account, organization: s.organization.isEmpty ? nil : s.organization, email: email)
                guard !taken(seat), !out[i].forgotten.contains(key(s)) else { continue }
                // an account id alone is taken by a profile that has that account in any organisation
                if s.organization.isEmpty, out.contains(where: { $0.seats.contains { $0.account.lowercased() == s.account } }) { continue }
                // last in use: when this profile's window last wrote a session under it
                out[i].standby.append(StandbyAccount(email: email ?? "", seat: seat, addedAt: now, plan: found.logins.plans[s.account],
                                                     lastInUse: used.flatMap { AccountBook.sane($0, now: now) }))
            }
        }
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
        var l = Logins()
        for p in homeFiles() { l.take(claudeJSON: p) }
        for p in folderFiles("~/.claude") { l.take(claudeJSON: p) }
        namesMemo = (now, l.emails)
        return l.emails
    }
}

extension StandbyAccount {
    /// Its address, or "account <first 8>" while none is known (found by its id only).
    var label: String { email.isEmpty ? "account \(seat?.account.prefix(8) ?? id.prefix(8))" : email }
}
