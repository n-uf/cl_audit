// Settings: the Settings page of the cl_audit window. Accounts across the top; the selected account's
// settings in three columns of compact cards. Changes are saved as you make them; only a new name or
// label, or adding and removing accounts, needs Apply (that installs, renames or removes icon apps).

import AppKit
import Combine
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var accounts: [AccountEntry] { didSet { scheduleSave() } }
    @Published var selection: String? {
        didSet {
            guard oldValue != selection else { return }
            if note != nil { hideNote() }
            unsaved = nil            // why another profile's name or label wasn't saved
        }
    }
    static let dashboardID = "__dashboard__"
    @Published var message = ""
    @Published var tick = 0                 // bumped every few seconds so icon status re-reads
    /// "Sign in to another account…" (profile ▸ Claude Code ▸ Login): which profile, the address it signs in as, and
    /// since when Terminal shows Claude Code's sign-in (nil: the address is still being typed).
    struct AccountSwitch: Equatable { let id: String; var email: String; var started: Date? }
    @Published var accountSwitch: AccountSwitch?
    private(set) var saved: [AccountEntry]
    var configFolders: [FolderChoice] { Detect.configFolders() }
    var dataFolders: [FolderChoice] { Detect.desktopDataFolders() }
    // MARK: Claude Code on this Mac (ClaudeLocator.swift)

    /// The `claude` found (nil: none yet, see `claudeLooked`). The first value is only 26.11.1's own places (no process
    /// run, never the Claude app's copy); the full look (login shell, Volta, nvm, npm, the app's copy) follows off the
    /// main thread and replaces it. Looked for again when the window comes to the front, on "Check again", before a
    /// sign-in and, only while the first-run page or an "isn't installed" note is on screen, every few seconds (backing
    /// off to a minute).
    @Published private(set) var claude: ClaudeFound? = ClaudeLocator.find(quick: true)
    /// Its version, once `claude --version` has answered.
    @Published private(set) var claudeVersion: String?
    /// A full look (shell and npm too) has finished at least once since the window opened: until then nil only means
    /// "not known yet", never "not installed".
    @Published private(set) var claudeLooked = false
    /// The install help (a sheet, or the first-run page's step 1) is asked for.
    @Published var installHelp = false
    var claudePath: String? { claude?.path }
    /// A full look is done and found nothing: the only state in which cl_audit says Claude Code isn't installed.
    var claudeKnownMissing: Bool { claude == nil && claudeLooked }
    private var claudeBusy = false
    private var claudeAt = Date.distantPast
    private var claudeMisses = 0
    /// Looks again at most this often unless asked to.
    static let claudeEvery: TimeInterval = 3
    /// "Isn't installed" notes on screen right now (ClaudeMissingLine counts itself in and out), and whether the window
    /// shows Settings (set by the window): the periodic look runs only while one of them is up.
    var claudeNotes = 0
    var windowShowsSettings: () -> Bool = { true }

    /// Looks for `claude` off the main thread (throttled unless `force`) and publishes what it finds. The version comes
    /// with it, from `claude --version`, when the program is new.
    func detectClaude(force: Bool = false, then done: (() -> Void)? = nil) {
        guard !claudeBusy, force || Date().timeIntervalSince(claudeAt) >= Self.claudeEvery else { return }
        claudeBusy = true; claudeAt = Date()
        if force { claudeMisses = 0 }
        let had = (claude, claudeVersion)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = ClaudeLocator.find()
            let version: String? = found.flatMap { f in f == had.0 && had.1 != nil ? had.1 : ClaudeLocator.version(of: f.path) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.claudeBusy = false
                if self.claude != found { self.claude = found }
                if self.claudeVersion != version { self.claudeVersion = version }
                if !self.claudeLooked { self.claudeLooked = true }
                if found == nil || found?.fromApp == true { self.claudeMisses += 1 } else { self.claudeMisses = 0 }
                done?()
            }
        }
    }

    /// Right before a sign-in: the `claude` already found, if it is still there. Otherwise 26.11.1's own places (file
    /// lookups only) and a full look off the main thread; never the Claude app's copy from a quick look, and never a
    /// guess before the full look is done. The app's copy found by a full look yields to a real install as soon as one
    /// shows in 26.11.1's places.
    func claudeNow() -> String? {
        if let c = claude, ClaudeLocator.isExecutable(c.path) {
            guard c.fromApp, let real = ClaudeLocator.find(quick: true) else { return c.path }
            claude = real; claudeVersion = nil
            detectClaude(force: true)
            return real.path
        }
        let f = ClaudeLocator.find(quick: true)
        if claude != f { claude = f }
        detectClaude(force: true)             // the full look follows (login shell, Volta, nvm, npm, the app's copy)
        return f?.path
    }

    /// A sign-in action's `claude`: nil says why. Before the first full look is done it says it is still looking; once it
    /// is, "isn't installed" with the install help (a sheet; on the first-run page its step 1).
    func requireClaude() -> String? {
        if let p = claudeNow() { return p }
        message = noClaudeWhy
        if claudeLooked { showInstallHelp() }
        return nil
    }

    /// Why there is no `claude` to sign in with, in a line: still looking, or not installed (with its Install…).
    var noClaudeWhy: String { claudeLooked ? ClaudeInstall.missingInstall : "Still looking for Claude Code… try again in a moment" }

    func showInstallHelp() { if selection != Self.firstRunID { installHelp = true } }

    /// Every few seconds (the timer): a `claude` that went away is dropped. Looking again, while it is missing (or only
    /// the Claude app's copy and the first-run page is up), runs only while the first-run page, an "isn't installed" note
    /// or the install help is on screen in a shown window, and backs off: 3 s, 6, 12, 24, 48, then once a minute.
    func watchClaude() {
        if let c = claude, !ClaudeLocator.isExecutable(c.path) { claude = ClaudeLocator.find(quick: true); claudeVersion = nil }
        let wanted = claude == nil || (claude?.fromApp == true && isFirstRun)
        let onScreen = (isFirstRun && selection == Self.firstRunID) || claudeNotes > 0 || installHelp
        guard wanted, onScreen, windowShowsSettings() else { claudeMisses = 0; return }
        let wait = min(60, Self.claudeEvery * pow(2, Double(claudeMisses)))
        guard Date().timeIntervalSince(claudeAt) >= wait else { return }
        detectClaude()
    }
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?

    /// "What this does now", after a change to a setting without a picture of its own.
    @Published var note: SettingNote?
    private var noteHide: DispatchWorkItem?
    private var noteHovered = false
    private var emailsWatch: AnyCancellable?
    private var storeWatch: NSObjectProtocol?

    /// The file as saved elsewhere, with this window's own unsaved changes kept on top.
    func takeInOutsideChanges() {
        let fresh = Store.load()
        guard !fresh.isEmpty, fresh != saved else { return }     // our own save, or nothing new
        let merged = Self.merge(base: saved, local: accounts, remote: fresh)
        saved = fresh
        if merged != accounts { accounts = merged; refreshFirstRun() }
        if !isValid(selection) { selection = homeSelection }
    }

    /// Three-way merge by profile id: the file now (`remote`) plus what changed here (`local`) since the last load
    /// or save (`base`): edited or added here wins, removed here stays removed, everything else is as in the file.
    /// Order: this window's, then profiles added elsewhere.
    static func merge(base: [AccountEntry], local: [AccountEntry], remote: [AccountEntry]) -> [AccountEntry] {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let localIDs = Set(local.map(\.id))
        var out: [AccountEntry] = []
        for e in local {
            if let b = baseByID[e.id], b == e {
                if let r = remoteByID[e.id] { out.append(r) }        // untouched here: the file's version, or gone
            } else if let b = baseByID[e.id], let r = remoteByID[e.id], b.iconHidden == e.iconHidden, r.iconHidden != b.iconHidden {
                var m = e; m.iconHidden = r.iconHidden; out.append(m) // edited here, but Usage in the Dock changed there
            } else {                                                  // (the agent recording a Dock icon dragged out)
                out.append(e)                                         // edited or added here
            }
        }
        for r in remote where !localIDs.contains(r.id) && baseByID[r.id] == nil { out.append(r) }   // added elsewhere
        return out
    }

    /// Saves this window's changes merged into the file as it is now (never an older copy over newer changes).
    private func saveMerged() throws {
        let merged = try Store.edit { remote in Self.merge(base: saved, local: accounts, remote: remote) }
        saved = merged
        if merged != accounts { accounts = merged }
    }

    func showNote(_ n: SettingNote) {
        withAnimation(.easeOut(duration: 0.18)) { note = n }
        scheduleNoteHide()
    }
    func hideNote() {
        noteHide?.cancel()
        withAnimation(.easeIn(duration: 0.15)) { note = nil }
    }
    func hoverNote(_ on: Bool) {
        noteHovered = on
        if on { noteHide?.cancel() } else { scheduleNoteHide() }
    }
    private func scheduleNoteHide() {
        noteHide?.cancel()
        guard !noteHovered else { return }
        let w = DispatchWorkItem { [weak self] in self?.hideNote() }
        noteHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }

    init() {
        saved = Store.load()
        // No profiles is no profile: a fresh install gets the first-run page (FirstRun.swift), not an automatic "main"
        accounts = saved
        isFirstRun = FirstRun.needed(saved)          // decided here and at the events below, not on every redraw
        selection = isFirstRun ? Self.firstRunID : Self.dashboardID
        firstRun.color = TileColor.accents.first ?? .purple
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick += 1
            self.linkSeats()
            self.followSwitch()
            self.followFirstRun()
            self.watchClaude()
        }
        if Self.followsDock { detectClaude(force: true) }
        // after the change, not inside it: an animated note started while the window is redrawing for the
        // change itself left the Emails key and the cards showing the old state
        // saved elsewhere (the agent recording a Dock icon dragged out by hand): take it in at once, so this copy never
        // saves an older one over it
        storeWatch = DistributedNotificationCenter.default().addObserver(forName: Store.changed, object: nil, queue: .main) { [weak self] _ in
            self?.takeInOutsideChanges()
        }
        emailsWatch = Privacy.shared.$show.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.showNote(SettingNotes.emails(on)) }
    }

    /// Off in offscreen renders, which must never save.
    static var followsDock = true

    /// Profiles not linked to a Claude account seat yet get the one their folder is signed in to (one profile per
    /// seat: see FolderRules.linkSeats). Saved like any other change; only cl_audit does this.
    func linkSeats() {
        guard Self.followsDock, !isFirstRun, !needsApply, problem == nil else { return }   // not under the first-run page
        let linked = FolderRules.linkStandbySeats(FolderRules.linkSeats(accounts))
        if linked != accounts { accounts = linked }
    }

    /// Starts "Sign in to another account…" for a profile: the New account row, with an address picked in the Login
    /// pop-up already filled in (picking one only fills in the sign-in; no sign-in is ever copied between folders).
    func askSwitch(_ id: String, email: String = "") { accountSwitch = AccountSwitch(id: id, email: email, started: nil) }

    /// Sign in: Terminal runs Claude Code's own sign-in for the profile's folder with the address filled in
    /// (`claude auth login --claudeai --email`); cl_audit then waits for the folder's .claude.json to name the new
    /// account (followSwitch). Returns why it can't start, or nil.
    func beginSwitch() -> String? {
        guard var s = accountSwitch, let e = accounts.first(where: { $0.id == s.id }) else { return nil }
        let email = s.email.trimmingCharacters(in: .whitespaces)
        guard email.contains("@"), !email.hasPrefix("@"), !email.hasSuffix("@") else { return "Type the account's email address." }
        if let owner = accounts.first(where: { $0.id != e.id && ($0.seat?.email ?? Account.expectedEmail(configDir: $0.configDir))?.lowercased() == email.lowercased() }) {
            return "That's the account of “\(owner.name)”. One profile per account."
        }
        guard let claude = requireClaude() else { return noClaudeWhy }
        guard ClaudeCLI.openLogin(claude, account: Account(e), email: email) else { return "Terminal didn't open." }
        s.email = email; s.started = Date()
        accountSwitch = s
        return nil
    }

    func cancelSwitch() { accountSwitch = nil }

    /// A switch started here: as soon as the folder's .claude.json names another account than the profile's, the
    /// profile is linked to it by itself (no second question), unless another profile has it; then the card says
    /// which. Gives up after an hour.
    func followSwitch() {
        guard let s = accountSwitch, let started = s.started else { return }
        guard let e = accounts.first(where: { $0.id == s.id }), Date().timeIntervalSince(started) < 3600 else {
            accountSwitch = nil; return
        }
        guard let move = FolderRules.seatMove(e, among: accounts) else {
            // not linked yet (a new profile's first sign-in): linkSeats links it; nothing to wait for then
            if e.seat == nil, Account.signedInSeat(configDir: e.configDir) != nil { accountSwitch = nil }
            return
        }
        accountSwitch = nil
        if move.owner == nil { relink(e.id) }
    }

    /// "Use this account": links the profile to the account its Claude Code folder is signed in to now; its name, look,
    /// Dock icon, Claude window and settings stay (FolderRules.relink). Refused, with a note, when another profile
    /// has that account. Saved like any other change.
    @discardableResult
    func relink(_ id: String) -> Bool {
        guard Self.followsDock, !needsApply, problem == nil else { return false }
        guard let out = FolderRules.relink(id, in: accounts) else {
            if let e = accounts.first(where: { $0.id == id }), let owner = FolderRules.seatMove(e, among: accounts)?.owner {
                message = "“\(owner.name)” already uses that account"
            }
            return false
        }
        accounts = out
        return true
    }

    /// Picks up changes made elsewhere (e.g. an icon's own Options menu) when nothing is pending here.
    func reloadIfClean() {
        guard !needsApply else { return }
        let fresh = Store.load()
        if !fresh.isEmpty, fresh != accounts { saved = fresh; accounts = fresh; refreshFirstRun() }
        if !isValid(selection) { selection = homeSelection }
    }

    /// The page a window opens on: the first-run page while there is no profile yet, else the Dashboard tile.
    var homeSelection: String { isFirstRun ? Self.firstRunID : Self.dashboardID }

    /// A selection that still points at something: an account, the Dashboard tile, or a new account being set up.
    func isValid(_ id: String?) -> Bool {
        (id == Self.firstRunID && isFirstRun) || (id == Self.dashboardID && !isFirstRun)
            || (id == Self.newID && draft != nil) || (id == Self.switchID && switchTarget != nil)
            || (id == Self.restoreID && restoreTarget != nil)
            || (id == Self.exportID && accounts.contains { $0.id == exportingProfile })
            || (id == Self.importID && accounts.contains { $0.id == importingProfile })
            || accounts.contains { $0.id == id }
    }

    /// The Switch page (Switch.swift): which profile and which of its standby accounts ("<profile>~<id>").
    @Published var switching: String?
    static let switchID = "__switch__"

    /// The profile and standby account the Switch page is about. Once a switch it runs has linked the profile to that
    /// account (it's no longer on standby), the page keeps showing it from the copy its runner took.
    var switchTarget: (entry: AccountEntry, standby: StandbyAccount)? {
        guard let k = switching, let p = SwitchOffer.parse(k), let e = accounts.first(where: { $0.id == p.profile }) else { return nil }
        if let s = e.standby.first(where: { $0.id == p.standby }) { return (e, s) }
        if let snap = runners[k]?.targetSnapshot, snap.id == p.standby { return (e, snap) }
        return nil
    }
    /// The switches started from the page, by "<profile>~<standby account>" (SwitchRunner.swift).
    private var runners: [String: SwitchRunner] = [:]

    func runner(_ e: AccountEntry, _ s: StandbyAccount) -> SwitchRunner {
        let k = AccountEntry.standbyStatusID(e.id, s.id)
        if let r = runners[k] { return r }
        let r = SwitchRunner(profile: e.id, standby: s.id, model: self)
        runners[k] = r
        return r
    }

    /// The switch of this profile to show beside its tile: one that's running, else the one on the Switch page.
    func switchRunner(of profile: String) -> SwitchRunner? {
        if let r = runners.values.first(where: { $0.profile == profile && $0.isRunning }) { return r }
        if let k = switching, SwitchOffer.parse(k)?.profile == profile, let r = runners[k] { return r }
        return nil
    }

    /// A switch of this profile that stopped half way (from its receipts; looked at again at most every 10 s, and at
    /// once after a switch moves on).
    func unfinishedSwitch(of profile: String, now: Date = Date()) -> SwitchReceipt? {
        if now.timeIntervalSince(unfinishedLook.at) > 10 {
            unfinishedLook = (now, Dictionary(SwitchEngine.receipts().filter(\.unfinished).map { ($0.profile, $0) }, uniquingKeysWith: { a, _ in a }))
        }
        return unfinishedLook.byProfile[profile]
    }
    private var unfinishedLook: (at: Date, byProfile: [String: SwitchReceipt]) = (.distantPast, [:])
    /// Bumped each time a switch changes phase: what shows a profile's backups looks again (a finished switch has made one).
    @Published private(set) var switchChanges = 0
    func forgetUnfinished() { unfinishedLook.at = .distantPast; switchChanges += 1 }

    // MARK: the Restore page (SessionsRestore.swift, RestoreRunner.swift, RestorePage.swift)

    /// Which backup the Restore page is about.
    @Published var restoring: RestoreKey?
    static let restoreID = "__restore__"

    var restoreTarget: (entry: AccountEntry, key: RestoreKey)? {
        guard let k = restoring, let e = accounts.first(where: { $0.id == k.profile }) else { return nil }
        return (e, k)
    }
    private var restoreRunners: [String: RestoreRunner] = [:]

    func restoreRunner(_ k: RestoreKey) -> RestoreRunner {
        if let r = restoreRunners[k.id] { return r }
        let r = RestoreRunner(key: k, model: self)
        restoreRunners[k.id] = r
        return r
    }

    /// The restore of this profile to show beside its tile: one that's running, else the one on the Restore page.
    func restoreRunner(of profile: String) -> RestoreRunner? {
        if let r = restoreRunners.values.first(where: { $0.key.profile == profile && $0.isRunning }) { return r }
        if let k = restoring, k.profile == profile, let r = restoreRunners[k.id] { return r }
        return nil
    }

    /// A restore of this profile that stopped half way (from its receipts, looked at again at most every 10 s).
    func unfinishedRestore(of profile: String, now: Date = Date()) -> SessionsRestore.Receipt? {
        if now.timeIntervalSince(restoreLook.at) > 10 {
            restoreLook = (now, Dictionary(SessionsRestore.unfinished().map { ($0.profile, $0) }, uniquingKeysWith: { a, _ in a }))
        }
        return restoreLook.byProfile[profile]
    }
    private var restoreLook: (at: Date, byProfile: [String: SessionsRestore.Receipt]) = (.distantPast, [:])
    func forgetRestore() { restoreLook.at = .distantPast; switchChanges += 1 }

    /// Opens the Restore page for a backup. One that ended (restored, undone) starts over when asked for again, unless
    /// it is in front.
    func showRestore(_ k: RestoreKey) {
        // one restore of a profile runs at a time: while one does, every way to the Restore page leads to it
        if let r = restoreRunners.values.first(where: { $0.key.profile == k.profile && $0.isRunning && $0.key != k }) {
            restoring = r.key
            selection = restoreTarget == nil ? Self.dashboardID : Self.restoreID
            return
        }
        if let r = restoreRunners[k.id], r.phase == .done || r.phase == .undone, !(selection == Self.restoreID && restoring == k) {
            restoreRunners[k.id] = nil
        }
        restoring = k
        selection = restoreTarget == nil ? Self.dashboardID : Self.restoreID
    }

    /// The page for a restore that stopped half way: to finish it or undo it.
    func showRestore(finishing r: SessionsRestore.Receipt) {
        showRestore(RestoreKey(profile: r.profile, backup: r.backup, place: r.backupPlace, resume: r.id))
    }

    // MARK: the Export and Import pages (ExportPage.swift, ImportPage.swift)

    /// The profile whose Export page, or Import page, is open.
    @Published var exportingProfile: String?
    @Published var importingProfile: String?
    static let exportID = "__export__", importID = "__import__"
    private var exportRunners: [String: ExportRunner] = [:]
    private var importRunners: [String: ImportRunner] = [:]

    /// The model the Export and Import pages belong to, for cl_audit quitting (applicationWillTerminate).
    nonisolated(unsafe) static weak var current: SettingsModel?

    /// cl_audit is quitting: every page lets go of its password and is told to stop; nothing is removed here. What was unpacked goes
    /// in SessionsImport.shutDown (off the main thread, two seconds at most; the next launch's sweep takes the rest), which also
    /// stops the tools and detaches an attached image. The quit hook calls this, then that.
    func leaveArchiveWork() {
        for r in exportRunners.values { r.leave() }
        for r in importRunners.values { r.quit() }
    }

    func exportRunner(for profile: String) -> ExportRunner {
        Self.current = self
        if let r = exportRunners[profile] { return r }
        let r = ExportRunner(profile: profile, model: self)
        exportRunners[profile] = r
        return r
    }

    func importRunner(for profile: String) -> ImportRunner {
        Self.current = self
        if let r = importRunners[profile] { return r }
        let r = ImportRunner(profile: profile, model: self)
        importRunners[profile] = r
        return r
    }

    /// Export… : a fresh page, unless an export of the profile is under way (then that one).
    func showExport(_ profile: String) {
        if let r = exportRunners[profile], !r.isWorking { r.leave(); exportRunners[profile] = nil }
        exportingProfile = profile
        selection = Self.exportID
    }

    /// Import… : a fresh page, unless an import of the profile is under way (then the Restore page's steps).
    func showImport(_ profile: String) {
        if let r = importRunners[profile] {
            // one that was committed is its restore's page: it stays while that restore runs, else it starts over
            var busy = false
            if case .running(let k) = r.phase { busy = restoreRunners[k.id]?.isRunning ?? false }
            if !busy { r.leave(); importRunners[profile] = nil }
        }
        importingProfile = profile
        selection = Self.importID
    }

    /// Every running switch that waits for the operator and is worth an alert (SwitchWaiting.swift), in key order: where it
    /// waits, its profile's name, how many steps it has, and whether the profile's alerts are on. The window's sign-in of a
    /// profile without a Claude window, and the Return step before the session is open or after its link missed, are left out.
    var waitingSwitches: [SwitchWaiting.Waiting] {
        runners.values.compactMap { r -> SwitchWaiting.Waiting? in
            guard SwitchWaiting.waits(r.phase) else { return nil }
            let e = accounts.first { $0.id == r.profile }
            guard SwitchWaiting.alertable(phase: r.phase, hasWindow: e?.claudeWindow ?? false,
                                          linkSent: r.sidebarLinkSent, missed: r.sidebarMissed) else { return nil }
            return SwitchWaiting.Waiting(step: SwitchWaiting.Step(key: r.key, phase: r.phase), name: e?.name ?? "",
                                         steps: r.stepCount, notify: e?.notify ?? false)
        }.sorted { $0.step.key < $1.step.key }
    }

    /// The alert's Cancel switch: the runner's cancel, only while Claude Code's sign-in waits (nothing to cancel after).
    func cancelWaitingSwitch(_ key: String) {
        if let r = runners[key], SwitchWaiting.canCancel(r.phase) { r.cancel() }
    }

    func showSwitch(_ key: String) {
        var key = key
        // a click on the Dock icon (or the menu bar) while a restore holds the window closed (SwitchMarker "restore"): its page
        if let p = SwitchOffer.parse(key), p.standby.hasPrefix("restore-") {
            if let r = restoreRunners.values.first(where: { $0.key.profile == p.profile && $0.isRunning }) { showRestore(r.key) }
            else if let u = unfinishedRestore(of: p.profile) { showRestore(finishing: u) }
            else { selection = Self.dashboardID }
            return
        }
        if let p = SwitchOffer.parse(key) {
            // one switch of a profile at a time: while one runs, its page is the one shown
            if let r = runners.values.first(where: { $0.profile == p.profile && $0.isRunning }) { key = r.key }
            // a switch that ended (done, or cancelled and put back) starts over when asked for again, unless it's in front
            else if let r = runners[key], r.phase == .done || r.phase == .cancelled, !(selection == Self.switchID && switching == key) {
                runners[key] = nil
            }
        }
        switching = key
        // a ready runner handed out here is an ordinary switch: an Undo this switch… that was abandoned leaves none of its
        // banner, sixth step or preselected answer behind (showUndoSwitch sets them again after this)
        // (a runner that failed or was cancelled forgets it too, or a later ordinary switch would show it and record it)
        if let r = runners[key], !r.isRunning, r.phase != .done, r.undoes != nil {      // a done one on its page in front keeps its keys
            r.undoes = nil
            if r.phase == .ready, r.receipt == nil { r.moveSessions = nil }
        }
        selection = switchTarget == nil ? Self.dashboardID : Self.switchID
    }

    /// "Undo this switch…": the Switch page the other way, which says it also puts back from the backup the switch made
    /// (when it made one and moved the sessions), preselecting that the sessions follow.
    func showUndoSwitch(_ done: SwitchReceipt, key: String) {
        showSwitch(key)
        guard let t = switchTarget else { return }
        let r = runner(t.entry, t.standby)
        guard !r.isRunning, r.receipt == nil, let b = done.backup else { return }
        r.undoes = SwitchRunner.SwitchUndo(receipt: done.id, backup: b, place: done.backupPlace ?? BackupPrefs.placeURL.path)
        r.moveSessions = true
    }

    /// Settings opened from inside the app: the Dashboard tile, unless a new account is being set up.
    func openDefault() {
        reloadIfClean()
        if !(selection == Self.newID && draft != nil) { selection = homeSelection }
    }

    /// What an icon app is made of (which apps exist, their names and labels). Changing it needs Apply.
    static func structure(_ list: [AccountEntry]) -> [String] { list.map { "\($0.id)|\($0.name)|\($0.label)" } }
    var needsApply: Bool { Self.structure(accounts) != Self.structure(saved) || (saved.isEmpty && !accounts.isEmpty) }

    /// Everything else is saved a moment after it changes, and the running icons follow it right away.
    private func scheduleSave() {
        saveWork?.cancel()
        guard !needsApply, problem == nil, accounts != saved else { return }
        autosaving = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autosaving = false
            guard !self.needsApply, self.problem == nil else { return }
            do {
                try self.saveMerged(); self.message = "Saved"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in   // a brief confirmation
                    if self?.message == "Saved" { self?.message = "" }
                }
            }
            catch { self.message = "Couldn't save: \(error.localizedDescription)" }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    var problem: String? {
        for a in accounts { if let p = a.problem { return "\(a.name.isEmpty ? "New profile" : a.name): \(p)" } }
        let names = accounts.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if Set(names).count != names.count { return "Two profiles have the same name." }
        return FolderRules.clash(in: accounts)          // one account per Claude Code folder and per window
    }

    func binding(_ id: String) -> Binding<AccountEntry>? {
        guard accounts.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.accounts.first { $0.id == id } ?? AccountEntry(id: id, name: "", label: "", configDir: "") },
            set: { new in
                guard let i = self.accounts.firstIndex(where: { $0.id == id }) else { return }
                let old = self.accounts[i]
                self.accounts[i] = new
                if let n = SettingNotes.note(from: old, to: new) { self.showNote(n) }
            })
    }

    func add() {
        var n = accounts.count + 1
        while accounts.contains(where: { $0.name == "profile \(n)" }) { n += 1 }
        let name = "profile \(n)"
        let id = Store.newID(from: name, taken: accounts.map(\.id))
        let used = Set(accounts.map { expand($0.configDir) })     // suggest a settings folder no account uses yet
        let folder = configFolders.first { !used.contains(expand($0.path)) }?.path ?? ""
        accounts.append(AccountEntry(id: id, name: name, label: "ACC\(n)", configDir: folder))
        selection = id
    }

    /// A new account being set up from scratch (the "New profile" tile), not yet in `accounts`.
    @Published var draft: NewAccountDraft?
    static let newID = "__new__"

    /// The first-run page (FirstRun.swift): shown while no profile exists (or only the "main" an older version made by
    /// itself, never signed in); what has been picked there so far.
    static let firstRunID = "__firstrun__"
    @Published var firstRun = FirstRunDraft()
    /// Decided when the window loads and when the profiles change here (removed, loaded from the file, Done), never on a
    /// redraw: a briefly unreadable ~/.claude.json can't flip Settings to this page, and a sign-in landing in ~/.claude
    /// from the page keeps it until Done.
    @Published private(set) var isFirstRun = false
    func refreshFirstRun() {
        let now = FirstRun.needed(accounts, signedInCounts: !isFirstRun)
        if now != isFirstRun { isFirstRun = now }
    }

    func startNew() {
        if draft == nil {
            var d = NewAccountDraft()
            let used = Set(accounts.map(\.color))
            d.color = TileColor.accents.first { !used.contains($0) } ?? .purple
            d.template = accounts.first(where: { $0.id == selection }) ?? accounts.first
            d.standardTaken = FolderRules.windowOwner(.standard, FolderKey.standardDataDir, among: accounts) != nil
            draft = d
        }
        selection = Self.newID
    }

    /// Cancels the new account and removes what its setup created (after the page has asked).
    @Published var discarding = false
    func cancelNew() {
        guard let d = draft else { return }
        guard d.started else { draft = nil; selection = accounts.first?.id; return }
        discarding = true
        DispatchQueue.global(qos: .userInitiated).async {
            // a full look, here: the sign-out must run with the `claude` that is really there, never with nothing
            // (that would delete the folder and orphan its sign-in in the Keychain)
            NewAccountSetup.discard(d, claude: ClaudeCLI.find())
            DispatchQueue.main.async {
                self.discarding = false
                self.draft = nil
                self.selection = self.accounts.first?.id
                self.message = "Cancelled \(d.name.isEmpty ? "the new profile" : d.name); its folders and login were removed"
            }
        }
    }

    /// Adds the new account and installs its Dock icon.
    func finishNew() {
        guard let d = draft else { return }
        var e = d.entry
        // linked to the seat its folder is signed in to (Finish is refused while another profile has that seat)
        if var s = Account.signedInSeat(configDir: e.configDir), FolderRules.seatOwner(s, among: accounts) == nil {
            s.linkedAt = Date(); e.seat = s
        }
        accounts.append(e)
        draft = nil
        selection = d.entry.id
        apply()
        message = "Added \(d.name)"
    }

    /// The account waiting for "Remove" to be confirmed.
    @Published var pendingRemoval: AccountEntry?

    func askRemove(_ id: String) { pendingRemoval = accounts.first { $0.id == id } }

    /// Drops the account and applies at once: Installer.sync quits and deletes its icon app and everything macOS
    /// keeps for it. Then its Terminal scripts go and, if asked, its folders (signed out first). Other changes
    /// waiting for Apply are applied with it.
    func removeAccount(_ e: AccountEntry, deleteFolders: Bool) {
        remove(e.id)
        var hidden = UserDefaults.standard.stringArray(forKey: "dashboardHidden") ?? []
        hidden.removeAll { $0 == e.id }
        UserDefaults.standard.set(hidden, forKey: "dashboardHidden")
        apply {
            self.message = deleteFolders ? "Removed \(e.name); deleting its folders…" : "Removed \(e.name)"
            DispatchQueue.global(qos: .userInitiated).async {
                // a full look, here: the sign-out must run with the `claude` that is really there (see cancelNew)
                let failed = deleteFolders ? AccountRemoval.deleteFolders(e, claude: ClaudeCLI.find()) : []
                AccountRemoval.removeScripts(e.configDir)
                DispatchQueue.main.async {
                    self.message = !failed.isEmpty ? "Removed \(e.name), but couldn't delete " + failed.joined(separator: ", ")
                        : deleteFolders ? "Removed \(e.name) and deleted its folders" : "Removed \(e.name); its folders are kept"
                }
            }
        }
    }

    func remove(_ id: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts.remove(at: i)
        refreshFirstRun()
        if isFirstRun { selection = Self.firstRunID }       // the last profile is gone: Set up cl_audit again
        else if selection == id { selection = accounts.isEmpty ? Self.firstRunID : accounts[max(0, i - 1)].id }
    }

    func revert() {
        accounts = saved.isEmpty ? accounts : saved
        refreshFirstRun()
        if !accounts.contains(where: { $0.id == selection }) { selection = accounts.first?.id }
        message = ""
    }

    /// A name or label edit being saved (its Dock icon app is renamed or rebuilt), why the last one couldn't be,
    /// and what the last one did, for the top strip's display.
    @Published var saving = false
    @Published var unsaved: String?
    @Published var savedNote: String?
    private var savedNoteClear: DispatchWorkItem?

    /// A setting just changed and is about to be saved (a moment after the change).
    @Published var autosaving = false

    /// "Saved · <what>" in the main display for a moment, then the profile's state again.
    func showSaved(_ what: String, for seconds: Double = 2) {
        savedNote = what
        savedNoteClear?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.savedNote = nil }
        savedNoteClear = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// Saves a name or label change at once (no Apply): the Dock icon apps follow, then the display says so.
    func saveNow(_ what: String) {
        saving = true
        unsaved = nil
        apply { [weak self] in
            guard let self else { return }
            self.saving = false
            self.showSaved(what)
        }
    }

    /// The profile whose Usage in the Dock was just switched, until the Dock really has its icon in or out: the main
    /// display says "Restarting the Dock…" and the profile keys wait, so quick flips can't start changes that undo
    /// each other.
    @Published var dockRestarting: String?
    /// A Usage in the Dock change that didn't get done: why, for its switch (taken once, by dockProgress).
    private var dockFailed: [String: String] = [:]
    private var dockWatch: Timer?
    /// How long the agent gets to install or remove a Dock icon and restart the Dock (a busy Mac is slow).
    static let dockLimit: TimeInterval = 90

    /// Usage in the Dock: on, a Dock icon in the Dock; off, none. The agent does it (off: it quits, unpins and removes
    /// the Dock icon app, remembering its place; on: it pins it back there and starts it) and reads the usage either
    /// way; this saves the switch and, turning it on, installs the app. The profile's settings are kept either way.
    func setUsageInDock(_ id: String, _ on: Bool) {
        guard dockRestarting == nil, let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let before = accounts[i]
        accounts[i].iconHidden = !on
        if let n = SettingNotes.note(from: before, to: accounts[i]) { showNote(n) }
        let e = accounts[i]
        DockManager.markChange(Installer.appURL(e))
        dockLog.log("\(e.id, privacy: .public): Usage in the Dock \(on ? "on" : "off", privacy: .public)")
        if on && !FileManager.default.fileExists(atPath: Installer.appURL(e).path) { apply() }   // no app yet: install it
        dockRestarting = id
        dockFailed[id] = nil
        // done when the Dock really has it (its app there and pinned) or really hasn't (app gone, unpinned, quit);
        // not done in time: put the setting back, so the agent puts the Dock back as it was
        let since = Date()
        dockWatch?.invalidate()
        dockWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self, self.dockRestarting == id, let e = self.accounts.first(where: { $0.id == id }) else { t.invalidate(); return }
            if Self.dockSettled(e, on) {
                t.invalidate()
                self.dockRestarting = nil
                self.showSaved("Usage in the Dock \(on ? "on" : "off")")
            } else if Date().timeIntervalSince(since) > Self.dockLimit {
                t.invalidate()
                self.dockRestarting = nil
                self.dockFailed[id] = Self.dockWhy(on)
                dockLog.log("\(id, privacy: .public): Usage in the Dock \(on ? "on" : "off", privacy: .public) not done in \(Int(Self.dockLimit), privacy: .public) s, put back")
                if let i = self.accounts.firstIndex(where: { $0.id == id }) { self.accounts[i].iconHidden = on }
            }
        }
    }

    /// Usage in the Dock's change really done: on, its app is there and pinned (the agent starts it too); off, its
    /// app is gone, unpinned and not running.
    static func dockSettled(_ e: AccountEntry, _ on: Bool) -> Bool {
        let app = Installer.appURL(e)
        let there = FileManager.default.fileExists(atPath: app.path)
        if on { return there && DockManager.isPinned(app) }
        return !there && !Installer.isRunning(e) && !DockManager.isPinned(app)
    }

    /// Why, in words short enough for one line under the switch in a narrow column.
    static func dockWhy(_ on: Bool) -> String {
        if case .stopped = Agent.health() { return "The agent isn't running" }
        return on ? "Not in the Dock after \(Int(dockLimit)) s" : "Still in the Dock after \(Int(dockLimit)) s"
    }

    /// For Usage in the Dock's switch: how far its change has got.
    func dockProgress(_ id: String, _ on: Bool) -> SwitchProgress {
        if let why = dockFailed.removeValue(forKey: id) { return .failed(why) }
        return dockRestarting == id ? .working : .done
    }

    /// Claude window: on, the profile has a Claude window signed in to its account; off, none. Turning it off keeps
    /// the window's folder and sign-in, so turning it back on needs no new sign-in.
    func setClaudeWindow(_ id: String, _ on: Bool) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let before = accounts[i]
        accounts[i].claudeWindow = on
        if let n = SettingNotes.note(from: before, to: accounts[i]) { showNote(n) }
        let e = accounts[i]
        if on, e.desktop == .separate, !e.desktopDataDir.isEmpty {
            // a profile made without one gets its window's folder now (its sign-in comes with the first start)
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: expand(e.desktopDataDir)), withIntermediateDirectories: true)
        }
        showSaved("Claude window \(on ? "on" : "off")")
    }

    func apply(then done: (() -> Void)? = nil) {
        guard problem == nil else { return }
        do {
            try saveMerged()
            message = "Applying…"
            let list = accounts
            DispatchQueue.main.async {
                let log = Installer.sync(list)
                self.message = log.isEmpty ? "Icons are up to date" : log.joined(separator: ", ")
                DockManager.afterAccountsChanged(list)       // pins a new icon into the group, when managed
                done?()
            }
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// The choices for a picker, always including the current value.
    func choices(_ list: [FolderChoice], current: String) -> [FolderChoice] {
        if current.isEmpty || list.contains(where: { $0.path == current }) { return list }
        return list + [FolderChoice(path: current, detail: current.contains(".claude") ? Account.expectedEmail(configDir: current) : nil)]
    }
}

// MARK: - Page

struct SettingsPage: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.face) private var face

    @ObservedObject private var uninstall = UninstallUI.shared

    var body: some View {
        Group {
            if model.isFirstRun {
                // no profile yet: only the first-run page, no tiles to pick from
                GeometryReader { geo in
                    ScrollView { FirstRunPage(model: model, width: geo.size.width).padding(.horizontal, 16).padding(.vertical, 14) }
                }
            } else { page }
        }
        .sheet(item: $model.pendingRemoval) { e in RemoveAccountSheet(entry: e, model: model) }
        .sheet(isPresented: $uninstall.show) { UninstallSheet(model: model) }
        .sheet(isPresented: $model.installHelp) { ClaudeInstallSheet(model: model) }
    }

    var page: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        DashboardTile(selected: model.selection == SettingsModel.dashboardID)
                            .onTapGesture { model.selection = SettingsModel.dashboardID }
                        ProfileTiles(model: model)       // drag one to change the order (ProfileOrder.swift)
                        if model.draft != nil {
                            NewTile(selected: model.selection == SettingsModel.newID).onTapGesture { model.selection = SettingsModel.newID }
                        }
                        Button(action: model.startNew) {
                            TileKey(selected: false, leading: 0, trailing: 0) {
                                Image(systemName: "plus").font(.system(size: 15, weight: .light)).frame(width: 42)
                            }
                        }
                        .buttonStyle(PressableKey()).help("Add a profile")
                        ProfileOrderInfo()
                    }
                    .padding(.vertical, 3).padding(.horizontal, 2)
                }
                applyBar
            }
            .padding(8)
            .background(SurfaceShape(surface: face.strip, radius: 7))
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 2)
            if model.selection == SettingsModel.newID, model.draft != nil {
                // The add-account page scrolls itself, so its action bar can stay pinned at the bottom.
                NewAccountView(draft: Binding(get: { model.draft ?? NewAccountDraft() }, set: { model.draft = $0 }), model: model)
            } else { GeometryReader { geo in ScrollView {
                let w = geo.size.width - 32
                if model.selection == SettingsModel.dashboardID {
                    DashboardSettings(width: w).padding(.horizontal, 16).padding(.vertical, 14)
                } else if model.selection == SettingsModel.switchID, let t = model.switchTarget {
                    SwitchPage(entry: t.entry, standby: t.standby, model: model, runner: model.runner(t.entry, t.standby), width: w)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                } else if model.selection == SettingsModel.restoreID, let t = model.restoreTarget {
                    RestorePage(entry: t.entry, key: t.key, model: model, runner: model.restoreRunner(t.key), width: w)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                } else if model.selection == SettingsModel.exportID, let p = model.exportingProfile, let e = model.accounts.first(where: { $0.id == p }) {
                    ExportPage(entry: e, model: model, runner: model.exportRunner(for: p), width: w)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                } else if model.selection == SettingsModel.importID, let p = model.importingProfile, let e = model.accounts.first(where: { $0.id == p }) {
                    ImportPage(entry: e, model: model, runner: model.importRunner(for: p), width: w)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                } else if let id = model.selection, let entry = model.binding(id) {
                    // one identity per profile: switching tabs starts with fresh view state (a half-typed name, the
                    // Dock restart pulse, an open (i)), so nothing from one profile shows up, or is saved, on another
                    AccountSettings(entry: entry, model: model, width: w).id(id).padding(.horizontal, 16).padding(.vertical, 14)
                } else {
                    Text("Add a profile with ＋").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                }
            } }
            } // the setting note floats over the whole window (MainWindowView), so the Emails key shows it on the dashboard too
        }
    }

    /// The same page without scroll views, for rendering to an image (image rendering skips scroll views).
    var snapshot: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DashboardTile(selected: model.selection == SettingsModel.dashboardID)
                ProfileTiles(model: model)
                TileKey(selected: false, leading: 0, trailing: 0) { Image(systemName: "plus").font(.system(size: 15, weight: .light)).frame(width: 42) }
                ProfileOrderInfo()
                Spacer()
                applyBar
            }
            .padding(8)
            .background(SurfaceShape(surface: face.strip, radius: 7))
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 2)
            if model.selection == SettingsModel.dashboardID { DashboardSettings().padding(14) }
            else if let id = model.selection, let entry = model.binding(id) { AccountSettings(entry: entry, model: model).id(id).padding(14) }
        }
    }

    var applyBar: some View {
        HStack(spacing: 8) {
            // why a name or label wasn't saved, or what the last save did
            if let p = model.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(face.danger).font(.caption).lineLimit(2)
            } else if let u = model.unsaved {
                Label(u, systemImage: "exclamationmark.triangle.fill").foregroundStyle(face.danger).font(.caption).lineLimit(2)
            } else if !model.message.isEmpty {
                Text(model.message).font(.caption).foregroundStyle(face.muted).lineLimit(1)
            }
        }
        .fixedSize()
    }
}

