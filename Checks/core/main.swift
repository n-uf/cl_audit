// Core checks for ProfileCore (Core/): compiled against the library ONLY, with Foundation and nothing of the app (no
// AppKit, SwiftUI or WidgetKit), which proves the rules need neither. The ids, the one comparison and identities without
// an id, the standby accounts and the picks, the tidy standby list, fresh and full (in both modes), times in words with a
// fixed calendar, the colour level, and parsing a sign-in item and Anthropic's replies (the signin suite's parsing
// checks, re-added here); then a lint that Core/ stays shareable; then the headline (whose numbers a headline shows: the
// split, a stale or mislabelled reading, signed out, unconfirmed, by age with both apps' thresholds); the display; and the
// reader as a state machine (events in, actions out: the sign-in read, expired, rejected, busy, a held reading, the
// account lookup, the folder signed in to another account mid-read, the one other-account rule, renewals, cl_quick's
// reading rules). Fake data only: example.com addresses, zero-pattern
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
    // the one owner rule (sameAccount): matches, with one side known by its address only matched by the address
    let typed = AccountIdentity.address("ANN@example.com")
    check(typed.addressOnly && !fromFile.addressOnly && !fromProcess.addressOnly && typed.sameAccount(fromFile) && fromFile.sameAccount(typed),
          "an address only (no id, no organisation): the address decides, any case, either side")
    check(!AccountIdentity.address("").sameAccount(.address("")) && !AccountIdentity.address(nil).sameAccount(fromFile), "no address: never the same")
    check(AccountIdentity(hex).sameAccount(AccountIdentity(Seat(account: hex.account.uppercased(), organization: uuid(51).uppercased()))),
          "ids differing only by case: one account")
    check(!AccountIdentity(a).sameAccount(AccountIdentity(Seat(account: uuid(1), organization: uuid(52), email: a.email))),
          "the same address in another organisation (both ids): another account")
    check(noOrg.sameAccount(Seat(account: uuid(3), organization: "")) && !noOrg.same(Seat(account: uuid(3), organization: "")),
          "no organisation (nil) and an empty one: one account by the owner rule (Seat.same stays exact)")
    check(!a.sameAccount(Seat(account: uuid(9), organization: uuid(51), email: a.email)) && !a.sameAccount(nil),
          "both ids present but different: another account, never the address")
    check(!fromProcess.sameAccount(AccountIdentity(account: nil, email: "ann@example.com", organization: uuid(52), source: .guessed)),
          "an address with an organisation isn't address-only: the organisation counts")
    check(AccountIdentity(Seat(account: "", email: "ann@example.com")).addressOnly, "an empty id is none")
    let byAddress = StandbyAccount(email: "Ann@example.com", id: "q1"), seated = StandbyAccount(email: "", seat: Seat(account: uuid(1), organization: uuid(51)), id: "q2")
    check(byAddress.identity.addressOnly && AccountIdentity(a).sameAccount(byAddress.identity) && seated.identity.sameAccount(AccountIdentity(a))
          && seated.identity.email == "" && StandbyAccount(email: "x@example.com", seat: Seat(account: uuid(1)), id: "q3").identity.email == "x@example.com",
          "a standby entry's identity: its seat (the entry's address when the seat has none), else its address only")
    check(AccountIdentity(a).withoutOrganization.sameAccount(AccountIdentity(account: uuid(1).uppercased(), email: nil, organization: nil, source: .verified))
          && !AccountIdentity(a).sameAccount(AccountIdentity(account: uuid(1), email: nil, organization: nil, source: .verified)),
          "an id named without an organisation: compared with the seat's left out (withoutOrganization)")
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
    // two entries of one account, one with an organisation and one without: the merge never swaps the known one for none
    // (no record organisation, nil == nil), whichever is newer; a newer one with another organisation still wins
    func merged(_ a: StandbyAccount, _ b: StandbyAccount, orgs: [String: String] = [:]) -> Seat? {
        StandbyTidy.apply([P(seat: nil, name: "x", standby: [a, b], accountNote: nil)], recordOrgs: { orgs }, now: now).accounts[0].standby.first?.seat
    }
    func entry(_ id: String, org: String?, used: TimeInterval) -> StandbyAccount {
        StandbyAccount(email: "m@example.com", seat: Seat(account: uuid(40), organization: org, email: "m@example.com"), id: id,
                       lastInUse: now.addingTimeInterval(-used))
    }
    let withOrgOld = entry("a", org: uuid(41), used: 600), noOrgNew = entry("b", org: nil, used: 60), emptyOrgNew = entry("c", org: "", used: 60)
    check(merged(withOrgOld, noOrgNew)?.organization == uuid(41) && merged(withOrgOld, emptyOrgNew)?.organization == uuid(41)
          && merged(noOrgNew, withOrgOld)?.organization == uuid(41),
          "a newer entry with no organisation (nil or \"\") never takes the place of a known one; an older known one replaces none")
    check(merged(withOrgOld, entry("d", org: uuid(42), used: 60))?.organization == uuid(42)
          && merged(entry("e", org: uuid(42), used: 60), withOrgOld, orgs: [uuid(40): uuid(41)])?.organization == uuid(41),
          "a newer one with another organisation still wins; the record's organisation wins over any")
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
        // (whether the year is written follows the caller's calendar, as before: `now` (13 Nov 2026) and 12 Jan 2027 are both 1448 in the
        // Hijri one, so only that calendar writes "12 Jan"; the Buddhist and Japanese years turn on 1 Jan, so they write "12 Jan 2027")
        let words = TimeWords.when(next, now: now, calendar: other)
        check(words == (id == .islamicUmmAlQura ? "12 Jan" : "12 Jan 2027") && TimeWords.when(nextMonth, now: now, calendar: other) == "24 Dec"
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
    check(UsageParser.accountID(Data(profile.utf8)) == "x" && UsageParser.accountID(Data(#"{"account":{"uuid":""}}"#.utf8)) == nil
          && UsageParser.accountID(Data(#"{"organization":{"uuid":"o"}}"#.utf8)) == nil,
          "the profile reply's account id: account.uuid only (never the organisation's), none when empty")
    check(UsageParser.organizationID(Data(#"{"account":{"uuid":"x"},"organization":{"uuid":"o-1","name":"o"}}"#.utf8)) == "o-1"
          && UsageParser.organizationID(Data(profile.utf8)) == nil && UsageParser.organizationID(Data(#"{"organization":{"uuid":""}}"#.utf8)) == nil
          && UsageParser.organizationID(Data(#"{"account":{"uuid":"a"}}"#.utf8)) == nil,
          "the profile reply's organisation id: organization.uuid only (never the account's), none when empty or missing")
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
            if l.hasPrefix("import "), l != "import Foundation" { found.append("\(f):\(i + 1) \(l)") }
            for bad in ["usage-n-uf", "status/", "accounts.json", "config.json", "Privacy", "UserDefaults", "NSWorkspace", "NSRunningApplication",
                        "FileManager", "contentsOf:", "static var ", "nonisolated(unsafe)"] where code.contains(bad) {
                found.append("\(f):\(i + 1) \(bad)")
            }
            // an app's words for a full limit and its source stay in the app (the data stays here)
            for bad in ["reset time unknown", "\"in \"", "\"5-hour\"", "\"Week\"", "\"Anthropic\""] where code.contains(bad) {
                found.append("\(f):\(i + 1) \(bad)")
            }
            // nor do comments name an app's screens or files ("alert" stays allowed: whether numbers call for one is Core's data)
            for bad in ["▸", "receipt", "Dock", "Settings"] where l.contains(bad) { found.append("\(f):\(i + 1) \(bad) (comment)") }
            // (card and menu as whole words: "@discardableResult" or "discard" are no screen)
            if l.range(of: #"\b[Cc]ards?\b|\b[Mm]enus?\b"#, options: .regularExpression) != nil { found.append("\(f):\(i + 1) card or menu (comment)") }
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

// ============ 9. the reader as a state machine: events in, actions out (no Keychain, no network, no clock) ============
do {
    let mo = Seat(account: uuid(61), organization: uuid(71), email: "mo@example.com")
    let pat = Seat(account: uuid(62), organization: uuid(71), email: "pat@example.com")
    func machine(_ linked: Seat? = mo, rules: ReadingRules = .clAudit) -> ReaderMachine {
        ReaderMachine(rules: rules, timing: ReaderMachine.Timing(poll: 300, endpointSource: "endpoint"), linked: linked, firstFetch: t0)
    }
    func use(five: Double? = nil, week: Double? = nil, at: Date, resets: Date? = nil, source: String = "endpoint") -> Usage {
        Usage(fiveHour: five, fiveHourResets: five == nil ? nil : resets ?? at.addingTimeInterval(3600), weekly: week,
              weeklyResets: week == nil ? nil : resets ?? at.addingTimeInterval(86400), fetchedAt: at, source: source)
    }
    func endpoint(_ u: Usage) -> UsageAnswer { UsageAnswer(source: .usageEndpoint, usage: u) }
    func tick(_ m: inout ReaderMachine, _ now: Date, line: Usage? = nil) -> [ReaderMachine.Action] {
        m.handle(.tick(now: now, statusLine: line, folderThere: true))
    }
    func req(_ key: String, _ gen: Int = 0, _ at: Date = t0) -> ReaderMachine.Request { .init(key: key, generation: gen, asked: at) }
    let token = SignInRead.token(key: "k1", expiresAt: t0.addingTimeInterval(8 * 3600), plan: "max")

    // the record keeps the state's description: its words are data
    check("\(FetchState.failed("HTTP 500"))" == #"failed("HTTP 500")"# && "\(FetchState.rateLimited)" == "rateLimited"
          && "\(FetchState.noLogin)" == "noLogin" && "\(FetchState.ok)" == "ok", "FetchState's descriptions are the record's words, unchanged")

    // a first read: the sign-in read (the token stays with the app), then its account looked up and the usage asked
    var m = machine()
    check(tick(&m, t0) == [.readSignIn(generation: 0), .save] && m.inFlight && m.nextFetch == t0.addingTimeInterval(300),
          "the first tick reads the sign-in; the next read in one interval")
    check(m.handle(.signInRead(token, generation: 0, now: t0)) == [.keepSignIn, .lookUp(req("k1")), .fetchUsage(req("k1"))]
          && m.plan == "max" && m.kept == token, "a token: kept (by its key), its account looked up, the usage asked")
    check(tick(&m, t0.addingTimeInterval(10)) == [.save], "while a read is under way, a tick only saves")
    // its answer comes back before its account: held, nothing shown
    check(m.handle(.usageAnswer(endpoint(use(week: 30, at: t0)), key: "k1", asked: t0, generation: 0, now: t0)) == [.save]
          && m.held?.key == "k1" && m.usage == nil && m.state == .ok && m.rewriteDue, "a reading whose account isn't known yet is held, saved as a read")
    var out = m.handle(.lookupAnswer(email: "mo@example.com", key: "k1", asked: t0, generation: 0, expected: "mo@example.com", now: t0))
    check(m.held == nil && m.usage?.weekly == 30 && m.numbersOwner == "mo@example.com" && out.first.map {
        if case .numbersTaken = $0 { return true }; return false } == true && out.last == .save,
          "its account back: the held reading taken (the app's alerts), then saved")
    // the next read: the token is kept, no Keychain read, no second lookup
    out = tick(&m, t0.addingTimeInterval(301))
    check(out == [.fetchUsage(req("k1", 0, t0.addingTimeInterval(301))), .save], "the next read asks with the kept sign-in, no lookup again: \(out)")
    _ = m.handle(.written)
    check(!m.rewriteDue, "written: no rewrite due")

    // no sign-in: noLogin, looked for again in a minute; the folder's record watched (at most every 30 s)
    var none = machine()
    _ = tick(&none, t0)
    check(none.handle(.signInRead(.notFound, generation: 0, now: t0)) == [.keepSignIn, .save] && none.state == .noLogin
          && none.nextFetch == t0.addingTimeInterval(60) && none.watchesSignIn, "no sign-in: noLogin, again in a minute, the record watched")
    check(none.handle(.signInRecordChanged(now: t0.addingTimeInterval(10), floor: 30)) == []
          && none.handle(.signInRecordChanged(now: t0.addingTimeInterval(31), floor: 30)) == [.recordChanged, .tick]
          && none.forceLoginRead && none.needsSignInRead(now: t0.addingTimeInterval(31)), "the record changed: read now, not more often than the floor")
    var denied = machine()
    _ = tick(&denied, t0)
    _ = denied.handle(.signInRead(.denied, generation: 0, now: t0))
    check(denied.state == .denied && denied.nextFetch == t0.addingTimeInterval(300) && !denied.watchesSignIn
          && !denied.needsSignInRead(now: t0.addingTimeInterval(9 * 60)) && denied.needsSignInRead(now: t0.addingTimeInterval(10 * 60)),
          "a refused read: denied, read again only every 10 minutes")

    // an expired sign-in: expired, a renewal considered; the kept one read again only after 10 minutes
    var exp = machine()
    _ = tick(&exp, t0)
    check(exp.handle(.signInRead(.token(key: "k9", expiresAt: t0.addingTimeInterval(-1), plan: nil), generation: 0, now: t0))
          == [.keepSignIn, .save, .considerRenew] && exp.state == .expired && !exp.inFlight, "an expired token: expired, saved, a renewal considered")
    check(tick(&exp, t0.addingTimeInterval(301)) == [.save, .considerRenew, .save] && exp.state == .expired,
          "within 10 minutes: no Keychain read, still expired")
    check(tick(&exp, t0.addingTimeInterval(601))  == [.readSignIn(generation: 0), .save], "10 minutes on: the sign-in read again")
    // Claude Code renews its own sign-in: its status line written after the expired one was read says it works, so the
    // sign-in is read again at once (at most once a minute), not after 10 minutes
    var renewed = machine()
    _ = tick(&renewed, t0)
    _ = renewed.handle(.signInRead(.token(key: "k9", expiresAt: t0.addingTimeInterval(-1), plan: nil), generation: 0, now: t0))
    let early = tick(&renewed, t0.addingTimeInterval(30), line: use(week: 20, at: t0.addingTimeInterval(20), source: "line"))
    check(!early.contains(.readSignIn(generation: 0)) && renewed.state == .expired, "a status line within a minute of the read: not read again yet")
    let later = tick(&renewed, t0.addingTimeInterval(90), line: use(week: 21, at: t0.addingTimeInterval(80), source: "line"))
    check(later.contains(.readSignIn(generation: 0)), "a newer status line a minute on, the sign-in expired: read again now (\(later))")
    _ = renewed.handle(.signInRead(.token(key: "k10", expiresAt: t0.addingTimeInterval(8 * 3600), plan: nil), generation: 0, now: t0.addingTimeInterval(90)))
    check(renewed.handle(.usageAnswer(endpoint(use(week: 22, at: t0.addingTimeInterval(91))), key: "k10", asked: t0.addingTimeInterval(90), generation: 0,
                                      now: t0.addingTimeInterval(91))).contains(.save) && renewed.state == .ok,
          "…the renewed sign-in reads: ok again")
    // a line taken within that minute and no newer one after it: still read again once the minute is up, not at 10 minutes
    var lone = machine()
    _ = tick(&lone, t0)
    _ = lone.handle(.signInRead(.token(key: "k9", expiresAt: t0.addingTimeInterval(-1), plan: nil), generation: 0, now: t0))
    let loneLine = use(week: 20, at: t0.addingTimeInterval(20), source: "line")
    let loneEarly = tick(&lone, t0.addingTimeInterval(30), line: loneLine)
    let loneOn = tick(&lone, t0.addingTimeInterval(61), line: loneLine)
    check(!loneEarly.contains(.readSignIn(generation: 0)) && loneOn.contains(.readSignIn(generation: 0)),
          "a status line within a minute of the read, none newer: read again once the minute is up (\(loneOn))")
    _ = lone.handle(.signInRead(.token(key: "k9", expiresAt: t0.addingTimeInterval(-1), plan: nil), generation: 0, now: t0.addingTimeInterval(61)))
    check(!tick(&lone, t0.addingTimeInterval(200), line: loneLine).contains(.readSignIn(generation: 0)),
          "…read once: still expired with no newer line, not read again before 10 minutes")
    var okLine = machine()
    _ = tick(&okLine, t0); _ = okLine.handle(.signInRead(token, generation: 0, now: t0))
    let okTaken = use(week: 20, at: t0.addingTimeInterval(20), source: "line")
    _ = tick(&okLine, t0.addingTimeInterval(30), line: okTaken)
    _ = okLine.handle(.usageFailed(.signInRejected, asked: t0, generation: 0, now: t0.addingTimeInterval(40)))
    check(okLine.state == .expired && !tick(&okLine, t0.addingTimeInterval(120), line: okTaken).contains(.readSignIn(generation: 0)),
          "a status line taken before the sign-in was rejected: no renewal to read")
    var oldLine = machine()
    _ = tick(&oldLine, t0)
    _ = oldLine.handle(.signInRead(.token(key: "k9", expiresAt: t0.addingTimeInterval(-1), plan: nil), generation: 0, now: t0.addingTimeInterval(100)))
    check(!tick(&oldLine, t0.addingTimeInterval(200), line: use(week: 20, at: t0.addingTimeInterval(50), source: "line")).contains(.readSignIn(generation: 0)),
          "a status line written before the expired sign-in was read: no read again")
    // rejected by the endpoint (401/403): expired too, the same 10 minutes
    var rej = machine()
    _ = tick(&rej, t0); _ = rej.handle(.signInRead(token, generation: 0, now: t0))
    check(rej.handle(.usageFailed(.signInRejected, asked: t0, generation: 0, now: t0)) == [.considerRenew, .save]
          && rej.state == .expired && rej.loginRejected && !rej.needsSignInRead(now: t0.addingTimeInterval(599))
          && rej.needsSignInRead(now: t0.addingTimeInterval(600)), "a rejected sign-in: expired, renewal considered, read again after 10 minutes")

    // busy (429): a backoff from 2 minutes, doubled, at most 30; a good answer clears it
    var busy = machine()
    _ = tick(&busy, t0); _ = busy.handle(.signInRead(token, generation: 0, now: t0))
    _ = busy.handle(.lookupAnswer(email: "mo@example.com", key: "k1", asked: t0, generation: 0, expected: nil, now: t0))
    var backoffs: [TimeInterval] = []
    for _ in 0..<6 { _ = busy.handle(.usageFailed(.rateLimited, asked: t0, generation: 0, now: t0)); backoffs.append(busy.backoff) }
    check(backoffs == [120, 240, 480, 960, 1800, 1800] && busy.state == .rateLimited && busy.failing
          && busy.nextFetch == t0.addingTimeInterval(300 + 1800), "429: backoff 2, 4, 8, 16, then 30 minutes, added to the interval: \(backoffs)")
    _ = busy.handle(.usageAnswer(endpoint(use(week: 10, at: t0)), key: "k1", asked: t0, generation: 0, now: t0))
    check(busy.backoff == 0 && busy.state == .ok && !busy.failing, "a good answer: no backoff, ok")
    for (f, s) in [(ReaderMachine.Failure.http(500), FetchState.failed("HTTP 500")), (.network("offline"), .failed("offline")),
                   (.unexpectedReply, .failed("unexpected reply"))] {
        _ = busy.handle(.usageFailed(f, asked: t0, generation: 0, now: t0))
        check(busy.state == s && busy.failing && busy.usage?.weekly == 10, "\(f): \(s), the numbers kept")
    }

    // an account lookup outage: 1, 2, 4… minutes, at most 30; a second reading without an account: "account not confirmed"
    var look = machine()
    var waits: [TimeInterval] = []
    for _ in 0..<7 { _ = look.handle(.lookupFailed(now: t0)); waits.append(look.nextLookup.timeIntervalSince(t0)) }
    check(waits == [60, 120, 240, 480, 960, 1800, 1800], "the lookup's retries: \(waits)")
    _ = look.handle(.usageAnswer(endpoint(use(week: 50, at: t0)), key: "k2", asked: t0, generation: 0, now: t0))
    _ = look.handle(.usageAnswer(endpoint(use(week: 60, at: t0)), key: "k2", asked: t0, generation: 0, now: t0))
    check(look.unconfirmed && look.usage?.weekly == 60 && look.numbersOwner == nil && look.held == nil,
          "the second reading still without an account: shown, not confirmed")
    _ = look.handle(.accountFound(email: "mo@example.com", key: "k2", expected: nil, now: t0))
    check(!look.unconfirmed && look.numbersOwner == "mo@example.com", "its account back: confirmed")

    // the folder signed in to another account mid-read: everything of the old one goes, its answer is dropped
    var sw = machine()
    _ = tick(&sw, t0); _ = sw.handle(.signInRead(token, generation: 0, now: t0))
    _ = sw.handle(.lookupAnswer(email: "mo@example.com", key: "k1", asked: t0, generation: 0, expected: nil, now: t0))
    _ = sw.handle(.usageAnswer(endpoint(use(week: 70, at: t0)), key: "k1", asked: t0, generation: 0, now: t0))
    _ = tick(&sw, t0.addingTimeInterval(301))                             // a read under way, generation 0
    let t1 = t0.addingTimeInterval(302)
    check(sw.handle(.folderLooked(changed: true, seen: pat, now: t1)) == [.forgetSignIn, .startedOver]
          && sw.usage == nil && sw.kept == nil && sw.state == .idle && sw.generation == 1 && sw.forceLoginRead && sw.plan == nil
          && sw.loginEmail == nil && sw.signInChangedAt == t1 && sw.onOtherAccount, "another account signed in: the old one's numbers, sign-in and plan go")
    check(sw.handle(.usageAnswer(endpoint(use(week: 99, at: t1)), key: "k1", asked: t0.addingTimeInterval(301), generation: 0, now: t1)) == [.tick]
          && sw.usage == nil && !sw.inFlight, "the old account's answer under way: dropped, read again now")
    check(sw.handle(.usageAnswer(endpoint(use(week: 99, at: t1)), key: "k1", asked: t0, generation: 1, now: t1)) == []
          && sw.usage == nil, "an answer asked before the change: the old account's, dropped")
    check(sw.handle(.lookupAnswer(email: "mo@example.com", key: "k1", asked: t0, generation: 1, expected: "pat@example.com", now: t1)) == [],
          "a lookup asked before the change: dropped")
    check(tick(&sw, t1.addingTimeInterval(1), line: use(week: 5, at: t0.addingTimeInterval(200), source: "line")) == [.readSignIn(generation: 1), .save]
          && sw.usage == nil, "the new sign-in read at once; a status line written before the change isn't taken")
    // the Keychain still holds the old sign-in: read again 15, 30… seconds on, at most four times, within 5 minutes
    _ = sw.handle(.signInRead(.token(key: "old", expiresAt: nil, plan: nil), generation: 1, now: t1))
    var retries: [ReaderMachine.Action] = []
    for i in 1...5 {
        retries += sw.handle(.accountFound(email: "MO@example.com", key: "old", expected: "pat@example.com", now: t1.addingTimeInterval(Double(i))))
    }
    check(retries.filter { $0 == .signInNotThereYet }.count == 4 && sw.signInRetries == 4 && sw.forceLoginRead,
          "the sign-in still the old account's: read again, four times at most")
    var same = machine()
    _ = same.handle(.folderLooked(changed: true, seen: mo, now: t0))
    check(same.handle(.accountFound(email: "MO@example.com", key: "k1", expected: "mo@example.com", now: t0)) == [] && same.signInRetries == 0,
          "the sign-in's address the folder's (any case): no read again")
    var late = machine()
    _ = late.handle(.folderLooked(changed: true, seen: pat, now: t0))
    check(late.handle(.accountFound(email: "mo@example.com", key: "k1", expected: "pat@example.com", now: t0.addingTimeInterval(301))) == [],
          "more than 5 minutes after the change: no read again")
    // one login's other seat (personal vs Team: the same address and account id): told by the reply's organisation against
    // the one the folder's record named; one not known on either side is never another seat
    func seatRetry(_ org: String?, seen: Seat) -> [ReaderMachine.Action] {
        var x = machine()
        _ = x.handle(.folderLooked(changed: true, seen: seen, now: t0))
        return x.handle(.accountFound(email: "mo@example.com", key: "k1", expected: "mo@example.com", now: t0, account: mo.account, organization: org))
    }
    let moNoOrg = Seat(account: mo.account, organization: nil, email: mo.email), moEmptyOrg = Seat(account: mo.account, organization: "", email: mo.email)
    check(seatRetry(uuid(72), seen: mo) == [.signInNotThereYet] && seatRetry(uuid(71).uppercased(), seen: mo) == []
          && seatRetry(nil, seen: mo) == [] && seatRetry(uuid(72), seen: moNoOrg) == [] && seatRetry(uuid(72), seen: moEmptyOrg) == [],
          "the folder on the login's other seat, the sign-in's organisation another: read again; the same (any case) or one not known: not")

    // the one "is it another account" rule
    let r = machine(mo)
    check(r.belongs(.seat(nil)) == .unknown && r.belongs(.seat(mo)) == .same && r.belongs(.seat(pat)) == .other
          && machine(nil).belongs(.seat(pat)) == .notLinked, "a seat against the linked one: unknown, same, other, not linked")
    let hexSeat = Seat(account: "00000000-0000-4000-8000-0000000000ab", organization: uuid(71))
    check(r.belongs(.seat(Seat(account: uuid(61), organization: uuid(71), email: "x@example.com"))) == .same
          && machine(hexSeat).belongs(.seat(Seat(account: hexSeat.account.uppercased(), organization: uuid(71)))) == .same
          && machine(hexSeat).belongs(.seat(Seat(account: hexSeat.account, organization: uuid(72)))) == .other
          && r.belongs(.seat(Seat(account: uuid(62), organization: uuid(71), email: mo.email))) == .other,
          "seats by the one owner rule: the ids in any case, another organisation another account, never the address")
    check(r.belongs(.address("MO@example.com"), expected: "mo@example.com") == .same && r.belongs(.address("pat@example.com"), expected: "mo@example.com") == .other
          && r.belongs(.address("pat@example.com")) == .notLinked && r.belongs(.address(nil), expected: "mo@example.com") == .unknown,
          "addresses in any case; none expected: not linked")
    var other = machine(mo)
    _ = other.handle(.folderLooked(changed: false, seen: pat, now: t0))
    check(other.onOtherAccount && !other.mayRenewByItself(autoRenew: true, folderNow: mo, lastAttempt: nil, now: t0),
          "the folder last seen on another account: on another account, never renewed in this profile's name")
    _ = other.handle(.folderLooked(changed: false, seen: mo, now: t0))
    check(!other.onOtherAccount && other.mayRenewByItself(autoRenew: true, folderNow: mo, lastAttempt: nil, now: t0)
          && !other.mayRenewByItself(autoRenew: true, folderNow: pat, lastAttempt: nil, now: t0)
          && !other.mayRenewByItself(autoRenew: true, folderNow: nil, lastAttempt: nil, now: t0)
          && machine(nil).renewsIn(folderNow: nil), "the folder as it is now: renewed only when it's the profile's own (or none is linked)")

    // renewing: at most every 30 minutes, one at a time; its end reads the sign-in again, unless the account changed since
    var rn = machine(mo)
    check(!rn.mayRenewByItself(autoRenew: false, folderNow: mo, lastAttempt: nil, now: t0)
          && !rn.mayRenewByItself(autoRenew: true, folderNow: mo, lastAttempt: t0.addingTimeInterval(-29 * 60), now: t0)
          && rn.mayRenewByItself(autoRenew: true, folderNow: mo, lastAttempt: t0.addingTimeInterval(-30 * 60), now: t0),
          "off, or tried in the last 30 minutes: no renewal")
    check(rn.handle(.renewStarted(note: "renewing")) == [.save] && rn.renewing && rn.renewNote == "renewing"
          && !rn.mayRenewByItself(autoRenew: true, folderNow: mo, lastAttempt: nil, now: t0), "under way: no second one")
    check(rn.handle(.renewEnded(note: "renewed", generation: 0)) == [.tick] && !rn.renewing && rn.renewNote == "renewed"
          && rn.forceLoginRead && rn.nextFetch == .distantPast, "renewed: the sign-in read again now")
    _ = rn.handle(.renewStarted(note: "renewing"))
    _ = rn.handle(.folderLooked(changed: true, seen: pat, now: t0))
    check(rn.handle(.renewEnded(note: "renewed", generation: 0)) == [] && !rn.renewing && rn.renewNote == nil,
          "renewed for an account it no longer reads: its words dropped")
    check(rn.handle(.renewRefused(note: "folder gone")) == [.save] && rn.renewNote == "folder gone", "a renewal refused: its note saved")

    // linked to another account: read afresh, unless the folder is signed in to it already
    var link = machine(mo)
    _ = link.handle(.folderLooked(changed: false, seen: pat, now: t0))
    _ = link.handle(.profile(linked: pat, poll: 600))
    check(link.handle(.relinked(folderMoved: false, now: t0)) == [.tick] && link.generation == 0 && link.timing.poll == 600,
          "linked to the account the folder is on already: its numbers stay, a tick")
    _ = link.handle(.profile(linked: mo, poll: 600))
    check(link.handle(.relinked(folderMoved: false, now: t0)) == [.forgetSignIn, .startedOver, .lookAfresh, .tick] && link.generation == 1,
          "linked to another account than the folder's: start over, look afresh")
    _ = link.handle(.profile(linked: pat, poll: 600))
    check(link.handle(.relinked(folderMoved: true, now: t0)) == [.forgetSignIn, .startedOver, .lookAfresh, .tick] && link.generation == 3,
          "with another folder: answers under way for the old folder dropped too")
    check(link.handle(.folderMoved(now: t0)) == [.forgetSignIn] && link.generation == 4 && link.kept == nil, "the folder moved: its own sign-in")

    // a full limit: read again 2 s after its reset; past it, read again at once (at most once a minute)
    var full = machine()
    _ = full.handle(.numbers(use(week: 100, at: t0, resets: t0.addingTimeInterval(600)), now: t0))
    check(full.resetReadAt(now: t0) == t0.addingTimeInterval(602) && ReaderMachine.resetPassed(full.usage!, now: t0.addingTimeInterval(601)),
          "full: a read planned 2 s after the reset")
    var p2 = machine()
    _ = tick(&p2, t0)                                                     // the first read: lastAsked t0
    _ = p2.handle(.signInRead(token, generation: 0, now: t0))
    _ = p2.handle(.usageAnswer(endpoint(use(week: 100, at: t0, resets: t0.addingTimeInterval(10))), key: nil, asked: t0, generation: 0, now: t0))
    check(!tick(&p2, t0.addingTimeInterval(30)).contains { if case .fetchUsage = $0 { return true }; return false }
          && tick(&p2, t0.addingTimeInterval(61)).contains(.fetchUsage(req("k1", 0, t0.addingTimeInterval(61)))),
          "a full limit past its reset: read again, once a minute at most")

    // the status line file: taken when newer (the model limits and credits kept), no account named
    var line = machine()
    var withScoped = use(week: 20, at: t0); withScoped.scoped = [ScopedLimit(name: "Fable", percent: 10, resets: nil)]
    _ = line.handle(.accountFound(email: "mo@example.com", key: "k1", expected: nil, now: t0, account: "acct-mo"))
    _ = line.handle(.usageAnswer(endpoint(withScoped), key: "k1", asked: t0, generation: 0, now: t0))
    check(line.numbersOwner == "mo@example.com" && line.numbersAccount == "acct-mo",
          "(read with a key whose account is known: its account's, with its id when the reply gave one)")
    _ = tick(&line, t0.addingTimeInterval(5), line: use(five: 3, week: 25, at: t0.addingTimeInterval(4), source: "line"))
    check(line.usage?.weekly == 25 && line.usage?.scoped.first?.percent == 10 && line.numbersOwner == nil && line.numbersAccount == nil,
          "a newer status line: its two limits, the model limit kept, no account (nor its id)")
    var noID = machine()
    _ = noID.handle(.accountFound(email: "mo@example.com", key: "k1", expected: nil, now: t0))
    _ = noID.handle(.usageAnswer(endpoint(withScoped), key: "k1", asked: t0, generation: 0, now: t0))
    var adopted = machine()
    _ = adopted.handle(.adopt(usage: withScoped, loginEmail: "mo@example.com", owner: "mo@example.com", plan: nil, renewNote: nil, ownerAccount: "acct-mo"))
    var adoptedNoOwner = machine()
    _ = adoptedNoOwner.handle(.adopt(usage: withScoped, loginEmail: "mo@example.com", owner: nil, plan: nil, renewNote: nil, ownerAccount: "acct-mo"))
    check(noID.numbersOwner == "mo@example.com" && noID.numbersAccount == nil && adopted.numbersAccount == "acct-mo"
          && adoptedNoOwner.numbersAccount == nil,
          "a reply without an id: the address only, as before; a saved record's id adopted only with its owner")
    // the reply's organisation: kept with the account's id only, adopted with it, gone with a status line
    var withOrg = machine()
    _ = withOrg.handle(.accountFound(email: "mo@example.com", key: "k1", expected: nil, now: t0, account: "acct-mo", organization: "org-team"))
    _ = withOrg.handle(.usageAnswer(endpoint(withScoped), key: "k1", asked: t0, generation: 0, now: t0))
    var orgNoID = machine()
    _ = orgNoID.handle(.accountFound(email: "mo@example.com", key: "k1", expected: nil, now: t0, organization: "org-team"))
    _ = orgNoID.handle(.usageAnswer(endpoint(withScoped), key: "k1", asked: t0, generation: 0, now: t0))
    var orgEmpty = machine()
    _ = orgEmpty.handle(.accountFound(email: "mo@example.com", key: "k1", expected: nil, now: t0, account: "acct-mo", organization: ""))
    _ = orgEmpty.handle(.usageAnswer(endpoint(withScoped), key: "k1", asked: t0, generation: 0, now: t0))
    var orgAdopted = machine(), orgAdoptedNoID = machine()
    _ = orgAdopted.handle(.adopt(usage: withScoped, loginEmail: "mo@example.com", owner: "mo@example.com", plan: nil, renewNote: nil,
                                 ownerAccount: "acct-mo", ownerOrganization: "org-team"))
    _ = orgAdoptedNoID.handle(.adopt(usage: withScoped, loginEmail: "mo@example.com", owner: "mo@example.com", plan: nil, renewNote: nil,
                                     ownerAccount: nil, ownerOrganization: "org-team"))
    check(withOrg.numbersOrganization == "org-team" && withOrg.loginOrganization == "org-team" && orgNoID.numbersOrganization == nil
          && orgEmpty.numbersOrganization == nil && orgAdopted.numbersOrganization == "org-team" && orgAdoptedNoID.numbersOrganization == nil,
          "the reply's organisation: kept with the account's id (never alone, never empty), adopted only with the id")
    _ = tick(&withOrg, t0.addingTimeInterval(5), line: use(week: 26, at: t0.addingTimeInterval(4), source: "line"))
    check(withOrg.numbersOrganization == nil && withOrg.numbersAccount == nil, "a newer status line: no organisation either")
    _ = tick(&line, t0.addingTimeInterval(6), line: use(week: 90, at: t0.addingTimeInterval(1), source: "line"))
    check(line.usage?.weekly == 25, "an older status line: not taken")

    // Refresh now, and a stopped reader
    var rf = machine()
    _ = rf.handle(.refreshRequested)
    check(rf.rewriteDue && rf.forceLoginRead && rf.nextFetch == .distantPast, "Refresh now: read now, the sign-in again, the record rewritten")
    check(rf.handle(.stop) == [.planResetRead(nil)] && tick(&rf, t0) == [] && rf.resetReadAt(now: t0) == nil, "stopped: nothing more")
    check(rf.handle(.renewStarted(note: "renewing")) == [] && rf.handle(.renewRefused(note: "gone")) == [] && !rf.renewing && rf.renewNote == nil,
          "stopped: a renewal's start or refusal changes nothing")

    // a request the app couldn't send (no kept sign-in for its key) is answered as a failure: the read ends, the next comes
    var lost = machine()
    _ = tick(&lost, t0); _ = lost.handle(.signInRead(token, generation: 0, now: t0))
    check(lost.inFlight, "(a read under way)")
    _ = lost.handle(.usageFailed(.network("the sign-in to ask with is gone"), asked: t0, generation: 0, now: t0))
    check(!lost.inFlight && lost.failing && tick(&lost, t0.addingTimeInterval(300)).contains { if case .fetchUsage = $0 { return true }; return false },
          "the usage request not sent: the read ends as failed, the next one comes on time")
    _ = lost.handle(.lookupAnswer(email: nil, key: "k1", asked: t0, generation: 0, expected: nil, now: t0))
    check(lost.lookupFails == 1 && lost.nextLookup == t0.addingTimeInterval(60), "the lookup not sent: a failed lookup, tried again in a minute")

    // cl_quick's rules: the scales, partial and empty answers, the week, refusals and how they lift, message text
    var q = machine(rules: .clQuick)
    _ = q.handle(.numbers(use(five: 20, week: 40, at: t0), now: t0))
    _ = q.handle(.rateLimit(RateLimitEvent(window: .fiveHour, utilization: 0.42, resetsAt: t0.addingTimeInterval(7200), status: .allowed), now: t0.addingTimeInterval(60)))
    check(q.usage?.fiveHour == 42 && q.usage?.weekly == 40 && q.usage?.fetchedAt == t0 && q.usage?.fiveHourResets == t0.addingTimeInterval(7200),
          "a rate-limit event's fraction (0.42) is 42 %; a partial answer keeps the week and its read time; the window given whole, its reset too")
    check(ReadingRules.clQuick.take(UsageAnswer(source: .usageEndpoint, usage: nil, given: []), last: q.usage) == nil
          && ReadingRules.clQuick.take(endpoint(use(five: 1, week: 2, at: t0.addingTimeInterval(9))), last: q.usage)?.fetchedAt == t0.addingTimeInterval(9),
          "an empty answer changes nothing; a whole one moves the read time")
    let audit = ReadingRules.clAudit.take(UsageAnswer(source: .usageEndpoint, usage: use(week: 50, at: t0.addingTimeInterval(9)), given: [.week]), last: q.usage)
    check(audit?.fiveHour == nil && audit?.weekly == 50 && audit?.fetchedAt == t0.addingTimeInterval(9), "cl_audit's: an answer replaces the numbers")
    check(ReadingRules.clAudit.percents(UsageAnswer(source: .rateLimitEvent, usage: use(week: 0.5, at: t0), given: [.week]))?.weekly == 50
          && ReadingRules.clAudit.percents(endpoint(use(week: 50, at: t0)))?.weekly == 50, "the endpoint gives 0–100, a rate-limit event 0–1")
    let opus = #"{"limits":[{"type":"seven_day_opus","percent":80},{"type":"weekly","percent":70},{"type":"five_hour","percent":5}]}"#
    check(UsageParser.fromAPI(Data(opus.utf8), source: "t", week: .sevenDayOnly)?.weekly == nil
          && UsageParser.fromAPI(Data(opus.utf8), source: "t")?.weekly != nil, "the week is seven_day only for cl_quick; cl_audit's parser as it was")
    let rejectedAt = t0.addingTimeInterval(100)
    _ = q.handle(.rateLimit(RateLimitEvent(window: .named("seven_day"), utilization: 1, resetsAt: t0.addingTimeInterval(86400), status: .rejected), now: rejectedAt))
    check(q.refusal == Refusal(until: t0.addingTimeInterval(86400), at: rejectedAt, on: .week), "a rejection: refusedUntil, refusedAt, refusedOn wk")
    _ = q.handle(.rateLimit(RateLimitEvent(window: .named("seven_day_opus"), utilization: 0.1, resetsAt: nil, status: .allowed), now: rejectedAt))
    check(q.refusal != nil && RateLimitEvent.Window.named("seven_day_opus") == .scoped("seven_day_opus"), "a model's window \"allowed\": the refusal stays")
    func ask(_ m: inout ReaderMachine, _ u: Usage, at: Date) {
        _ = m.handle(.usageAnswer(endpoint(u), key: nil, asked: at, generation: m.generation, now: at))
    }
    var withFable = use(five: 10, at: rejectedAt.addingTimeInterval(400)); withFable.scoped = [ScopedLimit(name: "Fable", percent: 5, resets: nil)]
    ask(&q, withFable, at: rejectedAt.addingTimeInterval(400))
    check(q.refusal != nil, "an answer without the week (a model's window only beside the 5-hour one): the refusal stays")
    ask(&q, use(week: 40, at: rejectedAt.addingTimeInterval(299)), at: rejectedAt.addingTimeInterval(299))
    check(q.refusal != nil, "the week with room, said under 5 minutes after the refusal: it stays")
    ask(&q, use(week: 100, at: rejectedAt.addingTimeInterval(301)), at: rejectedAt.addingTimeInterval(301))
    check(q.refusal != nil, "the week full, 5 minutes on: it stays")
    ask(&q, use(week: 40, at: rejectedAt.addingTimeInterval(301)), at: rejectedAt.addingTimeInterval(301))
    check(q.refusal == nil, "the week with room, 5 minutes on: lifted")
    _ = q.handle(.rateLimit(RateLimitEvent(window: .fiveHour, utilization: 1, resetsAt: nil, status: .rejected), now: rejectedAt))
    _ = q.handle(.rateLimit(RateLimitEvent(window: .fiveHour, utilization: 0.2, resetsAt: nil, status: .allowed), now: rejectedAt.addingTimeInterval(1)))
    check(q.refusal == nil, "\"allowed\" lifts it at once")
    _ = q.handle(.rateLimit(RateLimitEvent(window: .named("overage"), utilization: nil, resetsAt: nil, status: .rejected), now: rejectedAt))
    check(q.refusal == nil, "a spend window's rejection sets none")
    check(q.handle(.limitMessage(LimitMessage(isError: false, model: "claude-x", on: .unknown, until: nil), now: rejectedAt)) == [] && q.refusal == nil,
          "limit words in a plain message: not read")
    _ = q.handle(.limitMessage(LimitMessage(isError: false, model: "<synthetic>", on: .unknown, until: t0), now: rejectedAt))
    check(q.refusal == Refusal(until: t0, at: rejectedAt, on: .unknown), "in a \"<synthetic>\" message: refusedOn unknown")
    ask(&q, use(five: 10, week: 100, at: rejectedAt.addingTimeInterval(400)), at: rejectedAt.addingTimeInterval(400))
    check(q.refusal != nil, "not said which window: a full one keeps it")
    ask(&q, use(five: 10, week: 20, at: rejectedAt.addingTimeInterval(400)), at: rejectedAt.addingTimeInterval(400))
    check(q.refusal == nil && ReadingRules.clQuick.readsMessage(isError: true, model: nil), "every window with room: lifted; an error message is read")
    var a = machine()
    _ = a.handle(.rateLimit(RateLimitEvent(window: .week, utilization: 1, resetsAt: nil, status: .rejected), now: t0))
    _ = a.handle(.limitMessage(LimitMessage(isError: true, model: "<synthetic>", on: .week, until: nil), now: t0))
    check(a.refusal == nil && !ReadingRules.clAudit.readsMessage(isError: true, model: "<synthetic>"), "cl_audit's rules: no refusal kept, no message text read")
}

print("core checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
