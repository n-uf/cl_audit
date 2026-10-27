// Rules: Opening and closing and Usage in the Dock, run only by the cl_audit agent (Agent.swift), whether or not
// cl_audit is open. What applies to a profile comes from AccountEntry.runs.
//
//   Dock icon runs · At login         started when you log in (its Claude window left as it is)
//   Dock icon runs · With its window  started when its Claude window opens, quit 10 s after the window quits
//                                      (a Claude update restarts the window)
//   Dock icon runs · When started     only when you start it
//   Claude window opens and quits with the Dock icon
//                                      a Dock icon you start opens its window (not at login); one that quits normally
//                                      quits it too (Claude can ask about unsent work)
//   Usage in the Dock off              its Dock icon quits (the window left alone), is unpinned and its app removed,
//                                      with what macOS keeps for it; its place in the Dock is remembered here. On
//                                      again: cl_audit installs it, and it's pinned back in its place and started.
//   A Dock icon dragged out of the Dock by hand turns Usage in the Dock off (kept in the Dock by hand: on); only the
//   agent records that, through the one locked write of the profiles file.
// None of this touches the usage: the agent reads it for every profile, always. Starting or quitting a Dock icon
// never restarts the Dock; only a pin or unpin does, once, through DockWriter.

import AppKit

/// Something the agent is doing for a profile, for the dashboard's switches.
struct AgentAction: Codable, Equatable {
    enum Kind: String, Codable { case dockStarts, dockQuits, windowOpens, windowQuits }
    var kind: Kind
    var at: Date          // when it started, or (dockQuits) when the Dock icon quits
}

