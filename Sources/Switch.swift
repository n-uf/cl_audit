// Switch: a profile working on another of its accounts (Accounts.swift), offered where a full limit shows (the dashboard
// card's at-limit box, the alert, the Dock and menu bar menus, the quick chat) and run on the Switch page
// (SwitchPage.swift, SwitchRunner.swift).
//
// Here: the standby accounts a profile can switch to, an account's short name, and what the Claude window's sidebar
// holds for an account, counted read-only from the window's own files (no session, title or group name is kept; the
// default-profile move uses it).

import Foundation

/// A standby account the profile could switch to. A standby account isn't read, so it has no limits: only what is
/// remembered of it (its plan, when it was last in use, whether its week was full when it left).
struct SwitchOffer {
    let profile: String
    let standby: StandbyAccount

    /// "<profile>~<standby>": names the page, the alert's action and the menu items.
    var key: String { AccountEntry.switchKey(profile, standby.id) }
    var short: String { AccountNames.short(standby.email) }
    /// Its week was full when it left, and hasn't started again yet.
    func knownFull(now: Date = Date()) -> Bool { standby.knownFull(now: now) }

    /// "Ultra · last in use 3 days ago", or "on standby".
    func lineWords(now: Date = Date()) -> String {
        let parts = [standby.plan.map(Account.planWords), standby.lastInUse.map { "last in use " + AccountBook.ago($0, now: now) },
                     knownFull(now: now) ? "week full when it left" : nil].compactMap { $0 }
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

    /// Its standby accounts in the order a full limit offers them (AccountBook.offerOrder: not known to be full first, the
    /// least used by its last week, then the most recently in use).
    func switchOffers(now: Date = Date()) -> [SwitchOffer] {
        AccountBook.offerOrder(standby, now: now).map { SwitchOffer(profile: id, standby: $0) }
    }

    /// The one to offer when a limit is full (AccountBook.best), or nil.
    func bestOffer(now: Date = Date()) -> SwitchOffer? {
        AccountBook.best(standby, now: now).map { SwitchOffer(profile: id, standby: $0) }
    }
}

enum AccountNames {
    /// An account's short name: its address before the @ ("ultra-2"), the first letter only while addresses are hidden.
    static func short(_ email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        return Privacy.shared.show ? local : String(local.prefix(1)) + "•••"
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
        let root = (dir as NSString).appendingPathComponent("claude-code-sessions/\(account)")
        let fm = FileManager.default
        let prefs = sidebarPrefs(dataDir: dir)
        // the organisation the sidebar was set up for, else the one with the most sessions
        let orgs = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter(AccountDiscovery.isUUID)
        let scoped = orgs.first { prefs.scopes.contains("\(account)/\($0)") }
        let sizes = Dictionary(uniqueKeysWithValues: orgs.map { ($0, entries(root, $0).count) })     // each folder listed once
        let org = scoped ?? orgs.max { sizes[$0, default: 0] < sizes[$1, default: 0] }
        guard let org else { return nil }
        var c = SidebarCounts()
        let odir = (root as NSString).appendingPathComponent(org)
        // an entry can be large (it carries the account's connector list): only its "isArchived" is looked for
        let archived = [Data(#""isArchived":true"#.utf8), Data(#""isArchived" : true"#.utf8), Data(#""isArchived": true"#.utf8)]
        for f in entries(root, org) {
            let d = (try? Data(contentsOf: URL(fileURLWithPath: (odir as NSString).appendingPathComponent(f)))) ?? Data()
            if archived.contains(where: { d.range(of: $0) != nil }) { c.archived += 1 } else { c.sessions += 1 }
        }
        let scope = "\(account)/\(org)"
        c.sections = prefs.sections[scope] ?? 0
        c.groups = prefs.groups[scope] ?? 0
        if let data = fm.contents(atPath: (odir as NSString).appendingPathComponent("scheduled-tasks.json")),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            c.tasks = (j["scheduledTasks"] as? [Any])?.count ?? 0
        }
        return c
    }

    private static func entries(_ root: String, _ org: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: (root as NSString).appendingPathComponent(org))) ?? [])
            .filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }
    }

    /// The sidebar's mirror: per account/organisation, how many sections it shows and how many groups it has.
    private static func sidebarPrefs(dataDir: String) -> (scopes: Set<String>, sections: [String: Int], groups: [String: Int]) {
        let path = (dataDir as NSString).appendingPathComponent("claude_desktop_config.json")
        guard let data = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
        return accounts > 1 ? "Switch to another of its accounts: Claude Code on its folder signs in again."
                            : "Switch to its other account: Claude Code on its folder signs in again."
    }
    /// The full-limit alert's button, worded like the card's and the menus' (it opens the Switch page)
    static let button = "Switch account…"
}
