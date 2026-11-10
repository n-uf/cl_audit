// SwitchRunner: one profile's switch to another of its accounts (cl_quick's AccountSwitcher), for the Switch page
// (SwitchPage.swift). A profile is one Claude Code folder, and the folder holds one signed-in account at a time, so a
// switch is signing in again on the same folder, as the other account: Claude Code's own `claude auth login`, in
// Terminal with the address filled in, finished in the browser. The browser's claude.ai session decides which account
// signs in, so the result is checked: the folder's .claude.json is looked at every 2 s, for at most 10 minutes, until its
// account changes. Then:
//
//   reached     the folder is on the account wanted: the profile works on it, the one before stands by
//   other       the folder is on another account (the browser was signed in as someone else): the profile follows it
//               all the same (FolderRules.noteAccounts), and the page offers to sign in again as the one wanted
//   timed out   nothing signed in for 10 minutes: nothing changed
//
// Before the sign-in, a switch to a standby account moves the profile's Claude window sessions and scheduled tasks to
// that account, inside the profile's folder, the way claude-transplant does (SwitchEngine.swift): the window closes (its
// own quit, only that window) and stays closed until the sign-in ends; a backup is made first; the receipt keeps Undo
// possible until Claude Code is on the new account (reached: the receipt is linked). Sessions a running Claude Code owns
// are held where they are. With nothing to move (or a standby account whose ids aren't known yet), only the sign-in runs.
// Claude Code's transcripts stay in the folder; the Claude window's own sign-in is the person's to change: cl_audit never
// signs anything in or out, never sees a password or a token and never touches the Keychain. "Sign in again" on the
// account in use is the same watch with no move: the folder's account doesn't change then, so only Claude Code's login
// ending well (the script leaves a marker, ClaudeCLI.openLogin) says it's done.

import AppKit

final class SwitchRunner: ObservableObject {
    enum Phase: Equatable {
        case ready
        case closing                    // the profile's Claude window was asked to quit; waiting for it (at most 45 s)
        case moving                     // the backup, then the window's sessions and tasks move to the account wanted
        case waiting                    // Terminal shows Claude Code's sign-in; the folder is looked at every 2 s
        case reached                    // the folder is on the account wanted
        case other(String)              // the folder is on another account: its address
        case timedOut                   // no sign-in came in 10 minutes
        case failed(String)             // it couldn't start or the move stopped: why
        case undone                     // Undo put the moved sessions back
    }

    /// A switch under way: the account wanted, and the account the folder was on when it began.
    struct Goal: Equatable {
        var standby: String?            // the standby account's id; nil: signing in again on the account in use
        var wantedSeat: Seat?           // nil for an address remembered without a sign-in yet
        var wantedEmail: String
        var from: Seat?
        var started: Date
        /// Signing in again on the account already in use: the folder's account is the same before and after.
        var again: Bool { standby == nil && from != nil }
    }

    enum Outcome: Equatable { case reached, other(Seat), timedOut }

    /// How long a sign-in is waited for, and how often the folder is looked at.
    static let giveUp: TimeInterval = 10 * 60
    static let every: TimeInterval = 2

    let profile: String
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var goal: Goal?
    /// The account the switch went for, as it was on standby: once reached it isn't on standby any more, and the page keeps
    /// showing it from this copy.
    private(set) var targetSnapshot: StandbyAccount?
    /// The move's receipt (SwitchEngine): what moved, for Undo until Claude Code is on the new account.
    @Published private(set) var receipt: SwitchReceipt?
    /// What the move said: sessions held (a running Claude Code owns them), entries that didn't move, why tasks stayed.
    @Published private(set) var moveNote: String?
    /// The plan before it ran: how many sessions and tasks move (the page's steps say it).
    @Published private(set) var planned: SwitchPlan?
    private weak var model: SettingsModel?
    private var timer: Timer?
    private var closeStarted = Date()
    private let reads = DispatchQueue(label: "cl_audit.switch-reads", qos: .utility)

