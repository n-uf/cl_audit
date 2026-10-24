import AppKit
import CryptoKit
import Security
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
    var lastStatus: Data?
    var renewing = false
    let details = DetailsController()
    lazy var manager = ManagerUI()          // the settings app's launcher palette and main screen
    var lastClick = Date.distantPast
    // The login is kept in memory and the Keychain is read only when it's needed: at the start, when the
    // kept login has expired or was refused (then at most every 10 minutes), or on Refresh now.
    // Reads go through /usr/bin/security like Claude Code's own, so they don't prompt.
    var cachedLogin: Login?
    var lastLoginRead = Date.distantPast
    var loginRejected = false
    var forceLoginRead = false
    var renewNote: String?
    /// At most one automatic renewal per this many seconds, even across restarts.
    let renewSpacing: TimeInterval = 30 * 60
    let defaults = UserDefaults.standard
    let claudeBundleID = "com.anthropic.claudefordesktop"

    var usage: Usage?
    var claudeOpen = false        // this account's Claude window is running (drawn as a dot on the tile)
    var state: FetchState = .idle
    var plan: String?
    var loginEmail: String?
    var profileFor: String?        // short hash of the token the e-mail was looked up for
    var nextFetch = Date.distantPast
    var backoff: TimeInterval = 0
    var inFlight = false
    var tileView: TileView!
    var timer: Timer?

    var style: IconStyle { entry.style }
    var pollMinutes: Int { max(entry.pollMinutes, 1) }

    static func loadEntry(_ id: String) -> AccountEntry {
        Store.load().first { $0.id == id } ?? AccountEntry(id: id, name: id, label: "?", configDir: "~/.claude")
    }

    /// Change this icon's own options and save them to the shared config.
    func change(_ edit: (inout AccountEntry) -> Void) {
        edit(&entry)
        Store.update(entry)
        applyEntry()
    }

    func applyEntry() {
        account = Account(entry)
        applyLoginItem()
        if entry.notify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        redraw()
    }

    @objc func configChanged() {
        let fresh = Self.loadEntry(entry.id)
        guard fresh != entry else { return }
        let refetch = fresh.configDir != entry.configDir || fresh.pollMinutes != entry.pollMinutes
        entry = fresh
        if refetch { loginEmail = nil; profileFor = nil; nextFetch = .distantPast; cachedLogin = nil }
        applyEntry()
        if refetch { tick() }
        if entry.autoRenew && state == .expired { maybeRenew() }
    }

    func applyLoginItem() {
        let svc = SMAppService.mainApp
        // The entry points at the app's location, so an app that moved or was renamed registers again.
        let here = Bundle.main.bundlePath, key = "loginItemPath"
        if entry.openAtLogin, svc.status != .enabled || defaults.string(forKey: key) != here {
            if svc.status == .enabled { try? svc.unregister() }
            if (try? svc.register()) != nil { defaults.set(here, forKey: key) }
        }
        if !entry.openAtLogin, svc.status == .enabled { try? svc.unregister(); defaults.removeObject(forKey: key) }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        if isSettingsApp {
            NSWindow.allowsAutomaticWindowTabbing = false   // Settings and Dashboard are separate windows
            MainMenu.install()
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(showSettingsWindow),
                                                                name: Installer.openSettingsNote, object: nil)
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(showMainScreen),
                                                                name: Installer.openDashboardNote, object: nil)
            if CommandLine.arguments.contains("--settings") {
                let account = CommandLine.arguments.first { $0.hasPrefix("--account=") }.map { String($0.dropFirst("--account=".count)) }
                manager.showMain(page: .settings, account: account)
            } else { manager.showMain() }
            return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(configChanged), name: Store.changed, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(refreshNow), name: Installer.refreshAllNote, object: nil)
        tileView = TileView(model: model())
        NSApp.dockTile.contentView = tileView
        NSApp.dockTile.display()
        usage = UsageParser.fromStatusLine(account)
        redraw()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        tick()
        applyEntry()
    }

    // The settings app stays in the Dock after its windows close: its icon is the launcher.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// An icon app quit because its account was removed takes its open-at-login entry with it.
    func applicationWillTerminate(_ note: Notification) {
        guard !isSettingsApp, let id = accountID, !Store.load().contains(where: { $0.id == id }) else { return }
        try? SMAppService.mainApp.unregister()
    }

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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if isSettingsApp { manager.togglePalette(); return false }
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
        switch entry.clickAction {
        case .details:
            details.toggle(detailsInfo(), detailsActions())
        case .peekThenOpen:
            details.peek(detailsInfo(), seconds: entry.peekSeconds)
            if account.opensDesktop { openClaude() }
        case .open:
            if account.opensDesktop { openClaude() } else { Installer.openSettings(account: accountID) }
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
            problem: state.menuText, renewNote: renewNote,
            canOpenClaude: account.opensDesktop,
            needsLogin: mismatch || state == .noLogin || state == .expired,
            design: entry.panelDesign,
            accent: entry.accentNSColor,
            refreshing: inFlight)
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

    var expectedEmail: String? { account.expectedEmail() }

    /// The login in the Keychain belongs to a different account than this folder is set up for.
    var mismatch: Bool {
        guard let a = loginEmail, let b = expectedEmail else { return false }
        return a.lowercased() != b.lowercased()
    }

    func model() -> TileModel {
        TileModel(label: account.label, fiveHour: usage?.fiveHour, weekly: usage?.weekly,
                  stale: isStale || state == .expired || state == .noLogin, style: style, warn: mismatch,
                  tint: entry.color, frame: entry.frame,
                  fiveHourElapsed: windowElapsed(usage?.fiveHourResets, 5 * 3600),
                  weeklyElapsed: windowElapsed(usage?.weeklyResets, 7 * 86400), windowOpen: claudeOpen && entry.windowDot)
    }

    func redraw() {
        guard !isSettingsApp, tileView != nil else { return }
        if details.isShown { details.update(detailsInfo(), detailsActions()) }   // an open panel follows along
        // What this icon sees, for the settings window (no secrets).
        let status = IconStatus(loginEmail: loginEmail, expectedEmail: expectedEmail, state: "\(state)",
                                fiveHour: usage?.fiveHour, weekly: usage?.weekly, updatedAt: usage?.fetchedAt,
                                renewNote: renewNote, fiveHourResets: usage?.fiveHourResets,
                                weeklyResets: usage?.weeklyResets, plan: plan)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(status), data != lastStatus { lastStatus = Store.writeStatus(entry.id, status) }
        tileView.model = model()
        NSApp.dockTile.display()
    }

    /// Whether this account's Claude window is running; redraws the tile when that changes.
    func refreshWindowState() {
        let open = account.opensDesktop && (Launcher.activity(for: [account])[account.configDir]?.desktopOpen ?? false)
        if open != claudeOpen { claudeOpen = open; redraw() }
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
        if let local = UsageParser.fromStatusLine(account), local.fetchedAt > (usage?.fetchedAt ?? .distantPast) {
            usage = local
        }
        if Date() >= nextFetch { fetch() }
        redraw()
    }

    func fetch() {
        guard !inFlight else { return }
        nextFetch = Date().addingTimeInterval(TimeInterval(pollMinutes * 60) + backoff)
        let login = currentLogin()
        guard case let .token(token, expiresAt, plan) = login else {
            state = login.isDenied ? .denied : .noLogin
            redraw(); return
        }
        self.plan = plan
        if let expiresAt, expiresAt < Date() { state = .expired; redraw(); maybeRenew(); return }
        if profileFor != Account.sha8(token) { lookUpEmail(token) }

        inFlight = true
        URLSession.shared.dataTask(with: request("usage", token: token)) { [weak self] data, resp, err in
            DispatchQueue.main.async { self?.finish(data: data, response: resp as? HTTPURLResponse, error: err) }
        }.resume()
    }

    func currentLogin() -> Login {
        var usable = false
        if case let .token(_, expiresAt, _)? = cachedLogin {
            usable = !loginRejected && (expiresAt ?? .distantFuture) > Date().addingTimeInterval(60)
        }
        let wait: TimeInterval = cachedLogin == nil ? 0 : 10 * 60
        if forceLoginRead || (!usable && Date().timeIntervalSince(lastLoginRead) >= wait) {
            cachedLogin = Login.read(account)
            lastLoginRead = Date()
            loginRejected = false
            forceLoginRead = false
        }
        return cachedLogin ?? .notFound
    }

    func request(_ path: String, token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/\(path)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("usage-dock/0.1", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        return req
    }

    func lookUpEmail(_ token: String) {
        let key = Account.sha8(token)
        URLSession.shared.dataTask(with: request("profile", token: token)) { [weak self] data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let email = ok ? data.flatMap(UsageParser.email) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                if let email { self.loginEmail = email; self.profileFor = key }
                self.redraw()
            }
        }.resume()
    }

    func finish(data: Data?, response: HTTPURLResponse?, error: Error?) {
        inFlight = false
        defer { redraw() }
        if let error { state = .failed(error.localizedDescription); return }
        switch response?.statusCode ?? 0 {
        case 200:
            guard let data, let u = UsageParser.fromAPI(data) else { state = .failed("unexpected reply"); return }
            usage = u; state = .ok; backoff = 0
            checkThresholds(u)
        case 401, 403:
            state = .expired
            loginRejected = true
            maybeRenew()
        case 429:
            state = .rateLimited
            backoff = min(max(backoff * 2, 120), 1800)
            nextFetch = Date().addingTimeInterval(TimeInterval(pollMinutes * 60) + backoff)
        case let code:
            state = .failed("HTTP \(code)")
        }
    }

    // MARK: renewing an expired login

    func maybeRenew() {
        guard entry.autoRenew, !renewing else { return }
        if let last = defaults.object(forKey: "lastRenewAttempt") as? Date,
           Date().timeIntervalSince(last) < renewSpacing { return }
        renewLogin()
    }

    @objc func renewLogin() {
        guard !renewing else { return }
        guard let claude = ClaudeCLI.find() else {
            renewNote = "Couldn't renew: Claude Code isn't installed"; redraw(); return
        }
        renewing = true
        defaults.set(Date(), forKey: "lastRenewAttempt")
        renewNote = "Renewing the login through Claude Code…"
        redraw()
        let acct = account
        DispatchQueue.global(qos: .utility).async {
            let ok = ClaudeCLI.renew(claude, account: acct)
            DispatchQueue.main.async {
                self.renewing = false
                self.renewNote = ok ? "Login renewed at \(Self.when(Date()))" : "Couldn't renew the login: run Claude Code for this account once"
                self.nextFetch = .distantPast
                self.forceLoginRead = true
                self.tick()
            }
        }
    }

    func checkThresholds(_ u: Usage) {
        guard entry.notify else { return }
        let limit = Double(entry.notifyPercent)
        for (key, title, p, resets) in [("n5h", "5-hour limit", u.fiveHour, u.fiveHourResets),
                                        ("nwk", "Weekly limit", u.weekly, u.weeklyResets)] {
            guard let p, p >= limit else { continue }
            let mark = resets.map { "\(Int($0.timeIntervalSince1970))" } ?? "unknown"
            if defaults.string(forKey: key) == mark { continue }
            defaults.set(mark, forKey: key)
            let c = UNMutableNotificationContent()
            c.title = "Claude \(account.name): \(title) at \(Int(p.rounded()))%"
            if let resets { c.body = "Resets \(Self.when(resets))" }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key + mark, content: c, trigger: nil))
        }
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
            let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "")
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
        if let why = state.menuText { m.addItem(info(why)) }
        if let note = renewNote { m.addItem(info(note)) }
        if Privacy.shared.show || loginEmail == nil { m.addItem(info("Login: \(loginEmail ?? "checking…")")) }
        if mismatch, let want = expectedEmail {
            m.addItem(info(Privacy.shared.show ? "⚠︎ This folder is set up for \(want)" : "⚠︎ This folder is set up for a different account"))
        }
        if mismatch || state == .noLogin || state == .expired {
            let login = NSMenuItem(title: "Log in…", action: #selector(logIn), keyEquivalent: "")
            login.target = self; m.addItem(login)
        }
        m.addItem(.separator())

        if account.opensDesktop {
            let open = NSMenuItem(title: "Open Claude (\(account.name))", action: #selector(openClaude), keyEquivalent: "")
            open.target = self; m.addItem(open)
        }
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "")
        refresh.target = self; m.addItem(refresh)
        if state == .expired {
            let renew = NSMenuItem(title: renewing ? "Renewing login…" : "Renew login now (uses a little usage)",
                                   action: #selector(renewLogin), keyEquivalent: "")
            renew.target = self; renew.isEnabled = !renewing; m.addItem(renew)
        }

        let options = NSMenu(); options.autoenablesItems = false
        options.addItem(info("Style"))
        for s in IconStyle.allCases {
            let i = NSMenuItem(title: s.title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = s.rawValue; i.state = s == style ? .on : .off; i.indentationLevel = 1
            options.addItem(i)
        }
        options.addItem(.separator())
        options.addItem(info("Refresh every"))
        for n in [2, 5, 10, 15] {
            let i = NSMenuItem(title: "\(n) minutes", action: #selector(pickPoll(_:)), keyEquivalent: "")
            i.target = self; i.tag = n; i.state = n == pollMinutes ? .on : .off; i.indentationLevel = 1
            options.addItem(i)
        }
        options.addItem(.separator())
        let notify = NSMenuItem(title: "Notify at \(entry.notifyPercent)%", action: #selector(toggleNotify), keyEquivalent: "")
        notify.target = self; notify.state = entry.notify ? .on : .off; options.addItem(notify)
        let auto = NSMenuItem(title: "Renew expired login automatically", action: #selector(toggleRenew), keyEquivalent: "")
        auto.target = self; auto.state = entry.autoRenew ? .on : .off; options.addItem(auto)
        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = entry.openAtLogin ? .on : .off; options.addItem(login)
        let opts = NSMenuItem(title: "Icon options", action: nil, keyEquivalent: "")
        opts.submenu = options; m.addItem(opts)
        let dashboard = NSMenuItem(title: "Dashboard", action: #selector(showDashboard), keyEquivalent: "")
        dashboard.target = self; m.addItem(dashboard)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self; m.addItem(settings)
        return m
    }

    @objc func refreshNow() { nextFetch = .distantPast; forceLoginRead = true; tick() }
    @objc func pickStyle(_ item: NSMenuItem) {
        if let r = item.representedObject as? String, let s = IconStyle(rawValue: r) { change { $0.style = s } }
    }
    @objc func pickPoll(_ item: NSMenuItem) { change { $0.pollMinutes = item.tag }; nextFetch = Date(); tick() }
    @objc func toggleNotify() { change { $0.notify.toggle() } }
    @objc func toggleLogin() { change { $0.openAtLogin.toggle() } }
    @objc func toggleRenew() { change { $0.autoRenew.toggle() }; if state == .expired { maybeRenew() } }
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