/// "What this does now": the setting note after a change, floating at the bottom of the window on every page.
struct SettingNoteOverlay: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear.allowsHitTesting(false)
            if let n = model.note {
                SettingNoteBanner(note: n, hover: model.hoverNote, close: model.hideNote)
                    .id(n.id)
                    .padding(.horizontal, 16).padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

/// The main display in the window's top strip, by priority: a change in progress (saving, the Dock restarting, what
/// was just saved), then a problem, then what the selected profile is doing now.
struct SettingsStatus: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let w: CGFloat = 246, h = TopStrip.height
        let _ = model.tick                        // the profile's state is read again every few seconds
        Group {
            if model.saving || model.autosaving { DisplayWindow(text: "Saving…", tone: .amber, height: h, width: w) }
            else if model.dockRestarting != nil { DisplayWindow(text: "Restarting the Dock…", tone: .amber, height: h, width: w) }
            else if let done = model.savedNote { DisplayWindow(text: "Saved", dim: "· \(done)", tone: .ok, height: h, width: w) }
            else if model.unsaved != nil || model.problem != nil { DisplayWindow(text: "Not saved", dim: "· see below", tone: .warn, height: h, width: w) }
            else if model.selection == SettingsModel.newID { DisplayWindow(text: "New profile", dim: "· not added yet", height: h, width: w) }
            else if model.selection == SettingsModel.switchID { DisplayWindow(text: "Switch", dim: "· nothing changes yet", height: h, width: w) }
            else if model.selection == SettingsModel.restoreID { DisplayWindow(text: "Restore", dim: "· nothing is overwritten", height: h, width: w) }
            else if model.selection == SettingsModel.exportID { DisplayWindow(text: "Export", dim: "· nothing is changed", height: h, width: w) }
            else if model.selection == SettingsModel.importID { DisplayWindow(text: "Import", dim: "· nothing is overwritten", height: h, width: w) }
            else if let id = model.selection, let e = model.accounts.first(where: { $0.id == id }) { profileState(e, w: w, h: h) }
            else { DisplayWindow(text: "Saved", dim: "· as you change", height: h, width: w) }
        }
        .help(model.unsaved ?? model.problem ?? "Settings are saved as you change them; a name or label when you press Return")
    }

    /// What the selected profile is doing now: its usage (read by the agent) and, with one, its Dock icon.
    @ViewBuilder func profileState(_ e: AccountEntry, w: CGFloat, h: CGFloat) -> some View {
        // the agent first, in the dashboard's words
        let health = Agent.health()
        if case .stopped = health, AgentStarter.shared.failures >= 3, !AgentStarter.shared.starting {
            DisplayWindow(text: "Not updating", dim: "· agent won't start", tone: .warn, height: h, width: w)
        } else if case .stopped = health {
            DisplayWindow(text: "Starting the agent…", tone: .amber, height: h, width: w)
        } else if case let .paused(until) = health {
            DisplayWindow(text: "Not updating", dim: "· agent paused until \(StripState.time(until))", tone: .amber, height: h, width: w)
        } else {
            switch UsageIconState.of(e) {
            case .off: DisplayWindow(text: "Reading usage", dim: "· every \(max(e.pollMinutes, 1)) min", tone: .ok, height: h, width: w)
            case .missing: DisplayWindow(text: "Missing", dim: "· reinstall", tone: .warn, height: h, width: w, dimTone: .warn)
            case .inDock: DisplayWindow(text: "Running", dim: "· in the Dock", tone: .ok, height: h, width: w)
            case .notPinned: DisplayWindow(text: "Running", dim: "· not in the Dock", tone: .ok, height: h, width: w, dimTone: .amber)
            case .notRunning:
                if DockManager.isPinned(Installer.appURL(e)) { DisplayWindow(text: "Stopped", dim: "· in the Dock", height: h, width: w) }
                else { DisplayWindow(text: "Stopped", dim: "· not in the Dock", height: h, width: w, dimTone: .amber) }
            }
        }
    }
}

