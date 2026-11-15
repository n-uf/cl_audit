// Core checks for ProfileCore (Core/): compiled against the library ONLY, with Foundation and nothing of the app (no
// AppKit, SwiftUI or WidgetKit), which proves the rules need neither. The ids, the one comparison and identities without
// an id, the standby accounts and the picks, the tidy standby list, fresh and full (in both modes), times in words with a
// fixed calendar, the colour level, and parsing a sign-in item and Anthropic's replies (the signin suite's parsing
// checks, re-added here); then a lint that Core/ stays shareable; then the headline (whose numbers a headline shows: the
// split, a stale or mislabelled reading, signed out, unconfirmed, by age with both apps' thresholds). Fake data only: example.com addresses, zero-pattern
// ids, made-up tokens.
//
// Runs with HOME at Checks/.work/core/home (Checks/run.sh sets and guards it); it reads only Core/'s own sources.

import Foundation
@testable import ProfileCore

setbuf(stdout, nil)
guard NSHomeDirectory().hasSuffix("/Checks/.work/core/home") else { print("refusing: HOME is \(NSHomeDirectory())"); exit(2) }
var passed = 0, failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passed += 1 } else { failed += 1; print("FAIL (line \(line)): \(what)") }
}
func uuid(_ n: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", n) }
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
var gmt = Calendar(identifier: .gregorian); gmt.timeZone = TimeZone(identifier: "GMT")!

// ============ 1. identity: the seat comparisons ============
do {
    let a = Seat(account: uuid(1), organization: uuid(51), email: "ann@example.com")
    check(a.same(Seat(account: uuid(1), organization: uuid(51), email: "other@example.com")), "the same seat: the ids, not the address")
    let hex = Seat(account: "00000000-0000-4000-8000-0000000000ab", organization: uuid(51))      // (uuid(n) has no letters to change case)
    check(!hex.same(Seat(account: hex.account.uppercased(), organization: uuid(51))) && hex.same(Seat(account: hex.account, organization: uuid(51))),
          "Seat.same is exact: another case is another seat (as before)")
    check(!a.same(Seat(account: uuid(1), organization: uuid(52))), "another organisation: another seat")
    check(!a.same(nil) && !a.same(Seat(account: uuid(2), organization: uuid(51))), "nil or another account: not the same")
    let noOrg = Seat(account: uuid(3))
    check(!noOrg.same(Seat(account: uuid(3), organization: "")) && noOrg.same(Seat(account: uuid(3))),
          "Seat.same: no organisation (nil) isn't an empty one (as before)")
    let id = SeatID(a)
    check(id.same(a) && !SeatID(hex).same(Seat(account: hex.account.uppercased(), organization: uuid(51))) && SeatID(noOrg).organization == ""
          && SeatID(noOrg).same(noOrg) && SeatID(noOrg).same(Seat(account: uuid(3), organization: "")),
          "SeatID.same: exact ids, no organisation is \"\" (as before)")
    check(SeatID(hex).sameIgnoringCase(Seat(account: hex.account.uppercased(), organization: uuid(51))) && !id.sameIgnoringCase(Seat(account: uuid(1), organization: uuid(52)))
          && SeatID(hex).sameIgnoringCase(SeatID(account: hex.account.uppercased(), organization: uuid(51))),
          "SeatID.sameIgnoringCase: a switch reaching its account, whatever the case (as before)")
    check(AccountID.same("ABC", "abc") && !AccountID.same(nil, "abc") && AccountID.normal("AbC") == "abc"
          && AccountID.sameOrganization(nil, "") && !AccountID.sameOrganization(nil, "x"), "AccountID: the loose comparison")
    // identity: by the ids when both have one, else by address and organisation (a running process says no id)
    let fromFile = AccountIdentity(a)
    let fromProcess = AccountIdentity(account: nil, email: "ANN@example.com", organization: uuid(51), source: .verified)
    check(fromFile.source == .guessed && fromProcess.matches(fromFile) && fromFile.matches(fromProcess), "no id on one side: the address and organisation")
    check(!AccountIdentity(account: nil, email: "ann@example.com", organization: uuid(52), source: .verified).matches(fromFile), "another organisation: another account")
    check(!AccountIdentity(account: uuid(9), email: "ann@example.com", organization: uuid(51), source: .guessed).matches(fromFile),
          "both with ids: the ids decide, not the address")
    // the saved shapes stay as they were (older Dock icon copies read the same files)
    let keys = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Seat(account: "a", organization: "o", email: "e@example.com"))) as? [String: Any])?.keys.sorted()
    check(keys == ["account", "email", "organization"], "Seat's JSON keys: \(keys ?? [])")
    let idKeys = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(id)) as? [String: Any])?.keys.sorted()
    check(idKeys == ["account", "organization"], "SeatID's JSON keys: \(idKeys ?? [])")
}

