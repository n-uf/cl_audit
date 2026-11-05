// SwitchRunner: one switch, step by step, for the Switch page (SwitchView.swift), with SwitchEngine doing the moving.
//
//   1. the profile's Claude window closes (gracefully; only that window, by its data folder; never force-quit)
//   2. its sessions and scheduled tasks move to the other account (Sessions follow on), with a receipt
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
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var receipt: SwitchReceipt?
    @Published private(set) var note: String?            // a word under the steps (signed in as another account, …)
    @Published private(set) var sidebarOpened = false     // the session that arranges the sidebar was opened
    private weak var model: SettingsModel?
    private var timer: Timer?
    private var started = Date()

    init(profile: String, standby: String, model: SettingsModel) {
        self.profile = profile; self.standby = standby; self.model = model
    }

    var key: String { AccountEntry.standbyStatusID(profile, standby) }
    private var entry: AccountEntry? { model?.accounts.first { $0.id == profile } }
    private var target: StandbyAccount? { entry?.standby.first { $0.id == standby } }

    // MARK: the window

    /// The profile's own Claude window (by its data folder), if it runs.
    static func windowApps(_ e: AccountEntry) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
            .filter { !$0.isTerminated && Launcher.isWindow(of: Account(e), $0) }
    }

    static func windowClosed(_ e: AccountEntry) -> Bool { windowApps(e).isEmpty }

    // MARK: going

    func start() {
        guard phase == .ready || isFailed, let e = entry, let s = target else { return }
        note = nil
        switch SwitchEngine.plan(e, standby: s) {
        case .failure(let why): phase = .failed(why.description); return
        case .success: break
        }
        let apps = Self.windowApps(e)
        if apps.isEmpty { move() ; return }
        phase = .closing
        apps.forEach { $0.terminate() }               // the window's own quit: it may ask about work under way
        started = Date()
        tick(every: 0.5) { [weak self] in
            guard let self, let e = self.entry else { return true }
            if Self.windowClosed(e) { self.move(); return true }
            if Date().timeIntervalSince(self.started) > 45 {
                self.phase = .failed("The window didn't close; it may be asking about work under way. Answer it, then try again. Nothing moved.")
                return true
            }
            return false
        }
    }

    private var isFailed: Bool { if case .failed = phase { return true }; return false }

    private func move() {
        guard let e = entry, let s = target, case .success(let plan) = SwitchEngine.plan(e, standby: s) else {
            phase = .failed("The switch couldn't be planned again."); return
        }
        phase = .moving
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SwitchEngine.run(plan, windowClosed: { Self.windowClosed(e) }) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let r):
                    self.receipt = r
                    if !r.problems.isEmpty { self.note = "Left where they were: " + r.problems.joined(separator: "; ") }
                    self.signInCode()
                case .failure(let err):
                    self.phase = .failed("\(err)")
                }
            }
        }
    }

    /// Claude Code's own sign-in for the profile's folder, with the account's address filled in.
    func signInCode() {
        guard let e = entry, let s = target else { return }
        phase = .codeSignIn
        if let claude = model?.claudePath { ClaudeCLI.openLogin(claude, account: Account(e), email: s.email) }
        else { note = "Claude Code wasn't found on this Mac: sign in from Terminal, then come back." }
        started = Date()
        tick(every: 2) { [weak self] in
            guard let self, let e = self.entry, let s = self.target, let to = s.seat else { return true }
            guard let now = Account.signedInSeat(configDir: e.configDir) else { return false }
            if now.same(to) { self.linked(); return true }
            if let from = e.seat, now.same(from) { return false }        // not yet
            self.note = "Claude Code signed in as \(Privacy.masked(now.email ?? "another account")), not \(Privacy.masked(s.email)): sign in again."
            return false
        }
    }

    /// Claude Code is on the new account: the profile works on it now, the old one stands by; the window opens again.
    private func linked() {
        guard let m = model, let before = entry, let out = FolderRules.completeSwitch(profile, to: standby, in: m.accounts) else {
            phase = .failed("The profile couldn't be linked to the new account."); return
        }
        m.accounts = out
        // each account keeps its own numbers: never the old account's under the new one's name
        if let after = out.first(where: { $0.id == profile }) { FolderRules.moveNumbers(before, after) }
        note = nil
        phase = .windowSignIn
        guard let e = entry else { return }
        if e.claudeWindow { Launcher.openClaude(Account(e)) }
        let to = e.seat?.account
        tick(every: 2) { [weak self] in
            guard let self, let e = self.entry else { return true }
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
        sidebarOpened = true
        note = nil
        Launcher.openClaude(Account(e))
        let started = Date()
        tick(every: 1) { [weak self] in
            guard let self, let e = self.entry else { return true }
            guard let pid = Self.windowApps(e).first?.processIdentifier else {
                if Date().timeIntervalSince(started) < 20 { return false }
                self.sidebarOpened = false
                self.note = "The window didn't open. Open it, then Open the session."
                return true
            }
            let alone = NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
                .allSatisfy { $0.isTerminated || $0.processIdentifier == pid }
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = WindowLink.send(url, to: pid)
                DispatchQueue.main.async { [weak self] in self?.linkSent(outcome, url: url, alone: alone, name: e.name) }
            }
            return true
        }
    }

    private func linkSent(_ outcome: WindowLink.Outcome, url: URL, alone: Bool, name: String) {
        switch outcome {
        case .sent:
            break
        case .notAllowed where alone, .failed where alone:
            NSWorkspace.shared.open(url)                  // the only Claude window: the link can't reach another
        case .notAllowed:
            sidebarOpened = false
            note = "cl_audit may not send the link to \(name)'s window, and other Claude windows are open, so nothing opened. Allow cl_audit to control Claude (System Settings ▸ Privacy & Security ▸ Automation), or quit the other Claude windows, then Open the session."
        case .failed(let code):
            sidebarOpened = false
            note = "The link didn't reach \(name)'s window (\(code)). Open the session to try again."
        }
    }

    /// Cancel before Claude Code signed in: the sessions go back (the window is still closed then); nothing else changed.
    func cancel() {
        timer?.invalidate()
        guard let r = receipt, phase == .codeSignIn || isFailed else { phase = .ready; return }
        guard let e = entry else { return }
        do {
            try SwitchEngine.undo(r.id, windowClosed: { Self.windowClosed(e) })
            receipt = SwitchEngine.load(r.id)
            phase = .cancelled
            if e.claudeWindow { Launcher.openClaude(Account(e)) }
        } catch {
            phase = .failed("Undo didn't finish: \(error). The receipt is in cl_audit's folder (switches/\(r.id)).")
        }
    }

    /// The window signed in later, or not at all: the switch itself is done.
    func finish() { timer?.invalidate(); phase = .done }

    /// Renders only: the page as it looks at a step.
    func preview(_ p: Phase, receipt r: SwitchReceipt? = nil, note n: String? = nil, sidebarOpened o: Bool = false) {
        phase = p; receipt = r; note = n; sidebarOpened = o
    }

    private func tick(every s: TimeInterval, _ step: @escaping () -> Bool) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: s, repeats: true) { [weak self] t in
            if step() { t.invalidate(); if self?.timer === t { self?.timer = nil } }
        }
    }
}
