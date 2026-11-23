// Switch: a profile working on another of its accounts (Accounts.swift), offered where a full limit shows (the dashboard
// card's at-limit box, the alert, the Dock and menu bar menus) and run on the Switch page
// (SwitchPage.swift, SwitchRunner.swift).
//
// Here: the standby accounts a profile can switch to, an account's short name, and what the Claude window's sidebar
// holds for an account, counted read-only from the window's own files (no session, title or group name is kept; the
// default-profile move uses it).

import AddressPrivacy
import Foundation
import ProfileCore

/// A standby account the profile could switch to. A standby account isn't read, so it has no limits: only what is
/// remembered of it (its plan, when it was last in use). Its kept week only orders the offers; it is never shown.
struct SwitchOffer {
    let profile: String
    let standby: StandbyAccount

    /// "<profile>~<standby>": names the page, the alert's action and the menu items.
    var key: String { AccountEntry.switchKey(profile, standby.id) }
    var short: String { AccountNames.short(standby.label) }
    /// Its week was full when it left, and hasn't started again yet.
    func knownFull(now: Date = Date()) -> Bool { standby.knownFull(now: now) }

    /// "Ultra · last used 3 days ago", or "on standby" (never "in use": the tick and the IN USE badge say that).
    func lineWords(now: Date = Date()) -> String {
        let parts = [standby.plan.map(Account.planWords), standby.lastInUse.map { "last used " + AccountBook.ago($0, now: now) }].compactMap { $0 }
        return parts.isEmpty ? "on standby" : parts.joined(separator: " · ")
    }

    static func parse(_ key: String) -> (profile: String, standby: String)? {
        let parts = key.split(separator: "~", maxSplits: 1).map(String.init)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty ? (parts[0], parts[1]) : nil
    }
}

extension AccountEntry {
    /// "<profile>~<standby id>": the Switch page for that account, as the menus, the alerts and the card name it.
    static func switchKey(_ profile: String, _ standby: String) -> String { "\(profile)~\(standby)" }

    /// The Switch page key's standby id for Claude Code's own account while the Claude app is on another one and no standby
    /// entry is it (codeTarget): a switch made elsewhere (cl_quick) put the folder on it, and only the Claude app is left.
    static let codeStandbyID = "claude-code"

    /// Claude Code's own account as a switch target, the finish line: Terminal's account whenever the record says the
    /// Claude app is on another (AccountView.codeRow) and no standby entry is it (then that entry is the target). Always
    /// offered, so the Terminal row's "Sign the Claude app in…" always opens the Switch page: when something the switch
    /// needs isn't known, the page says what (codeTargetMissing) and the switch refuses to start. Its seat is the folder's
    /// (the profile's seat) when that is Terminal's account, else none. A switch to it moves the Claude app's sessions to
    /// it; there is no sign-in to open.
    func codeTarget(_ v: AccountView) -> StandbyAccount? {
        guard let code = v.codeRow else { return nil }
        let s = seat.flatMap { AccountID.same(v.codeAccount, $0.account) ? $0 : nil }
        guard !standby.contains(where: { b in
            (b.seat?.email ?? b.email).lowercased() == code.lowercased() || (s.map { s in b.seat.map { $0.same(s) } ?? false } ?? false)
        }) else { return nil }
        return StandbyAccount(email: s?.email ?? code, seat: s, addedAt: nil, id: Self.codeStandbyID)
    }

    /// What a switch to Terminal's account (codeTarget) still needs to know, in one sentence, or nil when it can go: the
    /// folder's account with its organisation (the sessions' folder to move to), and the Claude app's own account with
    /// its organisation (the sessions' folder to move from), not Terminal's. The Switch page says it under the account,
    /// and the switch refuses with it.
    func codeTargetMissing(_ v: AccountView) -> String? {
        guard v.codeRow != nil else { return nil }
        guard let s = seat, s.organization != nil, AccountID.same(v.codeAccount, s.account) else { return Self.codeSeatMissingWords }
        guard let app = appSeat(v) else { return Self.appSeatMissingWords }
        return app.same(s) ? Self.sameAccountWords : nil
    }
    static let codeSeatMissingWords = "Terminal's account isn't fully known yet (its organisation), so there is no folder to move the sessions to. Refresh now, then try again."
    static let appSeatMissingWords = "The Claude app's account isn't known yet (its window's sign-in, with its organisation), so there are no sessions to move. Open the Claude window once, then try again."
    static let sameAccountWords = "The Claude app is on Terminal's account already: nothing to switch."

