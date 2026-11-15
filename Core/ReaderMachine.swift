// ProfileCore · the reader: one profile's reading of its usage as a state machine. Events in (a tick, a refresh asked
// for, the folder's sign-in looked at, a sign-in read, the usage endpoint's answer or failure, the account lookup's
// answer, a renewal's start and end, and cl_quick's rate-limit events and limit messages), actions out (read the sign-in,
// keep or drop it, look its account up, fetch the usage, consider a renewal, numbers taken, plan the read at a reset, save
// the record, tick again). No clock, no sign-in store, no network and no files: `now` comes with every event, and the token
// never comes in (a sign-in read is known by its key, a short hash the app makes). The app keeps the timers, does the
// reading, and performs the actions in the order given.
//
// The rules, as cl_audit's reader always had them:
// - the kept sign-in is read again only when needed: none yet, a refresh asked for, or one that is expired, rejected or
//   about to expire (then at most every `Timing.keptSignInRetry`; one not found or in an unknown form every
//   `Timing.signInRetry`);
// - the folder signed in to another account since the last look: everything of the old account goes (numbers, kept
//   sign-in, plan, renewal note) and the new sign-in is read at once; answers asked for before that are the old account's;
// - whose numbers they are: the account looked up for the token they were read with. A reading whose token's account isn't
//   known yet is held; at the second such reading it shows as "account not confirmed"; a token once confirmed keeps its
//   account through a lookup outage;
// - the endpoint busy (429): a backoff, doubled each time (`Timing.backoffFloor` to `backoffCap`); a rejected sign-in
//   (401/403) is expired, and a renewal is considered;
// - a full limit whose reset has passed is read again at once (at most every `Timing.resetRereadFloor`).
// The one "is it another account" rule is `belongs(_:)`.

import Foundation

public struct ReaderMachine: Equatable {
    /// The reader's intervals: cl_audit's values by default; `poll` is the profile's read interval.
    public struct Timing: Equatable {
        public var poll: TimeInterval
        /// No sign-in yet, or one in an unknown form: looked for again this often.
        public var signInRetry: TimeInterval = 60
        /// A rejected or expired sign-in is read again at most this often.
        public var keptSignInRetry: TimeInterval = 10 * 60
        /// A token that expires within this is read again.
        public var expiresSoon: TimeInterval = 60
        /// A full limit past its reset is read again at most this often.
        public var resetRereadFloor: TimeInterval = 60
        /// The endpoint busy: the backoff starts here, doubles, and stops at the cap.
        public var backoffFloor: TimeInterval = 120
        public var backoffCap: TimeInterval = 1800
        /// The account lookup failing: tried again after this, doubled each time, at most the cap.
        public var lookupRetry: TimeInterval = 60
        public var lookupCap: TimeInterval = 1800
        /// Right after the folder signed in to another account, the store can still hold the old sign-in: within this
        /// window, a sign-in whose account isn't the folder's is read again, at most `newSignInRetries` times, `newSignInStep`
        /// more seconds apart each time.
        public var newSignInWindow: TimeInterval = 5 * 60
        public var newSignInRetries = 4
        public var newSignInStep: TimeInterval = 15
        /// At most one automatic renewal per this long.
        public var renewSpacing: TimeInterval = 30 * 60
        /// How the app names the usage endpoint as a source (its numbers carry no credits of their own when it gave none).
        public var endpointSource: String

        public init(poll: TimeInterval, endpointSource: String) { self.poll = poll; self.endpointSource = endpointSource }
    }

    /// A reading held until its token's account is known.
    public struct Held: Equatable {
        public var usage: Usage
        public var key: String
    }

    /// The endpoint's answer, or why there is none.
    public enum Failure: Equatable {
        /// 401 or 403: the sign-in was rejected (expired).
        case signInRejected
        /// 429: busy.
        case rateLimited
        case http(Int)
        /// No answer (the network's own words).
        case network(String)
        /// A 200 whose body isn't a usage answer.
        case unexpectedReply
    }

