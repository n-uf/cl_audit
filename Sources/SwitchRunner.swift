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
    /// The profile's window, by its data folder (it doesn't change in a switch): what SwitchMarker marks.
    private var window: String? { entry.map { Launcher.dataDirKey(of: Account($0)) } }
    private func releaseWindow() { if let w = window { SwitchMarker.release(w) } }

    // MARK: the window

    /// The profile's own Claude window (by its data folder), if it runs.
    static func windowApps(_ e: AccountEntry) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
            .filter { !$0.isTerminated && Launcher.isWindow(of: Account(e), $0) }
    }

    static func windowClosed(_ e: AccountEntry) -> Bool { windowApps(e).isEmpty }

    // MARK: going

    func start() {
        guard phase == .ready || isFailed, let e = entry, let s = target, let w = window else { return }
        note = nil
        // a switch that stopped half way is put back first: never a second move on top of it
        guard SwitchEngine.unfinished(profile: profile).isEmpty else {
            phase = .failed("An earlier switch of \(e.name) didn't finish: Undo it first."); return
        }
        switch SwitchEngine.plan(e, standby: s) {
        case .failure(let why): phase = .failed(why.description); return
        case .success: break
        }
        // the window stays closed from here until the profile is linked or the switch is undone; one switch at a time
        guard SwitchMarker.claim(w, profile: profile, standby: standby) else {
            phase = .failed("Another switch of this Claude window is under way."); return
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
                self.releaseWindow()
                self.phase = .failed("The window didn't close; it may be asking about work under way. Answer it, then try again. Nothing moved.")
                return true
            }
            return false
        }
    }

    private var isFailed: Bool { if case .failed = phase { return true }; return false }

    private func move() {
        guard let e = entry, let s = target, case .success(let plan) = SwitchEngine.plan(e, standby: s) else {
            releaseWindow()
            phase = .failed("The switch couldn't be planned again. Nothing moved."); return
        }
        phase = .moving
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SwitchEngine.run(plan, windowClosed: { Self.windowClosed(e) }) }
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
        // linked: the way back is a switch now, and the window may open again
        if let id = receipt?.id { SwitchEngine.markLinked(id); receipt = SwitchEngine.load(id) ?? receipt }
        releaseWindow()
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
            break
        case .notAllowed where stillAlone:
            NSWorkspace.shared.open(url)                  // the only Claude window: the link can't reach another
        case _ where entry.map({ Self.windowApps($0).contains { $0.processIdentifier == pid } }) != true:
            sidebarOpened = false                         // never `open` then: it could start another account's window
            note = "\(name)'s window quit before the link reached it. Open the window, then Open the session."
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
        guard let r = receipt, r.linked == nil, phase == .codeSignIn || isFailed else { releaseWindow(); phase = .ready; return }
        undoUnfinished(r.id)
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
            phase = .failed("Undo didn't finish: \(error). The receipt is in cl_audit's folder (switches/\(id)).")
        }
    }

    /// The window signed in later, or not at all: the switch itself is done.
    func finish() { timer?.invalidate(); releaseWindow(); phase = .done }

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