// ============ 2. standby accounts: the order, the one best rule, tidy lists ============
do {
    let now = t0
    func sb(_ n: Int, seat: Bool = true, week: Double? = nil, resets: Date? = nil, used: TimeInterval? = nil) -> StandbyAccount {
        StandbyAccount(email: "s\(n)@example.com", seat: seat ? Seat(account: uuid(10 + n), organization: uuid(60 + n)) : nil,
                       addedAt: now, id: "k\(n)", lastInUse: used.map { now.addingTimeInterval(-$0) }, lastWeek: week, lastWeekResets: resets)
    }
    let full = sb(1, week: 100, resets: now.addingTimeInterval(3600))
    let light = sb(2, week: 10)
    let heavy = sb(3, week: 70)
    let unread = sb(4)
    let addressOnly = sb(5, seat: false)
    let order = AccountBook.offerOrder([full, addressOnly, unread, heavy, light], now: now).map(\.id)
    check(order == ["k2", "k3", "k4", "k1", "k5"], "the offer order: least used, then unread, full last, address-only at the end: \(order)")
    check(AccountBook.best([full, addressOnly, unread, heavy, light], now: now)?.id == "k2", "the best: the least used with a seat and room")
    check(AccountBook.best([addressOnly], now: now) == nil, "an account remembered by its address only is never the one offered")
    check(AccountBook.best([full, addressOnly], now: now) == nil, "full and address-only: nothing to offer")
    let reset = sb(6, week: 100, resets: now.addingTimeInterval(-60))
    check(!reset.knownFull(now: now) && AccountBook.best([full, reset], now: now)?.id == "k6", "a full week that started again isn't full")
    // another pick beside best: the one seen in use most recently (with a seat), whatever its numbers
    let recentFull = sb(8, week: 100, resets: now.addingTimeInterval(3600), used: 60)
    check(AccountBook.mostRecent([light, recentFull, sb(9, seat: false, used: 10), sb(10, used: 600)])?.id == "k8"
          && AccountBook.mostRecent([unread, addressOnly]) == nil, "mostRecent: seen in use most recently, full or not; never address-only")
    check(AccountBook.ago(now.addingTimeInterval(-90), now: now) == "1 min ago" && AccountBook.ago(now.addingTimeInterval(-3 * 86400), now: now) == "3 days ago"
          && AccountBook.ago(.distantPast, now: now).hasSuffix("weeks ago"), "how long ago, never a trap")
    // read with the decoder's clock: dates from the future or before 2000 are dropped, the week kept sane
    let json = #"{"id":"k9","email":"s9@example.com","addedAt":\#(now.addingTimeInterval(5 * 86400).timeIntervalSinceReferenceDate),"lastInUse":-1e12,"lastWeek":5000}"#
    let dec = JSONDecoder(); dec.userInfo[StandbyAccount.now] = now
    let read = try? dec.decode(StandbyAccount.self, from: Data(json.utf8))
    check(read?.id == "k9" && read?.addedAt == nil && read?.lastInUse == nil && read?.lastWeek == nil, "a crafted standby entry: its dates and week dropped")
    let keys = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(light)) as? [String: Any])?.keys.sorted()
    check(keys == ["addedAt", "email", "id", "lastWeek", "seat"], "StandbyAccount's JSON keys stay its own: \(keys ?? [])")
    // the tidy list: one entry per account, never an account in use
    struct P: StandbyHolder { var seat: Seat?; var name: String; var standby: [StandbyAccount]; var accountNote: AccountNote? }
    var dup = light; dup.id = "kd"; dup.seat?.account = uuid(12).uppercased(); dup.lastInUse = now
    let inUseElsewhere = sb(7)
    let profiles = [P(seat: Seat(account: uuid(1)), name: "Main", standby: [light, dup, inUseElsewhere], accountNote: nil),
                    P(seat: Seat(account: uuid(17)), name: "Work", standby: [], accountNote: nil)]
    let tidy = StandbyTidy.apply(profiles, now: now)
    check(tidy.changed && tidy.accounts[0].standby.map(\.id) == ["k2"] && tidy.accounts[0].accountNote?.kind == .tidied
          && tidy.accounts[0].standby[0].lastInUse == now, "tidied: one entry per account (any case), not another profile's in use; the newest last use kept")
    check(!StandbyTidy.apply([P(seat: nil, name: "x", standby: [light, heavy], accountNote: nil)], now: now).changed, "a tidy list stays as it is")
}

