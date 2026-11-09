// DefaultProfileRunner: the steps of "Make the default profile the one Claude opens directly" (DefaultProfile.swift is
// the logic, DefaultProfilePage.swift the page). It orders the moves; the writing is the restore engine's, through a
// RestoreRunner (RestoreRunner.swift) for the profile, so closing the usual window, the receipt, Stop, Finish, the sidebar
// session and Undo are the Restore page's own.
//
//   windowOnly    close both windows → back up (the old window's data, the usual app's data) → the profile becomes the
//                 usual app's (desktop = .standard, saved) → restore the old window's backup into the usual app's data
//   otherFolder   Claude Code signs into ~/.claude (Terminal; the old profile's address filled in; waits for the account to
//                 show up) → the ~/.claude profile is made (or taken) and linked → the same four steps, plus the old
//                 profile's transcripts → the old profile stays as a standby account of it, or is removed (the page)
//
// Cancel works while waiting for the sign-in and while the windows close; a stopped restore keeps what is back (Finish or
// Undo on its page). Undo (the restore's) also puts the window kind back (SettingsModel.defaultMoveUndone).

import AppKit
import Combine

final class DefaultProfileRunner: ObservableObject {
    enum Phase: Equatable {
        case ready                      // the offer
        case signingIn                  // otherFolder: Claude Code's login in Terminal, waiting for the account
        case closing                    // both windows asked to quit
        case backingUp
        case moving                     // the restore runs (its page shows the details)
        case done
        case failed(String)
        case undone
    }

    let situation: DefaultProfile.Situation
    private weak var model: SettingsModel?
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var note: String?
    @Published private(set) var inner: RestoreRunner?
    @Published private(set) var record: DefaultProfile.Record?
    /// The profile that is (becomes) the default one: the old one itself, or the ~/.claude profile.
    @Published private(set) var targetID: String?
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var claimed: [String] = []
    private let markName = "default-" + UUID().uuidString.prefix(8).lowercased()
    private var seatAtAsk: Seat?
    private var signInStarted: Date?

    init(situation: DefaultProfile.Situation, model: SettingsModel) {
        self.situation = situation; self.model = model
        targetID = situation.kind == .windowOnly ? situation.old.id : situation.target?.id
    }

    /// Renders only: the page at a step.
    func preview(_ p: Phase, note n: String? = nil, inner i: RestoreRunner? = nil, record r: DefaultProfile.Record? = nil) {
        phase = p; note = n; inner = i; record = r
    }

    var isRunning: Bool {
        switch phase {
        case .signingIn, .closing, .backingUp, .moving: return true
        default: return false
        }
    }

    // MARK: the entries

    private var old: AccountEntry { model?.accounts.first { $0.id == situation.old.id } ?? situation.old }
    var target: AccountEntry? { targetID.flatMap { id in model?.accounts.first { $0.id == id } } }

    /// The old profile's window data folder as it is now (expanded), and the folder its Claude Code transcripts are in.
    private var oldDataDir: String { Account(old).claudeUserDataDir ?? "" }
    private var oldCodeDir: String { Account(old).configDir }

    // MARK: going

    func start() {
        var again = false
        if case .failed = phase { again = true }
        guard phase == .ready || again, let m = model else { return }
        note = nil
        // the profiles changed since the page opened (the offer no longer applies): nothing starts
        if DefaultProfile.situation(m.accounts) == nil {
            phase = .failed("The profiles changed; open the offer again."); return
        }
        if situation.kind == .windowOnly { closeWindows(); return }
        // otherFolder: ~/.claude must be signed in first (Claude Code's own login; nothing is moved or copied)
        if Account.signedInSeat(configDir: "~/.claude") != nil { prepareTarget(); return }
        guard let claude = m.requireClaude() else { phase = .failed(m.noClaudeWhy); return }
        let email = old.seat?.email ?? Account.expectedEmail(configDir: old.configDir)
        let probe = AccountEntry(id: "default", name: "default", label: "DEFAULT", configDir: "~/.claude")
        guard ClaudeCLI.openLogin(claude, account: Account(probe), email: email) else { phase = .failed("Terminal didn't open."); return }
        seatAtAsk = Account.signedInSeat(configDir: "~/.claude")
        signInStarted = Date()
        phase = .signingIn
        tick(every: 2) { [weak self] in
            guard let self else { return true }
            guard self.phase == .signingIn else { return true }
            if let started = self.signInStarted, Date().timeIntervalSince(started) > 3600 {
                self.phase = .ready; self.note = "The sign-in didn't finish in an hour; start again."; return true
            }
            guard Account.signedInSeat(configDir: "~/.claude") != nil else { return false }
            self.prepareTarget()
            return true
        }
    }

