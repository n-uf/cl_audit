// Adding a Claude account: one page in Settings. The account lives in a new Claude Code folder or in one
// that already exists (the default ~/.claude too); a folder and a desktop window can belong to only one
// account, which the Checks card verifies live. A banner lists every desktop app window and its Code tab sessions
// open: the steps that write folders wait until it's quit (Claude Code in Terminal doesn't matter).
// The Claude Code card leads with the account: one signed in in a folder no profile uses (connecting that folder), or
// "Sign in to another account…" with the address filled in, in a new folder. Folders stay where they are.
// Steps: quit the desktop app → create or connect the folder → sign in (Claude Code, then the Claude window) → add the Dock icon.

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
    var continueAnyway = false          // set up while Claude is still running
    var usageInDock = true              // off: no Dock icon, usage read in the background ("Start reading usage")
    var claudeWindow = true             // off: no Claude window, so no Claude app sign-in step
    /// "Sign in to another account…": the address Claude Code's sign-in is filled in with (only filled in: the
    /// browser's claude.ai account decides), the address row open, and when Sign in was pressed.
    var email = ""
    var asking = false
    var signInAsked: Date?
    /// The account the folder was signed in to when Sign in was pressed (nil: none), so signing in again in the
    /// folder this setup made waits for another account, not just any sign-in.
    var seatAtAsk: Seat?
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
    /// The usual Claude app for ~/.claude, its own Claude window for any other folder.
    var window: DesktopMode { .for(configDir: configDir) }
    var dataDir: String {
        switch window {
        case .separate: return "~/Library/Application Support/Claude-\(id)"
        case .standard: return FolderKey.standardDataDir
        }
    }

    var entry: AccountEntry {
        var e = AccountEntry(id: id, name: name, label: label.isEmpty ? "NEW" : label, configDir: configDir)
        if let t = template {
            e.style = t.style; e.pollMinutes = t.pollMinutes; e.notify = t.notify; e.notifyPercent = t.notifyPercent; e.notifyBack = t.notifyBack
            e.dockRuns = t.dockRuns; e.windowFollowsDock = t.windowFollowsDock; e.autoRenew = t.autoRenew; e.clickAction = t.clickAction
            e.peekSeconds = t.peekSeconds; e.longPressDetails = t.longPressDetails; e.panelDesign = t.panelDesign
            e.windowDot = t.windowDot
        }
        e.desktop = window
        e.desktopDataDir = window == .separate ? dataDir : ""
        e.color = color
        e.accent = color
        e.iconHidden = !usageInDock
        e.claudeWindow = claudeWindow
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

    /// Accounts signed in in Claude Code folders on this Mac that no profile uses, each with its folder (picking one
    /// connects that folder as it is). Other profiles' folders, and folders inside or around them, are left out.
    static func freeAccounts(among accounts: [AccountEntry], folders: [FolderChoice] = Detect.configFolders()) -> [(email: String, path: String)] {
        folders.compactMap { c in
            guard let e = c.detail, FolderRules.configOwner(c.path, among: accounts) == nil else { return nil }
            return (e, c.path)
        }
    }

    /// Why Sign in (the address route) can't go with this address, or nil. The address only fills in the sign-in, so
    /// this is the early, by-address part; afterwards the account and organisation ids decide (checks).
    static func addressProblem(_ email: String, among accounts: [AccountEntry]) -> String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard e.contains("@"), !e.hasPrefix("@"), !e.hasSuffix("@"), !e.contains(" ") else { return "Type the account's email address." }
        if let owner = accounts.first(where: { ($0.seat?.email ?? Account.expectedEmail(configDir: $0.configDir))?.lowercased() == e.lowercased() }) {
            return "That's the account of “\(owner.name)”. One profile per account."
        }
        return nil
    }

    /// A free folder already signed in to this address, if any: picking it connects that folder, no new sign-in.
    static func freeFolder(for email: String, among accounts: [AccountEntry], folders: [FolderChoice] = Detect.configFolders()) -> String? {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard !e.isEmpty else { return nil }
        return freeAccounts(among: accounts, folders: folders).first { $0.email.lowercased() == e }?.path
    }

    /// Sign in was pressed and the folder doesn't name another account yet: nothing signed in, or still the account it
    /// had when Sign in was pressed. Stops waiting after an hour (Sign in can be pressed again).
    static func waiting(_ d: NewAccountDraft, now: Date = Date(), signedIn: (String) -> Seat? = Account.signedInSeat) -> Bool {
        guard let asked = d.signInAsked, now.timeIntervalSince(asked) < 3600 else { return false }
        guard exists(d.configDir) || d.configDir == "~/.claude", let s = signedIn(d.configDir) else { return true }
        return d.seatAtAsk.map { s.same($0) } ?? false
    }

    /// Everything the Checks card shows, in order. Any `.bad` line blocks Create/Connect and Finish.
    static func checks(_ d: NewAccountDraft, accounts: [AccountEntry], runs: [ClaudeRun], checked: Bool) -> [SetupCheck] {
        var out: [SetupCheck] = []
        let name = d.name.trimmingCharacters(in: .whitespaces)
        // the name: only a clash is worth a line (the caption under the field says what it's for)
        if accounts.contains(where: { $0.name.lowercased() == name.lowercased() }) { out.append(.init(section: .account, state: .bad, text: "Another profile is already called “\(name)”")) }

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
        do {
            if let owner = FolderRules.windowOwner(d.window, d.dataDir, among: accounts) {
                out.append(.init(section: .window, state: .bad, text: d.window == .standard ? "The usual Claude app is “\(owner.name)”'s window" : "\(d.dataDir) is already “\(owner.name)”'s window"))
            } else {
                let standardOwner = FolderRules.windowOwner(.standard, FolderKey.standardDataDir, among: accounts)
                out.append(.init(section: .window, state: .ok, text: d.window == .standard ? "The usual Claude app and its sign-in"
                                 : "Own window and sign-in" + (standardOwner.map { " · standard is \($0.name)'s" } ?? "")))
            }
        }

        // the sign-in: one profile per Claude account seat (account and organisation ids, from the folder's
        // .claude.json); the address typed only filled in the sign-in, so another one is said, not refused
        if let email = signedInEmail(d) {
            if let owner = FolderRules.seatOwner(Account.signedInSeat(configDir: d.configDir), among: accounts) {
                out.append(.init(section: .signIn, state: .bad, text: "Signed in as \(Privacy.masked(email)), the Claude account of “\(owner.name)”: one profile per account"))
            } else if !d.email.isEmpty, d.email.lowercased() != email.lowercased() {
                out.append(.init(section: .signIn, state: .warn, text: "Signed in as \(Privacy.masked(email)), not \(Privacy.masked(d.email)): the browser's claude.ai account decided"))
            } else {
                out.append(.init(section: .signIn, state: .ok, text: "Signed in as \(Privacy.masked(email))"))
            }
        }

        // The desktop app open: it writes sign-in and settings, which matters only until the folders exist, and only
        // for a profile with a Claude window. Without one the only new folder is the Claude Code folder, which the
        // desktop app never writes (its Code tab uses ~/.claude, sign-in runs in Terminal, shared items are links).
        // Claude Code in Terminal doesn't get in the way.
        let appRuns = runs.filter { $0.kind != .terminal }
        if foldersReady(d) || !d.claudeWindow { return out }
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
    /// (an account id, not the organisation); nothing from it is kept or shown. The usual Claude app is checked too.
    static func desktopSignIn(_ d: NewAccountDraft) -> DesktopSignIn {
        guard d.claudeWindow, foldersReady(d) else { return .notChecked }
        let file = (expand(d.dataDir) as NSString).appendingPathComponent("config.json")
        guard let data = FileManager.default.contents(atPath: file),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              j.keys.contains(where: { $0.hasPrefix("oauth:tokenCache") }),
              let desktop = j["lastKnownAccountUuid"] as? String else { return .notSignedIn }
        guard let code = Account.expectedAccountUuid(configDir: d.configDir) else { return .unknown }
        return desktop == code ? .same : .different
    }

    static func windowOpen(_ d: NewAccountDraft) -> Bool {
        Launcher.activity(for: [Account(d.entry)])[expand(d.configDir)]?.desktopOpen ?? false
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
        if d.window == .separate, d.claudeWindow, !exists(d.dataDir) {     // no Claude window: no folder for one
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
    @State private var customFolders: [String] = []
    @State private var checking = false
    @State private var addressProblem: String?      // why Sign in (the address route) can't go yet
    @Environment(\.face) private var face

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
        .alert("Cancel the new profile\(draft.name.isEmpty ? "" : " “\(draft.name)”")?", isPresented: $confirmCancel) {
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
    private var running: Bool { draft.claudeWindow && monitor.checked && !appRuns.isEmpty && !draft.continueAnyway && !NewAccountSetup.foldersReady(draft) }
    /// "Quit the desktop app" is a step only for a profile with a Claude window (see NewAccountSetup.checks).
    private var quitStep: Bool { draft.claudeWindow }
    private var desktop: NewAccountSetup.DesktopSignIn { NewAccountSetup.desktopSignIn(draft) }
    /// The Claude window's own sign-in is a step whenever the profile has one (its own window or the usual Claude app).
    private var needsDesktop: Bool { draft.claudeWindow }
    private var desktopDone: Bool { !needsDesktop || desktop == .same || desktop == .unknown }
    private var folders: Bool { NewAccountSetup.foldersReady(draft) && NewAccountSetup.linksReady(draft) }
    private var signedIn: String? { checks(.folder).contains { $0.blocks } ? nil : NewAccountSetup.signedInEmail(draft) }
    private var windowOpen: Bool { NewAccountSetup.foldersReady(draft) && NewAccountSetup.windowOpen(draft) }
    private var tint: Color { Color(nsColor: draft.color.color(fiveHour: nil, stale: false)) }
    private var createTitle: String { draft.source == .new ? "Create" : "Connect" }
    /// The last step: a Dock icon, or (Usage in the Dock off) only reading its usage, which installs nothing.
    private var finishStep: String { draft.usageInDock ? "Add the Dock icon" : "Start reading usage" }

    /// What's next: 1 quit the desktop app, 2 folder, 3 Claude Code sign-in, 4 desktop app sign-in, 5 Dock icon.
    private var current: Int {
        if quitStep && !NewAccountSetup.foldersReady(draft) && (running || !monitor.checked) { return 1 }
        if !folders { return 2 }
        if signedIn == nil { return 3 }
        if !desktopDone { return 4 }
        return 5
    }

    // MARK: layouts

    private func wide(_ w: CGFloat) -> some View {
        let col3: CGFloat = 400, gaps: CGFloat = 12 * 2 + 16 * 2   // 400: room for the two keys in the warning box
        let rest = max(700, w - col3 - gaps)
        // The first column never gets narrower than its widest row (the window switch), so its cards line up.
        let col1 = max(350, rest * 0.42)
        // the folder card takes what is left, so the steps pane keeps the same gap to the window's edge
        return ScrollView {
            HStack(alignment: .top, spacing: 12) {
                // layout A: who it is and each part in its own card, the part's switch first
                VStack(spacing: 10) { profileCard(stacked: false); windowCard(stacked: false); dockCard(stacked: false) }
                    .frame(width: col1)
                folderCard(stacked: false).frame(minWidth: 0, maxWidth: .infinity)
                stepsPanel.frame(width: col3)
            }
            .frame(width: max(0, w - 32), alignment: .topLeading)   // never wider than the window
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
    }

    private func column(narrow: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    progressStrip(compact: narrow)
                    profileCard(stacked: narrow)
                    folderCard(stacked: narrow)
                    windowCard(stacked: narrow)
                    dockCard(stacked: narrow)
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

    /// Profile: who it is (name and colour), in rows like Settings ▸ Profile.
    private func profileCard(stacked: Bool) -> some View {
        SCard(title: "Profile", info: "The new profile: one Claude account, with its Claude Code folder and, if you want them, a Claude window and a Dock icon. Its click and panel settings start as \(draft.template?.name ?? "the other profiles'").") {
            SRow(label: "Name", info: "What cl_audit calls this profile. Its Dock icon is “cl_audit \(draft.name.isEmpty ? "<name>" : draft.name)”, and a new Claude Code folder is \(draft.name.isEmpty ? "~/.claude-<name>" : draft.newConfigDir).", first: true, stacked: stacked) {
                SField(placeholder: "e.g. personal", text: $draft.name, width: nil).disabled(draft.started)
            }
            if let clash = checks(.account).first { SRowLine(text: clash.text, color: face.danger) }
            SRow(label: "Colour", info: "The profile's colour in the launcher, on the dashboard and in its panels.", stacked: stacked) {
                FlowLayout(spacing: 6) {
                    ForEach(TileColor.accents, id: \.self) { c in
                        Swatch(color: c, selected: draft.color == c, size: 16).onTapGesture { draft.color = c }
                    }
                }
                .padding(.vertical, 6)
                .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
            }
        }
    }

    /// Claude window: its switch first (layout A). Which window follows from the folder: ~/.claude uses the usual Claude
    /// app, any other folder its own window; only a clash with another profile's window needs a line.
    private func windowCard(stacked: Bool) -> some View {
        SCard(title: "Claude window", info: "A Claude window signed in to this profile's account. A folder other than ~/.claude gets its own window, with its own sign-in and Code sidebar; ~/.claude uses the usual Claude app. Off: no window, and no window sign-in step; Claude Code in Terminal still works.") {
            SRow(label: "Claude window", info: "On: a Claude window for this profile, opened from the dashboard or its Dock icon. Off: none; its folder and sign-in are kept, so turning it on later needs no new setup.", first: true, stacked: stacked) {
                SSwitch(isOn: $draft.claudeWindow, on: draft.window == .standard ? "the usual Claude app" : "its own window", off: "none")
                    .disabled(draft.started)
            }
            if draft.claudeWindow, let clash = checks(.window).first(where: { $0.state != .ok }) {
                SRowLine(text: clash.text, color: clash.state == .bad ? face.danger : face.caution)
            }
        }
    }

    /// Dock icon: its switch first (layout A); the rest of its settings start as the template profile's.
    private func dockCard(stacked: Bool) -> some View {
        SCard(title: "Dock icon", info: "A Dock icon, “cl_audit \(draft.name.isEmpty ? "<name>" : draft.name)”, showing this profile's usage; how it runs, its click and its look start as \(draft.template?.name ?? "the other profiles'") and are in the profile's settings afterwards.") {
            SRow(label: "Usage in the Dock", info: "On: Finish installs the Dock icon and puts it in the Dock. Off: nothing is installed and the Dock isn't touched; cl_audit still reads the usage for the dashboard, the launcher and alerts.", first: true, stacked: stacked) {
                SSwitch(isOn: $draft.usageInDock, on: "shows the usage", off: "no Dock icon")
            }
        }
    }

    /// Claude Code: the account first, in a pop-up like Settings ▸ Login, then the folder that comes with it. A folder
    /// holds one sign-in, so an account is always picked with its folder: an account signed in in a folder no profile
    /// uses connects that folder as it is; "Sign in to another account…" signs in, with the address filled in, in a
    /// new folder (~/.claude-<id>). Folders are used where they are: Claude Code names a folder's Keychain sign-in
    /// after its path, so moving one would lose it.
    private func folderCard(stacked: Bool) -> some View {
        SCard(title: "Claude Code", info: "Where this profile's Claude Code sign-in, settings and history live: one folder, signed in to one claude.ai account. Folders are used where they are; Claude Code names a folder's Keychain sign-in after its path, so a moved folder would lose it.") {
            SRow(label: "Account", info: "The claude.ai account this profile is for. Accounts signed in in Claude Code folders on this Mac that no profile uses come with their folder; other profiles' are dimmed (one profile per account). Sign in to another account… opens Claude Code's own sign-in in Terminal with the address filled in; the browser's claude.ai account decides which account it is, checked afterwards by its account and organisation ids.", first: true, stacked: stacked) {
                accountValue
            }
            accountLine
            SRow(label: "Folder", info: "The Claude Code folder for this profile: its sign-in, settings and history live there. It follows the account; picking one by hand shows who is signed in there. New folder: ~/.claude-<name>, with the items below linked from another folder.", stacked: stacked) {
                folderPopup
            }
            if let c = checks(.folder).first(where: { $0.state == .bad || $0.state == .warn }) {
                SRowLine(text: c.text, color: c.state == .bad ? face.danger : face.caution)
            }
            if draft.source == .new { shareRows(stacked: stacked) }
        }
    }

    /// The account the folder is signed in to, or the one about to be: the label of the Account pop-up.
    private var accountShown: (text: String, tint: Color?, icon: String?) {
        let red = Color(nsColor: Painter.red), green = Color(nsColor: Painter.green)
        if let email = signedIn {
            if FolderRules.seatOwner(Account.signedInSeat(configDir: draft.configDir), among: model.accounts) != nil {
                return (email, red, "exclamationmark.triangle.fill")
            }
            if !draft.email.isEmpty, draft.email.lowercased() != email.lowercased() { return (email, FaceTheme.ledAmber, "exclamationmark.triangle.fill") }
            return (email, green, nil)
        }
        if draft.source == .existing, let dir = draft.existingDir {
            if case .claudeCode(let e?) = FolderKind.of(dir) { return (e, nil, nil) }
            return ("not signed in yet", nil, nil)
        }
        if !draft.email.isEmpty { return (draft.email, nil, nil) }
        return ("Choose an account", nil, nil)
    }

    /// Accounts signed in in Claude Code folders on this Mac that no profile uses, with their folder.
    private var freeAccounts: [(email: String, path: String)] { NewAccountSetup.freeAccounts(among: model.accounts) }

    /// Sign in was pressed and the folder doesn't name a new account yet.
    private var waiting: Bool { NewAccountSetup.waiting(draft) }

    /// The folder was made by this setup, so signing in there again (another address) is allowed; a folder that
    /// existed before is never signed in again from here.
    private var canSignInAgain: Bool { draft.createdConfigDir != nil && draft.source == .new }

    /// The Account menu's free accounts: "address   in folder", and whether it's the one picked.
    private var freeAccountLines: [(title: String, path: String, picked: Bool)] {
        freeAccounts.map { a in
            let picked = draft.source == .existing && (draft.existingDir.map { FolderKey.canonical($0) == FolderKey.canonical(a.path) } ?? false)
            return (Privacy.masked(a.email) + "   in " + a.path, a.path, picked)
        }
    }

    /// The Account menu's other profiles' accounts, dimmed: "address   Plan · Name's".
    private var otherAccountLines: [String] {
        var out: [String] = []
        for o in model.accounts {
            guard let e = o.seat?.email ?? Account.expectedEmail(configDir: o.configDir) else { continue }
            var detail: [String] = []
            if let plan = Store.status(o.id)?.plan { detail.append(Account.planWords(plan)) }
            detail.append(o.name + "'s")
            out.append(Privacy.masked(e) + "   " + detail.joined(separator: " · "))
        }
        return out
    }

    private func pickFreeAccount(_ path: String) {
        draft.source = .existing; draft.existingDir = path; draft.email = ""; draft.asking = false
    }

    @ViewBuilder private var accountValue: some View {
        if draft.asking {
            AddressRow(email: $draft.email, canSignIn: model.claudePath != nil,
                       signIn: startAddressSignIn, cancel: { draft.asking = false; addressProblem = nil })
                .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
        } else if waiting {
            HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    LED(color: FaceTheme.ledAmber, lit: Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0)
                }
                Text("signing in…").font(.system(size: 12)).foregroundStyle(face.caution).lineLimit(1)
                Spacer(minLength: 6)
                Button("Cancel") { draft.signInAsked = nil; draft.seatAtAsk = nil }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
            }
            .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
        } else {
            let shown = accountShown
            let free = freeAccountLines
            let others = otherAccountLines
            Menu {
                // once a folder is made or connected, the account comes with it: only signing in again in the
                // folder this setup made is left
                ForEach(free, id: \.path) { a in
                    if a.picked {
                        Toggle(a.title, isOn: .constant(true))
                    } else {
                        Button(a.title) { pickFreeAccount(a.path) }.disabled(draft.started)
                    }
                }
                ForEach(others, id: \.self) { line in Button(line) {}.disabled(true) }
                Divider()
                Button("Sign in to another account…") { askAddress() }
                    .disabled(model.claudePath == nil)
            } label: {
                MenuWell(text: shown.text, tint: shown.tint, icon: shown.icon, fill: true).settingsEmail(shown.text.contains("@"))
            }
            .faceMenuFill()
            .disabled(draft.started && !canSignInAgain)
            .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
        }
    }

    /// One grey line under Account: what the choice does, or what's happening.
    @ViewBuilder private var accountLine: some View {
        let text: (String, Color?)? = {
            if draft.asking {
                if let p = addressProblem { return (p, face.danger) }
                if let dir = NewAccountSetup.freeFolder(for: draft.email, among: model.accounts), !draft.started {
                    return ("\(Privacy.masked(draft.email)) is signed in in \(dir) already: pick it in the pop-up to use that folder as it is.", nil)
                }
                return ("Signs in through Claude Code in Terminal, in \(draft.started ? draft.configDir : "a new folder"). The browser's claude.ai account decides: switch it there first if it shows another one.", nil)
            }
            if waiting {
                return ("Finish signing in as \(Privacy.masked(draft.email)) in the browser. If it shows another claude.ai account, switch it there first.", nil)
            }
            if let email = signedIn {
                if let owner = FolderRules.seatOwner(Account.signedInSeat(configDir: draft.configDir), among: model.accounts) {
                    return ("\(Privacy.masked(email)) is the account of “\(owner.name)”. One profile per account: Sign in to another account… in the pop-up.", face.danger)
                }
                if !draft.email.isEmpty, draft.email.lowercased() != email.lowercased() {
                    return ("Signed in as \(Privacy.masked(email)), not \(Privacy.masked(draft.email)): the browser's claude.ai account decided. Keep it, or sign in again from the pop-up after switching the browser.", face.caution)
                }
                return nil
            }
            if draft.source == .existing, let dir = draft.existingDir { return ("Connects \(dir) as it is: its sign-in, settings and history stay.", nil) }
            if freeAccounts.isEmpty { return ("No free Claude Code folder is signed in on this Mac: Sign in to another account… in the pop-up.", nil) }
            return nil
        }()
        if let text { SRowLine(text: text.0, color: text.1) }
    }

    /// The Folder pop-up: a new folder, or one on this Mac with who is signed in there (other profiles' dimmed).
    private var folderPopup: some View {
        Menu {
            if draft.source == .new {
                Toggle("New folder   \(draft.newConfigDir)", isOn: .constant(true))
            } else {
                Button("New folder   \(draft.newConfigDir)") { draft.source = .new; draft.existingDir = nil }
            }
            ForEach(folderChoices, id: \.self) { p in
                if let owner = FolderRules.configOwner(p, among: model.accounts) {
                    Button("\(p)   \(owner.name)'s") {}.disabled(true)
                } else if isSelected(p) {
                    Toggle("\(p)   \(folderWho(p))", isOn: .constant(true))
                } else {
                    Button("\(p)   \(folderWho(p))") { draft.source = .existing; draft.existingDir = p; draft.email = ""; draft.asking = false }
                        .disabled(!canTake(p))
                }
            }
            Divider()
            Button("Choose another folder…") {
                if let p = pickFolder() {
                    if !folderChoices.contains(where: { FolderKey.canonical($0) == FolderKey.canonical(p) }) { customFolders.append(p) }
                    draft.source = .existing; draft.email = ""; draft.asking = false
                    draft.existingDir = folderChoices.first { FolderKey.canonical($0) == FolderKey.canonical(p) } ?? p
                }
            }
        } label: {
            MenuWell(text: draft.source == .new ? "New folder \(draft.newConfigDir)" : draft.existingDir ?? "Choose…", mono: true, fill: true)
        }
        .faceMenuFill()
        .disabled(draft.started)
    }

    /// Who is signed in in a folder, for the Folder pop-up.
    private func folderWho(_ p: String) -> String {
        switch FolderKind.of(p) {
        case .claudeCode(let e): return e.map { Privacy.masked($0) } ?? "not signed in"
        case .empty: return "empty"
        case .missing: return "doesn't exist"
        case .other: return "not a Claude Code folder"
        }
    }

    /// Sign in (the address route): the new folder is made if it isn't yet, then Terminal runs Claude Code's sign-in
    /// for it with the address filled in. The result is checked afterwards, by account and organisation ids.
    private func startAddressSignIn() {
        if let p = NewAccountSetup.addressProblem(draft.email, among: model.accounts) { addressProblem = p; return }
        let e = draft.email.trimmingCharacters(in: .whitespaces)
        // a folder connected as it was is never signed in again from here; the folder this setup made can be
        guard !draft.started || canSignInAgain else { addressProblem = "This profile uses \(draft.configDir) as it is. Cancel the setup to sign in to another account."; return }
        draft.email = e; draft.source = .new; draft.existingDir = nil
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { addressProblem = "Name the profile first."; return }
        if !NewAccountSetup.foldersReady(draft) {
            if running { addressProblem = "Quit the desktop app first (step 1)."; return }
            if blocked { addressProblem = "Fix the red lines first."; return }
            do { try NewAccountSetup.createOrConnect(&draft) } catch { addressProblem = error.localizedDescription; return }
        }
        guard let claude = model.claudePath, ClaudeCLI.openLogin(claude, account: Account(draft.entry), email: e) else {
            addressProblem = "Terminal didn't open."; return
        }
        draft.seatAtAsk = Account.signedInSeat(configDir: draft.configDir)     // signing in again waits for another account
        draft.asking = false; draft.signInAsked = Date(); addressProblem = nil; model.tick += 1
    }

    /// "Sign in to another account…": the one-line address row, in place of the pop-up. Before any folder is made it
    /// means a new folder; afterwards only the folder this setup made is signed in again.
    private func askAddress() {
        if !draft.started { draft.source = .new; draft.existingDir = nil }
        draft.asking = true; addressProblem = nil          // the address typed before stays: often the same one, again
    }

    /// A new folder only: which folder to link items from (a pop-up), and which items (keys under the label).
    @ViewBuilder private func shareRows(stacked: Bool) -> some View {
        let done = NewAccountSetup.foldersReady(draft)
        SRow(label: "Share from", info: "The Claude Code folder the items below are linked from, so edits there show up in this profile too. Sign-in, plugins and usage stay separate.", stacked: stacked) {
            Menu {
                Picker("", selection: $draft.shareFrom) {
                    ForEach(shareSources, id: \.self) { p in
                        let owner = model.accounts.first { FolderKey.canonical($0.configDir) == FolderKey.canonical(p) }
                        Text(p + (owner.map { "   \($0.name)'s" } ?? "")).tag(p)
                    }
                }
                .pickerStyle(.inline).labelsHidden()
            } label: { MenuWell(text: draft.shareFrom, mono: true, fill: true) }
            .faceMenuFill()
            .disabled(done)
            .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
        }
        SRow(label: "Shared", info: "Linked into the new folder from the folder above. Lit keys are shared; the rest start empty in the new folder.", stacked: true) {
            WrapChips(items: SharedItem.allCases.map { ($0.title, draft.share.contains($0)) }, tint: tint) { i in
                let item = SharedItem.allCases[i]
                if draft.share.contains(item) { draft.share.remove(item) } else { draft.share.insert(item) }
            }
            .disabled(done)
        }
    }


    /// Medium and narrow layouts show the sign-in as a card (wide shows it in step 3).
    private var signInCard: some View {
        SCard(title: "Sign in") { signInParts }
    }

    /// The two parts of signing in: a · Claude Code (Terminal), b · the desktop app (its own window).
    private var signInParts: some View {
        let owner = signedIn.flatMap { _ in FolderRules.seatOwner(Account.signedInSeat(configDir: draft.configDir), among: model.accounts) }
        return VStack(spacing: 1) {
            part(signedIn == nil ? (current == 3 ? .now : .todo) : owner != nil ? .warn : .done, current: current == 3,
                 title: "a · Claude Code") {
                if waiting {
                    sub("Waiting for \(Privacy.masked(draft.email.isEmpty ? "the sign-in" : draft.email)) in the browser")
                } else if let email = signedIn {
                    if let o = owner {
                        Text("\(Privacy.masked(email)) is “\(o.name)”'s account: one profile per account")
                            .font(.system(size: 11.5)).foregroundStyle(face.danger).fixedSize(horizontal: false, vertical: true)
                        if canSignInAgain {
                            // signing in again in the folder this setup made replaces its sign-in; no sign-out first
                            Button("Sign in to another account…") { askAddress() }
                                .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize().padding(.top, 3)
                        }
                    } else {
                        sub(Privacy.masked(email) + (draft.source == .existing && !draft.started ? ", already in the folder" : ""))
                    }
                } else {
                    sub(draft.email.isEmpty ? "Terminal opens; approve in the browser"
                        : "Terminal opens with \(Privacy.masked(draft.email)) filled in; approve in the browser, switching its claude.ai account there first if it shows another one")
                }
            }
            if !draft.claudeWindow {
                part(.todo, current: false, title: "b · Claude window", droppedOut: true) { sub("Only when the profile has a Claude window") }
            } else if needsDesktop {
                let state: StepState = signedIn == nil ? .todo : desktopDone ? .done : desktop == .different ? .warn : current == 4 ? .now : .todo
                part(state, current: current == 4, title: draft.window == .standard ? "b · Claude window (the usual Claude app)" : "b · Claude window") {
                    // one status line: its own sign-in, checked against Claude Code's by account id
                    if signedIn == nil {
                        sub("After Claude Code")
                    } else {
                        switch desktop {
                        case .same: Text("Signed in to the same account").font(.system(size: 11.5)).foregroundStyle(face.ok)
                            .fixedSize(horizontal: false, vertical: true)
                        case .unknown: sub("Signed in")
                        case .different:
                            Text("Signed in to another account: in that window, Settings ▸ Log out, then sign in as \(Privacy.masked(signedIn ?? ""))")
                                .font(.system(size: 11.5)).foregroundStyle(face.caution).fixedSize(horizontal: false, vertical: true)
                        default:
                            HStack(spacing: 5) {
                                if windowOpen { ProgressView().controlSize(.mini) }
                                sub("Sign in to it as \(Privacy.masked(signedIn ?? "")): the window has its own sign-in")
                            }
                        }
                    }
                    // the one grey line: Code session records stay in the data folder they were made in
                    Text(sidebarWords).font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .faceWindow(radius: 6)
    }

    /// "Its Code sidebar starts empty: …" with the how-to link (the one used after linking a profile to another account).
    private var sidebarWords: AttributedString {
        var a = AttributedString(draft.window == .standard
            ? "Its Code sidebar shows this account's Code sessions only; earlier ones stay with the account they were made under ("
            : "Its Code sidebar starts empty: Code sessions stay in the window they were made in (")
        var link = AttributedString("how-to")
        link.link = URL(string: "https://github.com/n-uf/cl_audit#moving-a-profile-to-another-account")
        a += link + AttributedString(").")
        return a
    }

    private func sub(_ s: String) -> some View {
        Text(s).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func part<C: View>(_ state: StepState, current: Bool, title: String, droppedOut: Bool = false, @ViewBuilder content: () -> C) -> some View {
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
                    .strikethrough(droppedOut)
                content()
            }
            Spacer(minLength: 0)
        }
        .opacity(droppedOut ? 0.45 : 1)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(current ? 0.08 : 0.03))
    }

    // MARK: steps (wide)

    private var stepsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {

            let ready = NewAccountSetup.foldersReady(draft)
            let n = quitStep ? 0 : -1           // without a Claude window there's no "Quit the desktop app" step
            if quitStep {
                stepRow(1, state: ready ? .done : monitor.checked ? (appRuns.isEmpty ? .done : draft.continueAnyway ? .warn : .bad) : .todo,
                        title: "Quit the desktop app",
                        detail: ready ? "done · it can stay open now" : !monitor.checked ? "checking…" : appRuns.isEmpty ? "closed" : nil,
                        connector: running) {
                    if running { warningBox }
                }
            }
            stepRow(2 + n, state: folders ? .done : current == 2 ? .now : running ? .held : .todo,
                    title: draft.source == .new ? "Create the folder" + (draft.share.isEmpty ? "" : " and links") : "Connect the folder",
                    detail: folders ? draft.configDir : running ? "held until the desktop app is quit" : checks.contains(where: { $0.blocks && $0.section != .running }) ? "fix the red lines first" : nil,
                    detailBad: running && !folders) { EmptyView() }
            stepRow(3 + n, state: !folders ? .todo
                        : (signedIn.flatMap { _ in FolderRules.seatOwner(Account.signedInSeat(configDir: draft.configDir), among: model.accounts) } != nil || (needsDesktop && signedIn != nil && desktop == .different)) ? .warn
                        : current == 3 || current == 4 ? .now : .done,
                    title: "Sign in",
                    detail: folders ? nil : needsDesktop ? "Claude Code, then the Claude window" : "Claude Code") {
                if folders { signInParts.padding(.top, 3) }
            }
            stepRow(4 + n, state: current == 5 ? .now : .todo, title: finishStep,
                    detail: draft.usageInDock ? "Finish installs “cl_audit \(draft.name.isEmpty ? "…" : draft.name)” and puts it in the Dock"
                                              : "cl_audit reads its usage from now on; nothing is installed and the Dock isn't touched") { EmptyView() }

            actionBar(hint: false).padding(.top, 8)
        }
        .padding(14)
        .background(RaisedShape(finish: face.module, radius: face.moduleRadius))
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
        let items: [(String, Bool, Int)] = (quitStep ? [("Quit desktop app", ready || (monitor.checked && appRuns.isEmpty), 1)] : [])
                                            + [(draft.source == .new ? "Create folder" : "Connect folder", folders, 2),
                                            ("Claude Code", signedIn != nil, 3)]
            + (needsDesktop ? [("Claude window", signedIn != nil && desktopDone, 4)] : []) + [(draft.usageInDock ? "Dock icon" : "Read usage", false, 5)]
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
                .buttonStyle(.primaryKey(compact: true)).disabled(blocked || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            } else if current == 5 {
                Button(draft.usageInDock ? "Finish" : "Start reading usage") { model.finishNew() }.buttonStyle(.primaryKey(compact: true)).disabled(blocked || model.discarding)
            } else {
                Button(desktop == .different ? "Finish anyway" : "Finish now") { model.finishNew() }
                    .buttonStyle(PillButtonStyle(tint: nil, compact: true)).disabled(blocked || model.discarding)
                    .help("Sign-in can be finished later from Settings")
                if signedIn == nil {
                    Button("Sign in to Claude Code…") {
                        if let c = model.claudePath { ClaudeCLI.openLogin(c, account: Account(draft.entry), email: draft.email.isEmpty ? nil : draft.email) }
                    }
                        .buttonStyle(.pill(tint, compact: true)).disabled(model.claudePath == nil)
                } else if draft.claudeWindow {
                    Button(windowOpen ? "Show Claude window" : "Open Claude window") { Launcher.openClaude(Account(draft.entry)) }
                        .buttonStyle(.pill(tint, compact: true))
                }
            }
        }
        .padding(.horizontal, hint ? 16 : 0).padding(.vertical, hint ? 10 : 0)
        .background(hint ? Color.black(face.light ? 0.03 : 0.12) : Color.clear)
        .overlay(alignment: .top) { if hint { EngravedRule() } }
    }

    private var nextHint: String {
        switch current {
        case 1: return monitor.checked ? "Next: quit the desktop app" : "Checking the desktop app…"
        case 2: return draft.name.isEmpty ? "Next: name the profile" : draft.source == .existing && draft.existingDir == nil ? "Next: pick a folder" : blocked ? "Fix the red lines to go on" : draft.source == .new ? "Next: create the folder and links" : "Next: connect the folder"
        case 3: return "Next: sign in to Claude Code"
        case 4: return desktop == .different ? "Its Claude window uses another account" : "Next: sign in to the Claude window"
        default: return draft.usageInDock ? "Next: add the Dock icon" : "Next: start reading usage"
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
    @Environment(\.face) private var face

    var body: some View {
        let title = HStack(spacing: 5) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(face.soft)
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
    @Environment(\.face) private var face

    /// A track like PillPicker's; an option that can't be chosen is printed struck through.
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                let off = disabled.contains(o), on = o == selection
                Button { selection = o } label: {
                    Text(title(o)).font(.system(size: 9.5, weight: .semibold)).tracking(1).textCase(.uppercase)
                        .strikethrough(off)
                        .foregroundStyle(on ? face.legend : face.trackLegend.opacity(off ? 0.5 : 1))
                        .shadow(color: on ? face.legendShadow : .clear, radius: 0, y: face.legendShadowY)
                        .padding(.horizontal, 10).frame(height: 22)
                        .background { if on { RaisedShape(finish: face.key, radius: 3) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(off)
            }
        }
        .padding(3)
        .background(WellShape(well: face.track, radius: 5))
        .fixedSize()
    }
}

/// Toggle chips that wrap onto more lines when narrow.
struct WrapChips: View {
    let items: [(String, Bool)]
    var tint: Color = .accentPill
    let toggle: (Int) -> Void

    /// Keys: a chosen one is latched down with its orange strip lit (no ticks, no frames).
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                Button { toggle(i) } label: {
                    KeyLook(latched: items[i].1, height: 22, hPad: 10) { Text(items[i].0) }
                }
                .buttonStyle(PressableKey())
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
