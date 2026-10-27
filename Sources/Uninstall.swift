// Uninstall: removes cl_audit and everything it made on this Mac. Settings ▸ General ▸ Uninstall cl_audit…, the cl_audit
// menu, `UsageDock --uninstall [--yes] [--delete-folders=<profile ids>]`, and the self-clean-up when cl_audit.app was
// moved to the Trash.
//
// Always removed: every Dock icon app and its pin, the agent and its background item, saved usage, settings, caches
// and preferences, Terminal scripts, then cl_audit itself (to the Trash). Per profile, only when asked: its Claude Code
// folder (signed out first) and its own Claude window's data folder; never ~/.claude or the standard window, and a
// folder another profile shares items from only together with that profile's. The Trash self-clean-up never deletes
// folders.

import AppKit
import SwiftUI

enum Uninstall {
    /// What always goes, in words.
    static func always() -> [String] {
        let apps = Installer.installed().map { $0.url.deletingPathExtension().lastPathComponent }
        return [apps.isEmpty ? "No Dock icon apps are installed" :
                    "\(apps.count) Dock icon app\(apps.count == 1 ? "" : "s") and \(apps.count == 1 ? "its pin" : "their pins"): " + apps.joined(separator: ", "),
                "The cl_audit agent and its background item",
                "Saved usage, settings, caches and preferences (\(tilde(Store.folder.path)) and the rest)",
                "Terminal scripts cl_audit wrote",
                "cl_audit itself, to the Trash"]
    }

    /// The folders that may go for a profile when these profiles' Claude Code folders go: (Claude Code folder, window
    /// data folder), nil for one that's never deleted or isn't there, and why its Claude Code folder can't go.
    static func options(_ e: AccountEntry, accounts: [AccountEntry], deleting: Set<String>) -> (config: String?, window: String?, block: String?) {
        let fs = AccountRemoval.folders(e)
        let config = fs.contains(e.configDir) ? e.configDir : nil
        let window = fs.first { $0 != e.configDir }
        // a folder others share items from goes only together with theirs
        let block = Account(e).isDefaultDir ? nil : AccountRemoval.folderBlock(e, among: accounts.filter { !deleting.contains($0.id) || $0.id == e.id })
        return (config, window, block)
    }

