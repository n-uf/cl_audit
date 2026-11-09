// SwitchRunner: one switch, step by step, for the Switch page (SwitchView.swift), with SwitchEngine doing the moving.
//
//   1. the profile's Claude window closes (gracefully; only that window, by its data folder; never force-quit)
//   2. a backup of its sessions is made (SessionsBackup.swift), then they and its scheduled tasks move to the other
//      account (the answer to "Move them?"), with a receipt that names the backup
//   3. Claude Code signs in as that account, in Terminal with the address filled in; the window stays closed meanwhile,
//      and Cancel puts the sessions back (Undo from the receipt)
//   4. once the folder names that account, the profile works on it; the old account joins standby
//   5. the window opens again; its own sign-out and sign-in to that account finish the switch
//   6. on that account, a new Code session in the window arranges the sidebar as before (SwitchSidebar.swift): the
//      operator presses Return in it
//
// After step 4 the way back is a switch the other way. The sidebar's groups, order and pins are synced per account
// by claude.ai, so cl_audit doesn't write them: the window's own sidebar tools do, in step 6.

import AppKit

final class SwitchRunner: ObservableObject {
    enum Phase: Equatable {
        case ready
        case closing                    // asked the window to quit; waiting
        case moving
        case codeSignIn                 // Terminal shows Claude Code's sign-in; waiting for the folder to name the account
        case windowSignIn               // switched; the window waits for its own sign-in to that account
        case sidebar                    // the window is on it; a session there arranges the sidebar (one Return)
        case done
        case cancelled                  // the sessions went back (Undo)
        case failed(String)
    }

    let profile: String
    let standby: String
    /// Each change may end or start a switch that stopped half way: the tile beside the profile looks again at once.
    @Published private(set) var phase: Phase = .ready { didSet { model?.forgetUnfinished() } }
    @Published private(set) var receipt: SwitchReceipt?
    @Published private(set) var note: String?            // a word under the steps (signed in as another account, …)
    @Published private(set) var sidebarOpened = false     // the session that arranges the sidebar was opened
    @Published private(set) var sidebarMissed = false     // the link didn't reach the window (the page marks step 5)
    /// The link reached the window (or was opened as the only Claude window): the session is there, waiting for Return.
    /// Only then does the waiting alert (SwitchWaiting.swift) ask for it.
    @Published private(set) var sidebarLinkSent = false
    /// Before the switch: the account it leaves signed in once to a folder of its own (so its limits keep showing), or
    /// skipped.
    @Published private(set) var ownFolder: OwnFolder = .idle
    enum OwnFolder { case idle, signing, skipped }
    /// The sessions question, asked every time with no answer chosen: move them to the account switched to (with a
    /// backup), or leave them with each account. Fixed once the switch starts.
    @Published var moveSessions: Bool?
    /// Whether the backup made before the sessions move takes Claude Code's transcripts too (on by default). The page
    /// toggles it before the switch starts; fixed once it has.
    @Published var backupTranscripts = true
    /// "Undo this switch…": this switch goes back the other way, and then anything the switch it undoes changed is put back
    /// from that switch's backup (the Restore page, opened with that backup; SessionsRestore.swift). nil: an ordinary switch.
    @Published var undoes: SwitchUndo?
    struct SwitchUndo: Equatable { var receipt: String; var backup: String; var place: String }
    /// The backup made before the sessions move, as soon as it exists (the engine reports it before the first move):
    /// the page shows it, also when the switch stops after.
    struct BackupRef: Equatable { var id: String; var place: String }
    @Published private(set) var backupMade: BackupRef?
    /// The backup couldn't be made (or the window opened while it was): step 1 failed, nothing moved.
    @Published private(set) var backupFailed = false
    /// The backup this switch made: reported by the engine, else named by the receipt.
    var backupRef: BackupRef? {
        backupMade ?? receipt.flatMap { r in r.backup.map { BackupRef(id: $0, place: r.backupPlace ?? BackupPrefs.placeURL.path) } }
    }
    /// The step that failed (1–5), shown red on the page; nil while nothing failed.
    @Published private(set) var failedStep: Int?
    /// What each sign-in check saw: Claude Code's folder and the window, as short names for the page (nil until seen),
    /// and whether it's the account switched to (compared by account id: short names can be alike).
    @Published private(set) var codeSeen: String?
    @Published private(set) var windowSeen: String?
    @Published private(set) var codeOnTarget: Bool?
    @Published private(set) var windowOnTarget: Bool?
    private weak var model: SettingsModel?
    private var timer: Timer?
    private var started = Date()
    /// The account switched to, as it was on standby: once linked it's no longer there, and its page keeps showing it
    /// from this copy (each runner its own, so several profiles' pages never mix them up).
    private(set) var targetSnapshot: StandbyAccount?
    /// Watches the window after a Cancel while it was asked to quit (its own timer: the steps' timer is another's).
    private var reopenTimer: Timer?

