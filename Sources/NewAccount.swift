// Adding a Claude account: one page in Settings. The account lives in a new Claude Code folder or in one
// that already exists (the default ~/.claude too); a folder and a desktop window can belong to only one
// account, which the Checks card verifies live. A banner lists every desktop app window and its Code tab sessions
// open: the steps that write folders wait until it's quit (Claude Code in Terminal doesn't matter).
// The Account card leads with the account: one signed in in a folder no profile uses (connecting that folder), or
// "Sign in to another account…" in a new folder, with the address filled in if one is typed. Folders stay where they are.
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
    var usageInDock = true              // off: no Dock icon, usage read in the background (the last step, "Start reading usage")
    /// Its own menu bar icon (On this Mac). Off by default; New profile's page starts it on (SettingsModel.startNew), first
    /// run and the default profile leave it off.
    var menuBar = false
    var claudeWindow = true             // off: no Claude window, so no Claude app sign-in step
    /// "Sign in to another account…": the address Claude Code's sign-in is filled in with (only filled in: the
    /// browser's claude.ai account decides; empty: none, optional), the address row open, and when Sign in was pressed.
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
    /// Something is on disk that this setup made (a folder): Name, Folder and the account choice are fixed then; Cancel and
    /// clean up starts over. A connected existing folder alone writes nothing, so another choice can still replace it.
    var locked: Bool { createdConfigDir != nil || createdDataDir != nil }

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
        e.menuBar = menuBar
        e.menuBarLook = Self.newMenuBarLook       // (the template's look isn't copied: a new profile starts here)
        return e
    }

    /// A new profile's menu bar icon: Two bars, Levels, the profile's label and Countdown. MenuBarLook's own default (the
    /// carry-over from the old single item, MenuBarLegacy, too) keeps no label.
    static var newMenuBarLook: MenuBarLook {
        var l = MenuBarLook()
        l.label = true
        return l
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
    /// A red line blocks Sign in's folder (the profile's and the folder's lines) and Create (the window's clash too); the
    /// desktop-app line (`running`) holds only the Claude window's folder, "Checking…" too: which Claude runs is never
    /// taken for "none" before it has been read.
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

    /// The Claude Code folder is in place: created, or an existing one connected.
    static func codeReady(_ d: NewAccountDraft) -> Bool { d.source == .existing ? d.connected : exists(d.configDir) }

    /// The window's data folder is needed for the switch's current value (on, its own window) and isn't there yet.
    static func windowFolderMissing(_ d: NewAccountDraft) -> Bool { d.window == .separate && d.claudeWindow && !exists(d.dataDir) }

    /// The Claude Code folder is in place (created, or an existing one connected) and so is the window's data folder,
    /// which only a profile with a Claude window gets (makeWindowFolder makes it only then). Follows the switch as it is now.
    static func foldersReady(_ d: NewAccountDraft) -> Bool { codeReady(d) && !windowFolderMissing(d) }

    /// New profile's Claude window step is due: the Claude Code folder is in place (Sign in made or connected it) and the
    /// window's own data folder isn't yet. Its look at the desktop app, then that folder (windowStepLook).
    static func windowStepDue(_ d: NewAccountDraft) -> Bool { codeReady(d) && windowFolderMissing(d) }

    /// The Claude window's own sign-in is a step whenever the switch is on (its own window or the usual Claude app).
    static func needsDesktop(_ d: NewAccountDraft) -> Bool { d.claudeWindow }

    /// A red line about the profile or its Claude Code folder (its name, the folder): it holds Sign in's folder (and a
    /// connect). The Claude window's lines (its clash, the desktop app) are its own step's and never hold Sign in.
    static func codeBlocked(_ d: NewAccountDraft, accounts: [AccountEntry]) -> Bool {
        checks(d, accounts: accounts, runs: [], checked: true).contains { $0.blocks && $0.section != .running && $0.section != .window }
    }

    /// What Sign in (and a connect) waits for before it can act, as the grey line under Account says it (a hint, never red):
    /// the name, then the red lines while the Claude Code folder isn't in place. Never the desktop app: it never writes that
    /// folder. nil: it can go.
    static func signInWait(_ d: NewAccountDraft, accounts: [AccountEntry]) -> String? {
        if d.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name the profile first." }
        // before anything is made or connected (a new folder that is already there, not made here, is a red line, never
        // "ready": signing in there would take a folder that isn't this setup's)
        if !d.started && codeBlocked(d, accounts: accounts) { return "Fix the red lines first." }
        return nil
    }

    /// What the address row's Sign in waits for, on the draft as that sign-in would leave it (forSignIn: often a new folder,
    /// whatever folder is connected now): the name, or the red line that would hold its folder, said as itself (that folder
    /// isn't the one on the page, so "fix the red lines" would point at nothing). nil: it can go.
    static func addressWait(_ d: NewAccountDraft, accounts: [AccountEntry]) -> String? {
        let next = forSignIn(d, email: d.email.trimmingCharacters(in: .whitespaces))
        guard let w = signInWait(next, accounts: accounts) else { return nil }
        if next.name.trimmingCharacters(in: .whitespaces).isEmpty { return w }
        return checks(next, accounts: accounts, runs: [], checked: true)
            .first { $0.blocks && $0.section != .running && $0.section != .window }?.text ?? w
    }

    /// Whether Claude Code's sign-in may run in the draft's folder now: before anything is made (it makes a new folder); in
    /// the folder this setup made (signing in there again); in an existing folder connected with no account in it yet (its
    /// first sign-in). Never in a connected folder that is signed in already: it is used as it is.
    static func signInAllowed(_ d: NewAccountDraft) -> Bool {
        !d.locked || (d.createdConfigDir != nil && d.source == .new) || emptyConnected(d)
    }

    /// An existing folder connected with no confirmed account in it yet (none, or only the guess an unconfirmed sign-in left):
    /// a sign-in runs there (its first, or a retry), never in a new folder.
    static func emptyConnected(_ d: NewAccountDraft) -> Bool {
        d.source == .existing && d.connected && (signedInEmail(d) == nil || d.unconfirmed)
    }

    /// The draft as a sign-in from Account leaves it: a new folder, unless something is made already (signing in again in
    /// the folder this setup made) or a connected folder waits for its first sign-in.
    static func forSignIn(_ d: NewAccountDraft, email: String) -> NewAccountDraft {
        var n = d
        n.email = email
        if !n.locked && !emptyConnected(n) { replaceFolder(&n, existing: nil) }
        return n
    }

    /// Another folder for the draft before anything is made: an existing one (used as it is, connected by the caller once
    /// nothing holds it) or, nil, a new one. What the last folder's sign-in left goes with it (its waiting, its end, its
    /// Continue anyway): it was about that folder, never this one.
    static func replaceFolder(_ d: inout NewAccountDraft, existing path: String?) {
        d.source = path == nil ? .new : .existing
        d.existingDir = path
        d.connected = false
        d.signInAsked = nil; d.seatAtAsk = nil; d.signInSaid = nil; d.signInRunning = false
        d.continueAnyway = false
    }

    /// Whether Create can add the profile now: its folders there for the switches as they are (its window's too), no red
    /// line (the Claude window's clash included; the desktop-app look only holds the window's folder, which foldersReady
    /// covers), no sign-in under way, and nothing being removed (Cancel, the window switch turning off). The page's key and
    /// SettingsModel.finishNew both ask this.
    static func canFinish(_ d: NewAccountDraft, accounts: [AccountEntry], discarding: Bool, windowBusy: Bool) -> Bool {
        foldersReady(d) && !discarding && !windowBusy && !d.signInRunning && !waiting(d)
            && !checks(d, accounts: accounts, runs: [], checked: true).contains { $0.blocks && $0.section != .running }
    }

    /// The line under Name and Folder, which are fixed once the folder is made or connected.
    /// (shown only once something is made, NewAccountDraft.locked: a connected folder alone can still be replaced)
    static func lockedNote(_ d: NewAccountDraft) -> String { "Set when the folder was made. Cancel and clean up starts over." }

    /// Why Create/Connect can't go on when it ran and the folders still aren't ready, or nil when they are: said, never silent.
    static func notReadyWhy(_ d: NewAccountDraft) -> String? {
        guard !foldersReady(d) else { return nil }
        var missing: [String] = []
        if !codeReady(d) { missing.append(d.configDir) }
        if windowFolderMissing(d) { missing.append(d.dataDir) }
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

    /// The Account pop-up's other profiles' accounts, "address   Plan · Name's" and "address   Plan · Name's standby": each
    /// can be picked (shared seats), which signs in to it in the new profile's own folder with its address filled in. One row
    /// per seat (account and organisation, by the one owner rule): the accounts in use first, then the standby ones, each in
    /// profile order; an account in use in one profile and standing by in another shows once, as the in-use one. The address
    /// goes through AddressSettings.words (a menu row is plain text: "hidden address" while addresses are hidden). Two rows
    /// that would read the same (hidden addresses of one profile's standby accounts, or one address in two organisations)
    /// are told apart by a number after the later ones ("Work's standby 2"), which names no address. An empty address on a
    /// seat counts as none (the entry's own, or the folder's, is taken). `blur`: a test override of Show emails.
    static func otherAccounts(among accounts: [AccountEntry],
                              plan: (AccountEntry) -> String? = { Store.status($0.id)?.plan },
                              expected: (String) -> String? = { Account.expectedEmail(configDir: $0) },
                              blur: Bool? = nil) -> [(title: String, email: String)] {
        var out: [(title: String, email: String)] = []
        var seen: [AccountIdentity] = []
        var bases: [String] = []            // each row's title before its number
        func add(_ who: AccountIdentity, email: String?, plan: String?, owner: String) {
            guard let email, !email.isEmpty, !seen.contains(where: { $0.sameAccount(who) }) else { return }
            seen.append(who)
            let detail = [plan.map(Account.planWords), owner].compactMap { $0 }
            let base = AddressSettings.words(email, blur: blur) + "   " + detail.joined(separator: " · ")
            let same = bases.filter { $0 == base }.count
            bases.append(base)
            out.append((same > 0 ? base + " \(same + 1)" : base, email))
        }
        for o in accounts {
            let e = o.seat?.email.flatMap { $0.isEmpty ? nil : $0 } ?? expected(o.configDir)
            var who = o.seat.map { AccountIdentity($0) } ?? AccountIdentity(account: nil, email: e, organization: nil, source: .guessed)
            if (who.email ?? "").isEmpty { who.email = e }
            add(who, email: e, plan: plan(o), owner: o.name + "'s")
        }
        for o in accounts {
            for s in o.standby {
                add(s.identity, email: s.identity.email, plan: s.plan, owner: o.name + "'s standby")
            }
        }
        return out
    }

    /// The address row's field and its grey line: the address only fills in the sign-in, the browser's account decides.
    static let addressPlaceholder = "name@example.com (optional)"
    static let addressHelp = "Leave it empty to choose the account in your browser."

    /// On this Mac's grey line under a Claude window that's on.
    static func windowWords(standard: Bool) -> String {
        standard ? "The usual Claude app, with its sign-in and Code sidebar." : "Its own window, with its own sign-in and Code sidebar."
    }
    /// On this Mac's grey line under a menu bar icon that's on.
    static let menuBarWords = "Style and colours: in Settings after."

    /// Why Sign in (the address route) can't go with this address, or nil: only an address that isn't one. The address is
    /// optional: empty signs in with none, and the account picked in the browser is the folder's, read afterwards. Another
    /// profile's account is no problem (shared seats): `addressNote` says so.
    static func addressProblem(_ email: String) -> String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        if e.isEmpty { return nil }
        guard e.contains("@"), !e.hasPrefix("@"), !e.hasSuffix("@"), !e.contains(" ") else { return "That isn't an email address. Leave it empty to pick the account in the browser." }
        return nil
    }

    /// The amber note for an address typed that another profile has, in use or standing by (FolderRules.sharedNote), or nil.
    /// The address only fills in the sign-in, so this is the early, by-address part; afterwards the account and organisation
    /// ids decide (`signInNote`).
    static func addressNote(_ email: String, among accounts: [AccountEntry],
                            signedIn: (String) -> Seat? = Account.signedInSeat) -> String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty, addressProblem(e) == nil else { return nil }      // no address: the folder's account decides afterwards
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
    static let failedWords = RunsMonitor.failedWords + ", so the Claude window's folder isn't made yet"

    /// What keeps the Claude window's data folder from being made on a look made at the click, or nil: the desktop-app line
    /// when it blocks. `runs` nil: which Claude runs couldn't be checked.
    static func runsBlock(_ d: NewAccountDraft, accounts: [AccountEntry], runs: [ClaudeRun]?) -> String? {
        checks(d, accounts: accounts, runs: (runs ?? []).filter { $0.kind != .terminal }, checked: runs != nil, failed: runs == nil)
            .first { $0.section == .running && $0.blocks }?.text
    }

    /// Every line about the draft, in order: the name, the folder, the window, the sign-in, the desktop app. A `.bad` line
    /// blocks (SetupCheck.blocks). `failed`: which Claude runs couldn't be checked (RunsMonitor.failed): a red line, never
    /// "the desktop app is closed".
    static func checks(_ d: NewAccountDraft, accounts: [AccountEntry], runs: [ClaudeRun], checked: Bool, failed: Bool = false) -> [SetupCheck] {
        var out: [SetupCheck] = []
        let name = d.name.trimmingCharacters(in: .whitespaces)
        // no name: nothing can be made without one (a grey hint, `.wait`); emptied after a folder was connected, a red line,
        // so Create can't add a profile with no name
        if name.isEmpty { out.append(.init(section: .account, state: d.started ? .bad : .wait, text: "Name the profile first.")) }
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

        // The desktop app open: it writes sign-in and settings into a window's data folder, which matters only until the
        // new window's own folder exists (New profile's Claude window step). The Claude Code folder is never in its way:
        // the desktop app never writes it (its Code tab uses ~/.claude, sign-in runs in Terminal, shared items are links),
        // so Sign in makes it without this check. Claude Code in Terminal doesn't get in the way.
        let appRuns = runs.filter { $0.kind != .terminal }
        if !windowFolderMissing(d) { return out }
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

    /// A connected folder after Cancel: "~/.claude-x stays as it is, signed in" (it is never signed out or deleted).
    static func keptWords(_ d: NewAccountDraft) -> String {
        "\(d.configDir) stays as it is" + (signedInEmail(d) != nil && !d.unconfirmed ? ", signed in" : "")   // (a guess isn't "signed in")
    }

    /// What Cancel will undo, for the confirmation.
    static func discardSummary(_ d: NewAccountDraft) -> String {
        guard d.locked else { return d.connected ? keptWords(d) + "." : "Nothing has been created yet." }
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

    /// Creates the new folder (with links from ~/.claude) or connects the existing one, and creates the separate window's
    /// data folder: first run and the default profile, which make both at once. Records what it created, so Cancel can
    /// remove exactly that.
    static func createOrConnect(_ d: inout NewAccountDraft) throws {
        try createCode(&d)
        try makeWindowFolder(&d)                                            // no Claude window: no folder for one
    }

    /// The Claude Code folder alone: the new folder with its links, or the existing one connected. New profile's Sign in
    /// makes it first, with no look at the desktop app (which never writes it); the window's folder is its own step.
    static func createCode(_ d: inout NewAccountDraft) throws {
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
    }

    /// The separate window's data folder, made when the switch is on and it isn't there, and recorded so Cancel and the
    /// switch remove exactly that. createOrConnect (first run, the default profile) and New profile's Claude window step
    /// (windowStepLook, only after its look found the desktop app closed) both make it here.
    static func makeWindowFolder(_ d: inout NewAccountDraft) throws {
        guard windowFolderMissing(d) else { return }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: expand(d.dataDir)), withIntermediateDirectories: true)
        d.createdDataDir = d.dataDir
    }

    /// The Claude window turned on: its step (windowStepDue) makes its folder once the Claude Code folder is in place, after
    /// its own look at the desktop app, asked again whatever an earlier Continue anyway said. Makes nothing.
    static func windowOn(_ d: inout NewAccountDraft) {
        d.claudeWindow = true
        d.continueAnyway = false
    }

    /// The Claude window step: the look made at the click (`runs` nil: which Claude runs couldn't be checked) and, only when
    /// it found nothing in the way, the window's folder (makeWindowFolder). The line that held it, or nil when the folder is
    /// there now.
    /// `anyway`: its Continue anyway, taken for this look only and kept on the draft only once this look ran (never a flag
    /// left set by a look that didn't happen).
    static func windowStepLook(_ d: inout NewAccountDraft, accounts: [AccountEntry], runs: [ClaudeRun]?, anyway: Bool = false) -> String? {
        guard windowStepDue(d) else { return nil }
        var asked = d
        if anyway { asked.continueAnyway = true }
        if let why = runsBlock(asked, accounts: accounts, runs: runs) { return why }
        if anyway { d.continueAnyway = true }
        do { try makeWindowFolder(&d) } catch { return PlainWords.why(error) }
        return nil
    }

    /// Why the Claude window can't be turned off after the folder is made, or nil: a window this setup didn't start (on a
    /// window folder it didn't make) is open, and it is never quit from here.
    static func windowOffBlock(_ d: NewAccountDraft, isOpen: (Account) -> Bool = ClaudeWindow.isOpen) -> String? {
        guard d.claudeWindow, d.window == .separate, d.createdDataDir == nil, exists(d.dataDir), isOpen(Account(d.entry)) else { return nil }
        return notOurWindow
    }
    static let notOurWindow = "A Claude window this setup didn't start is open on its folder.\nThe switch stays on."
    static let windowQuitFirst = "The Claude window this setup started was quit first."
    static let windowDidntQuit = "The Claude window didn't quit in time.\nThe switch stays on. Quit the window, then turn the switch off again."
    static let windowFolderKept = "The window's folder couldn't be removed.\nThe switch stays on."

    enum WindowOff: Equatable { case off(quit: Bool), kept(String) }

    /// Turning the Claude window off after the folder is made: the window this setup started quits first, then that folder
    /// goes. Which window is this setup's goes by the folder it made (ownWindow: createdDataDir), as Cancel's clean-up does;
    /// pid plus start time only confirm that the instances asked to quit are gone (ClaudeWindow.quitAndWait).
    /// A folder it didn't make stays, and a window it didn't start is never quit (windowOffBlock). `kept`: the switch stays
    /// on and the draft is unchanged (its window may have quit). Blocks; call off the main thread, then `turnedOff` on the draft.
    static func windowOff(_ d: NewAccountDraft) -> WindowOff {
        if let why = windowOffBlock(d) { return .kept(why) }
        var quit = false
        if let a = ownWindow(d), ClaudeWindow.isOpen(a) {
            guard ClaudeWindow.quitAndWait(a, seconds: discardWait) else { return .kept(windowDidntQuit) }
            quit = true
        }
        if let a = ownWindow(d), ClaudeWindow.isOpen(a) { return .kept(windowDidntQuit) }     // opened again meanwhile
        if let dir = ownWindow(d).flatMap({ _ in d.createdDataDir }) {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: expand(dir)))
            // still there: the switch stays on and createdDataDir stays, so Cancel or the switch can try again
            if exists(dir) { return .kept(windowFolderKept) }
        }
        return .off(quit: quit)
    }

    /// The draft after windowOff said `off`: no window, and no window folder of its own to clean up.
    static func turnedOff(_ d: inout NewAccountDraft) {
        d.claudeWindow = false
        d.createdDataDir = nil
    }
}

