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
    // Claude Code signed in to another account in this folder: .claude.json names another seat
    private var signIn = SignInWatch()
    private var signInChangedAt: Date?           // when the account changed: older numbers and status lines are the old one's
    private var signInRetries = 0                // reads again when the new sign-in hasn't reached the Keychain yet
    private var planName: String?                // Claude's own name for the plan ("Ultra"), from that same .claude.json

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
        account = Account(e.readingEntry())       // the account's own folder once it has one (Accounts.swift)
        self.defaults = defaults
        nextFetch = Date().addingTimeInterval(startIn)
        adoptSaved()                             // the numbers don't blank while the agent restarts
        Self.adoptOldMarks(e.id, into: defaults)
        _ = signInChanged()                      // the first look: what the folder is signed in to now
        scheduleResetRead()
    }

    /// Carry on from what was saved last, if it was read for the profile's account (after a switch: the new account's
    /// numbers, which FolderRules.moveNumbers moved into this status file in SwitchRunner.linked(), before the profile
    /// was saved). A saved status that names no account is taken only by a profile not linked to one.
    private func adoptSaved() {
        guard let saved = Store.status(entry.id), entry.seat == nil || saved.readFor != nil,
              let s = Optional(saved.only(for: entry.seat?.email)), let at = s.updatedAt, s.fiveHour != nil || s.weekly != nil else { return }
        usage = Usage(fiveHour: s.fiveHour, fiveHourResets: s.fiveHourResets, weekly: s.weekly,
                      weeklyResets: s.weeklyResets, fetchedAt: at, source: s.source ?? "Anthropic",
                      scoped: s.scoped ?? [], credits: s.credits, noFiveHour: s.noFiveHour ?? false)
        loginEmail = s.loginEmail
        plan = s.plan
        renewNote = s.renewNote
    }

    /// The profile's settings changed: another account (a switch), another folder to read, or another interval reads
    /// again at once.
    func update(_ e: AccountEntry) {
        guard e != entry, !stopped else { return }
        let seatChanged = !(e.seat.map { $0.same(entry.seat) } ?? (entry.seat == nil))
        let pollChanged = e.pollMinutes != entry.pollMinutes
        entry = e
        if seatChanged {
            let want = Account(e.readingEntry())
            let readsNewAlready = want.configDir == account.configDir && (e.seat.map { $0.same(signIn.seen) } ?? false)
            account = want
            if !readsNewAlready {
                // the profile works on another account, read from another folder (a switch): the old one's numbers,
                // sign-in and marks go (no "is back" from the switch itself, and its numbers never saved over the new
                // one's, which FolderRules.moveNumbers put in this status file before the profile was saved); the new
                // one's carry on from those
                startOver()
                signIn = SignInWatch(); _ = signInChanged()
                adoptSaved()
                agentLog.log("reader \(self.id, privacy: .public): the profile works on another account; reading it")
            }
            // else: linked to the account this folder is signed in to (Use this account): its numbers, read since that
            // sign-in, are this account's and show now
            tick()
            return
        }
        if followReadingFolder() || pollChanged { nextFetch = .distantPast; tick(); return }
        if renewsByItself && state == .expired { maybeRenew() }
        save()
    }

    /// Reading the account's own folder (always renewed, as a standby account's), or the profile's choice (Renew
    /// sign-in). From the folder read now, not the file: it's what a renewal would run in.
    private var renewsByItself: Bool { entry.autoRenew || account.configDir != Account(entry).configDir }

    /// Bumped when the folder or the account read changes: a reply asked for before is dropped.
    private(set) var generation = 0

    /// The Claude Code folder read now (the account's own, or the working folder).
    var folderRead: String { account.configDir }

    /// Another folder to read, the same account: its own sign-in; replies under way for the old folder are dropped.
    private func readAnotherFolder(now: Date = Date()) {
        loginEmail = nil; profileFor = nil; nextFetch = .distantPast; cachedLogin = nil
        generation += 1
        signInChangedAt = now
        signIn = SignInWatch(); _ = signInChanged()
    }

    /// The account's own folder got signed in (or stopped being): read from there from now on. True when it moved.
    @discardableResult
    private func followReadingFolder() -> Bool {
        let want = Account(entry.readingEntry())
        guard want.configDir != account.configDir else { return false }
        agentLog.log("reader \(self.id, privacy: .public): reading from \(want.configDir == Account(self.entry).configDir ? "the working folder" : "the account's own folder", privacy: .public)")
        account = want
        readAnotherFolder()
        return true
    }

    /// The profile was removed: a read or renewal still under way saves nothing.
    func stop() { stopped = true; resetRead?.cancel() }

    /// Every 30 s: the status line file if it's newer, a fetch when it's due, and the saved status. A full limit whose
    /// reset has passed is read again at once (then at most once a minute until Anthropic's numbers move on).
    func tick() {
        guard !stopped else { return }
        if entry.keptFolder != nil { followReadingFolder() }
        if signInChanged() { startOver() }
        if var local = UsageParser.fromStatusLine(account), local.fetchedAt > (usage?.fetchedAt ?? .distantPast),
           local.fetchedAt > (signInChangedAt ?? .distantPast) {
            // the status line has only the two limits: the model limits and credits stay as Anthropic last gave them
            local.scoped = usage?.scoped ?? []; local.credits = usage?.credits
            local.noFiveHour = usage?.noFiveHour ?? false
            if local.noFiveHour { local.fiveHour = nil; local.fiveHourResets = nil }
            usage = local
        }
        if let u = usage, Self.resetPassed(u), !failing, Date().timeIntervalSince(lastAsked) >= 60 { nextFetch = .distantPast }
        // the folder read (a standby account's kept folder, the account in use's, or the profile's own) isn't there any
        // more: no read of its sign-in at all (FolderGuard), whatever was made while it existed
        if Date() >= nextFetch, FolderGuard.folderReady(account.configDir) { fetch() }
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

    // MARK: another account signed in

    /// The last answer the resolver gave (its time kept while nothing else changed, so the record isn't rewritten).
    private var lastResolved: ResolvedAccount?

    /// The folder read is signed in to another account than the one the profile is linked to: its numbers show, labelled
    /// with that account (AccountResolver), but no alerts go out about them in this profile's name and no renewal runs.
    private var onOtherAccount: Bool {
        guard let linked = entry.seat, let seen = signIn.seen else { return false }
        return !seen.same(linked)
    }

    /// Whether Claude Code was signed in to another account in this folder since the last look.
    private func signInChanged() -> Bool {
        let dir = account.configDir
        return signIn.look(stamp: SignInWatch.stamp(configDir: dir)) {
            planName = Account.planName(configDir: dir)       // read with it: no extra reads
            return Account.signedInSeat(configDir: dir)
        }
    }

    /// Another account is signed in: the kept sign-in, the numbers and the alert marks are the old account's. Drop
    /// them and read the new sign-in now (one Keychain read, as at the start), so no stale numbers and no "Wrong
    /// account" until Refresh now.
    private func startOver(now: Date = Date()) {
        agentLog.log("reader \(self.id, privacy: .public): Claude Code is signed in to another account; reading the new sign-in")
        cachedLogin = nil; forceLoginRead = true; loginRejected = false
        loginEmail = nil; profileFor = nil; plan = nil; renewNote = nil
        usage = nil; state = .idle; backoff = 0
        signInChangedAt = now; signInRetries = 0
        generation += 1                           // replies under way are the old account's
        resetRead?.cancel(); resetRead = nil
        Self.forgetLimitMarks(id, in: defaults)   // no "is back" or "full" alert from the switch itself
        nextFetch = .distantPast
    }

    /// Right after a change, the Keychain can still hold the old sign-in for a moment (Claude Code writes the two at
    /// different times): when the sign-in read names another account than .claude.json, read it again a few times.
    private func checkNewSignIn(_ email: String) {
        guard let at = signInChangedAt, Date().timeIntervalSince(at) < 5 * 60, signInRetries < 4,
              let expected = expectedEmail, expected.lowercased() != email.lowercased() else { return }
        signInRetries += 1
        forceLoginRead = true
        nextFetch = Date().addingTimeInterval(TimeInterval(15 * signInRetries))
        agentLog.log("reader \(self.id, privacy: .public): the Keychain still has the old sign-in; reading it again soon")
    }

    // MARK: fetching

    private func fetch() {
        guard !inFlight else { return }
        lastAsked = Date()
        nextFetch = Date().addingTimeInterval(TimeInterval(pollMinutes * 60) + backoff)
        inFlight = true
        let gen = generation
        // the Keychain is read off the main thread (a locked Keychain can keep /usr/bin/security waiting), so one
        // profile never holds up the others or the agent's rules
        if needsLoginRead() {
            let acct = account
            // the folder's sign-in record as it was before the read: a change after it is read again (watchSignIn)
            let stamp = SignInWatch.stamp(configDir: acct.configDir)
            DispatchQueue.global(qos: .utility).async {
                let login = Login.read(acct)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // read for a folder or account it no longer reads: dropped, read again
                    guard gen == self.generation else { self.inFlight = false; self.nextFetch = .distantPast; self.tick(); return }
                    self.cachedLogin = login
                    self.loginStamp = stamp
                    self.lastLoginRead = Date()
                    self.loginRejected = false
                    self.forceLoginRead = false
                    self.ask(with: login, gen: gen)
                }
            }
        } else {
            ask(with: cachedLogin ?? .notFound, gen: gen)
        }
    }

    private func ask(with login: Login, gen: Int) {
        guard !stopped else { inFlight = false; return }
        guard case let .token(token, expiresAt, plan) = login else {
            inFlight = false
            state = login.failure
            // no sign-in yet (or one it can't read): look again in a minute, not at the next read interval
            if Self.waitsForSignIn(login) { nextFetch = Date().addingTimeInterval(Self.signInRetry) }
            save(); return
        }
        self.plan = plan
        if let expiresAt, expiresAt < Date() { inFlight = false; state = .expired; save(); maybeRenew(); return }
        if profileFor != Account.sha8(token) { lookUpEmail(token, gen: gen) }
        let asked = Date()
        URLSession.shared.dataTask(with: Self.request("usage", token: token)) { [weak self] data, resp, err in
            DispatchQueue.main.async { self?.finish(data: data, response: resp as? HTTPURLResponse, error: err, asked: asked, gen: gen) }
        }.resume()
    }

    /// The kept sign-in is read again only when needed: none yet, Refresh now, or expired/refused (then at most
    /// every 10 minutes).
    private func needsLoginRead() -> Bool {
        var usable = false
        if case let .token(_, expiresAt, _)? = cachedLogin {
            usable = !loginRejected && (expiresAt ?? .distantFuture) > Date().addingTimeInterval(60)
        }
        // no sign-in yet, or one that isn't readable: a minute (it may have just been made); a refused or expired one
        // waits ten (asking again sooner would only repeat a prompt)
        let wait: TimeInterval = cachedLogin == nil ? 0 : Self.waitsForSignIn(cachedLogin) ? Self.signInRetry : 10 * 60
        return forceLoginRead || (!usable && Date().timeIntervalSince(lastLoginRead) >= wait)
    }

    /// While a profile waits for a sign-in to show up, it looks again this often.
    static let signInRetry: TimeInterval = 60
    /// The sign-in watch reads the Keychain no more often than this per profile.
    nonisolated(unsafe) static var watchFloor: TimeInterval = 30

    /// The last read found no item, or an item in a form cl_audit doesn't know: a sign-in may be on its way.
    static func waitsForSignIn(_ l: Login?) -> Bool {
        switch l {
        case .notFound?, .unreadable?: return true
        default: return false
        }
    }

    /// The folder's .claude.json (Claude Code writes it as it signs in) as it was when the Keychain was last read.
    private var loginStamp: [FileAttributeKey: AnyHashable] = [:]

    /// Every few seconds (the agent's sign-in watch): a profile with no readable sign-in looks at its folder's
    /// .claude.json, one stat, and when it changed since the last read, reads the Keychain at once, so the "no sign-in"
    /// goes within seconds of Claude Code finishing the login instead of on the read schedule.
    func watchSignIn() {
        guard !stopped, !inFlight, Self.waitsForSignIn(cachedLogin), state == .noLogin || state == .unreadable else { return }
        let stamp = SignInWatch.stamp(configDir: account.configDir)
        guard stamp != loginStamp else { return }
        // Claude Code rewrites ~/.claude.json often (settings, projects): only a record that names an account is a sign-in...
        guard Account.signedInSeat(configDir: account.configDir) != nil else { loginStamp = stamp; return }
        // ...and the Keychain is read at most every 30 seconds, whatever the record does
        guard Date().timeIntervalSince(lastLoginRead) >= Self.watchFloor else { return }
        agentLog.log("reader \(self.id, privacy: .public): the folder's sign-in record changed; reading the sign-in now")
        forceLoginRead = true; nextFetch = .distantPast
        tick()
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

    private func lookUpEmail(_ token: String, gen: Int) {
        let key = Account.sha8(token), asked = Date()
        URLSession.shared.dataTask(with: Self.request("profile", token: token)) { [weak self] data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let email = ok ? data.flatMap(UsageParser.email) : nil
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }      // another folder or account since
                if let at = self.signInChangedAt, asked < at { return }    // the old account's sign-in
                if let email { self.loginEmail = email; self.profileFor = key; self.checkNewSignIn(email) }
                self.save()
            }
        }.resume()
    }

    func finish(data: Data?, response: HTTPURLResponse?, error: Error?, asked: Date = Date(), gen: Int) {
        inFlight = false
        guard !stopped else { return }
        // asked for a folder or account it no longer reads, or with the old account's sign-in: not this account's numbers
        if gen != generation { nextFetch = .distantPast; tick(); return }           // read again now, for what it reads now
        if let at = signInChangedAt, asked < at { nextFetch = .distantPast; return }
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
    func apply(_ u: Usage, now: Date = Date()) {
        var u = u
        let before = usage?.credits
        // the status line file has no credits: keep the last ones Anthropic gave
        u.credits = Credits.carry(u.credits, from: before, now: now) ?? (u.source == "Anthropic" ? nil : before)
        usage = u; state = .ok; backoff = 0
        if !onOtherAccount {                     // another account's numbers: no alerts about them
            noteBack(u)
            checkThresholds(u)
            noteCredits(u, before: before, now: now)
        }
        scheduleResetRead()
    }

    // MARK: renewing an expired sign-in

    private var renewKey: String { "lastRenewAttempt.\(id)" }

    /// An automatic renewal may run: Renew sign-in on (always, for a standby account), none under way, and the folder
    /// signed in to the account the profile linked; one signed in to another account waits for a choice.
    static func mayRenewByItself(autoRenew: Bool, renewing: Bool, onOtherAccount: Bool) -> Bool {
        autoRenew && !renewing && !onOtherAccount
    }

    /// The folder a renewal would run in, as it is now (not as the last beat saw it), is signed in to the profile's
    /// account: never another account's sign-in renewed in its name.
    static func renewsInItsFolder(_ seat: Seat?, _ dir: String) -> Bool {
        seat.map { $0.same(Account.signedInSeat(configDir: dir)) } ?? true
    }

    private func maybeRenew() {
        guard Self.mayRenewByItself(autoRenew: renewsByItself, renewing: renewing, onOtherAccount: onOtherAccount) else { return }
        guard Self.renewsInItsFolder(entry.seat, account.configDir) else { return }
        if let last = defaults.object(forKey: renewKey) as? Date, Date().timeIntervalSince(last) < Self.renewSpacing { return }
        renewLogin()
    }

    /// Runs Claude Code once for this profile's folder so it swaps its access key (see ClaudeCLI.renew). Finding
    /// Claude Code and running it happen off the main thread.
    func renewLogin() {
        guard !renewing, !stopped else { return }
        // its folder isn't there (deleted, or a link): never renewed, nothing started (Claude Code would make it again)
        guard FolderGuard.folderReady(account.configDir) else {
            renewNote = "Not renewed: its Claude Code folder isn't there"
            save(); return
        }
        // asked for too (Renew login now in the menus): never in a folder signed in to another account, whose sign-in
        // would be renewed in this profile's name; that one shows Use this account or log back in instead
        guard Self.renewsInItsFolder(entry.seat, account.configDir) else {
            renewNote = "Not renewed: this folder is signed in to another account"
            save(); return
        }
        renewing = true
        defaults.set(Date(), forKey: renewKey)
        renewNote = "Renewing the login through Claude Code…"
        save()
        let acct = account, gen = generation
        DispatchQueue.global(qos: .utility).async {
            let claude = ClaudeCLI.find()
            let ok = claude.map { ClaudeCLI.renew($0, account: acct) } ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.renewing = false
                // renewed for a folder or account it no longer reads: its words would be about another sign-in
                guard gen == self.generation else { return }
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
        // a model's own weekly limit (Fable) alerts like the two: at the level, and when full with when it's back
        let all = [("5h", "5-hour limit", "5-hour limit", u.fiveHour, u.fiveHourResets),
                   ("wk", "Weekly limit", "weekly limit", u.weekly, u.weeklyResets)]
            + (entry.showFable ? u.scoped : []).map { ($0.key, "\($0.name) weekly limit", "\($0.name) weekly limit", $0.percent, $0.resets) }
        for (key, title, fullName, p, resets) in all {
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
            // the 5-hour or weekly limit full holds the profile back: another of its accounts with room (and current
            // numbers) is offered, with a Switch account… button (Switch.swift), never naming it; Fable's own limit
            // doesn't hold it back
            let offer = full && (key == "5h" || key == "wk") ? entry.bestOffer() : nil
            if full {
                c.title = "Claude \(account.name): \(fullName) full"
                let back = resets.map { "Back \(Self.backWords($0)), in \(TimeWords.countdown($0))" } ?? "Reset time unknown"
                c.body = SwitchWords.alertLine(offer, accounts: entry.standby.count).map { "\(back). \($0)" } ?? back
            } else {
                c.title = "Claude \(account.name): \(title) at \(Int(p.rounded()))%"
                if let resets { c.body = "Resets \(Self.when(resets))" }
            }
            c.threadIdentifier = id
            let me = id, d = defaults, kind = full ? "f" : "n", gen = generation
            // sent by cl_audit's own program, so the alert comes from cl_audit in /Applications (the app System
            // Settings ▸ Notifications lists), not from this helper inside it
            DispatchQueue.global(qos: .utility).async {
                let code = Self.post(id: "\(me).\(kind)\(key).\(mark)", title: c.title, body: c.body, thread: me, offer: offer)
                DispatchQueue.main.async { [weak self] in
                    self?.alerting.remove(k)
                    // marked only for the account it was about (not one read since a switch, whose marks were cleared)
                    if code == 0, self?.stopped != true, self?.generation == gen { d.set(mark, forKey: k); if full { d.set(mark, forKey: levelKey) } }
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
        // a model's own limit (Fable) has its own "back": "Claude Main: Fable is back", unless one of the two still holds
        // the profile back (its reset brings the profile's own "back")
        for s in entry.showFable ? u.scoped : [] {
            let k = "full\(s.key).\(id)"
            if AtLimit.isFull(s.percent) {
                let v = s.resets.map { String(Int($0.timeIntervalSince1970.rounded())) } ?? "?"
                if defaults.string(forKey: k) != v { defaults.set(v, forKey: k) }
            } else if let was = defaults.string(forKey: k) {
                defaults.removeObject(forKey: k)
                guard entry.notifyBack, !five, !week else { continue }
                let t = Int(was).map { Date(timeIntervalSince1970: TimeInterval($0)) }
                sendOnce(title: "Claude \(account.name): \(s.name) is back",
                         body: t.map { "The \(s.name) weekly limit reset at \(TimeWords.when($0, now: now))" }
                            ?? "The \(s.name) weekly limit has room again",
                         slot: s.key, stamp: was)
            }
        }
        // the other limit still full: the profile isn't back yet (that one's reset sends it)
        guard !back.isEmpty, !five, !week, entry.notifyBack else { return }
        let body: String
        if back.count == 2 {
            body = "The 5-hour and weekly limits reset"
        } else if let t = Int(back[0].mark).map({ Date(timeIntervalSince1970: TimeInterval($0)) }) {
            body = "The \(back[0].name) limit reset at \(TimeWords.when(t, now: now))"
        } else {
            body = "The \(back[0].name) limit has room again"
        }
        sendOnce(title: "Claude \(account.name) is back", body: body, slot: "back", stamp: back.map(\.mark).joined(separator: "-"))
    }

    /// One alert that isn't kept for later ("back", credits): tried once.
    private func sendOnce(title: String, body: String, slot: String, stamp: String) {
        let me = id, k = "\(slot).\(id)"
        guard !alerting.contains(k) else { return }
        alerting.insert(k)
        DispatchQueue.global(qos: .utility).async {
            let code = Self.post(id: "\(me).\(slot).\(stamp)", title: title, body: body, thread: me)
            DispatchQueue.main.async { [weak self] in self?.alerting.remove(k) }
            switch code {
            case 0: agentLog.log("\(me, privacy: .public): \(slot, privacy: .public) alert sent")
            case 2: agentLog.log("\(me, privacy: .public): \(slot, privacy: .public) alert dropped: notifications for cl_audit aren't allowed")
            default: agentLog.error("\(me, privacy: .public): \(slot, privacy: .public) alert not sent (\(code))")
            }
        }
    }

    /// Usage credits: one alert when the profile starts spending them ("Claude Work is using usage credits"), again
    /// only after it stopped; one when they run out, seen happen (not when they were already out at the first read).
    /// At the profile's alerts switch; tried once.
    private func noteCredits(_ u: Usage, before: Credits?, now: Date = Date()) {
        guard let c = u.credits else { return }
        let k = "cr.\(id)"
        if c.inUse(fiveHour: u.fiveHour, weekly: u.weekly, now: now) {
            guard defaults.object(forKey: k) == nil else { return }
            defaults.set(Int(now.timeIntervalSince1970), forKey: k)
            guard entry.notify else { return }
            let why = AtLimit.isFull(u.fiveHour) ? "The 5-hour limit is full" : AtLimit.isFull(u.weekly) ? "The weekly limit is full" : nil
            let body = [why, c.spentWords.map { "\($0) so far" }].compactMap { $0 }.joined(separator: " · ")
            sendOnce(title: "Claude \(account.name) is using usage credits", body: body.isEmpty ? "Usage credits are paid for" : body,
                     slot: "credits", stamp: String(Int(now.timeIntervalSince1970)))
        } else {
            defaults.removeObject(forKey: k)
        }
        if c.out, let before, !before.out, entry.notify {
            sendOnce(title: "Claude \(account.name) is out of usage credits",
                     body: "Past a full limit, Claude stops until credits are added or the limit resets",
                     slot: "creditsOut", stamp: String(Int(now.timeIntervalSince1970)))
        }
    }

    /// Tests only: takes the alerts instead of macOS (id, title, body, thread).
    static var testPoster: ((String, String, String, String, String?) -> Int32)?    // (…, thread, switch or back key)

    /// Hands one alert to cl_audit's own program (UsageDock --post-alert). 0 sent, 2 not allowed, else failed. With a
    /// switch offer, the alert has its Switch account… button; with a standby account that is back (`backKey`), Switch
    /// back and Stay.
    static func post(id: String, title: String, body: String, thread: String, offer: SwitchOffer? = nil, backKey: String? = nil) -> Int32 {
        if let t = testPoster { return t(id, title, body, thread, offer?.key ?? backKey) }
        guard let app = LegacyCleanup.agentParentApp() else { return 1 }
        let p = Process()
        p.executableURL = app.appendingPathComponent("Contents/MacOS/UsageDock")
        p.arguments = ["--post-alert", id, title, body, thread] + (offer.map { [$0.key] } ?? backKey.map { [$0, SwitchAlert.backKind] } ?? [])
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
        for k in ["lastRenewAttempt", "adopted", "loginItemForgotten", "dockPlace"] {
            d.removeObject(forKey: "\(k).\(id)")
        }
        forgetLimitMarks(id, in: d)
    }

    /// What the alerts remember about the limits (levels reached, full, credits), as when the profile is new.
    static func forgetLimitMarks(_ id: String, in d: UserDefaults) {
        for k in ["n5h", "nwk", "f5h", "fwk", "full5h", "fullwk", "cr"] {
            d.removeObject(forKey: "\(k).\(id)")
        }
        // a model's own limit: nm…, fm…, fullm… ("nmfable.<id>")
        for k in d.dictionaryRepresentation().keys where k.hasSuffix(".\(id)")
            && (k.hasPrefix("nm") || k.hasPrefix("fm") || k.hasPrefix("fullm")) {
            d.removeObject(forKey: k)
        }
    }

    // MARK: saved status

    /// Writes status/<id>.json when what this reader sees changed (the write posts the "changed" notice).
    func save() {
        guard !stopped else { return }
        var status = IconStatus(loginEmail: loginEmail, expectedEmail: expectedEmail, state: "\(state)",
                                fiveHour: usage?.fiveHour, weekly: usage?.weekly, updatedAt: usage?.fetchedAt,
                                renewNote: renewNote, fiveHourResets: usage?.fiveHourResets,
                                weeklyResets: usage?.weeklyResets, plan: planName ?? plan,
                                source: usage?.source, problem: state.menuText, renewing: renewing,
                                scoped: usage.map { $0.scoped.isEmpty ? nil : $0.scoped } ?? nil, credits: usage?.credits,
                                noFiveHour: usage?.noFiveHour == true ? true : nil)
        // the one answer about the account (AccountResolver), written here once for every surface to read: the numbers
        // stay, labelled with the account they were read for (no "otherAccount" state for the profile's own folder). A
        // standby account's reader (id "<profile>~<standby>") has no answer of its own.
        if !id.contains("~") {
            let list = Store.loadChecked() ?? []
            let me = list.first { $0.id == id } ?? entry
            var r = AccountResolver.resolve(me, among: list, app: AppSignIn.cached(for: me),
                                            code: Account.signedInSeat(configDir: me.configDir), loginEmail: loginEmail,
                                            names: AccountResolver.knownNames())
            if var last = lastResolved { last.at = r.at; if last == r { r.at = lastResolved!.at } }
            lastResolved = r
            status.resolved = r
            if r.clash != nil {
                // Claude Code's folder on another profile's account in use: those numbers are that profile's
                status.fiveHour = nil; status.weekly = nil; status.fiveHourResets = nil; status.weeklyResets = nil
                status.scoped = nil; status.credits = nil; status.noFiveHour = nil
                status.problem = r.line
            }
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(status), data != lastStatus { lastStatus = Store.writeStatus(id, status) }
    }

    static func when(_ d: Date) -> String { TimeWords.when(d) }
}

/// Which account a profile's folder is signed in to, looked at on every tick: its .claude.json names a seat. The file
/// is parsed only when its date or size changed. Signing out (no account named) isn't a change; signing in to another
/// account after it is.
struct SignInWatch {
    private(set) var seen: Seat?                                  // the last account the file named
    private var stamp: [FileAttributeKey: AnyHashable] = [:]

    /// One look: true when the file names another account than the last one it named.
    mutating func look(stamp new: [FileAttributeKey: AnyHashable], seat: () -> Seat?) -> Bool {
        guard new != stamp else { return false }
        stamp = new
        guard let now = seat() else { return false }
        defer { seen = now }
        return seen.map { !now.same($0) } ?? false
    }

    /// The .claude.json's date and size (empty when there's none).
    static func stamp(configDir: String) -> [FileAttributeKey: AnyHashable] {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: Account.claudeJSON(configDir: configDir))) ?? [:]
        return attrs.filter { $0.key == .modificationDate || $0.key == .size }.compactMapValues { $0 as? AnyHashable }
    }
}
