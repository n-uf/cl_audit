// Adding a Claude account: one page in Settings. The account lives in a new Claude Code folder or in one
// that already exists (the default ~/.claude too); a folder and a desktop window can belong to only one
// account, which the Checks card verifies live. A banner lists every Claude app and Claude Code session
// still running: the steps that write folders wait until they're closed (or "Continue anyway").
// Steps: close Claude → create or connect the folder → sign in → open its Claude window → add the Dock icon.

import AppKit
import SwiftUI

/// Items that can be shared from ~/.claude by linking them into a new folder.
enum SharedItem: String, CaseIterable, Identifiable {
    case instructions = "CLAUDE.md", agents, skills, commands, memory = "projects"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .instructions: return "instructions"
        case .agents: return "agents"
        case .skills: return "skills"
        case .commands: return "commands"
        case .memory: return "memory & history"
        }
    }
}

enum FolderSource: String { case new, existing }

struct NewAccountDraft: Equatable {
    var name = ""
    var color: TileColor = .purple
    var share: Set<SharedItem> = [.instructions, .agents, .skills, .commands]
    var source: FolderSource = .new
    var existingDir: String?            // the chosen folder, when connecting an existing one
    var window: DesktopMode = .separate
    var continueAnyway = false          // set up while Claude is still running
    /// What this setup did; Cancel undoes exactly this (an existing folder is never deleted or signed out).
    var createdConfigDir: String?
    var createdDataDir: String?
    var connected = false
    var started: Bool { createdConfigDir != nil || createdDataDir != nil || connected }

    var id: String { Store.newID(from: name, taken: []) }
    var label: String { String(name.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6)) }
    var newConfigDir: String { "~/.claude-\(id)" }
    var configDir: String { source == .existing ? (existingDir ?? "") : newConfigDir }
    var dataDir: String {
        switch window {
        case .separate: return "~/Library/Application Support/Claude-\(id)"
        case .standard: return FolderKey.standardDataDir
        case .none: return ""
        }
    }

    var entry: AccountEntry {
        var e = AccountEntry(id: id, name: name, label: label.isEmpty ? "NEW" : label, configDir: configDir)
        e.desktop = window
        e.desktopDataDir = window == .separate ? dataDir : ""
        e.color = color
        e.accent = color
        return e
    }
}

/// One line of the Checks card.
struct SetupCheck: Identifiable {
    enum State { case ok, bad, warn, wait }
    let id = UUID()
    let state: State
    let text: String
    var blocks: Bool { state == .bad }
}

/// What has been done so far, read from disk each time (so it stays right if things happen elsewhere).
enum NewAccountSetup {
    static let shared = URL(fileURLWithPath: expand("~/.claude"))

    static func exists(_ path: String) -> Bool { !path.isEmpty && FileManager.default.fileExists(atPath: expand(path)) }

    /// The Claude Code folder is in place (created, or an existing one connected) and so is the window's data folder.
    static func foldersReady(_ d: NewAccountDraft) -> Bool {
        let config = d.source == .existing ? d.connected : exists(d.configDir)
        return config && (d.window != .separate || exists(d.dataDir))
    }

    static func linksReady(_ d: NewAccountDraft) -> Bool {
        d.source == .existing || d.share.allSatisfy { item in
            !FileManager.default.fileExists(atPath: shared.appendingPathComponent(item.rawValue).path)
                || exists((d.configDir as NSString).appendingPathComponent(item.rawValue))
        }
    }

    /// Signed in when Claude Code has recorded this folder's account (it writes it right after the login).
    static func signedInEmail(_ d: NewAccountDraft) -> String? {
        exists(d.configDir) || d.configDir == "~/.claude" ? Account.expectedEmail(configDir: d.configDir) : nil
    }

