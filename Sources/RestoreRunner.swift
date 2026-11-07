// RestoreRunner: one restore of a backup, step by step, for the Restore page (RestorePage.swift), with SessionsRestore
// doing the writing.
//
//   preview   counted from the backup against what is there now; nothing is written, and the page says why a restore
//             may not start yet (a switch that stopped half way, another switch/restore/import, claude-transplant)
//   1. the profile's Claude window closes (only if something in the window comes back; the same quit as a switch)
//   2. what's listed comes back, merged and never overwriting (SessionsRestore.run), with a receipt as it goes
//   3. the window opens again (if it was closed for this); the sidebar's groups and pins are arranged by one Return in a
//      helper session, as after a switch (the same link, the same plan type)
//
// Stop keeps what is back; Finish picks up from the same receipt (also after cl_audit stopped: the tile of the profile
// shows "Restore stopped" and the page opens on it); Undo takes back exactly what the receipt says it put back.

import AppKit

/// Which backup a Restore page is about: the profile, the backup and where it is (General ▸ Backups, or the place a
/// receipt recorded), or a stopped restore to finish, and the switch it undoes when it follows "Undo this switch".
struct RestoreKey: Equatable {
    var profile: String
    var backup: String
    var place: String
    var resume: String? = nil               // a stopped restore's receipt
    var afterSwitch: String? = nil          // Undo this switch: the receipt of the switch that was switched back
    var id: String { "\(profile)/\(backup)/\(resume ?? "")" }
}

final class RestoreRunner: ObservableObject {
    enum Phase: Equatable {
        case ready                      // the preview
        case closing                    // asked the window to quit; waiting
        case writing
        case undoing                    // Undo this restore: taking back what the receipt says it put back
        case sidebar                    // back; a helper session arranges the sidebar (one Return)
        case done
        case stopped(String)            // some are back, the receipt is unfinished: Finish or Undo
        case failed(String)             // nothing was written
        case undone
    }

    /// Why a restore may not start yet.
    struct NotYet: Equatable {
        var title: String
        var words: String
        var switchKey: String?          // "Open the switch"
    }

    let key: RestoreKey
    private weak var model: SettingsModel?
    /// Each change may end or start a restore that stopped half way: the tile beside the profile looks again at once (not
    /// while the runner is made, which happens while a page is being drawn).
    @Published private(set) var phase: Phase = .ready { didSet { if started { model?.forgetRestore() } } }
    private var started = false
    private var frozen = false          // renders only: a preview's numbers are not counted again
    @Published private(set) var plan: SessionsRestore.Plan?          // nil: still counting
    @Published private(set) var notYet: NotYet?
    @Published private(set) var receipt: SessionsRestore.Receipt?
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    @Published private(set) var note: String?
    @Published private(set) var manifest: SessionsBackup.Manifest?
    @Published private(set) var sidebarOpened = false
    @Published private(set) var sidebarMissed = false
    @Published private(set) var sidebarLinkSent = false
    @Published private(set) var keepFailed: String?
    private var timer: Timer?
    private var reopenTimer: Timer?
    private let stopLock = NSLock()
    private var stopFlag = false
    private var closedByUs = false
    /// This runner put its own mark on the window (SwitchMarker): only then does it take it off. A mark that is a switch's
    /// (the same process runs both) is never ours to release.
    private var claimedByUs = false
    /// The window is being closed for an Undo this restore (not for a restore): Cancel then goes back to where it was.
    @Published private(set) var undoing = false
    private var priorPhase: Phase = .ready

    init(key: RestoreKey, model: SettingsModel) {
        self.key = key; self.model = model
        manifest = SessionsBackup.load(profile: key.profile, id: key.backup, place: URL(fileURLWithPath: key.place))
        if let id = key.resume, let r = SessionsRestore.load(id) {
            receipt = r
            if r.undone != nil { phase = .undone }
            else if r.finished != nil { phase = .done }
            else { phase = .stopped(r.stopped ?? "It stopped half way; the Mac may have stopped.") }
        }
        started = true
    }

    var entry: AccountEntry? { model?.accounts.first { $0.id == key.profile } }
    var backup: SessionsRestore.Backup { SessionsRestore.Backup(profile: key.profile, id: key.backup, place: URL(fileURLWithPath: key.place)) }
    private var window: String? { entry.map { Launcher.dataDirKey(of: Account($0)) } }
    /// This runner's own name on the window's mark ("restore-<8 characters>"): two restore pages of one profile never share
    /// a mark, and the engine lets through only the mark of the runner that asks.
    let markName = "restore-" + UUID().uuidString.prefix(8).lowercased()
    private func releaseWindow() {
        if claimedByUs, let w = window { SwitchMarker.release(w, profile: key.profile, standby: markName) }
        claimedByUs = false
    }