    init(profile: String, standby: String, model: SettingsModel) {
        self.profile = profile; self.standby = standby; self.model = model
        targetSnapshot = model.accounts.first { $0.id == profile }?.standby.first { $0.id == standby }
    }

    /// The account switched to, short ("ultra-2").
    var targetShort: String? { (target?.email ?? targetSnapshot?.email).map(AccountNames.short) }

    /// Between Close and switch and Done: the window is closed or waiting for a sign-in.
    var isRunning: Bool {
        switch phase {
        case .closing, .moving, .codeSignIn, .windowSignIn, .sidebar: return true
        default: return false
        }
    }

    /// How many steps this switch has: the sidebar's is the fifth (the sessions move and there's a Claude window to arrange).
    var stepCount: Int { moveSessions == true && entry?.claudeWindow == true ? 5 : 4 }

    private func fail(_ why: String, step: Int?) { failedStep = step; undoStopped = false; phase = .failed(why) }
    /// Undo itself stopped part way (the receipt keeps the rest for another try).
    @Published private(set) var undoStopped = false

    var key: String { AccountEntry.standbyStatusID(profile, standby) }
    private var entry: AccountEntry? { model?.accounts.first { $0.id == profile } }
    private var target: StandbyAccount? { entry?.standby.first { $0.id == standby } }
    /// The profile's window, by its data folder (it doesn't change in a switch): what SwitchMarker marks.
    private var window: String? { entry.map { Launcher.dataDirKey(of: Account($0)) } }
    private func releaseWindow() { if let w = window { SwitchMarker.release(w, profile: profile, standby: standby) } }

    // MARK: the window