    /// Does it, in order. Blocks; call off the main thread (or from the command line). `trash`: cl_audit.app to move to
    /// the Trash at the end (nil when it's already there). Returns what was kept, in words.
    @discardableResult
    static func run(deleteConfig: Set<String>, deleteWindow: Set<String>, trash: URL?, claude: String?,
                    log: (String) -> Void = { print($0) }) -> [String] {
        let fm = FileManager.default
        let accounts = Store.loadChecked() ?? []
        // 1. the agent: unregistered (from cl_audit's own program; otherwise launchd is told to stop it) and stopped
        log("Stopping the cl_audit agent")
        if Bundle.main.bundleIdentifier == Installer.managerID { try? Agent.service.unregister() }
        else { Installer.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Agent.bundleID)"], timeout: 10) }
        if let m = Agent.readMark(), m.pid != getpid(), kill(m.pid, 0) == 0 { kill(m.pid, SIGTERM) }
        // 2. the Dock icon apps quit, their Claude windows left alone
        let apps = Installer.installed()
        log("Quitting \(apps.count) Dock icon app\(apps.count == 1 ? "" : "s")")
        let me = Bundle.main.bundleURL.standardizedFileURL     // a Dock icon app doing the Trash clean-up quits last, itself
        for (url, _) in apps where url.standardizedFileURL != me { Installer.stop(url) }
        // 3. every cl_audit pin and recent-app entry, in one Dock change (your other pins stay)
        let ours = Set(apps.map { DockManager.key($0.url) } + [trash].compactMap { $0 }.map(DockManager.key)
                       + [DockManager.key(Installer.appsFolder.appendingPathComponent("cl_audit.app"))])
        let isOurs = { (t: [String: Any]) -> Bool in
            (DockManager.path(t).map { ours.contains($0) } ?? false)
                || (DockManager.filePath(t).map { DockManager.isIconAppPath(URL(fileURLWithPath: $0)) } ?? false)
        }
        let lists = DockWriter.backend.read()
        if lists.pinned.contains(where: isOurs) || lists.recent.contains(where: isOurs) {
            log("Taking cl_audit's icons out of the Dock")
            DockWriter.updateNow("uninstall: cl_audit's pins") { l in l.pinned.removeAll(where: isOurs); l.recent.removeAll(where: isOurs) }
        }
        // 4. the Dock icon apps and what macOS keeps for them
        for (url, id) in apps {
            try? fm.removeItem(at: url)
            Installer.run(AccountRemoval.lsregister, ["-u", url.path])
            AccountRemoval.purgeFiles(id)
        }
        for id in AccountRemoval.orphanIDs(keeping: []) { AccountRemoval.purgeFiles(id) }
        // 5. the folders asked for: signed out first, their Claude windows quit normally
        var kept: [String] = []
        for e in accounts {
            let o = options(e, accounts: accounts, deleting: deleteConfig)
            let config = deleteConfig.contains(e.id) && o.config != nil && o.block == nil
            let window = deleteWindow.contains(e.id) && o.window != nil
            if config || window {
                log("Deleting \(e.name)'s " + [config ? "Claude Code folder" : nil, window ? "Claude window data" : nil].compactMap { $0 }.joined(separator: " and "))
                let failed = AccountRemoval.deleteFolders(e, claude: claude, config: config, window: window)
                kept += failed.map { "\($0) (couldn't be deleted)" }
            }
            if !config { kept.append("\(e.configDir), \(e.name)'s Claude Code folder and its sign-in") }
            if let w = o.window, !window { kept.append("\(w), \(e.name)'s Claude window data") }
            AccountRemoval.removeScripts(e.configDir)
        }
        // 6. settings, saved usage, caches and preferences, Terminal scripts
        log("Deleting cl_audit's settings")
        try? fm.removeItem(at: Store.folder)
        for b in [Installer.managerID, Agent.bundleID] {
            Installer.run("/usr/bin/defaults", ["delete", b])
            for u in AccountRemoval.libraryFiles(bundleID: b) where fm.fileExists(atPath: u.path) { try? fm.removeItem(at: u) }
        }
        for f in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix("usage-n-uf-") { try? fm.removeItem(at: f) }
        // 7. cl_audit itself, to the Trash
        if let trash, fm.fileExists(atPath: trash.path) {
            log("Moving cl_audit to the Trash")
            if (try? fm.trashItem(at: trash, resultingItemURL: nil)) == nil { kept.append("\(trash.path) (move it to the Trash yourself)") }
        }
        kept.append("Notification settings for cl_audit in System Settings ▸ Notifications (remove them there if you like)")
        return kept
    }