    /// What the app asks the endpoint (or the lookup) with: the kept sign-in's key, the generation it was asked in, and when.
    public struct Request: Equatable {
        public var key: String
        public var generation: Int
        public var asked: Date
    }

    public enum Event: Equatable {
        /// The app's periodic tick: the status line file's numbers (if it has fresh ones), and whether the profile's folder
        /// is there to read (a folder that's gone is never read).
        case tick(now: Date, statusLine: Usage?, folderThere: Bool)
        /// The folder's sign-in record looked at: `changed` when it names another account than the last look; `seen` the
        /// last account it named.
        case folderLooked(changed: Bool, seen: Seat?, now: Date)
        /// The profile's settings as they are now: its linked account and read interval.
        case profile(linked: Seat?, poll: TimeInterval)
        /// The profile was linked to another account; `folderMoved` when its folder changed with it.
        case relinked(folderMoved: Bool, now: Date)
        /// The profile's folder changed (its own sign-in from now on).
        case folderMoved(now: Date)
        /// Read at the next tick, whatever the schedule.
        case readNow
        /// Refresh now: read the sign-in again and fetch now, and write the record, changed or not.
        case refreshRequested
        /// What was saved last, adopted at the start (numbers, address, their reading's account, plan, renewal note).
        case adopt(usage: Usage, loginEmail: String?, owner: String?, plan: String?, renewNote: String?)
        /// The sign-in read for generation `generation` came back.
        case signInRead(SignInRead, generation: Int, now: Date)
        /// The folder's sign-in record changed while no sign-in could be read: read it now, at most every `floor`.
        case signInRecordChanged(now: Date, floor: TimeInterval)
        /// The usage endpoint's answer (`key`: the kept sign-in's it was read with; nil when not known).
        case usageAnswer(UsageAnswer, key: String?, asked: Date, generation: Int, now: Date)
        case usageFailed(Failure, asked: Date, generation: Int, now: Date)
        /// The account lookup's answer for `key` (`email` nil: it failed); `expected` is the address the folder's record names.
        case lookupAnswer(email: String?, key: String, asked: Date, generation: Int, expected: String?, now: Date)
        /// The token `key`'s account is known (as a lookup's return).
        case accountFound(email: String, key: String, expected: String?, now: Date)
        case lookupFailed(now: Date)
        /// Numbers to take (as a good reading's): what alerts they call for is the app's.
        case numbers(Usage, now: Date)
        /// A renewal was not started (`note`: the app's words why).
        case renewRefused(note: String)
        /// A renewal started (`note`: the app's words).
        case renewStarted(note: String)
        /// A renewal ended (`note`: the app's words for how), for generation `generation`.
        case renewEnded(note: String, generation: Int)
        /// A rate-limit event (cl_quick).
        case rateLimit(RateLimitEvent, now: Date)
        /// A message that says a limit (cl_quick).
        case limitMessage(LimitMessage, now: Date)
        /// The record was written.
        case written
        /// The profile was removed: nothing more is read or saved.
        case stop
    }

    public enum Action: Equatable {
        /// Read the sign-in (off the main thread), then hand it back as `.signInRead` with this generation.
        case readSignIn(generation: Int)
        /// Keep the sign-in just read, its token included (the app holds the token).
        case keepSignIn
        /// Drop the kept sign-in and its token.
        case forgetSignIn
        /// Look up the account of the kept sign-in (`request.key`).
        case lookUp(Request)
        /// Fetch the usage with the kept sign-in (`request.key`).
        case fetchUsage(Request)
        /// An automatic renewal may be due: the app asks `mayRenewByItself` with what it reads now.
        case considerRenew
        /// Numbers taken (a good reading): the app's alerts for them (`creditsBefore`: the credits before them).
        case numbersTaken(Usage, creditsBefore: Credits?, now: Date)
        /// Plan a read at this time (a full limit's reset), or cancel the planned one (nil).
        case planResetRead(Date?)
        /// The folder signed in to another account: forget the old account's alert marks, cancel a planned read, say so.
        case startedOver
        /// Linked to another account it doesn't read yet: look at the folder afresh and adopt what was saved for it.
        case lookAfresh
        /// The sign-in read still names the old account: it is read again soon.
        case signInNotThereYet
        /// The folder's record changed while no sign-in could be read: it is read now.
        case recordChanged
        /// Save the record (written when it changed, or when `rewriteDue`).
        case save
        /// Tick again now.
        case tick
    }

