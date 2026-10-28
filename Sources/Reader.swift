// Reader: one profile's usage, read by the cl_audit agent (Agent.swift), which keeps one reader per profile.
//
// The sign-in is kept in memory and the Keychain is read only when it's needed: at the start, when the kept sign-in
// has expired or was refused (then at most every 10 minutes), or on Refresh now. Reads go through /usr/bin/security,
// the way Claude Code reads it, so they don't prompt (Login.read in Model.swift). The usage comes from Anthropic's
// usage endpoint, with the status line file as a fallback; the account check from its profile endpoint.
// What a reader sees is saved to status/<id>.json (no secrets) for the Dock icons and the cl_audit window.

import AppKit
import UserNotifications

final class UsageReader {
    private(set) var entry: AccountEntry
    private(set) var account: Account
    private let defaults: UserDefaults           // the agent's: alert marks and renewal times, per profile id

    private(set) var usage: Usage?
    private(set) var state: FetchState = .idle
    private var plan: String?
    private var loginEmail: String?
    private var profileFor: String?              // short hash of the token the e-mail was looked up for
    private var renewNote: String?
    private var renewing = false
    private var cachedLogin: Login?
    private var lastLoginRead = Date.distantPast
    private var loginRejected = false
    private var forceLoginRead = false
    private var nextFetch: Date
    private var backoff: TimeInterval = 0
    private var inFlight = false
    private var lastStatus: Data?
    private var stopped = false                  // its profile was removed: nothing more is saved
    private var alerting: Set<String> = []       // alerts being handed to macOS
    private var lastAsked = Date.distantPast     // when a fetch last started
    private var resetRead: DispatchWorkItem?     // reads again the moment a full limit resets

    /// At most one automatic renewal per this many seconds, even across restarts.
    static let renewSpacing: TimeInterval = 30 * 60

    var id: String { entry.id }
    private var pollMinutes: Int { max(entry.pollMinutes, 1) }
    private var expectedEmail: String? { account.expectedEmail() }
    /// Anthropic didn't answer the last time (an error or "busy"): for the main display.
    var failing: Bool {
        if case .failed = state { return true }
        return state == .rateLimited
    }

    /// `startIn`: seconds until the first fetch, so profiles don't all ask at once.
    init(_ e: AccountEntry, defaults: UserDefaults, startIn: TimeInterval = 0) {
        entry = e
        account = Account(e)
        self.defaults = defaults
        nextFetch = Date().addingTimeInterval(startIn)
        // carry on from what was saved last (the numbers don't blank while the agent restarts)
        if let s = Store.status(e.id), let at = s.updatedAt, s.fiveHour != nil || s.weekly != nil {
            usage = Usage(fiveHour: s.fiveHour, fiveHourResets: s.fiveHourResets, weekly: s.weekly,
                          weeklyResets: s.weeklyResets, fetchedAt: at, source: s.source ?? "Anthropic")
            loginEmail = s.loginEmail
            plan = s.plan
            renewNote = s.renewNote
        }
        Self.adoptOldMarks(e.id, into: defaults)
        scheduleResetRead()
    }

    /// The profile's settings changed: a new folder or interval reads again at once.
    func update(_ e: AccountEntry) {
        guard e != entry, !stopped else { return }
        let refetch = e.configDir != entry.configDir || e.pollMinutes != entry.pollMinutes
        entry = e
        account = Account(e)
        if refetch { loginEmail = nil; profileFor = nil; nextFetch = .distantPast; cachedLogin = nil; tick() }
        if entry.autoRenew && state == .expired { maybeRenew() }
        save()
    }

    /// The profile was removed: a read or renewal still under way saves nothing.
    func stop() { stopped = true; resetRead?.cancel() }

    /// Every 30 s: the status line file if it's newer, a fetch when it's due, and the saved status. A full limit whose
    /// reset has passed is read again at once (then at most once a minute until Anthropic's numbers move on).
    func tick() {
        guard !stopped else { return }
        if let local = UsageParser.fromStatusLine(account), local.fetchedAt > (usage?.fetchedAt ?? .distantPast) {
            usage = local
        }
        if let u = usage, Self.resetPassed(u), !failing, Date().timeIntervalSince(lastAsked) >= 60 { nextFetch = .distantPast }
        if Date() >= nextFetch { fetch() }
        save()
    }

    /// A limit read as full whose reset time has passed: the numbers are out of date.
    static func resetPassed(_ u: Usage, now: Date = Date()) -> Bool {
        (AtLimit.isFull(u.fiveHour) && (u.fiveHourResets.map { $0 <= now } ?? false))
            || (AtLimit.isFull(u.weekly) && (u.weeklyResets.map { $0 <= now } ?? false))
    }

