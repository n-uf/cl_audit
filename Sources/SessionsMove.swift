// SessionsMove: cl_audit's own profiles and settings in an export (format 4), for a move to another Mac.
//
// An export can carry cl_audit.json beside its export.json: each exported profile's record (its name and label, its look and how it
// behaves, its place in the profile order, whether it had a Dock icon, its accounts and which one is in use) and cl_audit's General and
// backup settings. Never its folders: a made profile always gets its own. It names addresses and account ids, so only the encrypted disk image carries it:
// a zip leaves it out and says so. In a move (SessionsExport.Job.move) the ids and addresses are the real ones; in any other export
// they are fingerprints like everywhere else in the file, so an import of that file can't name the accounts.
//
// An import never changes a profile that is here. A profile of the file is "already here" when one of its accounts (the account and
// organisation ids) is a profile's here, in use or standing by (one account belongs to one profile), or, for a file that names no
// account, when a profile here has its name. One whose name a profile here already has (with other accounts) isn't made. The others
// are made, under the file's id when it is free here (another id when it isn't). A profile made by an import:
// - has no sign-in. Each of its accounts needs one, through Add account: sign-ins never travel, and the Keychain is never read;
// - works in its own folders, the usual ones for its id (~/.claude-<id> and its own window, Claude-<id>), whatever the file says: never
//   ~/.claude, never the usual Claude app's window, never a folder the file names. One of those names that is already on this Mac is
//   used only when no profile has it, it is a plain folder and it holds no sign-in (else the next name), and the page says so;
// - has Usage in the Dock off, whatever the file says, and comes after the profiles that are here (their order doesn't change).
//   Making it writes only cl_audit's profiles file and the two folders it works in (made empty, only when they aren't there). No Dock icon app is built, the Dock is never written, no Claude app is opened or quit.
//   Putting it in the Dock is a step the person takes on the done page (Usage in the Dock, which builds its Dock icon app);
// - is written down in a receipt (moves/<id>/move.json) before it is made, so Undo takes back exactly it: a profile unchanged since
//   whose sessions' import isn't still in place, and the folders it made, once empty.
// Settings: this Mac's stay unless the person takes the file's; the ones that differ are listed with both values. Nothing secret is
// among them (looks, switches, how many backups to keep, where backups go). The backups place is taken only when that folder is
// there on this Mac and is inside the home folder or on a volume of its own.
//
// The file is untrusted: read through a 1 MB cap, at most 16 levels deep, every field checked for its type and range; a profile
// whose name can't be one is left out, an account whose ids aren't ids is dropped, and anything else odd falls back to the default.
// Each is said on the page.

import Foundation

enum SessionsMove {
    static let fileName = "cl_audit.json"
    static let format = "cl_audit-profiles"
    static let maxBytes = 1 << 20
    static let maxProfiles = 64
    static let maxAccounts = 20

    /// Where the General settings are read and written (a check's seam: a suite in a throwaway home keeps them in memory). The backup
    /// settings go through BackupPrefs.store, as the backups do.
    nonisolated(unsafe) static var prefs: PrefStore = UserDefaults.standard

    // MARK: - what the file holds, checked

    struct Account: Equatable {
        var email: String?
        var seat: SeatID
        var inUse: Bool
    }

    struct Profile: Equatable {
        var id: String
        var name: String
        var part: String?                   // "p2": its sessions are that part of the export
        var place: Int                      // its place in the profile order on the other Mac (0: first)
        var inDock: Bool                    // it had a Dock icon there
        var accounts: [Account]             // the one in use first
        var entry: AccountEntry             // its record as the file has it, checked: no seat, no standby yet
        var notes: [String] = []            // what was cleaned or dropped, in words
    }

    struct File: Equatable {
        var move: Bool
        var profiles: [Profile]
        var general: [String: String]       // key → raw value, known keys only
        var backups: [String: String]
        var notes: [String] = []
        /// The file's accounts came as fingerprints (an export that wasn't a move): none can be named.
        var fingerprinted = false
    }

    // MARK: making it (an export)

    /// The profile fields carried as they are (each checked when read back): how it looks and behaves.
    static let carried: [String] = ["style", "color", "frame", "accent", "panelDesign", "windowDot", "menuBar", "menuBarLook", "pollMinutes", "notify",
                                    "notifyPercent", "notifyBack", "autoRenew", "clickAction", "peekSeconds", "longPressDetails", "dockRuns",
                                    "windowFollowsDock", "opensFromDock", "claudeWindow", "showFable", "sessionsFollow"]

    /// cl_audit.json for these profiles (`parts`: profile id → the part folder that holds its sessions). `all`: every profile here, in
    /// order, for each one's place. The ids and addresses are the real ones: an export that isn't a move scrubs them like any other file.
    static func make(_ exported: [AccountEntry], parts: [String: String], all: [AccountEntry], move: Bool, now: Date = Date()) -> Data {
        var list: [[String: Any]] = []
        for e in exported.prefix(maxProfiles) {
            var p: [String: Any] = ["id": e.id, "name": e.name, "label": e.label, "place": all.firstIndex { $0.id == e.id } ?? list.count,
                                    "inDock": !e.iconHidden, "window": e.desktop.rawValue]
            // (no folders: a made profile always gets its own on the new Mac, whatever a file says)
            if let part = parts[e.id] { p["part"] = part }
            if let d = try? JSONEncoder().encode(e), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                var look: [String: Any] = [:]
                for k in carried { if let v = j[k] { look[k] = v } }
                p["settings"] = look
            }
            var accounts: [[String: Any]] = []
            if let s = e.seat { accounts.append(["account": s.account, "organization": s.organization ?? "", "email": s.email ?? "", "inUse": true]) }
            for q in e.standby {
                guard let s = q.seat else { continue }
                accounts.append(["account": s.account, "organization": s.organization ?? "", "email": s.email ?? q.email, "inUse": false])
            }
            p["accounts"] = accounts
            list.append(p)
        }
        var general: [String: Any] = [:], backups: [String: Any] = [:]
        for k in known {
            switch k.store {
            case .general: general[k.key] = typed(k, current(k))
            case .backups: backups[k.key] = typed(k, current(k))
            }
        }
        let root: [String: Any] = ["format": format, "move": move, "profiles": list, "general": general, "backups": backups]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    // MARK: reading it (an import), checked field by field