    /// How a sign-in or a reading's account relates to the account the profile is linked to.
    public enum Belongs: Equatable {
        /// The profile is linked to no account (or none is expected): nothing to compare.
        case notLinked
        /// What was read names no account.
        case unknown
        case same
        case other
    }

    /// What names an account: a seat (the folder's record), or an address (the account lookup, the folder's address).
    public enum Clue: Equatable {
        case seat(Seat?)
        case address(String?)
    }

    public let rules: ReadingRules
    public private(set) var timing: Timing

    // the profile
    public private(set) var linked: Seat?
    /// The last account the folder's record named (the sign-in watch).
    public private(set) var seen: Seat?

    // the numbers and whose they are
    public private(set) var usage: Usage?
    public private(set) var state: FetchState = .idle
    public private(set) var plan: String?
    public private(set) var loginEmail: String?
    /// The key the address was looked up for.
    public private(set) var profileFor: String?
    /// The account the numbers were read for: the one looked up for the key they were read with (`numbersKey`); nil while
    /// it isn't known, and for a status line file (which names none).
    public private(set) var numbersOwner: String?
    public private(set) var numbersKey: String?
    public private(set) var held: Held?
    /// Readings in a row held for the key being held.
    public private(set) var heldReads = 0
    /// The numbers are a reading whose account couldn't be confirmed.
    public private(set) var unconfirmed = false
    /// Keys whose account was confirmed.
    public private(set) var ownerByKey: [String: String] = [:]
    public private(set) var lookupFails = 0
    public private(set) var nextLookup = Date.distantPast
    /// The account refused (cl_quick's rules; always nil with cl_audit's).
    public private(set) var refusal: Refusal?

    // the sign-in and the schedule
    public private(set) var kept: SignInRead?
    public private(set) var lastLoginRead = Date.distantPast
    public private(set) var loginRejected = false
    public private(set) var forceLoginRead = false
    public private(set) var nextFetch: Date
    public private(set) var backoff: TimeInterval = 0
    public private(set) var inFlight = false
    public private(set) var lastAsked = Date.distantPast
    /// The next save writes the record even when nothing changed (a refresh asked for, every read's answer).
    public private(set) var rewriteDue = false
    public private(set) var stopped = false
    /// When the folder signed in to another account: older answers and status lines are the old account's.
    public private(set) var signInChangedAt: Date?
    public private(set) var signInRetries = 0
    /// Bumped when the folder or the account read changes: an answer asked for before is dropped.
    public private(set) var generation = 0

    // renewing
    public private(set) var renewNote: String?
    public private(set) var renewing = false

    public init(rules: ReadingRules = .clAudit, timing: Timing, linked: Seat?, firstFetch: Date) {
        self.rules = rules; self.timing = timing; self.linked = linked; nextFetch = firstFetch
    }

    /// The endpoint didn't answer the last time (an error, or busy).
    public var failing: Bool {
        if case .failed = state { return true }
        return state == .rateLimited
    }

    /// The folder is signed in to another account than the profile's: its numbers show, labelled with it, but no alerts go
    /// out about them in this profile's name and no renewal runs.
    public var onOtherAccount: Bool { belongs(.seat(seen)) == .other }

    /// The one "is it another account" rule: what a clue names, against the profile's account (the linked seat, by the one
    /// owner rule, `Seat.sameAccount`: the ids in any case), or against an expected address (any case).
    public func belongs(_ clue: Clue, expected: String? = nil) -> Belongs {
        switch clue {
        case .seat(let s):
            guard let linked else { return .notLinked }
            guard let s else { return .unknown }
            return s.sameAccount(linked) ? .same : .other
        case .address(let a):
            guard let expected else { return .notLinked }
            guard let a else { return .unknown }
            return a.lowercased() == expected.lowercased() ? .same : .other
        }
    }