    /// The profile's own Claude window (by its data folder), if it runs.
    static func windowApps(_ e: AccountEntry) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
            .filter { !$0.isTerminated && Launcher.isWindow(of: Account(e), $0) }
    }

    static func windowClosed(_ e: AccountEntry) -> Bool { windowApps(e).isEmpty }

    // MARK: before going: the account it leaves keeps its limits showing

    /// The account in use has a folder of its own, signed in to it (its numbers come from there; Accounts.swift).
    static func hasOwnFolder(_ e: AccountEntry) -> Bool {
        guard let k = e.keptFolder, !k.isEmpty else { return false }
        return FolderFactsCache.facts(k).map { $0.seat.same(e.seat) } ?? false
    }

    /// Sign the account in use in once to a folder of its own (made now if it has none), in Terminal with its address
    /// filled in; done when that folder names it.
    func keepOwnFolder() {
        guard let m = model, let i = m.accounts.firstIndex(where: { $0.id == profile }), let email = m.accounts[i].seat?.email else { return }
        guard let claude = m.requireClaude() else { note = m.noClaudeWhy; return }
        var dir = m.accounts[i].keptFolder ?? ""
        if dir.isEmpty {
            guard let made = StandbyFolder.make(for: email) else { note = "Couldn't make a folder for its sign-in in your home folder."; return }
            dir = made
            m.accounts[i].keptFolder = made
        }
        let e = m.accounts[i]
        ClaudeCLI.openLogin(claude, account: Account(AccountEntry(id: e.id, name: e.name, label: e.label, configDir: dir)), email: email)
        note = nil
        ownFolder = .signing
        started = Date()
        tick(every: 2) { [weak self] in
            guard let self, self.phase == .ready, let e = self.entry else { return true }
            if Self.hasOwnFolder(e) { self.ownFolder = .idle; return true }      // the cache follows .claude.json's date
            return Date().timeIntervalSince(self.started) > 15 * 60          // given up on after a while; the key stays
        }
    }

    /// Switch without it: the account it leaves shows its limits as last read ("hasn't been read since").
    func skipOwnFolder() { timer?.invalidate(); ownFolder = .skipped }

    /// Another account picked on the page before it starts: the answers given so far go with it.
    func carry(from other: SwitchRunner) {
        guard phase == .ready, receipt == nil else { return }
        moveSessions = other.moveSessions
        backupTranscripts = other.backupTranscripts
        if other.ownFolder == .skipped { ownFolder = .skipped }
    }

    // MARK: going

    func start() {
        guard phase == .ready || isFailed || phase == .cancelled, let e = entry, let s = target, let w = window else { return }
        // the sessions question has no default: the page's key waits for an answer
        guard let follow = moveSessions else { note = "Choose first: move the sessions, or leave them."; return }
        note = nil; failedStep = nil; codeSeen = nil; windowSeen = nil; codeOnTarget = nil; windowOnTarget = nil
        sidebarOpened = false; sidebarMissed = false; sidebarLinkSent = false; undoStopped = false
        backupMade = nil; backupFailed = false
        reopenTimer?.invalidate(); reopenTimer = nil
        targetSnapshot = s
        // a switch that stopped half way is put back first: never a second move on top of it
        guard SwitchEngine.unfinished(profile: profile).isEmpty else {
            fail("An earlier switch of \(e.name) didn't finish: Undo it first.", step: nil); return
        }
        switch SwitchEngine.plan(e, standby: s, follow: follow) {
        case .failure(let why): fail(why.description, step: nil); return
        case .success: break
        }
        // the window stays closed from here until the profile is linked or the switch is undone; one switch at a time
        guard SwitchMarker.claim(w, profile: profile, standby: standby) else {
            fail("Another switch of this Claude window is under way.", step: nil); return
        }
        receipt = nil                                 // a cancelled run's receipt: this run writes its own
        let apps = Self.windowApps(e)
        if apps.isEmpty { move(follow: follow) ; return }
        phase = .closing
        apps.forEach { $0.terminate() }               // the window's own quit: it may ask about work under way
        started = Date()
        tick(every: 0.5) { [weak self] in
            guard let self, let e = self.entry else { return true }
            if Self.windowClosed(e) { self.move(follow: follow); return true }
            if Date().timeIntervalSince(self.started) > 45 {
                self.releaseWindow()
                self.fail("The window didn't close; it may be asking about work under way. Answer it, then try again. Nothing moved.", step: 1)
                return true
            }
            return false
        }
    }

    private var isFailed: Bool { if case .failed = phase { return true }; return false }

    /// `follow`: the sessions answer start() checked, never read again here.
    private func move(follow: Bool) {
        guard let e = entry, let s = target, case .success(var plan) = SwitchEngine.plan(e, standby: s, follow: follow) else {
            releaseWindow()
            fail("The switch couldn't be planned again. Nothing moved.", step: 2); return
        }
        plan.backupTranscripts = backupTranscripts      // as it was when the switch started
        plan.undoes = undoes?.receipt                   // Undo this switch: the receipt names the switch it undoes
        phase = .moving
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try SwitchEngine.run(plan, windowClosed: { Self.windowClosed(e) }, backupMade: { id, place in
                    DispatchQueue.main.async { [weak self] in self?.backupMade = BackupRef(id: id, place: place) }
                })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let r):
                    self.receipt = r
                    if !r.problems.isEmpty { self.note = r.problems.joined(separator: " ") }   // each one a sentence
                    self.signInCode()
                case .failure(let err):
                    // stopped half way: its receipt, for Undo (the window stays closed until then); nothing moved: free
                    self.receipt = SwitchEngine.unfinished(profile: self.profile).first
                    if self.receipt == nil { self.releaseWindow() }
                    var step = 2
                    if case SwitchError.backup = err { self.backupFailed = true; step = 1 }
                    self.fail("\(err)", step: step)
                }
            }
        }
    }

    /// Claude Code's own sign-in for the profile's folder, with the account's address filled in.
    func signInCode() {
        guard let e = entry, let s = target else { return }
        phase = .codeSignIn
        if let claude = model?.claudeNow() { ClaudeCLI.openLogin(claude, account: Account(e), email: s.email) }
        else { note = ClaudeInstall.missing + ". Install it (\(ClaudeInstall.command)), then sign in again." }
        started = Date()
        tick(every: 2) { [weak self] in
            guard let self, let e = self.entry, let s = self.target, let to = s.seat else { return true }
            guard let now = Account.signedInSeat(configDir: e.configDir) else { return false }
            // checked against the account switched to before going on (set only when it changes: each change redraws)
            let seen = now.email.map(AccountNames.short) ?? "another account", on = now.same(to)
            if self.codeSeen != seen { self.codeSeen = seen }
            if self.codeOnTarget != on { self.codeOnTarget = on }
            if on { self.linked(); return true }
            if let from = e.seat, now.same(from) { return false }        // not yet
            self.note = "Claude Code signed in as \(Privacy.masked(now.email ?? "another account")), not \(Privacy.masked(s.email)): sign in again."
            return false
        }
    }

    /// Claude Code is on the new account: the profile works on it now, the old one stands by; the window opens again.
    private func linked() {
        guard let m = model, let before = entry, let out = FolderRules.completeSwitch(profile, to: standby, in: m.accounts) else {
            fail("The profile couldn't be linked to the new account.", step: 4); return
        }
        // each account keeps its own numbers: never the old account's under the new one's name; moved before the profile
        // is saved, so the agent's readers for the new arrangement start from them
        if let after = out.first(where: { $0.id == profile }) { FolderRules.moveNumbers(before, after) }
        m.accounts = out
        // linked: the way back is a switch now, and the window may open again; switched back: no "is back" offer left
        if let id = receipt?.id { SwitchEngine.markLinked(id); receipt = SwitchEngine.load(id) ?? receipt }
        BackWatch.dismiss(key)
        releaseWindow()
        note = nil
        phase = .windowSignIn
        guard let e = entry else { return }
        if e.claudeWindow { Launcher.openClaude(Account(e)) }
        let to = e.seat?.account
        tick(every: 2) { [weak self] in
            guard let self, let e = self.entry else { return true }
            // checked against the account switched to: the page waits until the window reports it
            if e.claudeWindow, let seen = FolderRules.windowAccount(e) {
                let known = ([e.seat] + e.standby.map(\.seat)).compactMap { $0 }.first { $0.account == seen }
                let name = known?.email.map(AccountNames.short) ?? "another account", on = seen == to
                if self.windowSeen != name { self.windowSeen = name }
                if self.windowOnTarget != on { self.windowOnTarget = on }
            }
            guard !e.claudeWindow || FolderRules.windowAccount(e) == to else { return false }
            if e.claudeWindow, self.sidebarPlan != nil {
                self.phase = .sidebar
                // a moment for the window to settle on the account before the link reaches it
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    if self?.phase == .sidebar, self?.sidebarOpened == false { self?.arrangeSidebar() }
                }
            } else {
                self.phase = .done
            }
            return true
        }
    }

    // MARK: the sidebar

    /// The moved sessions' groups and pins to put back, or nil when there's nothing to arrange.
    var sidebarPlan: SidebarPlan? { receipt?.sidebar.flatMap { $0.isEmpty ? nil : $0 } }

    /// Opens a new Code session in the profile's window with the sidebar plan: the operator presses Return there. The
    /// link goes to that window's own process (WindowLink). Without leave to send it there, it's opened the usual way
    /// only when no other Claude window runs; otherwise nothing opens and the page says what to do.
    func arrangeSidebar() {
        guard let plan = sidebarPlan, let e = entry, let url = plan.link(folder: SidebarPlan.helperFolder) else { return }
        sidebarOpened = true; sidebarMissed = false; sidebarLinkSent = false
        note = nil
        Launcher.openClaude(Account(e))
        let started = Date()
        tick(every: 1) { [weak self] in
            guard let self, let e = self.entry else { return true }
            guard let pid = Self.windowApps(e).first?.processIdentifier else {
                if Date().timeIntervalSince(started) < 20 { return false }
                self.sidebarOpened = false
                self.note = "The window didn't open. Open it, then Open the session."
                self.sidebarMissed = true
                return true
            }
            let alone = NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
                .allSatisfy { $0.isTerminated || $0.processIdentifier == pid }
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = WindowLink.send(url, to: pid)
                DispatchQueue.main.async { [weak self] in self?.linkSent(outcome, url: url, alone: alone, pid: pid, name: e.name) }
            }
            return true
        }
    }

    private func linkSent(_ outcome: WindowLink.Outcome, url: URL, alone: Bool, pid: pid_t, name: String) {
        // still the profile's window, still the only Claude window: then `open` can only reach it
        let stillAlone: Bool = {
            guard alone, let e = entry, Self.windowApps(e).contains(where: { $0.processIdentifier == pid }) else { return false }
            return NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
                .allSatisfy { $0.isTerminated || $0.processIdentifier == pid }
        }()
        switch outcome {
        case .sent:
            sidebarLinkSent = true
        case .notAllowed where stillAlone:
            NSWorkspace.shared.open(url)                  // the only Claude window: the link can't reach another
            sidebarLinkSent = true
        case _ where entry.map({ Self.windowApps($0).contains { $0.processIdentifier == pid } }) != true:
            sidebarOpened = false; sidebarMissed = true   // never `open` then: it could start another account's window
            note = "\(name)'s window quit before the link reached it. Open the window, then Open the session."
        case .notAllowed:
            sidebarOpened = false; sidebarMissed = true
            note = "cl_audit may not send the link to \(name)'s window, and other Claude windows are open, so nothing opened. Allow cl_audit to control Claude (System Settings ▸ Privacy & Security ▸ Automation), or quit the other Claude windows, then Open the session."
        case .failed(let code):
            sidebarOpened = false; sidebarMissed = true
            note = "The link didn't reach \(name)'s window (\(code)). Open the session to try again."
        }
    }

    /// Cancel before Claude Code signed in: the sessions go back (the window is still closed then); nothing else changed.
    func cancel() {
        timer?.invalidate()
        guard let r = receipt, r.linked == nil, phase == .codeSignIn || isFailed else {
            let wasClosing = phase == .closing
            releaseWindow(); phase = .ready
            if wasClosing { reopenIfItCloses() }
            return
        }
        undoUnfinished(r.id)
    }

    /// Cancelled while the window was asked to quit: it may still close (its own question answered later). Then it
    /// opens again, as it was before the switch; watched for a minute, or until another start.
    private func reopenIfItCloses() {
        guard let e = entry, e.claudeWindow else { return }
        note = "Cancelled. The window was already asked to quit: if it closes, cl_audit opens it again."
        let since = Date()
        reopenTimer?.invalidate()
        reopenTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            let over: Bool = {
                guard let self, self.phase == .ready, let e = self.entry else { return true }
                if Self.windowClosed(e) { Launcher.openClaude(Account(e)); return true }
                return Date().timeIntervalSince(since) > 60
            }()
            guard over else { return }
            t.invalidate()
            if self?.reopenTimer === t { self?.reopenTimer = nil }
            if self?.note?.hasPrefix("Cancelled. The window was already asked") == true { self?.note = nil }
        }
    }

    /// Undo of a switch that stopped half way or was cancelled (this one, or an earlier one the page found unfinished):
    /// what it moved goes back, then the window may open again.
    func undoUnfinished(_ id: String) {
        timer?.invalidate()
        guard let e = entry else { return }
        guard Self.windowClosed(e) else { note = "Quit \(e.name)'s Claude window first, then Undo."; return }
        do {
            let r = try SwitchEngine.undo(id, windowClosed: { Self.windowClosed(e) })
            if receipt == nil || receipt?.id == id { receipt = r }
            releaseWindow()
            note = nil
            phase = .cancelled
            if e.claudeWindow { Launcher.openClaude(Account(e)) }
        } catch {
            fail("Undo didn't finish: \(error). The receipt is in cl_audit's folder (switches/\(id)).", step: 2)
            undoStopped = true
        }
    }

    /// The window signed in later, or not at all: the switch itself is done.
    func finish() { timer?.invalidate(); releaseWindow(); phase = .done }

    /// Renders only: the page as it looks at a step.
    func preview(_ p: Phase, receipt r: SwitchReceipt? = nil, note n: String? = nil, sidebarOpened o: Bool = false,
                 moves: Bool? = nil, failedStep f: Int? = nil, codeSeen c: String? = nil, windowSeen w: String? = nil,
                 sidebarMissed m: Bool = false, undoStopped u: Bool = false, codeOn: Bool? = nil, windowOn: Bool? = nil,
                 linkSent: Bool = false, backup b: BackupRef? = nil, backupFailed bf: Bool = false) {
        phase = p; receipt = r; note = n; sidebarOpened = o; sidebarLinkSent = linkSent; backupMade = b; backupFailed = bf
        moveSessions = moves; failedStep = f; codeSeen = c; windowSeen = w; sidebarMissed = m; undoStopped = u
        codeOnTarget = codeOn; windowOnTarget = windowOn
    }

    private func tick(every s: TimeInterval, _ step: @escaping () -> Bool) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: s, repeats: true) { [weak self] t in
            if step() { t.invalidate(); if self?.timer === t { self?.timer = nil } }
        }
    }
}
