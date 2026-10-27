// Managing the Dock (Settings ▸ Dashboard ▸ Dock, off by default): keeps the profile icons pinned together in
// account order with the cl_audit app last, and keeps at most one Claude pin, placed before the group. macOS ties
// running Claude windows to Claude pins in its own order, so several pins get mixed up; the profile icons are
// the reliable way to reach each account's window. Only the Dock's pin list (com.apple.dock persistent-apps)
// is changed, and the Dock restarts once, only when it doesn't match the settings. The list is saved before the first
// change so it can be restored.

import AppKit
import SwiftUI
import os

/// What cl_audit does to the Dock, for `log show --predicate 'subsystem == "local.usage-n-uf"'`.
let dockLog = Logger(subsystem: "local.usage-n-uf", category: "dock")

final class DockPrefs: ObservableObject {
    static let shared = DockPrefs()
    private let d = UserDefaults.standard

    enum Icons: String, CaseIterable { case together, leave }
    enum ClaudePins: String, CaseIterable { case one, none, leave }

    @Published var manage: Bool { didSet { d.set(manage, forKey: "dockManage") } }
    @Published var icons: Icons { didSet { d.set(icons.rawValue, forKey: "dockIcons") } }
    @Published var claude: ClaudePins { didSet { d.set(claude.rawValue, forKey: "dockClaude") } }

    private init() {
        manage = d.bool(forKey: "dockManage")
        icons = Icons(rawValue: d.string(forKey: "dockIcons") ?? "") ?? .together
        claude = ClaudePins(rawValue: d.string(forKey: "dockClaude") ?? "") ?? .one
    }

    /// The pin list as it was before cl_audit's first change, and when it was saved.
    var backup: [[String: Any]]? {
        guard let data = d.data(forKey: "dockBackup") else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]]
    }
    var backupDate: Date? { d.object(forKey: "dockBackupDate") as? Date }

    func saveBackup(_ list: [[String: Any]]) {
        guard d.data(forKey: "dockBackup") == nil,
              let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) else { return }
        d.set(data, forKey: "dockBackup"); d.set(Date(), forKey: "dockBackupDate")
        objectWillChange.send()
    }

    func clearBackup() { d.removeObject(forKey: "dockBackup"); d.removeObject(forKey: "dockBackupDate"); objectWillChange.send() }
}

enum DockManager {
    static let dock = "com.apple.dock" as CFString
    static let key = "persistent-apps" as CFString

    static func pins() -> [[String: Any]] {
        CFPreferencesAppSynchronize(dock)
        return CFPreferencesCopyAppValue(key, dock) as? [[String: Any]] ?? []
    }

    static func path(_ tile: [String: Any]) -> String? {
        guard let t = tile["tile-data"] as? [String: Any], let f = t["file-data"] as? [String: Any],
              let s = f["_CFURLString"] as? String else { return nil }
        let url = s.hasPrefix("file://") ? URL(string: s) : URL(fileURLWithPath: s)
        return url?.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }

