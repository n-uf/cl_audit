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
        write(wanted)
        return true
    }

    /// After accounts change (Apply, add, remove, rename): tidy when "Manage the Dock" is on.
    static func afterAccountsChanged(_ accounts: [AccountEntry]) {
        guard DockPrefs.shared.manage else { return }
        tidy(accounts: accounts)
    }

    /// Takes one app's pin out of the Dock (hiding cl_usage) and remembers its left neighbour, to put it back there.
    static func unpinRemembering(_ app: URL, defaults: UserDefaults) {
        let list = pins(), k = key(app)
        markChange(app)
        guard let i = list.firstIndex(where: { path($0) == k }) else { dockLog.log("unpin \(k, privacy: .public): not pinned"); return }
        defaults.set(true, forKey: "dockWasPinned")
        defaults.set(i > 0 ? (path(list[i - 1]) ?? "") : "", forKey: "dockLeftNeighbour")
        var kept = list; kept.remove(at: i)
        dockLog.log("unpin \(k, privacy: .public): at \(i), writing")
        write(kept)
        // the Dock may still be settling (the app has just started): look again, and once more if it came back
        DispatchQueue.global(qos: .utility).async {
            for attempt in 1...3 {
                Thread.sleep(forTimeInterval: 3)
                if wantsShown(app) == true { dockLog.log("unpin \(k, privacy: .public): switched on meanwhile, stopping"); return }
                guard isPinned(app) else { dockLog.log("unpin \(k, privacy: .public): gone (check \(attempt))"); return }
                dockLog.log("unpin \(k, privacy: .public): still pinned (check \(attempt)), writing again")
                write(pins().filter { path($0) != k })
            }
        }
    }

    /// Puts back a pin taken out by `unpinRemembering`. The app has just become a Dock app again, and the Dock
    /// rewrites its list around that, so this waits a moment, pins, and checks once more.
    static func repin(_ app: URL, defaults: UserDefaults) {
        // shown means in the Dock: back where it was, or, never pinned before, after the other cl_audit icons
        markChange(app)
        guard !isPinned(app) else { dockLog.log("repin \(key(app), privacy: .public): already pinned"); return }
        let neighbour = defaults.bool(forKey: "dockWasPinned") ? defaults.string(forKey: "dockLeftNeighbour") : nil
        defaults.removeObject(forKey: "dockWasPinned"); defaults.removeObject(forKey: "dockLeftNeighbour")
        // Done by a short helper process (this app started with --pin): inside the app that just became a Dock app
        // again, the Dock overwrote the change.
        guard let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--pin", app.path, neighbour ?? "-"]
        do { try p.run(); dockLog.log("repin \(key(app), privacy: .public): helper started") }
        catch { dockLog.error("repin \(key(app), privacy: .public): helper failed \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Show in the Dock follows the Dock

    /// A Dock icon app's own preferences (where its pin place and change time are kept).
    static func appDefaults(_ app: URL) -> UserDefaults? {
        (Installer.info(app)?["CFBundleIdentifier"] as? String).flatMap { UserDefaults(suiteName: $0) }
    }

    /// cl_audit is changing this icon's place in the Dock (switch flipped, app relaunching, pin retries): for a
    /// while, a difference between the switch and the Dock is ours, not yours.
    static func markChange(_ app: URL) { appDefaults(app)?.set(Date(), forKey: "dockChangeAt") }

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
        for attempt in 1...3 {
            if wantsShown(app) == false { dockLog.log("pin \(key(app), privacy: .public): switched off meanwhile, stopping"); return }
            markChange(app)
            pin(app, after: neighbour)
            Thread.sleep(forTimeInterval: 6)
            if isPinned(app) { dockLog.log("pin \(key(app), privacy: .public): pinned (try \(attempt))"); return }
            dockLog.log("pin \(key(app), privacy: .public): not there after try \(attempt)")
        }
    }

    /// Pins an app if it isn't pinned: after `neighbour` ("" = first), or else right after the other cl_usage icons.
    static func pin(_ app: URL, after neighbour: String? = nil) {
        var list = pins()
        let k = key(app)
        guard !list.contains(where: { path($0) == k }) else { return }
        var at = list.count
        if let n = neighbour {
            if n.isEmpty { at = 0 } else if let j = list.firstIndex(where: { path($0) == n }) { at = j + 1 }
        } else if let j = list.lastIndex(where: { t in path(t).map { $0 != key(settingsURL) && isIconApp($0) } ?? false }) {
            at = j + 1
        }
        list.insert(tile(app), at: min(at, list.count))
        write(list)
    }

    static func isPinned(_ app: URL) -> Bool { pins().contains { path($0) == key(app) } }

    static func restore(prefs: DockPrefs = .shared) {
        guard let list = prefs.backup else { return }
        write(list)
        prefs.clearBackup()
    }

    private static func write(_ list: [[String: Any]]) {
        CFPreferencesSetAppValue(key, list as CFArray, dock)
        let ok = CFPreferencesAppSynchronize(dock)
        dockLog.log("write \(list.count) pins, synced \(ok), restarting the Dock")
        Installer.run("/usr/bin/killall", ["Dock"])
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
