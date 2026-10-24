// Adding a Claude account: one page in Settings. The account lives in a new Claude Code folder or in one
// that already exists (the default ~/.claude too); a folder and a desktop window can belong to only one
// account, which the Checks card verifies live. A banner lists every desktop app window and its Code tab sessions
// open: the steps that write folders wait until it's quit (Claude Code in Terminal doesn't matter).
// Steps: quit the desktop app → create or connect the folder → sign in (Claude Code, then the desktop app) → add the Dock icon.

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
    var shareFrom = "~/.claude"         // the Claude Code folder the shared items are linked from
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
    /// An existing account whose behaviour settings (click, press and hold, panel design, icon style, refresh,
    /// notifications, login item, renewal) the new one starts with, so it acts like the others.
    var template: AccountEntry?
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
        if let t = template {
            e.style = t.style; e.pollMinutes = t.pollMinutes; e.notify = t.notify; e.notifyPercent = t.notifyPercent
            e.openAtLogin = t.openAtLogin; e.autoRenew = t.autoRenew; e.clickAction = t.clickAction
            e.peekSeconds = t.peekSeconds; e.longPressDetails = t.longPressDetails; e.panelDesign = t.panelDesign
        }
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
    static func shared(_ d: NewAccountDraft) -> URL { URL(fileURLWithPath: expand(d.shareFrom)) }

    static func exists(_ path: String) -> Bool { !path.isEmpty && FileManager.default.fileExists(atPath: expand(path)) }

    /// The Claude Code folder is in place (created, or an existing one connected) and so is the window's data folder.
    static func foldersReady(_ d: NewAccountDraft) -> Bool {
        let config = d.source == .existing ? d.connected : exists(d.configDir)
        return config && (d.window != .separate || exists(d.dataDir))
    }

    static func linksReady(_ d: NewAccountDraft) -> Bool {
        d.source == .existing || d.share.allSatisfy { item in
            !FileManager.default.fileExists(atPath: shared(d).appendingPathComponent(item.rawValue).path)
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
        // the name: only a clash is worth a line (the caption under the field says what it's for)
        if accounts.contains(where: { $0.name.lowercased() == name.lowercased() }) { out.append(.init(section: .account, state: .bad, text: "Another account is already called “\(name)”")) }

        // the Claude Code folder
        if d.source == .new {
            if let owner = FolderRules.configOwner(d.configDir, among: accounts) {
                out.append(.init(section: .folder, state: .bad, text: "\(d.configDir) overlaps “\(owner.name)”'s folder. Pick another name."))
            } else if exists(d.configDir) && d.createdConfigDir == nil {
                out.append(.init(section: .folder, state: .bad, text: "\(d.configDir) already exists. Choose “Existing folder” to connect it, or pick another name."))
            } else if !name.isEmpty {
                out.append(.init(section: .folder, state: .ok, text: "New folder \(d.configDir)"))
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
                    out.append(.init(section: .folder, state: .ok, text: "Free · empty, Claude Code sets it up when you sign in"))
                case .claudeCode:
                    out.append(.init(section: .folder, state: .ok, text: "Free · a Claude Code folder"))
                }
            }
        } else {
            out.append(.init(section: .folder, state: .wait, text: "Pick the folder to connect"))
        }

        // the desktop window
        switch d.window {
        case .none: out.append(.init(section: .window, state: .ok, text: "Claude Code only, no desktop window"))
        default:
            if let owner = FolderRules.windowOwner(d.window, d.dataDir, among: accounts) {
                out.append(.init(section: .window, state: .bad, text: d.window == .standard ? "The standard window is “\(owner.name)”'s: choose Separate" : "\(d.dataDir) is already “\(owner.name)”'s window"))
            } else {
                let standardOwner = FolderRules.windowOwner(.standard, FolderKey.standardDataDir, among: accounts)
                out.append(.init(section: .window, state: .ok, text: d.window == .standard ? "The standard Claude window and its sign-in"
                                 : "Own window and sign-in" + (standardOwner.map { " · standard is \($0.name)'s" } ?? "")))
            }
        }

        // the sign-in: shared is allowed, but both icons would show the same usage
        if let email = signedInEmail(d) {
            if let owner = FolderRules.signInOwner(email, among: accounts) {
                out.append(.init(section: .signIn, state: .warn, text: "Signed in as \(Privacy.masked(email)), like “\(owner.name)”: both icons would show the same usage"))
            } else {
                out.append(.init(section: .signIn, state: .ok, text: "Signed in as \(Privacy.masked(email))"))
            }
        }

        // The desktop app open: it writes sign-in and settings, which matters only until the folders exist.
        // Claude Code in Terminal doesn't get in the way.
        let appRuns = runs.filter { $0.kind != .terminal }
        if foldersReady(d) { return out }
        if !checked { out.append(.init(section: .running, state: .wait, text: "Checking whether the desktop app is open…")) }
        else if appRuns.isEmpty { out.append(.init(section: .running, state: .ok, text: "The desktop app is closed")) }
        else {
            let apps = appRuns.filter { $0.kind == .desktop }.count
            out.append(.init(section: .running, state: d.continueAnyway ? .warn : .bad,
                             text: "The desktop app is open (\(apps) window\(apps == 1 ? "" : "s"))"))
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

    /// Whether this account's own Claude window is signed in, and to the same claude.ai account as Claude Code.
    enum DesktopSignIn { case notChecked, notSignedIn, same, different, unknown }

    /// Reads the window's config.json only for whether a login is stored and which account it last used
    /// (an account id); nothing from it is kept or shown. The standard window and Terminal only aren't checked.
    static func desktopSignIn(_ d: NewAccountDraft) -> DesktopSignIn {
        guard d.window == .separate, foldersReady(d) else { return .notChecked }
        let file = (expand(d.dataDir) as NSString).appendingPathComponent("config.json")
        guard let data = FileManager.default.contents(atPath: file),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              j.keys.contains(where: { $0.hasPrefix("oauth:tokenCache") }),
              let desktop = j["lastKnownAccountUuid"] as? String else { return .notSignedIn }
        guard let code = Account.expectedAccountUuid(configDir: d.configDir) else { return .unknown }
        return desktop == code ? .same : .different
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
                let src = shared(d).appendingPathComponent(item.rawValue)
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
/// steps, with the "desktop app is open" warning attached to step 1). Narrower: one column with a progress
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
    @State private var signingOut = false
    @State private var customFolders: [String] = []
    @State private var showHidden = false
    @State private var checking = false

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
        .alert("Quit the desktop app?", isPresented: $confirmQuit) {
            Button("Quit them", role: .destructive) { ClaudeRuns.quitDesktopApps(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { monitor.refresh() } }
            Button("Not now", role: .cancel) {}
        } message: { Text("Every Claude window closes, with the Claude Code sessions in its Code tab. Unsent messages there may be lost.") }
    }

    // MARK: state

    /// Only the Claude desktop app (with its Code tab) gets in the way; Claude Code in Terminal doesn't.
    private var appRuns: [ClaudeRun] { monitor.runs.filter { $0.kind != .terminal } }
    private var checks: [SetupCheck] { NewAccountSetup.checks(draft, accounts: model.accounts, runs: appRuns, checked: monitor.checked) }
    private func checks(_ s: SetupCheck.Section) -> [SetupCheck] { checks.filter { $0.section == s } }
    private var blocked: Bool { checks.contains { $0.blocks } }
    /// The desktop app open while the folders don't exist yet (afterwards it can stay open).
    private var running: Bool { monitor.checked && !appRuns.isEmpty && !draft.continueAnyway && !NewAccountSetup.foldersReady(draft) }
    private var desktop: NewAccountSetup.DesktopSignIn { NewAccountSetup.desktopSignIn(draft) }
    private var needsDesktop: Bool { draft.window == .separate }
    private var desktopDone: Bool { !needsDesktop || desktop == .same || desktop == .unknown }
    private var folders: Bool { NewAccountSetup.foldersReady(draft) && NewAccountSetup.linksReady(draft) }
    private var signedIn: String? { checks(.folder).contains { $0.blocks } ? nil : NewAccountSetup.signedInEmail(draft) }
    private var windowOpen: Bool { NewAccountSetup.foldersReady(draft) && NewAccountSetup.windowOpen(draft) }
    private var tint: Color { Color(nsColor: draft.color.color(fiveHour: nil, stale: false)) }
    private var createTitle: String { draft.source == .new ? "Create" : "Connect" }

    /// What's next: 1 quit the desktop app, 2 folder, 3 Claude Code sign-in, 4 desktop app sign-in, 5 Dock icon.
    private var current: Int {
        if !NewAccountSetup.foldersReady(draft) && (running || !monitor.checked) { return 1 }
        if !folders { return 2 }
        if signedIn == nil { return 3 }
        if !desktopDone { return 4 }
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
                    if folders { signInCard }
                }
                .frame(maxWidth: 700)
                .padding(14)
                .frame(maxWidth: .infinity)
            }
            if running { warningBar(narrow: narrow) }
            actionBar(hint: true)
        }
    }

    // MARK: cards

    private func accountCard(labelWidth: CGFloat, stacked: Bool) -> some View {
        SCard(title: "Account") {
          // No row labels: a name field and colour swatches say what they are.
           VStack(alignment: .leading, spacing: 10) {
                TextField("Name, e.g. personal", text: $draft.name)
                    .textFieldStyle(.plain).font(.system(size: 13)).padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.25)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.14)))
                    .frame(maxWidth: 260)
                    .disabled(draft.started)
                FlowLayout(spacing: 6) {
                    ForEach(TileColor.accents, id: \.self) { c in
                        Swatch(color: c, selected: draft.color == c, size: 16).onTapGesture { draft.color = c }
                    }
                }
                .padding(.leading, -3)
           }
           .frame(maxWidth: .infinity, alignment: .leading)
           .padding(.top, 2)
            statusLines(checks(.account), indent: 0).padding(.top, 4)
        }
    }

    private func folderCard(labelWidth: CGFloat, stacked: Bool) -> some View {
        SCard(title: "Claude Code folder") {
            // Its sign-in, settings and history live here; one account per folder. The chosen option opens its details.
            let options: [(FolderSource, String, String)] = [
                (.new, "New folder", draft.name.isEmpty ? "Starts fresh" : "Starts fresh in \(draft.newConfigDir)"),
                (.existing, "Existing folder", "Keeps its sign-in, settings and history")]
            VStack(spacing: 1) {
                ForEach(options, id: \.0) { o in
                    VStack(spacing: 0) {
                        listRow(selected: draft.source == o.0, disabled: draft.started) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(o.1).font(.system(size: 12.5, weight: draft.source == o.0 ? .medium : .regular))
                                Text(o.2).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        } action: { draft.source = o.0 }
                        if draft.source == o.0 {
                            Group { if o.0 == .new { shareChoice } else { existingChoice } }
                                .padding(.leading, 32).padding(.trailing, 10).padding(.top, 2).padding(.bottom, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.1))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.09)))
            .padding(.top, 2)
            statusLines(checks(.folder).filter { $0.state == .bad || $0.state == .warn }, indent: 0).padding(.top, 4)
        }
    }

    /// Under “New folder”: what to link from the main folder.
    private var shareChoice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Share from").font(.system(size: 11)).foregroundStyle(.secondary)
                // Any Claude Code folder on this Mac can be the source.
                Menu {
                    ForEach(shareSources, id: \.self) { p in
                        let owner = model.accounts.first { FolderKey.canonical($0.configDir) == FolderKey.canonical(p) }
                        Button(p + (owner.map { "  ·  \($0.name)" } ?? "") + (FolderKey.canonical(p) == FolderKey.canonical(draft.shareFrom) ? "  ✓" : "")) {
                            draft.shareFrom = p
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(draft.shareFrom).font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold))
                    }
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(NewAccountSetup.foldersReady(draft))
                InfoDot(text: "Linked, so edits there show up in this account too. Sign-in, plugins and usage stay separate.")
            }
            WrapChips(items: SharedItem.allCases.map { ($0.title, draft.share.contains($0)) }, tint: tint) { i in
                let item = SharedItem.allCases[i]
                if draft.share.contains(item) { draft.share.remove(item) } else { draft.share.insert(item) }
            }
            .disabled(NewAccountSetup.foldersReady(draft))
        }
    }

    /// Under “Existing folder”: the folders this account can take.
    @ViewBuilder private var existingChoice: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Only folders this account can take are offered; the rest are named underneath with the reason.
            let offered = folderChoices.filter { canTake($0) || isSelected($0) }
            VStack(spacing: 1) {
                ForEach(offered, id: \.self) { path in folderRow(path) }
                if offered.isEmpty {
                    Text("No free Claude Code folder on this Mac")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03))
                }
                listRow(selected: false, disabled: draft.started) {
                    Text("Choose another folder…").font(.system(size: 12))
                } action: {
                    if let p = pickFolder() {
                        if !folderChoices.contains(where: { FolderKey.canonical($0) == FolderKey.canonical(p) }) { customFolders.append(p) }
                        draft.existingDir = folderChoices.first { FolderKey.canonical($0) == FolderKey.canonical(p) } ?? p
                    }
                }
            }
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.09)))
            // Folders that can't be taken: one line, opening a compact list (stays short with many accounts).
            let hidden: [(path: String, why: String)] = folderChoices.compactMap { p in
                if let o = FolderRules.configOwner(p, among: model.accounts) { return (p, o.name) }
                return canTake(p) ? nil : (p, "not a Claude Code folder")
            }
            if !hidden.isEmpty {
                Button { withAnimation(.easeOut(duration: 0.15)) { showHidden.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(showHidden ? 90 : 0))
                        Text("\(hidden.count) folder\(hidden.count == 1 ? "" : "s") " + (hidden.allSatisfy { $0.why != "not a Claude Code folder" }
                             ? "already used by other accounts" : "not offered"))
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 7)
                if showHidden {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(hidden, id: \.path) { h in
                            HStack(spacing: 8) {
                                Text(h.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(h.why).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .padding(.leading, 14).padding(.top, 4)
                }
            }
        }
    }

    private func windowCard(labelWidth: CGFloat, stacked: Bool) -> some View {
        let standardFree = FolderRules.windowOwner(.standard, FolderKey.standardDataDir, among: model.accounts) == nil
        // The standard window is offered only while no other account has it.
        let options: [(DesktopMode, String, String)] = (standardFree ? [(.standard, "The standard Claude window", "The desktop app as you usually open it, signed in to this account")] : [])
            + [(.separate, "Its own Claude window", "The desktop app opened separately, with this account's sign-in"),
               (.none, "Terminal only", "No desktop app for this account; Claude Code in Terminal")]
        return SCard(title: "Claude desktop app") {
            VStack(spacing: 1) {
                ForEach(options, id: \.0) { o in
                    listRow(selected: draft.window == o.0, disabled: draft.started) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(o.1).font(.system(size: 12.5, weight: draft.window == o.0 ? .medium : .regular))
                            Text(o.2).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } action: { draft.window = o.0 }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.09)))
            .padding(.top, 2)
            statusLines(checks(.window).filter { $0.state != .ok }, indent: 0).padding(.top, 4)
        }
    }

    /// Medium and narrow layouts show the sign-in as a card (wide shows it in step 3).
    private var signInCard: some View {
        SCard(title: "Sign in") { signInParts }
    }

    /// The two parts of signing in: a · Claude Code (Terminal), b · the desktop app (its own window).
    private var signInParts: some View {
        let owner = signedIn.flatMap { FolderRules.signInOwner($0, among: model.accounts) }
        return VStack(spacing: 1) {
            part(signedIn == nil ? (current == 3 ? .now : .todo) : owner != nil ? .warn : .done, current: current == 3,
                 title: "a · Claude Code") {
                if let email = signedIn {
                    sub(Privacy.masked(email) + (draft.source == .existing && !draft.started ? ", already in the folder" : ""))
                    if let o = owner {
                        Text("“\(o.name)” uses this sign-in too: both icons would show the same usage")
                            .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        if draft.createdConfigDir != nil {
                            Button(signingOut ? "Signing out…" : "use another account") { signOut() }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).underline().disabled(signingOut)
                        }
                    }
                } else {
                    sub("Terminal opens; approve in the browser")
                }
            }
            if draft.window == .standard {
                part(.todo, current: false, title: "b · Desktop app") { sub("Uses the standard Claude window and its sign-in") }
            } else if needsDesktop {
                let state: StepState = signedIn == nil ? .todo : desktopDone ? .done : desktop == .different ? .warn : current == 4 ? .now : .todo
                part(state, current: current == 4, title: "b · Desktop app") {
                    if signedIn == nil {
                        sub("After Claude Code")
                    } else {
                        switch desktop {
                        case .same: Text("Its window is signed in to the same account").font(.system(size: 11.5)).foregroundStyle(Color(nsColor: Painter.green))
                            .fixedSize(horizontal: false, vertical: true)
                        case .unknown: sub("Its window is signed in")
                        case .different:
                            Text("Its window is signed in to a different account").font(.system(size: 11.5)).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            sub("In that window: Settings ▸ Log out, then sign in as \(Privacy.masked(signedIn ?? ""))")
                        default:
                            sub("Sign in to its own Claude window as \(Privacy.masked(signedIn ?? ""))")
                            if windowOpen {
                                HStack(spacing: 5) { ProgressView().controlSize(.mini); sub("waiting for the sign-in") }
                            }
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08)))
    }

    private func sub(_ s: String) -> some View {
        Text(s).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func part<C: View>(_ state: StepState, current: Bool, title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                switch state {
                case .done: Circle().fill(Color(nsColor: Painter.green)); Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(.black.opacity(0.7))
                case .warn, .bad: Circle().fill(Color.orange); Text("!").font(.system(size: 9, weight: .heavy)).foregroundStyle(.black.opacity(0.7))
                case .now: Circle().strokeBorder(tint, lineWidth: 2)
                default: Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.3)
                }
            }
            .frame(width: 14, height: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(state == .todo ? Color.secondary : Color.primary)
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(current ? 0.08 : 0.03))
    }

    // MARK: steps (wide)

    private var stepsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {

            let ready = NewAccountSetup.foldersReady(draft)
            stepRow(1, state: ready ? .done : monitor.checked ? (appRuns.isEmpty ? .done : draft.continueAnyway ? .warn : .bad) : .todo,
                    title: "Quit the desktop app",
                    detail: ready ? "done · it can stay open now" : !monitor.checked ? "checking…" : appRuns.isEmpty ? "closed" : nil,
                    connector: running) {
                if running { warningBox }
            }
            stepRow(2, state: folders ? .done : current == 2 ? .now : running ? .held : .todo,
                    title: draft.source == .new ? "Create the folder" + (draft.share.isEmpty ? "" : " and links") : "Connect the folder",
                    detail: folders ? draft.configDir : running ? "held until the desktop app is quit" : checks.contains(where: { $0.blocks && $0.section != .running }) ? "fix the red lines first" : nil,
                    detailBad: running && !folders) { EmptyView() }
            stepRow(3, state: !folders ? .todo
                        : (signedIn.flatMap { FolderRules.signInOwner($0, among: model.accounts) } != nil || (needsDesktop && signedIn != nil && desktop == .different)) ? .warn
                        : current == 3 || current == 4 ? .now : .done,
                    title: "Sign in",
                    detail: folders ? nil : draft.window == .separate ? "Claude Code, then the desktop app" : "Claude Code") {
                if folders { signInParts.padding(.top, 3) }
            }
            stepRow(4, state: current == 5 ? .now : .todo, title: "Add the Dock icon", detail: "Finish installs “cl_audit \(draft.name.isEmpty ? "…" : draft.name)”") { EmptyView() }

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
                    if state == .bad && n == 1 { Text("· still open").font(.system(size: 12)).foregroundStyle(.red) }
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

    /// The "desktop app is open" warning, attached to step 1 (only until the folder exists).
    private var warningBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("While open, the desktop app writes its sign-in and settings, which could overwrite the folder being set up. It can stay open once the folder exists.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(runGroups, id: \.title) { g in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(g.title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(g.items, id: \.self) { Text($0).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle) }
                            if let n = g.note { Text(n).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            HStack {
                if appRuns.contains(where: { $0.kind != .terminal }) {
                    Button("Quit the desktop app") { confirmQuit = true }.buttonStyle(.pill(.red, compact: true))
                }
                Spacer()
                checkAgain
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
        let ready = NewAccountSetup.foldersReady(draft)
        // (name, done, the `current` value it stands for); the desktop app part only with its own window.
        let items: [(String, Bool, Int)] = [("Quit desktop app", ready || (monitor.checked && appRuns.isEmpty), 1),
                                            (draft.source == .new ? "Create folder" : "Connect folder", folders, 2),
                                            ("Claude Code", signedIn != nil, 3)]
            + (needsDesktop ? [("Desktop app", signedIn != nil && desktopDone, 4)] : []) + [("Dock icon", false, 5)]
        return HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                let it = items[i], now = it.2 == current, bad = it.2 == 1 && running
                HStack(spacing: 4) {
                    ZStack {
                        Circle().fill(it.1 ? Color(nsColor: Painter.green) : bad ? Color.red : Color.clear)
                        Circle().strokeBorder(it.1 || bad ? Color.clear : now ? tint : Color.secondary.opacity(0.6), lineWidth: now ? 2 : 1.2)
                        Text(it.1 ? "✓" : bad ? "!" : "\(i + 1)").font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(it.1 ? Color.black.opacity(0.7) : bad ? .white : now ? .primary : .secondary)
                    }
                    .frame(width: 16, height: 16)
                    if !compact || now { Text(it.0).font(.system(size: 11.5)).foregroundStyle(bad ? Color.red : now ? Color.primary : Color.secondary) }
                }
                if i < items.count - 1 { Text("›").foregroundStyle(.tertiary) }
            }
        }
    }

    private func warningBar(narrow: Bool) -> some View {
        let message = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(draft.continueAnyway ? Color.orange : Color.red).frame(width: 8, height: 8)
            (Text(draft.continueAnyway ? "Continuing while the desktop app is open" : "The desktop app is open").bold()
             + Text(" · " + runSummary + (draft.continueAnyway ? "" : ": \(createTitle) waits until it's quit")).foregroundColor(.secondary))
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        let buttons = HStack(spacing: 10) {
            if !draft.continueAnyway {
                if appRuns.contains(where: { $0.kind != .terminal }) {
                    Button("Quit the desktop app") { confirmQuit = true }.buttonStyle(.pill(.red, compact: true))
                }
                checkAgain
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

    /// Looks again right away (it also looks every 2 s), with a short "checking" state so the click shows.
    private var checkAgain: some View {
        Button {
            checking = true
            monitor.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { checking = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise").font(.system(size: 9.5, weight: .semibold))
                    .rotationEffect(.degrees(checking ? 360 : 0)).animation(checking ? .linear(duration: 0.8) : nil, value: checking)
                Text(checking ? "Checking…" : "Check again")
            }
        }
        .buttonStyle(PillButtonStyle(tint: nil, compact: true))
        .disabled(checking)
    }

    /// Cancel on the left, the one next action on the right ("Finish now" stays next to it once the folder exists).
    private func actionBar(hint: Bool) -> some View {
        HStack(spacing: 8) {
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
                .buttonStyle(.pill(tint, compact: true)).disabled(blocked || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            } else if current == 5 {
                Button("Finish") { model.finishNew() }.buttonStyle(.pill(.green, compact: true)).disabled(blocked || model.discarding)
            } else {
                Button(desktop == .different ? "Finish anyway" : "Finish now") { model.finishNew() }
                    .buttonStyle(PillButtonStyle(tint: nil, compact: true)).disabled(blocked || model.discarding)
                    .help("Sign-in can be finished later from Settings")
                if signedIn == nil {
                    Button("Sign in to Claude Code…") { if let c = model.claudePath { ClaudeCLI.openLogin(c, account: Account(draft.entry), email: nil) } }
                        .buttonStyle(.pill(tint, compact: true)).disabled(model.claudePath == nil)
                } else {
                    Button(windowOpen ? "Show Claude window" : "Open Claude window") { Launcher.openClaude(Account(draft.entry)) }
                        .buttonStyle(.pill(tint, compact: true))
                }
            }
        }
        .padding(.horizontal, hint ? 16 : 0).padding(.vertical, hint ? 10 : 0)
        .background(hint ? Color.primary.opacity(0.04) : Color.clear)
        .overlay(alignment: .top) { if hint { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) } }
    }

    private var nextHint: String {
        switch current {
        case 1: return monitor.checked ? "Next: quit the desktop app" : "Checking the desktop app…"
        case 2: return draft.name.isEmpty ? "Next: name the account" : draft.source == .existing && draft.existingDir == nil ? "Next: pick a folder" : blocked ? "Fix the red lines to go on" : draft.source == .new ? "Next: create the folder and links" : "Next: connect the folder"
        case 3: return "Next: sign in to Claude Code"
        case 4: return desktop == .different ? "Its Claude window uses another account" : "Next: sign in to the desktop app"
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

    /// Claude Code folders the shared items can be linked from.
    private var shareSources: [String] {
        Detect.configFolders().map(\.path).filter { if case .claudeCode = FolderKind.of($0) { return true }; return false }
    }

    /// A folder this account can connect: no other account uses it, and it's a Claude Code folder or empty.
    private func canTake(_ path: String) -> Bool {
        guard FolderRules.configOwner(path, among: model.accounts) == nil else { return false }
        switch FolderKind.of(path) { case .claudeCode, .empty: return true; default: return false }
    }

    private func isSelected(_ path: String) -> Bool {
        draft.existingDir.map { FolderKey.canonical($0) == FolderKey.canonical(path) } ?? false
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
        let selected = isSelected(path)
        return listRow(selected: selected, disabled: owner != nil || draft.started) {
            HStack(spacing: 6) {
                Text(path).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).layoutPriority(1)
                Text("· " + detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
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
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(c.state == .ok ? Color(nsColor: Painter.green) : c.state == .bad ? Color.red : Color.orange)
                        }
                    }
                    .frame(width: 12)
                    Text(c.text).font(.system(size: 11.5))
                        .foregroundStyle(c.state == .bad ? Color.red : c.state == .warn ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, indent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runSummary: String {
        let apps = appRuns.filter { $0.kind == .desktop }.count, sessions = appRuns.count - apps
        return [apps > 0 ? "\(apps) window\(apps == 1 ? "" : "s")" : nil, sessions > 0 ? "\(sessions) Code tab session\(sessions == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// What's open, by place: the desktop app's windows and their Code tab sessions.
    private var runGroups: [(title: String, items: [String], note: String?)] {
        var out: [(String, [String], String?)] = []
        let apps = appRuns.filter { $0.kind == .desktop }.map { r -> String in
            let key = FolderKey.canonical(r.folder)
            let owner = model.accounts.first { FolderRules.windowKey($0.desktop, $0.desktopDataDir) == key }
            let which = key == FolderKey.canonical(FolderKey.standardDataDir) ? "standard window" : "separate window"
            return (owner.map { "\($0.name) · " } ?? "") + which
        }
        if !apps.isEmpty { out.append((apps.count == 1 ? "Desktop app" : "Desktop apps", apps, nil)) }
        for (kind, title, note) in [(ClaudeRun.Kind.codeTab, "Code tab", "closes with its app" as String?)] {
            let groups = Dictionary(grouping: appRuns.filter { $0.kind == kind }, by: \.folder).sorted { $0.key < $1.key }
            guard !groups.isEmpty else { continue }
            out.append((title, groups.map { "\($0.value.count) session\($0.value.count == 1 ? "" : "s") · \($0.key)" }, note))
        }
        return out
    }

    private var runLines: [String] { runGroups.map { "\($0.title): " + $0.items.joined(separator: ", ") } }

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
    var tint: Color = .accentPill
    let toggle: (Int) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                // Selected: a check and a filled pill. Not selected: a plus and an outline only.
                let on = items[i].1
                Button { toggle(i) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: on ? "checkmark" : "plus").font(.system(size: 9, weight: .bold))
                        Text(items[i].0).font(.system(size: 11.5, weight: on ? .medium : .regular))
                    }
                    .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 3)
                    .background(Capsule().fill(on ? tint.opacity(0.22) : Color.clear))
                    .overlay(Capsule().strokeBorder(on ? tint.opacity(0.55) : Color.secondary.opacity(0.4),
                                                    style: StrokeStyle(lineWidth: 1, dash: on ? [] : [3, 2])))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .contentShape(Capsule())
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
