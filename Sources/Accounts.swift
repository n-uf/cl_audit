// Accounts: a profile works on one Claude account at a time and may keep others, so it can switch to one when a limit
// is full (Settings ▸ a profile ▸ Claude Code ▸ Accounts). The one in use is the profile's `seat`, signed in in its
// Claude Code folder; the others wait in `standby`, each with its limits read from a sign-in kept in a small folder of
// its own. cl_audit never copies or moves a sign-in: each folder's sign-in is Claude Code's own, made in Terminal.
//
// Here: what a standby account is, what Claude Code recorded about a folder's account (no tokens), the entry the agent
// reads a standby account's limits with, the accounts Add account finds on this Mac, and the folder a new sign-in goes in.

import Foundation

/// One of a profile's other accounts.
struct StandbyAccount: Codable, Equatable, Hashable, Identifiable {
    var id: String                 // short and fixed: names its saved status (status/<profile>~<id>.json)
    var email: String              // as found or typed; shown
    var seat: Seat?                // the account and organisation, once a sign-in or the window's records said
    var configDir: String?         // the Claude Code folder that keeps its sign-in (its limits come from it); nil: none kept
    var addedAt: Date?
    var plan: String?              // Claude's own name for its plan ("Ultra"), as last seen in use
    var lastInUse: Date?           // when it was last the profile's account in use (it left the folder then); nil: never here
    /// Its week as last read while it was in use, and when that week starts again: kept to pick which standby account a
    /// full limit offers (AccountBook.offerOrder), never shown. A standby account isn't read.
    var lastWeek: Double?
    var lastWeekResets: Date?

    init(email: String, seat: Seat? = nil, configDir: String? = nil, addedAt: Date? = Date(), id: String = StandbyAccount.newID(),
         plan: String? = nil, lastInUse: Date? = nil, lastWeek: Double? = nil, lastWeekResets: Date? = nil) {
        self.id = id; self.email = email; self.seat = seat; self.configDir = configDir; self.addedAt = addedAt
        self.plan = plan; self.lastInUse = lastInUse; self.lastWeek = lastWeek; self.lastWeekResets = lastWeekResets
    }

    static func newID() -> String { String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(8)) }

    /// Known to be full: its week was full when it was last read, and that week hasn't started again yet.
    func knownFull(now: Date = Date()) -> Bool {
        guard let w = lastWeek, AtLimit.isFull(w) else { return false }
        return (lastWeekResets ?? .distantFuture) > now
    }
}

/// The bookkeeping of a profile's accounts that needs nothing but its records (cl_quick's AccountBook): what a switch
/// says it affects, how long ago, and which standby account to offer first.
enum AccountBook {
    /// What a switch affects, for the Switch page: Claude Code on the folder (in Terminal and editors for ~/.claude, the
    /// uses pointed at it with CLAUDE_CONFIG_DIR for any other), sessions running now included; not the Claude app, which
    /// runs its own claude with its own sign-in. `email` as it should be shown (masked where the caller masks).
    static func switchWords(folder: String, email: String, isDefault: Bool) -> String {
        (isDefault ? "Claude Code in Terminal and editors on \(folder)" : "Claude Code pointed at \(folder) with CLAUDE_CONFIG_DIR")
            + " moves to \(email), sessions running now included; the Claude app keeps its own sign-in."
            + " Finish the sign-in in Terminal and the browser as that account."
    }

