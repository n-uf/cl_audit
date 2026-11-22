// Adding a Claude account: one page in Settings. The account lives in a new Claude Code folder or in one
// that already exists (the default ~/.claude too); a folder and a desktop window can belong to only one
// account, which the Checks card verifies live. A banner lists every desktop app window and its Code tab sessions
// open: the steps that write folders wait until it's quit (Claude Code in Terminal doesn't matter).
// The Claude Code card leads with the account: one signed in in a folder no profile uses (connecting that folder), or
// "Sign in to another account…" with the address filled in, in a new folder. Folders stay where they are.
// Steps: quit the desktop app → create or connect the folder → sign in (Claude Code, then the Claude window) → add the Dock icon.

import AddressPrivacy
import AppKit
import ProfileCore
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
    /// How the last sign-in window ended, until the next Sign in (SignInWindow): its line under Account. A signed-in or
    /// wrong-account end says nothing here (the folder's own account tells, below), and an unconfirmed one is never
    /// taken for a sign-in (`unconfirmed`).
    var signInSaid: SignInSaid?
    var unconfirmed: Bool { signInSaid?.kind == .unverified }
    /// The sign-in window is open and followed (SignInWindow): "signing in…" until it ends, whatever the folder's record
    /// says meanwhile (a record that names an account is not yet a confirmed sign-in).
    var signInRunning = false
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
    /// The usual Claude app is a profile's already (set when the draft starts): the new profile then gets its own window.
    var standardTaken = false
    /// The window the new profile gets, decided here once and stored in its entry (`entry.desktop`): the usual Claude app
    /// for ~/.claude while no profile has it, its own window otherwise. Never worked out from a folder again afterwards.
    var window: DesktopMode { .forNew(configDir: configDir, standardTaken: standardTaken) }
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
    /// A red line blocks Create/Connect and Finish; so does the desktop-app check while it hasn't been made yet
    /// ("Checking…"): which Claude runs is never taken for "none" before it has been read.
    var blocks: Bool { state == .bad || section == .running && state == .wait }
}

/// What has been done so far, read from disk each time (so it stays right if things happen elsewhere).
enum NewAccountSetup {
    static func shared(_ d: NewAccountDraft) -> URL { URL(fileURLWithPath: expand(d.shareFrom)) }

    /// The address the Account pop-up's label holds, when it holds one (or an account id): the label draws it through
    /// AddressPrivacy (one fixed blurred stand-in while emails are hidden, the address itself while the pointer is on it),
    /// never the address under a blur or a mask of it. Its other words ("Choose an account", "not signed in yet") are plain.
    static func wellAddress(_ text: String) -> String? { AddressSettings.hides(text) ? text : nil }

    static func exists(_ path: String) -> Bool { !path.isEmpty && FileManager.default.fileExists(atPath: expand(path)) }

    /// The Claude Code folder is in place (created, or an existing one connected) and so is the window's data folder,
    /// which only a profile with a Claude window gets (createOrConnect makes it only then).
    static func foldersReady(_ d: NewAccountDraft) -> Bool {
        let config = d.source == .existing ? d.connected : exists(d.configDir)
        return config && (d.window != .separate || !d.claudeWindow || exists(d.dataDir))
    }

    /// The line under a switch that is locked once the folder is made (Name and Folder lock the same way).
    static func lockedNote(_ d: NewAccountDraft) -> String {
        d.createdConfigDir != nil || d.createdDataDir != nil
            ? "Set when the folder was made. Cancel and clean up starts over."
            : "Set when the folder was connected. Cancel setup starts over."
    }

    /// Why Create/Connect can't go on when it ran and the folders still aren't ready, or nil when they are: said, never silent.
    static func notReadyWhy(_ d: NewAccountDraft) -> String? {
        guard !foldersReady(d) else { return nil }
        var missing: [String] = []
        if d.source == .existing ? !d.connected : !exists(d.configDir) { missing.append(d.configDir) }
        if d.window == .separate, d.claudeWindow, !exists(d.dataDir) { missing.append(d.dataDir) }
        return "The folder isn't ready yet: " + (missing.isEmpty ? "something is missing" : missing.joined(separator: " and ") + (missing.count > 1 ? " aren't there" : " isn't there")) + ". Cancel and start over."
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

    /// Why Sign in (the address route) can't go with this address, or nil: only an address that isn't one. Another
    /// profile's account is no problem (shared seats): `addressNote` says so.
    static func addressProblem(_ email: String) -> String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard e.contains("@"), !e.hasPrefix("@"), !e.hasSuffix("@"), !e.contains(" ") else { return "Type the account's email address." }
        return nil
    }