final class AgentRules {
    private var accounts: [AccountEntry] = []
    private var lastOpen: [String: Bool] = [:]
    private var lastDock: [String: Bool] = [:]          // Usage in the Dock as last acted on
    private var startedByAgent: [String: Date] = [:]
    private var quitWork: [String: DispatchWorkItem] = [:]
    private var observers: [NSObjectProtocol] = []
    private let loginAt: Date?
    private let defaults: UserDefaults                  // the agent's: each profile's Dock place ("dockPlace.<id>")
    private var removing: Set<String> = []
    /// What it's doing now, for the dashboard (written into the agent's mark).
    private(set) var actions: [String: AgentAction] = [:] { didSet { if actions != oldValue { onChange?() } } }
    var onChange: (() -> Void)?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        loginAt = Self.consoleLoginTime()
        let stored = defaults.double(forKey: "loginSession")
        let newSession = loginAt.map { abs($0.timeIntervalSince1970 - stored) > 1 } ?? (ProcessInfo.processInfo.systemUptime < 300)
        if let loginAt { defaults.set(loginAt.timeIntervalSince1970, forKey: "loginSession") }
        accounts = Store.load()
        for e in accounts { lastDock[e.id] = e.runs.dockIcon }
        let acts = Launcher.activity(for: accounts.map(Account.init))
        for e in accounts { lastOpen[e.id] = acts[Account(e).configDir]?.desktopOpen ?? false }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.appChanged(app, launched: name == NSWorkspace.didLaunchApplicationNotification)
            })
        }
        let dn = DistributedNotificationCenter.default()
        observers.append(dn.addObserver(forName: Installer.iconQuitNote, object: nil, queue: .main) { [weak self] note in
            if let id = note.object as? String { self?.iconQuit(id) }
        })
        observers.append(dn.addObserver(forName: Installer.appsChangedNote, object: nil, queue: .main) { [weak self] _ in
            self?.applyDockSwitches()
        })
        if newSession {
            agentLog.log("agent: new login session, starting the Dock icons that run at login")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.atLogin() }
        }
        tidy()
    }

    /// The profiles file changed. A profile seen for the first time starts from its window's state now, so the
    /// window opening later counts as opening.
    func update(_ list: [AccountEntry]) {
        accounts = list
        let fresh = list.filter { lastOpen[$0.id] == nil }
        if !fresh.isEmpty {
            let acts = Launcher.activity(for: fresh.map(Account.init))
            for e in fresh { lastOpen[e.id] = acts[Account(e).configDir]?.desktopOpen ?? false }
        }
        applyDockSwitches()
    }

    /// Every 30 s: a Dock icon moved by hand, where each one is, and actions that are over.
    func tick() {
        adoptDock()
        rememberPlaces()
        tidy()
        let now = Date()
        actions = actions.filter { _, a in a.kind == .dockQuits ? a.at > now - 2 : now.timeIntervalSince(a.at) < 30 }
    }

    // MARK: at login

    private func atLogin() {
        let acts = Launcher.activity(for: accounts.map(Account.init))
        for e in accounts {
            let r = e.runs, open = acts[Account(e).configDir]?.desktopOpen ?? false
            if r.atLogin || (r.withWindow && open) { startDock(e, reason: r.atLogin ? "at login" : "its window is open") }
        }
    }

    /// The first minutes after you log in: a Dock icon macOS reopens doesn't open its window then.
    private var loggingIn: Bool { loginAt.map { Date().timeIntervalSince($0) < 180 } ?? (ProcessInfo.processInfo.systemUptime < 180) }

    // MARK: windows and Dock icons starting and quitting

    private func appChanged(_ app: NSRunningApplication, launched: Bool) {
        if app.bundleIdentifier == Launcher.claudeBundleID {
            // a window that just started has its arguments a moment later; a quitting one is gone right away
            windowsChanged()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowsChanged() }
        } else if let bid = app.bundleIdentifier, bid.hasPrefix(Installer.managerID + "."),
                  let e = accounts.first(where: { Installer.bundleID($0) == bid }) {
            if launched { dockStarted(e, app) } else if actions[e.id]?.kind == .dockQuits { actions[e.id] = nil }
        }
    }

    private func windowsChanged() {
        let acts = Launcher.activity(for: accounts.map(Account.init))
        for e in accounts {
            let open = acts[Account(e).configDir]?.desktopOpen ?? false
            let was = lastOpen[e.id]
            lastOpen[e.id] = open
            if actions[e.id]?.kind == .windowOpens && open { actions[e.id] = nil }
            if actions[e.id]?.kind == .windowQuits && !open { actions[e.id] = nil }
            guard let was, was != open, e.runs.withWindow else { continue }
            if open {
                quitWork[e.id]?.cancel(); quitWork[e.id] = nil
                if actions[e.id]?.kind == .dockQuits { actions[e.id] = nil }
                if !Installer.isRunning(e) { startDock(e, reason: "its window opened") }
            } else if Installer.isRunning(e) {
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.quitWork[e.id] = nil
                    guard let now = self.accounts.first(where: { $0.id == e.id }), now.runs.withWindow,
                          !self.windowOpen(now) else { if self.actions[e.id]?.kind == .dockQuits { self.actions[e.id] = nil }; return }
                    self.quitDock(now, reason: "its window quit")
                }
                quitWork[e.id]?.cancel()
                quitWork[e.id] = w
                actions[e.id] = AgentAction(kind: .dockQuits, at: Date() + 10)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
            }
        }
    }

    /// A Dock icon started: started by you (a click in the Dock, the dashboard), its window opens too when it follows.
    private func dockStarted(_ e: AccountEntry, _ app: NSRunningApplication) {
        if actions[e.id]?.kind == .dockStarts { actions[e.id] = nil }
        let byAgent = startedByAgent[e.id].map { Date().timeIntervalSince($0) < 20 } ?? false
        let quiet = Launcher.arguments(of: app.processIdentifier).contains("--no-follow")
        guard e.runs.windowFollowsDock, !byAgent, !quiet, !loggingIn, !windowOpen(e) else { return }
        agentLog.log("agent: \(e.id, privacy: .public): Dock icon started, opening its window")
        actions[e.id] = AgentAction(kind: .windowOpens, at: Date())
        Launcher.openClaude(Account(e))
    }

    /// A Dock icon quit normally (not a reinstall, not Usage in the Dock off, not "Quit and keep Claude window").
    private func iconQuit(_ id: String) {
        guard let e = accounts.first(where: { $0.id == id }), e.runs.windowFollowsDock, windowOpen(e) else { return }
        agentLog.log("agent: \(id, privacy: .public): Dock icon quit, quitting its window")
        actions[id] = AgentAction(kind: .windowQuits, at: Date())
        NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
            .filter { Launcher.isWindow(of: Account(e), $0) }.forEach { $0.terminate() }
    }

    private func windowOpen(_ e: AccountEntry) -> Bool {
        Launcher.activity(for: [Account(e)])[Account(e).configDir]?.desktopOpen ?? false
    }

    private func startDock(_ e: AccountEntry, reason: String) {
        let app = Installer.appURL(e)
        guard e.runs.dockIcon, FileManager.default.fileExists(atPath: app.path), !Installer.isRunning(e) else { return }
        agentLog.log("agent: \(e.id, privacy: .public): starting its Dock icon (\(reason, privacy: .public))")
        startedByAgent[e.id] = Date()
        actions[e.id] = AgentAction(kind: .dockStarts, at: Date())
        Installer.run("/usr/bin/open", ["-g", app.path, "--args", "--no-follow"])
    }

    /// Quits a Dock icon without taking its window along.
    private func quitDock(_ e: AccountEntry, reason: String) {
        let apps = Installer.running(e)
        guard !apps.isEmpty else { return }
        agentLog.log("agent: \(e.id, privacy: .public): quitting its Dock icon (\(reason, privacy: .public))")
        DistributedNotificationCenter.default().postNotificationName(Installer.quietQuitNote, object: e.id, userInfo: nil, deliverImmediately: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { apps.forEach { $0.terminate() } }
    }

    // MARK: Usage in the Dock

    /// Usage in the Dock turned on or off (in cl_audit, or by dragging the icon): quit and unpin, or pin and start.
    /// A new profile's Dock icon is pinned after the other cl_audit icons once cl_audit has installed it.
    private func applyDockSwitches() {
        for e in accounts {
            let on = e.runs.dockIcon, app = Installer.appURL(e)
            let exists = FileManager.default.fileExists(atPath: app.path)
            if let was = lastDock[e.id], was == on { continue }
            if lastDock[e.id] == nil && !on { lastDock[e.id] = false; continue }      // a new profile without a Dock icon
            if on {
                guard exists else { lastDock[e.id] = lastDock[e.id] ?? false; continue }   // cl_audit installs it first
                lastDock[e.id] = true
                let place = defaults.object(forKey: "dockPlace.\(e.id)") as? String
                agentLog.log("agent: \(e.id, privacy: .public): Usage in the Dock on, pinning \(place == nil ? "after the other icons" : "in its place", privacy: .public) and starting")
                DockManager.pinInBackground(app, after: place)
                startDock(e, reason: "Usage in the Dock on")
            } else {
                lastDock[e.id] = false
                agentLog.log("agent: \(e.id, privacy: .public): Usage in the Dock off")
                removeApp(e)
            }
        }
        let ids = Set(accounts.map(\.id))
        lastDock = lastDock.filter { ids.contains($0.key) }
        lastOpen = lastOpen.filter { ids.contains($0.key) }
    }

    /// Usage in the Dock off: its place in the Dock remembered, the Dock icon quit (its window left alone), unpinned
    /// in one Dock write, and its app removed with what macOS keeps for it. Turned back on meanwhile, it stays.
    private func removeApp(_ e: AccountEntry) {
        let app = Installer.appURL(e)
        guard FileManager.default.fileExists(atPath: app.path), !removing.contains(e.id) else { return }
        removing.insert(e.id)
        if let p = DockManager.place(of: app) { defaults.set(p, forKey: "dockPlace.\(e.id)") }
        agentLog.log("agent: \(e.id, privacy: .public): quitting, unpinning and removing its Dock icon app")
        Installer.stop(app)
        DockManager.unpin(app) { [weak self] in
            self?.removing.remove(e.id)
            guard let now = Store.loadChecked()?.first(where: { $0.id == e.id }), !now.runs.dockIcon else { return }
            AccountRemoval.removeDockApp(id: e.id, app: app)
            agentLog.log("agent: \(e.id, privacy: .public): Dock icon app removed")
        }
    }

    /// Where each pinned Dock icon is, so one that goes (Usage in the Dock off, or dragged out) comes back there.
    private func rememberPlaces() {
        for e in accounts where e.runs.dockIcon {
            if let p = DockManager.place(of: Installer.appURL(e)) { defaults.set(p, forKey: "dockPlace.\(e.id)") }
        }
    }

    /// The switch follows the Dock: a Dock icon dragged out by hand → Usage in the Dock off (and its app goes);
    /// kept in the Dock by hand → on.
    private func adoptDock() {
        for e in accounts {
            guard let hidden = DockManager.adoptDock(e) else { continue }
            Store.update(e.id) { $0.iconHidden = hidden }
            lastDock[e.id] = !hidden            // the Dock already shows it as it is
            if hidden { var off = e; off.iconHidden = true; removeApp(off) }
        }
    }

    /// A Dock icon app for a profile whose Usage in the Dock is off isn't supposed to exist (one an older version
    /// kept, or hid): it goes, its window left alone. Read fresh, so a profile just turned on is never touched.
    private func tidy() {
        guard let fresh = Store.loadChecked() else { return }
        for e in fresh where !e.runs.dockIcon {
            let app = Installer.appURL(e)
            guard FileManager.default.fileExists(atPath: app.path), !DockManager.changing(app) else { continue }
            removeApp(e)
        }
    }

    // MARK: the login session

    /// When you logged in to the Mac (the console session in the login records), so a restart of the agent within
    /// the same session doesn't start the At login Dock icons again.
    static func consoleLoginTime() -> Date? {
        var latest: Date?
        setutxent()
        defer { endutxent() }
        while let p = getutxent() {
            var u = p.pointee
            guard u.ut_type == Int16(USER_PROCESS) else { continue }
            let line = withUnsafeBytes(of: &u.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let user = withUnsafeBytes(of: &u.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard line == "console", user == NSUserName() else { continue }
            let t = Date(timeIntervalSince1970: TimeInterval(u.ut_tv.tv_sec))
            if latest.map({ t > $0 }) ?? true { latest = t }
        }
        return latest
    }
}
