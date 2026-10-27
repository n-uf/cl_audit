import AppKit
import ServiceManagement

// MARK: - App
//
// The same binary plays two roles. Without UsageAccountID in its Info.plist it is the settings app
// ("cl_audit"): it shows the settings window and quits when that closes. With it, it is one
// account's Dock icon.

final class AppDelegate: NSObject, NSApplicationDelegate {
    let accountID = Bundle.main.infoDictionary?["UsageAccountID"] as? String
    var isSettingsApp: Bool { accountID == nil }
    lazy var entry: AccountEntry = Self.loadEntry(accountID ?? "")
    lazy var account = Account(entry)
    let details = DetailsController()
    lazy var manager = ManagerUI()          // the settings app's launcher palette and main screen
    var lastClick = Date.distantPast
    /// When cl_audit last came to the front: a Dock click that did this found its window behind others.
    var activatedAt = Date.distantPast
    let defaults = UserDefaults.standard
    let claudeBundleID = "com.anthropic.claudefordesktop"

    // A Dock icon only shows what the cl_audit agent saved for its profile (status/<id>.json): it never reads the
    // Keychain or the network, sends no alerts and has no login item. Refresh and renew are asked of the agent.
    var status: IconStatus?
    /// Refresh now was asked: "Updating…" until the agent saves newer numbers (at most 15 s).
    var refreshAsked: Date?
    var claudeOpen = false        // this account's Claude window is running (drawn as a dot on the tile)
    var quietQuit = false         // quit without taking the Claude window along (cl_audit reinstalling, or "Quit and keep")
    var quitForWindow = false     // quitting because the Claude window quit ("the Dock icon follows the window")
    var windowQuitWork: DispatchWorkItem?
    var appliedHidden: Bool?
    var tileView: TileView!
    var timer: Timer?

    var style: IconStyle { entry.style }
    var pollMinutes: Int { max(entry.pollMinutes, 1) }

    static func loadEntry(_ id: String) -> AccountEntry {
        Store.load().first { $0.id == id } ?? AccountEntry(id: id, name: id, label: "?", configDir: "~/.claude")
    }

    // MARK: what the agent saved

    var usage: Usage? {
        guard let s = status, let at = s.updatedAt, s.fiveHour != nil || s.weekly != nil else { return nil }
        return Usage(fiveHour: s.fiveHour, fiveHourResets: s.fiveHourResets, weekly: s.weekly, weeklyResets: s.weeklyResets,
                     fetchedAt: at, source: s.source ?? "Anthropic")
    }
    var loginEmail: String? { status?.loginEmail }
    var plan: String? { status?.plan }
    var expired: Bool { status?.state == "expired" }
    var noLogin: Bool { status?.state == "noLogin" }
    var renewing: Bool { status?.renewing == true }
    var refreshing: Bool {
        guard let t = refreshAsked else { return false }
        return Date().timeIntervalSince(t) < 15 && (status?.updatedAt ?? .distantPast) < t
    }
    /// Why the numbers aren't fresh, in words: the agent not running comes first.
    var problem: String? {
        Agent.isAlive(Agent.readMark()) ? status?.problem : "Not updating: the cl_audit agent isn't running (open cl_audit)"
    }

    func loadStatus() {
        status = Store.status(entry.id)
        redraw()
    }

    @objc func statusChanged(_ note: Notification) {
        guard (note.object as? String) == accountID else { return }
        loadStatus()
    }

    func applyEntry() {
        account = Account(entry)
        applyVisibility()
        redraw()
    }