    /// While a limit is full, a read the moment it resets (2 s after), so the cards, the Dock icon and the "back"
    /// alert follow at once rather than at the next scheduled read.
    private func scheduleResetRead() {
        resetRead?.cancel(); resetRead = nil
        guard let u = usage, !stopped else { return }
        let now = Date()
        guard let at = Self.resetReadAt(u, now: now) else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.nextFetch = .distantPast
            self.tick()
        }
        resetRead = item
        DispatchQueue.main.asyncAfter(deadline: .now() + at.timeIntervalSince(now), execute: item)
    }

    /// When to read again for a full limit's reset: 2 s after the first full limit resets, or nil.
    static func resetReadAt(_ u: Usage, now: Date = Date()) -> Date? {
        [(u.fiveHour, u.fiveHourResets), (u.weekly, u.weeklyResets)]
            .compactMap { AtLimit.isFull($0.0) ? $0.1 : nil }.filter { $0 > now }.min()?.addingTimeInterval(2)
    }

    /// Refresh now (a Dock icon, the dashboard): fetch now and read the sign-in again.
    func refreshNow() { nextFetch = .distantPast; forceLoginRead = true; tick() }

    // MARK: fetching

    private func fetch() {
        guard !inFlight else { return }
        lastAsked = Date()
        nextFetch = Date().addingTimeInterval(TimeInterval(pollMinutes * 60) + backoff)
        inFlight = true
        // the Keychain is read off the main thread (a locked Keychain can keep /usr/bin/security waiting), so one
        // profile never holds up the others or the agent's rules
        if needsLoginRead() {
            let acct = account
            DispatchQueue.global(qos: .utility).async {
                let login = Login.read(acct)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.cachedLogin = login
                    self.lastLoginRead = Date()
                    self.loginRejected = false
                    self.forceLoginRead = false
                    self.ask(with: login)
                }
            }
        } else {
            ask(with: cachedLogin ?? .notFound)
        }
    }

    private func ask(with login: Login) {
        guard !stopped else { inFlight = false; return }
        guard case let .token(token, expiresAt, plan) = login else {
            inFlight = false
            state = login.isDenied ? .denied : .noLogin
            save(); return
        }
        self.plan = plan
        if let expiresAt, expiresAt < Date() { inFlight = false; state = .expired; save(); maybeRenew(); return }
        if profileFor != Account.sha8(token) { lookUpEmail(token) }
        URLSession.shared.dataTask(with: Self.request("usage", token: token)) { [weak self] data, resp, err in
            DispatchQueue.main.async { self?.finish(data: data, response: resp as? HTTPURLResponse, error: err) }
        }.resume()
    }

    /// The kept sign-in is read again only when needed: none yet, Refresh now, or expired/refused (then at most
    /// every 10 minutes).
    private func needsLoginRead() -> Bool {
        var usable = false
        if case let .token(_, expiresAt, _)? = cachedLogin {
            usable = !loginRejected && (expiresAt ?? .distantFuture) > Date().addingTimeInterval(60)
        }
        let wait: TimeInterval = cachedLogin == nil ? 0 : 10 * 60
        return forceLoginRead || (!usable && Date().timeIntervalSince(lastLoginRead) >= wait)
    }

    static func request(_ path: String, token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/\(path)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("usage-dock/0.1", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        return req
    }

    private func lookUpEmail(_ token: String) {
        let key = Account.sha8(token)
        URLSession.shared.dataTask(with: Self.request("profile", token: token)) { [weak self] data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let email = ok ? data.flatMap(UsageParser.email) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                if let email { self.loginEmail = email; self.profileFor = key }
                self.save()
            }
        }.resume()
    }

    private func finish(data: Data?, response: HTTPURLResponse?, error: Error?) {
        inFlight = false
        guard !stopped else { return }
        defer { save() }
        if let error { state = .failed(error.localizedDescription); return }
        switch response?.statusCode ?? 0 {
        case 200:
            guard let data, let u = UsageParser.fromAPI(data) else { state = .failed("unexpected reply"); return }
            apply(u)
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

    /// A good reading: keep it, send what alerts it calls for, and plan the read at the next reset (saving is the
    /// caller's).
    func apply(_ u: Usage) {
        usage = u; state = .ok; backoff = 0
        noteBack(u)
        checkThresholds(u)
        scheduleResetRead()
    }

    // MARK: renewing an expired sign-in

    private var renewKey: String { "lastRenewAttempt.\(id)" }

    private func maybeRenew() {
        guard entry.autoRenew, !renewing else { return }
        if let last = defaults.object(forKey: renewKey) as? Date, Date().timeIntervalSince(last) < Self.renewSpacing { return }
        renewLogin()
    }

    /// Runs Claude Code once for this profile's folder so it swaps its access key (see ClaudeCLI.renew). Finding
    /// Claude Code and running it happen off the main thread.
    func renewLogin() {
        guard !renewing, !stopped else { return }
        renewing = true
        defaults.set(Date(), forKey: renewKey)
        renewNote = "Renewing the login through Claude Code…"
        save()
        let acct = account
        DispatchQueue.global(qos: .utility).async {
            let claude = ClaudeCLI.find()
            let ok = claude.map { ClaudeCLI.renew($0, account: acct) } ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.renewing = false
                self.renewNote = claude == nil ? "Couldn't renew: Claude Code isn't installed"
                    : ok ? "Login renewed at \(Self.when(Date()))" : "Couldn't renew the login: run Claude Code for this profile once"
                self.nextFetch = .distantPast
                self.forceLoginRead = true
                self.tick()
            }
        }
    }

    // MARK: alerts

    /// One alert per limit and reset, from cl_audit (the agent), at the profile's level, and one when the limit is
    /// full, saying when it's back ("Back at 15:28, in 1h 42m"). No e-mail addresses. The reset is marked as alerted
    /// only once macOS took the alert, so one that couldn't be shown (alerts not allowed yet) comes when they are.
    private func checkThresholds(_ u: Usage) {
        guard entry.notify else { return }
        let limit = Double(entry.notifyPercent)
        for (key, title, p, resets) in [("5h", "5-hour limit", u.fiveHour, u.fiveHourResets),
                                        ("wk", "Weekly limit", u.weekly, u.weeklyResets)] {
            guard let p else { continue }
            let full = AtLimit.isFull(p)
            guard full || p >= limit else { continue }
            let stamp = resets.map { Int($0.timeIntervalSince1970.rounded()) }
            // no reset time: at most one a day
            let mark = stamp.map(String.init) ?? "day-\(Int(Date().timeIntervalSince1970 / 86400))"
            // the level alert's mark (n5h), and the full one's (f5h): a limit that is full also counts as alerted
            // for its level
            let k = "\(full ? "f" : "n")\(key).\(id)", levelKey = "n\(key).\(id)"
            // one alert per reset: Anthropic's reset time wobbles by a fraction of a second between replies, so
            // marks within 10 minutes of each other are the same reset (windows are hours apart)
            if let old = defaults.string(forKey: k), old == mark || Self.sameReset(old, stamp) { continue }
            guard !alerting.contains(k) else { continue }
            alerting.insert(k)
            let c = UNMutableNotificationContent()
            if full {
                c.title = "Claude \(account.name): \(title.prefix(1).lowercased() + title.dropFirst()) full"
                c.body = resets.map { "Back \(Self.backWords($0)), in \(TimeWords.countdown($0))" } ?? "Reset time unknown"
            } else {
                c.title = "Claude \(account.name): \(title) at \(Int(p.rounded()))%"
                if let resets { c.body = "Resets \(Self.when(resets))" }
            }
            c.threadIdentifier = id
            let me = id, d = defaults, kind = full ? "f" : "n"
            // sent by cl_audit's own program, so the alert comes from cl_audit in /Applications (the app System
            // Settings ▸ Notifications lists), not from this helper inside it
            DispatchQueue.global(qos: .utility).async {
                let code = Self.post(id: "\(me).\(kind)\(key).\(mark)", title: c.title, body: c.body, thread: me)
                DispatchQueue.main.async { [weak self] in
                    self?.alerting.remove(k)
                    if code == 0, self?.stopped != true { d.set(mark, forKey: k); if full { d.set(mark, forKey: levelKey) } }
                }
                switch code {
                case 0: agentLog.log("\(me, privacy: .public): alert sent: \(title, privacy: .public) \(full ? "full" : "at \(Int(p.rounded()))%", privacy: .public)")
                case 2: agentLog.log("\(me, privacy: .public): alert waits: notifications for cl_audit aren't allowed")
                default: agentLog.error("\(me, privacy: .public): alert not sent (\(code))")
                }
            }
        }
    }

    /// "at 15:28" today, else "Thu 09:00", "11 Nov" (after "Back").
    static func backWords(_ d: Date, now: Date = Date()) -> String {
        String(TimeWords.back(d, now: now).dropFirst("back ".count))
    }

    /// Notify when back: a limit read as full is remembered (full5h.<id>: its reset time, or "?"). When it no longer is
    /// and no other limit still holds the profile back, one alert: "Claude Work is back · The 5-hour limit reset at
    /// 15:28". Remembered whatever the switch says; sent only with it on, and tried once (a late "back" is no use).
    private func noteBack(_ u: Usage, now: Date = Date()) {
        let five = AtLimit.isFull(u.fiveHour), week = AtLimit.isFull(u.weekly)
        var back: [(name: String, mark: String)] = []
        for (key, name, full, resets) in [("5h", "5-hour", five, u.fiveHourResets), ("wk", "weekly", week, u.weeklyResets)] {
            let k = "full\(key).\(id)"
            if full {
                let v = resets.map { String(Int($0.timeIntervalSince1970.rounded())) } ?? "?"
                if defaults.string(forKey: k) != v { defaults.set(v, forKey: k) }
            } else if let was = defaults.string(forKey: k) {
                defaults.removeObject(forKey: k)
                back.append((name, was))
            }
        }
        // the other limit still full: the profile isn't back yet (that one's reset sends it)
        guard !back.isEmpty, !five, !week, entry.notifyBack, !alerting.contains("back.\(id)") else { return }
        let title = "Claude \(account.name) is back"
        let body: String
        if back.count == 2 {
            body = "The 5-hour and weekly limits reset"
        } else if let t = Int(back[0].mark).map({ Date(timeIntervalSince1970: TimeInterval($0)) }) {
            body = "The \(back[0].name) limit reset at \(TimeWords.when(t, now: now))"
        } else {
            body = "The \(back[0].name) limit has room again"
        }
        let me = id, k = "back.\(id)", stamp = back.map(\.mark).joined(separator: "-")
        alerting.insert(k)
        DispatchQueue.global(qos: .utility).async {
            let code = Self.post(id: "\(me).back.\(stamp)", title: title, body: body, thread: me)
            DispatchQueue.main.async { [weak self] in self?.alerting.remove(k) }
            switch code {
            case 0: agentLog.log("\(me, privacy: .public): back alert sent")
            case 2: agentLog.log("\(me, privacy: .public): back alert dropped: notifications for cl_audit aren't allowed")
            default: agentLog.error("\(me, privacy: .public): back alert not sent (\(code))")
            }
        }
    }

    /// Tests only: takes the alerts instead of macOS (id, title, body, thread).
    static var testPoster: ((String, String, String, String) -> Int32)?

    /// Hands one alert to cl_audit's own program (UsageDock --post-alert). 0 sent, 2 not allowed, else failed.
    static func post(id: String, title: String, body: String, thread: String) -> Int32 {
        if let t = testPoster { return t(id, title, body, thread) }
        guard let app = LegacyCleanup.agentParentApp() else { return 1 }
        let p = Process()
        p.executableURL = app.appendingPathComponent("Contents/MacOS/UsageDock")
        p.arguments = ["--post-alert", id, title, body, thread]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return 1 }
        let deadline = Date().addingTimeInterval(20)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return 1 }
        return p.terminationStatus
    }

    static func sameReset(_ old: String, _ stamp: Int?) -> Bool {
        guard let a = Int(old), let b = stamp else { return false }
        return abs(a - b) < 600
    }

    /// The marks the profile's own Dock icon app kept before the agent read usage (its last alert per limit, its last
    /// renewal), so an alert already shown isn't shown again.
    static func adoptOldMarks(_ id: String, into d: UserDefaults) {
        guard d.object(forKey: "adopted.\(id)") == nil else { return }
        d.set(true, forKey: "adopted.\(id)")
        guard let old = UserDefaults(suiteName: "\(Installer.managerID).\(id)") else { return }
        for key in ["n5h", "nwk"] where d.string(forKey: "\(key).\(id)") == nil {
            if let m = old.string(forKey: key) { d.set(m, forKey: "\(key).\(id)") }
        }
        if d.object(forKey: "lastRenewAttempt.\(id)") == nil, let t = old.object(forKey: "lastRenewAttempt") as? Date {
            d.set(t, forKey: "lastRenewAttempt.\(id)")
        }
    }

    /// Everything the agent keeps for a removed profile.
    static func forget(_ id: String, in d: UserDefaults) {
        for k in ["n5h", "nwk", "f5h", "fwk", "full5h", "fullwk", "lastRenewAttempt", "adopted", "loginItemForgotten", "dockPlace"] {
            d.removeObject(forKey: "\(k).\(id)")
        }
    }

    // MARK: saved status

    /// Writes status/<id>.json when what this reader sees changed (the write posts the "changed" notice).
    func save() {
        guard !stopped else { return }
        let status = IconStatus(loginEmail: loginEmail, expectedEmail: expectedEmail, state: "\(state)",
                                fiveHour: usage?.fiveHour, weekly: usage?.weekly, updatedAt: usage?.fetchedAt,
                                renewNote: renewNote, fiveHourResets: usage?.fiveHourResets,
                                weeklyResets: usage?.weeklyResets, plan: plan,
                                source: usage?.source, problem: state.menuText, renewing: renewing)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(status), data != lastStatus { lastStatus = Store.writeStatus(id, status) }
    }

    static func when(_ d: Date) -> String { TimeWords.when(d) }
}