    init(profile: String, model: SettingsModel) {
        self.profile = profile; self.model = model
    }

    var isRunning: Bool { phase == .closing || phase == .moving || phase == .waiting }

    /// The window mark's name for this switch (SwitchMarker): the window stays closed from the move until the sign-in ends.
    private var markName: String { "switch-" + (goal?.standby ?? "again") }
    private func windowKey(_ e: AccountEntry) -> String { Launcher.dataDirKey(of: Account(e)) }

    /// The Switch page's key for the account it went for ("<profile>~<standby id>").
    var key: String { AccountEntry.switchKey(profile, goal?.standby ?? targetSnapshot?.id ?? "") }

    /// The account it went for, short ("ultra-2").
    var targetShort: String? { (goal?.wantedEmail ?? targetSnapshot?.email).map(AccountNames.short) }

    private var entry: AccountEntry? { model?.accounts.first { $0.id == profile } }

    /// The marker a sign-in again leaves when Claude Code's login ended well.
    /// Named after the profile id's hash, so a hand-edited id ("../x") never names a file outside cl_audit's folder. A
    /// Terminal sign-in that ends after a newer one began can leave its marker late; the newer run cleared the old one when
    /// it began and judges the folder's account first, so a late marker only ends a sign-in again whose account is
    /// already the one in use (cl_quick's SignIn works the same way).
    static func marker(for profile: String) -> URL { Store.folder.appendingPathComponent("signed-in-\(Account.sha8(profile)).done") }
    private func clearMarker() { try? FileManager.default.removeItem(at: Self.marker(for: profile)) }

    // MARK: the profile's Claude window (shared with Restore, Export and the default-profile move)