/// The strip's tile for an account being set up.
struct NewTile: View {
    let selected: Bool
    var body: some View {
        // a wide key like the other tiles, text only
        TileKey(selected: selected) { TileText(title: "New profile", sub: "not added yet") }
    }
}

struct AccountTile: View {
    let entry: AccountEntry
    let selected: Bool
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            TileKey(selected: selected, leading: 5) {
                HStack(spacing: 9) {
                    Image(nsImage: preview(entry, status: Store.status(for: entry), tick: model.tick)).resizable().frame(width: 32, height: 32)
                    TileText(title: entry.name.isEmpty ? "New profile" : entry.name, sub: sub)
                }
            }
            .onTapGesture { model.selection = entry.id }
            .contextMenu { Button("Remove \(entry.name)…", role: .destructive) { model.askRemove(entry.id) } }
            // flush on its right while its Switch page is open, or a switch of it is unfinished (SwitchView.swift)
            SwitchTileDisplay(entry: entry, model: model)
        }
    }

    /// "~/.claude", and with more than one account, the one in use: "~/.claude · ultra-1".
    private var sub: String {
        if entry.usageOnly { return "usage only" }
        guard !entry.standby.isEmpty, let email = entry.seat?.email else { return entry.configDir }
        return "\(entry.configDir) · \(AccountNames.short(email))"
    }
}