    /// The command line: `--uninstall` lists what would go; `--yes` does it; `--delete-folders=work,starpay` adds
    /// those profiles' folders (both kinds, where allowed).
    static func commandLine(_ args: [String]) -> Int32 {
        let accounts = Store.loadChecked() ?? []
        let ids = Set(args.first { $0.hasPrefix("--delete-folders=") }.map {
            $0.dropFirst("--delete-folders=".count).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        } ?? [])
        if let bad = ids.first(where: { id in !accounts.contains { $0.id == id } }) { print("No profile with the id “\(bad)”."); return 1 }
        print("Always removed:")
        always().forEach { print("  - \($0)") }
        for e in accounts {
            let o = options(e, accounts: accounts, deleting: ids)
            let del = ids.contains(e.id)
            print("\(e.name) (\(e.id)):")
            print("  Claude Code folder: " + (o.config == nil ? "\(e.configDir), never deleted" : del && o.block == nil ? "\(e.configDir): DELETED, signed out first" : "\(e.configDir): kept" + (del ? " (\(o.block ?? ""))" : "")))
            if let w = o.window { print("  Claude window data: \(w): " + (del ? "DELETED" : "kept")) }
            else { print("  Claude window data: " + (e.desktop == .standard ? "the standard window, never deleted" : "none of its own")) }
        }
        guard args.contains("--yes") else { print("\nNothing changed. Add --yes to uninstall" + (ids.isEmpty ? " (add --delete-folders=<ids> for folders)." : ".")); return 0 }
        NSRunningApplication.runningApplications(withBundleIdentifier: Installer.managerID)
            .filter { $0.processIdentifier != getpid() }.forEach { $0.terminate() }
        let app = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil
        let kept = run(deleteConfig: ids, deleteWindow: ids, trash: app, claude: ClaudeCLI.find())
        print("\ncl_audit is uninstalled. Kept:")
        kept.forEach { print("  - \($0)") }
        return 0
    }

    // MARK: moved to the Trash

    /// Whether a path is inside a Trash (the user's, or a volume's).
    static func inTrash(_ path: String) -> Bool { path.contains("/.Trash/") || path.contains("/.Trashes/") }

