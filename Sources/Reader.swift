// Reader: one profile's usage, read by the cl_audit agent (Agent.swift), which keeps one reader per profile.
//
// The sign-in is kept in memory and the Keychain is read only when it's needed: at the start, when the kept sign-in
// has expired or was refused (then at most every 10 minutes), or on Refresh now. Reads go through /usr/bin/security,
// the way Claude Code reads it, so they don't prompt (Login.read in Model.swift). The usage comes from Anthropic's
// usage endpoint, with the status line file as a fallback while it is fresh (written in the last 15 minutes, no reset
// passed); the account check from its profile endpoint.
// What a reader sees is saved to status/<id>.json (no secrets) for the Dock icons and the cl_audit window.
//
// The reading's logic and state are ProfileCore's ReaderMachine (Core/ReaderMachine.swift): events in, actions out. This
// class is its driver: it keeps the timers, looks at the folder's sign-in record (ClaudeAuth's watch), reads the Keychain
// (the token stays here, never in the machine), asks the endpoints, reads the status line file, feeds what comes back to
// the machine, and performs its actions in order (the alerts, the saved record, the read at a reset).

import AppKit
import ClaudeAuth
import ProfileCore
import Runs
import UserNotifications

final class UsageReader {
    private(set) var entry: AccountEntry
    private(set) var account: Account
    private let defaults: UserDefaults           // the agent's: alert marks and renewal times, per profile id

    /// The reading's state and rules (whose numbers, the held reading, the schedule, the kept sign-in without its token).
    private(set) var machine: ReaderMachine
    /// The kept sign-in with its token: here only. The machine knows it by its key (Account.sha8).
    private var cachedLogin: Login?
    private var lastStatus: Data?
    private var alerting: Set<String> = []       // alerts being handed to macOS
    private var resetRead: DispatchWorkItem?     // reads again the moment a full limit resets
    // Claude Code signed in to another account in this folder: .claude.json names another seat
    private var signIn = SignInWatch()
    private var planName: String?                // Claude's own name for the plan ("Ultra"), from that same .claude.json

    /// How the usage endpoint's numbers name their source.
    static let endpointSource = "Anthropic"

    var id: String { entry.id }
    private var expectedEmail: String? { account.expectedEmail() }
    var usage: Usage? { machine.usage }
    var state: FetchState { machine.state }
    /// A reading whose token's account isn't known yet: held (not shown, not alerted) until it is (profileFound).
    var heldReading: (usage: Usage, key: String)? { machine.held.map { ($0.usage, $0.key) } }
    /// The numbers shown are a reading whose account couldn't be confirmed (its lookup keeps failing).
    var unconfirmed: Bool { machine.unconfirmed }
    /// Anthropic didn't answer the last time (an error or "busy"): for the main display.
    var failing: Bool { machine.failing }

    /// The machine's intervals for a profile: its read interval, cl_audit's other values (Timing's defaults: at most one
    /// automatic renewal per 30 minutes, even across restarts, and the rest).
    static func timing(_ e: AccountEntry) -> ReaderMachine.Timing {
        var t = ReaderMachine.Timing(poll: TimeInterval(max(e.pollMinutes, 1) * 60), endpointSource: endpointSource)
        t.signInRetry = signInRetry
        return t
    }

    /// `startIn`: seconds until the first fetch, so profiles don't all ask at once.
    init(_ e: AccountEntry, defaults: UserDefaults, startIn: TimeInterval = 0) {
        entry = e
        account = Account(e)
        self.defaults = defaults
        machine = ReaderMachine(rules: .clAudit, timing: Self.timing(e), linked: e.seat, firstFetch: Date().addingTimeInterval(startIn))
        adoptSaved()                             // the numbers don't blank while the agent restarts
        Self.adoptOldMarks(e.id, into: defaults)
        lookAtFolder(follow: false)              // the first look: what the folder is signed in to now
        perform([.planResetRead(machine.resetReadAt(now: Date()))])
    }

    /// Hands an event to the machine and performs what it says.
    private func send(_ event: ReaderMachine.Event, keep: (() -> Void)? = nil) {
        perform(machine.handle(event), keep: keep)
    }