    /// Before the agent, each Dock icon app was its own login item; macOS only lets an app remove its own, so each copy
    /// does it when it runs (and the agent runs each copy once with --forget-login-item).
    static func forgetLoginItem() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled || svc.status == .requiresApproval { try? svc.unregister() }
        UserDefaults.standard.removeObject(forKey: "loginItemPath")
    }

    /// Shown: a normal app with its Dock tile. Hidden: a background app (no tile).
    /// The mode is set once, at launch (switching it while running is unreliable on macOS); a change restarts
    /// the app. Hiding takes its pin out and remembers the place; showing puts it back there.
    func applyVisibility() {
        guard !isSettingsApp else { return }
        let hide = entry.iconHidden
        if let applied = appliedHidden {
            guard applied != hide else { return }
            dockLog.log("\(self.entry.id, privacy: .public): Show in the Dock \(hide ? "off" : "on", privacy: .public), relaunching")
            DockManager.markChange(Bundle.main.bundleURL)
            relaunch()
            return
        }
        appliedHidden = hide
        dockLog.log("\(self.entry.id, privacy: .public): started \(hide ? "hidden" : "shown", privacy: .public)")
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
        // hidden is never pinned; shown is pinned when the switch was just turned on (a normal start leaves the Dock
        // as you arranged it, so taking it out of the Dock by hand sticks)
        if hide { DockManager.unpinRemembering(Bundle.main.bundleURL, defaults: defaults) }
        else if CommandLine.arguments.contains("--dock-changed") { DockManager.repin(Bundle.main.bundleURL, defaults: defaults) }
    }

    /// Quits and starts again a moment later (in the background, without opening its Claude window).
    func relaunch() {
        quietQuit = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // --dock-changed: the new process pins itself if Show in the Dock was just turned on
        p.arguments = ["-c", "sleep 1.5; /usr/bin/open -g \"$0\" --args --no-follow --dock-changed", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc func configChanged() {
        // a removed profile: quit quietly (cl_audit takes the app away), never carry on with default settings
        guard let fresh = Store.loadChecked()?.first(where: { $0.id == entry.id }) else {
            if Store.loadChecked() != nil { quietQuit = true; NSApp.terminate(nil) }
            return
        }
        guard fresh != entry else { return }
        entry = fresh
        applyEntry()
        refreshWindowState()          // a new open/close mode applies right away, not at the next refresh
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // A hidden cl_usage starts as a background app, so its tile never flashes up.
        NSApp.setActivationPolicy(isSettingsApp || !entry.iconHidden ? .regular : .accessory)
        if isSettingsApp {
            NSWindow.allowsAutomaticWindowTabbing = false   // Settings and Dashboard are separate windows
            AppIconPrefs.shared.apply()                    // the chosen app icon (Settings ▸ General ▸ App icon)
            MainMenu.install()
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(showSettingsWindow),
                                                                name: Installer.openSettingsNote, object: nil)
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(showMainScreen),
                                                                name: Installer.openDashboardNote, object: nil)
            // cl_usage that follows its Claude window: started here when that window opens.
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
                guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Launcher.claudeBundleID else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Installer.startFollowers() }
            }
            // A profile's style, colour or frame changed (here or in its Dock icon's menu): redraw its icon file, now
            // for a stopped Dock icon app, when it quits for a running one.
            DistributedNotificationCenter.default().addObserver(forName: Store.changed, object: nil, queue: .main) { _ in
                Installer.lookMayHaveChanged()
            }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier?.hasPrefix(Installer.managerID + ".") == true else { return }
                Installer.lookMayHaveChanged(after: 5)   // past a relaunch (Show in the Dock restarts it after 1.5 s)
            }
            // On start: reinstall missing cl_usage apps and start the ones that should run.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if Store.exists { Installer.sync(Store.load()) }
                // the one login item; restarted when it runs an older build (waits for it, so off the main thread)
                DispatchQueue.global(qos: .utility).async { Agent.ensureRunning() }
            }
            if CommandLine.arguments.contains("--settings") {
                let account = CommandLine.arguments.first { $0.hasPrefix("--account=") }.map { String($0.dropFirst("--account=".count)) }
                manager.showMain(page: .settings, account: account)
            } else { manager.showMain() }
            return
        }
        Self.forgetLoginItem()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(configChanged), name: Store.changed, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(statusChanged(_:)), name: Store.statusChanged, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(quietQuitAsked(_:)), name: Installer.quietQuitNote, object: accountID)
        status = Store.status(entry.id)
        tileView = TileView(model: model())
        NSApp.dockTile.contentView = tileView
        NSApp.dockTile.display()
        redraw()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        tick()
        applyEntry()
        // "Window follows": starting cl_usage opens its Claude window, but not at login and not when cl_audit
        // starts it (it passes --no-follow), so neither opens every window at once.
        let atLogin = ProcessInfo.processInfo.systemUptime < 180
        if entry.follows.windowFollowsUsage, !claudeOpen,
           !CommandLine.arguments.contains("--no-follow"), !atLogin {
            Launcher.openClaude(account)
        }
    }

    @objc func quietQuitAsked(_ note: Notification) { quietQuit = true }

    // The settings app stays in the Dock after its windows close: its icon is the launcher.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// An icon app quit because its account was removed takes its open-at-login entry with it. Otherwise, with
    /// "Window follows" or "Lockstep", quitting cl_usage quits its Claude window too (a normal quit, so Claude can
    /// ask about unsent work), unless it's quitting because of that window, or was asked to keep it.
    func applicationWillTerminate(_ note: Notification) {
        guard !isSettingsApp, let id = accountID else { return }
        guard Store.load().contains(where: { $0.id == id }) else { Self.forgetLoginItem(); return }
        if entry.follows.windowFollowsUsage, !quietQuit, !quitForWindow { quitClaudeWindow() }
    }

    @objc func quitClaudeWindow() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
            .filter { Launcher.isWindow(of: account, $0) }
            .forEach { $0.terminate() }
    }

    @objc func quitKeepingWindow() { quietQuit = true; NSApp.terminate(nil) }

    /// From the menu (no account) or an icon app's "Settings…" and gear (its account id as the object).
    @objc func showSettingsWindow(_ note: Any?) {
        manager.closePalette()
        manager.showMain(page: .settings, account: (note as? Notification)?.object as? String)
    }
    @objc func showMainScreen() { manager.showMain() }
    @objc func showLauncher() { manager.togglePalette() }
    @objc func openAccountFromMenu(_ item: NSMenuItem) {
        if let id = item.representedObject as? String, let e = Store.load().first(where: { $0.id == id }) {
            Launcher.openClaude(Account(e))
        }
    }

    /// The settings app's Dock menu: a long press opens the main screen; right-click lists the accounts.
    func managerDockMenu() -> NSMenu {
        let m = NSMenu(); m.autoenablesItems = false
        func add(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; m.addItem(i)
        }
        let leftDown = NSEvent.pressedMouseButtons & 1 != 0
        if leftDown && !NSEvent.modifierFlags.contains(.control) {
            DispatchQueue.main.async { self.manager.closePalette(); self.manager.showMain() }
            add("Settings…", #selector(showSettingsWindow))
            return m
        }
        for e in Store.load() {
            let i = NSMenuItem(title: "Open Claude \(e.name)", action: #selector(openAccountFromMenu(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = e.id; m.addItem(i)
        }
        m.addItem(.separator())
        add("Dashboard", #selector(showMainScreen))
        add("Launcher", #selector(showLauncher))
        add("Settings…", #selector(showSettingsWindow))
        return m
    }

    func applicationDidBecomeActive(_ note: Notification) { activatedAt = Date() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if isSettingsApp {
            // the click also brings cl_audit to the front, before or after this call: it was in front only if it is
            // active now and didn't just become so
            manager.togglePalette(wasInFront: NSApp.isActive && Date().timeIntervalSince(activatedAt) > 0.5)
            return false
        }
        // Click: the account's click action. Double-click or ⌥-click: the full details panel.
        // (Press-and-hold and right-click open the Dock menu; macOS doesn't pass those on.)
        let now = Date()
        let doubleClick = now.timeIntervalSince(lastClick) < 0.45
        lastClick = now
        if doubleClick || NSEvent.modifierFlags.contains(.option) {
            details.endPeek()
            details.open(detailsInfo(), detailsActions())
            return false
        }
        // Without a Claude window a click can only show the usage: "Opens Claude" shows the details panel instead,
        // and "Usage, then Claude" the usage alone (opening Claude does nothing then).
        let action: ClickAction = entry.claudeWindow || entry.clickAction != .open ? entry.clickAction : .details
        switch action {
        case .details:
            details.toggle(detailsInfo(), detailsActions())
        case .peekThenOpen:
            details.peek(detailsInfo(), seconds: entry.peekSeconds)
            openClaude()
        case .open:
            openClaude()
        }
        return false
    }

    func detailsInfo() -> DetailsInfo {
        var icon = model(); icon.warn = false
        let info = DetailsInfo(
            name: account.name, icon: Painter.image(icon, pixels: 128),
            login: loginEmail, expected: expectedEmail, mismatch: mismatch, plan: plan,
            fiveHour: usage?.fiveHour, fiveHourResets: usage?.fiveHourResets,
            weekly: usage?.weekly, weeklyResets: usage?.weeklyResets,
            updated: usage?.fetchedAt, source: usage?.source,
            problem: problem, renewNote: status?.renewNote,
            needsLogin: mismatch || noLogin || expired,
            design: entry.panelDesign,
            accent: entry.accentNSColor,
            refreshing: refreshing)
        return info
    }

    func detailsActions() -> DetailsActions {
        DetailsActions(
            openClaude: { [weak self] in self?.openClaude() },
            refresh: { [weak self] in self?.refreshNow() },
            settings: { [accountID] in Installer.openSettings(account: accountID) },
            logIn: { [weak self] in self?.logIn() },
            dashboard: { Installer.openDashboard() })
    }

    // MARK: data

    var isStale: Bool {
        guard let usage else { return true }
        let limit = max(TimeInterval(pollMinutes * 60) * 3, 30 * 60)
        return Date().timeIntervalSince(usage.fetchedAt) > limit
    }

    var expectedEmail: String? { status?.expectedEmail ?? account.expectedEmail() }

    /// The login in the Keychain belongs to a different account than this folder is set up for.
    var mismatch: Bool {
        guard let a = loginEmail, let b = expectedEmail else { return false }
        return a.lowercased() != b.lowercased()
    }

    func model() -> TileModel {
        TileModel(label: account.label, fiveHour: usage?.fiveHour, weekly: usage?.weekly,
                  stale: isStale || expired || noLogin, style: style, warn: mismatch,
                  tint: entry.color, frame: entry.frame,
                  fiveHourElapsed: windowElapsed(usage?.fiveHourResets, 5 * 3600),
                  weeklyElapsed: windowElapsed(usage?.weeklyResets, 7 * 86400), windowOpen: claudeOpen && entry.windowDot)
    }

    func redraw() {
        guard !isSettingsApp, tileView != nil else { return }
        if details.isShown { details.update(detailsInfo(), detailsActions()) }   // an open panel follows along
        tileView.model = model()
        NSApp.dockTile.display()
    }

    /// Whether this account's Claude window is running; redraws the tile when that changes.
    func refreshWindowState() {
        let open = windowIsOpen()
        if open != claudeOpen { claudeOpen = open; redraw() }
        // "The Dock icon follows the window": its window quit → quit too, after 10 s (a Claude update restarts the window).
        if entry.follows.usageFollowsWindow, !open {
            guard windowQuitWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.windowQuitWork = nil
                if self.entry.follows.usageFollowsWindow, !self.windowIsOpen() { self.quitForWindow = true; NSApp.terminate(nil) }
            }
            windowQuitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        } else {
            windowQuitWork?.cancel(); windowQuitWork = nil
        }
    }

    func windowIsOpen() -> Bool {
        Launcher.activity(for: [account])[account.configDir]?.desktopOpen ?? false
    }

    @objc func appsChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Launcher.claudeBundleID else { return }
        // A window that just started has its arguments a moment later; a quitting one is gone right away.
        refreshWindowState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshWindowState() }
    }

    func tick() {
        refreshWindowState()
        // Show in the Dock follows the Dock: dragged out by hand → background; kept in the Dock by hand → shown
        if !isSettingsApp, let hidden = DockManager.adoptDock(entry) { Store.update(entry.id) { $0.iconHidden = hidden } }
        loadStatus()                  // also redraws: the staleness and the agent's state change with time
    }

    // MARK: opening Claude

    @objc func openClaude() { Launcher.openClaude(account) }

    // MARK: menu

    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: Date()) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: d)
    }

    static func ago(_ d: Date) -> String {
        let m = Int(Date().timeIntervalSince(d) / 60)
        return m < 1 ? "just now" : m < 60 ? "\(m) min ago" : "\(m / 60) h \(m % 60) min ago"
    }

    func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        if isSettingsApp { return managerDockMenu() }
        // Experimental long press: the Dock asks for this menu both on right-click and on
        // press-and-hold. With the left button still down (and no Control key), it's a long press:
        // show the details panel and keep the Dock's menu short.
        let leftDown = NSEvent.pressedMouseButtons & 1 != 0
        if entry.longPressDetails, leftDown, !NSEvent.modifierFlags.contains(.control) {
            DispatchQueue.main.async { self.details.openBesideDockMenu(self.detailsInfo(), self.detailsActions()) }
            let short = NSMenu(); short.autoenablesItems = false
            let settings = NSMenuItem(title: "Profile settings…", action: #selector(showSettings), keyEquivalent: "")
            settings.target = self; short.addItem(settings)
            return short
        }
        let m = NSMenu(); m.autoenablesItems = false
        m.addItem(info("Claude \(account.name)" + (plan.map { " · \($0)" } ?? "")))
        m.addItem(.separator())
        func line(_ title: String, _ p: Double?, _ r: Date?) {
            m.addItem(info("\(title): \(Painter.pct(p))" + (r.map { " · resets \(Self.when($0))" } ?? "")))
        }
        line("5-hour limit", usage?.fiveHour, usage?.fiveHourResets)
        line("Weekly limit", usage?.weekly, usage?.weeklyResets)
        if let usage { m.addItem(info("Updated \(Self.ago(usage.fetchedAt)) · \(usage.source)")) }
        if let why = problem { m.addItem(info(why)) }
        if let note = status?.renewNote { m.addItem(info(note)) }
        if Privacy.shared.show || loginEmail == nil { m.addItem(info("Login: \(loginEmail ?? "checking…")")) }
        if mismatch, let want = expectedEmail {
            m.addItem(info(Privacy.shared.show ? "⚠︎ This folder is set up for \(want)" : "⚠︎ This folder is set up for a different account"))
        }
        if mismatch || noLogin || expired {
            let login = NSMenuItem(title: "Log in…", action: #selector(logIn), keyEquivalent: "")
            login.target = self; m.addItem(login)
        }
        m.addItem(.separator())

        // Actions only; how the icon looks and behaves is set in its profile settings.
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; i.isEnabled = enabled; m.addItem(i)
        }
        if entry.claudeWindow {
            add(claudeOpen ? "Show Claude window" : "Open Claude window", #selector(openClaude))
            if claudeOpen { add("Quit Claude window", #selector(quitClaudeWindow)) }
        }
        add("Refresh now", #selector(refreshNow))
        if expired { add(renewing ? "Renewing login…" : "Renew login now (uses a little usage)", #selector(renewLogin), enabled: !renewing) }
        m.addItem(.separator())
        add("Dashboard", #selector(showDashboard))
        add("Profile settings…", #selector(showSettings))
        if entry.follows.windowFollowsUsage {
            m.addItem(.separator())
            add("Quit and keep Claude window", #selector(quitKeepingWindow))
        }
        return m
    }

    /// Asks the agent to read this profile now; the panel says "Updating…" until it has.
    @objc func refreshNow() {
        refreshAsked = Date()
        DistributedNotificationCenter.default().postNotificationName(Installer.refreshAllNote, object: accountID, userInfo: nil,
                                                                     deliverImmediately: true)
        redraw()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.5) { [weak self] in self?.redraw() }
    }
    /// Asks the agent to renew this profile's sign-in through Claude Code now.
    @objc func renewLogin() {
        DistributedNotificationCenter.default().postNotificationName(Agent.renewNote, object: accountID, userInfo: nil,
                                                                     deliverImmediately: true)
    }
    @objc func showSettings() { Installer.openSettings(account: accountID) }
    @objc func showDashboard() { details.close(); Installer.openDashboard() }
    @objc func logIn() {
        guard let claude = ClaudeCLI.find() else { NSSound.beep(); return }
        ClaudeCLI.openLogin(claude, account: account, email: expectedEmail)
    }
}

extension Login {
    var isDenied: Bool { if case .denied = self { return true }; return false }
}