// ============ 3. limits: fresh, full, the blocker, the countdown face ============
do {
    let now = t0
    check(Freshness.isFresh(now.addingTimeInterval(-60), now: now) && !Freshness.isFresh(now.addingTimeInterval(-16 * 60), now: now)
          && !Freshness.isFresh(now.addingTimeInterval(120), now: now) && !Freshness.isFresh(nil, now: now), "fresh: the last 15 minutes, a minute ahead at most")
    check(Freshness.passed(now, now: now) && !Freshness.passed(now.addingTimeInterval(1), now: now) && !Freshness.passed(nil, now: now), "a reset that has passed")
    check(AtLimit.isFull(99.5) && !AtLimit.isFull(99.4) && !AtLimit.isFull(nil), "full: 100 as the cards round it")
    check(AtLimit.holding(100, nil, now: now) && !AtLimit.holding(100, now, now: now), "holding: full and not reset (an unknown reset holds)")
    let later = now.addingTimeInterval(7200), sooner = now.addingTimeInterval(600)
    check(AtLimit.blocker(fiveHour: 100, fiveHourResets: sooner, weekly: 100, weeklyResets: later, now: now) == FullLimit(kind: .week, resets: later, alsoFull: .fiveHour),
          "both full: the one that resets last holds it back")
    check(AtLimit.blocker(fiveHour: 100, fiveHourResets: later, weekly: 100, weeklyResets: later, now: now)?.kind == .week, "a tie: the week")
    check(AtLimit.blocker(fiveHour: 100, fiveHourResets: nil, weekly: 100, weeklyResets: later, now: now) == FullLimit(kind: .fiveHour, resets: nil, alsoFull: .week),
          "an unknown reset counts as last")
    check(AtLimit.blocker(fiveHour: 40, fiveHourResets: nil, weekly: 99, weeklyResets: nil, now: now) == nil, "nothing full: no blocker")
    check(FullLimit(kind: .fiveHour, resets: now.addingTimeInterval(102 * 60)).minutesLeft(now) == 102 && FullLimit(kind: .week, resets: nil).minutesLeft(now) == nil,
          "the full limit's minutes left (the words are each app's)")
    // full in two modes: acts (fresh numbers only) and display (dated, the reset still ahead, however old)
    let ahead = now.addingTimeInterval(3600)
    check(AtLimit.full(100, resets: ahead, readAt: now.addingTimeInterval(-120), mode: .acts(freshFor: 300), now: now)
          && !AtLimit.full(100, resets: ahead, readAt: now.addingTimeInterval(-600), mode: .acts(freshFor: 300), now: now)
          && AtLimit.full(100, resets: nil, readAt: now, mode: .acts(freshFor: 300), now: now), "acts: only fresh numbers (the threshold the caller's)")
    check(AtLimit.full(100, resets: ahead, readAt: now.addingTimeInterval(-86400), mode: .display, now: now)
          && !AtLimit.full(100, resets: nil, readAt: now, mode: .display, now: now)
          && !AtLimit.full(100, resets: now.addingTimeInterval(-1), readAt: now, mode: .display, now: now)
          && !AtLimit.full(90, resets: ahead, readAt: now, mode: .display, now: now), "display: dated and still ahead; a dateless 100% doesn't count")
    check(Freshness.isFresh(now.addingTimeInterval(-200), now: now, within: 300) && !Freshness.isFresh(now.addingTimeInterval(-400), now: now, within: 300),
          "freshness: the window is the caller's")
    let u = Usage(fiveHour: 30, fiveHourResets: now.addingTimeInterval(-1), weekly: 60, weeklyResets: now.addingTimeInterval(86400), fetchedAt: now,
                  source: "Anthropic", scoped: [ScopedLimit(name: "Fable", percent: 40, resets: now.addingTimeInterval(-5))]).current(now: now)
    check(u.fiveHour == nil && u.weekly == 60 && u.scoped.first?.percent == nil && u.scoped.first?.key == "mfable", "a passed reset's percent goes")
    let c = Credits(enabled: true, used: 4.2, cap: 50, currency: "USD", out: false)
    check(c.inUse(fiveHour: 100, weekly: 10, now: now) && !c.inUse(fiveHour: 10, weekly: 10, now: now) && c.money(4.2) == "$4.20",
          "credits: in use at a full limit, the amount")
    check(Credits.carry(Credits(enabled: true, used: 5, cap: nil, currency: nil, out: false), from: c, now: now)?.spentAt == now, "credits: an amount that went up")
}

