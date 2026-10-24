// Managing the Dock (Settings ▸ Dashboard ▸ Dock, off by default): keeps the cl_audit icons pinned together in
// account order with the cl_audit app last, and keeps at most one Claude pin, placed before the group. macOS ties
// running Claude windows to Claude pins in its own order, so several pins get mixed up; the cl_audit icons are
// the reliable way to reach each account's window. Only the Dock's pin list (com.apple.dock persistent-apps)
// is changed, and the Dock restarts once, only when something differs. The list is saved before the first
// change so it can be restored.

import AppKit
import SwiftUI

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

    /// The pin list as it should be, from the current one. Apps that aren't cl_audit's or Claude stay in place.
    static func plan(_ current: [[String: Any]], accounts: [AccountEntry], prefs: DockPrefs) -> [[String: Any]] {
        let claudeKey = key(claudeURL)
        let ours = accounts.map { key(Installer.appURL($0)) } + [key(settingsURL)]
        let oursURLs = accounts.map { Installer.appURL($0) } + [settingsURL]
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

    private static var icons: [String: NSImage] = [:]
    static func icon(_ url: URL) -> NSImage {
        if let i = icons[url.path] { return i }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        icons[url.path] = i
        return i
    }

    /// Pins in `now` that `after` drops (the extra copies of a path).
    static func removedMarks(_ now: [[String: Any]], _ after: [[String: Any]]) -> Set<Int> {
        var left = Dictionary(after.compactMap(path).map { ($0, 1) }, uniquingKeysWith: +)
        var out = Set<Int>()
        for (i, t) in now.enumerated() {
            guard let p = path(t) else { continue }
            if (left[p] ?? 0) > 0 { left[p]! -= 1 } else { out.insert(i) }
        }
        return out
    }

    /// Pins in `after` that are new, or whose neighbour on the left changed (moved).
    static func changedMarks(_ now: [[String: Any]], _ after: [[String: Any]]) -> Set<Int> {
        let n = now.map(path), a = after.map(path)
        var out = Set<Int>()
        var seen: [String: Int] = [:]
        for (i, p) in a.enumerated() {
            guard let p else { continue }
            let k = seen[p, default: 0]; seen[p] = k + 1
            let positions = n.indices.filter { n[$0] == p }
            guard k < positions.count else { out.insert(i); continue }      // added
            let before = positions[k] > 0 ? n[positions[k] - 1] : nil
            let left = i > 0 ? a[i - 1] : nil
            if before != left { out.insert(i) }
        }
        return out
    }

    /// One line for the card: whether the Dock already matches, and what differs.
    static func status(accounts: [AccountEntry], prefs: DockPrefs) -> (tidy: Bool, text: String) {
        let current = pins()
        let claudePins = current.filter { path($0) == key(claudeURL) }.count
        if same(current, plan(current, accounts: accounts, prefs: prefs)) {
            return (true, "Tidy: Claude pinned \(claudePins == 0 ? "nowhere" : claudePins == 1 ? "once" : "\(claudePins) times")"
                    + (prefs.icons == .together ? ", cl_audit icons together" : ""))
        }
        var parts: [String] = []
        if prefs.claude == .one && claudePins != 1 { parts.append(claudePins == 0 ? "Claude isn't pinned" : "Claude is pinned \(claudePins) times") }
        if prefs.claude == .none && claudePins > 0 { parts.append("Claude is pinned \(claudePins == 1 ? "once" : "\(claudePins) times")") }
        if prefs.icons == .together { parts.append("the cl_audit icons are apart or out of order") }
        return (false, "Not tidy: " + (parts.isEmpty ? "the pins differ" : parts.joined(separator: "; ")))
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

    static func restore(prefs: DockPrefs = .shared) {
        guard let list = prefs.backup else { return }
        write(list)
        prefs.clearBackup()
    }

    private static func write(_ list: [[String: Any]]) {
        CFPreferencesSetAppValue(key, list as CFArray, dock)
        CFPreferencesAppSynchronize(dock)
        Installer.run("/usr/bin/killall", ["Dock"])
    }
}

/// Settings ▸ Dashboard ▸ Dock.
struct DockCard: View {
    @ObservedObject private var prefs = DockPrefs.shared
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let accounts = Store.load()
        let st = DockManager.status(accounts: accounts, prefs: prefs)
        let now = DockManager.pins()
        let after = DockManager.plan(now, accounts: accounts, prefs: prefs)
        return SCard(title: "Dock") {
            SRow(label: "Manage the Dock", info: "Keeps the cl_audit icons pinned together and Claude pinned at most once. With several Claude windows open, macOS mixes up which Claude pin is which; the cl_audit icons always open the right window.", first: true) {
                Toggle("", isOn: Binding(get: { prefs.manage }, set: { on in
                    prefs.manage = on
                    if on { DockManager.tidy(accounts: accounts); refreshSoon() }
                })).smallSwitch()
            }
            if prefs.manage {
                SRow(label: "cl_audit icons", info: "Pinned side by side in account order, the cl_audit app last. Pins follow as accounts are added or removed.") {
                    PillPicker(options: DockPrefs.Icons.allCases, selection: Binding(get: { prefs.icons }, set: { prefs.icons = $0; DockManager.tidy(accounts: accounts); refreshSoon() }),
                               compact: true) { $0 == .together ? "Together" : "Leave as is" }
                }
                SRow(label: "Claude pins", info: "One pin opens the standard Claude window. More pins get mixed up between windows.") {
                    PillPicker(options: DockPrefs.ClaudePins.allCases, selection: Binding(get: { prefs.claude }, set: { prefs.claude = $0; DockManager.tidy(accounts: accounts); refreshSoon() }),
                               compact: true) { $0 == .one ? "One" : $0 == .none ? "None" : "Leave" }
                }
                SRow(label: "Now") {
                    HStack(spacing: 6) {
                        Circle().fill(st.tidy ? Color(nsColor: Painter.green) : Color.orange).frame(width: 7, height: 7)
                        Text(st.tidy ? "Tidy" : "Not tidy").font(.system(size: 12)).help(st.text)
                        if !st.tidy {
                            Button("Tidy now") { DockManager.tidy(accounts: accounts); refreshSoon() }
                                .buttonStyle(PillButtonStyle(tint: nil, compact: true))
                                .help("Restarts the Dock once")
                                .padding(.leading, 6)
                        }
                    }
                }
                if !st.tidy {
                    VStack(alignment: .leading, spacing: 4) {
                        DockStrip(label: "now", tiles: now, marks: DockManager.removedMarks(now, after), color: .red)
                        DockStrip(label: "after", tiles: after, marks: DockManager.changedMarks(now, after), color: Color(nsColor: Painter.green))
                        Text("Your Dock's pinned apps; red: pins removed, green: pins moved or added. Hover an icon for its name.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 6)
                }
            }
            if let date = prefs.backupDate {
                SRow(label: "Before cl_audit", info: "Your Dock's pins as they were on \(date.formatted(.dateTime.day().month(.abbreviated).hour().minute())), saved before cl_audit first changed them.") {
                    Button("Restore my Dock") { DockManager.restore(); refreshSoon() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
                }
            }
        }
        .onAppear { tick += 1 }
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

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(tiles.indices, id: \.self) { i in
                    let url = DockManager.fileURL(tiles[i])
                    Image(nsImage: url.map { DockManager.icon($0) } ?? NSImage())
                        .resizable().interpolation(.high).frame(width: 18, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(marks.contains(i) ? color : .clear, lineWidth: 1.5).padding(-1.5))
                        .opacity(marks.contains(i) && color == .red ? 0.55 : 1)
                        .help(url?.deletingPathExtension().lastPathComponent ?? "")
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
        }
    }
}