    static var claudeURL: URL { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Launcher.claudeBundleID) ?? URL(fileURLWithPath: "/Applications/Claude.app") }
    static var settingsURL: URL { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Installer.managerID) ?? Bundle.main.bundleURL }

    /// A new pin for an app (what `defaults write … persistent-apps -array-add` would add).
    static func tile(_ url: URL) -> [String: Any] {
        ["tile-type": "file-tile",
         "tile-data": ["file-label": url.deletingPathExtension().lastPathComponent,
                       "file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15]]]
    }

    /// Whether a pinned app is a cl_audit icon app (by its Info.plist), even one whose account is gone.
    static func isIconApp(_ p: String) -> Bool {
        Installer.info(URL(fileURLWithPath: "/" + p))?["UsageAccountID"] != nil
    }

    /// The pin list as these settings want it, from the current one. Apps that aren't cl_audit's or Claude stay in place.
    static func plan(_ current: [[String: Any]], accounts: [AccountEntry], prefs: DockPrefs) -> [[String: Any]] {
        let claudeKey = key(claudeURL)
        let ours = accounts.map { key(Installer.appURL($0)) } + [key(settingsURL)]
        // a profile whose Dock icon is hidden is never pinned: its pin (if any) is dropped, not placed in the group
        let oursURLs = accounts.filter { !$0.iconHidden }.map { Installer.appURL($0) } + [settingsURL]
        func isOurs(_ p: String?) -> Bool { p.map { ours.contains($0) || isIconApp($0) } ?? false }
        func isClaude(_ p: String?) -> Bool { p == claudeKey }

        let managesIcons = prefs.icons == .together, managesClaude = prefs.claude != .leave
        var out: [[String: Any]] = []
        var anchor: Int?
        var claudeTile: [String: Any]?
        var keptClaude = false
        var existing: [String: [String: Any]] = [:]
        for t in current {
            let p = path(t)
            if isClaude(p) && managesClaude {
                if claudeTile == nil { claudeTile = t }
                if anchor == nil && managesIcons { anchor = out.count }
                // Icons left as they are: keep the first Claude pin where it is (if one is wanted).
                if !managesIcons && prefs.claude == .one && !keptClaude { out.append(t); keptClaude = true }
                continue
            }
            if isOurs(p) && managesIcons {
                if let p { existing[p] = t }
                if anchor == nil { anchor = out.count }
                continue
            }
            out.append(t)
        }
        guard managesIcons else {
            if prefs.claude == .one && !keptClaude { out.append(claudeTile ?? tile(claudeURL)) }
            return out
        }
        var group: [[String: Any]] = []
        if prefs.claude == .one { group.append(claudeTile ?? tile(claudeURL)) }
        else if prefs.claude == .leave, let c = claudeTile { group.append(c) }
        for u in oursURLs where FileManager.default.fileExists(atPath: u.path) {
            group.append(existing[key(u)] ?? tile(u))
        }
        out.insert(contentsOf: group, at: min(anchor ?? out.count, out.count))
        return out
    }

    static func same(_ a: [[String: Any]], _ b: [[String: Any]]) -> Bool { a.map(path) == b.map(path) }

    static func fileURL(_ tile: [String: Any]) -> URL? {
        guard let t = tile["tile-data"] as? [String: Any], let f = t["file-data"] as? [String: Any],
              let s = f["_CFURLString"] as? String else { return nil }
        return s.hasPrefix("file://") ? URL(string: s) : URL(fileURLWithPath: s)
    }

    static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    /// What the Dock shows for a pinned app: a cl_audit icon app's live tile (its account's numbers), otherwise
    /// the app's icon.
    static func tileImage(_ url: URL) -> NSImage {
        if let e = Store.load().first(where: { key(Installer.appURL($0)) == key(url) }) {
            return preview(e, status: Store.status(e.id))
        }
        return icon(url)
    }

    /// Running apps the Dock shows after its divider: apps that aren't pinned, and extra windows of a pinned app
    /// (each Claude window is its own app), in launch order.
    static func running(besides tiles: [[String: Any]]) -> [(image: NSImage, name: String)] {
        var pinned = Dictionary(tiles.compactMap(path).map { ($0, 1) }, uniquingKeysWith: +)
        pinned[key(finderURL)] = 1
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleURL != nil }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
            .compactMap { app in
                let k = key(app.bundleURL!)
                if let n = pinned[k], n > 0 { pinned[k] = n - 1; return nil }
                let image = Store.load().contains { key(Installer.appURL($0)) == k } ? tileImage(app.bundleURL!) : (app.icon ?? icon(app.bundleURL!))
                return (image, app.localizedName ?? app.bundleURL!.deletingPathExtension().lastPathComponent)
            }
    }

    private static var icons: [String: NSImage] = [:]
    static func icon(_ url: URL) -> NSImage {
        if let i = icons[url.path] { return i }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        icons[url.path] = i
        return i
    }

    /// Pins cl_audit looks after: its icon apps and Claude.
    static func managedMarks(_ tiles: [[String: Any]], accounts: [AccountEntry]) -> Set<Int> {
        let ours = Set(accounts.map { key(Installer.appURL($0)) } + [key(settingsURL), key(claudeURL)])
        return Set(tiles.indices.filter { i in path(tiles[i]).map { ours.contains($0) || isIconApp($0) } ?? false })
    }

    /// The pins that keep their order between `now` and `after` (longest common run), by index on each side.
    static func kept(_ now: [[String: Any]], _ after: [[String: Any]]) -> (now: Set<Int>, after: Set<Int>) {
        let n = now.map { path($0) ?? "" }, a = after.map { path($0) ?? "" }
        var table = Array(repeating: Array(repeating: 0, count: a.count + 1), count: n.count + 1)
        for i in stride(from: n.count - 1, through: 0, by: -1) {
            for j in stride(from: a.count - 1, through: 0, by: -1) {
                table[i][j] = n[i] == a[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var kn = Set<Int>(), ka = Set<Int>(), i = 0, j = 0
        while i < n.count && j < a.count {
            if n[i] == a[j] { kn.insert(i); ka.insert(j); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }
        return (kn, ka)
    }

    /// Pins in `now` that go: removed, or moved away from here.
    static func removedMarks(_ now: [[String: Any]], _ after: [[String: Any]]) -> Set<Int> {
        Set(now.indices).subtracting(kept(now, after).now)
    }

    /// Pins in `after` that are new, or moved here.
    static func changedMarks(_ now: [[String: Any]], _ after: [[String: Any]]) -> Set<Int> {
        Set(after.indices).subtracting(kept(now, after).after)
    }

    /// Whether the profile icons are pinned side by side, in profile order, with the cl_audit app last.
    static func iconsInOrder(_ tiles: [[String: Any]], accounts: [AccountEntry]) -> Bool {
        let wanted = (accounts.map { Installer.appURL($0) } + [settingsURL]).filter { FileManager.default.fileExists(atPath: $0.path) }.map(key)
        let paths = tiles.map(path)
        let found = paths.indices.filter { i in paths[i].map { wanted.contains($0) || isIconApp($0) } ?? false }
        guard let first = found.first else { return wanted.isEmpty }
        let contiguous = found == Array(first..<(first + found.count))
        return contiguous && found.compactMap { paths[$0] } == wanted
    }

    /// One line for the card: whether the Dock already matches, and what differs.
    static func status(accounts: [AccountEntry], prefs: DockPrefs) -> (tidy: Bool, text: String) {
        let current = pins()
        let claudePins = current.filter { path($0) == key(claudeURL) }.count
        if same(current, plan(current, accounts: accounts, prefs: prefs)) {
            return (true, "Claude pinned \(claudePins == 0 ? "nowhere" : claudePins == 1 ? "once" : "\(claudePins) times")"
                    + (prefs.icons == .together ? ", profile icons together" : ""))
        }
        var parts: [String] = []
        if prefs.claude == .one && claudePins != 1 { parts.append(claudePins == 0 ? "Claude isn't pinned" : "Claude is pinned \(claudePins) times") }
        if prefs.claude == .one && claudePins == 1 && prefs.icons == .together { parts.append("Claude is pinned, but not just before the profile icons") }
        if prefs.claude == .none && claudePins > 0 { parts.append("Claude is pinned \(claudePins == 1 ? "once" : "\(claudePins) times")") }
        if prefs.icons == .together && !iconsInOrder(current, accounts: accounts) { parts.append("the profile icons are apart or out of order") }
        if parts.count > 1, parts.contains("Claude is pinned, but not just before the profile icons"), parts.contains("the profile icons are apart or out of order") {
            parts.removeAll { $0 == "Claude is pinned, but not just before the profile icons" }
        }
        let reason = parts.isEmpty ? "the pins differ" : parts.joined(separator: "; ")
        return (false, reason.prefix(1).uppercased() + reason.dropFirst())
    }

    /// Writes the planned list and restarts the Dock, only if it differs. Saves the original list first.
    @discardableResult
    static func tidy(accounts: [AccountEntry], prefs: DockPrefs = .shared) -> Bool {
        let current = pins()
        let wanted = plan(current, accounts: accounts, prefs: prefs)
        guard !same(current, wanted) else { return false }
        prefs.saveBackup(current)
        DockWriter.update("arrange the Dock") { l in
            let w = plan(l.pinned, accounts: accounts, prefs: prefs)
            if !same(l.pinned, w) { l.pinned = w }
        }
        return true
    }

    /// After accounts change (Apply, add, remove, rename): tidy when "Manage the Dock" is on.
    static func afterAccountsChanged(_ accounts: [AccountEntry]) {
        guard DockPrefs.shared.manage else { return }
        tidy(accounts: accounts)
    }

    /// Takes one app's pin out of the Dock (Usage in the Dock off) and remembers its left neighbour, to put it back there.
    static func unpinRemembering(_ app: URL, defaults: UserDefaults) {
        let list = pins(), k = key(app)
        markChange(app)
        guard let i = list.firstIndex(where: { path($0) == k }) else { dockLog.log("unpin \(k, privacy: .public): not pinned"); return }
        defaults.set(true, forKey: "dockWasPinned")
        defaults.set(i > 0 ? (path(list[i - 1]) ?? "") : "", forKey: "dockLeftNeighbour")
        dockLog.log("unpin \(k, privacy: .public): at \(i)")
        // the writer checks after the Dock restarts and writes again if the Dock put it back; flipped back on
        // meanwhile, nothing is taken out
        DockWriter.update("unpin \(k)") { l in
            guard wantsShown(app) != true else { return }
            l.pinned.removeAll { path($0) == k }
        }
    }

    /// Puts back a pin taken out by `unpinRemembering` (the agent, when Usage in the Dock is turned on): back where it
    /// was, or, never pinned before, after the other cl_audit icons. In the background: it waits for the Dock to
    /// settle, pins, and checks after the Dock restarts.
    static func repinInBackground(_ app: URL) {
        markChange(app)
        guard !isPinned(app) else { dockLog.log("repin \(key(app), privacy: .public): already pinned"); return }
        let d = appDefaults(app)
        let neighbour = d?.bool(forKey: "dockWasPinned") == true ? d?.string(forKey: "dockLeftNeighbour") : nil
        d?.removeObject(forKey: "dockWasPinned"); d?.removeObject(forKey: "dockLeftNeighbour")
        DispatchQueue.global(qos: .utility).async { pinFromHelper(app, after: neighbour) }
    }

    // MARK: Show in the Dock follows the Dock

    /// A Dock icon app's own preferences (where its pin place and change time are kept). Inside that app (and its
    /// --pin helper) they are the standard ones: macOS gives no suite named after the app's own bundle id, so the
    /// change mark was neither written nor read there, and turning Show in the Dock on was undone at once.
    static func appDefaults(_ app: URL) -> UserDefaults? {
        guard let id = Installer.info(app)?["CFBundleIdentifier"] as? String else { return nil }
        return id == Bundle.main.bundleIdentifier ? .standard : UserDefaults(suiteName: id)
    }

    /// cl_audit is changing this icon's place in the Dock (switch flipped, app relaunching, pin retries): for a
    /// while, a difference between the switch and the Dock is ours, not yours.
    static func markChange(_ app: URL) { appDefaults(app)?.set(Date(), forKey: "dockChangeAt") }
    /// The same, by bundle id (for a copy that is being replaced and has no Info.plist to read right now).
    static func markChange(bundleID id: String) {
        (id == Bundle.main.bundleIdentifier ? .standard : UserDefaults(suiteName: id))?.set(Date(), forKey: "dockChangeAt")
    }

    /// What `reconcilePins` does to the Dock's list, without touching the Dock (so it can be tested).
    /// - `want`: each profile's bundle id → where its Dock icon app is now (named after the profile).
    /// - `hidden`: bundle ids of profiles whose Show in the Dock is off.
    /// - `renew`: bundle ids whose picture changed (their entry is replaced by a fresh one; the Dock keeps a picture
    ///   with the entry, through restarts).
    /// - `exists` / `bundleIDAt`: the file system, for pins the Dock hasn't stamped with a bundle id.
    struct PinPlan { var list: [[String: Any]]; var changed = false; var notes: [String] = []; var marked: [URL] = [] }
    static func planPins(_ list: [[String: Any]], want: [String: URL], hidden: Set<String> = [], renew: Set<String> = [],
                         exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                         bundleIDAt: (URL) -> String? = { Installer.info($0)?["CFBundleIdentifier"] as? String }) -> PinPlan {
        var plan = PinPlan(list: [])
        var seen = Set<String>()
        for t in list {
            guard let p = filePath(t) else { plan.list.append(t); continue }
            let u = URL(fileURLWithPath: p)
            let bid = ((t["tile-data"] as? [String: Any])?["bundle-identifier"] as? String) ?? (exists(p) ? bundleIDAt(u) : nil)
            if let bid, hidden.contains(bid) {
                // a hidden profile isn't in the Dock: its pin goes (wherever it points), it never moves
                plan.notes.append("drop pin of \(bid), which is hidden"); plan.changed = true
            } else if let bid, let app = want[bid] {
                if seen.contains(bid) { plan.notes.append("drop second pin of \(bid)"); plan.changed = true; continue }
                seen.insert(bid)
                if key(app) != key(u) {
                    plan.notes.append("pin of \(bid) follows \(u.lastPathComponent) → \(app.lastPathComponent)")
                    plan.list.append(tile(app)); plan.marked.append(app); plan.changed = true
                } else if renew.contains(bid) {
                    plan.notes.append("fresh pin for \(bid) (new look)")
                    plan.list.append(tile(app)); plan.marked.append(app); plan.changed = true
                } else {
                    plan.list.append(t)
                }
            } else if isIconAppPath(u) && !exists(p) {
                plan.notes.append("drop pin of \(u.lastPathComponent), which is gone"); plan.changed = true
            } else {
                plan.list.append(t)
            }
        }
        return plan
    }

    /// Where Dock icon apps live and how they're named: /Applications/cl_audit <name>.app (not cl_audit itself).
    static func isIconAppPath(_ u: URL) -> Bool {
        u.deletingLastPathComponent().path == Installer.appsFolder.path && u.pathExtension == "app"
            && u.lastPathComponent.hasPrefix("cl_audit ")
    }

    /// The Dock's pins of Dock icon apps, matched to profiles by bundle id (the profile's fixed handle), not by the
    /// app's name: a pin left at an old name (a rename) moves to the current one in the same place, a second pin of
    /// the same profile goes, pins of apps that are gone go, and a pin whose picture changed is renewed. Reads the
    /// Dock fresh; one Dock restart, only when something changed.
    static func reconcilePins(_ accounts: [AccountEntry], renew: [URL] = []) {
        let want = Dictionary(accounts.map { (Installer.bundleID($0), Installer.appURL($0)) }, uniquingKeysWith: { a, _ in a })
        let hidden = Set(accounts.filter(\.iconHidden).map(Installer.bundleID))
        let renewIDs = Set(renew.compactMap { Installer.info($0)?["CFBundleIdentifier"] as? String })
        var renewLeft = renewIDs            // a fresh entry once, not again on the writer's check
        DockWriter.update("Dock icons") { l in
            let plan = planPins(l.pinned, want: want, hidden: hidden, renew: renewLeft)
            if plan.changed {
                plan.marked.forEach(markChange)
                plan.notes.forEach { dockLog.log("\($0, privacy: .public)") }
                l.pinned = plan.list
                renewLeft = []
            }
            // the recent apps part of the Dock can hold a renamed or removed app's old name too
            l.recent.removeAll { t in filePath(t).map { isIconAppPath(URL(fileURLWithPath: $0)) && !FileManager.default.fileExists(atPath: $0) } ?? false }
        }
    }

    /// A tile's file path as stored (not lowercased).
    static func filePath(_ tile: [String: Any]) -> String? {
        guard let t = tile["tile-data"] as? [String: Any], let f = t["file-data"] as? [String: Any],
              let s = f["_CFURLString"] as? String else { return nil }
        return (s.hasPrefix("file://") ? URL(string: s) : URL(fileURLWithPath: s))?.standardizedFileURL.path
    }

    static func changing(_ app: URL) -> Bool {
        guard let d = appDefaults(app) else { return false }
        d.synchronize()
        return (d.object(forKey: "dockChangeAt") as? Date).map { Date().timeIntervalSince($0) < 30 } ?? false
    }

    /// The Dock is the truth: when a profile's switch and the Dock disagree and cl_audit isn't changing it, the
    /// switch follows the Dock (you dragged the icon out, or kept it in the Dock by hand). Returns the new
    /// setting, or nil when nothing changes.
    static func adoptDock(_ e: AccountEntry) -> Bool? {
        let app = Installer.appURL(e)
        guard FileManager.default.fileExists(atPath: app.path), !changing(app) else { return nil }
        let pinned = isPinned(app)
        guard pinned == e.iconHidden else { return nil }
        dockLog.log("\(e.id, privacy: .public): Dock \(pinned ? "has" : "lacks", privacy: .public) it, switch follows (\(pinned ? "on" : "off", privacy: .public))")
        markChange(app)
        return !pinned
    }

    /// Whether this Dock icon app's profile wants it in the Dock right now (nil: not a profile's app).
    /// Read fresh each time, so a pin or unpin still under way stops when the switch has been flipped back.
    static func wantsShown(_ app: URL) -> Bool? {
        guard let id = Installer.info(app)?["UsageAccountID"] as? String,
              let e = Store.load().first(where: { $0.id == id }) else { return nil }
        return !e.iconHidden
    }

    /// The helper's work: wait for the Dock to settle, pin, check, and try once more.
    static func pinFromHelper(_ app: URL, after neighbour: String?) {
        // The Dock is busy with the app that just started, and rewrites its list as it restarts: pin once it has
        // settled, then check after the restart and try again (up to three times). Stops as soon as the profile
        // no longer wants it shown (the switch was flipped back meanwhile).
        Thread.sleep(forTimeInterval: 4)
        markChange(app)
        DockWriter.updateNow("pin \(key(app))") { l in
            guard wantsShown(app) != false else { return }
            l.pinned = pinned(l.pinned, app, after: neighbour)
        }
    }

    /// Pins an app if it isn't pinned: after `neighbour` ("" = first), or else right after the other cl_usage icons.
    static func pin(_ app: URL, after neighbour: String? = nil) {
        DockWriter.update("pin \(key(app))") { l in l.pinned = pinned(l.pinned, app, after: neighbour) }
    }

    /// The list with `app` pinned (unchanged if it already is).
    static func pinned(_ list: [[String: Any]], _ app: URL, after neighbour: String? = nil) -> [[String: Any]] {
        let k = key(app)
        guard !list.contains(where: { path($0) == k }) else { return list }
        var out = list, at = list.count
        if let n = neighbour {
            if n.isEmpty { at = 0 } else if let j = list.firstIndex(where: { path($0) == n }) { at = j + 1 }
        } else if let j = list.lastIndex(where: { t in path(t).map { $0 != key(settingsURL) && isIconApp($0) } ?? false }) {
            at = j + 1
        }
        out.insert(tile(app), at: min(at, list.count))
        return out
    }

    static func isPinned(_ app: URL) -> Bool { pins().contains { path($0) == key(app) } }

    static func restore(prefs: DockPrefs = .shared) {
        guard let list = prefs.backup else { return }
        DockWriter.update("restore the Dock", { l in if !same(l.pinned, list) { l.pinned = list } },
                          done: { ok in if ok { prefs.clearBackup() } })
    }

}

/// Settings ▸ Dashboard ▸ Dock. Written so each part says what it does: one switch with its effect spelled
/// out, the Dock as a picture, then the two choices as plain options, and an undo.
struct DockCard: View {
    @ObservedObject private var prefs = DockPrefs.shared
    @State private var tick = 0
    @Environment(\.face) private var face

    var body: some View {
        let _ = tick
        let accounts = Store.load()
        let st = DockManager.status(accounts: accounts, prefs: prefs)
        let now = DockManager.pins()
        let after = DockManager.plan(now, accounts: accounts, prefs: prefs)
        return SCard(title: "Dock") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Keep the Dock in order").font(.system(size: 12.5, weight: .medium))
                        DisplayWindow(text: "Experimental", tone: .amber, height: 18, size: 9)
                    }
                    Text("Pins the profile icons side by side, in profile order, with at most one Claude pin before them. Several Claude pins get mixed up between Claude windows; the profile icons always open the right one. Redone when you add or remove an account.")
                        .font(.system(size: 11)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5)).foregroundStyle(face.caution)
                        Text("Invasive and error-prone: it rewrites your Dock's pin list and restarts the Dock, and macOS can misplace or drop pins along the way. “Restore my Dock” puts back the pins saved before the first change.")
                            .font(.system(size: 11)).foregroundStyle(face.caution).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: Binding(get: { prefs.manage }, set: { on in
                    prefs.manage = on
                    if on { DockManager.tidy(accounts: accounts); refreshSoon() }
                })).smallSwitch()
            }
            .padding(.vertical, 4)

            if prefs.manage {
                divider
                // The Dock as it is (and as it would be), with its status and the one action.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        LED(color: st.tidy ? FaceTheme.ledOn : FaceTheme.led)
                        Text(st.tidy ? "Your Dock matches these choices" : "Your Dock doesn't match yet").font(.system(size: 12))
                        Spacer(minLength: 6)
                        if !st.tidy {
                            Button("Arrange Dock") { DockManager.tidy(accounts: accounts); refreshSoon() }
                                .buttonStyle(PillButtonStyle(tint: nil, compact: true))
                                .help("Rearranges the pins as chosen below; the Dock restarts once")
                        }
                    }
                    if st.tidy {
                        DockStrip(label: "now", tiles: now, marks: DockManager.managedMarks(now, accounts: accounts), color: Color(nsColor: Painter.green))
                        caption("Your Dock: pinned apps, then running ones after the divider. Outlined: the pins cl_audit keeps in order. Hover an icon for its name.")
                    } else {
                        caption(st.text, color: face.caution)
                        DockStrip(label: "now", tiles: now, marks: DockManager.removedMarks(now, after), color: .red)
                        DockStrip(label: "after", tiles: after, marks: DockManager.changedMarks(now, after), color: Color(nsColor: Painter.green))
                        caption("Red: pins Arrange Dock removes or moves away. Green: where they go, and new pins. Running apps are shown in launch order; the Dock may order them differently.")
                    }
                }
                .padding(.vertical, 8)

                divider
                choices(title: "Claude pins", options: [
                    (DockPrefs.ClaudePins.one, "One Claude pin, just before the profile icons", "It opens the standard Claude window"),
                    (.none, "No Claude pin", "Open each Claude window from its cl_audit icon"),
                    (.leave, "Don't touch Claude pins", "Leave them as you placed them")],
                        selected: prefs.claude) { prefs.claude = $0; DockManager.tidy(accounts: accounts); refreshSoon() }
                divider
                choices(title: "Profile icons", options: [
                    (DockPrefs.Icons.together, "Side by side, in profile order", "The cl_audit app last"),
                    (.leave, "Don't move them", "Leave them as you placed them")],
                        selected: prefs.icons) { prefs.icons = $0; DockManager.tidy(accounts: accounts); refreshSoon() }
            }

            if let date = prefs.backupDate {
                divider
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Undo cl_audit's Dock changes").font(.system(size: 12))
                        caption("Puts back your pins as they were on \(date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                    }
                    Spacer(minLength: 6)
                    Button("Restore my Dock") { DockManager.restore(); refreshSoon() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
                }
                .padding(.vertical, 6)
            }
        }
        .onAppear { tick += 1 }
    }

    private var divider: some View { EngravedRule() }

    private func caption(_ s: String, color: Color? = nil) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(color ?? face.muted).fixedSize(horizontal: false, vertical: true)
    }

    /// A small group of radio choices, each with a one-line note.
    private func choices<T: Hashable>(title: String, options: [(T, String, String)], selected: T, pick: @escaping (T) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(face.muted).padding(.bottom, 2)
            ForEach(options.indices, id: \.self) { i in
                let o = options[i], on = o.0 == selected
                Button { pick(o.0) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        LEDRadio(on: on).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(o.1).font(.system(size: 12, weight: on ? .medium : .regular))
                            Text(o.2).font(.system(size: 10.5)).foregroundStyle(face.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }

    /// The Dock rewrites its list as it restarts; look again shortly after.
    private func refreshSoon() {
        tick += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { tick += 1 }
    }
}

/// A row of pinned apps drawn with their real icons; marked ones get a coloured outline.
struct DockStrip: View {
    let label: String
    let tiles: [[String: Any]]
    let marks: Set<Int>
    let color: Color
    @Environment(\.face) private var face

    var body: some View {
        HStack(spacing: 6) {
            Printed(text: label, size: 8.5).frame(width: 34, alignment: .leading)
            // As the Dock shows it: Finder, the pinned apps, a divider, then running apps that aren't pinned.
            HStack(spacing: 3) {
                tile(DockManager.icon(DockManager.finderURL), name: "Finder", mark: false)
                ForEach(tiles.indices, id: \.self) { i in
                    let url = DockManager.fileURL(tiles[i])
                    tile(url.map { DockManager.tileImage($0) } ?? NSImage(), name: url?.deletingPathExtension().lastPathComponent ?? "", mark: marks.contains(i))
                }
                let running = DockManager.running(besides: tiles)
                if !running.isEmpty {
                    Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 1, height: 16).padding(.horizontal, 3)
                    ForEach(running.indices, id: \.self) { i in tile(running[i].image, name: running[i].name + " (running)", mark: false) }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .faceWindow(radius: 6)
        }
    }

    private func tile(_ image: NSImage, name: String, mark: Bool) -> some View {
        Image(nsImage: image)
            .resizable().interpolation(.high).frame(width: 18, height: 18)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(mark ? color : .clear, lineWidth: 1.5).padding(-1.5))
            .opacity(mark && color == .red ? 0.55 : 1)
            .help(name)
    }
}