// ============ 4. times in words (a fixed calendar), and the level ============
do {
    let now = gmt.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 10, minute: 0))!
    let today = now.addingTimeInterval(5 * 3600 + 28 * 60)
    check(TimeWords.when(today, now: now, calendar: gmt) == "15:28" && TimeWords.back(today, now: now, calendar: gmt) == "back at 15:28", "today: the time")
    let sunday = gmt.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 13, minute: 0))!
    check(TimeWords.when(sunday, now: now, calendar: gmt) == "Sun 13:00" && TimeWords.back(sunday, now: now, calendar: gmt) == "back Sun 13:00", "within six days: the weekday")
    let nextMonth = gmt.date(from: DateComponents(year: 2026, month: 12, day: 24, hour: 9))!
    check(TimeWords.when(nextMonth, now: now, calendar: gmt) == "24 Dec", "further this year: the date")
    check(TimeWords.when(gmt.date(from: DateComponents(year: 2027, month: 1, day: 12))!, now: now, calendar: gmt) == "12 Jan 2027", "another year")
    // another system calendar: the words stay Gregorian (en_US_POSIX gave Gregorian before); only the time zone is the caller's
    for id in [Calendar.Identifier.buddhist, .japanese, .islamicUmmAlQura] {
        var other = Calendar(identifier: id); other.timeZone = TimeZone(identifier: "GMT")!
        let next = gmt.date(from: DateComponents(year: 2027, month: 1, day: 12))!
        // (whether the year is written follows the caller's calendar, as before: 12 Jan 2027 is still 1448 in the Hijri one)
        let words = TimeWords.when(next, now: now, calendar: other)
        check((words == "12 Jan 2027" || (id == .islamicUmmAlQura && words == "12 Jan")) && TimeWords.when(nextMonth, now: now, calendar: other) == "24 Dec"
              && TimeWords.when(today, now: now, calendar: other) == "15:28", "a \(id) calendar: Gregorian words (\(words))")
    }
    var tokyo = gmt; tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    check(TimeWords.when(today, now: now, calendar: tokyo) == "Sat 00:28", "the time zone is the caller's: \(TimeWords.when(today, now: now, calendar: tokyo))")
    check(TimeWords.countdown(now.addingTimeInterval(30), now: now) == "1m" && TimeWords.countdown(now.addingTimeInterval(102 * 60), now: now) == "1h 42m"
          && TimeWords.countdown(now.addingTimeInterval(3 * 86400 + 3600), now: now) == "3d 1h" && TimeWords.countdown(now.addingTimeInterval(16 * 86400), now: now) == "16 days",
          "the countdown's forms")
    let cases: [(Double?, Bool, Level)] = [(nil, false, .none), (40, true, .none), (49.9, false, .green), (50, false, .amber), (79.9, false, .amber),
                                            (80, false, .red), (94.4, false, .red), (94.5, false, .crimson), (100, false, .crimson)]
    for (p, stale, want) in cases { check(Level.of(p, stale: stale) == want, "level of \(String(describing: p)) (stale \(stale)): \(want)") }
}

// ============ 5. parsing: a sign-in item, Anthropic's replies ============
do {
    let item = #"{"claudeAiOauth":{"accessToken":"sk-test-token","expiresAt":1800000000000,"subscriptionType":"max"}}"#
    if case let .token(t, exp, plan) = Login.parse(Data(item.utf8)) {
        check(t == "sk-test-token" && exp == Date(timeIntervalSince1970: 1_800_000_000) && plan == "max", "a sign-in item: its token, expiry and plan")
    } else { check(false, "a sign-in item is read") }
    let hex = item.utf8.map { String(format: "%02x", $0) }.joined()
    if case .token(let t, _, _) = Login.parse(Data((hex + "\n").utf8)) { check(t == "sk-test-token", "hex output (security -w prints hex for non-text)") }
    else { check(false, "hex output is read") }
    for (what, out) in [("empty", ""), ("not JSON", "hello"), ("no token", #"{"claudeAiOauth":{}}"#), ("an empty token", #"{"claudeAiOauth":{"accessToken":""}}"#),
                        ("odd hex", "abc")] {
        if case .unreadable = Login.parse(Data(out.utf8)) { check(true, what) } else { check(false, "\(what): unreadable") }
    }
    check(Login.decode(Data("7b7d".utf8)) == Data("{}".utf8), "hex decodes")

    let reply = #"{"five_hour":{"utilization":7,"resets_at":"2099-01-01T00:00:00.000Z"},"seven_day":{"utilization":64,"resets_at":1800000000},"#
        + #""limits":[{"kind":"weekly_scoped","percent":40,"resets_at":"2099-01-02T00:00:00Z","scope":{"model":{"display_name":"Fable"}}},{"kind":"session"}],"#
        + #""spend":{"enabled":true,"used":{"amount_minor":420,"currency":"USD","exponent":2},"limit":{"amount_minor":5000}}}"#
    let u = UsageParser.fromAPI(Data(reply.utf8), now: t0, source: "test source")
    check(u?.fiveHour == 7 && u?.weekly == 64 && u?.weeklyResets == Date(timeIntervalSince1970: 1_800_000_000) && u?.fetchedAt == t0
          && u?.source == "test source" && u?.noFiveHour == false, "the usage reply: both limits, a numeric reset, the caller's source name")
    check(u?.scoped == [ScopedLimit(name: "Fable", percent: 40, resets: UsageParser.date("2099-01-02T00:00:00Z"))], "a model's own weekly limit")
    check(u?.credits?.used == 4.2 && u?.credits?.cap == 50 && u?.credits?.enabled == true, "usage credits (spend)")
    let ultra = #"{"limits":[{"type":"seven_day","percent":12,"resets_at":"2099-01-01T00:00:00Z","kind":"weekly"}]}"#
    let v = UsageParser.fromAPI(Data(ultra.utf8), source: "test source")
    check(v?.weekly == 12 && v?.fiveHour == nil && v?.noFiveHour == true, "the limits[] variant, a plan with no 5-hour limit (Ultra)")
    check(UsageParser.fromAPI(Data("{}".utf8), source: "t") == nil && UsageParser.fromAPI(Data("nope".utf8), source: "t") == nil, "no limit or not JSON: nothing")
    check(UsageParser.date(1_800_000_000_000 as NSNumber) == Date(timeIntervalSince1970: 1_800_000_000) && UsageParser.date("2099-01-01T00:00:00.5Z") != nil,
          "dates: milliseconds, seconds, ISO with a fraction")
    check(UsageParser.percent(["used_percentage": 33]) == 33 && UsageParser.percent([:]) == nil, "the percent under its several names")
    let profile = #"{"account":{"uuid":"x","email_address":"ann@example.com"},"organization":{"name":"o"}}"#
    check(UsageParser.email(Data(profile.utf8)) == "ann@example.com" && UsageParser.email(Data(#"{"a":[{"email":"no-at"}]}"#.utf8)) == nil,
          "the profile reply's address, wherever it sits")
    let keys = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Credits(enabled: true, used: 1, cap: nil, currency: "USD", out: false))) as? [String: Any])?.keys.sorted()
    check(keys == ["currency", "enabled", "out", "used"], "Credits' JSON keys: \(keys ?? [])")
}