    /// The mark on the window for this runner; false when another switch or restore holds it.
    private func claimWindow(_ w: String) -> Bool {
        guard SwitchMarker.claim(w, profile: key.profile, standby: markName) else { return false }
        claimedByUs = true
        return true
    }

    /// Between Close and restore and the end: the window is closed or being written to.
    var isRunning: Bool {
        switch phase {
        case .closing, .writing, .undoing, .sidebar: return true
        default: return false
        }
    }

    /// The window is being closed or files are being written or taken back: not the sidebar step, which waits for the operator.
    var isBusy: Bool {
        switch phase {
        case .closing, .writing, .undoing: return true
        default: return false
        }
    }

    /// Where Cancel (or a failed Undo) goes back to: the sidebar step is over by then, so it is Restored.
    private func returnPhase(_ p: Phase) -> Phase { p == .sidebar ? .done : p }

    /// The restore is the one this page is about and it can still be started: preview, nothing under way.
    var isReady: Bool { phase == .ready }

    var resumeID: String? { key.resume ?? receipt.flatMap { $0.unfinished ? $0.id : nil } }

    /// A step 1 that is needed: something in the window comes back.
    var needsWindow: Bool { plan?.windowNeeded ?? false }

    // MARK: the preview (read-only), off the main thread

    func refresh() {
        guard !frozen else { return }
        switch phase {
        case .ready, .stopped: break
        default: return
        }
        guard let e = entry else { return }
        let target = SessionsRestore.Target(e), b = backup, resume = resumeID, profile = key.profile
        let w = window
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = SessionsRestore.plan(target, b)
            var not: NotYet?
            if let why = SessionsRestore.blocker(profile: profile, except: resume) {
                not = NotYet(title: why.switchKey != nil ? "A switch of \(e.name) is unfinished" : "A restore of \(e.name) is unfinished",
                             words: why.words, switchKey: why.switchKey)
            } else if p.windowNeeded, let m = w.flatMap({ SwitchMarker.current($0) }) {       // only a restore that writes in the window waits for it
                not = NotYet(title: "A switch of \(e.name) is under way", words: "Its window stays closed until the switch is linked or undone. Wait for it, or open it.",
                             switchKey: AccountEntry.standbyStatusID(m.profile, m.standby))
            } else if let why = SessionsRestore.busy() {
                not = NotYet(title: why.contains("claude-transplant") ? "claude-transplant is moving sessions" : "Another switch, restore or import is under way",
                             words: why, switchKey: nil)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.plan = p; self.notYet = not
                if self.manifest == nil { self.manifest = p.manifest }
            }
        }
    }

    // MARK: going

    func start() {
        let resuming: Bool = { if case .stopped = phase { return true }; return false }()
        // a stopped restore with nothing left to write can still be finished (it is only marked so)
        guard phase == .ready || resuming, let e = entry, let p = plan, p.refusal == nil, p.count > 0 || resuming, notYet == nil, let w = window else { return }
        note = nil; keepFailed = nil
        stopLock.lock(); stopFlag = false; stopLock.unlock()
        progress = (receipt?.back ?? 0, (receipt?.back ?? 0) + p.count)
        reopenTimer?.invalidate(); reopenTimer = nil
        guard p.windowNeeded else { write(); return }
        // the window stays closed from here until the restore ends; one at a time
        guard claimWindow(w) else {
            note = "Another switch or restore of this Claude window is under way."; return
        }
        let apps = SwitchRunner.windowApps(e)
        if apps.isEmpty { write(); return }
        closeWindow(apps, then: { [weak self] in self?.write() }, giveUp: { [weak self] in
            guard let self else { return }
            self.phase = self.receipt?.unfinished == true ? .stopped("The window didn't close; nothing more was written.") : .ready
            self.note = "The window didn't close; it may be asking about work under way. Answer it, then try again. Nothing was written."
        })
    }

    /// The profile's window is asked to quit (only that one; it may ask about work under way) and watched for 45 seconds;
    /// `then` runs once it is closed, `giveUp` (after the mark is let go) when it isn't.
    private func closeWindow(_ apps: [NSRunningApplication], then go: @escaping () -> Void, giveUp: @escaping () -> Void) {
        closedByUs = true
        phase = .closing
        apps.forEach { $0.terminate() }
        let started = Date()
        tick(every: 0.5) { [weak self] in
            guard let self, let e = self.entry else { return true }
            if SwitchRunner.windowClosed(e) { go(); return true }
            if Date().timeIntervalSince(started) > 45 {
                self.releaseWindow()
                self.closedByUs = false
                giveUp()
                return true
            }
            return false
        }
    }

    private func write() {
        guard let e = entry else { return }
        let target = SessionsRestore.Target(e), b = backup, resume = resumeID, afterSwitch = key.afterSwitch, mark = markName
        phase = .writing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try SessionsRestore.run(target, b, continuing: resume, afterSwitch: afterSwitch, mark: mark, windowClosed: { SwitchRunner.windowClosed(e) },
                                        stop: { self?.stopRequested ?? true },
                                        progress: { d, t in DispatchQueue.main.async { self?.progress = (d, t) } })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let r):
                    self.receipt = r
                    self.finish(r)
                case .failure(let err):
                    // stopped part way: the receipt is there for Finish and Undo; nothing written: back to the preview
                    let unfinished = SessionsRestore.unfinished(profile: self.key.profile).first
                    self.receipt = unfinished
                    self.releaseWindow()
                    if self.closedByUs, let e = self.entry, e.claudeWindow { Launcher.openClaude(Account(e)) }
                    self.closedByUs = false
                    if let u = unfinished { self.phase = .stopped(u.stopped ?? "\(err)"); self.refresh() }       // what is still missing
                    else { self.phase = .failed("\(err)") }
                    self.note = "\(err)"
                }
            }
        }
    }

    private var stopRequested: Bool { stopLock.lock(); defer { stopLock.unlock() }; return stopFlag }

    /// Stop, keep what's back: after the file being written, nothing more is.
    func stop() { stopLock.lock(); stopFlag = true; stopLock.unlock() }

    private func finish(_ r: SessionsRestore.Receipt) {
        releaseWindow()
        guard let e = entry else { phase = .done; return }
        let arranges = r.sidebar != nil && e.claudeWindow
        if closedByUs || arranges, e.claudeWindow { Launcher.openClaude(Account(e)) }
        closedByUs = false
        guard arranges else { phase = .done; return }
        phase = .sidebar
        // a moment for the window to settle before the link reaches it
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.phase == .sidebar, self?.sidebarOpened == false { self?.arrangeSidebar() }
        }
    }

    // MARK: Cancel while the window closes

    func cancel() {
        timer?.invalidate()
        guard phase == .closing else { return }
        releaseWindow()
        closedByUs = false
        if undoing { undoing = false; phase = priorPhase } else {
            phase = receipt?.unfinished == true ? .stopped(receipt?.stopped ?? "Stopped.") : .ready
        }
        guard let e = entry, e.claudeWindow else { return }
        note = "Cancelled. The window was already asked to quit: if it closes, cl_audit opens it again."
        let since = Date()
        reopenTimer?.invalidate()
        reopenTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            let over: Bool = {
                guard let self, let e = self.entry, !self.isBusy else { return true }       // a new run (or undo) under way ends the watch
                if SwitchRunner.windowClosed(e) { Launcher.openClaude(Account(e)); return true }
                return Date().timeIntervalSince(since) > 60
            }()
            guard over else { return }
            t.invalidate()
            if self?.reopenTimer === t { self?.reopenTimer = nil }
            if self?.note?.hasPrefix("Cancelled. The window was already asked") == true { self?.note = nil }
        }
    }

    // MARK: Undo this restore

    /// Takes back exactly what the receipt says. The click is the consent: with window files among them the profile's window
    /// closes first (only that one, the same quit and the same Cancel as a restore's step 1), and the same rules as a
    /// restore apply (a switch that stopped half way, another switch or restore holding the window, the locks).
    func undo() {
        guard phase != .closing, phase != .writing, phase != .undoing, let r = receipt, r.undone == nil, let e = entry, let w = window else { return }
        note = nil
        if let why = SessionsRestore.blocker(profile: key.profile, except: r.id) { note = why.words; return }
        guard r.windowTouched else { runUndo(r.id); return }
        if let why = SessionsRestore.markerBlocker(profile: key.profile, dataDir: SessionsRestore.Target(e).dataDir, own: markName) { note = why; return }
        guard claimWindow(w) else { note = "Another switch or restore of this Claude window is under way."; return }
        let apps = SwitchRunner.windowApps(e)
        if apps.isEmpty { runUndo(r.id); return }
        priorPhase = returnPhase(phase); undoing = true
        closeWindow(apps, then: { [weak self] in self?.runUndo(r.id) }, giveUp: { [weak self] in
            guard let self else { return }
            self.undoing = false; self.phase = self.priorPhase
            self.note = "The window didn't close; it may be asking about work under way. Answer it, then try again. Nothing was taken back."
        })
    }

    private func runUndo(_ id: String) {
        guard let e = entry else { return }
        if !undoing { priorPhase = returnPhase(phase) }
        undoing = false
        phase = .undoing
        let mark = markName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SessionsRestore.undo(id, mark: mark, windowClosed: { SwitchRunner.windowClosed(e) }) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.releaseWindow()
                if self.closedByUs, let e = self.entry, e.claudeWindow { Launcher.openClaude(Account(e)) }
                self.closedByUs = false
                switch result {
                case .success(let u):
                    self.receipt = u
                    self.note = u.problems.isEmpty ? nil : u.problems.suffix(3).joined(separator: " ")
                    self.phase = .undone
                case .failure(let err):
                    self.phase = self.priorPhase
                    self.note = "Undo didn't finish: \(err). The receipt is in cl_audit's folder (restores/\(id)); Undo again to take back the rest."
                }
            }
        }
    }

    // MARK: Keep for 90 days

    /// Claude Code's own clean-up would delete restored transcripts older than its keep time again: one number in settings.json.
    func keepForDays(_ days: Int) {
        guard let e = entry else { return }
        let dir = e.configDir
        keepFailed = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try CodeCleanup.set(days, codeDir: dir) }
            DispatchQueue.main.async {
                if case .failure(let err) = result { self?.keepFailed = "\(err)" }
                self?.refresh()
            }
        }
    }

    // MARK: the sidebar (one Return in a helper session), as after a switch

    var sidebarPlan: SidebarPlan? { receipt?.sidebar.flatMap { $0.isEmpty ? nil : $0 } }

    func arrangeSidebar() {
        guard let plan = sidebarPlan, let e = entry, let url = plan.link(folder: SidebarPlan.helperFolder) else { return }
        sidebarOpened = true; sidebarMissed = false; sidebarLinkSent = false
        note = nil
        Launcher.openClaude(Account(e))
        let started = Date()
        tick(every: 1) { [weak self] in
            guard let self, let e = self.entry else { return true }
            guard let pid = SwitchRunner.windowApps(e).first?.processIdentifier else {
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
        let stillAlone: Bool = {
            guard alone, let e = entry, SwitchRunner.windowApps(e).contains(where: { $0.processIdentifier == pid }) else { return false }
            return NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
                .allSatisfy { $0.isTerminated || $0.processIdentifier == pid }
        }()
        switch outcome {
        case .sent:
            sidebarLinkSent = true
        case .notAllowed where stillAlone:
            NSWorkspace.shared.open(url)
            sidebarLinkSent = true
        case _ where entry.map({ SwitchRunner.windowApps($0).contains { $0.processIdentifier == pid } }) != true:
            sidebarOpened = false; sidebarMissed = true
            note = "\(name)'s window quit before the link reached it. Open the window, then Open the session."
        case .notAllowed:
            sidebarOpened = false; sidebarMissed = true
            note = "cl_audit may not send the link to \(name)'s window, and other Claude windows are open, so nothing opened. Allow cl_audit to control Claude (System Settings ▸ Privacy & Security ▸ Automation), or quit the other Claude windows, then Open the session."
        case .failed(let code):
            sidebarOpened = false; sidebarMissed = true
            note = "The link didn't reach \(name)'s window (\(code)). Open the session to try again."
        }
    }

    /// The restore is over for the page: the sidebar session (if any) was left to the operator.
    func finishPage() { timer?.invalidate(); releaseWindow(); phase = .done }

    /// Renders only: the page as it looks at a step.
    func preview(_ p: Phase, plan pl: SessionsRestore.Plan? = nil, receipt r: SessionsRestore.Receipt? = nil, progress pr: (Int, Int) = (0, 0),
                 notYet n: NotYet? = nil, note nt: String? = nil, sidebarOpened o: Bool = false, linkSent l: Bool = false) {
        frozen = true
        phase = p; plan = pl ?? plan; receipt = r; progress = pr; notYet = n; note = nt; sidebarOpened = o; sidebarLinkSent = l
        if manifest == nil { manifest = plan?.manifest }
    }

    private func tick(every s: TimeInterval, _ step: @escaping () -> Bool) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: s, repeats: true) { [weak self] t in
            if step() { t.invalidate(); if self?.timer === t { self?.timer = nil } }
        }
    }

    /// For each switch's backup, the account that switch went to: "ultra-2" (the receipt names it by id only).
    static func targetWord(_ m: SessionsBackup.Manifest?, for e: AccountEntry) -> String? {
        guard let m, case .beforeSwitch(let rid) = m.kind, let r = SwitchEngine.load(rid) else { return nil }
        let seats = [e.seat] + e.standby.map(\.seat)
        let emails = [e.seat?.email] + e.standby.map { $0.seat?.email ?? $0.email }
        guard let i = seats.firstIndex(where: { r.to.same($0) }), let email = emails[i] else { return nil }
        return AccountNames.short(email)
    }
}
