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
    }

    /// The profile's settings changed: a new folder or interval reads again at once.
    func update(_ e: AccountEntry) {
        guard e != entry else { return }
        let refetch = e.configDir != entry.configDir || e.pollMinutes != entry.pollMinutes
        entry = e
        account = Account(e)
        if refetch { loginEmail = nil; profileFor = nil; nextFetch = .distantPast; cachedLogin = nil; tick() }
        if entry.autoRenew && state == .expired { maybeRenew() }
        save()
    }

    /// Every 30 s: the status line file if it's newer, a fetch when it's due, and the saved status.
    func tick() {
        if let local = UsageParser.fromStatusLine(account), local.fetchedAt > (usage?.fetchedAt ?? .distantPast) {
            usage = local
        }
        if Date() >= nextFetch { fetch() }
        save()
    }

    /// Refresh now (a Dock icon, the dashboard): fetch now and read the sign-in again.
    func refreshNow() { nextFetch = .distantPast; forceLoginRead = true; tick() }

    // MARK: fetching

    private func fetch() {
        guard !inFlight else { return }
        nextFetch = Date().addingTimeInterval(TimeInterval(pollMinutes * 60) + backoff)
        let login = currentLogin()
        guard case let .token(token, expiresAt, plan) = login else {
            state = login.isDenied ? .denied : .noLogin
            save(); return
        }
        self.plan = plan
        if let expiresAt, expiresAt < Date() { state = .expired; save(); maybeRenew(); return }
        if profileFor != Account.sha8(token) { lookUpEmail(token) }

        inFlight = true
        URLSession.shared.dataTask(with: Self.request("usage", token: token)) { [weak self] data, resp, err in
            DispatchQueue.main.async { self?.finish(data: data, response: resp as? HTTPURLResponse, error: err) }
        }.resume()
    }

    private func currentLogin() -> Login {
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
        defer { save() }
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

    // MARK: renewing an expired sign-in

    private var renewKey: String { "lastRenewAttempt.\(id)" }

    private func maybeRenew() {
        guard entry.autoRenew, !renewing else { return }
        if let last = defaults.object(forKey: renewKey) as? Date, Date().timeIntervalSince(last) < Self.renewSpacing { return }
        renewLogin()
    }

    /// Runs Claude Code once for this profile's folder so it swaps its access key (see ClaudeCLI.renew).
    func renewLogin() {
        guard !renewing else { return }
        guard let claude = ClaudeCLI.find() else {
            renewNote = "Couldn't renew: Claude Code isn't installed"; save(); return
        }
        renewing = true
        defaults.set(Date(), forKey: renewKey)
        renewNote = "Renewing the login through Claude Code…"
        save()
        let acct = account
        DispatchQueue.global(qos: .utility).async {
            let ok = ClaudeCLI.renew(claude, account: acct)
            DispatchQueue.main.async {
                self.renewing = false
                self.renewNote = ok ? "Login renewed at \(Self.when(Date()))" : "Couldn't renew the login: run Claude Code for this profile once"
                self.nextFetch = .distantPast
                self.forceLoginRead = true
                self.tick()
            }
        }
    }

    // MARK: alerts

    /// One alert per limit and reset, from cl_audit (the agent), at the profile's level. No e-mail addresses.
    private func checkThresholds(_ u: Usage) {
        guard entry.notify else { return }
        let limit = Double(entry.notifyPercent)
        for (key, title, p, resets) in [("n5h", "5-hour limit", u.fiveHour, u.fiveHourResets),
                                        ("nwk", "Weekly limit", u.weekly, u.weeklyResets)] {
            guard let p, p >= limit else { continue }
            let stamp = resets.map { Int($0.timeIntervalSince1970.rounded()) }
            let mark = stamp.map(String.init) ?? "unknown"
            let k = "\(key).\(id)"
            // one alert per reset: Anthropic's reset time wobbles by a fraction of a second between replies, so
            // marks within 10 minutes of each other are the same reset (windows are hours apart)
            if let old = defaults.string(forKey: k), old == mark || Self.sameReset(old, stamp) { continue }
            defaults.set(mark, forKey: k)
            let c = UNMutableNotificationContent()
            c.title = "Claude \(account.name): \(title) at \(Int(p.rounded()))%"
            if let resets { c.body = "Resets \(Self.when(resets))" }
            c.threadIdentifier = id
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(id).\(key).\(mark)", content: c, trigger: nil)) { err in
                if let err { agentLog.error("\(self.id, privacy: .public): alert not sent: \(err.localizedDescription, privacy: .public)") }
                else { agentLog.log("\(self.id, privacy: .public): alert sent: \(title, privacy: .public) at \(Int(p.rounded()))%") }
            }
        }
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
        for k in ["n5h", "nwk", "lastRenewAttempt", "adopted", "loginItemForgotten", "dockPlace"] { d.removeObject(forKey: "\(k).\(id)") }
    }

    // MARK: saved status

    /// Writes status/<id>.json when what this reader sees changed (the write posts the "changed" notice).
    func save() {
        let status = IconStatus(loginEmail: loginEmail, expectedEmail: expectedEmail, state: "\(state)",
                                fiveHour: usage?.fiveHour, weekly: usage?.weekly, updatedAt: usage?.fetchedAt,
                                renewNote: renewNote, fiveHourResets: usage?.fiveHourResets,
                                weeklyResets: usage?.weeklyResets, plan: plan,
                                source: usage?.source, problem: state.menuText, renewing: renewing)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(status), data != lastStatus { lastStatus = Store.writeStatus(id, status) }
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: Date()) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: d)
    }
}