    /// How the Claude app's sign-in is read for a profile (its window's account and organisation); checks give their own.
    nonisolated(unsafe) static var appLogin: (AccountEntry) -> AppSignIn.Login = { AppSignIn.cached(for: $0) }

    /// The Claude app's account as a seat, the sessions' folder its window uses: the app's own sign-in (its account and
    /// organisation, never a standby entry's last organisation), when it is the active account the record names and one of
    /// the profile's standby accounts. nil when any of that isn't known.
    func appSeat(_ v: AccountView) -> Seat? {
        let l = Self.appLogin(self)
        guard l.state == .known, let a = l.account, let o = l.org, AccountID.same(v.account, a),
              let s = standby.first(where: { v.isActive($0) }) else { return nil }
        return Seat(account: a, organization: o, email: s.seat?.email ?? s.email)
    }

    /// Its standby accounts in the order a full limit offers them (AccountBook.offerOrder: not known to be full first, the
    /// least used by its last week, then the most recently in use).
    func switchOffers(now: Date = Date()) -> [SwitchOffer] {
        AccountBook.offerOrder(standby, now: now).map { SwitchOffer(profile: id, standby: $0) }
    }

    /// AccountBook.best over this entry's standby list as it is (fullOffer gives it the listed one: never the account in
    /// use); private, so no place picks over the raw list again.
    private func bestOffer(now: Date = Date()) -> SwitchOffer? {
        AccountBook.best(standby, now: now).map { SwitchOffer(profile: id, standby: $0) }
    }

    /// THE offer while a limit is full, for every place that makes one (the full-limit alert; the menus pick
    /// the same through SwitchMenu.best): AccountBook.best over the standby list as the account answer lists it, so never
    /// the account in use, matched by its id or its address (AccountView.isActive). An account remembered by its address
    /// only is never it; no numbers are read for it. `view`: the account answer when the caller has a newer one than the
    /// saved record (the agent's reader, before it saves).
    func fullOffer(view: AccountView? = nil, now: Date = Date()) -> SwitchOffer? {
        listed(by: view ?? AccountView.of(Store.status(for: self, now: now))).bestOffer(now: now)
    }
}

enum AccountNames {
    /// An account's short name: its address before the @ ("ultra-2") while addresses are shown, and "hidden address" while they
    /// are hidden, the same for every account (AddressPrivacy.short: nothing of the address, not its first letter). A text that
    /// is no address or id ("its account", "another account") is as it is. A menu row that must tell hidden accounts apart is
    /// drawn with AddressMenuRow instead of from this text.
    static func short(_ email: String) -> String { AddressSettings.hides(email) ? AddressPrivacy.short(address: email) : email }

    /// The same for a given "Show emails" setting (what a check hands in: never the real preference).
    static func shortName(_ email: String, shown: Bool) -> String {
        AddressSettings.hides(email) ? AddressText.short(address: email, blur: !shown) : email
    }
}

/// What the Claude window's Code sidebar holds for one account: counted from its data folder, read-only. The entries'
/// folder for the account, the sidebar's mirror in claude_desktop_config.json (its sections and groups; only those keys
/// are read: the same file holds MCP settings, which may carry secrets), and its scheduled tasks. Pins live only in the
/// window's own storage and aren't counted.
struct SidebarCounts: Equatable {
    var sessions = 0               // in the sidebar (not archived)
    var archived = 0
    var sections = 0               // shown, built-in and own
    var groups = 0
    var tasks = 0