// ============ 6. the library stays shareable: Foundation only, no app's paths, files, words or state ============
do {
    let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Core")
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: core.path)) ?? []).filter { $0.hasSuffix(".swift") }.sorted()
    var found: [String] = []
    for f in files {
        let lines = ((try? String(contentsOf: core.appendingPathComponent(f), encoding: .utf8)) ?? "").components(separatedBy: "\n")
        for (i, l) in lines.enumerated() {
            let code = l.components(separatedBy: "//").first ?? ""        // comments may name things; code may not
            if l.hasPrefix("import "), !["import Foundation", "import CryptoKit", "import os"].contains(l) { found.append("\(f):\(i + 1) \(l)") }
            for bad in ["usage-n-uf", "status/", "accounts.json", "config.json", "Privacy", "UserDefaults", "NSWorkspace", "NSRunningApplication",
                        "FileManager", "contentsOf:", "static var ", "nonisolated(unsafe)"] where code.contains(bad) {
                found.append("\(f):\(i + 1) \(bad)")
            }
            // an app's words for a full limit and its source stay in the app (the data stays here)
            for bad in ["reset time unknown", "\"in \"", "\"5-hour\"", "\"Week\"", "\"Anthropic\""] where code.contains(bad) {
                found.append("\(f):\(i + 1) \(bad)")
            }
            // nor do comments name an app's screens or files
            for bad in ["▸", "receipt", "Dock", "Settings"] where l.contains(bad) { found.append("\(f):\(i + 1) \(bad) (comment)") }
        }
    }
    check(files.count >= 5 && found.isEmpty, "Core/ (\(files.count) files): Foundation only, no app paths, files, wording or global state: \(found)")
}