    /// The machine's actions, in order. `keep` stores a sign-in just read (its token stays in this class).
    private func perform(_ actions: [ReaderMachine.Action], keep: (() -> Void)? = nil) {
        for action in actions {
            switch action {
            case .readSignIn(let gen): readSignIn(gen: gen)
            case .keepSignIn: keep?()
            case .forgetSignIn: cachedLogin = nil
            case .lookUp(let req): lookUpEmail(req)
            case .fetchUsage(let req): fetchUsage(req)
            case .considerRenew: maybeRenew()
            case let .numbersTaken(u, before, now):
                // a reading taken for its confirmed account: the one another profile on the same seat reuses (SharedReads)
                SharedReads.note(u, owner: machine.numbersAccount, organization: machine.numbersOrganization)
                alertGate(u, before: before, now: now)
            case .planResetRead(let at): planResetRead(at)
            case .startedOver:
                agentLog.log("reader \(self.id, privacy: .public): Claude Code is signed in to another account; reading the new sign-in")
                resetRead?.cancel(); resetRead = nil
                Self.forgetLimitMarks(id, in: defaults)   // no "is back" or "full" alert from the switch itself
            case .lookAfresh:
                signIn = SignInWatch(); lookAtFolder(follow: false)
                adoptSaved()
                agentLog.log("reader \(self.id, privacy: .public): the profile works on another account; reading it")
            case .signInNotThereYet:
                agentLog.log("reader \(self.id, privacy: .public): the Keychain still has the old sign-in; reading it again soon")
            case .recordChanged:
                agentLog.log("reader \(self.id, privacy: .public): the folder's sign-in record changed; reading the sign-in now")
            case .save: save()
            case .tick: tick()
            }
        }
    }

    /// Carry on from what was saved last, if it was read for the profile's account (after a switch the saved numbers are
    /// the old account's, and `only(for:)` leaves them out). A saved status that names no account is taken only by a
    /// profile not linked to one.
    private func adoptSaved() {
        guard let saved = Store.status(entry.id), entry.seat == nil || saved.readFor != nil,
              let s = Optional(saved.only(for: entry.seat?.email)), let at = s.updatedAt, s.fiveHour != nil || s.weekly != nil else { return }
        let u = Usage(fiveHour: s.fiveHour, fiveHourResets: s.fiveHourResets, weekly: s.weekly,
                      weeklyResets: s.weeklyResets, fetchedAt: at, source: s.source ?? Self.endpointSource,
                      scoped: s.scoped ?? [], credits: s.credits, noFiveHour: s.noFiveHour ?? false)
        // (the saved numbers' own reading is their account)
        send(.adopt(usage: u, loginEmail: s.loginEmail, owner: s.readingOwner, plan: s.plan, renewNote: s.renewNote,
                    ownerAccount: s.readingAccount, ownerOrganization: s.readingOrganization))
    }

    /// The profile's settings changed: another account (a switch), another folder to read, or another interval reads
    /// again at once.
    func update(_ e: AccountEntry) {
        guard e != entry, !machine.stopped else { return }
        let seatChanged = !(e.seat.map { $0.same(entry.seat) } ?? (entry.seat == nil))
        let pollChanged = e.pollMinutes != entry.pollMinutes
        entry = e
        send(.profile(linked: e.seat, poll: Self.timing(e).poll))
        if seatChanged {
            let want = Account(e)
            let folderMoved = want.configDir != account.configDir
            account = want
            // the profile works on another account (a switch): replies under way for an old folder are dropped; unless the
            // folder is signed in to it already (FolderRules.noteAccounts: its numbers, read since that sign-in, are this
            // account's and show now), the old one's numbers, sign-in and marks go (no "is back" from the switch itself)
            // and the new one's are read afresh (the machine's .lookAfresh); then a tick
            send(.relinked(folderMoved: folderMoved, now: Date()))
            return
        }
        if followFolder() || pollChanged { forceFresh = true; send(.readNow); tick(); return }
        if renewsByItself && state == .expired { maybeRenew() }
        save()
    }

    /// The profile's choice (Renew sign-in).
    private var renewsByItself: Bool { entry.autoRenew }

    /// Bumped when the folder or the account read changes: a reply asked for before is dropped.
    var generation: Int { machine.generation }

    /// The profile's folder changed (Settings ▸ Claude Code ▸ Folder): read from there from now on, its own sign-in;
    /// replies under way for the old folder are dropped. True when it moved.
    @discardableResult
    private func followFolder(now: Date = Date()) -> Bool {
        let want = Account(entry)
        guard want.configDir != account.configDir else { return false }
        account = want
        send(.folderMoved(now: now))
        signIn = SignInWatch(); lookAtFolder(follow: false)
        return true
    }