    /// The profile's own Claude window (by its data folder), if it runs.
    static func windowApps(_ e: AccountEntry) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
            .filter { !$0.isTerminated && Launcher.isWindow(of: Account(e), $0) }
    }

    static func windowClosed(_ e: AccountEntry) -> Bool { windowApps(e).isEmpty }

    // MARK: going

    /// Switch to a standby account: the profile's Claude window closes, its sessions and scheduled tasks move to that
    /// account (SwitchEngine, with a backup first), then Claude Code's sign-in on the profile's folder with its address
    /// filled in, and the folder is watched. Nothing to move (or the account's ids aren't known yet: an address remembered
    /// without a sign-in): only the sign-in.
    func start(_ s: StandbyAccount) {
        guard !isRunning, let e = entry else { return }
        targetSnapshot = s; receipt = nil; moveNote = nil; planned = nil
        let g = Goal(standby: s.id, wantedSeat: s.seat, wantedEmail: s.email,
                     from: Account.signedInSeat(configDir: e.configDir) ?? e.seat, started: Date())
        // a switch that stopped half way is put back first: never a second move on top of it
        if let u = SwitchEngine.unfinished(profile: profile).first {
            goal = g; receipt = u
            phase = .failed("An earlier switch of \(e.name) stopped half way: Undo it first.")
            return
        }
        guard e.seat != nil, s.seat != nil else { begin(e, g); return }
        switch SwitchEngine.plan(e, standby: s) {
        case .failure(let why): goal = g; phase = .failed(why.description)
        case .success(let p):
            planned = p
            if !p.held.isEmpty { moveNote = Self.heldWords(p.held.count) }
            if p.moves { closeAndMove(e, g) } else { begin(e, g) }
        }
    }

    static func heldWords(_ n: Int) -> String {
        "\(n) \(n == 1 ? "session stays" : "sessions stay") with the account in use: Claude Code is running \(n == 1 ? "it" : "them") now. A later switch moves \(n == 1 ? "it" : "them") once \(n == 1 ? "it's" : "they're") closed."
    }

    /// The window closes (its own quit, which may ask about work under way; only this profile's window, by its data
    /// folder), and stays closed until the sign-in ends: no window opener starts it meanwhile (SwitchMarker).
    private func closeAndMove(_ e: AccountEntry, _ g: Goal) {
        goal = g
        guard SwitchMarker.claim(windowKey(e), profile: profile, standby: markName) else {
            phase = .failed("Another run on \(e.name)'s Claude window is under way (a restore, an import or a switch)."); return
        }
        let apps = Self.windowApps(e)
        if apps.isEmpty { move(e, g); return }
        phase = .closing
        apps.forEach { $0.terminate() }
        closeStarted = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self, self.phase == .closing, let e = self.entry else { t.invalidate(); return }
            if Self.windowClosed(e) { t.invalidate(); self.move(e, g); return }
            if Date().timeIntervalSince(self.closeStarted) > 45 {
                t.invalidate(); self.releaseWindow()
                self.phase = .failed("\(e.name)'s Claude window didn't close; it may be asking about work under way. Answer it, then try again. Nothing moved.")
            }
        }
    }

    /// The backup and the move, off the main thread (planned again now that the window is closed), then the sign-in.
    private func move(_ e: AccountEntry, _ g: Goal) {
        guard let s = targetSnapshot, case .success(let p) = SwitchEngine.plan(e, standby: s) else {
            releaseWindow(); phase = .failed("The switch couldn't be planned again. Nothing moved."); return
        }
        planned = p
        phase = .moving
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SwitchEngine.run(p, windowClosed: { Self.windowClosed(e) }) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let r):
                    self.receipt = r
                    let notes = (r.held?.isEmpty == false ? [Self.heldWords(r.held!.count)] : []) + r.problems
                    self.moveNote = notes.isEmpty ? nil : notes.joined(separator: " ")
                    self.begin(e, g)
                case .failure(let err):
                    // stopped half way: its receipt, for Undo; nothing moved: nothing to put back
                    self.receipt = SwitchEngine.unfinished(profile: self.profile).first
                    self.releaseWindow()
                    self.phase = .failed("\(err)")
                }
            }
        }
    }

    private func releaseWindow() {
        guard let e = entry else { return }
        SwitchMarker.release(windowKey(e), profile: profile, standby: markName)
    }

    /// Undo: the move put back from its receipt (the window must be closed), before Claude Code is on the new account.
    func undo() {
        guard !isRunning, let r = receipt, r.linked == nil, r.undone == nil, let e = entry else { return }
        phase = .moving
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SwitchEngine.undo(r.id, windowClosed: { Self.windowClosed(e) }) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let back):
                    self.receipt = back
                    self.moveNote = back.problems.isEmpty ? nil : back.problems.joined(separator: " ")
                    self.phase = .undone
                case .failure(let err): self.phase = .failed("\(err)")
                }
            }
        }
    }

    /// Undo applies: a move that is neither linked nor undone.
    var canUndo: Bool { receipt.map { $0.unfinished } ?? false }

    /// Sign in again on the account in use (its sign-in stopped working, or the folder is signed out): the same watch.
    func signInAgain() {
        guard !isRunning, let e = entry, let email = e.seat?.email ?? Account.expectedEmail(configDir: e.configDir) else { return }
        targetSnapshot = nil; receipt = nil; moveNote = nil; planned = nil
        begin(e, Goal(standby: nil, wantedSeat: e.seat, wantedEmail: email,
                      from: Account.signedInSeat(configDir: e.configDir), started: Date()))
    }

    /// The same account again (after another account signed in, or nothing did in time).
    func retry() {
        guard let g = goal, !isRunning else { return }
        if g.standby == nil { signInAgain(); return }
        // the sessions moved already (Undo not used): only the sign-in again, the window kept closed meanwhile
        if canUndo, let e = entry {
            guard SwitchMarker.claim(windowKey(e), profile: profile, standby: markName) else {
                phase = .failed("Another run on \(e.name)'s Claude window is under way."); return
            }
            begin(e, Goal(standby: g.standby, wantedSeat: g.wantedSeat, wantedEmail: g.wantedEmail, from: g.from, started: Date()))
            return
        }
        if let s = entry?.standby.first(where: { $0.id == g.standby }) ?? targetSnapshot { start(s) }
    }

    private func begin(_ e: AccountEntry, _ g: Goal) {
        clearMarker()
        guard let claude = model?.requireClaude() else { goal = g; releaseWindow(); phase = .failed(model?.noClaudeWhy ?? ClaudeInstall.missing + "."); return }
        guard ClaudeCLI.openLogin(claude, account: Account(e), email: g.wantedEmail.isEmpty ? nil : g.wantedEmail, marker: g.again ? Self.marker(for: profile) : nil) else {
            goal = g; releaseWindow(); phase = .failed("Terminal didn't open."); return
        }
        goal = g
        phase = .waiting
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in self?.look() }
    }

    /// Stops waiting: nothing changed, so there is nothing to put back.
    /// While the window closes: it stays open (asked to quit already, it may still close by its own answer later).
    /// While the sign-in is waited for after a move: the moved sessions stay where they went, and Undo puts them back.
    func cancel() {
        guard phase != .moving else { return }               // the move finishes or stops by itself
        timer?.invalidate(); timer = nil
        clearMarker()
        releaseWindow()
        if phase == .waiting || phase == .closing { phase = .ready }
    }

    /// Back to the start, for another switch from the page.
    func reset() { cancel(); guard phase != .moving else { return }; phase = .ready; goal = nil; moveNote = nil; planned = nil
        if !canUndo { receipt = nil } }

    /// One look at the folder: its file is read off the main thread, and what it said is judged here, on the main thread.
    func look() {
        guard phase == .waiting, let g = goal else { return }
        // the profile was removed while its sign-in was waited for: stop looking (nothing to note it on)
        guard let e = entry else { cancel(); return }
        let dir = e.configDir, marker = Self.marker(for: profile)
        reads.async { [weak self] in
            let now = Account.signedInSeat(configDir: dir)
            let done = FileManager.default.fileExists(atPath: marker.path)
            DispatchQueue.main.async {
                guard let self, self.phase == .waiting, self.goal == g else { return }
                if let o = Self.judge(g, now: now, markerDone: done) { self.end(o) }
            }
        }
    }

    /// What the folder says for a goal: reached, another account, timed out, or nil (still waiting). Signed out for a moment
    /// is still waiting. The account wanted is found by its ids, or by its address when it has none yet.
    static func judge(_ g: Goal, now: Seat?, markerDone: Bool, at: Date = Date()) -> Outcome? {
        if at.timeIntervalSince(g.started) > giveUp { return .timedOut }
        guard let cur = now else { return nil }
        if g.again {
            // the same account is no news until Claude Code's login says it ended well; another account is news at once
            if let from = g.from, cur.same(from) { return markerDone ? .reached : nil }
            return .other(cur)
        }
        if let from = g.from, cur.same(from) { return nil }
        return reached(g, cur) ? .reached : .other(cur)
    }

    static func reached(_ g: Goal, _ cur: Seat) -> Bool {
        // an account found by its id alone (no organisation known): the same account id is it
        if let w = g.wantedSeat { return w.organization == nil ? w.account.lowercased() == cur.account.lowercased() : w.same(cur) }
        return cur.email.map { $0.lowercased() == g.wantedEmail.lowercased() } ?? false
    }

    private func end(_ o: Outcome) {
        timer?.invalidate(); timer = nil
        clearMarker()
        // Claude Code on the account the sessions went to: the move is linked (the way back is a switch the other way)
        if o == .reached, let r = receipt { SwitchEngine.markLinked(r.id); receipt = SwitchEngine.load(r.id) ?? r }
        releaseWindow()
        // the account now in the folder is the one the profile works on, at once (the agent would within seconds too)
        if o != .timedOut { model?.noteAccounts() }
        switch o {
        case .reached: phase = .reached
        case .other(let s): phase = .other(s.email ?? "another account")
        case .timedOut: phase = .timedOut
        }
    }

    /// Renders only: the page as it looks in a phase.
    func preview(_ p: Phase, goal g: Goal?, target: StandbyAccount? = nil) {
        phase = p; goal = g; targetSnapshot = target ?? targetSnapshot
    }
}