/// A tile in the profile strip: a wide key; the chosen one latched down with its strip lit.
struct TileKey<Content: View>: View {
    let selected: Bool
    var leading: CGFloat = 12
    var trailing: CGFloat = 12
    @ViewBuilder let content: Content
    @Environment(\.face) private var face

    var body: some View {
        content
            .foregroundStyle(face.legend)
            .shadow(color: face.legendShadow, radius: 0, y: face.legendShadowY)
            .padding(.leading, leading).padding(.trailing, trailing)
            .frame(minHeight: 42)
            .background(RaisedShape(finish: selected ? face.keyDown : face.key, radius: 4, pressed: selected))
            .overlay { if selected { LampStrip() } }
            .contentShape(Rectangle())
    }
}

/// What a profile includes: Usage in the Dock and Claude window, two keys side by side with what the current choice
/// does under each. Both off is "usage only". Turning one off never deletes anything.
struct ProfileSwitches: View {
    let usageInDock: Bool
    let claudeWindow: Bool
    var waiting = false                 // the Dock is taking an icon in or out: the keys wait
    let setUsageInDock: (Bool) -> Void
    let setClaudeWindow: (Bool) -> Void
    @Environment(\.face) private var face

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            column(SwitchKey(title: "Usage in the Dock", on: usageInDock) { setUsageInDock(!usageInDock) }.disabled(waiting),
                   usageInDock ? "A Dock icon shows this profile's usage; click it for details."
                               : "No Dock icon. Usage still shows on the dashboard, in the launcher and in alerts; turn it back on and the icon returns to its place.")
            column(SwitchKey(title: "Claude window", on: claudeWindow) { setClaudeWindow(!claudeWindow) }.disabled(waiting),
                   claudeWindow ? "A Claude window for this profile, signed in to its account; open it from the dashboard or the Dock icon."
                                : "No Claude window. Its sign-in is kept, so turning it back on needs no new sign-in.")
        }
    }

    private func column(_ key: some View, _ says: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            key
            Text(says).font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A key that's on or off, like the profile tiles: raised, with a lamp strip on top, green when on, dark when off.
struct SwitchKey: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @Environment(\.face) private var face
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .bold)).tracking(1).textCase(.uppercase).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(face.legend)
                .shadow(color: face.legendShadow, radius: 0, y: face.legendShadowY)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(RaisedShape(finish: face.key, radius: 4, pressed: false))
                .overlay {
                    if on { LampStrip(color: FaceTheme.ledOn) }
                    else {
                        Capsule().fill(face.ledOff).frame(height: 2).padding(.horizontal, 5).padding(.top, 3)
                            .frame(maxHeight: .infinity, alignment: .top).allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableKey())
        .opacity(enabled ? 1 : 0.6)
        .accessibilityValue(on ? "on" : "off")
    }
}

/// A tile's two lines: its name in spaced capitals and a quieter line under it.
struct TileText: View {
    let title: String
    let sub: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10.5, weight: .bold)).tracking(1).textCase(.uppercase).lineLimit(1)
            Text(sub).font(.system(size: 10.5)).opacity(0.65).lineLimit(1)
        }
        .fixedSize()
    }
}

// MARK: - Cards and rows

/// A settings card: a raised module with a printed label, an engraved rule after it, and its rows.
struct SCard<Content: View>: View {
    let title: String
    var info: String? = nil
    @ViewBuilder let content: Content
    @Environment(\.face) private var face

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Printed(text: title)
                if let info { InfoDot(text: info) }
                EngravedRule(dark: face.light ? .black(0.28) : nil).frame(minWidth: 12)
            }
            .padding(.bottom, 4)
            VStack(spacing: 0) { content }
        }
        .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RaisedShape(finish: face.module, radius: face.moduleRadius))
    }
}

/// A settings row: the label in a fixed column and the control right after it (never pushed to the card's
/// far edge), or, for wide controls, the label above the control.
extension VerticalAlignment {
    private enum RowLine: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    /// The line a settings row's label lines up with: the middle of its control, or a field's own line when the field
    /// has a message under it.
    static let rowLine = VerticalAlignment(RowLine.self)
}

struct SRow<Control: View>: View {
    let label: String
    var info: String? = nil
    var first = false
    var stacked = false
    var picture: AnyView? = nil        // a small illustration inside the (i)
    @ViewBuilder let control: Control
    @Environment(\.face) private var face

    static var labelWidth: CGFloat { 146 }      // the longest label with its (i): "Usage in the Dock"
    /// A card with long values (accounts, paths, the address row) narrower than this stacks its rows, so they show
    /// whole: New profile's Claude Code card and Settings ▸ a profile ▸ Claude Code (one rule for both).
    static var stackBelow: CGFloat { 480 }

    var body: some View {
        VStack(spacing: 0) {
            if !first { EngravedRule() }
            if stacked {
                VStack(alignment: .leading, spacing: 6) { title; control }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .rowLine, spacing: 10) {
                    title.frame(width: Self.labelWidth, alignment: .leading)
                    control
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)     // no spacer: its spacing would take 10 pt
            }
        }
    }

    private var title: some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(face.soft).lineLimit(1)
            if let info { InfoDot(text: info, picture: picture) }
        }
    }
}

/// Hands its content the width of the settings column it's in (SettingsColumns sets it), read where the card is drawn:
/// a card built by a page above the columns can't read the column's environment itself.
struct InSettingsColumn<Content: View>: View {
    @Environment(\.settingsColumnWidth) private var width
    @ViewBuilder let content: (CGFloat) -> Content
    var body: some View { content(width) }
}

/// Signing in to another account, in one line like the Folder row: the address in a well as wide as the value column,
/// then Sign in and Cancel at the row's end, the same height as a pop-up and its key. In a narrow column Cancel is a
/// small × instead of wrapping. Return signs in, Esc cancels.
struct AddressRow: View {
    @Binding var email: String
    let canSignIn: Bool
    let signIn: () -> Void
    let cancel: () -> Void

    /// The field never gets narrower than this beside its keys: an address has to stay readable while it's typed.
    static let fieldMin: CGFloat = 160

    var body: some View {
        // one line with Cancel, one line with ×, or (narrow) the field on its own line with the keys under it. The
        // field's ideal width is fixed, so the column decides the form, not the address typed (no jump mid-typing).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { field.frame(minWidth: Self.fieldMin, idealWidth: Self.fieldMin, maxWidth: .infinity); signInKey; cancelKey }
            HStack(spacing: 6) { field.frame(minWidth: Self.fieldMin, idealWidth: Self.fieldMin, maxWidth: .infinity); signInKey; closeKey }
            VStack(alignment: .leading, spacing: 6) {
                field
                HStack(spacing: 6) { signInKey; closeKey }
            }
        }
    }

    private var field: some View {
        WellField(placeholder: "name@example.com", text: $email, onSubmit: signIn, onCancel: cancel)
    }
    private var signInKey: some View {
        Button("Sign in", action: signIn)
            .buttonStyle(.pill(FaceTheme.ledOn, compact: true)).disabled(!canSignIn).fixedSize()
    }
    private var cancelKey: some View {
        Button("Cancel", action: cancel).buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
    }
    private var closeKey: some View {
        Button(action: cancel) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
            .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize().help("Cancel")
    }
}

/// A small text field for settings rows (name, icon label), on an engraved line. Without `commit` every keystroke
/// goes straight to `text`. With it, the edit is kept here until Return or leaving the field, then handed to
/// `commit`, which saves it or returns why it can't; Esc puts the old text back. While an edit isn't saved the line
/// turns into an amber hairline with "Return saves · Esc undoes" under it (the caps clickable), like a validation message;
/// red with the reason when it can't be saved.
struct SField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = 180           // nil: as wide as the value column, so its right edge lines up with the pop-ups
    var mono = false
    var transform: (String) -> String = { $0 }
    var commit: ((String) -> String?)? = nil
    var cancel: (() -> Void)? = nil
    @State private var draft: String?
    @State private var problem: String?
    @FocusState private var focused: Bool
    @Environment(\.face) private var face

    /// Typed but not saved yet.
    private var pending: Bool { commit != nil && draft != nil && draft != text }
    private var lineColor: Color? { problem != nil ? face.danger : pending ? face.caution : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField(placeholder, text: Binding(get: { draft ?? text }, set: { v in
                if commit == nil { text = transform(v) } else { draft = transform(v); problem = nil }
            }))
                .textFieldStyle(.plain).font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
                .foregroundStyle(face.text)
                .focused($focused)
                .onSubmit(finish)
                .onExitCommand(perform: undo)
                .onChange(of: focused) { f in if !f { finish() } }
                .onDisappear(perform: finish)       // leaving the page counts as clicking elsewhere, for this field's profile
                .padding(.vertical, 3)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        Rectangle().fill(lineColor ?? (face.light ? Color.black(0.35) : Color.black(0.5))).frame(height: 1)
                        Rectangle().fill(face.light ? Color.white(0.6) : Color.white(0.04)).frame(height: 1)
                    }
                    .offset(y: 2)
                }
                .frame(width: width)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
                .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }   // the label stays level with the text
            if let problem {
                Text(problem).font(.system(size: 10.5)).foregroundStyle(face.danger).fixedSize().padding(.top, 2)
            } else if pending {
                HStack(spacing: 4) {
                    KeyCap(text: "Return", color: face.caution, help: "Save it") { finish(); focused = true }
                    Text("saves ·")
                    KeyCap(text: "Esc", color: face.caution, help: "Put the saved text back") { undo(); focused = true }
                    Text("undoes")
                }
                .font(.system(size: 10.5)).foregroundStyle(face.caution).fixedSize().padding(.top, 2)
            }
        }
        .help(problem ?? (commit != nil ? "Return or click elsewhere saves it; Esc puts it back" : ""))
    }

    private func undo() { draft = nil; problem = nil; cancel?() }

    private func finish() {
        guard let commit, let d = draft else { return }
        if d == text { draft = nil; problem = nil; return }
        if let p = commit(d) { problem = p } else { draft = nil; problem = nil }
    }
}

/// A key named in a hint ("Return", "Esc"), drawn as a small key cap in the hint's colour; clicking it does what the
/// key does. It never takes the focus, so clicking it isn't "clicking elsewhere" for the field.
struct KeyCap: View {
    let text: String
    let color: Color
    var help = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(hover ? 0.24 : 0.12)))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(hover ? 1 : 0.55), lineWidth: 0.75))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// The (i) next to a setting: click it for a short explanation in a popover (hover shows it too).
struct InfoDot: View {
    let text: String
    var picture: AnyView? = nil
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: open ? "info.circle.fill" : "info.circle")
                .font(.system(size: 10.5))
                .foregroundStyle(hover || open ? Color.secondary : Color.secondary.opacity(0.6))
                .frame(width: 16, height: 16)          // a bigger target than the glyph
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(text)
        .accessibilityLabel("About this setting")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 9) {
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                if let picture { picture }
            }
            .frame(width: 260, alignment: .leading).padding(12)
        }
    }
}

/// − value ＋ in small pills.
struct MiniStepper: View {
    let text: String
    let down: () -> Void
    let up: () -> Void
    /// − and + keys round a small display window.
    var body: some View {
        HStack(spacing: 6) {
            Button(action: down) { Image(systemName: "minus").font(.system(size: 9, weight: .bold)).frame(width: 8) }
            DisplayWindow(text: text).frame(minWidth: 54)
            Button(action: up) { Image(systemName: "plus").font(.system(size: 9, weight: .bold)).frame(width: 8) }
        }
        .buttonStyle(PillButtonStyle(tint: nil, compact: true))
    }
}

extension View {
    /// The on/off switch: a small key with an LED, green while on.
    func smallSwitch() -> some View {
        toggleStyle(LEDSwitchStyle()).labelsHidden()
    }
    func smallMenu() -> some View { labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize() }
}

extension ClickAction {
    var shortTitle: String {
        switch self {
        case .peekThenOpen: return "Usage, then Claude"
        case .open: return "Open Claude"
        case .details: return "Details panel"
        }
    }
}

extension PanelDesign {
    var shortTitle: String {
        switch self {
        case .glow: return "Glow"
        case .rings: return "Rings"
        case .numbers: return "Numbers"
        case .segments: return "Segments"
        case .pace: return "Pace"
        }
    }
}

// MARK: - The selected account

struct AccountSettings: View {
    @Binding var entry: AccountEntry
    @ObservedObject var model: SettingsModel
    var width: CGFloat = 1280
    @Environment(\.face) private var face

    var status: IconStatus? { _ = model.tick; return Store.status(for: entry) }
    var expected: String? { Account.expectedEmail(configDir: entry.configDir) }
    var mismatch: Bool {
        guard let a = status?.loginEmail, let b = expected else { return false }
        return a.lowercased() != b.lowercased()
    }

    /// Layout A: each part is one card, its switch first, one title per card. Left: Profile, Claude Code, Sessions (its
    /// backups, SessionsCard.swift), Claude window, Alerts; middle: the Dock icon (when it runs, a click, the usage panel, its look, a preview); right: the menu bar
    /// icon. A part that's off folds its card to the switch row. Two columns: the left cards with the menu bar under
    /// them, the Dock icon beside; one column: everything in that order. What the profile is doing now is in the main
    /// display at the top.
    var body: some View {
        SettingsColumns(width: width, groups: [
            [AnyView(accountCard), AnyView(codeCard), AnyView(SessionsCard(entry: entry, model: model)), AnyView(windowCard), AnyView(updatesCard)],
            [AnyView(dockIconCard)],
            [AnyView(MenuBarCard(entry: $entry))]],
            two: [[AnyView(accountCard), AnyView(codeCard), AnyView(SessionsCard(entry: entry, model: model)), AnyView(windowCard), AnyView(updatesCard), AnyView(MenuBarCard(entry: $entry))],
                  [AnyView(dockIconCard)]])
    }

