// Removing an account. Always: its Dock icon app and everything macOS keeps for it (open-at-login entry,
// preferences, caches, network storage, saved window state, Dock pin, Launch Services record), its saved
// status, its Terminal scripts and its place in the dashboard. Optionally its folders too: the Claude Code
// folder (signed out first, so its Keychain login goes) and the separate Claude window's data folder.
// The default ~/.claude and the standard Claude window are never deleted.

import AppKit
import SwiftUI

enum AccountRemoval {
    static let library = URL(fileURLWithPath: expand("~/Library"))

    // MARK: what macOS keeps for an icon app

    /// Files macOS and the app keep for an icon app's bundle id, in ~/Library.
    static func leftovers(_ id: String) -> [URL] {
        let b = "\(Installer.managerID).\(id)"
        return ["Caches/\(b)", "HTTPStorages/\(b)", "HTTPStorages/\(b).binarycookies", "Preferences/\(b).plist",
                "Saved Application State/\(b).savedState", "WebKit/\(b)", "Application Support/\(b)"]
            .map { library.appendingPathComponent($0) }
    }

    /// Removes what an icon app leaves behind once the app itself is gone.
    static func purgeApp(id: String, app: URL) {
        let fm = FileManager.default
        Installer.run("/usr/bin/defaults", ["delete", "\(Installer.managerID).\(id)"])
        for u in leftovers(id) where fm.fileExists(atPath: u.path) { try? fm.removeItem(at: u) }
        Store.removeStatus(id)
        unpinFromDock(app)
        Installer.run(lsregister, ["-u", app.path])
    }

    /// Ids that still have files in ~/Library but no account (left by older versions); cleaned on each sync.
    static func orphanIDs(keeping ids: Set<String>) -> [String] {
        let prefix = "\(Installer.managerID)."
        var found = Set<String>()
        for sub in ["Caches", "HTTPStorages", "Preferences", "Saved Application State"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: library.appendingPathComponent(sub).path)) ?? []
            for var n in names {
                // Strip the extension first, so the settings app's own "local.usage-n-uf.plist" isn't read as an id.
                for ext in [".plist", ".savedState", ".binarycookies"] where n.hasSuffix(ext) { n = String(n.dropLast(ext.count)) }
                guard n.hasPrefix(prefix) else { continue }
                let id = String(n.dropFirst(prefix.count))
                if !id.isEmpty, !id.contains("."), !ids.contains(id) { found.insert(id) }
            }
        }
        return found.sorted()
    }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Takes the app out of the Dock's kept icons, so no "?" stays behind. Restarts the Dock only if it was there.
    static func unpinFromDock(_ app: URL) {
        let key = "persistent-apps" as CFString, dock = "com.apple.dock" as CFString
        guard let items = CFPreferencesCopyAppValue(key, dock) as? [[String: Any]] else { return }
        let target = app.standardizedFileURL.path
        let kept = items.filter { item in
            guard let tile = item["tile-data"] as? [String: Any], let file = tile["file-data"] as? [String: Any],
                  let s = file["_CFURLString"] as? String, let u = URL(string: s) else { return true }
            return u.standardizedFileURL.path != target
        }
        guard kept.count != items.count else { return }
        CFPreferencesSetAppValue(key, kept as CFArray, dock)
        CFPreferencesAppSynchronize(dock)
        Installer.run("/usr/bin/killall", ["Dock"])
    }

    // MARK: the account's folders

    /// Why the folders can't be deleted, or nil when they can.
    static func folderBlock(_ e: AccountEntry, among accounts: [AccountEntry]) -> String? {
        if Account(e).isDefaultDir { return "~/.claude is the default Claude Code folder; it's never deleted" }
        let others = accounts.filter { $0.id != e.id }
        let linked = others.filter { linksInto(e.configDir, from: $0.configDir) }
        if !linked.isEmpty {
            return "\(linked.map(\.name).joined(separator: ", ")) share\(linked.count == 1 ? "s" : "") items from \(e.configDir)"
        }
        return nil
    }

    /// The folders "Delete its folders" would delete.
    static func folders(_ e: AccountEntry) -> [String] {
        var out: [String] = []
        if !Account(e).isDefaultDir, FileManager.default.fileExists(atPath: expand(e.configDir)) { out.append(e.configDir) }
        if e.desktop == .separate, !e.desktopDataDir.isEmpty,
           FolderKey.canonical(e.desktopDataDir) != FolderKey.canonical(FolderKey.standardDataDir),
           FileManager.default.fileExists(atPath: expand(e.desktopDataDir)) { out.append(e.desktopDataDir) }
        return out
    }

    /// Whether `folder` holds links pointing into `dir` (another account shares items from it).
    static func linksInto(_ dir: String, from folder: String) -> Bool {
        let fm = FileManager.default, base = expand(folder), key = FolderKey.canonical(dir)
        for name in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
            let p = (base as NSString).appendingPathComponent(name)
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: p) else { continue }
            let abs = dest.hasPrefix("/") ? dest : (base as NSString).appendingPathComponent(dest)
            let k = FolderKey.canonical(abs)
            if k == key || k.hasPrefix(key + "/") { return true }
        }
        return false
    }

    /// Running Claude that uses the account's folders (they must be closed before deleting them).
    static func runsUsing(_ e: AccountEntry, _ runs: [ClaudeRun]) -> [ClaudeRun] {
        runs.filter { r in
            switch r.kind {
            case .desktop: return e.desktop == .separate && !e.desktopDataDir.isEmpty && FolderKey.overlaps(r.folder, e.desktopDataDir)
            case .codeTab, .terminal: return FolderKey.overlaps(r.folder, e.configDir)
            }
        }
    }

    /// Total size of a folder, without following links. Call off the main thread.
    static func size(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: expand(path))
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in walk {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true { walk.skipDescendants(); continue }
            total += Int64(v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Signs the Claude Code folder out (its Keychain login goes), quits its Claude window and deletes the
    /// folders. Links inside are removed, never what they point to. Blocks; call off the main thread.
    /// Returns what couldn't be deleted.
    static func deleteFolders(_ e: AccountEntry, claude: String?) -> [String] {
        let fm = FileManager.default
        let dirs = folders(e)
        if dirs.contains(e.configDir), let claude, Account.expectedEmail(configDir: e.configDir) != nil {
            ClaudeCLI.logout(claude, configDir: e.configDir)
        }
        let account = Account(e)
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
            .filter { e.desktop == .separate && Launcher.isWindow(of: account, $0) }
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while apps.contains(where: { !$0.isTerminated }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        var failed: [String] = []
        for d in dirs {
            do { try fm.removeItem(at: URL(fileURLWithPath: expand(d))) } catch { failed.append(d) }
        }
        return failed
    }

    /// Terminal scripts written for the folder (sign-in and "open in Terminal").
    static func removeScripts(_ configDir: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: ClaudeCLI.loginScript(configDir))
        try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent("usage-n-uf-claude-\(Account.sha8(configDir)).command"))
    }
}