// ============ 7. the headline: whose numbers a headline may show, and how ============
do {
    let now = t0
    func who(_ n: Int?, _ email: String?, org: String? = nil, _ source: AccountIdentity.Source = .guessed) -> AccountIdentity {
        AccountIdentity(account: n.map(uuid), email: email, organization: org, source: source)
    }
    let pat = who(2, "pat@example.com"), mo = who(3, "mo@example.com")
    // cl_audit's thresholds (fresh for the read interval plus a minute, never hidden, a last-known full left out) and
    // cl_quick's (under 5 minutes fresh, last known to an hour with a dated full kept, hidden after)
    let audit = Headline.Ages(freshFor: 6 * 60), quick = Headline.Ages(freshFor: 5 * 60, hiddenAfter: 3600, datedFullStays: true)
    let ahead = now.addingTimeInterval(3600)
    func answer(_ o: Headline.Owner, signedIn: Bool = true, age: TimeInterval? = 60, ages: Headline.Ages = audit) -> Headline.Answer {
        Headline.of(o, signedIn: signedIn, readAt: age.map { now.addingTimeInterval(-$0) }, now: now, ages: ages)
    }
    func limit(_ a: Headline.Answer, _ p: Double?, _ resets: Date? = nil, age: TimeInterval = 60, split: Bool = true) -> Headline.Limit? {
        a.limit(p, resets: resets, readAt: now.addingTimeInterval(-age), split: split, now: now)
    }

    // the profile's own numbers: shown, the plan, and they act
    let own = answer(Headline.Owner(signIn: mo, reading: mo))
    check(own.split == nil && !own.otherReading && own.numbers() && own.plan() && own.readTime && own.acts
          && limit(own, 100, ahead) == Headline.Limit(percent: 100, resets: ahead, lastKnown: false), "the profile's own fresh numbers: shown, full acts")

    // the split, as a resolver decided it (cl_audit) and as compared here (cl_quick)
    let decided = answer(Headline.Owner(inUse: pat, signIn: mo, differs: true, switchWaits: true))
    check(decided.split == Headline.Split(switchWaits: true) && !decided.numbers() && !decided.plan() && decided.readTime
          && limit(decided, 40) == nil, "the split (decided): no numbers, no plan, its read time; the switch waiting carried")
    check(decided.numbers(split: false) && decided.plan(split: false) && limit(decided, 40, split: false)?.percent == 40,
          "…the sign-in's own numbers for its labelled line (split false)")
    check(answer(Headline.Owner(inUse: pat, signIn: pat, differs: true)).split != nil && answer(Headline.Owner(inUse: pat, signIn: mo, differs: false)).split == nil,
          "a decided answer wins over the identities")
    check(answer(Headline.Owner(inUse: pat, signIn: mo)).split == Headline.Split(switchWaits: false)
          && answer(Headline.Owner(inUse: pat, signIn: who(2, "other@example.com"))).split == nil, "compared here: by the ids when both have one")
    check(answer(Headline.Owner(inUse: who(2, "pat@example.com", org: uuid(51)), signIn: who(5, "pat@example.com", org: uuid(51)))).split != nil,
          "both ids known: the ids decide, even on one address (a personal plan and a team seat)")
    let process = who(nil, "Pat@example.com", org: uuid(51), .verified)
    check(answer(Headline.Owner(inUse: who(2, "pat@example.com", org: uuid(51)), signIn: process)).split == nil
          && answer(Headline.Owner(inUse: who(2, "pat@example.com", org: uuid(52)), signIn: process)).split != nil
          && answer(Headline.Owner(inUse: mo, signIn: process)).split != nil,
          "an identity without an id (a running process's): by address (any case) and organisation")
    check(answer(Headline.Owner(inUse: nil, signIn: mo, differs: true)).split == nil && answer(Headline.Owner(inUse: pat, signIn: nil, differs: true)).split == nil,
          "no account in use apart from the sign-in, or no sign-in: no split")
    check(answer(Headline.Owner(inUse: pat, signIn: mo, differs: true, elsewhere: true)).split == nil,
          "the sign-in on another profile's account in use: its numbers are that profile's, no split here")

    // numbers whose account couldn't be confirmed: as read, never full, and they decide no split
    let unsure = answer(Headline.Owner(inUse: pat, signIn: mo, differs: true, unconfirmed: true))
    check(unsure.split == nil && unsure.numbers() && !unsure.acts && limit(unsure, 100, ahead) == nil && limit(unsure, 70)?.percent == 70,
          "unconfirmed: no split, numbers as read, a full one left out")
    check(limit(answer(Headline.Owner(unconfirmed: true), ages: quick), 100, ahead) == Headline.Limit(percent: 100, resets: ahead, lastKnown: true),
          "…kept dated full limits (cl_quick's): as last known, never as acting")

    // another reading: stale, or labelled for another account than it was read for
    let stale = answer(Headline.Owner(reading: mo, readStale: true))
    check(stale.otherReading && !stale.numbers() && !stale.numbers(split: false) && !stale.plan(split: false) && !stale.readTime,
          "a stale reading: no numbers anywhere, no plan, no read time")
    let mislabelled = answer(Headline.Owner(reading: who(nil, "mo@example.com"), label: who(nil, "pat@example.com")))
    check(mislabelled.otherReading && !mislabelled.numbers(), "labelled for another account than it was read for: none")
    check(!answer(Headline.Owner(reading: who(nil, "MO@example.com"), label: who(nil, "mo@example.com"))).otherReading
          && !answer(Headline.Owner(reading: nil, label: who(nil, "mo@example.com"))).otherReading, "the same address in another case, or no reading named: its own")

    // signed out or expired: no numbers at all, the plan stays
    let out = answer(Headline.Owner(), signedIn: false)
    check(!out.numbers() && !out.numbers(split: false) && out.plan() && out.readTime && limit(out, 30) == nil, "signed out: no numbers, the plan and the read time stay")

    // by age, cl_audit's thresholds: fresh for 6 minutes; then last known, a full limit left out; never hidden
    check(answer(Headline.Owner(), age: 5 * 60).acts && limit(answer(Headline.Owner(), age: 5 * 60), 100, ahead)?.percent == 100, "5 minutes old: acts")
    let audOld = answer(Headline.Owner(), age: 7 * 60)
    check(audOld.age == .lastKnown && !audOld.acts && limit(audOld, 100, ahead, age: 7 * 60) == nil
          && limit(audOld, 60, ahead, age: 7 * 60) == Headline.Limit(percent: 60, resets: ahead, lastKnown: true), "7 minutes old: last known, a full limit left out")
    check(answer(Headline.Owner(), age: 2 * 86400).numbers() && answer(Headline.Owner(), age: nil).age == .undated && answer(Headline.Owner(), age: nil).acts,
          "never hidden by age (cl_audit's); undated numbers act")
    // cl_quick's: under 5 minutes fresh, to an hour last known (a dated full stays grey until its reset), hidden after
    let q10 = answer(Headline.Owner(), age: 10 * 60, ages: quick)
    check(q10.age == .lastKnown && limit(q10, 100, ahead, age: 10 * 60) == Headline.Limit(percent: 100, resets: ahead, lastKnown: true)
          && limit(q10, 100, nil, age: 10 * 60) == nil, "cl_quick's 10 minutes: a dated full stays as last known; a dateless 100% doesn't")
    check(!answer(Headline.Owner(), age: 2 * 3600, ages: quick).numbers() && answer(Headline.Owner(), age: 2 * 3600, ages: quick).age == .hidden,
          "cl_quick's over an hour: hidden")

    // a limit whose reset has passed: no percent, no reset (the one rule, Freshness.current)
    check(limit(own, 55, now.addingTimeInterval(-1)) == Headline.Limit(percent: nil, resets: nil, lastKnown: false)
          && Freshness.current(55, resets: now, now: now).percent == nil && Freshness.current(55, resets: now, now: now).resets == nil
          && Freshness.current(55, resets: ahead, now: now).percent == 55 && Freshness.current(55, resets: ahead, now: now).resets == ahead
          && ScopedLimit(name: "Fable", percent: 9, resets: now).current(now: now) == ScopedLimit(name: "Fable", percent: nil, resets: nil),
          "a reset that has passed: no percent and no reset, a model's limit keeps its name")
}