    /// Everything the Checks card shows, in order. Any `.bad` line blocks Create/Connect and Finish.
    static func checks(_ d: NewAccountDraft, accounts: [AccountEntry], runs: [ClaudeRun], checked: Bool) -> [SetupCheck] {
        var out: [SetupCheck] = []
        let name = d.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { out.append(.init(state: .wait, text: "Give the account a name.")) }
        else if accounts.contains(where: { $0.name.lowercased() == name.lowercased() }) { out.append(.init(state: .bad, text: "Another account is already called “\(name)”.")) }
        else { out.append(.init(state: .ok, text: "The name “\(name)” isn't taken")) }

        // the Claude Code folder
        if d.source == .new {
            if let owner = FolderRules.configOwner(d.configDir, among: accounts) {
                out.append(.init(state: .bad, text: "\(d.configDir) overlaps “\(owner.name)”'s folder. Pick another name."))
            } else if exists(d.configDir) && d.createdConfigDir == nil {
                out.append(.init(state: .bad, text: "\(d.configDir) already exists. Choose “Existing folder” to connect it, or pick another name."))
            } else if !name.isEmpty {
                out.append(.init(state: .ok, text: "\(d.configDir) is new and no other account uses it"))
            }
        } else if let dir = d.existingDir {
            if let owner = FolderRules.configOwner(dir, among: accounts) {
                let same = FolderKey.canonical(owner.configDir) == FolderKey.canonical(dir)
                out.append(.init(state: .bad, text: same ? "\(dir) is already used by “\(owner.name)”." : "\(dir) is inside, or contains, “\(owner.name)”'s folder."))
            } else {
                switch FolderKind.of(dir) {
                case .missing: out.append(.init(state: .bad, text: "\(dir) doesn't exist."))
                case .other: out.append(.init(state: .bad, text: "\(dir) isn't a Claude Code folder and isn't empty."))
                case .empty:
                    out.append(.init(state: .ok, text: "\(dir) isn't used by another account, and isn't inside or around one"))
                    out.append(.init(state: .ok, text: "It's empty: Claude Code sets it up when you sign in"))
                case .claudeCode:
                    out.append(.init(state: .ok, text: "\(dir) isn't used by another account, and isn't inside or around one"))
                    out.append(.init(state: .ok, text: "It's a Claude Code folder"))
                }
            }
        } else {
            out.append(.init(state: .wait, text: "Pick the folder to connect."))
        }

        // the desktop window
        switch d.window {
        case .none: out.append(.init(state: .ok, text: "No desktop window, Claude Code only"))
        default:
            if let owner = FolderRules.windowOwner(d.window, d.dataDir, among: accounts) {
                out.append(.init(state: .bad, text: d.window == .standard ? "The standard Claude window is already “\(owner.name)”'s. Choose a separate window." : "\(d.dataDir) is already “\(owner.name)”'s window."))
            } else {
                out.append(.init(state: .ok, text: d.window == .standard ? "The standard Claude window isn't used by another account" : "The window's data folder isn't used by another account"))
            }
        }

        // the sign-in: shared is allowed, but both icons would show the same usage
        if let email = signedInEmail(d) {
            if let owner = FolderRules.signInOwner(email, among: accounts) {
                out.append(.init(state: .warn, text: "Signed in as \(Privacy.masked(email)), which “\(owner.name)” also uses: both icons would show the same usage."))
            } else {
                out.append(.init(state: .ok, text: "The sign-in \(Privacy.masked(email)) isn't used by another account"))
            }
        }

        // Claude running
        if !checked { out.append(.init(state: .wait, text: "Checking whether Claude is running…")) }
        else if runs.isEmpty { out.append(.init(state: .ok, text: "No Claude is running")) }
        else {
            let apps = runs.filter { $0.kind == .desktop }.count, sessions = runs.count - apps
            let what = [apps > 0 ? "\(apps) desktop app\(apps == 1 ? "" : "s")" : nil,
                        sessions > 0 ? "\(sessions) Claude Code session\(sessions == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: ", ")
            out.append(.init(state: d.continueAnyway ? .warn : .bad, text: d.continueAnyway ? "Continuing while Claude runs (\(what))" : "Claude is still running: \(what)"))
        }
        return out
    }

    /// What Cancel will undo, for the confirmation.
    static func discardSummary(_ d: NewAccountDraft) -> String {
        guard d.createdConfigDir != nil || d.createdDataDir != nil else {
            return d.connected ? "\(d.configDir) stays as it is; nothing was created." : "Nothing has been created yet."
        }
        var parts: [String] = []
        if d.createdConfigDir != nil, let e = signedInEmail(d) { parts.append("signs out the Claude Code login (\(Privacy.masked(e)))") }
        if d.createdConfigDir != nil, windowOpen(d) { parts.append("quits its Claude window") }
        let dirs = [d.createdConfigDir, d.createdDataDir.map { _ in "its desktop data folder" }].compactMap { $0 }
        if !dirs.isEmpty { parts.append("deletes " + dirs.joined(separator: " and ")) }
        let first = parts.joined(separator: ", ")
        let kept = d.source == .existing ? " \(d.configDir) is left as it is." : " Nothing in ~/.claude is touched."
        return first.prefix(1).uppercased() + first.dropFirst() + "." + kept
    }

    /// Undoes what this setup created: the login it made, the window it opened, the folders it created.
    /// Folders that existed before are left alone. Blocks for the sign-out; call off the main thread.
    static func discard(_ d: NewAccountDraft, claude: String?) {
        let fm = FileManager.default
        if let dir = d.createdConfigDir {
            if let claude, signedInEmail(d) != nil { ClaudeCLI.logout(claude, configDir: dir) }
            let account = Account(d.entry)
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
                .filter { Launcher.isWindow(of: account, $0) }
            apps.forEach { $0.terminate() }
            let deadline = Date().addingTimeInterval(4)
            while apps.contains(where: { !$0.isTerminated }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            try? fm.removeItem(at: URL(fileURLWithPath: expand(dir)))      // removes the links, not what they point to
            try? fm.removeItem(at: ClaudeCLI.loginScript(dir))
        }
        if let dir = d.createdDataDir { try? fm.removeItem(at: URL(fileURLWithPath: expand(dir))) }
    }

    static func windowOpen(_ d: NewAccountDraft) -> Bool {
        d.window != .none && (Launcher.activity(for: [Account(d.entry)])[expand(d.configDir)]?.desktopOpen ?? false)
    }

    /// Creates the new folder (with links from ~/.claude) or connects the existing one, and creates the
    /// separate window's data folder. Records what it created, so Cancel can remove exactly that.
    static func createOrConnect(_ d: inout NewAccountDraft) throws {
        let fm = FileManager.default
        if d.source == .new {
            let config = URL(fileURLWithPath: expand(d.configDir))
            if !exists(d.configDir) { try fm.createDirectory(at: config, withIntermediateDirectories: true); d.createdConfigDir = d.configDir }
            for item in d.share {
                let src = shared.appendingPathComponent(item.rawValue)
                let dst = config.appendingPathComponent(item.rawValue)
                guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path),
                      (try? fm.destinationOfSymbolicLink(atPath: dst.path)) == nil else { continue }
                try fm.createSymbolicLink(at: dst, withDestinationURL: src)
            }
        } else {
            d.connected = true
        }
        if d.window == .separate, !exists(d.dataDir) {
            try fm.createDirectory(at: URL(fileURLWithPath: expand(d.dataDir)), withIntermediateDirectories: true)
            d.createdDataDir = d.dataDir
        }
    }
}

struct NewAccountView: View {
    @Binding var draft: NewAccountDraft
    @ObservedObject var model: SettingsModel
    @StateObject private var monitor = RunsMonitor()
    @ObservedObject private var privacy = Privacy.shared
    @State private var error: String?
    @State private var confirmCancel = false
    @State private var confirmQuit = false
    @State private var confirmAnyway = false
    @State private var signingOut = false
    @State private var customFolders: [String] = []