    /// How deep the brackets go (outside strings): a file nested deeper than a profiles file ever is is refused before it is parsed.
    static func depth(_ d: Data) -> Int {
        var most = 0, cur = 0, inString = false, escaped = false
        for b in d {
            if inString {
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
                continue
            }
            switch b {
            case 0x22: inString = true
            case 0x7B, 0x5B: cur += 1; most = max(most, cur)
            case 0x7D, 0x5D: cur -= 1
            default: break
            }
        }
        return most
    }

    static func isBool(_ v: Any?) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    static func bool(_ v: Any?) -> Bool? { isBool(v) ? (v as? NSNumber)?.boolValue : nil }
    /// A whole number (not a Bool, not 1.5).
    static func int(_ v: Any?) -> Int? {
        guard !isBool(v), let n = v as? NSNumber else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 1e9 else { return nil }
        return Int(d)
    }

    /// A profile name from a file: one plain line (no control, bidi or zero-width characters), at most 40 characters, trimmed; nil when
    /// nothing is left or it holds / or : (a profile's name can't).
    static func cleanName(_ s: Any?) -> String? {
        guard let raw = s as? String else { return nil }
        let n = SessionsBackup.oneLine(raw, max: 40).trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.contains("/"), !n.contains(":") else { return nil }
        return n
    }

    static func validID(_ s: String) -> Bool {
        s.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil && SessionsBackup.validProfile(s)
    }

    /// The folders a profile made by an import gets: always the usual ones for its own id, never a folder the file names (that could be
    /// ~/.claude, the usual Claude app's window, or anywhere else on this Mac).
    static func ownConfigDir(_ id: String, _ n: Int = 1) -> String { n == 1 ? "~/.claude-\(id)" : "~/.claude-\(id)-\(n)" }
    /// ~/.claude however it is spelled (Claude Code's default folder): never a made profile's.
    static func isDefaultFolder(_ dir: String) -> Bool { FolderKey.canonical(dir) == FolderKey.canonical("~/.claude") }
    static func ownDataDir(_ id: String, _ n: Int = 1) -> String { "~/Library/Application Support/Claude-\(id)" + (n == 1 ? "" : "-\(n)") }

    static func validEmail(_ s: String) -> Bool {
        s.utf8.count <= 254 && s.contains("@") && !s.hasPrefix("@") && !s.hasSuffix("@") && !s.contains(where: { $0.isWhitespace })
            && SessionsBackup.oneLine(s, max: 254) == s
    }

    /// Each carried field's check: what may stand there (anything else falls back to the default).
    private static func fieldOK(_ key: String, _ v: Any) -> Bool {
        switch key {
        case "style": return (v as? String).flatMap(IconStyle.init(rawValue:)) != nil
        case "color", "frame", "accent": return (v as? String).flatMap(TileColor.init(rawValue:)) != nil
        case "panelDesign": return (v as? String).flatMap(PanelDesign.init(rawValue:)) != nil
        case "clickAction": return (v as? String).flatMap(ClickAction.init(rawValue:)) != nil
        case "dockRuns": return (v as? String).flatMap(DockRuns.init(rawValue:)) != nil
        case "pollMinutes": return int(v).map { (1...60).contains($0) } ?? false
        case "notifyPercent": return int(v).map { (1...100).contains($0) } ?? false
        case "peekSeconds": return !isBool(v) && ((v as? NSNumber)?.doubleValue).map { $0.isFinite && PeekDuration.range.contains($0) } ?? false
        case "menuBarLook":
            guard let o = v as? [String: Any], o.count <= 8, let d = try? JSONSerialization.data(withJSONObject: o) else { return false }
            return (try? JSONDecoder().decode(MenuBarLook.self, from: d)) != nil
        default: return isBool(v)
        }
    }