    /// A renewal may run in the folder as it is now (`folderNow`: the account its record names now): a profile linked to no
    /// account, or one signed in to the profile's own. Never another account's sign-in renewed in its name.
    public func renewsIn(folderNow: Seat?) -> Bool {
        let b = belongs(.seat(folderNow))
        return b == .notLinked || b == .same
    }

    /// An automatic renewal may run now: Renew on, none under way, the folder not on another account as last seen nor now,
    /// and the last attempt `Timing.renewSpacing` ago or more.
    public func mayRenewByItself(autoRenew: Bool, folderNow: Seat?, lastAttempt: Date?, now: Date) -> Bool {
        guard autoRenew, !renewing, !onOtherAccount, renewsIn(folderNow: folderNow) else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < timing.renewSpacing { return false }
        return true
    }

    /// The folder's record may be watched for a sign-in: nothing under way, and the last read found none (or one in an
    /// unknown form).
    public var watchesSignIn: Bool {
        !stopped && !inFlight && (kept?.waits ?? false) && (state == .noLogin || state == .unreadable)
    }

    /// The kept sign-in is read again only when needed: none yet, a refresh asked for, or one rejected, expired or about
    /// to (then at most every `keptSignInRetry`; one not found or in an unknown form every `signInRetry`).
    public func needsSignInRead(now: Date) -> Bool {
        var usable = false
        if case let .token(_, expiresAt, _)? = kept {
            usable = !loginRejected && (expiresAt ?? .distantFuture) > now.addingTimeInterval(timing.expiresSoon)
        }
        let wait: TimeInterval = kept == nil ? 0 : (kept?.waits ?? false) ? timing.signInRetry : timing.keptSignInRetry
        return forceLoginRead || (!usable && now.timeIntervalSince(lastLoginRead) >= wait)
    }

    /// A limit read as full whose reset time has passed: the numbers are out of date.
    public static func resetPassed(_ u: Usage, now: Date) -> Bool {
        (AtLimit.isFull(u.fiveHour) && Freshness.passed(u.fiveHourResets, now: now))
            || (AtLimit.isFull(u.weekly) && Freshness.passed(u.weeklyResets, now: now))
    }

    /// When to read again for a full limit's reset: 2 s after the first full limit resets, or nil.
    public static func resetReadAt(_ u: Usage, now: Date) -> Date? {
        [(u.fiveHour, u.fiveHourResets), (u.weekly, u.weeklyResets)]
            .compactMap { AtLimit.isFull($0.0) ? $0.1 : nil }.filter { $0 > now }.min()?.addingTimeInterval(2)
    }

    /// The read planned for the numbers kept now.
    public func resetReadAt(now: Date) -> Date? { stopped ? nil : usage.flatMap { Self.resetReadAt($0, now: now) } }

    // MARK: events