    /// This program's real place now (macOS follows a moved app; Bundle.main keeps the place it started from).
    static func currentExecutablePath() -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(getpid(), &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    /// cl_audit.app was moved to the Trash (seen from the agent, which runs inside it) or is gone (seen from a Dock icon
    /// app): offers, once per move, to remove what belongs to it. Folders are never deleted here.
    static func offerTrashCleanup(defaults: UserDefaults, where place: String) {
        guard defaults.string(forKey: "trashOfferFor") != place else { return }
        defaults.set(place, forKey: "trashOfferFor")
        let apps = Installer.installed().count
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "cl_audit was moved to the Trash"
        a.informativeText = "Found \(apps) Dock icon app\(apps == 1 ? "" : "s"), the background agent and saved settings that belong to it. Remove them? Every Claude Code and Claude window folder is kept.\n\nOr put cl_audit back from the Trash and keep using it."
        a.addButton(withTitle: "Remove Them")
        a.addButton(withTitle: "Keep")
        let remove = a.runModal() == .alertFirstButtonReturn
        agentLog.log("trash: cl_audit at \(place, privacy: .public), \(remove ? "removing what belongs to it" : "kept", privacy: .public)")
        guard remove else { return }
        let kept = run(deleteConfig: [], deleteWindow: [], trash: nil, claude: nil, log: { agentLog.log("trash clean-up: \($0, privacy: .public)") })
        let done = NSAlert()
        done.messageText = "cl_audit's Dock icons, agent and settings are removed"
        done.informativeText = "Kept: " + kept.joined(separator: "; ") + ". Empty the Trash to remove cl_audit itself."
        done.runModal()
        exit(0)
    }
}

/// Shows the Uninstall sheet over the Settings page (from Settings ▸ General or the cl_audit menu).
final class UninstallUI: ObservableObject {
    static let shared = UninstallUI()
    @Published var show = false
}

/// Settings ▸ General ▸ Uninstall cl_audit…: what always goes, a choice per profile for its folders (off by default),
/// and Claude that must be closed first.
struct UninstallSheet: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var monitor = RunsMonitor()
    @State private var config: Set<String> = []
    @State private var window: Set<String> = []
    @State private var sizes: [String: Int64] = [:]
    @State private var working: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.face) private var face

    private var accounts: [AccountEntry] { model.saved }
    private var deleting: Set<String> { config.union(window) }
    /// Claude still using a folder that's about to go.
    private var running: [ClaudeRun] {
        accounts.flatMap { e -> [ClaudeRun] in
            let runs = AccountRemoval.runsUsing(e, monitor.runs)
            return runs.filter { ($0.kind == .desktop && window.contains(e.id)) || ($0.kind != .desktop && config.contains(e.id)) }
        }
    }
    private var ready: Bool { working == nil && (deleting.isEmpty || (monitor.checked && running.isEmpty)) }
    /// The Claude Code folders asked to go: a folder others share items from may go only together with theirs.
    private func opts(_ e: AccountEntry) -> (config: String?, window: String?, block: String?) {
        Uninstall.options(e, accounts: accounts, deleting: config)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uninstall cl_audit").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("ALWAYS REMOVED").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                ForEach(Uninstall.always(), id: \.self) { bullet($0) }
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(accounts) { e in profileRow(e) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .faceWindow(radius: 6)
            Text("Dock: cl_audit's pins go; your other pins stay as they are.").font(.system(size: 11)).foregroundStyle(.secondary)
            if !running.isEmpty { runningBox }
            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction)
                    .disabled(working != nil)
                Spacer()
                if let w = working { ProgressView().controlSize(.small); Text(w).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                Button(deleting.isEmpty ? "Uninstall" : "Uninstall and delete folders") { go() }
                    .buttonStyle(.pill(.red, compact: true)).disabled(!ready)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            monitor.start()
            let list = accounts.flatMap(AccountRemoval.folders)
            DispatchQueue.global(qos: .utility).async {
                let s = Dictionary(list.map { ($0, AccountRemoval.size($0)) }, uniquingKeysWith: { a, _ in a })
                DispatchQueue.main.async { sizes = s }
            }
        }
        .onDisappear { monitor.stop() }
    }

    @ViewBuilder private func profileRow(_ e: AccountEntry) -> some View {
        let o = opts(e)
        VStack(alignment: .leading, spacing: 5) {
            Text(e.name).font(.system(size: 12.5, weight: .medium))
            if let c = o.config {
                check("Delete \(c)\(size(c)), signed out first", on: config.contains(e.id), disabled: o.block != nil, note: o.block) { toggle(&config, e.id) }
            } else {
                Text("\(e.configDir) · never deleted").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let w = o.window {
                check("Delete its Claude window data\(size(w))", on: window.contains(e.id)) { toggle(&window, e.id) }
            } else {
                Text(e.desktop == .standard ? "The standard window · never deleted" : "No window data of its own").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
    }

    private func size(_ path: String) -> String {
        sizes[path].map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? ""
    }

    private func toggle(_ set: inout Set<String>, _ id: String) { if set.contains(id) { set.remove(id) } else { set.insert(id) } }

    private func check(_ title: String, on: Bool, disabled: Bool = false, note: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? face.danger : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11.5))
                    if let note { Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled || working != nil).opacity(disabled ? 0.5 : 1)
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(Color.secondary.opacity(0.6)).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0.height / 2 + 4 }
            Text(s).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Claude still using folders that are about to go: they must be closed first.
    private var runningBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Close Claude first: it's using folders that would be deleted").font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
            ForEach(running, id: \.id) { r in
                Text((r.kind == .desktop ? "Claude window" : r.kind == .codeTab ? "Code tab session" : "Terminal session (type /exit)") + " · " + r.folder)
                    .font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
            }
            Button("Check again") { monitor.refresh() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func go() {
        let c = config, w = window, claude = model.claudePath, app = Bundle.main.bundleURL
        working = "Uninstalling…"
        AgentStarter.shared.suspended = true          // the agent is meant to stop now
        DispatchQueue.global(qos: .userInitiated).async {
            let kept = Uninstall.run(deleteConfig: c, deleteWindow: w, trash: app, claude: claude,
                                     log: { line in DispatchQueue.main.async { working = line } })
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "cl_audit is uninstalled"
                a.informativeText = "Kept: " + kept.joined(separator: "; ") + "."
                a.runModal()
                exit(0)                          // now: quitting normally would save its window and settings again
            }
        }
    }
}