    /// cl_audit.json read and checked. nil: it isn't one (not a JSON object, over 1 MB, nested too deep, another format): the import
    /// refuses the whole file then, never half of it.
    static func read(_ d: Data) -> File? {
        guard d.count <= maxBytes, depth(d) <= 16, let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              j["format"] as? String == format else { return nil }
        var f = File(move: bool(j["move"]) ?? false, profiles: [], general: [:], backups: [:])
        let raw = (j["profiles"] as? [Any]) ?? []
        if raw.count > maxProfiles { f.notes.append("The file names \(raw.count) profiles; the first \(maxProfiles) are read.") }
        var ids = Set<String>(), names = Set<String>(), seats = Set<SeatID>()
        for (i, any) in raw.prefix(maxProfiles).enumerated() {
            guard let o = any as? [String: Any] else { f.notes.append("A profile in the file can't be read: left out."); continue }
            guard let name = cleanName(o["name"]) else { f.notes.append("A profile in the file has no name a profile can have: left out."); continue }
            guard names.insert(name.lowercased()).inserted else { f.notes.append("The file names “\(name)” twice: the second is left out."); continue }
            var notes: [String] = []
            var id = (o["id"] as? String).flatMap { validID($0) ? $0 : nil } ?? Store.newID(from: name, taken: Array(ids))
            if !validID(id) { id = "profile" }
            if ids.contains(id) { id = Store.newID(from: id, taken: Array(ids)) }
            ids.insert(id)
            let label = String(((o["label"] as? String) ?? "").uppercased().filter { ($0.isLetter || $0.isNumber) && $0.isASCII }.prefix(6))
            var entry = AccountEntry(id: id, name: name, label: label.isEmpty ? String(name.uppercased().filter { ($0.isLetter || $0.isNumber) && $0.isASCII }.prefix(6)) : label,
                                     configDir: "~/.claude-\(id)")
            if entry.label.isEmpty { entry.label = "NEW" }
            // how it looks and behaves: each field checked, then decoded the way cl_audit reads its own profiles file
            if let s = o["settings"] as? [String: Any] {
                var dict: [String: Any] = ["id": id, "name": name, "label": entry.label, "configDir": entry.configDir]
                var odd = 0
                for k in carried { if let v = s[k] { if fieldOK(k, v) { dict[k] = v } else { odd += 1 } } }
                if let data = try? JSONSerialization.data(withJSONObject: dict), let e = try? JSONDecoder().decode(AccountEntry.self, from: data) { entry = e }
                if odd > 0 { notes.append("\(odd) of its settings can't be read: \(odd == 1 ? "that one is" : "those are") left at the default") }
            }
            // its folders: never the file's (a file could name ~/.claude, the usual Claude app's window or any folder): always its own
            // Claude Code folder and its own window, the usual ones for its id (settled in `plan`, once the id is final here)
            entry.configDir = ownConfigDir(id)
            entry.desktop = .separate
            entry.desktopDataDir = ownDataDir(id)
            if (o["window"] as? String) == DesktopMode.standard.rawValue { notes.append("it used the usual Claude app on the other Mac: here it gets a window of its own") }
            entry.seat = nil; entry.standby = []; entry.keptFolder = nil
            // its accounts: real ids only, each account once in the whole file (one account belongs to one profile)
            var accounts: [Account] = []
            let list = (o["accounts"] as? [Any]) ?? []
            var fingerprints = 0, bad = 0
            for a in list.prefix(maxAccounts) {
                guard let x = a as? [String: Any], let acc = x["account"] as? String, let org = x["organization"] as? String else { bad += 1; continue }
                if Fingerprint.isValid(acc) || Fingerprint.isValid(org) { fingerprints += 1; continue }
                guard AccountDiscovery.isUUID(acc), AccountDiscovery.isUUID(org) else { bad += 1; continue }
                let seat = SeatID(account: acc.lowercased(), organization: org.lowercased())
                guard seats.insert(seat).inserted else { notes.append("an account another profile of the file has too: left out"); continue }
                let email = (x["email"] as? String).flatMap { validEmail($0) ? $0 : nil }
                accounts.append(Account(email: email, seat: seat, inUse: bool(x["inUse"]) ?? false))
            }
            if list.count > maxAccounts { notes.append("more than \(maxAccounts) accounts: the first \(maxAccounts) are read") }
            if bad > 0 { notes.append("\(bad) \(bad == 1 ? "account whose ids aren't" : "accounts whose ids aren't") account ids: left out") }
            if fingerprints > 0 { f.fingerprinted = true }
            // one in use, first: the one the file marks, else the first
            if let k = accounts.firstIndex(where: \.inUse) { let a = accounts.remove(at: k); accounts.insert(a, at: 0) }
            for k in accounts.indices { accounts[k].inUse = k == 0 }
            let place = int(o["place"]).map { min(max($0, 0), 999) } ?? i
            f.profiles.append(Profile(id: id, name: name, part: (o["part"] as? String).flatMap { $0.range(of: #"^p[0-9]{1,3}$"#, options: .regularExpression) != nil ? $0 : nil },
                                      place: place, inDock: bool(o["inDock"]) ?? false, accounts: accounts, entry: entry, notes: notes))
        }
        for (store, target) in [("general", Where.general), ("backups", Where.backups)] {
            guard let o = j[store] as? [String: Any] else { continue }
            for k in known where k.store == target {
                guard let v = o[k.key], let s = normalized(k, v) else { continue }
                if target == .general { f.general[k.key] = s } else { f.backups[k.key] = s }
            }
        }
        return f
    }

    // MARK: - the settings that travel

    enum Where: String, Codable { case general, backups }
    enum Kind: Equatable {
        case bool(on: String, off: String)
        case choice([(String, String)])         // raw value, its words
        case int(ClosedRange<Int>)
        case place
        static func == (a: Kind, b: Kind) -> Bool {
            switch (a, b) {
            case let (.bool(x, y), .bool(z, w)): return x == z && y == w
            case let (.choice(x), .choice(y)): return x.map(\.0) == y.map(\.0)
            case let (.int(x), .int(y)): return x == y
            case (.place, .place): return true
            default: return false
            }
        }
    }
    struct Known {
        var key: String
        var label: String
        var store: Where
        var kind: Kind
        var def: String                         // what it is when nothing is stored
    }

    /// cl_audit's General settings that travel (looks and switches; the Dock's own settings stay with each Mac, as the Dock does) and
    /// its backup settings. None holds a secret.
    static let known: [Known] = [
        Known(key: "face", label: "Face", store: .general, kind: .choice(Face.allCases.map { ($0.rawValue, $0.title) }), def: Face.std.rawValue),
        Known(key: Privacy.key, label: "Emails", store: .general, kind: .bool(on: "shown", off: "hidden"), def: "true"),
        Known(key: DashboardPrefs.historyKey, label: "Usage history", store: .general, kind: .bool(on: "on", off: "off"), def: "true"),
        Known(key: "dashboardCardStyle", label: "Dashboard cards", store: .general, kind: .choice(PanelDesign.allCases.map { ($0.rawValue, $0.title) }), def: PanelDesign.segments.rawValue),
        Known(key: "dashboardRange", label: "History period", store: .general, kind: .choice(StatsRange.allCases.map { ($0.rawValue, $0.title) }), def: StatsRange.week.rawValue),
        Known(key: "dashboardShowHeatmap", label: "Heatmap", store: .general, kind: .bool(on: "shown", off: "hidden"), def: "true"),
        Known(key: "dashboardShowTokens", label: "Tokens chart", store: .general, kind: .bool(on: "shown", off: "hidden"), def: "true"),
        Known(key: "dashboardShowShares", label: "Shares chart", store: .general, kind: .bool(on: "shown", off: "hidden"), def: "true"),
        Known(key: "appIconStyle", label: "App icon", store: .general, kind: .choice(AppIconStyle.allCases.map { ($0.rawValue, $0.rawValue) }), def: AppIconStyle.standard.rawValue),
        Known(key: "appIconPanelPlate", label: "App icon plate", store: .general, kind: .choice(PanelPlate.allCases.map { ($0.rawValue, $0.rawValue) }), def: PanelPlate.grey.rawValue),
        Known(key: "appIconPanelDisplay", label: "App icon display", store: .general, kind: .choice(PanelDisplay.allCases.map { ($0.rawValue, $0.rawValue) }), def: PanelDisplay.cyan.rawValue),
        Known(key: "appIconPanelKeys", label: "App icon keys", store: .general, kind: .choice(PanelKeys.allCases.map { ($0.rawValue, $0.rawValue) }), def: PanelKeys.classic.rawValue),
        Known(key: "appIconPanelSlot", label: "App icon slot", store: .general, kind: .choice(PanelSlot.allCases.map { ($0.rawValue, $0.rawValue) }), def: PanelSlot.lit.rawValue),
        Known(key: BackupPrefs.placeKey, label: "Backups folder", store: .backups, kind: .place, def: ""),
        Known(key: BackupPrefs.lastKey, label: "Backups kept (at least)", store: .backups, kind: .int(1...99), def: "\(BackupPrefs.defaultLast)"),
        Known(key: BackupPrefs.daysKey, label: "Backups kept (days)", store: .backups, kind: .int(0...3650), def: "\(BackupPrefs.defaultDays)"),
    ]

    private static func store(_ w: Where) -> PrefStore { w == .general ? prefs : BackupPrefs.store }

    /// A value as the file writes it ("true", "segments", "3", "~/Backups"), or nil when it can't be this setting's.
    static func normalized(_ k: Known, _ v: Any) -> String? {
        switch k.kind {
        case .bool: return bool(v).map { $0 ? "true" : "false" }
        case .choice(let list):
            guard let s = v as? String, list.contains(where: { $0.0 == s }) else { return nil }
            return s
        case .int(let r): return int(v).flatMap { r.contains($0) ? "\($0)" : nil }
        case .place:
            guard let s = v as? String, s.utf8.count <= 1024, SessionsBackup.oneLine(s, max: 1024) == s else { return nil }
            if s.isEmpty { return "" }
            guard s.hasPrefix("/") || s.hasPrefix("~/") else { return nil }
            return tilde(expand(s))
        }
    }

    /// The setting as it is on this Mac, written like the file writes it.
    static func current(_ k: Known) -> String {
        guard let v = store(k.store).object(forKey: k.key) else { return k.def }
        if case .bool = k.kind, !isBool(v), let n = v as? NSNumber { return n.boolValue ? "true" : "false" }      // (a plain 0/1 number)
        return normalized(k, v) ?? k.def
    }

    /// "Silver", "shown", "3", "cl_audit's folder ▸ backups".
    static func words(_ k: Known, _ raw: String) -> String {
        switch k.kind {
        case .bool(let on, let off): return raw == "true" ? on : off
        case .choice(let list): return list.first { $0.0 == raw }?.1 ?? raw
        case .int: return raw
        case .place: return raw.isEmpty ? "cl_audit's folder ▸ backups" : raw
        }
    }

    /// Why a backups place from a file can't be taken here, or nil: it must be a folder that is here, inside the home folder (not the
    /// home folder itself) or on a volume of its own (/Volumes/<name>/…), and not a link.
    static func placeProblem(_ raw: String) -> String? {
        if raw.isEmpty { return nil }
        let path = (expand(raw) as NSString).standardizingPath
        let home = NSHomeDirectory()
        let comps = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !comps.contains(".."), !comps.contains(".") else { return "it isn't a plain folder path" }
        let inHome = path.hasPrefix(home + "/") && path != home
        let onVolume = comps.count >= 2 && comps[0] == "Volumes"
        guard inHome || onVolume else { return "it is a system folder, not one in your home folder or on a disk of its own" }
        var st = stat()
        guard lstat(path, &st) == 0 else { return "that folder isn't on this Mac" }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return "it isn't a folder here" }
        return nil
    }

    // MARK: - the plan (read-only)

    struct Made: Equatable, Codable {
        var id: String
        var name: String
        var part: String?
        var entry: AccountEntry             // as it is written into the profiles file
        var place: Int
        var signIns: [String]               // the accounts to sign in to, the one in use first
        var inDock: Bool                    // it had a Dock icon on the other Mac: putting it in the Dock is a step on the done page
        var folders: [String] = []          // what the import made for it (expanded), deepest last; Undo takes them back once empty
        var notes: [String] = []
        var written = false                 // it is in the profiles file (not "appeared meanwhile")
    }

    struct Here: Equatable {
        var name: String                    // the file's
        var here: String                    // the profile here
        var id: String                      // …its id
        var part: String?
        var why: String
    }

    struct Diff: Equatable, Codable {
        var key: String
        var label: String
        var store: Where
        var here: String                    // raw values
        var file: String
        var hereWords: String
        var fileWords: String
        var problem: String?                // it can't be taken (the backups place: not here, a system folder)
    }

    struct Plan: Equatable {
        var move = false
        var fingerprinted = false
        var create: [Made] = []
        var here: [Here] = []
        var notMade: [(name: String, why: String)] = []
        var settings: [Diff] = []
        var notes: [String] = []
        static func == (a: Plan, b: Plan) -> Bool {
            a.move == b.move && a.create == b.create && a.here == b.here && a.notMade.map { $0.name + $0.why } == b.notMade.map { $0.name + $0.why }
                && a.settings == b.settings && a.notes == b.notes
        }
        /// The profile here (or made by this import) that a part of the file goes into: the file's profile for that part.
        func profile(forPart dir: String) -> String? {
            create.first { $0.part == dir }?.id ?? here.first { $0.part == dir }?.id
        }
        var takeable: [Diff] { settings.filter { $0.problem == nil } }
        var isEmpty: Bool { create.isEmpty && settings.isEmpty }
    }

    /// The first of `name(1)`, `name(2)` … that no profile uses and that is either not on this Mac or a plain folder (not a link) without
    /// a sign-in record (`signIn`: Claude Code's .claude.json, the window's config.json) in it. `there`: it is on this Mac already.
    static func freeFolder(name: (Int) -> String, owned: (String) -> Bool, signIn: String) -> (dir: String, there: Bool) {
        for n in 1...99 {
            let dir = name(n)
            if owned(dir) { continue }
            let path = expand(dir)
            var st = stat()
            guard lstat(path, &st) == 0 else { return (dir, false) }
            guard (st.st_mode & S_IFMT) == S_IFDIR else { continue }               // a link or a file of that name: never used
            if lstat((path as NSString).appendingPathComponent(signIn), &st) == 0 { continue }       // signed in to something: not ours
            return (dir, true)
        }
        return (name(100), false)
    }

    /// The accounts of a profile as cl_audit keeps them: the one in use (`seat`) and the others standing by, each without a kept sign-in.
    static func accountsEntry(_ e: inout AccountEntry, _ accounts: [Account], now: Date) {
        guard let first = accounts.first else { e.seat = nil; e.standby = []; return }
        // (whole seconds: the receipt keeps the record as written, and Undo compares it with what is in the profiles file)
        let now = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        e.seat = Seat(account: first.seat.account, organization: first.seat.organization, email: first.email)
        var used = Set<String>()
        e.standby = accounts.dropFirst().map { a in
            var sid = String(a.seat.account.filter(\.isHexDigit).prefix(8))
            while !used.insert(sid).inserted { sid = StandbyAccount.newID() }
            return StandbyAccount(email: a.email ?? "", seat: Seat(account: a.seat.account, organization: a.seat.organization, email: a.email), configDir: nil, addedAt: now, id: sid)
        }
    }

    /// What an import of this file would do here: which profiles it makes (and as what), which are here already, which it can't make,
    /// and which settings differ. Nothing is written.
    static func plan(_ f: File, accounts here: [AccountEntry], now: Date = Date()) -> Plan {
        var p = Plan(move: f.move, fingerprinted: f.fingerprinted)
        p.notes = f.notes
        var taken = here                                    // what is here, and what this plan makes, as it goes
        for fp in f.profiles.sorted(by: { $0.place != $1.place ? $0.place < $1.place : $0.name < $1.name }) {
            let seats = fp.accounts.map { Seat(account: $0.seat.account, organization: $0.seat.organization) }
            if let owner = here.first(where: { e in seats.contains { e.has($0) } }) {
                p.here.append(Here(name: fp.name, here: owner.name, id: owner.id, part: fp.part,
                                   why: owner.name.lowercased() == fp.name.lowercased() ? "the same account" : "its account is \(owner.name)'s here"))
                continue
            }
            if let owner = taken.first(where: { $0.name.lowercased() == fp.name.lowercased() }) {
                if fp.accounts.isEmpty, here.contains(where: { $0.id == owner.id }) {
                    p.here.append(Here(name: fp.name, here: owner.name, id: owner.id, part: fp.part, why: "the same name (the file doesn't name its accounts)"))
                } else {
                    p.notMade.append((fp.name, "a profile here is already called “\(owner.name)”"))
                }
                continue
            }
            var e = fp.entry
            let ids = taken.map(\.id)
            if ids.contains(e.id) { e.id = Store.newID(from: e.name, taken: ids) }
            if !validID(e.id) || ids.contains(e.id) { e.id = Store.newID(from: "profile", taken: ids) }
            var notes = fp.notes
            // its folders: always its own, the usual ones for its id (never the file's: never ~/.claude, never the usual Claude app). A
            // folder of that name no profile uses is taken as it is only when it holds no sign-in (and isn't a link); else the next name
            e.desktop = .separate
            let code = freeFolder(name: { ownConfigDir(e.id, $0) }, owned: { FolderRules.configOwner($0, among: taken) != nil }, signIn: ".claude.json")
            let data = freeFolder(name: { ownDataDir(e.id, $0) }, owned: { FolderRules.windowOwner(.separate, $0, among: taken) != nil }, signIn: "config.json")
            e.configDir = code.dir; e.desktopDataDir = data.dir
            for (dir, there) in [(code.dir, code.there), (data.dir, data.there)] where there {
                notes.append("uses the folder \(dir) already on this Mac (nothing in it changes)")
            }
            accountsEntry(&e, fp.accounts, now: now)
            // no Dock icon until the person puts it in the Dock (the done page's step): nothing builds an app or writes the Dock before
            e.iconHidden = true
            e.keptFolder = nil
            let signIns = fp.accounts.map { $0.email ?? "an account (its address isn't in the file)" }
            p.create.append(Made(id: e.id, name: e.name, part: fp.part, entry: e, place: fp.place,
                                 signIns: signIns.isEmpty ? [f.fingerprinted ? "its account (the file names it only by a fingerprint)" : "its account"] : signIns,
                                 inDock: fp.inDock, notes: notes))
            taken.append(e)
        }
        // the settings that differ
        for k in known {
            guard let file = (k.store == .general ? f.general : f.backups)[k.key] else { continue }
            let mine = current(k)
            guard file != mine else { continue }
            var d = Diff(key: k.key, label: k.label, store: k.store, here: mine, file: file, hereWords: words(k, mine), fileWords: words(k, file))
            if case .place = k.kind { d.problem = placeProblem(file) }
            p.settings.append(d)
        }
        return p
    }

    // MARK: - doing it, with a receipt

    struct SettingStep: Equatable, Codable {
        var key: String
        var store: Where
        var before: String?                 // nil: nothing was stored
        var after: String
        var settled = false
    }

    struct Receipt: Equatable, Codable {
        var id: String
        var started: Date
        var file: String                    // the export file's name
        var move: Bool
        var made: [Made]
        var settings: [SettingStep] = []
        var finished: Date?
        var undone: Date?
        var problems: [String] = []
        /// What Undo left, and why ("Work: changed since", "~/.claude-work: not empty").
        var left: [String] = []
        var madeNames: [String] { made.filter(\.written).map(\.name) }
    }

    static var root: URL { Store.folder.appendingPathComponent("moves") }
    static func validReceiptID(_ s: String) -> Bool { SessionsBackup.validID(s) }

    static func save(_ r: Receipt) throws {
        let d = root.appendingPathComponent(r.id)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = d.appendingPathComponent("move.json")
        try enc.encode(r).write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    static func load(_ id: String) -> Receipt? {
        guard validReceiptID(id) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: root.appendingPathComponent("\(id)/move.json"))).flatMap { try? dec.decode(Receipt.self, from: $0) }.flatMap { $0.id == id ? $0 : nil }
    }