    /// "just now", "12 min ago", "3 h ago", "yesterday", "4 days ago", "3 weeks ago".
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(s / 60)) min ago"
        case ..<86400: return "\(Int(s / 3600)) h ago"
        case ..<(2 * 86400): return "yesterday"
        case ..<(14 * 86400): return "\(Int(s / 86400)) days ago"
        default: return "\(Int(s / (7 * 86400))) weeks ago"
        }
    }

    /// "On standby · Ultra · last in use 3 days ago": a standby account's line. No usage: it isn't read.
    static func standbyWords(_ s: StandbyAccount, now: Date = Date()) -> String {
        (["On standby", s.plan.map(Account.planWords), s.lastInUse.map { "last in use " + ago($0, now: now) }]).compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The standby accounts in the order a full limit offers them (cl_quick's rule): those not known to be full first, the
    /// least used first by their week as last read (one never read here counts as unknown, after those read), then the most
    /// recently in use; those known to be full last. Only accounts with a seat can be switched to; the others come at the
    /// end, in the profile's order.
    static func offerOrder(_ list: [StandbyAccount], now: Date = Date()) -> [StandbyAccount] {
        list.enumerated().sorted { a, b in
            func rank(_ s: StandbyAccount) -> Int { s.seat == nil ? 2 : s.knownFull(now: now) ? 1 : 0 }
            let (x, y) = (a.element, b.element)
            if rank(x) != rank(y) { return rank(x) < rank(y) }
            // a week that started again since it was read counts as empty
            func used(_ s: StandbyAccount) -> Double {
                guard let w = s.lastWeek else { return 101 }
                return (s.lastWeekResets.map { $0 <= now } ?? false) ? 0 : w
            }
            if used(x) != used(y) { return used(x) < used(y) }
            let (p, q) = (x.lastInUse ?? .distantPast, y.lastInUse ?? .distantPast)
            return p != q ? p > q : a.offset < b.offset
        }.map(\.element)
    }

    /// The one to offer while a limit is full: the first that isn't known to be full and can be switched to, or nil.
    static func best(_ list: [StandbyAccount], now: Date = Date()) -> StandbyAccount? {
        offerOrder(list, now: now).first { $0.seat != nil && !$0.knownFull(now: now) }
    }
}

/// An account that moved between two profiles by signing in to another one's folder (FolderRules.noteAccounts).
struct AccountNote: Codable, Equatable, Hashable {
    enum Kind: String, Codable { case came, left }
    var kind: Kind
    var email: String              // the account; shown masked as Settings ▸ General ▸ Emails says
    var profile: String            // the other profile's name
    var at: Date

    /// "ultra-3 came from Work's standby accounts: it signed in to this profile's folder." / "ultra-3 left for Main: it
    /// signed in to Main's folder, so it's Main's account now."
    var words: String {
        let a = Privacy.masked(email.isEmpty ? "An account" : email)
        switch kind {
        case .came: return "\(a) came from \(profile)'s standby accounts: it signed in to this profile's folder."
        case .left: return "\(a) left for \(profile): it signed in to \(profile)'s folder, so it's \(profile)'s account now."
        }
    }
}

/// One element of a list read on its own: nil when it can't be read, so the rest of the list still is.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension AccountEntry {
    /// The saved status of one of its standby accounts.
    static func standbyStatusID(_ profile: String, _ standby: String) -> String { "\(profile)~\(standby)" }
    var standbyStatusIDs: [String] { standby.map { Self.standbyStatusID(id, $0.id) } }

    /// The entry the agent reads a standby account's limits with: this profile with that account's folder and seat, and
    /// nothing a profile does besides reading: no alerts, Dock icon, menu bar icon or window. Its sign-in is renewed while
    /// its folder is there (when it runs out all the same, its box says when it was last read), and it is read only while
    /// its folder is signed in to that account (the reader holds back numbers for any other). nil while no sign-in is kept for it, or while its seat isn't linked yet (a folder
    /// signed in to an account it can't be, the profile's own or another profile's, is never read).
    func readerEntry(for s: StandbyAccount) -> AccountEntry? {
        // a kept folder that isn't there (deleted) is never read: its reader would renew a sign-in for a folder the person
        // removed, and Claude Code would make it again. A link to a folder is read; only launching refuses links (FolderGuard)
        guard let dir = s.configDir, !dir.isEmpty, s.seat != nil, FolderGuard.isFolder(dir) else { return nil }
        var r = self
        r.id = Self.standbyStatusID(id, s.id)
        r.configDir = dir
        r.seat = s.seat
        // renewed while its folder is there (FolderGuard stops any renew for a folder that isn't); when its kept sign-in runs
        // out all the same, its box says when it was last read, with Sign in again
        r.notify = false; r.notifyBack = false; r.autoRenew = true
        r.iconHidden = true; r.claudeWindow = false; r.menuBar = false
        r.standby = []
        r.keptFolder = nil                    // the profile's own account's folder: never this one's
        return r
    }

    /// The Claude Code folder the profile's numbers are read from: the account in use's own folder (keptFolder: signed in
    /// once, renewed by itself), once it's signed in to that account, so its limits stay live whatever the working folder
    /// is signed in to (a switch signs that one in again each time); else the working folder.
    var readingFolder: String {
        // the folder's .claude.json, read again only when it changes (it can be large; this is asked every beat)
        guard let k = keptFolder, !k.isEmpty, let s = seat, s.same(FolderFactsCache.facts(k)?.seat) else { return configDir }
        return k
    }

    /// The account in use has a folder of its own, signed in to it.
    var readsOwnFolder: Bool { readingFolder != configDir }

    /// The profile as its reader sees it: the same, reading from `readingFolder`.
    func readingEntry() -> AccountEntry {
        var r = self
        r.configDir = readingFolder
        return r
    }

    /// Every seat this profile has: the one in use and its standby accounts'.
    var seats: [Seat] { [seat].compactMap { $0 } + standby.compactMap(\.seat) }

    /// The profile has this seat, in use or standing by.
    func has(_ s: Seat?) -> Bool { s.map { x in seats.contains { x.same($0) } } ?? false }
}