    /// Cancel while waiting for the sign-in or for the windows to close: nothing was written.
    func cancel() {
        timer?.invalidate(); timer = nil
        guard phase == .signingIn || phase == .closing else { return }
        releaseMarks()
        phase = .ready
        note = "Cancelled. Nothing was moved."
    }

    /// Step 1 done (or not needed): the ~/.claude profile is there, linked to the account ~/.claude is signed in to.
    private func prepareTarget() {
        guard let m = model, let seat = Account.signedInSeat(configDir: "~/.claude") else { return }
        var created = false, linked = false
        if let t = target {
            if t.seat == nil, let i = m.accounts.firstIndex(where: { $0.id == t.id }) { m.accounts[i] = DefaultProfile.moved(t, seat: seat); linked = true }
        } else {
            switch Self.makeDefaultProfile(from: old, among: m.accounts, seat: seat) {
            case .success(let e): m.accounts.append(e); targetID = e.id; created = true; linked = true
            case .failure(let err): phase = .failed("\(err)"); return
            }
        }
        pendingCreated = created; pendingLinked = linked
        closeWindows()
    }
    private var pendingCreated = false, pendingLinked = false

    /// The ~/.claude profile the offer makes when there is none: named after its account, looking like the old profile.
    static func makeDefaultProfile(from old: AccountEntry, among accounts: [AccountEntry], seat: Seat) -> Result<AccountEntry, Error> {
        var d = NewAccountDraft()
        var name = FirstRun.suggestedName(folder: "~/.claude")
        var n = 2
        while accounts.contains(where: { $0.name.lowercased() == name.lowercased() || $0.id == Store.newID(from: name, taken: []) }) { name = "\(FirstRun.suggestedName(folder: "~/.claude")) \(n)"; n += 1 }
        d.name = name; d.color = old.color; d.share = []; d.template = old
        d.source = .existing; d.existingDir = "~/.claude"
        d.standardTaken = FolderRules.windowOwner(.standard, FolderKey.standardDataDir, among: accounts) != nil
        do { try NewAccountSetup.createOrConnect(&d) } catch { return .failure(error) }
        var e = d.entry
        var s = seat; s.linkedAt = Date(); e.seat = s
        return .success(e)
    }

    // MARK: close both windows

    private func windowKeys() -> [(key: String, apps: () -> [NSRunningApplication], closed: () -> Bool)] {
        var usual = old
        usual.desktop = .standard; usual.desktopDataDir = ""
        var out = [(key: String, apps: () -> [NSRunningApplication], closed: () -> Bool)]()
        out.append((Launcher.dataDirKey(of: Account(usual)), { SwitchRunner.windowApps(usual) }, { SwitchRunner.windowClosed(usual) }))
        let o = old
        if !oldDataDir.isEmpty { out.append((Launcher.dataDirKey(of: Account(o)), { SwitchRunner.windowApps(o) }, { SwitchRunner.windowClosed(o) })) }
        return out
    }

    private func closeWindows() {
        guard let id = targetID else { return }
        let windows = windowKeys()
        // one at a time: a switch, restore or import of either window under way holds it
        for w in windows {
            guard SwitchMarker.claim(w.key, profile: id, standby: markName) else {
                releaseMarks(); phase = .failed("Another switch or restore of one of the Claude windows is under way. Wait for it, then try again."); return
            }
            claimed.append(w.key)
        }
        if let why = SessionsRestore.busy() { releaseMarks(); phase = .failed(why); return }
        let apps = windows.flatMap { $0.apps() }
        guard !apps.isEmpty else { backUp(); return }
        phase = .closing
        apps.forEach { $0.terminate() }
        let started = Date()
        tick(every: 0.5) { [weak self] in
            guard let self, self.phase == .closing else { return true }
            if windows.allSatisfy({ $0.closed() }) { self.backUp(); return true }
            if Date().timeIntervalSince(started) > 45 {
                self.releaseMarks(); self.phase = .ready
                self.note = "A window didn't close; it may be asking about work under way. Answer it, then try again. Nothing was written."
                return true
            }
            return false
        }
    }

    private func releaseMarks() {
        guard let id = targetID else { claimed = []; return }
        for k in claimed { SwitchMarker.release(k, profile: id, standby: markName) }
        claimed = []
    }

    // MARK: back up, then move

