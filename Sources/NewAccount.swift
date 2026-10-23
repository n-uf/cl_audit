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
    var customLabel: String?            // the icon label, if edited (otherwise it comes from the name)
    var label: String { customLabel ?? String(name.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6)) }
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
    enum Section { case account, folder, window, signIn, running }
    let id = UUID()
    let section: Section
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
        if name.isEmpty { out.append(.init(section: .account, state: .wait, text: "Give the account a name.")) }
        else if accounts.contains(where: { $0.name.lowercased() == name.lowercased() }) { out.append(.init(section: .account, state: .bad, text: "Another account is already called “\(name)”.")) }
        else { out.append(.init(section: .account, state: .ok, text: "The name “\(name)” isn't taken")) }

        // the Claude Code folder
        if d.source == .new {
            if let owner = FolderRules.configOwner(d.configDir, among: accounts) {
                out.append(.init(section: .folder, state: .bad, text: "\(d.configDir) overlaps “\(owner.name)”'s folder. Pick another name."))
            } else if exists(d.configDir) && d.createdConfigDir == nil {
                out.append(.init(section: .folder, state: .bad, text: "\(d.configDir) already exists. Choose “Existing folder” to connect it, or pick another name."))
            } else if !name.isEmpty {
                out.append(.init(section: .folder, state: .ok, text: "\(d.configDir) is new and no other account uses it"))
            }
        } else if let dir = d.existingDir {
            if let owner = FolderRules.configOwner(dir, among: accounts) {
                let same = FolderKey.canonical(owner.configDir) == FolderKey.canonical(dir)
                out.append(.init(section: .folder, state: .bad, text: same ? "\(dir) is already used by “\(owner.name)”." : "\(dir) is inside, or contains, “\(owner.name)”'s folder."))
            } else {
                switch FolderKind.of(dir) {
                case .missing: out.append(.init(section: .folder, state: .bad, text: "\(dir) doesn't exist."))
                case .other: out.append(.init(section: .folder, state: .bad, text: "\(dir) isn't a Claude Code folder and isn't empty."))
                case .empty:
                    out.append(.init(section: .folder, state: .ok, text: "\(dir) isn't used by another account, and isn't inside or around one"))
                    out.append(.init(section: .folder, state: .ok, text: "It's empty: Claude Code sets it up when you sign in"))
                case .claudeCode:
                    out.append(.init(section: .folder, state: .ok, text: "\(dir) isn't used by another account, and isn't inside or around one"))
                    out.append(.init(section: .folder, state: .ok, text: "It's a Claude Code folder"))
                }
            }
        } else {
            out.append(.init(section: .folder, state: .wait, text: "Pick the folder to connect."))
        }

        // the desktop window
        switch d.window {
        case .none: out.append(.init(section: .window, state: .ok, text: "No desktop window, Claude Code only"))
        default:
            if let owner = FolderRules.windowOwner(d.window, d.dataDir, among: accounts) {
                out.append(.init(section: .window, state: .bad, text: d.window == .standard ? "The standard Claude window is already “\(owner.name)”'s. Choose a separate window." : "\(d.dataDir) is already “\(owner.name)”'s window."))
            } else {
                out.append(.init(section: .window, state: .ok, text: d.window == .standard ? "The standard Claude window isn't used by another account" : "The window's data folder isn't used by another account"))
            }
        }

        // the sign-in: shared is allowed, but both icons would show the same usage
        if let email = signedInEmail(d) {
            if let owner = FolderRules.signInOwner(email, among: accounts) {
                out.append(.init(section: .signIn, state: .warn, text: "Signed in as \(Privacy.masked(email)), which “\(owner.name)” also uses: both icons would show the same usage."))
            } else {
                out.append(.init(section: .signIn, state: .ok, text: "The sign-in \(Privacy.masked(email)) isn't used by another account"))
            }
        }

        // Claude running
        if !checked { out.append(.init(section: .running, state: .wait, text: "Checking whether Claude is running…")) }
        else if runs.isEmpty { out.append(.init(section: .running, state: .ok, text: "No Claude is running")) }
        else {
            let apps = runs.filter { $0.kind == .desktop }.count, sessions = runs.count - apps
            let what = [apps > 0 ? "\(apps) desktop app\(apps == 1 ? "" : "s")" : nil,
                        sessions > 0 ? "\(sessions) Claude Code session\(sessions == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: ", ")
            out.append(.init(section: .running, state: d.continueAnyway ? .warn : .bad, text: d.continueAnyway ? "Continuing while Claude runs (\(what))" : "Claude is still running: \(what)"))
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

/// The add-account page. Wide windows: three columns (account and window · Claude Code folder · summary and
/// steps, with the "Claude is running" warning attached to step 1). Narrower: one column with a progress
/// strip on top and the warning and action bar pinned at the bottom; very narrow: labels above controls.
/// Each check sits under the field it's about; one button does the next step.
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
    @State private var editingLabel = false
    @State private var customFolders: [String] = []

    private enum Width { case wide, medium, narrow }

    var body: some View {
        let _ = model.tick                                // re-check the steps every few seconds
        GeometryReader { geo in
            let w = geo.size.width
            let width: Width = w >= 1100 ? .wide : w >= 600 ? .medium : .narrow
            Group {
                if width == .wide { wide(w) } else { column(narrow: width == .narrow) }
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .alert("Cancel the new account\(draft.name.isEmpty ? "" : " “\(draft.name)”")?", isPresented: $confirmCancel) {
            Button(draft.createdConfigDir != nil || draft.createdDataDir != nil ? "Cancel and clean up" : "Cancel setup", role: .destructive) { model.cancelNew() }
            Button("Keep setting up", role: .cancel) {}
        } message: { Text(NewAccountSetup.discardSummary(draft)) }
        .alert("Quit the Claude apps?", isPresented: $confirmQuit) {
            Button("Quit them", role: .destructive) { ClaudeRuns.quitDesktopApps(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { monitor.refresh() } }
            Button("Not now", role: .cancel) {}
        } message: { Text("Every Claude desktop app closes, with the Claude Code sessions in their Code tab. Unsent messages there may be lost. Claude Code in Terminal keeps running: type /exit there.") }
        .alert("Set up while Claude is running?", isPresented: $confirmAnyway) {
            Button("Continue anyway") { draft.continueAnyway = true }
            Button("Wait", role: .cancel) {}
        } message: { Text("A running Claude can overwrite settings in the folders being set up. Continue only if none of them uses this account's folders.") }
    }

    // MARK: state

    private var checks: [SetupCheck] { NewAccountSetup.checks(draft, accounts: model.accounts, runs: monitor.runs, checked: monitor.checked) }
    private func checks(_ s: SetupCheck.Section) -> [SetupCheck] { checks.filter { $0.section == s } }
    private var blocked: Bool { checks.contains { $0.blocks } }
    private var running: Bool { monitor.checked && !monitor.runs.isEmpty && !draft.continueAnyway }
    private var folders: Bool { NewAccountSetup.foldersReady(draft) && NewAccountSetup.linksReady(draft) }
    private var signedIn: String? { NewAccountSetup.signedInEmail(draft) }
    private var windowOpen: Bool { NewAccountSetup.foldersReady(draft) && NewAccountSetup.windowOpen(draft) }
    private var tint: Color { Color(nsColor: draft.color.color(fiveHour: nil, stale: false)) }
    private var createTitle: String { draft.source == .new ? "Create" : "Connect" }

    /// Which step is next (1…5), for the progress strip and the one primary button.
    private var current: Int {
        if running || !monitor.checked { return 1 }
        if !folders { return 2 }
        if signedIn == nil { return 3 }
        return 5
    }

    // MARK: layouts

    private func wide(_ w: CGFloat) -> some View {
        let col3: CGFloat = 360, gaps: CGFloat = 12 * 2 + 28
        let rest = max(700, w - col3 - gaps)
        // The first column never gets narrower than its widest row (the window switch), so its cards line up.
        let col1 = max(350, rest * 0.42)
        return ScrollView {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 10) { accountCard(labelWidth: 76, stacked: false); windowCard(labelWidth: 76, stacked: false) }
                    .frame(width: col1)
                folderCard(labelWidth: 76, stacked: false).frame(width: rest - col1)
                stepsPanel.frame(width: col3)
            }
            .padding(14)
        }
    }

    private func column(narrow: Bool) -> some View {
        let lw: CGFloat = narrow ? 0 : 120
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    progressStrip(compact: narrow)
                    accountCard(labelWidth: lw, stacked: narrow)
                    folderCard(labelWidth: lw, stacked: narrow)
                    windowCard(labelWidth: lw, stacked: narrow)
                    if signedIn != nil || folders { signInCard }
                }
                .frame(maxWidth: 700)
                .padding(14)
                .frame(maxWidth: .infinity)
            }
            if monitor.checked && !monitor.runs.isEmpty { warningBar(narrow: narrow) }
            actionBar(hint: true)
        }
    }

    // MARK: cards

    private func accountCard(labelWidth: CGFloat, stacked: Bool) -> some View {
        SCard(title: "Account") {
            FormRow(label: "Name", width: labelWidth, stacked: stacked) {
                TextField("e.g. personal", text: $draft.name)
                    .textFieldStyle(.plain).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.25)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.14)))
                    .frame(maxWidth: 240)
                    .disabled(draft.started)
            }
            FormRow(label: "Colour", width: labelWidth, stacked: stacked) {
                HStack(spacing: 8) {
                    ForEach([TileColor.orange, .blue, .purple, .teal, .pink], id: \.self) { c in
                        Swatch(color: c, selected: draft.color == c, size: 16).onTapGesture { draft.color = c }
                    }
                }
            }
            FormRow(label: "Icon label", width: labelWidth, stacked: stacked) {
                if editingLabel {
                    TextField("", text: Binding(get: { draft.label },
                                                set: { draft.customLabel = String($0.uppercased().filter { !$0.isWhitespace }.prefix(6)) }))
                        .textFieldStyle(.plain).frame(width: 80)
                        .onSubmit { editingLabel = false }
                } else {
                    HStack(spacing: 6) {
                        Text(draft.label.isEmpty ? "–" : draft.label).font(.system(size: 12, weight: .semibold))
                        Button("edit") { editingLabel = true }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary).underline()
                    }
                }
            }
            statusLines(checks(.account), indent: stacked ? 0 : labelWidth + 10)
        }
    }

    private func folderCard(labelWidth: CGFloat, stacked: Bool) -> some View {
        SCard(title: "Claude Code folder", info: "A new folder starts fresh. An existing one, the default ~/.claude too, keeps its sign-in, settings and history. A folder can belong to only one account.") {
            FormRow(label: "Folder", width: labelWidth, stacked: stacked) {
                PillPicker(options: [FolderSource.new, .existing], selection: $draft.source, compact: true) { $0 == .new ? "New" : "Existing" }
                    .disabled(draft.started)
            }
            if draft.source == .existing {
                VStack(spacing: 1) {
                    ForEach(folderChoices, id: \.self) { path in folderRow(path) }
                    listRow(selected: false, disabled: draft.started) {
                        Text("Choose another folder…").font(.system(size: 12))
                    } action: {
                        if let p = pickFolder() {
                            if !folderChoices.contains(where: { FolderKey.canonical($0) == FolderKey.canonical(p) }) { customFolders.append(p) }
                            draft.existingDir = folderChoices.first { FolderKey.canonical($0) == FolderKey.canonical(p) } ?? p
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.09)))
                .padding(.top, 6)
            }
            statusLines(checks(.folder), indent: stacked ? 0 : labelWidth + 10).padding(.top, 4)
            if draft.source == .new {
                FormRow(label: "Share from main", width: labelWidth, stacked: stacked || labelWidth < 100,
                        info: "Linked from ~/.claude, so changes there show up in every account. The login, plugins and usage stay separate.") {
                    WrapChips(items: SharedItem.allCases.map { ($0.title, draft.share.contains($0)) }) { i in
                        let item = SharedItem.allCases[i]
                        if draft.share.contains(item) { draft.share.remove(item) } else { draft.share.insert(item) }
                    }
                    .disabled(NewAccountSetup.foldersReady(draft))
                }
                .padding(.top, 6)
            }
        }
    }

    private func windowCard(labelWidth: CGFloat, stacked: Bool) -> some View {
        let standardOwner = FolderRules.windowOwner(.standard, FolderKey.standardDataDir, among: model.accounts)
        return SCard(title: "Claude window", info: "Only one account can use the standard window; a separate window has its own sign-in and data folder.") {
            FormRow(label: "Window", width: labelWidth, stacked: stacked) {
                Segments(options: [DesktopMode.standard, .separate, .none], selection: $draft.window,
                         disabled: standardOwner == nil ? [] : [.standard]) { $0 == .standard ? "Standard" : $0 == .separate ? "Separate" : "None" }
                    .disabled(draft.started)
            }
            statusLines(checks(.window), indent: stacked ? 0 : labelWidth + 10).padding(.top, 2)
            if let o = standardOwner, draft.window != .standard {
                Text("Standard is \(o.name)'s").font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.leading, 19 + (stacked ? 0 : labelWidth + 10)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Medium and narrow layouts show the sign-in state as a card (wide shows it in the steps).
    private var signInCard: some View {
        SCard(title: "Sign in") {
            if signedIn == nil {
                Text("Opens Terminal; you approve in the browser. For a different claude.ai account, open the link Terminal shows in a private window.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            statusLines(checks(.signIn), indent: 0)
        }
    }

    // MARK: steps (wide)

    private var stepsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: preview(draft.entry, status: nil)).resizable().frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text("cl_audit \(draft.name.isEmpty ? "…" : draft.name)").font(.system(size: 15, weight: .semibold))
                    Text([draft.configDir.isEmpty ? "no folder yet" : draft.configDir,
                          draft.window == .standard ? "standard window" : draft.window == .separate ? "separate window" : "no window"].joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.bottom, 10)

            stepRow(1, state: monitor.checked ? (monitor.runs.isEmpty ? .done : draft.continueAnyway ? .warn : .bad) : .todo,
                    title: "Close Claude",
                    detail: !monitor.checked ? "checking…" : monitor.runs.isEmpty ? "nothing is running" : draft.continueAnyway ? "continuing while Claude runs" : nil,
                    connector: running) {
                if running { warningBox }
            }
            stepRow(2, state: folders ? .done : current == 2 ? .now : running ? .held : .todo,
                    title: draft.source == .new ? "Create the folder" + (draft.share.isEmpty ? "" : " and links") : "Connect the folder",
                    detail: folders ? draft.configDir : running ? "held until Claude is closed" : checks.contains(where: { $0.blocks && $0.section != .running }) ? "fix the red lines first" : nil,
                    detailBad: running) { EmptyView() }
            stepRow(3, state: signedIn == nil ? (current == 3 ? .now : .todo) : (FolderRules.signInOwner(signedIn, among: model.accounts) != nil ? .warn : .done),
                    title: signedIn == nil ? "Sign in to Claude Code" : "Signed in",
                    detail: signedIn.map { Privacy.masked($0) + (draft.source == .existing && !draft.started ? ", already in the folder" : "") } ?? "Terminal, then approve in the browser") {
                if let w = checks(.signIn).first(where: { $0.state == .warn }) {
                    Text(w.text).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            if draft.window != .none {
                stepRow(4, state: windowOpen ? .done : .todo, title: "Open its Claude window", detail: windowOpen ? "open" : "optional") {
                    if NewAccountSetup.foldersReady(draft) && !windowOpen {
                        Button("Open window") { Launcher.openClaude(Account(draft.entry)) }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
                    }
                }
            }
            stepRow(5, state: current == 5 ? .now : .todo, title: "Add the Dock icon", detail: "Finish installs “cl_audit \(draft.name.isEmpty ? "…" : draft.name)”") { EmptyView() }

            actionBar(hint: false).padding(.top, 8)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }

    private enum StepState { case todo, now, done, bad, warn, held }

    private func stepRow<C: View>(_ n: Int, state: StepState, title: String, detail: String?, detailBad: Bool = false,
                                  connector: Bool = false, @ViewBuilder extra: () -> C) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                switch state {
                case .done: Circle().fill(Color(nsColor: Painter.green)); Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.7))
                case .bad: Circle().fill(Color.red); Text("!").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                case .warn: Circle().fill(Color.orange); Text("!").font(.system(size: 12, weight: .bold)).foregroundStyle(.black.opacity(0.7))
                case .now: Circle().strokeBorder(tint, lineWidth: 2); Text("\(n)").font(.system(size: 11, weight: .bold))
                case .held: Circle().strokeBorder(Color.red.opacity(0.7), lineWidth: 1.5); Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
                case .todo: Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5); Text("\(n)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if state == .bad { Text("· still running").font(.system(size: 12)).foregroundStyle(.red) }
                }
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(detailBad ? Color.red : Color.secondary).lineLimit(2) }
                extra()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .topLeading) {
            if connector { Rectangle().fill(Color.red.opacity(0.55)).frame(width: 1.5).padding(.leading, 9.25).padding(.top, 29).padding(.bottom, -7) }
        }
        .overlay(alignment: .top) { if n > 1 { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) } }
    }

    /// The "Claude is running" warning, attached to step 1.
    private var warningBox: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(runLines, id: \.self) { Text($0).font(.system(size: 11.5)) }
            Text("They write sign-in and settings while running, which could overwrite the folder being set up.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            if monitor.runs.contains(where: { $0.kind == .terminal }) {
                Text("Terminal sessions: type /exit in them.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                if monitor.runs.contains(where: { $0.kind != .terminal }) {
                    Button("Quit the apps") { confirmQuit = true }.buttonStyle(.pill(.red, compact: true))
                }
                Spacer()
                Button("continue anyway…") { confirmAnyway = true }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).underline()
            }
            .padding(.top, 4)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.35)))
        .padding(.top, 4)
    }

    // MARK: medium and narrow

    private func progressStrip(compact: Bool) -> some View {
        let names = ["Close Claude", draft.source == .new ? "Create folder" : "Connect folder", "Sign in", "Window", "Dock icon"]
        let done = [monitor.checked && monitor.runs.isEmpty, folders, signedIn != nil, windowOpen, false]
        return HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { i in
                let n = i + 1, now = n == current, bad = n == 1 && running
                HStack(spacing: 4) {
                    ZStack {
                        Circle().fill(done[i] ? Color(nsColor: Painter.green) : bad ? Color.red : Color.clear)
                        Circle().strokeBorder(done[i] || bad ? Color.clear : now ? tint : Color.secondary.opacity(0.6), lineWidth: now ? 2 : 1.2)
                        Text(done[i] ? "✓" : bad ? "!" : "\(n)").font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(done[i] ? Color.black.opacity(0.7) : bad ? .white : now ? .primary : .secondary)
                    }
                    .frame(width: 16, height: 16)
                    if !compact || now { Text(names[i]).font(.system(size: 11.5)).foregroundStyle(bad ? Color.red : now ? Color.primary : Color.secondary) }
                }
                if i < 4 { Text("›").foregroundStyle(.tertiary) }
            }
        }
    }

    private func warningBar(narrow: Bool) -> some View {
        let message = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(draft.continueAnyway ? Color.orange : Color.red).frame(width: 8, height: 8)
            (Text(draft.continueAnyway ? "Continuing while Claude runs" : "Claude is running").bold()
             + Text(" · " + runSummary + (draft.continueAnyway ? "" : ": \(createTitle) waits until they're closed")).foregroundColor(.secondary))
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        let buttons = HStack(spacing: 10) {
            if !draft.continueAnyway {
                if monitor.runs.contains(where: { $0.kind != .terminal }) {
                    Button("Quit the apps") { confirmQuit = true }.buttonStyle(.pill(.red, compact: true))
                }
                Button("continue anyway…") { confirmAnyway = true }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary).underline()
            }
        }
        return Group {
            if narrow {
                VStack(alignment: .leading, spacing: 6) { message; buttons.padding(.leading, 16) }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 10) { message; Spacer(minLength: 6); buttons }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background((draft.continueAnyway ? Color.orange : Color.red).opacity(0.12))
        .overlay(alignment: .top) { Rectangle().fill((draft.continueAnyway ? Color.orange : Color.red).opacity(0.35)).frame(height: 1) }
        .help(runLines.joined(separator: "\n"))
    }

    /// Cancel on the left, the one next action on the right.
    private func actionBar(hint: Bool) -> some View {
        let taken = signedIn.flatMap { FolderRules.signInOwner($0, among: model.accounts) }
        return HStack(spacing: 8) {
            Button(model.discarding ? "Cancelling…" : "Cancel") { confirmCancel = true }
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.discarding)
            Spacer(minLength: 6)
            if let e = error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
            else if hint { Text(nextHint).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
            if !NewAccountSetup.foldersReady(draft) {
                Button(createTitle) {
                    do { try NewAccountSetup.createOrConnect(&draft); error = nil; model.tick += 1 }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.pill(tint, compact: true)).disabled(blocked)
            } else if signedIn == nil {
                Button("Finish") { model.finishNew() }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).disabled(blocked || model.discarding)
                    .help("You can finish now and sign in later")
                Button("Sign in…") { if let c = model.claudePath { ClaudeCLI.openLogin(c, account: Account(draft.entry), email: nil) } }
                    .buttonStyle(.pill(tint, compact: true)).disabled(model.claudePath == nil)
            } else {
                if taken != nil, draft.createdConfigDir != nil {
                    Button(signingOut ? "Signing out…" : "Sign out") { signOut() }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).disabled(signingOut)
                }
                Button("Finish") { model.finishNew() }.buttonStyle(.pill(.green, compact: true)).disabled(blocked || model.discarding)
            }
        }
        .padding(.horizontal, hint ? 16 : 0).padding(.vertical, hint ? 10 : 0)
        .background(hint ? Color.primary.opacity(0.04) : Color.clear)
        .overlay(alignment: .top) { if hint { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) } }
    }

    private var nextHint: String {
        switch current {
        case 1: return monitor.checked ? "Next: close Claude" : "Checking what's running…"
        case 2: return blocked ? "Fix the red lines to go on" : draft.source == .new ? "Next: create the folder and links" : "Next: connect the folder"
        case 3: return "Next: sign in (or finish and sign in later)"
        default: return "Next: add the Dock icon"
        }
    }

    // MARK: pieces

    /// The folders on this Mac, plus any picked with “Choose another folder…”.
    private var folderChoices: [String] {
        var list = Detect.configFolders().map(\.path)
        for p in customFolders where !list.contains(where: { FolderKey.canonical($0) == FolderKey.canonical(p) }) { list.append(p) }
        return list
    }

    private func folderRow(_ path: String) -> some View {
        let owner = FolderRules.configOwner(path, among: model.accounts)
        let kind = FolderKind.of(path)
        var detail: String
        switch kind {
        case .claudeCode(let email): detail = email.map { Privacy.masked($0) } ?? "not signed in"
        case .empty: detail = "empty"
        case .missing: detail = "doesn't exist"
        case .other: detail = "not a Claude Code folder"
        }
        if FolderKey.canonical(path) == FolderKey.canonical("~/.claude") { detail = "default · " + detail }
        if let used = FolderKind.lastUsed(path) { detail += " · " + Self.ago(used) }
        let selected = draft.existingDir.map { FolderKey.canonical($0) == FolderKey.canonical(path) } ?? false
        let (tag, color): (String, Color) = owner.map { ($0.name, .red) } ?? (kind == .other || kind == .missing ? ("can't use", .red) : ("free", .green))
        return listRow(selected: selected, disabled: owner != nil || draft.started) {
            HStack(spacing: 6) {
                Text(path).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).layoutPriority(1)
                Text("· " + detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(tag).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
                    .padding(.horizontal, 7).padding(.vertical, 1).background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }
        } action: { draft.existingDir = path }
    }

    private func listRow<C: View>(selected: Bool, disabled: Bool, @ViewBuilder content: () -> C, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle().strokeBorder(selected ? Color.white : Color.secondary, lineWidth: selected ? 4 : 1.4).frame(width: 13, height: 13)
                content()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(selected ? 0.1 : 0.03))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && !selected ? 0.5 : 1)
    }

    private func statusLines(_ list: [SetupCheck], indent: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(list) { c in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Group {
                        if c.state == .wait {
                            Circle().fill(Color.secondary.opacity(0.6)).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0.height / 2 + 4 }
                        } else {
                            Image(systemName: c.state == .ok ? "checkmark" : c.state == .bad ? "xmark" : "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(c.state == .ok ? Color(nsColor: Painter.green) : c.state == .bad ? Color.red : Color.orange)
                        }
                    }
                    .frame(width: 13)
                    Text(c.text).font(.system(size: 12)).foregroundStyle(c.state == .wait ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, indent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runSummary: String {
        let apps = monitor.runs.filter { $0.kind == .desktop }.count, sessions = monitor.runs.count - apps
        return [apps > 0 ? "\(apps) app\(apps == 1 ? "" : "s")" : nil, sessions > 0 ? "\(sessions) Claude Code session\(sessions == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// One line per desktop app, then the Claude Code sessions grouped by where they run and which folder they use.
    private var runLines: [String] {
        var out: [String] = []
        for r in monitor.runs where r.kind == .desktop {
            let key = FolderKey.canonical(r.folder)
            let owner = model.accounts.first { FolderRules.windowKey($0.desktop, $0.desktopDataDir) == key }
            let which = key == FolderKey.canonical(FolderKey.standardDataDir) ? "standard window" : "separate window"
            out.append("Claude desktop app · " + (owner.map { "\($0.name) · " } ?? "") + which)
        }
        var parts: [String] = []
        for kind in [ClaudeRun.Kind.codeTab, .terminal] {
            for (folder, rs) in Dictionary(grouping: monitor.runs.filter { $0.kind == kind }, by: \.folder).sorted(by: { $0.key < $1.key }) {
                parts.append("\(rs.count) in \(kind == .codeTab ? "the Code tab" : "Terminal") on \(folder)")
            }
        }
        if !parts.isEmpty { out.append("Claude Code · " + parts.joined(separator: " · ")) }
        return out
    }

    /// Signs out the folder's login so the sign-in can be done again (only a folder this setup created).
    private func signOut() {
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
}

/// A label next to its control (fixed label width), or above it when stacked; never a window apart.
struct FormRow<Content: View>: View {
    let label: String
    var width: CGFloat = 76
    var stacked = false
    var info: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        let title = HStack(spacing: 5) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Color.primary.opacity(0.82))
            if let info { InfoDot(text: info) }
        }
        if stacked {
            VStack(alignment: .leading, spacing: 5) { title; content }.padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .center, spacing: 10) {
                title.frame(width: width, alignment: .leading)
                content
                Spacer(minLength: 0)
            }
            .frame(minHeight: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A pill switch whose options can be disabled (shown struck through).
struct Segments<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var disabled: Set<Value> = []
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                let off = disabled.contains(o), on = o == selection
                Button { selection = o } label: {
                    Text(title(o)).font(.system(size: 12, weight: on ? .semibold : .regular))
                        .strikethrough(off)
                        .foregroundStyle(on ? Color.primary : off ? Color.secondary.opacity(0.5) : Color.secondary)
                        .padding(.horizontal, 11).padding(.vertical, 4)
                        .background(Capsule().fill(on ? Color.primary.opacity(0.16) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(off)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }
}

/// Toggle chips that wrap onto more lines when narrow.
struct WrapChips: View {
    let items: [(String, Bool)]
    let toggle: (Int) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                Button { toggle(i) } label: {
                    Text(items[i].0).font(.system(size: 11.5))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(items[i].1 ? Color.accentPill.opacity(0.22) : Color.primary.opacity(0.06)))
                        .overlay(Capsule().stroke(items[i].1 ? Color.accentPill.opacity(0.6) : Color.primary.opacity(0.1)))
                        .foregroundStyle(items[i].1 ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension Color { static let accentPill = Color(red: 0.85, green: 0.47, blue: 0.34) }

/// Lays children out left to right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = (proposal.width.map { $0.isFinite ? $0 : 600 }) ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0 && x + z.width > maxW { y += row + spacing; x = 0; row = 0 }
            x += z.width + spacing; row = max(row, z.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(maxW, widest), height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + z.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z))
            x += z.width + spacing; row = max(row, z.height)
        }
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