/// What Claude Code recorded about the account a folder is signed in to (the oauthAccount block of its .claude.json):
/// enough to show and compare it. No sign-in: that's in the Keychain and isn't read here.
struct AccountFacts: Equatable {
    var seat: Seat
    var plan: String?              // Claude's own name ("Ultra"), when recorded
    var org: String?               // "Personal", or a team's name

    static func of(configDir: String) -> AccountFacts? { of(claudeJSON: Account.claudeJSON(configDir: configDir)) }

    static func of(claudeJSON path: String) -> AccountFacts? {
        guard let data = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = j["oauthAccount"] as? [String: Any] else { return nil }
        return of(oauthAccount: o)
    }

    static func of(oauthAccount o: [String: Any]) -> AccountFacts? {
        guard let account = o["accountUuid"] as? String, !account.isEmpty else { return nil }
        let plan = (o["planDisplayName"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return AccountFacts(seat: Seat(account: account, organization: o["organizationUuid"] as? String, email: o["emailAddress"] as? String),
                            plan: plan, org: orgWords(type: o["organizationType"] as? String, name: o["organizationName"] as? String))
    }

    /// A personal plan's organisation is "Personal" (Claude names it after the address); a team's has its own name.
    static func orgWords(type: String?, name: String?) -> String? {
        if let t = type?.lowercased(), !t.isEmpty, !t.contains("team"), !t.contains("enterprise") { return "Personal" }
        return name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }
}

/// An account Add account offers: found on this Mac, not yet one of the profile's.
struct FoundAccount: Identifiable, Equatable {
    var seat: Seat                 // its email is set
    var plan: String?
    var org: String?
    var folder: String?            // a Claude Code folder no profile uses that is signed in to it: its limits show at once
    var usedInWindow: Date?        // when this profile's Claude window last used it
    var owner: String?             // the profile that has it (shown dimmed)

    var id: String { seat.account + "/" + (seat.organization ?? "") }
    var email: String { seat.email ?? "" }
    var signedIn: Bool { folder != nil }

    // The pop-up's two lines are AddAccount.swift's (`second(profile:)`).

    /// "today", "this week", "in October", "in August 2025".
    static func whenUsed(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "today" }
        if now.timeIntervalSince(d) < 7 * 86400 { return "this week" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB")
        f.dateFormat = cal.component(.year, from: d) == cal.component(.year, from: now) ? "'in' MMMM" : "'in' MMMM yyyy"
        return f.string(from: d)
    }
}

enum AccountDiscovery {
    /// What Claude Code recorded about every account it knows on this Mac, by account id: each Claude Code folder's
    /// .claude.json and the backups Claude Code keeps of the usual one.
    static func knownFacts(home: String = NSHomeDirectory()) -> [String: AccountFacts] {
        var files = Detect.configFolders().map { Account.claudeJSON(configDir: $0.path) }
        files.append((home as NSString).appendingPathComponent(".claude.json.backup"))
        let backups = (home as NSString).appendingPathComponent(".claude/backups")
        for n in ((try? FileManager.default.contentsOfDirectory(atPath: backups)) ?? []).sorted() where n.hasPrefix(".claude.json.backup") {
            files.append((backups as NSString).appendingPathComponent(n))
        }
        var out: [String: AccountFacts] = [:]
        for f in files {
            guard let facts = AccountFacts.of(claudeJSON: f), facts.seat.email != nil else { continue }
            if out[facts.seat.account] == nil { out[facts.seat.account] = facts }
        }
        return out
    }

    /// The accounts a Claude window's data folder has used (its Code tab files sessions under <account>/<organisation>),
    /// with when it last did. Only ids and dates are read; no session is opened.
    static func windowSeats(dataDir: String) -> [(seat: Seat, used: Date?)] {
        let root = (expand(dataDir) as NSString).appendingPathComponent("claude-code-sessions")
        let fm = FileManager.default
        var out: [(Seat, Date?)] = []
        for a in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() where isUUID(a) {
            let adir = (root as NSString).appendingPathComponent(a)
            for o in ((try? fm.contentsOfDirectory(atPath: adir)) ?? []).sorted() where isUUID(o) {
                let odir = (adir as NSString).appendingPathComponent(o)
                let names = (try? fm.contentsOfDirectory(atPath: odir)) ?? []
                let dates = names.filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }.compactMap {
                    (try? fm.attributesOfItem(atPath: (odir as NSString).appendingPathComponent($0)))?[.modificationDate] as? Date
                }
                guard !dates.isEmpty else { continue }       // no session ever filed there: not an account it used
                out.append((Seat(account: a, organization: o, email: nil), dates.max()))
            }
        }
        return out
    }

    static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    /// What Add account lists for a profile: accounts signed in in Claude Code folders no profile uses (their limits show
    /// at once) and the accounts this profile's Claude window has used (they need a sign-in first), each once, by its
    /// seat; other profiles' accounts dimmed with their name. The profile's own accounts aren't listed. An account with
    /// no address known is left out (there'd be nothing to sign in as).
    static func found(for e: AccountEntry, among accounts: [AccountEntry],
                       facts: [String: AccountFacts] = knownFacts(),
                       folders: [FolderChoice] = Detect.configFolders(),
                       window: [(seat: Seat, used: Date?)]? = nil,
                       signedIn: (String) -> Seat? = Account.signedInSeat) -> [FoundAccount] {
        var byID: [String: FoundAccount] = [:]
        var order: [String] = []
        func add(_ f: FoundAccount) {
            if var old = byID[f.id] {
                old.folder = old.folder ?? f.folder
                old.usedInWindow = [old.usedInWindow, f.usedInWindow].compactMap { $0 }.max()
                old.plan = old.plan ?? f.plan; old.org = old.org ?? f.org
                byID[f.id] = old
            } else { byID[f.id] = f; order.append(f.id) }
        }
        // the profile's own folders, and any folder inside or around one of them, aren't offered
        let mine = [e.configDir] + e.standby.compactMap(\.configDir)
        for c in folders {
            guard let s = signedIn(c.path), s.email != nil, !mine.contains(where: { !$0.isEmpty && FolderKey.overlaps($0, c.path) }) else { continue }
            let f = AccountFacts.of(configDir: c.path)
            // a folder another profile uses: that profile's account (shown dimmed below, by its seat)
            let usedBy = FolderRules.configOwner(c.path, among: accounts, except: e.id)
            add(FoundAccount(seat: s, plan: f?.plan, org: f?.org, folder: usedBy == nil ? c.path : nil))
        }
        // the profile's own window folder (the usual Claude app's for the standard one); none set yet: no window history
        let windowDir: String? = e.desktop == .standard ? expand(FolderKey.standardDataDir) : Account(e).claudeUserDataDir
        for w in window ?? windowDir.map({ windowSeats(dataDir: $0) }) ?? [] {
            // the address from Claude Code's records, or from a folder signed in to that account just above
            let f = facts[w.seat.account]
            guard let email = f?.seat.email ?? byID.values.first(where: { $0.seat.account == w.seat.account })?.seat.email else { continue }
            var seat = w.seat
            seat.email = email
            let same = f.map { $0.seat.same(seat) } ?? false
            add(FoundAccount(seat: seat, plan: same ? f?.plan : nil, org: same ? f?.org : nil, folder: nil, usedInWindow: w.used))
        }
        var out: [FoundAccount] = []
        for id in order {
            guard var f = byID[id], !e.has(f.seat), !f.seat.same(signedIn(e.configDir)) else { continue }
            f.owner = FolderRules.seatOwner(f.seat, among: accounts, except: e.id)?.name
            if f.owner != nil { f.folder = nil }
            out.append(f)
        }
        // signed in first, then the window's by when it last used them, other profiles' last
        return out.enumerated().sorted { a, b in
            func rank(_ f: FoundAccount) -> Int { f.owner != nil ? 2 : f.signedIn ? 0 : 1 }
            if rank(a.element) != rank(b.element) { return rank(a.element) < rank(b.element) }
            let (x, y) = (a.element.usedInWindow ?? .distantPast, b.element.usedInWindow ?? .distantPast)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }
}

/// The small folder a standby account's sign-in is kept in: ~/.claude-<the address's first part>, numbered when that's
/// taken. Only Claude Code's own sign-in goes in it (made in Terminal); cl_audit reads it for the limits and renews it.
enum StandbyFolder {
    static func name(for email: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: expand($0)) }) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? "account"
        var slug = local.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "account" }
        let base = "~/.claude-\(slug)"
        if !exists(base) { return base }
        var n = 2
        while exists("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Makes the folder (only the owner can open it) and returns its path, or nil when it couldn't be made.
    static func make(for email: String) -> String? {
        let path = name(for: email)
        do {
            try FileManager.default.createDirectory(atPath: expand(path), withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            return path
        } catch { return nil }
    }
}