    /// Every move import's receipt, newest first.
    static func receipts() -> [Receipt] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(validReceiptID).compactMap(load).sorted { $0.started > $1.started }
    }

    /// Makes the folders of `path` that aren't there, one at a time, never through a link; returns those it made (outermost first).
    /// Stops (and returns what it made) at a part that is there and isn't a folder.
    private static func makeFolders(_ path: String) -> (made: [String], ok: Bool) {
        var made: [String] = []
        var cur = ""
        for comp in path.split(separator: "/") {
            cur += "/" + comp
            var st = stat()
            if lstat(cur, &st) == 0 {
                if (st.st_mode & S_IFMT) != S_IFDIR { return (made, false) }      // (a link, or a file, on the way: nothing made through it)
                continue
            }
            guard mkdir(cur, 0o700) == 0 else { return (made, false) }
            made.append(cur)
        }
        return (made, true)
    }

    /// Makes the profiles of the plan (those still free when the profiles file is written, under its lock) and their folders, and takes
    /// the file's settings when asked (only those that can be taken). The receipt is written before anything else and after each step.
    @discardableResult
    static func apply(_ p: Plan, takeSettings: Bool, file: String, now: Date = Date()) throws -> Receipt {
        var r = Receipt(id: SessionsBackup.newID(now), started: now, file: SessionsBackup.oneLine(file, max: 200), move: p.move, made: p.create)
        do { try save(r) } catch { throw BackupError("The import's receipt couldn't be saved; nothing was made.") }
        // 1. the profiles: each still free (its id, name, accounts and folders, its folder still without a sign-in) in the file as it is
        // now, added after the profiles that are here
        var wrote = Set<String>()
        do {
            try Store.edit { list in
                var out = list
                for m in p.create.sorted(by: { $0.place != $1.place ? $0.place < $1.place : $0.name < $1.name }) {
                    let e = m.entry
                    let clash = out.contains { $0.id == e.id || $0.name.lowercased() == e.name.lowercased() }
                        || e.seats.contains { s in out.contains { $0.has(s) } }
                        || FolderRules.configOwner(e.configDir, among: out) != nil
                        || FolderRules.windowOwner(e.desktop, e.desktop == .standard ? FolderKey.standardDataDir : e.desktopDataDir, among: out) != nil
                        || e.desktop == .standard || isDefaultFolder(e.configDir)
                        || FileManager.default.fileExists(atPath: (expand(e.configDir) as NSString).appendingPathComponent(".claude.json"))
                    if clash { continue }
                    // after the profiles that are here (their order never changes), the made ones in the file's order
                    out.append(e)
                    wrote.insert(e.id)
                }
                return out
            }
        } catch {
            r.problems.append("cl_audit's profiles file couldn't be written; no profile was made.")
            r.finished = now
            try? save(r)
            throw BackupError("cl_audit's profiles file couldn't be written (\(error.localizedDescription)); no profile was made.")
        }
        for i in r.made.indices {
            r.made[i].written = wrote.contains(r.made[i].id)
            if !r.made[i].written { r.problems.append("\(r.made[i].name) wasn't made: a profile with its name, account or folder appeared meanwhile.") }
        }
        try? save(r)
        // 2. their folders: made empty, only those that aren't there (a folder that is there is used as it is)
        for i in r.made.indices where r.made[i].written {
            let e = r.made[i].entry
            var dirs = [expand(e.configDir)]
            dirs.append(expand(e.desktop == .standard ? FolderKey.standardDataDir : e.desktopDataDir))
            for d in dirs {
                let (made, ok) = makeFolders(d)
                r.made[i].folders += made
                if !ok { r.problems.append("\(tilde(d)) couldn't be made (a file or a link is on the way): \(e.name)'s \(d == dirs[0] ? "sessions" : "window entries") can't be imported until it can.") }
                try? save(r)
            }
        }
        // 3. the settings, when asked: only those that can be taken, each written down before it is changed
        if takeSettings {
            for d in p.takeable {
                guard let k = known.first(where: { $0.key == d.key }) else { continue }
                let s = store(k.store)
                let before = s.object(forKey: k.key) == nil ? nil : current(k)
                r.settings.append(SettingStep(key: k.key, store: k.store, before: before, after: d.file))
                try? save(r)
                write(k, d.file)
            }
        }
        r.finished = Date()
        try? save(r)
        return r
    }

    private static func write(_ k: Known, _ raw: String?) {
        store(k.store).set(raw.map { typed(k, $0) }, forKey: k.key)
    }

    /// A raw value as it is stored and as the file writes it: a Bool, a number or a string.
    static func typed(_ k: Known, _ raw: String) -> Any {
        switch k.kind {
        case .bool: return raw == "true"
        case .int: return Int(raw) ?? 0
        case .choice, .place: return raw
        }
    }

    /// Whether a profile's sessions import (a restore of an imported backup into it) is still in place: then Undo leaves the profile.
    static func importInPlace(_ profile: String) -> Bool {
        SessionsRestore.receipts().contains { $0.profile == profile && $0.importedFrom != nil && $0.undone == nil && !$0.steps.isEmpty }
    }

    /// Takes back what the receipt says this import made: each profile unchanged since and whose sessions' import isn't in place (undo
    /// that first), the folders it made for them once empty, and each setting that is still what the import set. Whatever changed since
    /// stays, and is said.
    @discardableResult
    static func undo(_ id: String, now: Date = Date()) throws -> Receipt {
        guard var r = load(id) else { throw BackupError("The import's receipt isn't there any more.") }
        guard r.undone == nil else { return r }
        r.left = []
        // the settings first (they don't depend on anything)
        for i in r.settings.indices where !r.settings[i].settled {
            guard let k = known.first(where: { $0.key == r.settings[i].key }) else { r.settings[i].settled = true; continue }
            if current(k) == r.settings[i].after { write(k, r.settings[i].before) }
            else { r.left.append("\(k.label): changed since, left as it is") }
            r.settings[i].settled = true
        }
        // the profiles: only those exactly as the import wrote them, and without an import of their sessions still in place
        var removed = Set<String>()
        let made = r.made.filter(\.written)
        let blocked = Set(made.filter { importInPlace($0.id) }.map(\.id))
        do {
            try Store.edit { list in
                list.filter { e in
                    guard let m = made.first(where: { $0.id == e.id }) else { return true }
                    if blocked.contains(e.id) { return true }
                    guard e == m.entry else { return true }
                    removed.insert(e.id)
                    return false
                }
            }
        } catch { throw BackupError("cl_audit's profiles file couldn't be written; nothing was taken back.") }
        for m in made where !removed.contains(m.id) {
            r.left.append(blocked.contains(m.id) ? "\(m.name): its sessions' import is still in place (undo it first)" : "\(m.name): changed since, left as it is")
        }
        // the folders it made for the profiles it took back: deepest first, only when empty
        for m in made where removed.contains(m.id) {
            for d in m.folders.reversed() {
                if rmdir(d) != 0, errno != ENOENT { r.left.append("\(tilde(d)): not empty, left as it is") }
            }
            Store.removeStatus(m.id)
        }
        for i in r.made.indices where removed.contains(r.made[i].id) { r.made[i].written = false }
        if r.left.isEmpty || r.made.allSatisfy({ !$0.written }) { r.undone = now }
        try? save(r)
        return r
    }
}