    /// For `account` in the window whose data folder is `dataDir`; nil when the window has nothing for it.
    static func read(dataDir: String, account: String) -> SidebarCounts? {
        let dir = expand(dataDir)
        let prefs = sidebarPrefs(dataDir: dir)
        // the organisation the sidebar was set up for, else the one with the most sessions (ClaudeFiles' rule for both)
        let scopes = ClaudeFiles.sessionScopes(dataDir: dir, account: account)
        let entries = Dictionary(uniqueKeysWithValues: scopes.map { ($0.organization, ClaudeFiles.sessionEntries(in: $0.path).map(\.name)) })
        let orgs = scopes.map(\.organization)
        let scoped = orgs.first { prefs.scopes.contains("\(account)/\($0)") }
        let org = scoped ?? orgs.max { entries[$0, default: []].count < entries[$1, default: []].count }
        guard let org, let odir = scopes.first(where: { $0.organization == org })?.path else { return nil }
        var c = SidebarCounts()
        // an entry can be large (it carries the account's connector list): only its "isArchived" is looked for
        let archived = [Data(#""isArchived":true"#.utf8), Data(#""isArchived" : true"#.utf8), Data(#""isArchived": true"#.utf8)]
        for f in entries[org, default: []] {
            // bounded, never blocking (SafeRead): a FIFO named like an entry can't hold up the Switch page
            let d = SafeRead.whole((odir as NSString).appendingPathComponent(f), max: SafeRead.entryMax) ?? Data()
            if archived.contains(where: { d.range(of: $0) != nil }) { c.archived += 1 } else { c.sessions += 1 }
        }
        let scope = "\(account)/\(org)"
        c.sections = prefs.sections[scope] ?? 0
        c.groups = prefs.groups[scope] ?? 0
        if let j = TaskRegistry.registry(odir) {
            c.tasks = (j["scheduledTasks"] as? [Any])?.count ?? 0
        }
        return c
    }

    /// The sidebar's mirror: per account/organisation, how many sections it shows and how many groups it has.
    private static func sidebarPrefs(dataDir: String) -> (scopes: Set<String>, sections: [String: Int], groups: [String: Int]) {
        let path = (dataDir as NSString).appendingPathComponent("claude_desktop_config.json")
        guard let j = SafeRead.jsonObject(path),
              let e = (j["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any] else { return ([], [:], [:]) }
        var sections: [String: Int] = [:], groups: [String: Int] = [:]
        for (scope, v) in (e["dframe-code-sections"] as? [String: Any]) ?? [:] {
            let list = ((v as? [String: Any])?["sections"] as? [[String: Any]]) ?? []
            sections[scope] = list.filter { $0["shown"] as? Bool != false }.count
        }
        for (scope, v) in (e["dframe-group-scopes"] as? [String: Any]) ?? [:] {
            groups[scope] = (((v as? [String: Any])?["groups"] as? [Any]) ?? []).count
        }
        return (Set(sections.keys).union(groups.keys), sections, groups)
    }

    /// "166 sessions in the sidebar · 5 sections, 9 groups · 4 scheduled tasks"
    var words: [String] {
        func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }
        var out = [n(sessions, "session", "sessions") + " in the sidebar" + (archived > 0 ? " (and \(archived) archived)" : "")]
        if sections > 0 || groups > 0 { out.append("\(n(sections, "section", "sections")), \(n(groups, "group", "groups")) and the pins") }
        out.append(tasks > 0 ? n(tasks, "scheduled task", "scheduled tasks") : "no scheduled tasks")
        return out
    }
}

/// The full alert's words about switching to another account. An alert reaches the lock screen and Notification Center,
/// so it never names an account by its address or any part of it ("ultra-2"): the Switch page says which.
enum SwitchWords {
    static func alertLine(_ offer: SwitchOffer?, accounts: Int) -> String? {
        guard offer != nil else { return nil }
        return accounts > 1 ? "You can switch to another of its accounts: Claude Code signs in again on this profile's folder."
                            : "You can switch to its other account: Claude Code signs in again on this profile's folder."
    }
    /// The full-limit alert's button, worded like the card's and the menus' (it opens the Switch page)
    static let button = "Switch account…"
}