    private func backUp() {
        guard let id = targetID else { return }
        phase = .backingUp
        let place = BackupPrefs.placeURL
        let kind = situation.kind
        let oldDir = oldDataDir, oldCode = oldCodeDir
        let windows = windowKeys()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<(String, String), Error> = Result {
                let lock: SwitchEngine.Lock
                do { lock = try SwitchEngine.Lock.take() } catch { throw BackupError("\(error)") }
                defer { lock.release() }
                let now = Date()
                let oldID = SessionsBackup.newID(now)
                try SessionsBackup.make(SessionsBackup.Source(profile: id, dataDir: oldDir, codeDir: oldCode),
                                        id: oldID, kind: .manual, window: true, transcripts: kind == .otherFolder, place: place, now: now)
                let usualID = SessionsBackup.newID(now.addingTimeInterval(1))
                do {
                    try SessionsBackup.make(SessionsBackup.Source(profile: id, dataDir: FolderKey.standardDataDir, codeDir: "~/.claude"),
                                            id: usualID, kind: .manual, window: true, transcripts: false, place: place, now: now.addingTimeInterval(1))
                } catch { SessionsBackup.discard(profile: id, id: oldID, place: place); throw error }
                // still closed? a window that opened meanwhile may have changed what was copied: both are taken away
                guard windows.allSatisfy({ $0.closed() }) else {
                    SessionsBackup.discard(profile: id, id: oldID, place: place); SessionsBackup.discard(profile: id, id: usualID, place: place)
                    throw BackupError("A Claude window opened during the backup; nothing was moved. Close it and try again.")
                }
                return (oldID, usualID)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let (oldID, usualID)): self.move(backup: oldID, usualBackup: usualID, place: place)
                case .failure(let err):
                    self.releaseMarks()
                    self.phase = .failed("The backup couldn't be made (\(err)). Nothing moved. Backups go to \(tilde(place.path)); General ▸ Backups changes that.")
                }
            }
        }
    }

    private func move(backup: String, usualBackup: String, place: URL) {
        guard let m = model, let id = targetID, let i = m.accounts.firstIndex(where: { $0.id == id }) else { return }
        let seat = Account.signedInSeat(configDir: "~/.claude")
        var r = DefaultProfile.Record(id: UUID().uuidString.lowercased(), kind: situation.kind, profile: id,
                                      oldProfile: situation.kind == .otherFolder ? situation.old.id : nil,
                                      backup: backup, backupPlace: place.path, defaultBackup: usualBackup, started: Date())
        r.oldDataDir = oldDataDir
        r.created = pendingCreated
        r.linkedSeat = pendingLinked || (situation.kind == .windowOnly && m.accounts[i].seat == nil)
        if situation.kind == .windowOnly {
            // the profile becomes the usual app's window: saved before the restore, so its entries land in the usual app's data
            r.flipped = true; r.oldDesktop = m.accounts[i].desktop; r.oldDesktopDataDir = m.accounts[i].desktopDataDir
            m.accounts[i] = DefaultProfile.moved(m.accounts[i], seat: seat)
        }
        DefaultProfile.save(r)
        record = r
        m.apply()
        releaseMarks()                      // the restore claims the usual window itself
        // a Mac whose usual app never ran has no data folder yet: an empty one, so the entries have somewhere to go
        try? FileManager.default.createDirectory(atPath: expand(FolderKey.standardDataDir), withIntermediateDirectories: true)
        let key = RestoreKey(profile: id, backup: backup, place: place.path)
        let runner = m.restoreRunner(key)
        inner = runner
        phase = .moving
        runner.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.innerChanged() } }.store(in: &cancellables)
        runner.refresh()
        // the preview is counted off the main thread: start once it is there
        tick(every: 0.3) { [weak self] in
            guard let self, self.phase == .moving else { return true }
            guard let p = runner.plan else { return false }
            if let why = p.refusal ?? runner.notYet?.words { self.fail(why); return true }
            if p.count == 0 { self.finishWithoutRestore(); return true }
            runner.start()
            return true
        }
    }

    /// The restore's own page shows each step; this follows it to its end.
    private func innerChanged() {
        guard let runner = inner, var r = record else { return }
        if let rc = runner.receipt, r.receipt != rc.id { r.receipt = rc.id; record = r; DefaultProfile.save(r) }
        switch runner.phase {
        case .done, .sidebar:
            if phase == .moving, runner.receipt != nil {
                r.finished = Date(); record = r; DefaultProfile.save(r)
        // the receipt's id goes into the record the moment the engine writes it: a quit part way still finds the restore
        runner.onReceipt = { [rid = r.id] receipt in DefaultProfile.attachReceipt(record: rid, receipt: receipt) }
                phase = .done
                model?.forgetRestore()
            }
        case .failed(let why):
            if phase == .moving { fail(why) }
        case .undone:
            if phase != .undone { phase = .undone; model?.defaultMoveUndone(r.id) }
        default: break
        }
        objectWillChange.send()
    }

    /// Nothing in the old window to move (no entries, no transcripts): only the window kind changes, and it is done.
    private func finishWithoutRestore() {
        guard var r = record else { return }
        r.finished = Date(); record = r; DefaultProfile.save(r)
        phase = .done
    }

    /// The restore refused or couldn't start before writing anything: the window kind goes back, as it was.
    private func fail(_ why: String) {
        if let m = model, let r = record, DefaultProfile.restoreFor(r) == nil { m.defaultMoveUndone(r.id, quiet: true) }
        phase = .failed(why)
    }

    /// "Undo this move": the restore's Undo; its end puts the window kind back. Not once the old profile was kept as a
    /// standby account or removed.
    func undo() {
        if let r = record, let why = DefaultProfile.undoRefusal(r) { note = why; return }
        inner?.undo()
    }

    /// The move can't be undone any more (the old profile was kept as a standby account or removed).
    var undoRefused: String? { record.flatMap { DefaultProfile.undoRefusal($0) } ?? (oldRemoved ? DefaultProfile.undoRefusalWords(removed: true) : nil) }

    /// The old profile is gone from the list (removed from the remove flow).
    private var oldRemoved: Bool {
        situation.kind == .otherFolder && phase == .done && model?.accounts.contains { $0.id == situation.old.id } == false
    }

    /// The old profile has been dealt with (kept as a standby account, or removed): the page's last step is done.
    var oldDone: Bool { oldHandled || oldRemoved }

    // MARK: what the old profile becomes (otherFolder)

    /// The old profile may stay as a standby account of the default profile: another account than the default's.
    var canKeepOldAsStandby: Bool {
        guard situation.kind == .otherFolder, let t = target, let s = old.seat, s.email != nil else { return false }
        return !s.same(t.seat) && !t.has(s)
    }

    /// Keep it: the default profile gets the old one's account as a standby account (its folder and sign-in stay exactly
    /// as they are, nothing is moved or copied), and the old profile leaves the list. Its own standby accounts go along.
    func keepOldAsStandby() {
        guard canKeepOldAsStandby, let m = model, let t = target, let ti = m.accounts.firstIndex(where: { $0.id == t.id }),
              let s = old.seat else { return }
        var seat = s; seat.linkedAt = Date()
        var e = m.accounts[ti]
        e.standby.append(StandbyAccount(email: s.email ?? "", seat: seat, configDir: old.configDir))
        e.standby += old.standby
        m.accounts[ti] = e
        m.remove(old.id)
        m.apply()
        oldHandled = true
        note = "\(old.name) now stands by on \(e.name). Its folder and sign-in are as they were."
        objectWillChange.send()
    }

    /// Remove it: the existing remove flow (it signs its own folder out with `claude auth logout`, and asks about deleting it).
    func removeOld() {
        guard let m = model else { return }
        m.askRemove(old.id)         // the sheet asks; once it is removed (SettingsModel.removeAccount) the move can't be undone
    }
    @Published private(set) var oldHandled = false

    // MARK: timer

    private func tick(every s: TimeInterval, _ step: @escaping () -> Bool) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: s, repeats: true) { [weak self] t in
            if step() { t.invalidate(); if self?.timer === t { self?.timer = nil } }
        }
    }
        if var r = record { r.oldHandled = "standby"; record = r; DefaultProfile.save(r) }

    deinit { timer?.invalidate() }
}

extension SettingsModel {
    /// The restore of a default-profile move was undone (or never started): the window kind and link go back, the profile the
    /// move made goes. Everything else about the profile is as it is.
    func defaultMoveUndone(_ recordID: String, quiet: Bool = false) {
        guard var r = DefaultProfile.all().first(where: { $0.id == recordID }), r.undone == nil else { return }
        if let i = accounts.firstIndex(where: { $0.id == r.profile }) {
            if r.created { accounts.remove(at: i); refreshFirstRun(); if selection == r.profile { selection = accounts.first?.id } }
            else { accounts[i] = DefaultProfile.reverted(accounts[i], r) }
        }
        r.undone = Date()
        DefaultProfile.save(r)
        apply()
        if !quiet { message = "Undid the move to the default profile" }
    }
}
        if DefaultProfile.undoRefusal(r) != nil { return }
        // files were written and the restore wasn't undone: the window kind stays with them (Finish or Undo on the restore's page)
        if let rc = DefaultProfile.restoreFor(r), rc.undone == nil { return }