// MARK: - the words of the pages

enum MoveWords {
    private static func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }

    /// "Work (2 accounts)", "Home (1 account)".
    static func made(_ m: SessionsMove.Made) -> String {
        let k = m.entry.seats.count
        return k == 0 ? m.name : "\(m.name) (\(n(k, "account", "accounts")))"
    }

    /// The Profiles row: "2 to make: Work (2 accounts), Home (1 account) · here already: Main".
    static func profiles(_ p: SessionsMove.Plan) -> String {
        var parts: [String] = []
        if !p.create.isEmpty { parts.append("\(p.create.count) to make: " + p.create.prefix(6).map(made).joined(separator: ", ") + (p.create.count > 6 ? ", …" : "")) }
        if !p.here.isEmpty { parts.append("here already: " + p.here.prefix(6).map { $0.name == $0.here ? $0.name : "\($0.name) (as \($0.here))" }.joined(separator: ", ") + (p.here.count > 6 ? ", …" : "")) }
        if !p.notMade.isEmpty { parts.append("\(p.notMade.count) not made") }
        return parts.isEmpty ? "none in the file" : parts.joined(separator: " · ")
    }

    /// The lines under it: what a made profile is (and isn't), and each profile that isn't made, with why.
    static func profileNotes(_ p: SessionsMove.Plan) -> [String] {
        var out: [String] = []
        if !p.create.isEmpty {
            out.append("Made with their accounts, looks and settings, no sign-in: each account needs one afterwards, through Add account. No Dock icon yet: putting one in the Dock is a step after the import.")
        }
        if p.fingerprinted { out.append("This file wasn't made as a move: its accounts are only fingerprints, so the profiles come without them. Export ▸ Move to another Mac carries them.") }
        for x in p.notMade.prefix(6) { out.append("\(x.name): not made, \(x.why)") }
        for m in p.create { for note in m.notes.prefix(3) { out.append("\(m.name): \(note)") } }
        out += p.notes.prefix(3)
        return out
    }

    /// The Settings row: "3 differ: Face, Emails, Backups folder" or "the same as here".
    static func settings(_ p: SessionsMove.Plan, take: Bool) -> String {
        if p.settings.isEmpty { return "the same as here" }
        let names = p.settings.prefix(4).map(\.label).joined(separator: ", ") + (p.settings.count > 4 ? ", …" : "")
        let takeable = p.takeable.count
        if !take { return "\(n(p.settings.count, "differs", "differ")) (\(names)): this Mac's stay" }
        return takeable == p.settings.count ? "\(n(takeable, "is", "are")) taken from the file: \(names)"
            : "\(takeable) of \(p.settings.count) taken from the file (\(names)); \(p.settings.count - takeable) can't be"
    }

    /// One line per setting that differs: "Face: Std here, Silver in the file", with why one can't be taken.
    static func settingLines(_ p: SessionsMove.Plan) -> [String] {
        p.settings.map { d in "\(d.label): \(d.hereWords) here, \(d.fileWords) in the file" + (d.problem.map { " (can't be taken: \($0))" } ?? "") }
    }

    /// The key that does it: "Make 2 profiles", "Make 2 profiles and take 3 settings", "Take 3 settings".
    static func key(_ p: SessionsMove.Plan, take: Bool, create: Bool) -> String? {
        let profiles = create && !p.create.isEmpty ? "Make \(n(p.create.count, "profile", "profiles"))" : nil
        let settings = take && !p.takeable.isEmpty ? n(p.takeable.count, "setting", "settings") : nil
        switch (profiles, settings) {
        case let (a?, b?): return "\(a) and take \(b)"
        case let (a?, nil): return a
        case let (nil, b?): return "Take \(b)"
        default: return nil
        }
    }

    /// After it ran: "Made: Work, Home · 3 settings taken".
    static func done(_ r: SessionsMove.Receipt) -> String {
        if r.undone != nil { return "Taken back: the profiles it made are gone" + (r.settings.isEmpty ? "" : ", and the settings are as they were") }
        var parts: [String] = []
        let names = r.madeNames
        parts.append(names.isEmpty ? "No profile made" : "Made: " + names.joined(separator: ", "))
        if !r.settings.isEmpty { parts.append("\(n(r.settings.count, "setting", "settings")) taken from the file") }
        return parts.joined(separator: " · ")
    }

    /// The done page's steps for one made profile: the accounts to sign in to, the Dock, and where its tasks are turned on.
    static func steps(_ m: SessionsMove.Made, tasks: Int = 0) -> [String] {
        var out: [String] = []
        let who = m.signIns.joined(separator: ", ")
        out.append("Sign in to \(m.signIns.count == 1 ? "its account" : "each of its \(m.signIns.count) accounts") (\(who)): Settings ▸ \(m.name) ▸ Claude Code ▸ Accounts, Add account. Nothing is signed in yet.")
        out.append(m.inDock ? "Put it in the Dock: Settings ▸ \(m.name) ▸ Usage in the Dock, or the key here. It had a Dock icon on the other Mac." : "It had no Dock icon on the other Mac; Usage in the Dock turns one on.")
        if tasks > 0 { out.append("\(n(tasks, "scheduled task came", "scheduled tasks came")) paused: turn each on in its Claude window's Scheduled tasks once it's signed in.") }
        return out
    }
}