    /// The profile was removed: a read or renewal still under way saves nothing.
    func stop() { send(.stop) }

    /// Every 30 s: the status line file if it's newer and fresh (UsageParser.fromStatusLine), a fetch when it's due, and the saved status. A full limit whose
    /// reset has passed is read again at once (then at most once a minute until Anthropic's numbers move on).
    func tick() {
        guard !machine.stopped else { return }
        lookAtFolder(follow: true)
        // the profile's folder isn't there any more: no read of its sign-in at all, whatever was made while it existed.
        // A link to a folder is read (only launching refuses links: FolderGuard.folderReady)
        let dir = account.configDir
        send(.tick(now: Date(), statusLine: UsageParser.fromStatusLine(account),
                   folderThere: Account.isDefault(configDir: dir) || FolderGuard.isFolder(dir)))
    }

    /// While a limit is full, a read the moment it resets (2 s after), so the cards, the Dock icon and the "back"
    /// alert follow at once rather than at the next scheduled read. nil: none planned.
    private func planResetRead(_ at: Date?) {
        resetRead?.cancel(); resetRead = nil
        guard let at, !machine.stopped else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.machine.stopped else { return }
            self.forceFresh = true
            self.send(.readNow)
            self.tick()
        }
        resetRead = item
        DispatchQueue.main.asyncAfter(deadline: .now() + at.timeIntervalSince(Date()), execute: item)
    }

    /// Refresh now (a Dock icon, the dashboard, the cl_audit window after a switch): fetch now, read the sign-in again, and
    /// write the record at once, changed or not.
    func refreshNow() { forceFresh = true; send(.refreshRequested); tick() }

    /// The next usage read goes to Anthropic, never a shared seat's reading (SharedReads): Refresh now, a read at a reset,
    /// another folder or interval.
    private var forceFresh = false

    // MARK: another account signed in

    /// The last answer the resolver gave (its time kept while nothing else changed, so the record isn't rewritten).
    private var lastResolved: ResolvedAccount?

    /// One look at the folder's .claude.json (ClaudeAuth's watch): the machine learns the account it names, and with
    /// `follow`, that Claude Code was signed in to another account since the last look (it starts over: the kept sign-in,
    /// the numbers and the alert marks are the old account's, and the new sign-in is read now, so no stale numbers and no
    /// "Wrong account" until Refresh now). The folder signed in to another account than the profile's
    /// (ReaderMachine.onOtherAccount): its numbers show, labelled with that account (AccountResolver), but no alerts go
    /// out about them in this profile's name and no renewal runs, until the profile follows it (FolderRules.noteAccounts).
    private func lookAtFolder(follow: Bool) {
        let dir = account.configDir
        let changed = signIn.look(stamp: SignInWatch.stamp(configDir: dir)) {
            planName = Account.planName(configDir: dir)       // read with it: no extra reads
            return Account.signedInSeat(configDir: dir)
        }
        send(.folderLooked(changed: follow && changed, seen: signIn.seen, now: Date()))
    }

    // MARK: fetching

    /// The sign-in read (the machine decided it is needed: none yet, Refresh now, or expired/refused, then at most every 10
    /// minutes). The Keychain is read off the main thread (a locked Keychain can keep /usr/bin/security waiting), so one
    /// profile never holds up the others or the agent's rules. The token is kept here; the machine gets its key.
    private func readSignIn(gen: Int) {
        let acct = account
        // the folder's sign-in record as it was before the read: a change after it is read again (watchSignIn)
        let stamp = SignInWatch.stamp(configDir: acct.configDir)
        DispatchQueue.global(qos: .utility).async {
            let login = Login.read(acct)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // (read for a folder or account it no longer reads: dropped, read again; else kept, then asked with)
                self.send(.signInRead(Self.described(login), generation: gen, now: Date())) {
                    self.cachedLogin = login
                    self.loginStamp = stamp
                }
            }
        }
    }

    /// A sign-in as the machine knows it: without its token, by the token's short hash.
    static func described(_ login: Login) -> SignInRead {
        switch login {
        case let .token(token, expiresAt, plan): return .token(key: Account.sha8(token), expiresAt: expiresAt, plan: plan)
        case .notFound: return .notFound
        case .denied: return .denied
        case .unreadable: return .unreadable
        }
    }

    /// The kept sign-in's token, for the request the machine asked for (made with its key).
    private func token(for req: ReaderMachine.Request) -> String? {
        guard case let .token(token, _, _)? = cachedLogin, Account.sha8(token) == req.key else { return nil }
        return token
    }

    /// The usage, asked with the kept sign-in; the answer goes to `finish`. A seat another profile shares (SharedReads) that
    /// profile's reader read within this one's interval is answered with that reading instead: one read per seat per cycle.
    /// Never for a read asked for now (Refresh now, a read at a reset, another interval: `forceFresh`).
    private func fetchUsage(_ req: ReaderMachine.Request) {
        // (no kept sign-in for its key: never asked, but answered as a failure, so the read under way ends)
        guard let token = token(for: req) else {
            send(.usageFailed(.network("the sign-in to ask with is gone"), asked: req.asked, generation: req.generation, now: Date()))
            return
        }
        let now = Date(), fresh = forceFresh
        forceFresh = false
        if !fresh, machine.numbersKey == req.key,
           let u = SharedReads.reuse(owner: machine.numbersAccount, organization: machine.numbersOrganization,
                                     folder: Account.signedInSeat(configDir: account.configDir), have: machine.usage?.fetchedAt,
                                     within: Self.timing(entry).poll, now: now) {
            agentLog.log("reader \(self.id, privacy: .public): another profile read this account just now; its numbers are taken, no second read")
            send(.usageAnswer(UsageAnswer(source: .usageEndpoint, usage: u), key: req.key, asked: req.asked, generation: req.generation, now: now))
            return
        }
        URLSession.shared.dataTask(with: Self.request("usage", token: token)) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                self?.finish(data: data, response: resp as? HTTPURLResponse, error: err, asked: req.asked, gen: req.generation, key: req.key)
            }
        }.resume()
    }

    /// While a profile waits for a sign-in to show up, it looks again this often.
    static let signInRetry: TimeInterval = 60
    /// The sign-in watch reads the Keychain no more often than this per profile.
    nonisolated(unsafe) static var watchFloor: TimeInterval = 30

    /// The folder's .claude.json (Claude Code writes it as it signs in) as it was when the Keychain was last read.
    private var loginStamp = RecordStamp.none

    /// Every few seconds (the agent's sign-in watch): a profile with no readable sign-in looks at its folder's
    /// .claude.json, one stat, and when it changed since the last read, reads the Keychain at once, so the "no sign-in"
    /// goes within seconds of Claude Code finishing the login instead of on the read schedule.
    func watchSignIn() {
        guard machine.watchesSignIn else { return }
        let stamp = SignInWatch.stamp(configDir: account.configDir)
        guard stamp != loginStamp else { return }
        // Claude Code rewrites ~/.claude.json often (settings, projects): only a record that names an account is a sign-in...
        guard Account.signedInSeat(configDir: account.configDir) != nil else { loginStamp = stamp; return }
        // ...and the Keychain is read at most every 30 seconds, whatever the record does
        send(.signInRecordChanged(now: Date(), floor: Self.watchFloor))
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

    /// The kept sign-in's account, from Anthropic's profile endpoint; the answer goes to the machine (dropped there when
    /// another folder or account is read since, or it was the old account's sign-in).
    private func lookUpEmail(_ req: ReaderMachine.Request) {
        // (no kept sign-in for its key: never asked, but answered as a failed lookup, tried again later)
        guard let token = token(for: req) else {
            send(.lookupAnswer(email: nil, key: req.key, asked: req.asked, generation: req.generation, expected: expectedEmail, now: Date()))
            return
        }
        URLSession.shared.dataTask(with: Self.request("profile", token: token)) { [weak self] data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let email = ok ? data.flatMap(UsageParser.email) : nil
            // (the reply's account id too: whose the numbers are, known by the id where the folder's record has no address)
            let account = ok ? data.flatMap(UsageParser.accountID) : nil
            // (and its organisation's: one login's personal and Team seats are told apart by it)
            let organization = ok ? data.flatMap(UsageParser.organizationID) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.send(.lookupAnswer(email: email, key: req.key, asked: req.asked, generation: req.generation,
                                        expected: self.expectedEmail, now: Date(), account: account, organization: organization))
            }
        }.resume()
    }

    /// The account of the token `key` came back: it is the sign-in's address, and the owner of the numbers read with that
    /// token. A reading held for it (read before its owner was known) is taken now, with its alerts.
    /// Once the account is back, the numbers shown as "account not confirmed" are its own, and the usual rules (alerts
    /// included) apply to them. (Right after a sign-in change, a token whose account isn't the folder's is read again
    /// soon: the Keychain can still hold the old sign-in for a moment.)
    /// (`account`: the account's id, when the reply gave one; `organization`: its organisation's id.)
    func profileFound(_ email: String, key: String, account: String? = nil, organization: String? = nil) {
        send(.accountFound(email: email, key: key, expected: expectedEmail, now: Date(), account: account, organization: organization))
    }

    /// The token's account couldn't be looked up: tried again later, a little later each time (1, 2, 4… minutes, at most 30).
    func lookupFailed(now: Date = Date()) { send(.lookupFailed(now: now)) }

    /// The usage endpoint's reply, handed to the machine. Whose these numbers are is the account of the token they were
    /// read with, never the folder's .claude.json; a token whose account isn't known yet has its reading held, and at the
    /// second reading still without an owner, shown as "account not confirmed" (ReaderMachine).
    func finish(data: Data?, response: HTTPURLResponse?, error: Error?, asked: Date = Date(), gen: Int, key: String? = nil) {
        let now = Date()
        let failure: ReaderMachine.Failure
        if let error {
            failure = .network(error.localizedDescription)
        } else {
            switch response?.statusCode ?? 0 {
            case 200:
                guard let data, let u = UsageParser.fromAPI(data, source: Self.endpointSource) else { failure = .unexpectedReply; break }
                send(.usageAnswer(UsageAnswer(source: .usageEndpoint, usage: u), key: key, asked: asked, generation: gen, now: now))
                return
            case 401, 403: failure = .signInRejected
            case 429: failure = .rateLimited
            case let code: failure = .http(code)
            }
        }
        send(.usageFailed(failure, asked: asked, generation: gen, now: now))
    }

    /// A good reading: keep it, send what alerts it calls for, and plan the read at the next reset (saving is the
    /// caller's).
    func apply(_ u: Usage, now: Date = Date()) { send(.numbers(u, now: now)) }

    /// The machine took a good reading (`u`, its credits carried on): the alerts it calls for.
    private func alertGate(_ u: Usage, before: Credits?, now: Date) {
        // Alerts only for numbers that may act, as ProfileCore's Headline says it for every screen: the profile's own (not
        // Claude Code's in the split, SplitUsage, nor a reading the sign-in has moved on from), confirmed, and fresh by the
        // reading's own time (a reading held until its account was confirmed, and confirmed more than the read interval
        // later, is only last known: its alerts wait for the next read). And none for another account than the profile's
        // (onOtherAccount, until it follows it). A seat several profiles share alerts once per level and window: each alert
        // asks the ledger (SharedReads.claim) after this profile's own switch and level decided it.
        let resolved = answer()
        let a = Headline.of(resolved.owner(reading: nil, unconfirmed: unconfirmed), signedIn: true, readAt: u.fetchedAt,
                            now: now, ages: Store.ages(entry))
        if !machine.onOtherAccount, a.acts, a.numbers() {
            noteBack(u)
            // the account in use as the resolver says it now (the record is saved after this)
            var view = IconStatus(state: "ok"); view.resolved = resolved
            checkThresholds(u, inUse: AccountView.of(view))
            noteCredits(u, before: before, now: now)
        }
        // (then the machine's .planResetRead: the read at the next reset)
    }

    // MARK: renewing an expired sign-in

    private var renewKey: String { "lastRenewAttempt.\(id)" }

    /// An automatic renewal, when the machine allows it (ReaderMachine.mayRenewByItself): Renew sign-in on, none under way,
    /// the folder signed in to the account the profile works on as the watch saw it and as it is now (one signed in to
    /// another account is never renewed in its name), and none in the last 30 minutes, even across restarts.
    private func maybeRenew() {
        let last = defaults.object(forKey: renewKey) as? Date
        guard machine.mayRenewByItself(autoRenew: renewsByItself, folderNow: Account.signedInSeat(configDir: account.configDir),
                                       lastAttempt: last, now: Date()) else { return }
        renewLogin()
    }

    /// Runs Claude Code once for this profile's folder so it swaps its access key (see ClaudeCLI.renew). Finding
    /// Claude Code and running it happen off the main thread.
    func renewLogin() {
        guard !machine.renewing, !machine.stopped else { return }
        // its folder isn't there (deleted, or a link): never renewed, nothing started (Claude Code would make it again)
        guard FolderGuard.folderReady(account.configDir) else {
            send(.renewRefused(note: "Not renewed: its Claude Code folder isn't there")); return
        }
        // never in a folder signed in to another account, whose sign-in would be renewed in this profile's name; the
        // profile follows that one by itself, or signs back in with Log in…
        guard machine.renewsIn(folderNow: Account.signedInSeat(configDir: account.configDir)) else {
            send(.renewRefused(note: "Not renewed: this folder is signed in to another account")); return
        }
        defaults.set(Date(), forKey: renewKey)
        send(.renewStarted(note: "Renewing the sign-in through Claude Code…"))
        let acct = account, gen = machine.generation, seat = entry.seat
        DispatchQueue.global(qos: .utility).async {
            let claude = ClaudeCLI.find()
            // (ClaudeAuth checks the folder's account again as it runs: never another account's sign-in renewed)
            let ok = claude.map { ClaudeCLI.renew($0, account: acct, expecting: seat) } ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // (renewed for a folder or account it no longer reads: its words would be about another sign-in, so the
                // machine drops them; else it reads the sign-in again now)
                let note = claude == nil ? "Couldn't renew: Claude Code isn't installed"
                    : ok ? "Sign-in renewed at \(Self.when(Date()))" : "Couldn't renew the sign-in: run Claude Code for this profile once"
                self.send(.renewEnded(note: note, generation: gen))
            }
        }
    }

    // MARK: alerts

    /// One alert per limit and reset, from cl_audit (the agent), at the profile's level, and one when the limit is
    /// full, saying when it's back ("Back at 15:28, in 1h 42m"). No e-mail addresses. The reset is marked as alerted
    /// only once macOS took the alert, so one that couldn't be shown (alerts not allowed yet) comes when they are.
    private func checkThresholds(_ u: Usage, inUse: AccountView) {
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
            // a shared seat: another profile on it already alerted this level (or full) in this window, so not again
            let seat = seatKey, slot = full ? "f.\(key)" : "n\(Int(limit)).\(key)"
            guard SharedReads.claim(seat: seat, slot: slot, mark: mark, by: id) else { continue }
            alerting.insert(k)
            let c = UNMutableNotificationContent()
            // the 5-hour or weekly limit full holds the profile back: another of its accounts with room is offered, with
            // a Switch account… button (Switch.swift), never naming it: the one offer every place makes
            // (AccountEntry.fullOffer: never the account in use); Fable's own limit doesn't hold it back
            let offer = full && (key == "5h" || key == "wk") ? (Store.loadChecked()?.first { $0.id == id } ?? entry).fullOffer(view: inUse) : nil
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
                    if code != 0 { SharedReads.release(seat: seat, slot: slot, mark: mark, by: me) }    // another profile may send it
                    // marked only for the account it was about (not one read since a switch, whose marks were cleared)
                    if code == 0, self?.machine.stopped != true, self?.generation == gen { d.set(mark, forKey: k); if full { d.set(mark, forKey: levelKey) } }
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

    /// The seat this reader's numbers were read for (SharedReads.key), for the alert ledger; nil: not confirmed yet.
    private var seatKey: String? {
        machine.numbersAccount.flatMap { $0.isEmpty ? nil : SharedReads.key($0, machine.numbersOrganization) }
    }

    /// One alert that isn't kept for later ("back", credits): tried once.
    private func sendOnce(title: String, body: String, slot: String, stamp: String) {
        let me = id, k = "\(slot).\(id)", seat = seatKey
        guard !alerting.contains(k) else { return }
        // a shared seat: once per window for the seat (its stamp: a reset's, or the moment credits started)
        guard SharedReads.claim(seat: seat, slot: slot, mark: stamp, by: me) else { return }
        alerting.insert(k)
        DispatchQueue.global(qos: .utility).async {
            let code = Self.post(id: "\(me).\(slot).\(stamp)", title: title, body: body, thread: me)
            DispatchQueue.main.async { [weak self] in
                self?.alerting.remove(k)
                if code != 0 { SharedReads.release(seat: seat, slot: slot, mark: stamp, by: me) }
            }
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
    static var testPoster: ((String, String, String, String, String?) -> Int32)?    // (…, thread, switch key)

    /// Hands one alert to cl_audit's own program (UsageDock --post-alert). 0 sent, 2 not allowed, else failed. With a
    /// switch offer, the alert has its Switch account… button.
    static func post(id: String, title: String, body: String, thread: String, offer: SwitchOffer? = nil) -> Int32 {
        if let t = testPoster { return t(id, title, body, thread, offer?.key) }
        guard let app = LegacyCleanup.agentParentApp() else { return 1 }
        // (Runs' Runner: 20 s at most, then asked to end and left to; in the agent's own folder and environment)
        let args = ["--post-alert", id, title, body, thread] + (offer.map { [$0.key] } ?? [])
        return Runs.Runner.run(Runs.Program(app.appendingPathComponent("Contents/MacOS/UsageDock").path, args, folder: .inherited,
                                            timeout: 20, grace: 0, killAfterGrace: false))?.status ?? 1
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

    /// Writes status/<id>.json when what this reader sees changed, and always after a refresh asked for or a read
    /// (`rewriteDue`); the write posts the "changed" notice. The agent is the record's one writer.
    func save() {
        let m = machine, usage = m.usage, state = m.state
        guard !m.stopped else { return }
        var status = IconStatus(loginEmail: m.loginEmail, expectedEmail: expectedEmail, state: "\(state)",
                                fiveHour: usage?.fiveHour, weekly: usage?.weekly, updatedAt: usage?.fetchedAt,
                                renewNote: m.renewNote, fiveHourResets: usage?.fiveHourResets,
                                weeklyResets: usage?.weeklyResets, plan: planName ?? m.plan,
                                source: usage?.source, problem: state.menuText, renewing: m.renewing,
                                scoped: usage.map { $0.scoped.isEmpty ? nil : $0.scoped } ?? nil, credits: usage?.credits,
                                noFiveHour: usage?.noFiveHour == true ? true : nil)
        // decided here, for every surface: no percent past its limit's reset, and an expired sign-in with no fresh numbers
        // has none at all (no bars, "login expired", Log in…). The reader keeps its own copy, to read again at a reset
        status = status.current()
        status.numbersOwner = m.numbersOwner
        status.numbersAccount = m.numbersAccount
        status.numbersOrganization = m.numbersOrganization
        status.ownerUnconfirmed = m.unconfirmed ? true : nil
        // the one answer about the account (AccountResolver), written here once for every surface to read: the numbers
        // stay, labelled with the account they were read for (no "otherAccount" state for the profile's own folder)
        var r = answer()
        if var last = lastResolved { last.at = r.at; if last == r { r.at = lastResolved!.at } }
        lastResolved = r
        status.resolved = r
        if r.clash != nil {
            // Claude Code's folder on another profile's account in use: those numbers and that plan are that profile's
            status.dropForClash(r.line)
        }
        if let data = StatusCodec.encode(status), data != lastStatus || m.rewriteDue {
            send(.written)
            lastStatus = Store.writeStatus(id, status)
        }
    }

    /// The account answer for what this reader sees now (AccountResolver), with the numbers' own reading as their account.
    private func answer() -> ResolvedAccount {
        let list = Store.loadChecked() ?? []
        let me = list.first { $0.id == id } ?? entry
        return AccountResolver.resolve(me, among: list, app: AppSignIn.cached(for: me),
                                       code: Account.signedInSeat(configDir: me.configDir), loginEmail: machine.numbersOwner,
                                       loginAccount: machine.numbersAccount, loginOrganization: machine.numbersOrganization,
                                       names: AccountList.names(), recordTooLarge: Account.recordTooLarge(configDir: me.configDir),
                                       newestSwitch: SwitchEngine.receipts(profile: me.id).first)
    }

    static func when(_ d: Date) -> String { TimeWords.when(d) }
}

/// Which account a profile's folder is signed in to, looked at on every tick: its .claude.json names a seat. ClaudeAuth's
/// SignInChangeWatch over the record (read again only when its date, size or file changed; signing out isn't a change,
/// signing in to another account after it is), with the seat it last named, which the reader compares exactly
/// (Seat.same) where it always has.
struct SignInWatch {
    private var watch = SignInChangeWatch()
    private(set) var seen: Seat?                                  // the last account the file named

    /// One look: true when the file names another account than the last one it named.
    mutating func look(stamp new: RecordStamp, seat: () -> Seat?) -> Bool {
        var named: Seat?
        let changed = watch.look(stamp: new) { named = seat(); return named.map(SignedInAccount.init) }
        if let named { seen = named }
        return changed
    }

    /// The .claude.json's stamp (ClaudeAuth's RecordStamp: date, size, file; .none when there's none).
    static func stamp(configDir: String) -> RecordStamp { RecordStamp.of(Account.claudeJSON(configDir: configDir)) }
}

/// Shared seats (operator, 2026-11-22): one account may be several profiles', each with its own folder and sign-in, so
/// the agent keeps one reading per seat (account id and organisation) and a reader whose sign-in is on that seat takes it
/// instead of asking Anthropic again within its interval: one usage read per seat per cycle, no extra 429s. Main thread only
/// (the readers' actions and replies all run there). Its alerts go out once per level and window, from the first profile
/// that actually alerts (`claim`, the ledger).
enum SharedReads {
    nonisolated(unsafe) static var last: [String: Usage] = [:]

    /// A seat as a key: its id and organisation in their normal form ("" for none recorded).
    static func key(_ account: String, _ organization: String?) -> String {
        AccountID.normal(account) + "/" + AccountID.normal(organization ?? "")
    }

    /// A reading taken for its confirmed account (`owner`, with its organisation): kept for that seat, newest only.
    static func note(_ u: Usage, owner: String?, organization: String?) {
        guard let owner, !owner.isEmpty else { return }
        let k = key(owner, organization)
        if let old = last[k], old.fetchedAt >= u.fetchedAt { return }
        last[k] = u
    }

    /// The reading another profile took for this seat, to take instead of a read of its own: only when this reader's own
    /// last reading was confirmed for that seat (`owner`, `organization`, read with the key asked with: the caller's), its
    /// folder is still signed in to that very seat (`folder`, the organisation too: never across a switch, never a personal
    /// seat for a Team one), it is newer than what this reader has (`have`), and no older than `within` (the reader's
    /// interval). nil: read as usual.
    static func reuse(owner: String?, organization: String?, folder: Seat?, have: Date?, within: TimeInterval, now: Date = Date()) -> Usage? {
        guard let owner, !owner.isEmpty, let folder, AccountID.same(folder.account, owner),
              AccountID.sameOrganization(folder.organization, organization),
              let u = last[key(owner, organization)] else { return nil }
        let age = now.timeIntervalSince(u.fetchedAt)
        guard age >= 0, age < within, have.map({ u.fetchedAt > $0 }) ?? true else { return nil }
        return u
    }

    // MARK: the alert ledger

    /// Per seat (`key`) and slot (a limit at a level, "n80.5h", or full, "f.5h"; "back", a model's back, credits): the window's
    /// mark of the alert that went out, and the profile that sent it. Main thread only.
    nonisolated(unsafe) static var alerted: [String: (mark: String, by: String)] = [:]

    /// Whether a profile may send this alert for a shared seat, by the ledger alone (pure): yes, unless another profile already
    /// sent the same slot in the same window (the same mark, or reset times within 10 minutes: Anthropic's wobble). A seat not
    /// known (nil) never shares: always yes. Each profile's own switch and threshold decide before this is asked, so a
    /// profile with alerts off, a higher level, a failed read or a slower interval never stands in for another.
    static func mayAlert(_ ledger: [String: (mark: String, by: String)], seat: String?, slot: String, mark: String, by id: String) -> Bool {
        guard let seat, let had = ledger[seat + "#" + slot] else { return true }
        guard had.by != id else { return true }
        return !(had.mark == mark || UsageReader.sameReset(had.mark, Int(mark)))
    }

    /// The same, and when yes, this profile claims the slot (it is the one that alerts). nil seat: yes, nothing kept.
    static func claim(seat: String?, slot: String, mark: String, by id: String) -> Bool {
        guard mayAlert(alerted, seat: seat, slot: slot, mark: mark, by: id) else { return false }
        if let seat { alerted[seat + "#" + slot] = (mark, id) }
        return true
    }

    /// An alert that couldn't be shown after all: its claim goes, so another profile on the seat may send it.
    static func release(seat: String?, slot: String, mark: String, by id: String) {
        guard let seat, let had = alerted[seat + "#" + slot], had.by == id, had.mark == mark else { return }
        alerted[seat + "#" + slot] = nil
    }
}
