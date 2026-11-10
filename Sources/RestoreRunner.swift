// RestoreRunner: one restore of a backup, step by step, for the Restore page (RestorePage.swift), with SessionsRestore
// doing the writing.
//
//   preview   counted from the backup against what is there now; nothing is written, and the page says why a restore
//             may not start yet (a restore that stopped half way, another restore/import/move, claude-transplant)
//   1. the profile's Claude window closes (only if something in the window comes back; gracefully, only that window)
//   2. what's listed comes back, merged and never overwriting (SessionsRestore.run), with a receipt as it goes
//   3. the window opens again (if it was closed for this); the sidebar's groups and pins are arranged by one Return in a
//      helper session (SwitchSidebar.swift)
//
// Stop keeps what is back; Finish picks up from the same receipt (also after cl_audit stopped: the tile of the profile
// shows "Restore stopped" and the page opens on it); Undo takes back exactly what the receipt says it put back.

import AppKit

/// Which backup a Restore page is about: the profile, the backup and where it is (General ▸ Backups, or the place a
/// receipt recorded), or a stopped restore to finish.
struct RestoreKey: Equatable {
    var profile: String
    var backup: String
    var place: String
    var resume: String? = nil               // a stopped restore's receipt
    var addMemory = false                   // an import: add the memory files of a file from another Mac or profile (left out otherwise)
    var addSetup = false                    // add Claude Code's setup (CLAUDE.md, skills, agents …) that is missing here (left out otherwise)
    var addConfig = false                   // add the window's MCP settings (claude_desktop_config.json) where there is none (left out otherwise)
    var addTasks = false                    // an import: add the file's scheduled tasks, paused (left out otherwise)
    /// An import: the folders picked on this Mac for sessions whose folder isn't here (session id → folder); each is re-pointed there
    /// right after the import, while the window is still closed (SessionsRepoint.swift).
    var repoint: [String: String] = [:]
    /// A move's side files kept with the backup (SessionsSide.swift): which kinds are written. nil: every kind the backup keeps, the
    /// project MCP servers left out (an import of a move starts so, like its memory).
    var side: SideFiles.Kinds? = nil
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
    }

    let key: RestoreKey
    /// Told (from the restore's thread) the receipt's id as soon as the engine has written it: the default-profile move keeps
    /// it in its record, so a quit part way still finds this restore to Finish or Undo.
    var onReceipt: ((String) -> Void)?
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
    /// An import: how many of the transcripts to add belong to a folder that isn't on this Mac.
    @Published private(set) var foldersMissing = 0
    /// An import: the sessions it adds whose folder isn't on this Mac (each can be given a folder: Pick its folder on this Mac…).
    @Published private(set) var folderSessions: [SessionsRepoint.Session] = []
    /// The folders picked for them (session id → folder), re-pointed right after the import.
    @Published private(set) var picks: [String: String] = [:]
    /// What the re-point after the import did (its receipt), and why it couldn't when it couldn't.
    @Published private(set) var repointed: SessionsRepoint.Receipt?
    @Published private(set) var repointNote: String?
    /// The Import page keeps its own picks (its preview runner is made again on each choice): told of each pick.
    var onPick: ((String, String?) -> Void)?
    /// A move's side files the backup keeps (SessionsSide.swift), counted; nil: none.
    @Published private(set) var sidePlan: SideFiles.Plan?
    /// The kinds written (the Import page's rows).
    @Published private(set) var sideKinds = SideFiles.Kinds.nothing
    /// What writing them did (its receipt), and why when it couldn't.
    @Published private(set) var sided: SideFiles.Receipt?
    @Published private(set) var sideNote: String?
    /// History lines or trust will be written: they are shared files, written only while the window is closed.
    var sideNeedsWindow: Bool {
        guard let p = sidePlan else { return false }
        return (sideKinds.history && p.historyLines > 0) || (sideKinds.trust && p.trust > 0)
    }

    /// Pick its folder on this Mac…: an Open panel for a folder; the pick is kept for the import (nothing is written now).
    func pickFolder(_ session: String) {
        guard phase == .ready else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false; p.canCreateDirectories = false
        p.title = "Pick the session's folder on this Mac"; p.prompt = "Pick"
        if let s = folderSessions.first(where: { $0.id == session }) {
            p.message = "Where is \(tilde(s.folder)) on this Mac? The session is pointed at the folder you pick when it is imported."
        }
        guard p.runModal() == .OK, let url = p.url else { return }
        setPick(session, url.path)
    }

    /// A picked session has a Code-tab entry, which its re-point rewrites: the window closes for it (also when nothing else in the window
    /// comes in). A pick for a session the list doesn't know counts as having one.
    var windowForPicks: Bool {
        picks.keys.contains { id in folderSessions.first { $0.id == id }.map { !$0.entries.isEmpty } ?? true }
    }
    /// The window closes for this restore: something in it comes in, or a picked session's entry changes.
    var closesWindow: Bool { (plan?.windowNeeded ?? false) || windowForPicks || sideNeedsWindow }

    func setPick(_ session: String, _ folder: String?) {
        guard phase == .ready else { return }
        if let folder { picks[session] = folder } else { picks.removeValue(forKey: session) }
        onPick?(session, folder)
    }
    /// Close and import: the preview is counted again (the backup was just moved into place) and the restore starts at once.
    private var autoStart = false
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
    /// Claude Code's setup that is missing here: added or left out (the preview's choice; left out unless asked).
    @Published private(set) var addSetup = false

    /// "Add them" / "Leave them out" for the setup row: the preview is counted again.
    func setSetup(_ on: Bool) {
        guard on != addSetup, phase == .ready else { return }
        addSetup = on
        refresh()
    }
    /// The window's MCP settings, and (an import) its scheduled tasks: added or left out (left out unless asked).
    @Published private(set) var addConfig = false
    @Published private(set) var addTasks = false
    func setConfig(_ on: Bool) {
        guard on != addConfig, phase == .ready else { return }
        addConfig = on
        refresh()
    }
    func setTasks(_ on: Bool) {
        guard on != addTasks, phase == .ready else { return }
        addTasks = on
        refresh()
    }
    private var priorPhase: Phase = .ready

    init(key: RestoreKey, model: SettingsModel) {
        self.key = key; self.model = model
        addSetup = key.addSetup
        addConfig = key.addConfig; addTasks = key.addTasks
        picks = key.repoint
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
    var needsWindow: Bool { closesWindow }

    // MARK: the preview (read-only), off the main thread

    func refresh() {
        guard !frozen else { return }
        switch phase {
        case .ready, .stopped: break
        default: return
        }
        guard let e = entry else { return }
        let target = SessionsRestore.Target(e), b = backup, resume = resumeID, profile = key.profile, memory = key.addMemory, setup = addSetup
        let config = addConfig, tasks = addTasks
        let w = window
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = SessionsRestore.plan(target, b, addMemory: memory, addSetup: setup, addConfig: config, addTasks: tasks)
            var not: NotYet?
            if let why = SessionsRestore.blocker(profile: profile, except: resume) {
                not = NotYet(title: "A restore of \(e.name) is unfinished", words: why)
            } else if p.windowNeeded, let m = w.flatMap({ SwitchMarker.current($0) }) {       // only a restore that writes in the window waits for it
                if m.standby.hasPrefix("restore-") {
                    not = NotYet(title: "A restore of \(e.name) is under way", words: "Its window stays closed until that restore ends (or its Undo does). Wait for it, or open it.")
                } else {
                    not = NotYet(title: "\(e.name)'s window is held closed", words: "An import's folder pick or the default-profile move is writing its files. Wait for it to end.")
                }
            } else if let why = SessionsRestore.busy() {
                not = NotYet(title: why.contains("claude-transplant") ? "claude-transplant is moving sessions" : "Another restore, import or move is under way",
                             words: why)
            }
            let folders = p.isImport && p.refusal == nil ? SessionsImport.foldersMissing(p, backup: b) : 0
            let away = p.isImport && p.refusal == nil ? SessionsRepoint.staged(p, backup: b).filter { !$0.here } : []
            let side = p.refusal == nil ? SideFiles.stashed(b).map(SideFiles.plan) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.plan = p; self.notYet = not; self.foldersMissing = folders; self.folderSessions = away
                self.sidePlan = side.flatMap { $0.isEmpty ? nil : $0 }
                self.sideKinds = self.sidePlan.map { self.key.side ?? SideFiles.importKinds($0) } ?? .nothing
                // a pick for a session that no longer comes in is let go
                self.picks = self.picks.filter { k, _ in away.contains { $0.id == k } }
                if self.manifest == nil { self.manifest = p.manifest }
                if self.autoStart {
                    self.autoStart = false
                    if p.refusal == nil, not == nil, p.count > 0 { self.start() }
                    else if self.phase == .ready {
                        self.note = p.refusal ?? not?.words ?? "Nothing to import: everything in the file is here already."
                    }
                }
            }
        }
    }

    /// Close and import: counts once more against what is there now, then starts (the page shows why when it can't).
    func importNow() { autoStart = true; refresh() }

    /// The backup is an export's, unpacked (SessionsImport.swift): the page and the words say import.
    var isImport: Bool { manifest?.kind.isImport ?? (receipt?.importedFrom != nil) }
    /// "cl_audit Work 2026-10-30.zip"
    var importFile: String? {
        if case .imported(let f)? = manifest?.kind { return f }
        return receipt?.importedFrom
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
        // (a picked folder rewrites the session's Code-tab entry, and a move's history and trust are shared files: the window closes for
        // those too, when it has one)
        guard closesWindow else { write(); return }
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
        let target = SessionsRestore.Target(e), b = backup, resume = resumeID, mark = markName, memory = key.addMemory, setup = addSetup, config = addConfig, tasks = addTasks
        let picked = picks.sorted { $0.key < $1.key }.map { SessionsRepoint.Pick(session: $0.key, folder: $0.value) }
        let sideKinds = sidePlan == nil ? SideFiles.Kinds.nothing : self.sideKinds
        phase = .writing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try SessionsRestore.run(target, b, continuing: resume, addMemory: memory, addSetup: setup, addConfig: config, addTasks: tasks, mark: mark, windowClosed: { SwitchRunner.windowClosed(e) },
                                        stop: { self?.stopRequested ?? true },
                                        progress: { d, t in DispatchQueue.main.async { self?.progress = (d, t) } },
                                        receiptWritten: { id in self?.onReceipt?(id) })
            }
            // the picked folders, right after the import, while the window is still closed (its own receipt, linked to the import's:
            // Undo this import takes it back first)
            var moved: Result<SessionsRepoint.Receipt, Error>?
            if case .success(let r) = result, r.finished != nil, !picked.isEmpty {
                moved = Result { try SessionsRepoint.apply(target, picks: picked, restore: r.id, mark: mark, windowClosed: { SwitchRunner.windowClosed(e) }) }
            }
            // a move's side files, last: by the folder each session resolves to here (the one just picked, or its own when it is here)
            var sided: Result<SideFiles.Receipt?, Error>?
            if case .success(let r) = result, r.finished != nil, sideKinds != .nothing {
                var folders: [String: SideFiles.Folder] = [:]
                if case .success(let m)? = moved { for d in m.sessions where !d.undone { folders[d.session] = (d.from, d.to) } }
                sided = Result { try SideFiles.apply(target, b, kinds: sideKinds, restore: r.id, folders: folders, windowClosed: { SwitchRunner.windowClosed(e) }) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch sided {
                case .success(let s)?: self.sided = s; self.sideNote = s.flatMap { $0.problems.isEmpty ? nil : $0.problems.prefix(3).joined(separator: " ") }
                case .failure(let err)?: self.sideNote = "The side files weren't written: \(err)."
                case nil: break
                }
                switch moved {
                case .success(let m)?: self.repointed = m; self.repointNote = m.problems.isEmpty ? nil : m.problems.prefix(3).joined(separator: " ")
                case .failure(let err)?: self.repointNote = "The picked folders weren't applied: \(err). Pick them again under \(e.name)'s Sessions."
                case nil: break
                }
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
        if let why = DefaultProfile.undoRefusal(receipt: r.id) { note = why; return }
        if let why = SessionsRestore.blocker(profile: key.profile, except: r.id) { note = why; return }
        // (a re-point after the import changed Code-tab entries: its Undo, which runs first, needs the window closed too)
        // (and a move's history and trust, shared files, are taken back only while it is closed)
        guard r.windowTouched || SessionsRepoint.touchesWindow(restore: r.id) || SideFiles.touchesShared(restore: r.id) else { runUndo(r.id); return }
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
                    if let rp = self.repointed { self.repointed = SessionsRepoint.load(rp.id) ?? rp }
                    if let sd = self.sided { self.sided = SideFiles.load(sd.id) ?? sd }
                    if u.undone == nil {
                        // some restored transcripts are held by a running session: left in place, the receipt stays open
                        self.note = "\(u.undoLeft) restored \(u.undoLeft == 1 ? "transcript is" : "transcripts are") held by a running Claude Code session, so \(u.undoLeft == 1 ? "it was" : "they were") left in place and this restore stays open. Undo again once the session has ended takes the rest."
                        self.phase = self.priorPhase
                    } else {
                        self.note = u.problems.isEmpty ? nil : u.problems.suffix(3).joined(separator: " ")
                        self.phase = .undone
                        // an undo of the default-profile move's restore also puts the window kind back (DefaultProfileRunner.swift)
                        if let rec = DefaultProfile.record(forReceipt: u.id) { self.model?.defaultMoveUndone(rec.id) }
                    }
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
                 notYet n: NotYet? = nil, note nt: String? = nil, sidebarOpened o: Bool = false, linkSent l: Bool = false,
                 folders f: [SessionsRepoint.Session]? = nil, picks pk: [String: String]? = nil, repointed rp: SessionsRepoint.Receipt? = nil,
                 side sp: SideFiles.Plan? = nil, sideKinds sk: SideFiles.Kinds? = nil, sided sd: SideFiles.Receipt? = nil) {
        frozen = true
        if let sp { sidePlan = sp; sideKinds = sk ?? SideFiles.importKinds(sp) }
        if let sd { sided = sd }
        if let f { folderSessions = f; foldersMissing = f.count }
        if let pk { picks = pk }
        if let rp { repointed = rp }
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