    /// The amber note for an address typed that another profile has, in use or standing by (FolderRules.sharedNote), or nil.
    /// The address only fills in the sign-in, so this is the early, by-address part; afterwards the account and organisation
    /// ids decide (`signInNote`).
    static func addressNote(_ email: String, among accounts: [AccountEntry],
                            signedIn: (String) -> Seat? = Account.signedInSeat) -> String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard addressProblem(e) == nil else { return nil }
        let typed = AccountIdentity(account: nil, email: e, organization: nil, source: .guessed)
        return FolderRules.sharedNote(FolderRules.seatSharers(typed, among: accounts, signedIn: signedIn))
    }

    /// The amber note for the account the draft's folder is signed in to, when another profile has it too, or nil.
    static func signInNote(_ d: NewAccountDraft, among accounts: [AccountEntry],
                           signedIn: (String) -> Seat? = Account.signedInSeat) -> String? {
        guard signedInEmail(d) != nil else { return nil }
        return FolderRules.sharedNote(FolderRules.seatSharers(signedIn(d.configDir), among: accounts, signedIn: signedIn))
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

    /// Who is signed in in a folder, for the Folder pop-ups (New profile and Settings ▸ a profile ▸ Claude Code).
    static func folderWho(_ p: String) -> String {
        switch FolderKind.of(p) {
        case .claudeCode(let e): return e.map { AddressSettings.words($0) } ?? "not signed in"
        case .empty: return "empty"
        case .missing: return "doesn't exist"
        case .other: return "not a Claude Code folder"
        }
    }

    /// What a Claude Code folder has of the items New profile can link: linked from another folder (which one), its own,
    /// or not there. Read only: it looks at the links and changes nothing.
    enum SharedState: Equatable { case linked(from: String), own, missing }

    static func sharedItems(in configDir: String) -> [(item: SharedItem, state: SharedState)] {
        let dir = expand(configDir), fm = FileManager.default
        return SharedItem.allCases.map { item in
            let p = (dir as NSString).appendingPathComponent(item.rawValue)
            if let dest = try? fm.destinationOfSymbolicLink(atPath: p) {
                let target = dest.hasPrefix("/") ? dest : ((dir as NSString).appendingPathComponent(dest) as NSString).standardizingPath
                return (item, .linked(from: tilde((target as NSString).deletingLastPathComponent)))
            }
            return (item, fm.fileExists(atPath: p) ? .own : .missing)
        }
    }

    /// The red line while which Claude runs couldn't be checked.
    static let failedWords = RunsMonitor.failedWords + ", so the folder isn't set up yet"

    /// What keeps Create/Connect (and the address sign-in's folder) from going on a look made at the click, or nil: the
    /// desktop-app line when it blocks. `runs` nil: which Claude runs couldn't be checked.
    static func runsBlock(_ d: NewAccountDraft, accounts: [AccountEntry], runs: [ClaudeRun]?) -> String? {
        checks(d, accounts: accounts, runs: (runs ?? []).filter { $0.kind != .terminal }, checked: runs != nil, failed: runs == nil)
            .first { $0.section == .running && $0.blocks }?.text
    }

    /// Everything the Checks card shows, in order. Any `.bad` line blocks Create/Connect and Finish. `failed`: which Claude runs couldn't be checked (RunsMonitor.failed): a red line, never "the desktop app is closed".
    static func checks(_ d: NewAccountDraft, accounts: [AccountEntry], runs: [ClaudeRun], checked: Bool, failed: Bool = false) -> [SetupCheck] {
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

        // the sign-in: the account (account and organisation ids, from the folder's .claude.json) may be another profile's
        // too (shared seats): an amber note, never a block; the address typed only filled in the sign-in, so another one is
        // said, not refused
        if let email = signedInEmail(d) {
            if !d.email.isEmpty, d.email.lowercased() != email.lowercased() {
                out.append(.init(section: .signIn, state: .warn, text: "Signed in as \(AddressSettings.words(email)), not \(AddressSettings.words(d.email)): the browser's claude.ai account decided"))
            } else {
                out.append(.init(section: .signIn, state: .ok, text: "Signed in as \(AddressSettings.words(email))"))
            }
            if let note = signInNote(d, among: accounts) { out.append(.init(section: .signIn, state: .warn, text: note)) }
        }

        // The desktop app open: it writes sign-in and settings, which matters only until the folders exist, and only
        // for a profile with a Claude window. Without one the only new folder is the Claude Code folder, which the
        // desktop app never writes (its Code tab uses ~/.claude, sign-in runs in Terminal, shared items are links).
        // Claude Code in Terminal doesn't get in the way.
        let appRuns = runs.filter { $0.kind != .terminal }
        if foldersReady(d) || !d.claudeWindow { return out }
        if failed { out.append(.init(section: .running, state: .bad, text: failedWords)) }
        else if !checked { out.append(.init(section: .running, state: .wait, text: "Checking whether the desktop app is open…")) }
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
        if d.createdConfigDir != nil, let e = signedInEmail(d) { parts.append("signs out the Claude Code sign-in (\(AddressSettings.words(e)))") }
        if let a = ownWindow(d), ClaudeWindow.isOpen(a) { parts.append("quits its Claude window") }
        let dirs = [d.createdConfigDir, d.createdDataDir.map { _ in "its desktop data folder" }].compactMap { $0 }
        if !dirs.isEmpty { parts.append("deletes " + dirs.joined(separator: " and ")) }
        let first = parts.joined(separator: ", ")
        let kept = d.source == .existing ? " \(d.configDir) is left as it is." : " Nothing in ~/.claude is touched."
        return first.prefix(1).uppercased() + first.dropFirst() + "." + kept
    }

    /// Undoes what this setup created: the window it opened, the login it made, the folders it created. Folders that existed
    /// before are left alone. False, with nothing changed, when its window didn't quit in time (it may be asking about work
    /// under way): its folders are never deleted under it, and Cancel can be pressed again. Blocks; call off the main thread.
    @discardableResult
    static func discard(_ d: NewAccountDraft, claude: String?) -> Bool {
        let fm = FileManager.default
        // the window started on the window folder this setup made quits first, confirmed by identity (pid and start time);
        // never another window (ownWindow)
        if let a = ownWindow(d), !ClaudeWindow.quitAndWait(a, seconds: discardWait) { return false }
        // Never the default folder: ~/.claude's sign-in (Claude Code's own "Claude Code-credentials", which the usual Claude
        // app and `claude` in Terminal use) and its folder are never this draft's to sign out or delete, whatever it recorded.
        let ownConfig = d.createdConfigDir.flatMap { Account.isDefault(configDir: $0) ? nil : $0 }
        if let dir = ownConfig, let claude, signedInEmail(d) != nil { ClaudeCLI.logout(claude, configDir: dir) }
        // opened again meanwhile (the sign-out takes a moment): its folders stay; Cancel again quits it
        if let a = ownWindow(d), ClaudeWindow.isOpen(a) { return false }
        if let dir = ownConfig {
            try? fm.removeItem(at: URL(fileURLWithPath: expand(dir)))      // removes the links, not what they point to
            try? fm.removeItem(at: ClaudeCLI.loginScript(dir))
        }
        if let dir = d.createdDataDir { try? fm.removeItem(at: URL(fileURLWithPath: expand(dir))) }
        return true
    }
    /// How long Cancel waits for the window to quit (a check's seam).
    nonisolated(unsafe) static var discardWait: TimeInterval = 4
    static let windowKept = "The window didn't quit; its folders are kept. Quit it, then Cancel again."

    /// The window Cancel quits: the one started on the window folder this setup made (by that folder, whatever the draft's name
    /// says now), or none. Never the usual Claude window (the standard data folder), which a new profile never owns here.
    static func ownWindow(_ d: NewAccountDraft) -> Account? {
        guard let dir = d.createdDataDir, !dir.isEmpty,
              FolderKey.canonical(expand(dir)) != FolderKey.canonical(expand(FolderKey.standardDataDir)) else { return nil }
        var e = d.entry
        e.desktop = .separate; e.desktopDataDir = dir
        return Account(e)
    }

    /// Whether this account's own Claude window is signed in, and to the same claude.ai account as Claude Code.
    enum DesktopSignIn { case notChecked, notSignedIn, same, different, unknown }

    /// Reads the window's config.json (AppSignIn.storedSignIn) only for whether a login is stored and which account it last
    /// used (an account id, not the organisation); nothing from it is kept or shown. The usual Claude app is checked too.
    static func desktopSignIn(_ d: NewAccountDraft) -> DesktopSignIn {
        guard d.claudeWindow, foldersReady(d) else { return .notChecked }
        switch AppSignIn.storedSignIn(dataDir: expand(d.dataDir)) {
        case .none: return .notSignedIn
        case .unknown: return .unknown
        case .account(let desktop):
            guard let code = Account.expectedAccountUuid(configDir: d.configDir) else { return .unknown }
            return desktop == code.lowercased() ? .same : .different
        }
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
    @ObservedObject private var privacy = AddressPrivacy.shared
    @State private var error: String?
    @State private var confirmCancel = false
    @State private var confirmQuit = false
    @State private var customFolders: [String] = []
    @State private var checking = false
    @StateObject private var gate = ClickGate()         // the click-time look before a folder is made; Cancel and leaving call it off
    @State private var addressProblem: String?      // why Sign in (the address route) can't go yet
    @Environment(\.face) private var face

    /// The page's columns for a width: three (who it is and its parts · Claude Code · steps), two (every card · steps) or
    /// one (the cards, then the steps, with the next action pinned at the bottom). A column is never narrower than
    /// `column`, so nothing runs off the window or gets cut; a card narrower than `rowsFit` stacks its rows (the label
    /// on its own line, the control the card's full width under it), so addresses and paths show whole.
    struct Columns: Equatable { let count: Int; let widths: [CGFloat] }
    static let column: CGFloat = 340
    static let rowsFit = SRow<EmptyView>.stackBelow   // Claude Code's rows side by side from here (Settings uses it too)
    static let smallRowsFit: CGFloat = 330     // the small cards' rows (a name, swatches, a switch) fit down to here
    static let pad: CGFloat = 16, gap: CGFloat = 12

    static func columns(for w: CGFloat) -> Columns {
        let avail = w - 2 * pad
        if avail - 2 * gap >= 3 * column {
            let a = avail - 2 * gap
            let steps = min(400, max(column, a * 0.3))
            let rest = a - steps
            let first = max(column, min(380, rest * 0.42))
            return Columns(count: 3, widths: [first, rest - first, steps])
        }
        if avail - gap >= 2 * column {
            let a = avail - gap
            let steps = min(400, max(column, a * 0.42))
            return Columns(count: 2, widths: [a - steps, steps])
        }
        return Columns(count: 1, widths: [max(0, min(700, w - 28))])
    }

    var body: some View {
        let _ = model.tick                                // re-check the steps every few seconds
        GeometryReader { geo in
            let w = geo.size.width
            let c = Self.columns(for: w)
            Group {
                if c.count == 3 { three(c, w) } else if c.count == 2 { two(c, w) } else { one(c) }
            }
        }
        .onAppear { monitor.start(folders: model.accounts.map(\.configDir)) }
        .onDisappear { gate.cancel(); monitor.stop() }
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
    private var checks: [SetupCheck] { NewAccountSetup.checks(draft, accounts: model.accounts, runs: appRuns, checked: monitor.checked, failed: monitor.failed) }
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
    /// Who Claude Code in the folder is signed in to; nobody while its last sign-in ended unconfirmed (the folder's record
    /// alone is a guess: Sign in again, or Refresh now in Settings once the profile is made).
    private var signedIn: String? { checks(.folder).contains { $0.blocks } || draft.unconfirmed ? nil : NewAccountSetup.signedInEmail(draft) }
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

    /// Three columns: who it is and each part in its own card (layout A, the part's switch first) · Claude Code · steps.
    private func three(_ c: Columns, _ w: CGFloat) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: Self.gap) {
                VStack(spacing: 10) {
                    profileCard(stacked: c.widths[0] < Self.smallRowsFit)
                    windowCard(stacked: c.widths[0] < Self.smallRowsFit)
                    dockCard(stacked: c.widths[0] < Self.smallRowsFit)
                }
                .frame(width: c.widths[0])
                folderCard(stacked: c.widths[1] < Self.rowsFit).frame(width: c.widths[1])
                stepsPanel(bar: true).frame(width: c.widths[2])
            }
            .frame(width: max(0, w - 2 * Self.pad), alignment: .topLeading)   // never wider than the window
            .padding(.horizontal, Self.pad).padding(.vertical, 14)
        }
    }

    /// Two columns: every card, Claude Code right after who it is · the steps.
    private func two(_ c: Columns, _ w: CGFloat) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: Self.gap) {
                VStack(spacing: 10) {
                    profileCard(stacked: c.widths[0] < Self.smallRowsFit)
                    folderCard(stacked: c.widths[0] < Self.rowsFit)
                    windowCard(stacked: c.widths[0] < Self.smallRowsFit)
                    dockCard(stacked: c.widths[0] < Self.smallRowsFit)
                }
                .frame(width: c.widths[0])
                stepsPanel(bar: true).frame(width: c.widths[1])
            }
            .frame(width: max(0, w - 2 * Self.pad), alignment: .topLeading)
            .padding(.horizontal, Self.pad).padding(.vertical, 14)
        }
    }

    /// One column: the cards, then the steps under them; the next action stays pinned at the bottom.
    private func one(_ c: Columns) -> some View {
        let cw = c.widths[0]
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    profileCard(stacked: cw < Self.smallRowsFit)
                    folderCard(stacked: cw < Self.rowsFit)
                    windowCard(stacked: cw < Self.smallRowsFit)
                    dockCard(stacked: cw < Self.smallRowsFit)
                    stepsPanel(bar: false)
                }
                .frame(maxWidth: 700)
                .padding(14)
                .frame(maxWidth: .infinity)
            }
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
            if draft.started { SRowLine(text: NewAccountSetup.lockedNote(draft)) }
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
            SRow(label: "Account", info: "The claude.ai account this profile is for. Accounts signed in in Claude Code folders on this Mac that no profile uses come with their folder. Another profile's account can be this profile's too, and both profiles then show the same numbers. Sign in to another account… opens Claude Code's own sign-in in Terminal with the address filled in; the browser's claude.ai account decides which account it is, checked afterwards by its account and organisation ids.", first: true, stacked: stacked) {
                accountValue
            }
            accountLine
            ClaudeMissingLine(model: model)           // Sign in needs Claude Code: say so when it isn't there
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
        let green = Color(nsColor: Painter.green)
        if let email = signedIn {
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
    private var waiting: Bool { draft.signInRunning || NewAccountSetup.waiting(draft) }

    /// The folder was made by this setup, so signing in there again (another address) is allowed; a folder that
    /// existed before is never signed in again from here.
    private var canSignInAgain: Bool { draft.createdConfigDir != nil && draft.source == .new }

    /// The Account menu's free accounts: "address   in folder", and whether it's the one picked.
    private var freeAccountLines: [(title: String, path: String, picked: Bool)] {
        freeAccounts.map { a in
            let picked = draft.source == .existing && (draft.existingDir.map { FolderKey.canonical($0) == FolderKey.canonical(a.path) } ?? false)
            return (AddressSettings.words(a.email) + "   in " + a.path, a.path, picked)
        }
    }

    /// The Account menu's other profiles' accounts, "address   Plan · Name's": each can be picked (shared seats), which signs
    /// in to it in this profile's own folder (another profile's folder is never shared) with its address filled in.
    private var otherAccountLines: [(title: String, email: String)] {
        var out: [(title: String, email: String)] = []
        for o in model.accounts {
            guard let e = o.seat?.email ?? Account.expectedEmail(configDir: o.configDir), !out.contains(where: { $0.email.lowercased() == e.lowercased() }) else { continue }
            var detail: [String] = []
            if let plan = Store.status(o.id)?.plan { detail.append(Account.planWords(plan)) }
            detail.append(o.name + "'s")
            out.append((AddressSettings.words(e) + "   " + detail.joined(separator: " · "), e))
        }
        return out
    }

    private func pickFreeAccount(_ path: String) {
        draft.source = .existing; draft.existingDir = path; draft.email = ""; draft.asking = false
    }

    /// Another profile's account picked: the address route with its address filled in (the note under it says it's shared).
    private func pickOtherAccount(_ email: String) {
        draft.email = email
        askAddress()
    }

    @ViewBuilder private var accountValue: some View {
        if draft.asking {
            AddressRow(email: $draft.email, canSignIn: true,        // never greyed: without Claude Code the click says why
                       signIn: { startAddressSignIn() }, cancel: { gate.cancel(); draft.asking = false; addressProblem = nil })
                .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
        } else if waiting {
            HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    LED(color: FaceTheme.ledAmber, lit: Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0)
                }
                Text("signing in…").font(.system(size: 12)).foregroundStyle(face.caution).lineLimit(1)
                Spacer(minLength: 6)
                Button("Cancel") { model.cancelNewSignIn() }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
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
                ForEach(others, id: \.email) { o in Button(o.title) { pickOtherAccount(o.email) }.disabled(draft.started && !canSignInAgain) }
                Divider()
                if model.claudeKnownMissing { Button(ClaudeInstall.missingInstall) { model.showInstallHelp() } }
                Button("Sign in to another account…") { askAddress() }
                    .disabled(model.claudeKnownMissing)      // greyed, with the line above saying why
            } label: {
                MenuWell(text: shown.text, tint: shown.tint, icon: shown.icon, fill: true, address: NewAccountSetup.wellAddress(shown.text))
            }
            .faceMenuFill()
            .disabled(draft.started && !canSignInAgain)
            .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
        }
    }

    /// One grey line under Account: what the choice does, or what's happening.
    @ViewBuilder private var accountLine: some View {
        let text: (String, Color?)? = {
            // how the last sign-in window ended, when the folder's own account doesn't say it (below): unconfirmed, declined,
            // failed, no sign-in in time, replaced by another sign-in
            if !draft.asking, !waiting, let s = draft.signInSaid, s.kind != .signedIn, s.kind != .wrongAccount {
                return (s.text, s.danger ? face.danger : face.caution)
            }
            if draft.asking {
                if let p = addressProblem { return (p, face.danger) }
                // another profile's account typed or picked: taken all the same, said once, amber
                if let note = NewAccountSetup.addressNote(draft.email, among: model.accounts) { return (note, face.caution) }
                if let dir = NewAccountSetup.freeFolder(for: draft.email, among: model.accounts), !draft.started {
                    return ("\(AddressSettings.words(draft.email)) is signed in in \(dir) already: pick it in the pop-up to use that folder as it is.", nil)
                }
                return ("Claude Code signs in through Terminal; the browser's claude.ai account decides.", nil)
            }
            if waiting {
                return ("Finish in the browser as \(AddressSettings.words(draft.email)); switch its claude.ai account first if needed.", nil)
            }
            // a free account picked: say what Connect does before it's done (its sign-in is already there)
            if draft.source == .existing, !draft.started, let dir = draft.existingDir,
               signedIn == nil || NewAccountSetup.signInNote(draft, among: model.accounts) == nil {
                return ("Connects \(dir) as it is: its sign-in, settings and history stay.", nil)
            }
            if let email = signedIn {
                // another profile's account too (shared seats): the one amber note, no address in it (the field shows it)
                if let note = NewAccountSetup.signInNote(draft, among: model.accounts) { return (note, face.caution) }
                if !draft.email.isEmpty, draft.email.lowercased() != email.lowercased() {
                    return ("Signed in as \(AddressSettings.words(email)), not \(AddressSettings.words(draft.email)): the browser's claude.ai account decided. Keep it, or sign in again from the pop-up after switching the browser.", face.caution)
                }
                return nil
            }
            if draft.source == .existing, let dir = draft.existingDir { return ("Connects \(dir) as it is: its sign-in, settings and history stay.", nil) }
            if freeAccounts.isEmpty { return ("No free folder here is signed in: Sign in to another account… in the pop-up.", nil) }
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
    private func folderWho(_ p: String) -> String { NewAccountSetup.folderWho(p) }

    /// Sign in (the address route): the new folder is made if it isn't yet, then Terminal runs Claude Code's sign-in
    /// for it with the address filled in. The result is checked afterwards, by account and organisation ids.
    /// `confirmed`: a look made at the click found nothing in the way (the folder is made only then).
    private func startAddressSignIn(confirmed: Bool = false) {
        guard !gate.busy else { return }
        if let p = NewAccountSetup.addressProblem(draft.email) { addressProblem = p; return }
        let e = draft.email.trimmingCharacters(in: .whitespaces)
        // a folder connected as it was is never signed in again from here; the folder this setup made can be
        guard !draft.started || canSignInAgain else { addressProblem = "This profile uses \(draft.configDir) as it is. Cancel the setup to sign in to another account."; return }
        draft.email = e; draft.source = .new; draft.existingDir = nil
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { addressProblem = "Name the profile first."; return }
        if !NewAccountSetup.foldersReady(draft) {
            if running { addressProblem = "Quit the desktop app first (step 1)."; return }
            if blocked { addressProblem = "Fix the red lines first."; return }
            guard confirmed else {
                // Cancel, the address row's cancel or leaving the page meanwhile drops the look: no folder is made
                gate.look(monitor) { fresh in
                    if let why = NewAccountSetup.runsBlock(draft, accounts: model.accounts, runs: fresh) { addressProblem = why; return }
                    startAddressSignIn(confirmed: true)
                }
                return
            }
            do { try NewAccountSetup.createOrConnect(&draft) } catch { addressProblem = PlainWords.why(error); return }
        }
        guard let claude = model.requireClaude() else { addressProblem = model.noClaudeWhy; return }
        // Claude Code's sign-in in Terminal with the address filled in, followed to its end (SignInWindow): the sign-in
        // window ending any other way than on an account says so under Account (a refused start included)
        addressProblem = nil
        model.startNewSignIn(claude, email: e)
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

    /// The two parts of signing in: a · Claude Code (Terminal), b · the desktop app (its own window).
    private var signInParts: some View {
        return VStack(spacing: 1) {
            part(signedIn == nil ? (current == 3 ? .now : .todo) : .done, current: current == 3,
                 title: "a · Claude Code") {
                if waiting {
                    sub("Waiting for \(AddressSettings.words(draft.email.isEmpty ? "the sign-in" : draft.email)) in the browser")
                } else if let email = signedIn {
                    // the address in the drawn form (the stand-in while Show emails is off, never "hidden address" or real
                    // text under a blur), as the Account field shows it; then the shared note, amber, with no address in it
                    HStack(spacing: 0) {
                        AccountValue(text: email, size: 11.5, reserve: false)
                        if draft.source == .existing && !draft.started { Text(", already in the folder") }
                    }
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let note = NewAccountSetup.signInNote(draft, among: model.accounts) {
                        Text(note).font(.system(size: 11.5)).foregroundStyle(face.caution).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    sub(draft.email.isEmpty ? "Terminal opens; approve in the browser"
                        : "Terminal opens with \(AddressSettings.words(draft.email)) filled in; approve in the browser, switching its claude.ai account there first if it shows another one")
                }
            }
            if !draft.claudeWindow {
                part(.todo, current: false, title: "b · Claude window", droppedOut: true) { sub("Only when the profile has a Claude window") }
            } else if needsDesktop {
                let state: StepState = signedIn == nil || waiting ? .todo : desktopDone ? .done : desktop == .different ? .warn : current == 4 ? .now : .todo
                part(state, current: current == 4, title: draft.window == .standard ? "b · Claude window (the usual Claude app)" : "b · Claude window") {
                    // one status line: its own sign-in, checked against Claude Code's by account id
                    if signedIn == nil || waiting {
                        sub("After Claude Code")
                    } else {
                        switch desktop {
                        case .same: Text("Signed in to the same account").font(.system(size: 11.5)).foregroundStyle(face.ok)
                            .fixedSize(horizontal: false, vertical: true)
                        case .unknown: sub("Signed in")
                        case .different:
                            Text("The Claude window is signed in to another account: in that window, Settings ▸ Sign out, then sign in as \(AddressSettings.words(signedIn ?? ""))")
                                .font(.system(size: 11.5)).foregroundStyle(face.caution).fixedSize(horizontal: false, vertical: true)
                        default:
                            HStack(spacing: 5) {
                                if windowOpen { ProgressView().controlSize(.mini) }
                                sub("Sign in to it as \(AddressSettings.words(signedIn ?? "")): the window has its own sign-in")
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

    // MARK: steps

    /// The steps, in their own panel: beside the cards (three or two columns, with the action bar at its foot) or under
    /// them (one column, where the action bar is pinned to the window's bottom instead).
    private func stepsPanel(bar: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {

            let ready = NewAccountSetup.foldersReady(draft)
            let n = quitStep ? 0 : -1           // without a Claude window there's no "Quit the desktop app" step
            if quitStep {
                stepRow(1, state: ready ? .done : monitor.failed ? .bad : monitor.checked ? (appRuns.isEmpty ? .done : draft.continueAnyway ? .warn : .bad) : .todo,
                        title: "Quit the desktop app",
                        detail: ready ? "done · it can stay open now" : monitor.failed ? NewAccountSetup.failedWords
                            : !monitor.checked ? "checking…" : appRuns.isEmpty ? "closed" : nil,
                        detailBad: !ready && monitor.failed,
                        connector: running) {
                    if running { openApps } else if !ready && monitor.failed { checkAgain }
                }
            }
            stepRow(2 + n, state: folders ? .done : current == 2 ? .now : running ? .held : .todo,
                    title: draft.source == .new ? "Create the folder" + (draft.share.isEmpty ? "" : " and links") : "Connect the folder",
                    detail: folders ? draft.configDir : running ? "held until the desktop app is quit" : checks.contains(where: { $0.blocks && $0.section != .running }) ? "fix the red lines first" : nil,
                    detailBad: running && !folders) { EmptyView() }
            stepRow(3 + n, state: !folders ? .todo
                        : (needsDesktop && signedIn != nil && desktop == .different) ? .warn
                        : current == 3 || current == 4 ? .now : .done,
                    title: "Sign in",
                    detail: folders ? nil : needsDesktop ? "Claude Code, then the Claude window" : "Claude Code") {
                if folders { signInParts.padding(.top, 3) }
            }
            stepRow(4 + n, state: current == 5 ? .now : .todo, title: finishStep,
                    detail: draft.usageInDock ? "Finish installs “cl_audit \(draft.name.isEmpty ? "…" : draft.name)” and puts it in the Dock"
                                              : "cl_audit reads its usage from now on; nothing is installed and the Dock isn't touched") { EmptyView() }

            if bar { actionBar(hint: false).padding(.top, 8) }
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

    /// The desktop app still open, under step 1 (only until the folder exists): what is open in one red line, why it
    /// matters in one grey line, then the keys. No box: the step's red mark already says it.
    private var openApps: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Open: " + runGroups.flatMap(\.items).joined(separator: ", "))
                .font(.system(size: 11.5)).foregroundStyle(face.danger).fixedSize(horizontal: false, vertical: true)
                .help(runLines.joined(separator: "\n"))
            SRowLine(text: "While open it writes its sign-in and settings, which could overwrite the new folder; it can stay open once the folder exists.")
            FlowLayout(spacing: 8) {
                if appRuns.contains(where: { $0.kind != .terminal }) {
                    Button("Quit the desktop app") { confirmQuit = true }.buttonStyle(.pill(.red, compact: true))
                }
                checkAgain
            }
        }
        .padding(.top, 1)
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
    /// When that doesn't fit one line (the steps panel in a narrow column), the buttons go on a line of their own
    /// below, still on the right, so no word is ever broken.
    private func actionBar(hint: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { cancelButton; Spacer(minLength: 6); actionNote(hint: hint); actionButtons }
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) { cancelButton; Spacer(minLength: 6); actionNote(hint: hint) }
                HStack(spacing: 8) { actionButtons }
            }
        }
        .padding(.horizontal, hint ? 16 : 0).padding(.vertical, hint ? 10 : 0)
        .background(hint ? Color.black(face.light ? 0.03 : 0.12) : Color.clear)
        .overlay(alignment: .top) { if hint { EngravedRule() } }
    }

    private var cancelButton: some View {
        Button(model.discarding ? "Cancelling…" : "Cancel") { gate.cancel(); confirmCancel = true }
            .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.discarding).fixedSize()
    }

    /// The error, else (in the window-wide bar) what comes next.
    @ViewBuilder private func actionNote(hint: Bool) -> some View {
        if let e = error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
        else if hint { Text(nextHint).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
    }

    /// The one next action ("Finish now" stays next to it once the folder exists).
    @ViewBuilder private var actionButtons: some View {
        if !NewAccountSetup.foldersReady(draft) {
            Button(gate.busy ? "Checking…" : createTitle) {
                guard !gate.busy else { return }
                // the folder is made or connected only on a look made now (couldn't check, or the desktop app open, holds it);
                // Cancel or leaving the page meanwhile drops the look, and nothing is made
                gate.look(monitor) { fresh in
                    if let why = NewAccountSetup.runsBlock(draft, accounts: model.accounts, runs: fresh) { self.error = why; return }
                    do { try NewAccountSetup.createOrConnect(&draft); error = NewAccountSetup.notReadyWhy(draft); model.tick += 1 }
                    catch { self.error = PlainWords.why(error) }
                }
            }
            .buttonStyle(.primaryKey(compact: true)).disabled(blocked || gate.busy || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
        } else if current == 5 {
            Button(draft.usageInDock ? "Finish" : "Start reading usage") { model.finishNew() }.buttonStyle(.primaryKey(compact: true)).disabled(blocked || model.discarding)
        } else {
            Button(desktop == .different ? "Finish anyway" : "Finish now") { model.finishNew() }
                .buttonStyle(PillButtonStyle(tint: nil, compact: true)).disabled(blocked || model.discarding)
                .help("Sign-in can be finished later from Settings")
            if signedIn == nil {
                Button("Sign in to Claude Code…") {
                    // the same sign-in as the address route's, followed to its end (the address typed before, if any, filled in)
                    if let c = model.requireClaude() { model.startNewSignIn(c, email: draft.email.isEmpty ? nil : draft.email) }
                }
                    .buttonStyle(.pill(tint, compact: true)).disabled(model.discarding || waiting)
            } else if draft.claudeWindow, !waiting {
                // (another profile's account too: the window opens all the same, shared seats)
                Button(windowOpen ? "Show Claude window" : "Open Claude window") { Launcher.openClaude(Account(draft.entry)) }
                    .buttonStyle(.pill(tint, compact: true)).disabled(model.discarding)       // (never while Cancel removes its folders)
            }
        }
    }

    private var nextHint: String {
        switch current {
        case 1: return monitor.failed ? "Check again: which Claude runs couldn't be checked" : monitor.checked ? "Next: quit the desktop app" : "Checking the desktop app…"
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

    /// What's open, by place: the desktop app's windows and their Code tab sessions.
    private var runGroups: [(title: String, items: [String], note: String?)] {
        var out: [(String, [String], String?)] = []
        let apps = appRuns.filter { $0.kind == .desktop }.map { r -> String in
            if r.folder == ClaudeRun.unknownFolder { return "a window whose folder couldn't be read" }
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