/// The add-account page. Wide windows: three columns (account and window · Claude Code folder · summary and
/// steps: Sign in, the Claude window with its "desktop app is open" look, the Dock icon). Narrower: one column with a progress
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
    @State private var windowNote: WindowNote?      // the Claude window switch's line after it was turned on or off
    @State private var windowBusy = false           // turning the window off: its window quitting, its folder going
    @Environment(\.face) private var face

    /// The page's columns for a width: three (who it is and its parts · Account · steps), two (every card · steps) or
    /// one (the cards, then the steps, with the next action pinned at the bottom). A column is never narrower than
    /// `column`, so nothing runs off the window or gets cut; a card narrower than `rowsFit` stacks its rows (the label
    /// on its own line, the control the card's full width under it), so addresses and paths show whole.
    struct Columns: Equatable { let count: Int; let widths: [CGFloat] }
    static let column: CGFloat = 340
    static let rowsFit = SRow<EmptyView>.stackBelow   // Claude Code's rows side by side from here (Settings uses it too)
    static let smallRowsFit: CGFloat = 330     // the small cards' rows (a name, swatches, a switch) fit down to here
    /// The ten colour swatches (SwatchRow: 22 pt each with 2 pt between) beside the label column, with the card's padding:
    /// narrower, the Colour row stacks so they stay one row.
    static let swatchesInline: CGFloat = 430
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
        // an existing folder chosen while a name or a red line held it: connected as soon as they clear
        .onChange(of: draft.name) { _ in connectPicked() }
        .onChange(of: blocked) { _ in connectPicked() }
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
    /// A red line about the profile, its name or its Claude Code folder: it holds Sign in's folder (NewAccountSetup.codeBlocked).
    /// The Claude window's lines (its clash, the desktop app) are its own step's.
    private var blocked: Bool { NewAccountSetup.codeBlocked(draft, accounts: model.accounts) }
    /// What Sign in and a connect wait for (NewAccountSetup.signInWait): the name, then the red lines. nil: they can go.
    private var signInWait: String? { NewAccountSetup.signInWait(draft, accounts: model.accounts) }
    /// No name yet: every Sign in is off (the row key, the pop-up's picks), with one grey line under Account.
    private var unnamed: Bool { draft.name.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The Claude Code folder is in place: Sign in made it (or connected the existing one).
    private var made: Bool { NewAccountSetup.codeReady(draft) }
    /// The Claude window's folder isn't made yet while the Claude Code folder is (NewAccountSetup.windowStepDue).
    private var windowDue: Bool { NewAccountSetup.windowStepDue(draft) }
    /// The Claude window step is live: its folder is due and step 1 is done (signed in). Before, it waits, its keys off:
    /// never two steps live while Terminal waits for the browser.
    private var windowLive: Bool { windowDue && signedIn != nil && !waiting }
    /// The desktop app open while the window's folder isn't made yet (the step live).
    private var windowHeld: Bool { windowLive && monitor.checked && !appRuns.isEmpty && !draft.continueAnyway }
    private var desktop: NewAccountSetup.DesktopSignIn { NewAccountSetup.desktopSignIn(draft) }
    private var needsDesktop: Bool { NewAccountSetup.needsDesktop(draft) }
    private var desktopDone: Bool { !needsDesktop || desktop == .same || desktop == .unknown }
    private var folders: Bool { made && NewAccountSetup.linksReady(draft) }
    /// Who Claude Code in the folder is signed in to; nobody while its last sign-in ended unconfirmed (the folder's record
    /// alone is a guess: Sign in again, or Refresh now in Settings once the profile is made).
    private var signedIn: String? { checks(.folder).contains { $0.blocks } || draft.unconfirmed ? nil : NewAccountSetup.signedInEmail(draft) }
    private var windowOpen: Bool { NewAccountSetup.foldersReady(draft) && NewAccountSetup.windowOpen(draft) }
    /// The steps and their keys speak in progress colours, never the profile's (a pink profile's current step was pink):
    /// the current step and the key that moves it on are green (FaceTheme.ledOn, a switch that's on), a done step green
    /// with a check, a held one amber, a failed one red, one still to come grey.
    private var go: Color { FaceTheme.ledOn }
    /// The last step: a Dock icon, or (Usage in the Dock off) only reading its usage, which installs nothing.
    private var finishStep: String { draft.usageInDock ? "Add the Dock icon" : "Start reading usage" }

    /// What's next: 1 Sign in (the Claude Code folder, then its sign-in in Terminal), 2 the Claude window (its folder after
    /// a look at the desktop app, then its own sign-in; only with a Claude window), 3 the Dock icon (or reading the usage).
    private var current: Int {
        if !folders || signedIn == nil || waiting { return 1 }       // (signing in again: step 1, whatever the folder still names)
        if windowDue || !desktopDone { return 2 }
        return 3
    }

    // MARK: layouts

    /// Three columns: who it is and its parts on this Mac · Account · steps.
    private func three(_ c: Columns, _ w: CGFloat) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: Self.gap) {
                VStack(spacing: 10) {
                    profileCard(stacked: c.widths[0] < Self.smallRowsFit, width: c.widths[0])
                    onThisMacCard(stacked: c.widths[0] < Self.smallRowsFit)
                }
                .frame(width: c.widths[0])
                folderCard(stacked: c.widths[1] < Self.rowsFit).frame(width: c.widths[1])
                stepsPanel(bar: true).frame(width: c.widths[2])
            }
            .frame(width: max(0, w - 2 * Self.pad), alignment: .topLeading)   // never wider than the window
            .padding(.horizontal, Self.pad).padding(.vertical, 14)
        }
    }

    /// Two columns: Profile, On this Mac and Account, in that order · the steps.
    private func two(_ c: Columns, _ w: CGFloat) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: Self.gap) {
                VStack(spacing: 10) {
                    profileCard(stacked: c.widths[0] < Self.smallRowsFit, width: c.widths[0])
                    onThisMacCard(stacked: c.widths[0] < Self.smallRowsFit)
                    folderCard(stacked: c.widths[0] < Self.rowsFit)
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
                    profileCard(stacked: cw < Self.smallRowsFit, width: cw)
                    onThisMacCard(stacked: cw < Self.smallRowsFit)
                    folderCard(stacked: cw < Self.rowsFit)
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

    /// Profile: who it is (name and colour), in rows like Settings ▸ Profile. `width`: the card's column; narrower than
    /// `swatchesInline`, the Colour row stacks (its label above) so its ten swatches stay one row.
    private func profileCard(stacked: Bool, width: CGFloat) -> some View {
        SCard(title: "Profile", info: "The new profile: one Claude account, with its Claude Code folder and, if you want them, a Claude window and a Dock icon. Its click and panel settings start as \(draft.template?.name ?? "the other profiles'").") {
            SRow(label: "Name", info: "What cl_audit calls this profile. Its Dock icon is “cl_audit \(draft.name.isEmpty ? "<name>" : draft.name)”, and a new Claude Code folder is \(draft.name.isEmpty ? "~/.claude-<name>" : draft.newConfigDir).", first: true, stacked: stacked) {
                SField(placeholder: "e.g. personal", text: $draft.name, width: nil).disabled(draft.locked || waiting)   // (not while a sign-in waits)
            }
            // (the locked note is said once, under Folder, the last locked row: it covers the name too)
            // a red line only (the name taken, or emptied after a connect); no name yet is Account's one grey line
            if let clash = checks(.account).first(where: { $0.state == .bad }) { SRowLine(text: clash.text, color: face.danger) }
            SRow(label: "Colour", info: "The profile's colour in the launcher, on the dashboard and in its panels.", stacked: stacked || width < Self.swatchesInline) {
                // Settings ▸ Profile's own swatch row: the colours in one row
                SwatchRow(colors: TileColor.accents, selected: draft.color) { if let c = $0 { draft.color = c } }
            }
        }
    }

    /// On this Mac: the profile's three parts here, one switch row each with the words profile settings use, in the order the
    /// sketch reads (the largest to the smallest): its Claude window, its Dock icon, its menu bar icon. A part that's on says
    /// in one grey line what it comes with (the window: its sign-in and sidebar; the menu bar: where its look is set); the
    /// Dock icon's click and look start as the template profile's. Profile settings keep each part's own card.
    private func onThisMacCard(stacked: Bool) -> some View {
        SCard(title: "On this Mac", info: "This profile's things on this Mac: a Claude window signed in to its account, a Dock icon and a menu bar icon showing its usage. Each can change later in the profile's settings.") {
            SRow(label: "Claude window", info: "On: a Claude window for this profile, opened from the dashboard or its Dock icon. A folder other than ~/.claude gets its own window, with its own sign-in and Code sidebar; ~/.claude uses the usual Claude app.\nOff: none, and no window sign-in step; Claude Code in Terminal still works.\nIts folder is made in the Claude window step, after Sign in, once the desktop app is closed.\nTurned off, the window this setup started is quit and the folder it made is removed.", first: true, stacked: stacked) {
                SSwitch(isOn: Binding(get: { draft.claudeWindow }, set: { setWindow($0) }),
                        on: draft.window == .standard ? "the usual Claude app" : "its own window", off: "none")
                    .disabled(windowBusy || model.discarding)
            }
            if draft.claudeWindow { SRowLine(text: NewAccountSetup.windowWords(standard: draft.window == .standard)) }
            if let note = windowNoteShown { SRowLine(text: note, color: face.caution) }
            if draft.claudeWindow, let clash = checks(.window).first(where: { $0.state != .ok }) {
                SRowLine(text: clash.text, color: clash.state == .bad ? face.danger : face.caution)
            }
            SRow(label: "Dock icon", info: "On: Create installs “cl_audit \(draft.name.isEmpty ? "<name>" : draft.name)” and puts it in the Dock; how it runs, its click and its look start as \(draft.template?.name ?? "the other profiles'") and are in the profile's settings afterwards.\nOff: nothing is installed and the Dock isn't touched; cl_audit still reads the usage for the dashboard, the launcher and alerts.", stacked: stacked) {
                SSwitch(isOn: $draft.usageInDock, on: "shows the usage", off: "no Dock icon")
            }
            SRow(label: "Menu bar", info: "On: an icon for this profile in the menu bar, drawn by the cl_audit agent, like its Dock icon. It starts as Two bars in the level colours, with the profile's label and a countdown when full.\nOff: none; the usage is read either way.", stacked: stacked) {
                SSwitch(isOn: $draft.menuBar, on: "shows the usage", off: "no icon")
            }
            if draft.menuBar { SRowLine(text: NewAccountSetup.menuBarWords) }
        }
    }

    /// Claude Code: the account first, in a pop-up like Settings ▸ Login, then the folder that comes with it. A folder
    /// holds one sign-in, so an account is always picked with its folder: an account signed in in a folder no profile
    /// uses connects that folder as it is; "Sign in to another account…" signs in, with the address filled in, in a
    /// new folder (~/.claude-<id>). Folders are used where they are: Claude Code names a folder's Keychain sign-in
    /// after its path, so moving one would lose it.
    private func folderCard(stacked: Bool) -> some View {
        SCard(title: "Account", info: "The claude.ai account this profile is for, and the Claude Code folder its sign-in, settings and history live in: one folder, signed in to one account. Folders are used where they are; Claude Code names a folder's Keychain sign-in after its path, so a moved folder would lose it.") {
            SRow(label: "Account", info: "The claude.ai account this profile is for.\nAn account that a Claude Code folder on this Mac is signed in to, and that no profile uses, comes with its folder.\nAn account another profile has can be this profile's too. Picking it signs in to it in this profile's own folder, and both profiles then show the same numbers.\nSign in to another account… opens Claude Code's own sign-in in Terminal. Typing the address is optional: it only fills it in.\nThe claude.ai account open in the browser is the one it uses. It is checked afterwards by its account and organisation ids.", first: true, stacked: stacked) {
                accountValue
            }
            accountLine
            ClaudeMissingLine(model: model)           // Sign in needs Claude Code: say so when it isn't there
            SRow(label: "Folder", info: "The Claude Code folder for this profile: its sign-in, settings and history live there. It follows the account; picking one by hand shows who is signed in there. New folder: ~/.claude-<name>, with the items below linked from another folder.", stacked: stacked) {
                folderPopup
            }
            if draft.locked { SRowLine(text: NewAccountSetup.lockedNote(draft)) }
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

    /// A sign-in may still run in the draft's folder (NewAccountSetup.signInAllowed): the folder this setup made, or a
    /// connected one with no account yet; a folder that existed before, signed in, is never signed in again from here.
    private var canSignInAgain: Bool { draft.locked && NewAccountSetup.signInAllowed(draft) }

    /// The Account menu's free accounts: "address   in folder", and whether it's the one picked.
    private var freeAccountLines: [(title: String, path: String, picked: Bool)] {
        freeAccounts.map { a in
            let picked = draft.source == .existing && (draft.existingDir.map { FolderKey.canonical($0) == FolderKey.canonical(a.path) } ?? false)
            return (AddressSettings.words(a.email) + "   in " + a.path, a.path, picked)
        }
    }

    /// The Account menu's other profiles' accounts, in use and standing by (NewAccountSetup.otherAccounts): each can be
    /// picked (shared seats), which signs in to it in this profile's own folder (another profile's folder is never shared)
    /// with its address filled in.
    private var otherAccountLines: [(title: String, email: String)] { NewAccountSetup.otherAccounts(among: model.accounts) }

    private func pickFreeAccount(_ path: String) { useExisting(path) }

    /// An existing folder chosen (a found account in Account, or a folder in the Folder pop-up): used as it is, connected at
    /// once (nothing is written, so another choice can still replace it until something is made), or as soon as what holds
    /// it clears (connectPicked runs again when the name or the red lines change).
    private func useExisting(_ path: String) { replaceFolder(existing: path) }

    /// Another folder before anything is made (NewAccountSetup.replaceFolder): a sign-in still running for the last one ends
    /// first (the choices are off while one waits, so only a stale one), then the chosen existing folder connects.
    private func replaceFolder(existing path: String?) {
        if draft.signInRunning { model.cancelNewSignIn() }
        NewAccountSetup.replaceFolder(&draft, existing: path)
        draft.email = ""; draft.asking = false
        connectPicked()
    }

    /// Connects the chosen existing folder once nothing holds it (signInWait: a name, no red line).
    private func connectPicked() {
        guard draft.source == .existing, draft.existingDir != nil, !draft.connected, signInWait == nil else { return }
        try? NewAccountSetup.createCode(&draft)
        model.tick += 1
    }

    /// Another profile's account picked: the address route with its address filled in (the note under it says it's shared).
    private func pickOtherAccount(_ email: String) {
        draft.email = email
        askAddress()
    }

    @ViewBuilder private var accountValue: some View {
        if draft.asking {
            // the address is optional: empty, Sign in runs the same sign-in and the account picked in the browser is taken
            // dimmed (its lamp dark) until it can act (signInWait); without Claude Code it isn't greyed: the click says why
            AddressRow(email: $draft.email, canSignIn: NewAccountSetup.addressWait(draft, accounts: model.accounts) == nil,
                       placeholder: NewAccountSetup.addressPlaceholder,
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
                // the other profiles' accounts (in use, then standby), then the ones found on this Mac. Once a folder is
                // made or connected, the account comes with it: only signing in again in the folder this setup made is left
                ForEach(Array(others.enumerated()), id: \.offset) { _, o in
                    Button(o.title) { pickOtherAccount(o.email) }.disabled(draft.locked && !canSignInAgain)
                }
                ForEach(free, id: \.path) { a in
                    if a.picked {
                        Toggle(a.title, isOn: .constant(true))
                    } else {
                        Button(a.title) { pickFreeAccount(a.path) }.disabled(draft.locked)
                    }
                }
                Divider()
                if model.claudeKnownMissing { Button(ClaudeInstall.missingInstall) { model.showInstallHelp() } }
                Button("Sign in to another account…") { askAddress() }
                    .disabled(model.claudeKnownMissing)      // greyed, with the line above saying why
            } label: {
                MenuWell(text: shown.text, tint: shown.tint, icon: shown.icon, fill: true, address: NewAccountSetup.wellAddress(shown.text))
            }
            .faceMenuFill()
            .disabled(unnamed || draft.locked && !canSignInAgain)     // the name comes first (the line under it says so)
            .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
        }
    }

    /// One grey line under Account: what the choice does, or what's happening.
    @ViewBuilder private var accountLine: some View {
        let text: (String, Color?)? = {
            // the name comes first: until then every Sign in is off, and this one grey line says why (emptied after a connect,
            // the red line under Name says it, once)
            if unnamed { return draft.started ? nil : ("Name the profile first.", nil) }
            // how the last sign-in window ended, when the folder's own account doesn't say it (below): unconfirmed, declined,
            // failed, no sign-in in time, replaced by another sign-in
            if !draft.asking, !waiting, let s = draft.signInSaid, s.kind != .signedIn, s.kind != .wrongAccount {
                return (s.text, s.danger ? face.danger : face.caution)
            }
            if draft.asking {
                // what its Sign in waits for, on the folder it would sign in to (NewAccountSetup.addressWait): the name a grey
                // hint, a red line about that folder in red
                if let w = NewAccountSetup.addressWait(draft, accounts: model.accounts) {
                    return (w, w == "Name the profile first." ? nil : face.danger)
                }
                if let p = addressProblem { return (p, face.danger) }
                // another profile's account typed or picked: taken all the same, said once, amber
                if let note = NewAccountSetup.addressNote(draft.email, among: model.accounts) { return (note, face.caution) }
                if let dir = NewAccountSetup.freeFolder(for: draft.email, among: model.accounts), !draft.locked {
                    return ("\(AddressSettings.words(draft.email)) is signed in in \(dir) already: pick it in the pop-up to use that folder as it is.", nil)
                }
                return (NewAccountSetup.addressHelp, nil)
            }
            if waiting {
                if draft.email.isEmpty { return ("Finish in the browser with the claude.ai account this profile is for.", nil) }
                return ("Finish in the browser as \(AddressSettings.words(draft.email)); switch its claude.ai account first if needed.", nil)
            }
            // an existing folder chosen: connected at once (or once what holds it clears: the line above says what), used as
            // it is; with no account in it yet, its first sign-in follows from the pop-up
            if draft.source == .existing, let dir = draft.existingDir, signedIn == nil || NewAccountSetup.signInNote(draft, among: model.accounts) == nil {
                if !draft.connected { return ("\(dir) is connected as it is once the red lines are fixed.", nil) }
                if signedIn == nil { return ("Connected \(dir) as it is, with no account in it yet: Sign in to another account… in the pop-up signs in there.", nil) }
                return ("Connected \(dir) as it is: its sign-in, settings and history stay.", nil)
            }
            if let email = signedIn {
                // another profile's account too (shared seats): the one amber note, no address in it (the field shows it)
                if let note = NewAccountSetup.signInNote(draft, among: model.accounts) { return (note, face.caution) }
                if !draft.email.isEmpty, draft.email.lowercased() != email.lowercased() {
                    return ("Signed in as \(AddressSettings.words(email)), not \(AddressSettings.words(draft.email)): the browser's claude.ai account decided. Keep it, or sign in again from the pop-up after switching the browser.", face.caution)
                }
                return nil
            }
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
                Button("New folder   \(draft.newConfigDir)") { replaceFolder(existing: nil) }
            }
            ForEach(folderChoices, id: \.self) { p in
                if let owner = FolderRules.configOwner(p, among: model.accounts) {
                    Button("\(p)   \(owner.name)'s") {}.disabled(true)
                } else if isSelected(p) {
                    Toggle("\(p)   \(folderWho(p))", isOn: .constant(true))
                } else {
                    Button("\(p)   \(folderWho(p))") { useExisting(p) }
                        .disabled(!canTake(p))
                }
            }
            Divider()
            Button("Choose another folder…") {
                if let p = pickFolder() {
                    if !folderChoices.contains(where: { FolderKey.canonical($0) == FolderKey.canonical(p) }) { customFolders.append(p) }
                    useExisting(folderChoices.first { FolderKey.canonical($0) == FolderKey.canonical(p) } ?? p)
                }
            }
        } label: {
            MenuWell(text: draft.source == .new ? "New folder \(draft.newConfigDir)" : draft.existingDir ?? "Choose…", mono: true, fill: true)
        }
        .faceMenuFill()
        .disabled(draft.locked || waiting)          // another folder never replaces one a sign-in is waiting on
    }

    /// Who is signed in in a folder, for the Folder pop-up.
    private func folderWho(_ p: String) -> String { NewAccountSetup.folderWho(p) }

    /// The Claude window switch. Before any folder is made it only flips. After: on, the Claude window step's look runs at
    /// once and makes the window's folder only when the desktop app is closed (windowStepLook); off, the window this setup started quits first
    /// and the folder it made goes (NewAccountSetup.windowOff), or the switch stays on with the line saying why.
    private func setWindow(_ on: Bool) {
        guard on != draft.claudeWindow, !windowBusy else { return }
        windowNote = nil
        // a look under way (the Claude window step's) does nothing when it lands, and the line says so
        let stopped = gate.busy ? Self.lookStopped : nil
        gate.cancel()
        error = nil
        if on {
            NewAccountSetup.windowOn(&draft)
            noteWindow(stopped)
            if windowLive { lookForWindow() }          // (before Sign in is done the step waits: its look comes then)
            return
        }
        guard draft.started else { draft.claudeWindow = false; noteWindow(stopped); return }
        let d = draft
        windowBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = NewAccountSetup.windowOff(d)
            DispatchQueue.main.async {
                windowBusy = false
                switch r {
                case .off(let quit):
                    NewAccountSetup.turnedOff(&draft)
                    noteWindow([stopped, quit ? NewAccountSetup.windowQuitFirst : nil].compactMap { $0 }.joined(separator: "\n"))
                case .kept(let why):
                    noteWindow([stopped, why].compactMap { $0 }.joined(separator: "\n"))
                }
                model.tick += 1
            }
        }
    }
    static let lookStopped = "The desktop app check under way was stopped, so nothing was made."

    /// The switch's line, tied to the draft as it is now and whether its window is open: either changing hides it.
    struct WindowNote { let text: String; let draft: NewAccountDraft; let open: Bool }
    private func noteWindow(_ text: String?) {
        guard let text, !text.isEmpty else { windowNote = nil; return }
        windowNote = WindowNote(text: text, draft: draft, open: ClaudeWindow.isOpen(Account(draft.entry)))
    }
    private var windowNoteShown: String? {
        guard let n = windowNote, n.draft == draft, n.open == ClaudeWindow.isOpen(Account(draft.entry)) else { return nil }
        return n.text
    }

    /// The Claude window step's look, made now (`anyway`: its Continue anyway, for this look only): the window's folder is
    /// made only on its answer (windowStepLook); Cancel, the switch or leaving the page meanwhile drops it.
    private func lookForWindow(anyway: Bool = false) {
        guard !gate.busy, !windowBusy, windowLive else { return }   // never while the switch is turning the window off
        gate.look(monitor) { fresh in
            // Continue anyway counts for this look only, kept on the draft once the look ran (windowStepLook)
            let why = NewAccountSetup.windowStepLook(&draft, accounts: model.accounts, runs: fresh, anyway: anyway)
            // the desktop app's line shows in the window step itself; only another reason (the folder couldn't be made) goes to the bar
            error = why == NewAccountSetup.runsBlock(draft, accounts: model.accounts, runs: fresh) ? nil : why
            model.tick += 1
        }
    }

    /// Sign in (the address route): the new folder is made if it isn't yet, then Terminal runs Claude Code's sign-in
    /// for it with the address filled in, if one was typed. The result is checked afterwards, by account and organisation ids.
    /// Nothing of the draft changes until every gate has passed (Return with no name or a red line leaves the choices as
    /// they were).
    private func startAddressSignIn() {
        guard !gate.busy else { return }
        if let p = NewAccountSetup.addressProblem(draft.email) { addressProblem = p; return }
        let e = draft.email.trimmingCharacters(in: .whitespaces)
        // a folder connected as it was is never signed in again from here; the folder this setup made can be, and a
        // connected folder with no account yet gets its first sign-in (NewAccountSetup.signInAllowed)
        guard NewAccountSetup.signInAllowed(draft) else { addressProblem = "This profile uses \(draft.configDir) as it is. Cancel the setup to sign in to another account."; return }
        // the draft as this sign-in would leave it: nothing made yet means a new folder (NewAccountSetup.forSignIn)
        var next = NewAccountSetup.forSignIn(draft, email: e)
        // not yet (no name, a red line): the key is dimmed and the grey line says what comes first (signInWait); Return in
        // the field ends here too, with the draft untouched
        guard NewAccountSetup.signInWait(next, accounts: model.accounts) == nil else { addressProblem = nil; return }
        guard let claude = model.requireClaude() else { addressProblem = model.noClaudeWhy; return }
        // the Claude Code folder first, with no look at the desktop app (it never writes this folder); the window's folder
        // is the Claude window step's
        if !next.started { do { try NewAccountSetup.createCode(&next) } catch { addressProblem = PlainWords.why(error); return } }
        draft = next
        // Claude Code's sign-in in Terminal with the address filled in, or none (the account picked in the browser), followed
        // to its end (SignInWindow): the sign-in window ending any other way than on an account says so under Account (a
        // refused start included). Either way the folder's account is read afterwards and taken (signedInEmail, signInNote).
        addressProblem = nil
        model.startNewSignIn(claude, email: e.isEmpty ? nil : e)
    }

    /// "Sign in to another account…": the one-line address row, in place of the pop-up. Its Sign in decides the folder
    /// (NewAccountSetup.forSignIn): a new one before anything is made, the folder this setup made, or a connected folder
    /// waiting for its first sign-in.
    private func askAddress() {
        // only the row opens: the folder changes (NewAccountSetup.forSignIn) once Sign in passes its gates, so Cancel here
        // leaves a connected folder as it was
        draft.asking = true; addressProblem = nil          // the address typed before stays: often the same one, again
    }

    /// A new folder only: which folder to link items from (a pop-up), and which items (keys under the label).
    @ViewBuilder private func shareRows(stacked: Bool) -> some View {
        let done = NewAccountSetup.codeReady(draft)          // the links are made with the Claude Code folder (Sign in)
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
            WrapChips(items: SharedItem.allCases.map { ($0.title, draft.share.contains($0)) }) { i in
                let item = SharedItem.allCases[i]
                if draft.share.contains(item) { draft.share.remove(item) } else { draft.share.insert(item) }
            }
            .disabled(done)
        }
    }

    /// Step 1's lines once its folder is in place (or the sign-in is under way): Claude Code's sign-in in Terminal.
    @ViewBuilder private var codeSignInLines: some View {
        if waiting {
            Text("Waiting for the browser…").font(.system(size: 11.5)).foregroundStyle(face.caution)
                .fixedSize(horizontal: false, vertical: true)
        } else if let email = signedIn {
            // the address in the drawn form (the stand-in while Show emails is off, never "hidden address" or real
            // text under a blur), as the Account field shows it; then the shared note, amber, with no address in it
            HStack(spacing: 0) {
                Text("Signed in as ")
                AccountValue(text: email, size: 11.5, reserve: false)
                if draft.source == .existing && !draft.locked { Text(", already in the folder") }
            }
            .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let note = NewAccountSetup.signInNote(draft, among: model.accounts) {
                Text(note).font(.system(size: 11.5)).foregroundStyle(face.caution).fixedSize(horizontal: false, vertical: true)
            }
        } else if let s = signInFailed {
            // how the last sign-in window ended without an account: red for a failure, amber otherwise (as under Account)
            Text(s.text).font(.system(size: 11.5)).foregroundStyle(s.danger ? face.danger : face.caution)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            sub("Sign in from Account: Terminal opens, then approve in the browser")
        }
    }

    /// The last sign-in window's end when it gave no account (unconfirmed, declined, failed, no sign-in in time), or nil.
    private var signInFailed: SignInSaid? {
        guard !waiting, signedIn == nil, let s = draft.signInSaid, s.kind != .signedIn, s.kind != .wrongAccount else { return nil }
        return s
    }

    /// Step 1's mark: waiting for the browser amber, a sign-in that failed red.
    private var signInState: StepState {
        if waiting { return .held }                 // first: signing in again, the old account still in the folder
        if folders && signedIn != nil { return .done }
        if let s = signInFailed, s.danger { return .bad }
        return current == 1 ? .now : .todo
    }

    /// Step 1's line while its folder isn't made: what Sign in makes first (the step that used to be "Create the folder and
    /// links"), or the red lines that hold it.
    private var signInDetail: String {
        if folders { return draft.configDir }
        if unnamed { return "after the profile's name" }          // (its folder is named after it: no folder to say yet)
        if blocked { return "fix the red lines first" }
        if draft.source == .existing {
            let dir = draft.existingDir ?? draft.configDir
            return signedIn == nil ? "\(dir) as it is, then Claude Code in Terminal" : "\(dir) as it is, already signed in"
        }
        let links = draft.share.isEmpty ? "" : ", sharing \(draft.share.count) item\(draft.share.count == 1 ? "" : "s") from \(draft.shareFrom)"
        return "\(draft.newConfigDir)\(links), then Claude Code in Terminal"
    }

    /// Step 2's lines: before Sign in, what it waits for; while the window's folder isn't made, the desktop-app look and
    /// its keys (windowStep); then the window's own sign-in, checked against Claude Code's by account id.
    @ViewBuilder private var windowLines: some View {
        // the step waits, its keys off, until Sign in is done: never two steps live while Terminal waits for the browser
        if !made || signedIn == nil || waiting {
            sub("After Sign in")
        } else if windowDue {
            windowStep
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
                // its own key, here in its step (the foot has only Create): another profile's account too opens it (shared seats)
                Button(windowOpen ? "Show Claude window" : "Open Claude window") { Launcher.openClaude(Account(draft.entry)) }
                    .buttonStyle(.pill(go, compact: true)).disabled(model.discarding || windowBusy || waiting)   // (never while Cancel or the switch removes its folder)
                    .padding(.top, 2)
            }
            // the one grey line: Code session records stay in the data folder they were made in
            Text(sidebarWords).font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    /// Step 2's mark: held by the desktop app amber, a look that failed red, its sign-in on another account amber.
    private var windowState: StepState {
        if !made || signedIn == nil || waiting { return .todo }
        if windowDue { return monitor.failed ? .bad : windowHeld ? .held : current == 2 ? .now : .todo }
        return desktopDone ? .done : desktop == .different ? .warn : current == 2 ? .now : .todo
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

    /// Step 2 while the window's folder isn't made: the desktop-app line (checking, closed, open, or couldn't check), then its
    /// keys. Open (amber: it holds the step, it isn't a failure): Quit the desktop app, Check again or Continue anyway;
    /// couldn't check (red): Check again; otherwise Set up the Claude window, which looks again and makes the folder.
    @ViewBuilder private var windowStep: some View {
        if let c = checks(.running).first {
            Text(c.text).font(.system(size: 11.5))
                .foregroundStyle(monitor.failed ? face.danger : c.state == .bad || c.state == .warn ? face.caution : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(runLines.joined(separator: "\n"))
        }
        if windowHeld { sub("The window's folder is made once the desktop app is closed.") }
        FlowLayout(spacing: 8) {
            if monitor.failed {
                checkAgain
            } else if windowHeld {
                Button("Quit the desktop app") { confirmQuit = true }.buttonStyle(.pill(FaceTheme.ledAmber, compact: true))
                checkAgain
                Button("Continue anyway") { lookForWindow(anyway: true) }
                    .buttonStyle(PillButtonStyle(tint: nil, compact: true)).disabled(gate.busy || windowBusy)
            } else {
                Button(gate.busy ? "Checking…" : "Set up the Claude window") { lookForWindow() }
                    .buttonStyle(.pill(go, compact: true)).disabled(gate.busy || model.discarding || windowBusy)
            }
        }
        .padding(.top, 2)
    }

    private func sub(_ s: String) -> some View {
        Text(s).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: steps

    /// The steps, in their own panel: beside the cards (three or two columns, with the action bar at its foot) or under
    /// them (one column, where the action bar is pinned to the window's bottom instead).
    private func stepsPanel(bar: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1 Sign in (its Claude Code folder first), 2 the Claude window (only with one), then the Dock icon
            let last = draft.claudeWindow ? 3 : 2
            stepRow(1, state: signInState, title: "Sign in", detail: signInDetail) {
                if folders || waiting { codeSignInLines }
            }
            if draft.claudeWindow {
                stepRow(2, state: windowState,
                        title: draft.window == .standard ? "Claude window (the usual Claude app)" : "Claude window",
                        note: windowHeld ? "still open" : nil, detail: nil) {
                    windowLines
                }
            }
            stepRow(last, state: current == 3 ? .now : .todo, title: finishStep,
                    detail: draft.usageInDock ? "Create installs “cl_audit \(draft.name.isEmpty ? "…" : draft.name)” and puts it in the Dock"
                                              : "cl_audit reads its usage from now on; nothing is installed and the Dock isn't touched") { EmptyView() }

            if bar { actionBar(hint: false).padding(.top, 8) }
        }
        .padding(14)
        .background(RaisedShape(finish: face.module, radius: face.moduleRadius))
    }

    private enum StepState { case todo, now, done, bad, warn, held }

    /// A step: its mark (done green with a check; current green; held amber; failed red "!"; to come grey), its title, one
    /// grey line and what it holds.
    private func stepRow<C: View>(_ n: Int, state: StepState, title: String, note: String? = nil, detail: String?,
                                  @ViewBuilder extra: () -> C) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                switch state {
                case .done: Circle().fill(Color(nsColor: Painter.green)); Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.7))
                case .bad: Circle().fill(Color.red); Text("!").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                case .warn: Circle().fill(face.caution); Text("!").font(.system(size: 12, weight: .bold)).foregroundStyle(.black.opacity(0.7))
                case .now: Circle().strokeBorder(go, lineWidth: 2); Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(go)
                case .held: Circle().strokeBorder(face.caution, lineWidth: 1.5); Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(face.caution)
                case .todo: Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5); Text("\(n)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let note { Text("· " + note).font(.system(size: 12)).foregroundStyle(face.caution) }
                }
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(Color.secondary).lineLimit(2) }
                extra()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) { if n > 1 { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) } }
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

    /// Cancel on the left, Create on the right. When that doesn't fit one line (the steps panel in a narrow column), the buttons go on a line of their own
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
            .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.discarding || windowBusy).fixedSize()
    }

    /// The error, else (in the window-wide bar) what comes next.
    @ViewBuilder private func actionNote(hint: Bool) -> some View {
        if let e = error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
        else if hint { Text(nextHint).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
    }

    /// The one key at the foot: Create, in every case. Signing in is the Account card's (its Sign in key), the
    /// window's keys are its step's: no key here repeats one. Create waits only on what the profile needs: its Claude Code
    /// folder (made by Sign in) and, with its own window, that window's folder (step 2); a sign-in still to do can follow
    /// from Settings, so the key is plain until the steps are done, green then.
    @ViewBuilder private var actionButtons: some View {
        let title = "Create"            // one word in every case (the Dock icon off too: the step above says what it does)
        // the one rule, the model's too (NewAccountSetup.canFinish)
        let can = NewAccountSetup.canFinish(draft, accounts: model.accounts, discarding: model.discarding, windowBusy: windowBusy)
        if current == 3 {
            Button(title) { model.finishNew(windowBusy: windowBusy) }.buttonStyle(.primaryKey(compact: true)).disabled(!can)
        } else {
            Button(title) { model.finishNew(windowBusy: windowBusy) }.buttonStyle(.pill(go, compact: true)).disabled(!can)
                .help(!made ? "Sign in first, in Account." : windowDue ? "Set up the Claude window first, or turn it off." : "Sign-in can be finished later from Settings.")
        }
    }

    private var nextHint: String {
        switch current {
        case 1:
            if let w = signInWait { return w.replacingOccurrences(of: " first.", with: " next.") }
            return waiting ? "Finish signing in in the browser." : "Sign in from Account next."
        case 2:
            if windowDue { return monitor.failed ? "Which Claude runs couldn't be checked. Check again." : windowHeld ? "Quit the desktop app, or continue anyway." : "Set up the Claude window next." }
            return desktop == .different ? "Its Claude window uses another account." : "Sign in to the Claude window next."
        default: return draft.usageInDock ? "Add the Dock icon next." : "Start reading usage next."
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