// ============ 8. the display: one "what to show" value per profile ============
do {
    let now = t0
    func who(_ n: Int?, _ email: String?) -> AccountIdentity { AccountIdentity(account: n.map(uuid), email: email, organization: nil, source: .guessed) }
    let pat = who(2, "pat@example.com"), mo = who(3, "mo@example.com")
    // cl_audit's thresholds (fresh 6 minutes, grey after 30) and cl_quick's (fresh 5, grey once last known, hidden after an hour)
    let audit = Headline.Ages(freshFor: 6 * 60, greyAfter: 30 * 60)
    let quick = Headline.Ages(freshFor: 5 * 60, hiddenAfter: 3600, datedFullStays: true)
    let ahead = now.addingTimeInterval(3600)
    func read(_ week: Double?, five: Double? = 12, age: TimeInterval = 60, resets: Date? = nil) -> Usage {
        Usage(fiveHour: five, fiveHourResets: ahead, weekly: week, weeklyResets: resets ?? ahead,
              fetchedAt: now.addingTimeInterval(-age), source: "test")
    }
    func make(_ u: Usage?, sign: ProfileDisplay.SignIn = .ok, other: Bool = false, inUse: Bool = true, ages: Headline.Ages = audit,
              note: String? = nil) -> ProfileDisplay {
        makeFor(Headline.Owner(), u, sign: sign, other: other, inUse: inUse, note: note, ages: ages)
    }
    func makeFor(_ o: Headline.Owner, _ u: Usage?, sign: ProfileDisplay.SignIn = .ok, other: Bool = false, inUse: Bool = true,
              clash: ProfileDisplay.Clash? = nil, note: String? = nil, splitTo: String? = nil, ages: Headline.Ages = audit) -> ProfileDisplay {
        let a = Headline.of(o, signedIn: sign != .expired && sign != .signedOut, readAt: u?.fetchedAt, now: now, ages: ages)
        return ProfileDisplay.make(a, read: u, sign: sign, otherAccount: other, inUse: inUse, clash: clash, note: note, splitTo: splitTo,
                                   ages: ages, now: now)
    }

    // the profile's own fresh numbers: shown, full acts, lit, no key, the caller's line
    let own = make(read(100), note: "a line")
    check(own.usage?.weekly == 100 && own.none == nil && own.tier == .fresh && own.full == FullLimit(kind: .week, resets: ahead)
          && own.lamp && own.key == nil && own.line == .given("a line") && !own.grey && own.readAt == now.addingTimeInterval(-60),
          "fresh: the numbers, the full week, the lamp lit, no key, the caller's line")
    check(own.level(60) == .amber && own.level(96) == .crimson, "the level, as the shared rule")

    // the tiers: last known (a full one left out, nothing full), grey past greyAfter; cl_quick's grey at once, hidden after an hour
    let known = make(read(100, age: 10 * 60))
    check(known.tier == .lastKnown && known.usage?.weekly == nil && known.usage?.fiveHour == 12 && known.full == nil && !known.grey,
          "10 minutes (cl_audit's): last known, the full week left out, nothing full, not grey")
    let grey = make(read(40, age: 31 * 60))
    check(grey.tier == .stale && grey.grey && grey.usage?.weekly == 40 && grey.level(40) == .none && grey.full == nil,
          "31 minutes (cl_audit's): grey, the numbers kept, their level none")
    let q10 = make(read(100, age: 10 * 60), ages: quick)
    check(q10.tier == .stale && q10.usage?.weekly == 100 && q10.full == nil, "10 minutes (cl_quick's): grey at once, a dated full kept but never acting")
    let low = Headline.Ages(freshFor: 6 * 60, greyAfter: 60)
    check(make(read(40, age: 3 * 60), ages: low).tier == .fresh && make(read(40, age: 7 * 60), ages: low).tier == .stale,
          "a greyAfter below freshFor counts as freshFor: never grey while fresh, grey once last known")
    check(own.full(now: now) == own.full && own.full(now: ahead) == nil && own.full(now: ahead.addingTimeInterval(-1)) != nil,
          "full(now:): the full limit until its reset passes, drawn later")
    let qOld = make(read(40, age: 2 * 3600), ages: quick)
    check(qOld.usage == nil && qOld.none == .hidden && qOld.tier == .stale && qOld.grey, "two hours (cl_quick's): hidden")

    // the split: no numbers, the account in use's lamp, the key to it (not while a switch waits, not without its address)
    let splitOwner = Headline.Owner(inUse: pat, signIn: mo, differs: true)
    let split = makeFor(splitOwner, read(100), note: "Usage: Claude Code on mo", splitTo: "pat@example.com")
    check(split.usage == nil && split.none == .split && split.full == nil && split.lamp && split.key == .logInCode(to: "pat@example.com")
          && split.line == .split(Headline.Split(switchWaits: false)) && split.split != nil && split.grey,
          "the split: no numbers, nothing full, lit, the key to the account in use, the split's line over the caller's")
    check(makeFor(Headline.Owner(inUse: pat, signIn: mo, differs: true, switchWaits: true), read(100), splitTo: "pat@example.com").key == nil
          && makeFor(splitOwner, read(100)).key == nil, "a switch waiting for the other app, or no address: no key")
    check(makeFor(splitOwner, read(100), sign: .expired, splitTo: "pat@example.com").key == .logIn
          && makeFor(splitOwner, read(100), sign: .expired).lamp, "the split with the sign-in run out: Log in first; the lamp stays the account in use's")

    // signed out, expired, unreadable, another account: the key and the lamp
    let out = make(read(40), sign: .signedOut), exp = make(read(40), sign: .expired)
    check(out.usage == nil && out.none == .signedOut && out.key == .logIn && !out.lamp && out.needsLogin
          && exp.none == .expired && exp.key == .logIn && !exp.lamp, "signed out or expired: no numbers, why, Log in, the lamp off")
    let unread = make(read(40), sign: .unreadable)
    check(unread.usage?.weekly == 40 && unread.key == nil && !unread.lamp, "a sign-in that can't be read: the numbers as read, no key, the lamp off")
    let other = make(read(40), other: true)
    check(other.key == .logIn && !other.lamp && other.otherAccount, "the sign-in on another account than the folder's: Log in, the lamp off")
    check(!make(read(40), inUse: false).lamp, "no account in use known: no lamp")

    // the clash: carried with the other profile's id, the lamp off; unconfirmed: said first, never full
    let clash = makeFor(Headline.Owner(inUse: pat, signIn: mo, differs: true, elsewhere: true), read(40), clash: ProfileDisplay.Clash(id: "home", name: "Home"))
    check(clash.clash == ProfileDisplay.Clash(id: "home", name: "Home") && !clash.lamp && clash.split == nil && clash.key == .logIn && clash.needsLogin,
          "another profile's account: the clash by id, no split, the lamp off, the one key Log in (to the profile's own account)")
    let unsure = makeFor(Headline.Owner(inUse: pat, signIn: mo, differs: true, unconfirmed: true), read(100), note: "a line")
    check(unsure.usage?.fiveHour == 12 && unsure.usage?.weekly == nil && unsure.full == nil && unsure.line == .unconfirmed,
          "unconfirmed: as read, never full, said first")

    // resets that have passed, nothing read, another reading
    let past = make(read(100, resets: now.addingTimeInterval(-1)))
    check(past.usage?.weekly == nil && past.usage?.weeklyResets == nil && past.usage?.fiveHour == 12 && past.full == nil,
          "the week's reset passed: no percent, no reset, nothing full")
    let empty = make(read(40, five: nil, resets: now.addingTimeInterval(-1)))
    check(empty.usage == nil && empty.none == .notRead, "every limit's reset passed: no numbers (nothing left)")
    check(make(nil).none == .notRead && make(nil).tier == .fresh && make(nil).grey, "nothing read: no numbers, grey")
    let stale = makeFor(Headline.Owner(reading: mo, readStale: true), read(40))
    check(stale.usage == nil && stale.none == .otherReading && stale.readAt == nil, "another reading: no numbers, no read time")
}

print("core checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
