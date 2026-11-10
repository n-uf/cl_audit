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
// Nothing else moves: the sessions stay in the folder, each with the account it ran on; the Claude window, its sidebar,
// its scheduled tasks and its own sign-in are left alone. cl_audit never sees a password or a token and never touches
// the Keychain. "Sign in again" on the account in use is the same run: the folder's account doesn't change then, so only
// Claude Code's login ending well (the script leaves a marker, ClaudeCLI.openLogin) says it's done.

import AppKit

final class SwitchRunner: ObservableObject {
    enum Phase: Equatable {
        case ready
        case waiting                    // Terminal shows Claude Code's sign-in; the folder is looked at every 2 s
        case reached                    // the folder is on the account wanted
        case other(String)              // the folder is on another account: its address
        case timedOut                   // no sign-in came in 10 minutes
        case failed(String)             // the sign-in couldn't start: why
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
    private weak var model: SettingsModel?
    private var timer: Timer?
    private let reads = DispatchQueue(label: "cl_audit.switch-reads", qos: .utility)

    init(profile: String, model: SettingsModel) {
        self.profile = profile; self.model = model
    }

    var isRunning: Bool { phase == .waiting }

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

    /// Switch to a standby account: Claude Code's sign-in on the profile's folder with its address filled in, then the
    /// folder is watched.
    func start(_ s: StandbyAccount) {
        guard phase != .waiting, let e = entry else { return }
        targetSnapshot = s
        begin(e, Goal(standby: s.id, wantedSeat: s.seat, wantedEmail: s.email,
                      from: Account.signedInSeat(configDir: e.configDir), started: Date()))
    }

    /// Sign in again on the account in use (its sign-in stopped working, or the folder is signed out): the same watch.
    func signInAgain() {
        guard phase != .waiting, let e = entry, let email = e.seat?.email ?? Account.expectedEmail(configDir: e.configDir) else { return }
        targetSnapshot = nil
        begin(e, Goal(standby: nil, wantedSeat: e.seat, wantedEmail: email,
                      from: Account.signedInSeat(configDir: e.configDir), started: Date()))
    }

    /// The same account again (after another account signed in, or nothing did in time).
    func retry() {
        guard let g = goal, phase != .waiting else { return }
        if g.standby == nil { signInAgain(); return }
        if let s = entry?.standby.first(where: { $0.id == g.standby }) ?? targetSnapshot { start(s) }
    }

    private func begin(_ e: AccountEntry, _ g: Goal) {
        clearMarker()
        guard let claude = model?.requireClaude() else { goal = g; phase = .failed(model?.noClaudeWhy ?? ClaudeInstall.missing + "."); return }
        guard ClaudeCLI.openLogin(claude, account: Account(e), email: g.wantedEmail, marker: g.again ? Self.marker(for: profile) : nil) else {
            goal = g; phase = .failed("Terminal didn't open."); return
        }
        goal = g
        phase = .waiting
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in self?.look() }
    }

    /// Stops waiting: nothing changed, so there is nothing to put back.
    func cancel() {
        timer?.invalidate(); timer = nil
        clearMarker()
        if phase == .waiting { phase = .ready }
    }

    /// Back to the start, for another switch from the page.
    func reset() { cancel(); phase = .ready; goal = nil }

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
        if let w = g.wantedSeat { return w.same(cur) }
        return cur.email.map { $0.lowercased() == g.wantedEmail.lowercased() } ?? false
    }

    private func end(_ o: Outcome) {
        timer?.invalidate(); timer = nil
        clearMarker()
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