// MARK: - The dialog

/// Remove an account: what always goes, and a choice to keep or delete its folders.
struct RemoveAccountSheet: View {
    let entry: AccountEntry
    @ObservedObject var model: SettingsModel
    @StateObject private var monitor = RunsMonitor()
    @State private var deleteFolders = false
    @State private var sizes: [String: Int64] = [:]
    @State private var checking = false
    @Environment(\.dismiss) private var dismiss

    private var folders: [String] { AccountRemoval.folders(entry) }
    private var block: String? { AccountRemoval.folderBlock(entry, among: model.accounts) }
    private var running: [ClaudeRun] { deleteFolders ? AccountRemoval.runsUsing(entry, monitor.runs) : [] }
    private var canRemove: Bool { !deleteFolders || (block == nil && monitor.checked && running.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove “\(entry.name)”").font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("ALWAYS REMOVED").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                bullet("Its Dock icon “cl_audit \(entry.name)”, and its pin in the Dock")
                bullet("Its open-at-login entry, saved usage, preferences and caches")
                bullet("Its place on the dashboard")
            }

            VStack(spacing: 1) {
                option(selected: !deleteFolders, title: "Keep its folders",
                       detail: "\(entry.configDir) and its sign-in stay; you can add it again later") { deleteFolders = false }
                option(selected: deleteFolders, title: "Delete its folders too",
                       detail: block ?? (folders.isEmpty ? "Nothing to delete" : "Signs out, then deletes " + folders.map(describe).joined(separator: " and ") + ", with its history"),
                       disabled: block != nil || folders.isEmpty) { deleteFolders = true }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.09)))

            if deleteFolders && !running.isEmpty { runningBox }

            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction)
                Spacer()
                Button(deleteFolders ? "Remove and delete folders" : "Remove") {
                    let e = entry, del = deleteFolders
                    dismiss()
                    model.removeAccount(e, deleteFolders: del)
                }
                .buttonStyle(.pill(.red, compact: true))
                .disabled(!canRemove)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            monitor.start()
            let list = folders
            DispatchQueue.global(qos: .utility).async {
                let s = Dictionary(uniqueKeysWithValues: list.map { ($0, AccountRemoval.size($0)) })
                DispatchQueue.main.async { sizes = s }
            }
        }
        .onDisappear { monitor.stop() }
    }

    /// "~/.claude-work (632 MB)", or "its Claude window's data (455 MB)" for the window's data folder.
    private func describe(_ path: String) -> String {
        let name = path == entry.configDir ? path : "its Claude window's data"
        guard let b = sizes[path] else { return name }
        return "\(name) (\(ByteCountFormatter.string(fromByteCount: b, countStyle: .file)))"
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(Color.secondary.opacity(0.6)).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0.height / 2 + 4 }
            Text(s).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func option(selected: Bool, title: String, detail: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Circle().strokeBorder(selected ? Color.white : Color.secondary, lineWidth: selected ? 4 : 1.4)
                    .frame(width: 13, height: 13).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(selected ? 0.1 : 0.03))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    /// Claude still using the folders: they must be closed first.
    private var runningBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Close Claude first: it's using these folders").font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
            ForEach(running, id: \.id) { r in
                Text((r.kind == .desktop ? "Claude window" : r.kind == .codeTab ? "Code tab session" : "Terminal session (type /exit)") + " · " + r.folder)
                    .font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                if running.contains(where: { $0.kind == .desktop }) {
                    Button("Quit its Claude window") {
                        let account = Account(entry)
                        NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
                            .filter { Launcher.isWindow(of: account, $0) }.forEach { $0.terminate() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { monitor.refresh() }
                    }
                    .buttonStyle(.pill(.red, compact: true))
                }
                Spacer()
                Button {
                    checking = true; monitor.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { checking = false }
                } label: { Text(checking ? "Checking…" : "Check again") }
                .buttonStyle(PillButtonStyle(tint: nil, compact: true)).disabled(checking)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.35)))
    }
}