    // Account
    var accountCard: some View {
        SCard(title: "Profile", info: "Who this profile is in cl_audit: its name, the label on its icons, its colour, and whether Fable's own weekly limit shows.") {
            SRow(label: "Name", info: "What cl_audit calls this profile; its Dock icon app is “cl_audit \(entry.name.isEmpty ? "…" : entry.name)”. Saved when you press Return or click elsewhere (Esc puts it back); saving restarts that Dock icon.", first: true) {
                SField(placeholder: "name", text: $entry.name, width: nil,
                       commit: { v in save("Dock icon renamed") { $0.name = v } }, cancel: { model.unsaved = nil })
            }
            SRow(label: "Icon label", info: "Up to 6 letters printed on this profile's Dock icon, like MAIN or WORK, so you can tell the icons apart. Saved when you press Return or click elsewhere (Esc puts it back).") {
                SField(placeholder: "LABEL", text: $entry.label, width: nil, mono: true,
                       transform: { String($0.uppercased().filter { !$0.isWhitespace }.prefix(6)) },
                       commit: { v in save("icon label changed") { $0.label = v } }, cancel: { model.unsaved = nil })
            }
            SRow(label: "Colour", info: "This profile's colour inside cl_audit: the dot by its name on the dashboard and in the launcher, its Show key, its share of the history charts and the dot on its usage panel. The Dock icon's own colour is under Icon.") {
                SwatchRow(colors: TileColor.accents, selected: entry.accentColor) { if let c = $0 { entry.accent = c } }
            }
            SRow(label: "Fable's limit", info: "Fable's own weekly limit (Max and Ultra plans, premium Team and Enterprise seats): shown on this profile's dashboard card, usage panels, Dock and menu bar menus and the widget, with its alerts. Off: left out everywhere; it still counts in Anthropic's limits.") {
                SSwitch(isOn: $entry.showFable, on: "shown and alerted", off: "left out")
            }
            if let other = FolderRules.seatTaken(entry, among: model.accounts) {
                Text("Its Claude Code folder is signed in to the same Claude account as “\(other.name)”. One profile per account: sign this folder in with another account, or remove this profile.")
                    .font(.system(size: 11)).foregroundStyle(face.danger).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
            Button("Remove profile…") { model.askRemove(entry.id) }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(face.danger)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .overlay(alignment: .top) { EngravedRule() }
        }
    }

    // Claude Code and window
    /// Claude Code, like New profile's card: Account first (the account Claude Code in the folder is signed in to, and
    /// everything about it), then the Folder it lives in, then what that folder shares from another one. Rows stack
    /// (label above, the control the card's full width) when the card is narrow, so accounts and paths show whole.
    var codeCard: some View {
        InSettingsColumn { columnWidth in codeCard(stacked: columnWidth < SRow<EmptyView>.stackBelow) }
    }

    private func codeCard(stacked: Bool) -> some View {
        SCard(title: "Claude Code",
              info: "The claude.ai account this profile uses and the Claude Code folder it lives in. Its Claude window comes with it: the usual Claude app for the profile using ~/.claude, its own Claude window (own sign-in, chats and settings) for any other.") {
            accountRows(stacked: stacked)
            SRow(label: "Folder", info: "The Claude Code folder for this profile, like ~/.claude: its sign-in, settings and history live there. One profile per folder; folders are used where they are (Claude Code names a folder's Keychain sign-in after its path).", stacked: stacked) {
                // the folder key beside the pop-up while the whole path fits; in a narrow column the pop-up alone (its
                // menu has "Choose another folder…" too)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        folderMenu
                        Button { useFolder(pickFolder()) } label: { Image(systemName: "folder").font(.system(size: 10.5)) }
                            .buttonStyle(PillButtonStyle(tint: nil, compact: true)).help("Choose another folder…")
                            .fixedSize()                              // the key stays at the row's end
                    }
                    folderMenu
                }
            }
            shareRows(stacked: stacked)
        }
    }

    /// The Folder pop-up, worded like New profile's: each folder with who is signed in there, the one in use ticked,
    /// other profiles' dimmed with their name, then "Choose another folder…".
    private var folderMenu: some View {
        Menu {
            ForEach(model.choices(model.configFolders, current: entry.configDir), id: \.path) { c in
                if let owner = FolderRules.configOwner(c.path, among: model.accounts, except: entry.id) {
                    Button("\(c.path)   \(owner.name)'s") {}.disabled(true)
                } else if FolderKey.canonical(c.path) == FolderKey.canonical(entry.configDir) {
                    Toggle("\(c.path)   \(NewAccountSetup.folderWho(c.path))", isOn: .constant(true))   // the menu's own tick
                } else {
                    Button("\(c.path)   \(NewAccountSetup.folderWho(c.path))") { useFolder(c.path) }
                }
            }
            Divider()
            Button("Choose another folder…") { useFolder(pickFolder()) }
        } label: { MenuWell(text: entry.configDir.isEmpty ? "Choose…" : entry.configDir, mono: true, fill: true) }
        .faceMenuFill()
        .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
    }

    /// Share from and Shared, as New profile shows them for a new folder, here read from the folder as it is: which
    /// items are links into another Claude Code folder. Only for a folder that shares from another (not ~/.claude, the
    /// usual source). Read only in this release: cl_audit can't tell its own links from ones made by hand, and it
    /// never deletes or moves anything in a Claude Code folder, so the line under them says how to change them.
    @ViewBuilder func shareRows(stacked: Bool) -> some View {
        let items = NewAccountSetup.sharedItems(in: entry.configDir)
        let linked = items.compactMap { i -> (SharedItem, String)? in
            if case .linked(let from) = i.state { return (i.item, from) }
            return nil
        }
        let sources = Array(Set(linked.map(\.1))).sorted()
        if !Account(entry).isDefaultDir {
            SRow(label: "Share from", info: "The Claude Code folder this profile's folder links some items from (instructions, agents, skills, commands, memory & history), so edits there show up here too. Sign-in, plugins and usage stay separate.", stacked: stacked) {
                Text(sources.isEmpty ? "nothing: every item is its own" : sources.joined(separator: ", "))
                    .font(sources.isEmpty ? .system(size: 12) : .system(size: 11.5, design: .monospaced))
                    .foregroundStyle(sources.isEmpty ? face.muted : face.soft)
                    .lineLimit(1).truncationMode(.tail)
                    .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
            }
            if !linked.isEmpty {
                SRow(label: "Shared", info: "The items that are links into the folder above; the rest are this folder's own. cl_audit makes these links when it creates a folder (New profile) and doesn't change them afterwards.", stacked: stacked) {
                    Text(linked.map(\.0.title).joined(separator: ", "))
                        .font(.system(size: 12)).foregroundStyle(face.soft)
                        .fixedSize(horizontal: false, vertical: true)
                        .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
                }
            }
            if !sources.isEmpty {
                rowLine("To change them, add or remove the links in \(entry.configDir) in Finder.")
            }
        }
    }

    /// The folder is signed in to another account than the one the profile is linked to (or nil).
    var seatMove: FolderRules.SeatMove? { _ = model.tick; return FolderRules.seatMove(entry, among: model.accounts) }

    /// Account: one row for everything about this folder's sign-in, first in the card (as on New profile). Its value is
    /// the pop-up, drawn like the Folder one; only when something needs a choice, the keys for it sit under the pop-up
    /// in the same row (wrapping in a narrow column), with one grey line under the row. "Sign in to another account…"
    /// turns the value into the address row, in place; Esc or Cancel puts the pop-up back. Renew sign-in is a pop-up item.
    @ViewBuilder func accountRows(stacked: Bool) -> some View {
        let name = entry.name.isEmpty ? "This profile" : entry.name
        let old = Privacy.masked(entry.seat?.email ?? expected ?? "its account")
        let mine = model.accountSwitch?.id == entry.id ? model.accountSwitch : nil
        let move = seatMove
        let linkedLately: (was: String, at: Date)? = entry.seat.flatMap { s in
            guard let was = s.was, let at = s.linkedAt, Date().timeIntervalSince(at) < 7 * 86400 else { return nil }
            return (was, at)
        }
        // Accounts: the boxes need the card's width, so the row is always stacked (label above)
        SRow(label: "Accounts", info: loginInfo, first: true, stacked: true) {
            VStack(alignment: .leading, spacing: 8) {
                ClaudeMissingLine(model: model)          // every sign-in key below needs Claude Code: say so when it isn't there
                if let mine, mine.started != nil {
                    // waiting for the sign-in started here: cl_audit links the profile by itself once it's done
                    HStack(spacing: 8) {
                        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                            LED(color: FaceTheme.ledAmber, lit: Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0)
                        }
                        Text("signing in…").font(.system(size: 12)).foregroundStyle(face.caution).lineLimit(1)
                        Spacer(minLength: 6)
                        Button("Cancel") { model.cancelSwitch() }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                    }
                    .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
                } else if mine != nil {
                    AddressRow(email: Binding(get: { model.accountSwitch?.email ?? "" },
                                              set: { model.accountSwitch?.email = $0; switchProblem = nil }),
                               canSignIn: true,            // never greyed: without Claude Code it says why (beginSwitch)
                               signIn: { switchProblem = model.beginSwitch() },
                               cancel: { model.cancelSwitch(); switchProblem = nil })
                        .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
                } else {
                    inUseBox(move)
                        .alignmentGuide(.rowLine) { d in d[VerticalAlignment.top] }
                }
                // the others, most room first (held still while one is selected); click one to select it, again to deselect
                ForEach(standbyOrder) { s in standbyBox(s) }
                if entry.standby.contains(where: Self.canSwitch), picked == nil {
                    Text("Click a standby account to select it: its Switch account key opens the Switch page.")
                        .font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
                }
                addAccountRow
            }
        }
        // one grey line, worded like New profile's and short enough for one line in a 460 pt column
        if let mine, mine.started != nil {
            rowLine("Finish in the browser as \(Privacy.masked(mine.email)); switch its claude.ai account first if needed.")
        } else if mine != nil {
            rowLine(switchProblem ?? "Claude Code signs in through Terminal; \(name) stays on \(old) until then.",
                    color: switchProblem == nil ? nil : face.danger)
        } else if let move, let owner = move.owner {
            rowLine("\(Privacy.masked(move.to.email ?? "That account")) is the account of “\(owner.name)”. One profile per account.", color: face.danger)
        } else if let move {
            rowLine("Signed in as \(Privacy.masked(move.to.email ?? "another account")); \(name) is linked to \(old). Numbers wait until you choose.")
        } else if mismatch {
            rowLine("The Keychain's sign-in is another account than the folder's .claude.json names.")
        } else if status?.state == "expired" {
            rowLine("The sign-in ran out: use Claude Code, log in again, or turn on Renew sign-in.")
        } else if status?.state == "denied" {
            rowLine(FetchState.deniedWords, color: face.caution)
        } else if status?.state == "unreadable" {
            rowLine(Self.unreadableWords(version: model.claudeVersion), color: face.caution)
        } else if status?.state == "noLogin" {
            rowLine(noSignInWords)
        } else if let l = linkedLately {
            rowLine(linkedWords(was: l.was, at: l.at))
        }
        if mine == nil, windowElsewhere {
            SRow(label: "Claude window", stacked: stacked) {
                HStack(spacing: 7) {
                    LED(color: FaceTheme.ledAmber)
                    Text("another account").font(.system(size: 12)).foregroundStyle(face.caution)
                }
            }
            rowLine("Numbers are still \(name)'s (from Claude Code), not the window's account.")
        }
        // "Sessions follow" went: the Switch page asks every time, with no answer chosen
    }

    // MARK: Accounts (Accounts.swift): the one in use, the standby ones, Add account

    /// The account in use: its address as the pop-up it always was (the account Claude Code in the folder is signed in
    /// to, ticked; logging back in to the profile's own; Renew sign-in), its plan, IN USE, its limits as bars, and the one
    /// key a problem needs.
    func inUseBox(_ move: FolderRules.SeatMove?) -> some View {
        let signedIn = status?.loginEmail
        let red = face.danger
        let (shown, tint, icon): (String, Color?, String?) =
            mismatch ? (signedIn ?? "another account", red, "exclamationmark.triangle.fill")
            : move != nil ? (move?.to.email ?? "another account", red, "exclamationmark.triangle.fill")
            : status?.state == "expired" ? (signedIn ?? expected ?? "expired", face.caution, "clock.badge.exclamationmark")
            : (signedIn ?? expected ?? "not signed in yet", nil, nil)
        let facts = FolderFactsCache.facts(entry.configDir)
        let plan = (status?.plan).map(Account.planWords) ?? facts?.plan
        let ok = move == nil && !mismatch && !["expired", "noLogin", "denied", "unreadable"].contains(status?.state)
        return AccountBox(lamp: ok ? FaceTheme.ledOn : nil, badge: "In use", badgeTone: ok ? .ok : .warn,
                          detail: ([plan, facts?.org] + [entry.standby.isEmpty ? nil : "\(entry.name.isEmpty ? "the profile" : entry.name) works on it"])
                            .compactMap { $0 }.joined(separator: " · ")) {
            Menu {
                ForEach(loginItems) { it in
                    switch it.kind {
                    case .divider: Divider()
                    case .toggle(let on):
                        Toggle(it.title, isOn: Binding(get: { on }, set: { _ in it.action() })).disabled(!it.enabled)
                    case .item:
                        if it.checked { Toggle(it.title, isOn: .constant(true)) }      // drawn with the menu's own tick
                        else { Button(it.title, action: it.action).disabled(!it.enabled) }
                    }
                }
            } label: { AccountBoxTitle(text: Privacy.masked(shown), tint: tint, icon: icon) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
        } content: {
            limitsOrWhy(status, entry: entry, none: status?.state == "noLogin" ? noSignInWords : nil)
            if let move {
                // one key; logging back in to the profile's own account is in the pop-up, under this account
                if let owner = move.owner {
                    Button("Open \(owner.name)") { model.selection = owner.id }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
                } else {
                    Button("Use this account") { model.relink(entry.id) }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
                }
            } else if mismatch || status?.state == "noLogin" || status?.state == "expired" {
                logInKey(email: expected)
            } else if status?.state == "denied" || status?.state == "unreadable" {
                // the sign-in is there: not Log in…, but a fresh read (Refresh now), after allowing cl_audit Agent
                Button("Refresh now") { DistributedNotificationCenter.default().postNotificationName(Installer.refreshAllNote, object: entry.id, userInfo: nil, deliverImmediately: true) }
                    .buttonStyle(PillButtonStyle(tint: nil, compact: true))
            }
            if !entry.standby.isEmpty { ownFolderLine }
        }
    }

    /// With more than one account, the one in use has a folder of its own too, signed in once, so its limits keep
    /// showing after a switch (the working folder signs in again each time): said, or offered.
    @ViewBuilder var ownFolderLine: some View {
        let kept = entry.keptFolder.flatMap { $0.isEmpty ? nil : $0 }
        let ready = kept.flatMap { FolderFactsCache.facts($0) }.map { $0.seat.same(entry.seat) } ?? false
        if ready {
            Text("Its limits come from a sign-in kept for it, renewed by itself.")
                .font(.system(size: 10.5)).foregroundStyle(face.muted).lineLimit(1).minimumScaleFactor(0.9)
        } else {
            let why = kept == nil ? "Keep its limits showing after a switch: sign it in once to a folder of its own."
                                  : "Waiting for the sign-in in its own folder: finish it in the browser, or sign in again."
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(why).font(.system(size: 11.5)).foregroundStyle(face.caution).lineLimit(1)
                    Spacer(minLength: 6)
                    ownFolderKey
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(why).font(.system(size: 11.5)).foregroundStyle(face.caution).fixedSize(horizontal: false, vertical: true)
                    ownFolderKey
                }
            }
        }
    }

    private var ownFolderKey: some View {
        Button("Sign in…") { signInOwnFolder() }
            .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
    }

    /// The account in use, signed in once to a folder of its own (made now if it has none): Claude Code's sign-in there
    /// in Terminal, with its address filled in. Its numbers come from there once that's done (Reader.swift).
    func signInOwnFolder() {
        guard let email = entry.seat?.email ?? expected, let claude = model.requireClaude() else { return }
        var dir = entry.keptFolder ?? ""
        if dir.isEmpty {
            guard let made = StandbyFolder.make(for: email) else { model.message = "Couldn't make a folder for its sign-in"; return }
            dir = made
            entry.keptFolder = made
        }
        ClaudeCLI.openLogin(claude, account: Account(AccountEntry(id: entry.id, name: entry.name, label: entry.label, configDir: dir)), email: email)
    }

    /// A standby account: its address (a pop-up with Sign in… and Remove), its plan, STANDBY, and its limits from the
    /// sign-in kept for it, or why there are none.
    func standbyBox(_ s: StandbyAccount) -> some View {
        let name = entry.name.isEmpty ? "this profile" : entry.name
        let st: IconStatus? = { _ = model.tick; return Store.status(for: entry, standby: s) }()
        let read = s.configDir.map { FolderFactsCache.read($0) }
        let facts = read?.facts
        // its plan and organisation once its folder is signed in to it: never those of another account's sign-in
        let mine = s.seat.map { m in facts?.seat.same(m) ?? false } ?? false
        let plan = (st?.plan).map(Account.planWords) ?? (mine ? facts?.plan : nil)
        let hasNumbers = AccountRow(entry: entry.readerEntry(for: s) ?? entry, status: st).limits.contains { $0.p != nil }
        // not linked yet and its folder signed in to an account it can't have (the profile's own, or another profile's):
        // the wrong account. A sign-in that names a free account links by itself within seconds (Folders.swift).
        // (the folders' records come through FolderFactsCache: this is drawn every few seconds)
        let clash = s.seat == nil ? StandbyLook.clash(of: facts?.seat, for: entry, among: model.accounts,
                                                       inUse: FolderFactsCache.facts(entry.configDir)?.seat,
                                                       signedIn: { FolderFactsCache.facts($0)?.seat }) : nil
        // when a sign-in was started in its folder: the script each one writes; for an account not linked yet, else when
        // it was added (nothing new is saved)
        let started = s.configDir.flatMap { StandbyLook.signInStarted(configDir: $0, addedAt: s.seat == nil ? s.addedAt : nil) }
        let look = StandbyLook.of(email: s.email, hasFolder: s.configDir != nil, linked: s.seat != nil, folderSeat: facts?.seat,
                                  clash: clash, state: st?.state, hasNumbers: hasNumbers, problem: st?.problem,
                                  attempt: SignInAttempts.attempt(s.id), startedAt: started, signedInAt: read?.stamp)
        let why = look.line
        // unlit; clicked, its row lights and the Switch account key takes the place of "Standby" (an account not linked
        // yet can't be switched to: no key)
        let canSwitch = Self.canSwitch(s)
        let selected = picked == s.id && canSwitch
        // a warning and its keys keep full strength; only the limits (and "no numbers yet") dim
        return AccountBox(lamp: nil, badge: look.badge, badgeTone: look.tone,
                          detail: [plan, mine ? facts?.org : nil].compactMap { $0 }.joined(separator: " · "),
                          unlit: !selected, dimsContent: look.dims, selected: selected, litBadge: "Switch account",
                          litAction: { model.showSwitch(AccountEntry.standbyStatusID(entry.id, s.id)) }) {
            Menu {
                if model.claudeKnownMissing {
                    Button(ClaudeInstall.missingInstall) { model.showInstallHelp() }
                    Divider()
                }
                Button(s.configDir == nil ? "Sign in…" : "Sign in again…") { signInStandby(s) }
                Divider()
                Button("Remove from \(name)") { removeStandby(s) }
            } label: { AccountBoxTitle(text: Privacy.masked(s.email)) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
        } content: {
            // a click below the address selects the account (again: deselects); the address menu, the lit key and a
            // Sign in… key stay outside the click area, so they never select or deselect
            if let why {
                // the line of what's left (signing in, the wrong account, no numbers yet) and its keys: on one row while
                // they fit, else the keys under it
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        selectArea(s, canSwitch, selected) { BoxNote(text: why, tone: look.lineTone).lineLimit(1) }
                        standbyKeys(look.keys, s)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        selectArea(s, canSwitch, selected) {
                            BoxNote(text: why, tone: look.lineTone).fixedSize(horizontal: false, vertical: true)
                        }
                        standbyKeys(look.keys, s)
                    }
                }
            } else {
                selectArea(s, canSwitch, selected) {
                    VStack(alignment: .leading, spacing: 8) {
                        limitsOrWhy(st, entry: entry.readerEntry(for: s) ?? entry, none: nil)
                        // unlike the account in use (Renew sign-in, opt-in), a standby account's sign-in is always renewed
                        BoxNote(text: "Its sign-in renews by itself, so its limits stay current.", size: 10.5)
                            .lineLimit(1).minimumScaleFactor(0.9)
                    }
                }
            }
        }
    }

    /// The part of a standby box a click selects (again: deselects).
    private func selectArea<V: View>(_ s: StandbyAccount, _ canSwitch: Bool, _ selected: Bool, @ViewBuilder _ v: () -> V) -> some View {
        v().frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard canSwitch else { return }
                if picked == s.id { picked = nil; heldOrder = [] }
                else { if picked == nil { heldOrder = SwitchOffer.byRoom(entry).map(\.id) }; picked = s.id }
            }
            .help(canSwitch ? (selected ? "Click to deselect" : "Click to select, then Switch account") : "")
    }

    /// A standby account the profile can switch to: linked to its account and organization (what a switch plans with).
    static func canSwitch(_ s: StandbyAccount) -> Bool { s.seat?.organization != nil }

    /// Most room first; while one is selected, the order it had then, so the boxes don't move under the pointer.
    private var standbyOrder: [StandbyAccount] {
        let now = SwitchOffer.byRoom(entry)
        guard picked != nil, !heldOrder.isEmpty else { return now }
        let at = Dictionary(heldOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return now.enumerated().sorted { (at[$0.element.id] ?? Int.max, $0.offset) < (at[$1.element.id] ?? Int.max, $1.offset) }.map(\.element)
    }

    /// The keys a standby account's line needs (StandbyLook): Cancel takes a new account off the profile again (as Remove
    /// does: its folder and anything signed in there stay), Show Terminal brings Terminal forward (where Claude Code's
    /// sign-in waits), Sign in… / Sign in again… start the sign-in in its folder.
    func standbyKeys(_ keys: [StandbyLook.Key], _ s: StandbyAccount) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { k in
                switch k {
                case .cancel:
                    Button("Cancel") { removeStandby(s) }
                        .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                case .showTerminal:
                    Button("Show Terminal") { _ = Installer.run("/usr/bin/open", ["-a", "Terminal"]) }
                        .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                case .signIn:
                    Button("Sign in…") { signInStandby(s) }
                        .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                case .signInAgain:
                    Button("Sign in again…") { signInStandby(s) }
                        .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                }
            }
        }
    }

    /// The limits as the dashboard draws them, or one line why there are none yet.
    @ViewBuilder func limitsOrWhy(_ st: IconStatus?, entry e: AccountEntry, none: String?) -> some View {
        let row = AccountRow(entry: e, status: st)
        if row.limits.contains(where: { $0.p != nil }) {
            CardLimits(limits: row.limits, design: DashboardPrefs.shared.cardStyle, credits: st?.credits)
        } else {
            BoxNote(text: none ?? st?.problem ?? "No numbers yet: the agent reads them within a few minutes.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Add account: the key with what was found on this Mac, or, after "Sign in to another account…", the address row.
    @ViewBuilder var addAccountRow: some View {
        if let typed = adding {
            AddressRow(email: Binding(get: { typed }, set: { adding = $0; addProblem = nil }),
                       canSignIn: true,            // never greyed: without Claude Code it says why (addByAddress)
                       signIn: { addProblem = addByAddress() },
                       cancel: { adding = nil; addProblem = nil })
            rowLine(addProblem ?? AddAccountWords.signInLine(profile: entry.name, typed: typed),
                    color: addProblem == nil ? nil : face.danger)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { addAccountMenu; oneAtATime }
                VStack(alignment: .leading, spacing: 5) { addAccountMenu; oneAtATime }
            }
        }
    }

    private var oneAtATime: some View {
        Text("The profile works on one at a time.").font(.system(size: 11)).foregroundStyle(face.muted).lineLimit(1)
    }

    /// The accounts found on this Mac (Accounts.swift), in macOS's own menu with two lines a row (AddAccount.swift): the
    /// address, then in grey what is known of it. One click adds it; other profiles' are greyed and can't be added; then
    /// Sign in to another account…. Found accounts show no usage: limits are read only for a profile's own accounts.
    private var addAccountMenu: some View {
        AddAccountKey(pressed: addOpen)
            .accessibilityHidden(true)                  // the layer over it is the control: VoiceOver reads it once
            .overlay {
                MenuTrigger(label: "Add account", opened: { addOpen = $0 }) {
                    let found = FoundAccountsCache.list(for: entry, among: model.accounts)
                    let rows = AddAccountPopup.rows(found: found, profile: entry.name, canSignIn: model.claudeNow() != nil || !model.claudeLooked)
                    return AddAccountPopup.menu(rows,
                        onAdd: { id in if let f = found?.first(where: { $0.id == id }) { addFound(f) } },
                        onOther: { adding = ""; addProblem = nil },
                        onInstall: { model.showInstallHelp() })
                }
            }
            .fixedSize()
    }

    func addFound(_ f: FoundAccount) {
        guard let added = entry.adding(f, among: model.accounts) else { return }
        entry = added
        FoundAccountsCache.forget()
    }

    /// Sign in to another account…: a folder of its own for the new account, the account added (its seat comes with
    /// the sign-in), and Claude Code's sign-in in Terminal with the address filled in.
    func addByAddress() -> String? {
        let email = (adding ?? "").trimmingCharacters(in: .whitespaces)
        guard email.contains("@"), !email.hasPrefix("@"), !email.hasSuffix("@") else { return "Type the account's email address." }
        let known = [entry.seat?.email, expected].compactMap { $0?.lowercased() } + entry.standby.map { $0.email.lowercased() }
        if known.contains(email.lowercased()) { return "That's already one of \(entry.name)'s accounts." }
        if let owner = model.accounts.first(where: { o in o.id != entry.id && ([o.seat?.email, Account.expectedEmail(configDir: o.configDir)] + o.standby.map(\.email)).contains { $0?.lowercased() == email.lowercased() } }) {
            return "That's the account of “\(owner.name)”. One profile per account."
        }
        guard let claude = model.requireClaude() else { return model.noClaudeWhy }
        guard let dir = StandbyFolder.make(for: email) else { return "Couldn't make a folder for its sign-in in your home folder." }
        let s = StandbyAccount(email: email, configDir: dir)
        entry.standby.append(s)
        guard ClaudeCLI.openLogin(claude, account: Account(AccountEntry(id: s.id, name: entry.name, label: entry.label, configDir: dir)), email: email) else {
            return "Terminal didn't open: use Sign in… on the account."
        }
        SignInAttempts.began(s.id, folderSeat: nil)             // a folder made just now: nothing in it yet
        adding = nil
        FoundAccountsCache.forget()
        return nil
    }

    /// Sign in… on a standby account: its folder (made now if it has none) and Claude Code's sign-in there in Terminal.
    func signInStandby(_ s: StandbyAccount) {
        guard let i = entry.standby.firstIndex(where: { $0.id == s.id }), let claude = model.requireClaude() else { return }
        var dir = s.configDir
        if dir == nil {
            guard let made = StandbyFolder.make(for: s.email) else { model.message = "Couldn't make a folder for its sign-in"; return }
            dir = made
            entry.standby[i].configDir = made
        }
        guard let dir else { return }
        // what the folder is signed in to now, kept in memory: the sign-in is under way until that changes (AddAccount.swift)
        let was = FolderFactsCache.facts(dir)?.seat
        if ClaudeCLI.openLogin(claude, account: Account(AccountEntry(id: s.id, name: entry.name, label: entry.label, configDir: dir)), email: s.email) {
            SignInAttempts.began(s.id, folderSeat: was)
        }
    }

    /// Takes the account off this profile. Its folder and the sign-in in it stay where they are (cl_audit never deletes
    /// a Claude Code folder); Add account finds it again.
    func removeStandby(_ s: StandbyAccount) {
        entry.standby.removeAll { $0.id == s.id }
        SignInAttempts.forget(s.id)
        FoundAccountsCache.forget()
    }

    /// Login's (i): what it is, the pop-up, and Renew sign-in (now an item in the pop-up).
    var loginInfo: String {
        "The claude.ai accounts this profile has. It works on one at a time, IN USE: the one Claude Code in its folder is signed in to. The others STANDBY: their limits show too, read from a sign-in kept for each in a small folder of its own, so you can see which has room. Add account lists the accounts found on this Mac (signed in in a Claude Code folder, or used by this profile's Claude window) and Sign in to another account…, which opens Claude Code's own sign-in in Terminal in a new folder. An account belongs to one profile. cl_audit's background agent reads each sign-in from the Keychain, read-only, the same way Claude Code does; no new Keychain permission, and no sign-in is ever copied. Removing a standby account leaves its folder as it is.\n\nRenew sign-in (in the account in use's pop-up): Claude Code's sign-in uses a short-lived access key, which Claude Code swaps for a fresh one whenever it runs. cl_audit only reads that key, so after a while without Claude Code it runs out and the usage stops updating. On: cl_audit then runs Claude Code once in the background (a one-line prompt, \"Reply with OK.\", on Haiku, nothing saved) so it swaps the key; at most every 30 min, using a sliver of this profile's usage. Off: the usage waits until you next use Claude Code. Standby accounts' sign-ins are always renewed this way, so their limits stay current."
            + (model.claudeKnownMissing ? " Needs Claude Code installed; it wasn't found." : "")
            + (status?.renewNote.map { "\nLast: \($0)" } ?? "")
    }

    /// Why a switch can't start (Sign in), shown in the line under New account.
    @State private var switchProblem: String?
    /// Add account ▸ Sign in to another account…: the address being typed (nil: the key shows), and why it can't start.
    @State var adding: String?
    @State var addProblem: String?
    /// Add account's pop-up is open: its key shows pressed.
    @State private var addOpen = false
    /// The standby account clicked in Accounts: its row lights and its Switch account key opens the Switch page.
    @State var picked: String?
    @State private var heldOrder: [String] = []

    /// The profile's Claude window is signed in to another claude.ai account (only its id is known, never its address).
    var windowElsewhere: Bool { _ = model.tick; return FolderRules.windowOnAnotherAccount(entry) }

    /// What "no sign-in" says: the folder has none. When numbers show anyway because they are read from the account's
    /// kept sign-in in another folder, it says which part is missing, so a red "In use" isn't read as "not signed in at all".
    var noSignInWords: String {
        let numbers = AccountRow(entry: entry, status: status).limits.contains { $0.p != nil }
        let kept = !(entry.keptFolder ?? "").isEmpty
        return numbers && kept ? "This folder has no Claude Code sign-in; the account's numbers come from another sign-in."
                               : "No Claude Code sign-in in this folder yet."
    }

    /// The sign-in is there but isn't in a form cl_audit knows: with Claude Code's version when it's known.
    static func unreadableWords(version: String?) -> String {
        guard let v = version, !v.isEmpty else { return FetchState.unreadableWords }
        return "Signed in, but the sign-in isn't in a form cl_audit knows (Claude Code \(v)): Refresh now, or sign in again from Terminal."
    }

    /// "Log in…": Claude Code's own sign-in in Terminal, with the address filled in, for the folder the numbers are read
    /// from (the account's own once it has one).
    func logInKey(email: String?) -> some View {
        Button("Log in…") {
            if let claude = model.requireClaude() { ClaudeCLI.openLogin(claude, account: Account(entry.readingEntry()), email: email) }
        }
        .buttonStyle(.pill(.red, compact: true))
    }

    /// One grey line under a row, the card's width.
    func rowLine(_ s: String, color: Color? = nil) -> some View {
        Text(s).font(.system(size: 10.5)).foregroundStyle(color ?? face.muted)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
    }

    /// "Linked today 14:32 · was …. Stays with …: …, and the window's earlier Code sessions (how-to). To watch … again,
    /// give it a profile with New profile."
    func linkedWords(was: String, at: Date) -> AttributedString {
        let w = Privacy.masked(was)
        var a = AttributedString("Linked \(Self.when(at)) · was \(w). Stays with \(w): a CI token from claude setup-token, connectors, cloud sessions, and the window's earlier Code sessions (")
        var howTo = AttributedString("how-to")
        howTo.link = URL(string: "https://github.com/n-uf/cl_audit#moving-a-profile-to-another-account")
        var newProfile = AttributedString("New profile")
        newProfile.link = URL(string: Self.newProfileLink)
        a += howTo + AttributedString("). To watch \(w) again, give it a profile with ") + newProfile + AttributedString(".")
        return a
    }

    /// The "New profile" link in a grey line: opens the New profile page.
    static let newProfileLink = "cl-audit-settings://new-profile"

    func rowLine(_ s: AttributedString) -> some View {
        Text(s).font(.system(size: 10.5)).foregroundStyle(face.muted)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
            .environment(\.openURL, OpenURLAction { url in
                guard url.absoluteString == Self.newProfileLink else { return .systemAction }
                model.startNew()
                return .handled
            })
    }

    /// One line of the Account pop-up.
    struct LoginItem: Identifiable {
        enum Kind { case item, divider, toggle(Bool) }
        var id: String
        var title = ""
        var checked = false
        var enabled = true
        var kind = Kind.item
        var action: () -> Void = {}
    }

    /// What the account in use's pop-up lists, telling the same story as its label (the account Claude Code in this
    /// folder is signed in to, ticked): when that isn't the profile's account, the profile's own one to log back in to
    /// comes next; then Renew sign-in. Other accounts are Add account's. Linking to the one signed in here is the Use
    /// this account key in the box, not a menu line as well.
    var loginItems: [LoginItem] {
        let name = entry.name.isEmpty ? "this profile" : entry.name
        let move = seatMove
        let here = Account.signedInSeat(configDir: entry.configDir)?.email ?? status?.loginEmail ?? expected
        let plan = status?.plan.map(Account.planWords)
        let linked = entry.seat?.email
        let canSignIn = !model.claudeKnownMissing
        func line(_ email: String, _ detail: [String?]) -> String {
            ([Privacy.masked(email)] + [detail.compactMap { $0 }.joined(separator: " · ")].filter { !$0.isEmpty }).joined(separator: "   ")
        }
        var items: [LoginItem] = []
        if let here {
            items.append(LoginItem(id: "here", title: line(here, [plan, move == nil ? "this profile" : "signed in here"]), checked: true))
        }
        if move != nil {
            // accounts only: linking to the one signed in here is the Use this account key under the pop-up
            if let linked {
                items.append(LoginItem(id: "back", title: line(linked, ["\(name)'s account", "log in…"]), enabled: canSignIn) {
                    if let claude = model.requireClaude() { ClaudeCLI.openLogin(claude, account: Account(entry), email: linked) }
                })
            }
        }
        // other accounts are Add account's (below the boxes): this pop-up is about the account in use
        items.append(LoginItem(id: "d2", kind: .divider))
        // without Claude Code the items that need it are greyed; this one, right above them, says why
        if !canSignIn { items.append(LoginItem(id: "install", title: ClaudeInstall.missingInstall) { model.showInstallHelp() }) }
        items.append(LoginItem(id: "renew", title: "Renew sign-in by itself", enabled: canSignIn, kind: .toggle(entry.autoRenew)) {
            entry.autoRenew.toggle()
        })
        return items
    }

    /// The Account pop-up, in line with the Folder one: the account Claude Code in this folder is signed in to, green;
    /// red with a warning sign inside when it isn't the profile's account (or isn't the Keychain's), a clock when the
    /// sign-in ran out. A long address gets shorter ("…") rather than widening the card.
    func loginPopup(_ move: FolderRules.SeatMove?) -> some View {
        let signedIn = status?.loginEmail
        // the well is dark on every face: the bright display colours, not the face's (Silver's are dark, for its panel)
        let red = Color(nsColor: Painter.red), green = Color(nsColor: Painter.green)
        let (shown, tint, icon): (String, Color?, String?) =
            mismatch ? (signedIn ?? "another account", red, "exclamationmark.triangle.fill")
            : move != nil ? (move?.to.email ?? "another account", red, "exclamationmark.triangle.fill")
            : status?.state == "expired" ? (signedIn ?? expected ?? "expired", FaceTheme.ledAmber, "clock.badge.exclamationmark")
            : signedIn != nil ? (signedIn!, green, nil)
            : (expected ?? "not signed in yet", nil, nil)
        return Menu {
            ForEach(loginItems) { it in
                switch it.kind {
                case .divider: Divider()
                case .toggle(let on):
                    Toggle(it.title, isOn: Binding(get: { on }, set: { _ in it.action() })).disabled(!it.enabled)
                case .item:
                    if it.checked {
                        Toggle(it.title, isOn: .constant(true))      // drawn with the menu's own tick
                    } else {
                        Button(it.title, action: it.action).disabled(!it.enabled)
                    }
                }
            }
        } label: {
            MenuWell(text: shown, tint: tint, icon: icon, fill: true).settingsEmail(shown.contains("@"))
        }
        .faceMenuFill()
        .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }     // "Account" lines up with the pop-up, not the keys
    }

    /// "today 14:32", "Mon 14:32".
    static func when(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "'today' HH:mm" : "EEE HH:mm"
        return f.string(from: d)
    }

    // Dock icon: when it runs (the agent starts and quits it, whether or not cl_audit is open) and what a click on it
    // does. One card for everything about the Dock icon but its look (Icon, below it).
    var dockIconCard: some View {
        let name = entry.name.isEmpty ? "this profile" : entry.name
        return SCard(title: "Dock icon", info: "Everything about \(name)'s Dock icon: whether it's there, when it runs, what a click on it does, its usage panel and its look. The cl_audit agent starts and quits it, whether or not cl_audit is open; starting or quitting it never stops the usage, which cl_audit reads for every profile, always. Double-click or ⌥-click always opens the large panel.") {
            SRow(label: "Usage in the Dock", info: "On: a Dock icon shows \(name)'s usage; click it for details. Off: no Dock icon: it quits, is unpinned and its app is removed; the usage still shows on the dashboard, in the launcher and in alerts, and turning it back on brings the icon back to its place, with the same look and click settings. Changing it restarts the Dock once.", first: true) {
                // pulses until the Dock really has the icon or hasn't (dockProgress); another profile's change under
                // way: clicks wait, but the key isn't dimmed
                SSwitch(isOn: Binding(get: { !entry.iconHidden }, set: { model.setUsageInDock(entry.id, $0) }),
                        on: "shows the usage", off: "no Dock icon",
                        progress: { on, _ in model.dockProgress(entry.id, on) })
                    .allowsHitTesting(model.dockRestarting == nil || model.dockRestarting == entry.id)
            }
            if !entry.iconHidden {
                SRow(label: "Runs", info: "At login: always there, from when you log in to the Mac. With its window: starts when \(name)'s Claude window opens and quits 10 s after it quits (a Claude update restarts the window). When started: only when you start it (a click on its Dock tile, or its switch on the dashboard).") {
                    Menu {
                        Picker("", selection: $entry.dockRuns) { ForEach(DockRuns.allCases) { Text($0.title).tag($0) } }
                            .pickerStyle(.inline).labelsHidden()
                    } label: { MenuWell(text: entry.dockRuns.title, fill: true) }
                    .faceMenuFill()
                }
                SRowLine(text: runsWords)
                clickRows
                SRow(label: "Press and hold", info: "Press and hold the icon for its details panel and a short menu. Double-click or ⌥-click also opens the panel; right-click shows the full menu.") {
                    SSwitch(isOn: $entry.longPressDetails, on: "details and menu", off: "off")
                }
                SRow(label: "Usage panel", info: "How the usage panel looks when you click or press and hold this Dock icon. The dashboard's cards have one style for all profiles, in General.", stacked: true) {
                    // a large thing: Card style's control, with the panel's limits as Card style shows them (this
                    // profile's numbers once read)
                    SLooks(options: PanelDesign.allCases, selection: $entry.panelDesign, title: { $0.shortTitle }) { d in
                        CardLimits(limits: sampleInfo.limits, design: d, credits: sampleInfo.credits)
                            .padding(12)
                            .faceWindow(radius: 5)
                    }
                }
                SRow(label: "Icon", info: "How \(name)'s Dock icon draws the usage: numbers, rings, the panels' looks, or tiles in the level colours.", stacked: true) {
                    STiles(tiles: IconStyle.allCases.map { st in
                        .init(id: st, title: st.shortTitle, help: "\(st.title): \(st.blurb)",
                              picture: AnyView(Image(nsImage: Painter.image(iconModel(st), pixels: 96)).resizable().frame(width: 34, height: 34)))
                    }, selected: entry.style, minWidth: 70) { entry.style = $0 }
                }
                SRow(label: "Colour", info: "The colour of this profile's Dock icon: its label and tiles. By usage (the last swatch): it follows the 5-hour level, green to crimson. The profile's colour inside cl_audit is under Profile.") {
                    SwatchRow(colors: TileColor.allCases, selected: entry.color) { if let c = $0 { entry.color = c } }
                }
                SRow(label: "Frame", info: "A thin ring in this colour round the Dock icon, to spot it quickly among the others. The crossed circle: no ring.") {
                    SwatchRow(colors: TileColor.allCases, selected: entry.frame, none: true) { entry.frame = $0 }
                }
                SRow(label: "Claude open dot", info: "An orange dot at the Dock icon's top-left corner while this profile's Claude window is open.") {
                    SSwitch(isOn: $entry.windowDot, on: "while its window is open", off: "none", onShort: "window open")
                }
                PreviewStrip(caption: "not running, then as the limit fills up", items: dockPreview)
            }
        }
    }

    /// The grey line under Runs: what the current choice means.
    private var runsWords: String {
        switch entry.dockRuns {
        case .atLogin: return "Always there, from when you log in."
        case .withWindow:
            return entry.claudeWindow ? "Starts with the Claude window, quits 10 s after it."
                                      : "No Claude window, so it runs only when you start it."
        case .whenStarted: return "Only when you start it: its Dock tile, or its switch on the dashboard."
        }
    }

    /// Click and, after a brief usage panel, how long it shows. With Opens from ▸ Only when asked (or no Claude window)
    /// the Claude choices are off: the Dock icon shows the usage only, and the stored choice comes back with the window.
    @ViewBuilder private var clickRows: some View {
        let opens = entry.dockClickOpensWindow
        // what a click does now (without the window: "Open Claude" shows the details panel, as the Dock icon does)
        let shown = opens ? entry.clickAction.shortTitle
            : entry.clickAction == .details || (entry.clickAction == .open && !entry.claudeWindow) ? "Details panel" : "Usage panel"
        let brief = opens ? entry.clickAction == .peekThenOpen : shown == "Usage panel"     // the usage briefly: its duration
        SRow(label: "Click", info: "Usage, then Claude: the usage panel for a moment, then the Claude window. Open Claude: the Claude window straight away. Details panel: the large usage panel, and Claude only when you ask. Without a Claude window, or with Claude window ▸ Opens from ▸ Only when asked, a click shows the usage only: Usage panel (briefly) or Details panel.", picture: AnyView(ClickPicture(action: entry.clickAction, seconds: entry.peekSeconds))) {
            Menu {
                if opens {
                    Picker("", selection: $entry.clickAction) { ForEach(ClickAction.allCases) { Text($0.shortTitle).tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                } else {
                    Toggle("Usage panel", isOn: Binding(get: { shown == "Usage panel" }, set: { _ in
                        if entry.clickAction == .details || !entry.claudeWindow { entry.clickAction = .peekThenOpen }
                    }))
                    Toggle("Details panel", isOn: Binding(get: { shown == "Details panel" }, set: { _ in entry.clickAction = .details }))
                    Divider()
                    Button("Usage, then Claude") {}.disabled(true)
                    Button("Open Claude") {}.disabled(true)
                }
            } label: { MenuWell(text: shown, fill: true) }
            .faceMenuFill()
        }
        if entry.claudeWindow && !entry.opensFromDock {
            SRowLine(text: "Claude choices are off: Claude window ▸ Opens from is “Only when asked”.")
        } else if !entry.claudeWindow {
            SRowLine(text: "No Claude window: a click shows the usage only.")
        }
        if brief {
            SRow(label: "Usage shows for", info: "How long the usage panel stays up after a click" + (opens ? ", before the Claude window opens." : ".")) {
                MiniStepper(text: PeekDuration.text(entry.peekSeconds),
                            down: { entry.peekSeconds = PeekDuration.down(entry.peekSeconds) },
                            up: { entry.peekSeconds = PeekDuration.up(entry.peekSeconds) })
            }
        }
    }

    /// The Dock icon in a style, at the profile's numbers (samples when there are none yet).
    private func iconModel(_ st: IconStyle, _ h: Double? = nil, _ w: Double? = nil, countdown: TileCountdown? = nil) -> TileModel {
        TileModel(label: entry.label.isEmpty ? "?" : entry.label, fiveHour: h ?? status?.fiveHour ?? 58,
                  weekly: w ?? status?.weekly ?? 62, stale: false, style: st, tint: entry.color, frame: entry.frame,
                  fiveHourElapsed: 45, weeklyElapsed: 60, windowOpen: entry.windowDot, countdown: countdown)
    }

    /// The Dock icon's preview: not running, then as the limit fills up, full with its countdown.
    private var dockPreview: [PreviewStrip.Item] {
        let label = entry.label.isEmpty ? "?" : entry.label
        func tile(_ m: TileModel) -> AnyView { AnyView(Image(nsImage: Painter.image(m, pixels: 96)).resizable().frame(width: 38, height: 38)) }
        var items = [PreviewStrip.Item(title: "not running",
                                       picture: tile(Painter.notRunning(label: label, style: entry.style, tint: entry.color, frame: entry.frame)))]
        for s in PreviewStrip.states.dropFirst() {
            let full = (s.five ?? 0) >= 100
                ? AtLimit.tileCountdown(fiveHour: s.five, fiveHourResets: Date().addingTimeInterval(102 * 60), weekly: s.week, weeklyResets: nil) : nil
            items.append(.init(title: s.title, picture: tile(iconModel(entry.style, s.five, s.week, countdown: full))))
        }
        return items
    }

    // Claude window: its switch first, then whether it goes with the Dock icon and what may open it (the agent runs
    // this, whether or not cl_audit is open). Off, the card folds to the switch row.
    var windowCard: some View {
        let name = entry.name.isEmpty ? "this profile" : entry.name
        return SCard(title: "Claude window", info: "\(name)'s Claude window: its own (own sign-in, chats and settings), or the usual Claude app for ~/.claude. Whether it goes with the Dock icon and what may open it; the cl_audit agent does this, whether or not cl_audit is open.") {
            SRow(label: "Claude window", info: "On: a Claude window signed in to \(name)'s account; open it from the dashboard, the Dock icon or the menu bar icon. Off: none, and nothing opens one; its folder and sign-in are kept, so turning it back on needs no new sign-in.", first: true) {
                SSwitch(isOn: Binding(get: { entry.claudeWindow }, set: { model.setClaudeWindow(entry.id, $0) }),
                        on: entry.desktop == .standard ? "the usual Claude app" : "its own window", off: "none",
                        onShort: entry.desktop == .standard ? "the usual app" : nil)
                    .allowsHitTesting(model.dockRestarting == nil)      // waits for a Dock change, without dimming
            }
            if entry.claudeWindow {
                SRow(label: "With Dock icon", info: "On: quitting \(name)'s Dock icon quits its window too (Claude can ask about unsent work first; the Dock icon's menu then has “Quit and keep Claude window”), and, with Opens from ▸ Dock click too, starting the Dock icon (a click on its Dock tile, or its switch on the dashboard) opens the window. Not at login.") {
                    SSwitch(isOn: $entry.windowFollowsDock, on: entry.opensFromDock ? "opens and quits with it" : "quits with it", off: "on its own",
                            onShort: entry.opensFromDock ? "follows it" : nil)
                        .disabled(entry.iconHidden)
                }
                if entry.iconHidden { SRowLine(text: "No Dock icon to go with: Usage in the Dock is off.") }
                SRow(label: "Opens from", info: "Dock click too: a click on the Dock icon opens the window as its Click says, and so does starting the Dock icon with With Dock icon on. Only when asked: a Dock click shows the usage only; the dashboard's Open window key and tile, Open Claude in the Dock icon's and the menu bar icon's menus, and the details panel open it.") {
                    Menu {
                        Picker("", selection: $entry.opensFromDock) {
                            Text("Dock click too").tag(true)
                            Text("Only when asked").tag(false)
                        }
                        .pickerStyle(.inline).labelsHidden()
                    } label: { MenuWell(text: entry.opensFromDock ? "Dock click too" : "Only when asked", fill: true) }
                    .faceMenuFill()
                }
                if !entry.opensFromDock {
                    SRowLine(text: "A Dock click shows usage only; Open window and the Dock and menu bar menus open it.")
                }
            }
        }
    }

    // Alerts: how often the usage is read and when a notification comes
    var updatesCard: some View {
        SCard(title: "Alerts", info: "How often this profile's usage is read, and its Mac notifications: for the 5-hour, weekly and Fable limits, and for usage credits when they start and run out.") {
            SRow(label: "Refresh every", info: "How often cl_audit asks Anthropic for this profile's usage, with or without its Dock icon. Shorter is fresher; each check is one small request.", first: true) {
                Menu {
                    Picker("", selection: $entry.pollMinutes) { ForEach([2, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                } label: { MenuWell(text: "\(entry.pollMinutes) min", fill: true) }
                .faceMenuFill()
            }
            SRow(label: "Notify at", info: "A Mac notification when this profile's 5-hour, weekly or Fable limit reaches this level, when one is full (with when it's back), and when the profile starts spending usage credits or runs out of them. Off: no notifications.") {
                HStack(spacing: 8) {
                    SSwitch(isOn: $entry.notify, on: "", off: "off")        // on: the level beside it says the rest
                    if entry.notify {
                        MiniStepper(text: "\(entry.notifyPercent)%",
                                    down: { entry.notifyPercent = max(50, entry.notifyPercent - 5) },
                                    up: { entry.notifyPercent = min(100, entry.notifyPercent + 5) })
                    }
                }
                .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
            }
            SRow(label: "Notify when back", info: "One Mac notification when this profile's full 5-hour or weekly limit resets, so you know it works again (\"Claude \(entry.name.isEmpty ? "…" : entry.name) is back\"). Only for a limit that was full; while the other limit is still full, it waits for that one.") {
                SSwitch(isOn: $entry.notifyBack, on: "when a limit resets", off: "off")
            }
        }
    }

    /// A name or label edit, saved at once; if it clashes with another profile it isn't kept and the reason shows.
    func save(_ what: String, _ change: (inout AccountEntry) -> Void) -> String? {
        let old = entry
        change(&entry)
        if let p = model.problem {
            let tried = entry
            entry = old
            // said about this field when the name is the problem: which name is taken
            func key(_ n: String) -> String { n.trimmingCharacters(in: .whitespaces).lowercased() }
            let taken = tried.name != old.name && model.accounts.contains { $0.id != tried.id && key($0.name) == key(tried.name) }
            let said = taken ? "Another profile is called “\(tried.name.trimmingCharacters(in: .whitespaces))”" : p
            model.unsaved = said
            return said
        }
        model.saveNow(what)
        return nil
    }

    /// The panel preview: this account's latest numbers when known, otherwise samples.
    var sampleInfo: DetailsInfo {
        let s = status
        return DetailsInfo(
            name: entry.name.isEmpty ? "profile" : entry.name, icon: preview(entry, status: s),
            login: s?.loginEmail, expected: expected, mismatch: false, plan: s?.plan,
            fiveHour: s?.fiveHour ?? 23, fiveHourResets: s?.fiveHourResets ?? Date().addingTimeInterval(3 * 3600 + 20 * 60),
            weekly: s?.weekly ?? 58, weeklyResets: s?.weeklyResets ?? Date().addingTimeInterval(2 * 86400 + 5 * 3600),
            updated: s?.updatedAt, source: nil, problem: nil, renewNote: nil,
            needsLogin: false,
            design: entry.panelDesign, accent: entry.accentNSColor, noFiveHour: s?.noFiveHour == true)
    }

    /// A folder picked in Finder, used only if no other account has it and it's a Claude Code folder (or empty).
    func useFolder(_ path: String?) {
        guard let path else { return }
        if let owner = FolderRules.configOwner(path, among: model.accounts, except: entry.id) {
            model.message = FolderKey.canonical(owner.configDir) == FolderKey.canonical(path)
                ? "\(path) is already used by “\(owner.name)”." : "\(path) is inside, or contains, “\(owner.name)”'s folder."
            return
        }
        switch FolderKind.of(path) {
        case .other: model.message = "\(path) isn't a Claude Code folder and isn't empty."
        case .missing: model.message = "\(path) doesn't exist."
        default: entry.configDir = path
        }
    }
}

/// All icon styles as tiles with the account's numbers, grouped by family. The chosen style's good → bad
/// lane opens right under its tile, and tile and lane share one surface.
struct IconGallery: View {
    @Binding var entry: AccountEntry
    var status: IconStatus?
    @Environment(\.face) private var face
    static let states: [(Double, Double)] = [(5, 12), (30, 45), (58, 62), (84, 78), (97, 94)]
    static let columns = 4
    static let spacing: CGFloat = 4
    static let tileHeight: CGFloat = 74

    func model(_ st: IconStyle, _ h: Double? = nil, _ w: Double? = nil) -> TileModel {
        TileModel(label: entry.label.isEmpty ? "?" : entry.label, fiveHour: h ?? status?.fiveHour ?? 58,
                  weekly: w ?? status?.weekly ?? 62, stale: false, style: st, tint: entry.color, frame: entry.frame,
                  fiveHourElapsed: 45, weeklyElapsed: 60, windowOpen: entry.windowDot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(IconFamily.allCases) { fam in
                Printed(text: fam.title, size: 9).padding(.top, 6).padding(.bottom, 2)
                let rows = stride(from: 0, to: fam.styles.count, by: Self.columns).map {
                    Array(fam.styles[$0..<min($0 + Self.columns, fam.styles.count)])
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    if let col = row.firstIndex(of: entry.style) {
                        ZStack(alignment: .topLeading) {
                            TileLaneShape(column: col, columns: Self.columns, spacing: Self.spacing, tileHeight: Self.tileHeight)
                                .fill(LinearGradient(stops: face.win.stops, startPoint: .top, endPoint: .bottom)
                                    .shadow(.inner(color: face.win.inner, radius: face.win.innerRadius, y: face.win.innerY)))
                            VStack(spacing: 0) {
                                tiles(row)
                                lane.padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 9)
                            }
                        }
                        .padding(.bottom, 4)
                    } else {
                        tiles(row)
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }

    func tiles(_ row: [IconStyle]) -> some View {
        HStack(spacing: Self.spacing) {
            ForEach(0..<Self.columns, id: \.self) { i in
                if i < row.count { tile(row[i]) } else { Color.clear.frame(maxWidth: .infinity) }
            }
        }
        .frame(height: Self.tileHeight)
    }

    func tile(_ st: IconStyle) -> some View {
        let on = entry.style == st
        return VStack(spacing: 3) {
            Image(nsImage: Painter.image(model(st), pixels: 112)).resizable().frame(width: 48, height: 48)
            Text(st.shortTitle).font(.system(size: 10, weight: on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(on ? face.text : face.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { entry.style = st } }
        .help("\(st.title): \(st.blurb)")
    }

    /// The chosen style at about Dock size: first as the Dock shows it while the app isn't running (its icon
    /// file), then as the 5-hour limit fills up, under a bar in the level colours.
    var lane: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Preview").font(.system(size: 11, weight: .semibold))
                Text("not running, then as the limit fills up").font(.system(size: 10.5)).foregroundStyle(face.muted)
            }
            HStack(alignment: .bottom, spacing: 10) {
                VStack(spacing: 4) {
                    Text("not running").font(.system(size: 9.5)).foregroundStyle(face.muted).fixedSize()
                    Image(nsImage: Painter.image(Painter.notRunning(label: entry.label.isEmpty ? "?" : entry.label, style: entry.style,
                                                                     tint: entry.color, frame: entry.frame), pixels: 96))
                        .resizable().frame(width: 40, height: 40)
                        .help("What the Dock shows while this Dock icon isn't running")
                }
                Rectangle().fill(face.muted.opacity(0.35)).frame(width: 1, height: 56).padding(.bottom, 2)
                fillingUp
            }
        }
    }

    /// The five live tiles under the level bar.
    var fillingUp: some View {
        let segments = [Painter.green, Painter.green, Painter.amber, Painter.red, Painter.crimson]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                ForEach(0..<segments.count, id: \.self) { i in
                    Capsule().fill(Color(nsColor: segments[i])).frame(height: 3)
                }
            }
            .padding(.top, 2)
            HStack {
                Text("plenty left")
                Spacer()
                Text("half used")
                Spacer()
                Text("at limit")
            }
            .font(.system(size: 9.5)).foregroundStyle(face.muted)
            HStack(spacing: 0) {
                ForEach(Array(Self.states.enumerated()), id: \.offset) { _, v in
                    Image(nsImage: Painter.image(model(entry.style, v.0, v.1), pixels: 96)).resizable().frame(width: 40, height: 40)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// One surface for the selected tile and the lane under it: the tile's rounded top flows into the lane
/// with soft inner curves where they meet (none where the tile sits at the card's edge).
struct TileLaneShape: Shape {
    let column: Int
    let columns: Int
    let spacing: CGFloat
    let tileHeight: CGFloat
    var radius: CGFloat = 12
    var fillet: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let w = (rect.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let x0 = CGFloat(column) * (w + spacing), x1 = x0 + w
        let th = tileHeight, r = radius, f = fillet
        let atLeft = column == 0, atRight = column == columns - 1
        var p = Path()
        p.move(to: CGPoint(x: x0 + r, y: 0))
        p.addLine(to: CGPoint(x: x1 - r, y: 0))
        p.addQuadCurve(to: CGPoint(x: x1, y: r), control: CGPoint(x: x1, y: 0))
        if atRight {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        } else {
            p.addLine(to: CGPoint(x: x1, y: th - f))
            p.addQuadCurve(to: CGPoint(x: x1 + f, y: th), control: CGPoint(x: x1, y: th))
            p.addLine(to: CGPoint(x: rect.maxX - r, y: th))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: th + r), control: CGPoint(x: rect.maxX, y: th))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        }
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - r), control: CGPoint(x: 0, y: rect.maxY))
        if atLeft {
            p.addLine(to: CGPoint(x: 0, y: r))
        } else {
            p.addLine(to: CGPoint(x: 0, y: th + r))
            p.addQuadCurve(to: CGPoint(x: r, y: th), control: CGPoint(x: 0, y: th))
            p.addLine(to: CGPoint(x: x0 - f, y: th))
            p.addQuadCurve(to: CGPoint(x: x0, y: th - f), control: CGPoint(x: x0, y: th))
            p.addLine(to: CGPoint(x: x0, y: r))
        }
        p.addQuadCurve(to: CGPoint(x: x0 + r, y: 0), control: CGPoint(x: x0, y: 0))
        p.closeSubpath()
        return p
    }
}

struct Swatch: View {
    let color: TileColor
    let selected: Bool
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            if color == .usage {
                Circle().fill(AngularGradient(colors: [Color(nsColor: Painter.green), Color(nsColor: Painter.amber),
                                                       Color(nsColor: Painter.red), Color(nsColor: Painter.crimson), Color(nsColor: Painter.green)],
                                              center: .center))
            } else {
                Circle().fill(Color(nsColor: color.color(fiveHour: nil, stale: false)))
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.black(0.45), lineWidth: 1))
        .overlay { if selected { SwatchRing() } }
        .padding(4)
        .contentShape(Circle())
    }
}

/// The chosen swatch: a ring lit in the LED's orange, a little apart from the colour.
struct SwatchRing: View {
    var body: some View {
        Circle().stroke(FaceTheme.led, lineWidth: 1.5).padding(-3.5)
            .shadow(color: FaceTheme.led.opacity(0.55), radius: 3)
    }
}


struct NoneSwatch: View {
    let selected: Bool
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary, lineWidth: 1.5)
            Rectangle().fill(Color.hex(0xf87171)).frame(width: 1.5, height: size + 2).rotationEffect(.degrees(45))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { if selected { SwatchRing() } }
        .padding(4)
        .contentShape(Circle())
    }
}

/// The icon as the Dock would show it, with the account's latest numbers or sample ones.
/// The account's Dock icon; without a status it shows sample usage (23 % and 41 %), or none when `sample` is off.
func preview(_ e: AccountEntry, status: IconStatus?, style: IconStyle? = nil, tick: Int = 0, sample: Bool = true) -> NSImage {
    let expected = Account.expectedEmail(configDir: e.configDir)
    let warn = status?.loginEmail.map { $0.lowercased() != expected?.lowercased() } ?? false
    let m = TileModel(label: e.label.isEmpty ? "?" : e.label,
                      fiveHour: status?.fiveHour ?? (sample ? 23 : nil), weekly: status?.weekly ?? (sample ? 41 : nil),
                      stale: false, style: style ?? e.style, warn: warn && expected != nil, tint: e.color,
                      frame: e.frame)
    return Painter.image(m, pixels: 128)
}

/// Settings is a page of the one cl_audit window, not a window of its own.
enum SettingsWindow {
    static func show() {
        (NSApp.delegate as? AppDelegate)?.manager.showMain(page: .settings)
    }
}

/// App and Edit menus, so the settings window gets Quit and copy/paste shortcuts.
enum MainMenu {
    static func install() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Uninstall cl_audit…", action: #selector(AppDelegate.showUninstall), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit cl_audit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Dashboard", action: #selector(AppDelegate.showMainScreen), keyEquivalent: "0")
        window.addItem(withTitle: "Launcher", action: #selector(AppDelegate.showLauncher), keyEquivalent: "l")
        window.addItem(.separator())
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        NSApp.mainMenu = main
    }
}
