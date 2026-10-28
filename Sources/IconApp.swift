import AppKit
import ServiceManagement
import UserNotifications

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
    var quietQuit = false         // quit without taking the Claude window along (asked by cl_audit or the agent, or "Quit and keep")
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
        let fresh = Store.status(entry.id)
        if fresh?.updatedAt != status?.updatedAt, let at = fresh?.updatedAt {
            dockLog.log("\(self.entry.id, privacy: .public): shows the agent's numbers from \(Int(-at.timeIntervalSinceNow)) s ago")
        }
        status = fresh
        redraw()
    }

    @objc func statusChanged(_ note: Notification) {
        guard (note.object as? String) == accountID else { return }
        loadStatus()
    }

    func applyEntry() {
        account = Account(entry)
        redraw()
    }

    /// Before the agent, each Dock icon app was its own login item; macOS only lets an app remove its own, so each copy
    /// does it when it runs (and the agent runs each copy once with --forget-login-item).
    static func forgetLoginItem() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled || svc.status == .requiresApproval { try? svc.unregister() }
        UserDefaults.standard.removeObject(forKey: "loginItemPath")
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
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        if isSettingsApp {
            NSWindow.allowsAutomaticWindowTabbing = false   // Settings and Dashboard are separate windows
            AppIconPrefs.shared.apply()                    // the chosen app icon (Settings ▸ General ▸ App icon)
            MainMenu.install()
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(showSettingsWindow),
                                                                name: Installer.openSettingsNote, object: nil)
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(showMainScreen),
                                                                name: Installer.openDashboardNote, object: nil)
            // A profile's style, colour or frame changed (here or in its Dock icon's menu): redraw its icon file, now
            // for a stopped Dock icon app, when it quits for a running one.
            DistributedNotificationCenter.default().addObserver(forName: Store.changed, object: nil, queue: .main) { _ in
                Installer.lookMayHaveChanged()
            }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier?.hasPrefix(Installer.managerID + ".") == true else { return }
                Installer.lookMayHaveChanged(after: 5)
            }
            // On start: bring the Dock icon apps up to date (the agent starts the ones that should run).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let list = Store.loadChecked() { Installer.sync(list) }   // never with a bad read: it removes apps
                // the agent: registered or restarted now (an older build too), and watched while cl_audit is open
                AgentStarter.shared.start(reason: "cl_audit opened")
                AgentStarter.shared.watch()
            }
            // alerts come from cl_audit: macOS asks once, here, while the window is open (when a profile has them on)
            if Store.load().contains(where: \.notify) {
                let center = UNUserNotificationCenter.current()
                center.getNotificationSettings { s in
                    guard s.authorizationStatus == .notDetermined else {
                        agentLog.log("cl_audit: alerts \(s.authorizationStatus == .authorized ? "allowed" : "not allowed (System Settings ▸ Notifications ▸ cl_audit)", privacy: .public)")
                        return
                    }
                    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        agentLog.log("cl_audit: alerts \(granted ? "allowed" : "not allowed", privacy: .public)")
                    }
                }
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
        // logging out or shutting down quits every app: not a reason for its window to quit (macOS reopens it)
        ws.addObserver(self, selector: #selector(quietQuitAsked(_:)), name: NSWorkspace.willPowerOffNotification, object: nil)
        status = Store.status(entry.id)
        tileView = TileView(model: model())
        NSApp.dockTile.contentView = tileView
        NSApp.dockTile.display()
        redraw()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        tick()
        applyEntry()
        // cl_audit itself was moved to the Trash (or is gone) and its agent isn't running: offer to remove what
        // belongs to it, after a moment and a second look (an update replaces cl_audit for a few seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard !Agent.isAlive(Agent.readMark()) else { return }
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Installer.managerID)
            let gone = url.map { Uninstall.inTrash($0.path) } ?? ([Installer.appsFolder, URL(fileURLWithPath: expand("~/Applications"))]
                .allSatisfy { !FileManager.default.fileExists(atPath: $0.appendingPathComponent("cl_audit.app").path) })
            if gone { Uninstall.offerTrashCleanup(defaults: .standard, where: url?.path ?? "gone") }
        }
        // Usage in the Dock off: no Dock icon for this profile (opened from Finder, say). Its settings say how to
        // bring it back; this copy quits, its window left alone.
        if !entry.runs.dockIcon {
            Installer.openSettings(account: accountID)
            quietQuit = true
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc func quietQuitAsked(_ note: Notification) { quietQuit = true }

    // The settings app stays in the Dock after its windows close: its icon is the launcher.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A normal quit tells the agent, which quits the Claude window too when it follows the Dock icon (Claude can ask
    /// about unsent work). Not when cl_audit or the agent asked for it (a reinstall, Usage in the Dock off, its window
    /// quit) or with "Quit and keep Claude window".
    func applicationWillTerminate(_ note: Notification) {
        guard !isSettingsApp, let id = accountID else { return }
        guard Store.load().contains(where: { $0.id == id }) else { Self.forgetLoginItem(); return }
        if !quietQuit {
            DistributedNotificationCenter.default().postNotificationName(Installer.iconQuitNote, object: id, userInfo: nil,
                                                                         deliverImmediately: true)
        }
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
    /// Settings ▸ General with the Uninstall sheet.
    @objc func showUninstall() {
        manager.showMain(page: .settings)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { UninstallUI.shared.show = true }
    }
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
                  weeklyElapsed: windowElapsed(usage?.weeklyResets, 7 * 86400), windowOpen: claudeOpen && entry.windowDot,
                  countdown: AtLimit.tileCountdown(fiveHour: usage?.fiveHour, fiveHourResets: usage?.fiveHourResets,
                                                   weekly: usage?.weekly, weeklyResets: usage?.weeklyResets))
    }

    func redraw() {
        guard !isSettingsApp, tileView != nil else { return }
        if details.isShown { details.update(detailsInfo(), detailsActions()) }   // an open panel follows along
        tileView.model = model()
        NSApp.dockTile.display()
    }

    /// Whether this account's Claude window is running, for the open dot; redraws the tile when that changes.
    /// (Starting and quitting with the window is the agent's.)
    func refreshWindowState() {
        let open = windowIsOpen()
        if open != claudeOpen { claudeOpen = open; redraw() }
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
        loadStatus()                  // also redraws: the staleness and the agent's state change with time
    }

    // MARK: opening Claude

    @objc func openClaude() { Launcher.openClaude(account) }

    // MARK: menu

    static func when(_ d: Date) -> String { TimeWords.when(d) }

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
        // while a limit is full, both times first: "5-hour full · back at 15:28, in 1h 42m"
        if let full = AtLimit.blocker(fiveHour: usage?.fiveHour, fiveHourResets: usage?.fiveHourResets,
                                      weekly: usage?.weekly, weeklyResets: usage?.weeklyResets) {
            let i = info("\(full.title) · \(full.both())")
            i.attributedTitle = NSAttributedString(string: i.title, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), .foregroundColor: NSColor.systemRed])
            m.addItem(i)
        }
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
        if entry.runs.windowFollowsDock {
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