    var body: some View {
        let _ = model.tick                                // re-check the steps every few seconds
        let checks = NewAccountSetup.checks(draft, accounts: model.accounts, runs: monitor.runs, checked: monitor.checked)
        let blocked = checks.contains { $0.blocks }
        let folders = NewAccountSetup.foldersReady(draft)
        let links = folders && NewAccountSetup.linksReady(draft)
        let signedIn = NewAccountSetup.signedInEmail(draft)
        let window = folders && NewAccountSetup.windowOpen(draft)
        let claudeClear = monitor.checked && (monitor.runs.isEmpty || draft.continueAnyway)

        VStack(alignment: .leading, spacing: 10) {
            RunsBanner(runs: monitor.runs, checked: monitor.checked, accounts: model.accounts, continueAnyway: draft.continueAnyway,
                       quit: { confirmQuit = true }, anyway: { confirmAnyway = true })

            HStack(alignment: .top, spacing: 10) {
                detailsCard(folders: folders).frame(maxWidth: .infinity)
                VStack(spacing: 10) {
                    checksCard(checks)
                    stepsCard(blocked: blocked, folders: folders, links: links, signedIn: signedIn, window: window, claudeClear: claudeClear)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .alert("Cancel the new account\(draft.name.isEmpty ? "" : " “\(draft.name)”")?", isPresented: $confirmCancel) {
            Button(draft.createdConfigDir != nil || draft.createdDataDir != nil ? "Cancel and clean up" : "Cancel setup", role: .destructive) { model.cancelNew() }
            Button("Keep setting up", role: .cancel) {}
        } message: { Text(NewAccountSetup.discardSummary(draft)) }
        .alert("Quit the Claude windows?", isPresented: $confirmQuit) {
            Button("Quit them", role: .destructive) { ClaudeRuns.quitDesktopApps(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { monitor.refresh() } }
            Button("Not now", role: .cancel) {}
        } message: { Text("Every Claude desktop app closes, with the Claude Code sessions in their Code tab. Unsent messages there may be lost. Claude Code in Terminal keeps running: type /exit there.") }
        .alert("Set up while Claude is running?", isPresented: $confirmAnyway) {
            Button("Continue anyway") { draft.continueAnyway = true }
            Button("Wait", role: .cancel) {}
        } message: { Text("A running Claude can overwrite settings in the folders being set up. Continue only if none of them uses this account's folders.") }
    }

    // MARK: details

    func detailsCard(folders: Bool) -> some View {
        SCard(title: "New Claude account") {
            SRow(label: "Name", info: "Shown in the Dock as “cl_audit \(draft.name)”; names a new folder too.", first: true) {
                TextField("e.g. personal", text: $draft.name)
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(maxWidth: 160)
                    .disabled(draft.started)
            }
            SRow(label: "Icon label · colour") {
                HStack(spacing: 6) {
                    Text(draft.label.isEmpty ? "–" : draft.label).font(.system(size: 12, weight: .semibold))
                    ForEach([TileColor.orange, .blue, .purple, .teal, .pink], id: \.self) { c in
                        Swatch(color: c, selected: draft.color == c, size: 13).onTapGesture { draft.color = c }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                SRow(label: "Claude Code folder", info: "A new folder starts fresh. An existing one, the default ~/.claude too, keeps its sign-in, settings and history. A folder can belong to only one account.") {
                    PillPicker(options: [FolderSource.new, .existing], selection: $draft.source, compact: true) { $0 == .new ? "New folder" : "Existing folder" }
                }
                if draft.source == .new {
                    optionRow(selected: true, title: draft.newConfigDir, mono: true, detail: nil, tag: ("new", .green)) {}
                } else {
                    ForEach(folderChoices, id: \.self) { path in folderOption(path) }
                    optionRow(selected: false, title: "Choose another folder…", mono: false, detail: "any folder with Claude Code settings, or an empty one", tag: nil) {
                        if let p = pickFolder() {
                            if !folderChoices.contains(where: { FolderKey.canonical($0) == FolderKey.canonical(p) }) { customFolders.append(p) }
                            draft.existingDir = folderChoices.first { FolderKey.canonical($0) == FolderKey.canonical(p) } ?? p
                        }
                    }
                }
            }
            .disabled(draft.started)
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 4) {
                SRow(label: "Claude window", info: "Only one account can use the standard window; a separate window has its own sign-in and data folder.") { EmptyView() }
                ForEach([DesktopMode.standard, .separate, .none]) { mode in windowOption(mode) }
            }
            .disabled(draft.started)
            .padding(.bottom, 4)

            if draft.source == .new {
                VStack(alignment: .leading, spacing: 4) {
                    SRow(label: "Share from main", info: "Linked from ~/.claude, so changes there show up in every account. The login, plugins and usage stay separate.") { EmptyView() }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 4) {
                        ForEach(SharedItem.allCases) { item in
                            Toggle(item.title, isOn: Binding(get: { draft.share.contains(item) },
                                                             set: { on in if on { draft.share.insert(item) } else { draft.share.remove(item) } }))
                                .toggleStyle(.checkbox).font(.system(size: 11)).lineLimit(1).fixedSize()
                        }
                    }
                    .padding(.bottom, 4)
                }
                .disabled(folders)
            } else {
                SRow(label: "Share from main") {
                    Text("not for an existing folder: it keeps its own").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The Claude Code folders on this Mac, plus any picked with “Choose another folder…”.
    var folderChoices: [String] {
        var list = Detect.configFolders().map(\.path)
        for p in customFolders where !list.contains(where: { FolderKey.canonical($0) == FolderKey.canonical(p) }) { list.append(p) }
        return list
    }

    func folderOption(_ path: String) -> some View {
        let owner = FolderRules.configOwner(path, among: model.accounts)
        let kind = FolderKind.of(path)
        var detail: String
        switch kind {
        case .claudeCode(let email): detail = email.map { "signed in as \(Privacy.masked($0))" } ?? "not signed in"
        case .empty: detail = "empty"
        case .missing: detail = "doesn't exist"
        case .other: detail = "not a Claude Code folder"
        }
        if let used = FolderKind.lastUsed(path) { detail += " · last used " + Self.ago(used) }
        let tag: (String, Color)? = owner.map { ("used by \($0.name)", .red) }
            ?? (kind == .other || kind == .missing ? ("can't use", .red) : ("free", .green))
        let selected = draft.existingDir.map { FolderKey.canonical($0) == FolderKey.canonical(path) } ?? false
        return optionRow(selected: selected, title: path, mono: true, detail: detail, tag: tag,
                         badge: FolderKey.canonical(path) == FolderKey.canonical("~/.claude") ? "default" : nil,
                         disabled: owner != nil) { draft.existingDir = path }
    }

    func windowOption(_ mode: DesktopMode) -> some View {
        let owner = FolderRules.windowOwner(mode, mode == .separate ? "~/Library/Application Support/Claude-\(draft.id)" : FolderKey.standardDataDir, among: model.accounts)
        let title = mode == .standard ? "Standard window" : mode == .separate ? "Separate window, its own sign-in" : "No desktop window"
        let detail = mode == .standard ? FolderKey.standardDataDir
            : mode == .separate ? "~/Library/Application Support/Claude-\(draft.id)" + (NewAccountSetup.exists("~/Library/Application Support/Claude-\(draft.id)") ? " · exists" : " · new")
            : "Claude Code in the terminal only"
        let tag: (String, Color)? = mode == .none ? nil : owner.map { ("used by \($0.name)", .red) } ?? ("free", .green)
        return optionRow(selected: draft.window == mode, title: title, mono: false, detail: detail, tag: tag, disabled: owner != nil) { draft.window = mode }
    }

    func optionRow(selected: Bool, title: String, mono: Bool, detail: String?, tag: (String, Color)?, badge: String? = nil,
                   disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().strokeBorder(selected ? Color.white : Color.secondary, lineWidth: selected ? 4 : 1.5).frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title).font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        if let badge { Text(badge).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5)) }
                    }
                    if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 4)
                if let tag {
                    Text(tag.0).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tag.1)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(tag.1.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(selected ? 0.09 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(selected ? 0.35 : 0), lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }

    // MARK: checks and steps

    func checksCard(_ checks: [SetupCheck]) -> some View {
        SCard(title: "Checks") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(checks) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: c.state == .ok ? "checkmark" : c.state == .bad ? "xmark" : c.state == .warn ? "exclamationmark.triangle.fill" : "circle.dotted")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(c.state == .ok ? Color(nsColor: Painter.green) : c.state == .bad ? Color.red : c.state == .warn ? Color.orange : Color.secondary)
                            .frame(width: 13)
                        Text(c.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    func stepsCard(blocked: Bool, folders: Bool, links: Bool, signedIn: String?, window: Bool, claudeClear: Bool) -> some View {
        let tint = Color(nsColor: draft.color.color(fiveHour: nil, stale: false))
        let taken = signedIn.flatMap { FolderRules.signInOwner($0, among: model.accounts) }
        let waiting = monitor.runs.count
        return SCard(title: "Steps") {
            step(done: claudeClear, waiting: !claudeClear && monitor.checked,
                 title: monitor.runs.isEmpty ? (monitor.checked ? "Claude is closed" : "Close Claude") : draft.continueAnyway ? "Continuing while Claude runs" : "Close Claude",
                 note: claudeClear ? nil : monitor.checked ? "Waiting for \(waiting) to close: see the list above." : "Checking what's running…", first: true) { EmptyView() }
            step(done: folders && links,
                 title: draft.source == .new ? "Create the folder" + (draft.share.isEmpty ? "" : " and links") : "Connect \(draft.existingDir ?? "the folder")") {
                Button(draft.source == .new ? "Create" : "Connect") {
                    do { try NewAccountSetup.createOrConnect(&draft); error = nil; model.tick += 1 }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.pill(tint, compact: true))
                .disabled(blocked)
            }
            if let signedIn, draft.source == .existing, !draft.started || draft.connected {
                step(done: true, title: "Signed in as \(Privacy.masked(signedIn)) · already in the folder") { EmptyView() }
            } else {
                step(done: signedIn != nil && taken == nil, waiting: taken != nil,
                     title: signedIn.map { "Signed in as \(Privacy.masked($0))" + (taken.map { ", which “\($0.name)” also uses" } ?? "") } ?? "Sign in to Claude Code",
                     note: taken != nil
                        ? "Allowed, but both icons would show the same usage. To use another account: sign out, then open the link Terminal shows in a private browser window."
                        : "Opens Terminal; you approve in the browser. The browser uses the claude.ai account it's signed in to, so for a different account open the link Terminal shows in a private window.") {
                    if taken != nil {
                        Button(signingOut ? "Signing out…" : "Sign out") { signOut() }
                            .buttonStyle(.pill(.orange, compact: true)).disabled(signingOut || model.claudePath == nil)
                    } else {
                        Button("Sign in…") {
                            if let claude = model.claudePath { ClaudeCLI.openLogin(claude, account: Account(draft.entry), email: nil) }
                        }
                        .buttonStyle(.pill(tint, compact: true))
                        .disabled(!folders || model.claudePath == nil)
                    }
                }
            }
            if draft.window != .none {
                step(done: window, title: window ? "Claude window open" : "Open its Claude window",
                     note: window ? "Sign in there once, if you haven't." : "Optional if you only use Claude Code in the terminal.") {
                    Button("Open window") { Launcher.openClaude(Account(draft.entry)) }
                        .buttonStyle(PillButtonStyle(tint: nil, compact: true)).disabled(!folders)
                }
            }
            step(done: false, title: "Add the Dock icon “cl_audit \(draft.name)”", note: "Finish adds the account and installs it.") { EmptyView() }
            HStack {
                if let e = error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                else if blocked { Text("Fix the red checks to go on.").font(.caption).foregroundStyle(.secondary) }
                else if signedIn == nil { Text("You can finish before signing in, and sign in later.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(model.discarding ? "Cancelling…" : "Cancel") { confirmCancel = true }
                    .buttonStyle(PillButtonStyle(tint: nil, compact: true)).disabled(model.discarding)
                Button("Finish") { model.finishNew() }.buttonStyle(.pill(.green, compact: true))
                    .disabled(blocked || !folders || model.discarding)
            }
            .padding(.top, 8)
        }
    }

    /// Signs out the folder's login so the sign-in can be done again (only a folder this setup created).
    func signOut() {
        guard let claude = model.claudePath, draft.createdConfigDir != nil else { return }
        signingOut = true
        let dir = draft.configDir
        DispatchQueue.global(qos: .userInitiated).async {
            ClaudeCLI.logout(claude, configDir: dir)
            DispatchQueue.main.async { signingOut = false; model.tick += 1 }
        }
    }

    static func ago(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 3600 { return "just now" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        let days = Int(s / 86400)
        return days < 14 ? "\(days) day\(days == 1 ? "" : "s") ago" : "\(days / 7) weeks ago"
    }

    func step<C: View>(done: Bool, waiting: Bool = false, title: String, note: String? = nil, first: Bool = false,
                       @ViewBuilder action: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SRow(label: "", first: first) {
                HStack(spacing: 8) {
                    Image(systemName: done ? "checkmark.circle.fill" : waiting ? "exclamationmark.circle.fill" : "circle")
                        .foregroundStyle(done ? Color(nsColor: Painter.green) : waiting ? Color.orange : Color.secondary)
                    Text(title).font(.system(size: 12)).lineLimit(2)
                    Spacer()
                    if !done { action() }
                }
            }
            if let note, !done { Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.leading, 24).padding(.bottom, 4) }
        }
    }
}

/// The banner at the top: what's still running, with the folder each uses; green once all is closed.
struct RunsBanner: View {
    let runs: [ClaudeRun]
    let checked: Bool
    let accounts: [AccountEntry]
    let continueAnyway: Bool
    let quit: () -> Void
    let anyway: () -> Void

    var body: some View {
        let clear = checked && runs.isEmpty
        let tone: Color = !checked ? .gray : clear ? .green : .red
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: !checked ? "clock" : clear ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 22)).foregroundStyle(!checked ? Color.secondary : clear ? Color(nsColor: Painter.green) : Color.red)
            VStack(alignment: .leading, spacing: 3) {
                Text(!checked ? "Checking whether Claude is running…" : clear ? "No Claude is running" : "Close Claude before adding an account").font(.system(size: 14, weight: .semibold))
                Text(clear ? "Setup can go ahead. Opening Claude again before Finish brings this warning back."
                           : "Claude writes its sign-in and settings while it runs, so a running copy could overwrite the folders being set up. Close these; setup continues by itself.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !clear {
                    ForEach(lines, id: \.self) { l in
                        HStack(spacing: 6) {
                            Circle().fill(Color.secondary).frame(width: 6, height: 6)
                            Text(l).font(.system(size: 12))
                        }
                    }
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 8)
            if checked && !clear {
                VStack(alignment: .trailing, spacing: 6) {
                    if runs.contains(where: { $0.kind == .desktop }) {
                        Button("Quit the Claude windows", action: quit).buttonStyle(.pill(.red, compact: true))
                    }
                    Text("checks again every 2 s").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    if !continueAnyway { Button("Continue anyway…", action: anyway).buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(tone.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tone.opacity(0.4)))
    }

    /// One line per desktop app, then the Claude Code sessions grouped by where they run and which folder they use.
    var lines: [String] {
        var out: [String] = []
        for r in runs where r.kind == .desktop {
            let key = FolderKey.canonical(r.folder)
            let owner = accounts.first { FolderRules.windowKey($0.desktop, $0.desktopDataDir) == key }
            let which = key == FolderKey.canonical(FolderKey.standardDataDir) ? "standard window" : "separate window"
            out.append("Claude desktop app · " + (owner.map { "\($0.name) · " } ?? "") + which)
        }
        for kind in [ClaudeRun.Kind.codeTab, .terminal] {
            let rs = runs.filter { $0.kind == kind }
            guard !rs.isEmpty else { continue }
            let byFolder = Dictionary(grouping: rs, by: \.folder).sorted { $0.key < $1.key }
            let parts = byFolder.map { "\($0.value.count) on \($0.key)" }.joined(separator: " · ")
            out.append(kind == .codeTab ? "Claude Code in the desktop app's Code tab · \(parts)"
                                        : "Claude Code in Terminal · \(parts): type /exit there")
        }
        return out
    }
}

/// A Finder panel for choosing a folder (hidden folders shown), as a path with ~.
func pickFolder() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.showsHiddenFiles = true
    panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
    panel.prompt = "Use folder"
    return panel.runModal() == .OK ? panel.url.map { tilde($0.path) } : nil
}