    public mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case let .tick(now, statusLine, folderThere):
            return tick(now: now, statusLine: statusLine, folderThere: folderThere)
        case let .folderLooked(changed, s, now):
            seen = s
            return changed ? startOver(now: now) : []
        case let .profile(l, poll):
            linked = l; timing.poll = poll
            return []
        case let .relinked(folderMoved, now):
            let readsNewAlready = !folderMoved && belongs(.seat(seen)) == .same
            if folderMoved { generation += 1 }
            var out: [Action] = []
            if !readsNewAlready { out += startOver(now: now) + [.lookAfresh] }
            return out + [.tick]
        case let .folderMoved(now):
            loginEmail = nil; profileFor = nil; nextFetch = .distantPast; kept = nil
            numbersOwner = nil; numbersKey = nil; held = nil; heldReads = 0; unconfirmed = false
            generation += 1
            signInChangedAt = now
            return [.forgetSignIn]
        case .readNow:
            nextFetch = .distantPast
            return []
        case .refreshRequested:
            nextFetch = .distantPast; forceLoginRead = true; rewriteDue = true
            return []
        case let .adopt(u, email, owner, p, note):
            usage = u; loginEmail = email; numbersOwner = owner; plan = p; renewNote = note
            return []
        case let .signInRead(read, gen, now):
            guard gen == generation else { inFlight = false; nextFetch = .distantPast; return [.tick] }
            kept = read; lastLoginRead = now; loginRejected = false; forceLoginRead = false
            return [.keepSignIn] + ask(read, generation: gen, now: now)
        case let .signInRecordChanged(now, floor):
            guard now.timeIntervalSince(lastLoginRead) >= floor else { return [] }
            forceLoginRead = true; nextFetch = .distantPast
            return [.recordChanged, .tick]
        case let .usageAnswer(answer, key, asked, gen, now):
            return answered(.answer(answer), key: key, asked: asked, generation: gen, now: now)
        case let .usageFailed(failure, asked, gen, now):
            return answered(.failed(failure), key: nil, asked: asked, generation: gen, now: now)
        case let .lookupAnswer(email, key, asked, gen, expected, now):
            guard gen == generation else { return [] }
            if let at = signInChangedAt, asked < at { return [] }
            let out: [Action]
            if let email { out = found(email, key: key, expected: expected, now: now) } else { lookupFailed(now: now); out = [] }
            return out + [.save]
        case let .accountFound(email, key, expected, now):
            return found(email, key: key, expected: expected, now: now)
        case let .lookupFailed(now):
            lookupFailed(now: now)
            return []
        case let .numbers(u, now):
            return take(u, now: now)
        case let .renewRefused(note):
            guard !stopped else { return [] }
            renewNote = note
            return [.save]
        case let .renewStarted(note):
            guard !stopped else { return [] }
            renewing = true; renewNote = note
            return [.save]
        case let .renewEnded(note, gen):
            guard !stopped else { return [] }
            renewing = false
            guard gen == generation else { return [] }
            renewNote = note; nextFetch = .distantPast; forceLoginRead = true
            return [.tick]
        case let .rateLimit(e, now):
            return rateLimit(e, now: now)
        case let .limitMessage(m, now):
            guard !stopped, rules.refusals != nil, rules.readsMessage(isError: m.isError, model: m.model) else { return [] }
            refusal = Refusal(until: m.until, at: now, on: m.on)
            return [.save]
        case .written:
            rewriteDue = false
            return []
        case .stop:
            stopped = true
            return [.planResetRead(nil)]
        }
    }

    // MARK: the steps

    private mutating func tick(now: Date, statusLine: Usage?, folderThere: Bool) -> [Action] {
        guard !stopped else { return [] }
        if var local = statusLine, local.fetchedAt > (usage?.fetchedAt ?? .distantPast),
           local.fetchedAt > (signInChangedAt ?? .distantPast) {
            // the status line has only the two limits: the model limits and credits stay as the endpoint last gave them
            local.scoped = usage?.scoped ?? []; local.credits = usage?.credits
            local.noFiveHour = usage?.noFiveHour ?? false
            if local.noFiveHour { local.fiveHour = nil; local.fiveHourResets = nil }
            usage = local
            numbersOwner = nil; numbersKey = nil          // the status line names no account: whose these are isn't known
        }
        if let u = usage, Self.resetPassed(u, now: now), !failing, now.timeIntervalSince(lastAsked) >= timing.resetRereadFloor {
            nextFetch = .distantPast
        }
        var out: [Action] = []
        if now >= nextFetch, folderThere { out += fetch(now: now) }
        return out + [.save]
    }

    /// The folder signed in to another account: the kept sign-in, the numbers and the alert marks are the old account's.
    private mutating func startOver(now: Date) -> [Action] {
        kept = nil; forceLoginRead = true; loginRejected = false
        loginEmail = nil; profileFor = nil; plan = nil; renewNote = nil
        usage = nil; state = .idle; backoff = 0; refusal = nil
        numbersOwner = nil; numbersKey = nil; held = nil; heldReads = 0; unconfirmed = false
        signInChangedAt = now; signInRetries = 0
        generation += 1                           // answers under way are the old account's
        nextFetch = .distantPast
        return [.forgetSignIn, .startedOver]
    }

    private mutating func fetch(now: Date) -> [Action] {
        guard !inFlight else { return [] }
        lastAsked = now
        nextFetch = now.addingTimeInterval(timing.poll + backoff)
        inFlight = true
        if needsSignInRead(now: now) { return [.readSignIn(generation: generation)] }
        return ask(kept ?? .notFound, generation: generation, now: now)
    }

    private mutating func ask(_ read: SignInRead, generation gen: Int, now: Date) -> [Action] {
        guard !stopped else { inFlight = false; return [] }
        guard case let .token(key, expiresAt, p) = read else {
            inFlight = false
            rewriteDue = true                    // a read's answer: written, changed or not
            state = read.failure
            // no sign-in yet (or one it can't read): look again soon, not at the next read interval
            if read.waits { nextFetch = now.addingTimeInterval(timing.signInRetry) }
            return [.save]
        }
        plan = p
        if let expiresAt, expiresAt < now { inFlight = false; rewriteDue = true; state = .expired; return [.save, .considerRenew] }
        var out: [Action] = []
        // the token's account: looked up once per token (a confirmed one keeps its owner), again with backoff while it fails
        if profileFor != key, ownerByKey[key] == nil, now >= nextLookup { out.append(.lookUp(Request(key: key, generation: gen, asked: now))) }
        out.append(.fetchUsage(Request(key: key, generation: gen, asked: now)))
        return out
    }

    private enum Outcome { case answer(UsageAnswer), failed(Failure) }

    private mutating func answered(_ result: Outcome, key: String?, asked: Date, generation gen: Int, now: Date) -> [Action] {
        inFlight = false
        guard !stopped else { return [] }
        // asked for a folder or account it no longer reads, or with the old account's sign-in: not this account's numbers
        if gen != generation { nextFetch = .distantPast; return [.tick] }           // read again now, for what it reads now
        if let at = signInChangedAt, asked < at { nextFetch = .distantPast; return [] }
        rewriteDue = true                        // a read's answer: written, changed or not
        var out: [Action] = []
        switch result {
        case .answer(let answer):
            guard let u = rules.take(answer, last: usage) else { break }      // an empty answer: nothing changes
            if let r = refusal, rules.lifts(r, with: answer, numbers: u, now: now) { refusal = nil }
            out = reading(u, key: key, now: now)
        case .failed(let failure):
            switch failure {
            case .network(let why): state = .failed(why)
            case .unexpectedReply: state = .failed("unexpected reply")
            case .signInRejected:
                state = .expired
                loginRejected = true
                out = [.considerRenew]
            case .rateLimited:
                state = .rateLimited
                backoff = min(max(backoff * 2, timing.backoffFloor), timing.backoffCap)
                nextFetch = now.addingTimeInterval(timing.poll + backoff)
            case .http(let code):
                state = .failed("HTTP \(code)")
            }
        }
        return out + [.save]
    }

    /// Whose a good reading is: the account of the key it was read with; never the folder's record. A key whose account
    /// isn't known yet: held (neither shown nor alerted) until its lookup comes back; the numbers before it, whose account
    /// is known, stay meanwhile. A key confirmed before keeps its account (a lookup outage never blanks or freezes it). At
    /// the second reading still without an account, the numbers show as "account not confirmed".
    private mutating func reading(_ u: Usage, key: String?, now: Date) -> [Action] {
        if let key, let known = profileFor == key ? loginEmail : ownerByKey[key] {
            held = nil; heldReads = 0; unconfirmed = false
            numbersKey = key; numbersOwner = known
            return take(u, now: now)
        } else if let key {
            // (a key already shown as not confirmed stays shown so, read after read)
            if !(unconfirmed && numbersKey == key) {
                heldReads = held?.key == key ? heldReads + 1 : 1
                guard heldReads >= 2 else { held = Held(usage: u, key: key); state = .ok; return [] }
            }
            held = nil
            numbersKey = key; numbersOwner = nil; unconfirmed = true
            return take(u, now: now)
        } else {
            held = nil
            numbersKey = nil; numbersOwner = nil; unconfirmed = false
            return take(u, now: now)
        }
    }

    /// A good reading kept: its credits carried on, the state ok, no backoff; the app's alerts, then the read at its reset.
    private mutating func take(_ u: Usage, now: Date) -> [Action] {
        var u = u
        let before = usage?.credits
        // a status line file has no credits: keep the last ones the endpoint gave
        u.credits = Credits.carry(u.credits, from: before, now: now) ?? (u.source == timing.endpointSource ? nil : before)
        usage = u; state = .ok; backoff = 0
        return [.numbersTaken(u, creditsBefore: before, now: now), .planResetRead(resetReadAt(now: now))]
    }

    /// The account of the key came back: it is the sign-in's address, and the account of the numbers read with that key. A
    /// reading held for it is taken now; numbers shown as "account not confirmed" are its own from now on.
    private mutating func found(_ email: String, key: String, expected: String?, now: Date) -> [Action] {
        loginEmail = email; profileFor = key
        var out = checkNewSignIn(email, expected: expected, now: now)
        ownerByKey[key] = email; lookupFails = 0; nextLookup = .distantPast
        if let h = held, h.key == key {
            held = nil; heldReads = 0
            numbersKey = key; numbersOwner = email
            out += take(h.usage, now: now)
        } else if numbersKey == key {
            numbersOwner = email                         // the numbers read with this key: its account's
            if unconfirmed, let u = usage { unconfirmed = false; out += take(u, now: now) }
        }
        return out
    }

    /// Right after the folder signed in to another account, the store can still hold the old sign-in: when the sign-in's
    /// account isn't the one the folder's record names, it is read again a few times.
    private mutating func checkNewSignIn(_ email: String, expected: String?, now: Date) -> [Action] {
        guard let at = signInChangedAt, now.timeIntervalSince(at) < timing.newSignInWindow, signInRetries < timing.newSignInRetries,
              belongs(.address(email), expected: expected) == .other else { return [] }
        signInRetries += 1
        forceLoginRead = true
        nextFetch = now.addingTimeInterval(timing.newSignInStep * TimeInterval(signInRetries))
        return [.signInNotThereYet]
    }

    /// The account lookup failed: tried again later, a little later each time.
    private mutating func lookupFailed(now: Date) {
        lookupFails += 1
        nextLookup = now.addingTimeInterval(min(timing.lookupRetry * pow(2, Double(lookupFails - 1)), timing.lookupCap))
    }

    /// A rate-limit event: its window's numbers (a fraction) taken by the rules; a rejection sets a refusal, "allowed" lifts
    /// it at once. A model's or a spend window neither sets nor lifts one.
    private mutating func rateLimit(_ e: RateLimitEvent, now: Date) -> [Action] {
        guard !stopped else { return [] }
        var u = Usage(fetchedAt: now, source: timing.endpointSource)
        var given: Set<UsageWindow> = []
        switch e.window {
        case .fiveHour: u.fiveHour = e.utilization; u.fiveHourResets = e.resetsAt; given = [.fiveHour]
        case .week: u.weekly = e.utilization; u.weeklyResets = e.resetsAt; given = [.week]
        case .scoped, .unnamed: break
        }
        if !given.isEmpty, e.utilization != nil,
           let taken = rules.take(UsageAnswer(source: .rateLimitEvent, usage: u, given: given), last: usage) {
            usage = taken
        }
        if rules.refusals != nil, let on = e.window.refusal {
            switch e.status {
            case .rejected: refusal = Refusal(until: e.resetsAt, at: now, on: on)
            case .allowed: refusal = nil
            case .warning: break
            }
        }
        return [.save]
    }
}
