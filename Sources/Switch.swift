// Switch: a profile working on another of its accounts (Accounts.swift) when a limit is full. Stage 2 offers it where a
// full limit shows (the dashboard card's at-limit box, the alert, the Dock and menu bar menus) and opens the Switch
// page, which says what stays and what follows. The switch itself comes later; this page changes nothing yet.
//
// Here: the standby accounts a profile can switch to, an account's short name, and what the Claude window's sidebar
// holds for an account, counted read-only from the window's own files (no session, title or group name is kept).

import Foundation

/// A standby account the profile could switch to now, with its limits as the agent last saved them.
struct SwitchOffer {
    let profile: String
    let standby: StandbyAccount
    let status: IconStatus?

    /// "<profile>~<standby>": names the page, the alert's action and the menu items.
    var key: String { AccountEntry.standbyStatusID(profile, standby.id) }
    var short: String { AccountNames.short(standby.email) }
    /// It has numbers and none of its limits is full.
    var room: Bool {
        guard let s = status, s.weekly != nil || s.fiveHour != nil else { return false }
        return AtLimit.blocker(fiveHour: s.fiveHour, fiveHourResets: s.fiveHourResets, weekly: s.weekly, weeklyResets: s.weeklyResets) == nil
    }
    /// How much of its week is used (or its 5-hour window's, on a plan without a week shown).
    var used: Double? { status?.weekly ?? status?.fiveHour }

    /// "ultra-2: week 8% used"
    var usedWords: String {
        guard let p = used else { return "\(short): no numbers yet" }
        return "\(short): \(status?.weekly != nil ? "week" : "5-hour") \(Int(p.rounded()))% used"
    }
    /// "ultra-2 has 92% of its week left"
    var leftWords: String? {
        guard let p = used else { return nil }
        return "\(short) has \(max(0, 100 - Int(p.rounded())))% of its \(status?.weekly != nil ? "week" : "5-hour limit") left"
    }

    static func parse(_ key: String) -> (profile: String, standby: String)? {
        let parts = key.split(separator: "~", maxSplits: 1).map(String.init)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty ? (parts[0], parts[1]) : nil
    }
}

extension AccountEntry {
    /// Its standby accounts with a kept sign-in, those with room first, the least used first.
    func switchOffers(status: (String) -> IconStatus? = Store.status) -> [SwitchOffer] {
        standby.filter { ($0.configDir ?? "").isEmpty == false }
            .map { SwitchOffer(profile: id, standby: $0, status: status(Self.standbyStatusID(id, $0.id))) }
            .enumerated()
            .sorted { a, b in
                if a.element.room != b.element.room { return a.element.room }
                let (x, y) = (a.element.used ?? 101, b.element.used ?? 101)
                return x != y ? x < y : a.offset < b.offset
            }
            .map(\.element)
    }

    /// The one to offer when a limit is full: the standby account with the most room, or nil.
    func bestOffer(status: (String) -> IconStatus? = Store.status) -> SwitchOffer? {
        switchOffers(status: status).first { $0.room }
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
        let org = scoped ?? orgs.max { entries(root, $0).count < entries(root, $1).count }
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

/// The full alert's words about another account with room: "ultra-2 has 92% of its week left."
enum SwitchWords {
    static func alertLine(_ offer: SwitchOffer?) -> String? { offer?.leftWords.map { $0 + "." } }
    static func button(_ offer: SwitchOffer) -> String { "Switch to \(offer.short)" }
}
