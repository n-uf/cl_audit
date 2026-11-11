// Surfaces checks for cl_audit: one answer about each profile's account (Sources/AccountResolver.swift), written once into its
// status record, and every screen reading it alike: the menu bar, the Dock icon's menu and panel, the dashboard card, Settings ▸
// Accounts and quick chat's profile line. Also the Claude app's account (Sources/AppSignIn.swift): its config.json names the
// account, its log gives the organisation and whether it signed out (an account switched in place and back included; the
// log's own account line without config.json); a standby account's old numbers never shown, and no screen reading the
// sign-in files itself.
//
// Runs only with HOME and CFFIXED_USER_HOME = .../Checks/.work/surfaces/home (Checks/run.sh sets and guards it). Fake data only:
// example.com addresses, zero-pattern ids, made-up log lines and config.json files in the throwaway home. Nothing here opens
// an app, the Dock or Terminal, and nothing touches the Keychain.

import AppKit
import SwiftUI

setbuf(stdout, nil)
let home = NSHomeDirectory()
guard home.hasSuffix("/Checks/.work/surfaces/home"), expand("~") == home else { print("refusing: HOME is \(home)"); exit(2) }
let fm = FileManager.default
SettingsModel.followsDock = false
BackupPrefs.store = MemoryPrefs()
var passed = 0, failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passed += 1 } else { failed += 1; print("FAIL (line \(line)): \(what)") }
}
func uuid(_ n: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", n) }
func seat(_ n: Int, _ email: String) -> Seat { Seat(account: uuid(n), organization: uuid(n + 100), email: email) }
func put(_ path: String, _ text: String) {
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    fm.createFile(atPath: path, contents: Data(text.utf8))
}
let u1 = seat(1, "ultra-1@example.com"), u2 = seat(2, "ultra-2@example.com"), u3 = seat(3, "ultra-3@example.com")
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func profile(_ id: String, _ dir: String, _ s: Seat?) -> AccountEntry {
    var e = AccountEntry(id: id, name: id.capitalized, label: id.uppercased(), configDir: dir); e.seat = s
    return e
}
_ = NSApplication.shared

// ============ 1. the Claude app's account: its log after the launch, checked against config.json ============
do {
    let launched = t0
    func at(_ s: Double) -> String { AppSignIn.timeFormat.string(from: launched.addingTimeInterval(s)) }
    let ok = "\(at(5)) [info] [LocalSessionManager] Initialization succeeded in 12ms, accountId=\(u2.account), orgId=\(u2.organization!), sessions=3"
    func judge(_ lines: [String], known: String? = nil) -> AppSignIn.Login? {
        AppSignIn.judge(lines: lines.map { Substring($0) }, launched: launched, lastKnown: known, now: launched.addingTimeInterval(3600))
    }
    check(judge([ok, ""])?.account == u2.account && judge([ok, ""])?.org == u2.organization && judge([ok, ""])?.state == .known, "Initialization succeeded names the account")
    check(judge([ok, ""], known: u3.account)?.state == .unknown && judge([ok, ""], known: u2.account)?.state == .known, "config.json names another account: unknown; the same: known")
    check(judge([ok])?.state == .unknown, "the file's last line (still being written): unknown")
    let before = "\(AppSignIn.timeFormat.string(from: launched.addingTimeInterval(-60))) [info] [LocalSessionManager] Initialization succeeded, accountId=\(u2.account), orgId=\(u2.organization!)"
    check(judge([before, ""])?.state == .unknown, "a line from before the launch: unknown")
    check(judge([ok, "\(at(9)) [info] [account] Login-state transition (loggedOut: false → true, loading: false)", ""])?.state == .loggedOut, "a transition to signed out")
    check(judge([ok, "\(at(9)) [info] [LocalSessionManager] Account logged out", ""])?.state == .loggedOut, "Account logged out")
    check(judge([ok, "\(at(9)) [info] [account] Login-state transition (loggedOut: true -> false)", ""])?.state == .unknown, "a transition that isn't to signed out: unknown")
    check(judge(["\(at(7)) [info] [LocalSessionManager] Initialization succeeded, accountId=nope, orgId=\(u2.organization!)", ""])?.state == .unknown, "an id that isn't one: unknown")
    check(judge(["\(at(7)) [info] something else entirely", ""]) == nil, "no account line in this file: the next one decides")
    let logs = URL(fileURLWithPath: expand("~/Library/Logs/Claude-check"))
    put(logs.appendingPathComponent("main.log").path, "\(at(20)) [info] nothing about accounts\n")
    put(logs.appendingPathComponent("main1.log").path, ok + "\n")
    put(logs.appendingPathComponent("main01.log").path, "\(at(30)) [info] [LocalSessionManager] Account logged out\n")
    check(AppSignIn.logFiles(logs).map(\.lastPathComponent) == ["main.log", "main1.log"], "the log files newest first, only main.log and mainN.log")
    check(AppSignIn.fromLog(logs: logs, launched: launched, lastKnown: nil, now: launched.addingTimeInterval(3600)).account == u2.account, "read from the end, newest file first")
    // a crafted 1 MB line (an account line's start, then a long run that would make a pattern backtrack): skipped at once
    let longLine = "\(at(8)) [info] [account] Login-state transition (" + String(repeating: "loggedOut: ", count: 95_000) + ")"
    let longInit = "\(at(8)) [info] [LocalSessionManager] Initialization succeeded " + String(repeating: "accountId=", count: 100_000)
    let started = Date()
    let crafted = judge([ok, longLine, longInit, ""])
    check(Date().timeIntervalSince(started) < 1 && crafted?.account == u2.account, "1 MB crafted lines are skipped at once; the real line still decides")
    check(AppSignIn.saysLoggedOut("[account] Login-state transition (loggedOut: false → true, loading: false)")
          && !AppSignIn.saysLoggedOut("[account] Login-state transition (loggedOut: true -> false)")
          && !AppSignIn.saysLoggedOut("[account] Login-state transition (loggedOut: false, ready: true)"), "signed out read by plain tests")
    // a FIFO named main.log, and a FIFO or a huge file named config.json: nothing blocks, nothing big is read
    let fifoLogs = URL(fileURLWithPath: expand("~/Library/Logs/Claude-fifo"))
    try? fm.createDirectory(at: fifoLogs, withIntermediateDirectories: true)
    mkfifo(fifoLogs.appendingPathComponent("main.log").path, 0o600)
    let f0 = Date()
    let fromFifo = AppSignIn.fromLog(logs: fifoLogs, launched: launched, lastKnown: nil, now: launched.addingTimeInterval(3600))
    check(Date().timeIntervalSince(f0) < 1 && fromFifo.state == .unknown, "a FIFO named main.log returns at once")
    let fifoData = expand("~/Library/Application Support/Claude-fifo")
    try? fm.createDirectory(atPath: fifoData, withIntermediateDirectories: true)
    mkfifo(fifoData + "/config.json", 0o600)
    let f1 = Date()
    check(AppSignIn.lastKnown(dataDir: fifoData) == nil && Date().timeIntervalSince(f1) < 1, "a FIFO named config.json returns at once")
    let bigData = expand("~/Library/Application Support/Claude-big")
    put(bigData + "/config.json", #"{"lastKnownAccountUuid":"\#(u2.account)","pad":""# + String(repeating: "x", count: AppSignIn.configBytes) + #""}"#)
    check(AppSignIn.lastKnown(dataDir: bigData) == nil, "a config.json bigger than 256 KB isn't read whole (and isn't taken)")
    let wd = expand("~/Library/Application Support/Claude-check")
    put("\(wd)/config.json", #"{"lastKnownAccountUuid":"\#(u2.account.uppercased())","oauth:tokenCache":"never-read"}"#)
    check(AppSignIn.lastKnown(dataDir: wd) == u2.account, "config.json: only lastKnownAccountUuid")
    check(AppSignIn.current(dataDir: wd, launched: nil, onlyApp: false, logs: logs).source == "config", "the app not running alone: config.json says it")
    check(AppSignIn.current(dataDir: wd, launched: launched, onlyApp: true, logs: logs, now: launched.addingTimeInterval(3600)).org == u2.organization,
          "the only Claude app running: its log says it, with the organisation")
}

// ============ 1b. the app switched accounts in place and back (26.11.14): config.json names the account ============
// The sequence seen in 26.11.14, with fake ids: launched at "13:48" with an init for A (u1), at "15:03" a reevaluate and an
// init for B (u2), later only oauth-v2 lookups for A, and config.json naming A written at "19:30".
var appBack = AppSignIn.Login.unknown
do {
    let launched = t0, now = t0.addingTimeInterval(8 * 3600)
    func at(_ m: Double) -> String { AppSignIn.timeFormat.string(from: launched.addingTimeInterval(m * 60)) }
    let a = u1.account, oa = u1.organization!, b = u2.account, ob = u2.organization!
    let story = [
        "\(at(0.1)) [info] [LocalSessionManager] Initialization succeeded in 9ms, accountId=\(a), orgId=\(oa), sessions=2",
        "\(at(75)) [info] [sessions-bridge] identity reevaluate: <none> \u{2192} \(ob):\(b)",
        "\(at(75.1)) [info] [LocalSessionManager] Initialization succeeded in 7ms, accountId=\(b), orgId=\(ob), sessions=0",
        "\(at(100)) [info] [oauth-v2] lookup orgId=\(oa) cacheKey=acct:\(a)",
        "\(at(200)) [info] [oauth-v2] lookup orgId=\(oa) cacheKey=acct:\(a)"]
    func home(_ name: String, log: [String], config: String?, configAt: Double = 342) -> (logs: URL, data: String) {
        let logs = URL(fileURLWithPath: expand("~/Library/Logs/Claude-\(name)")), data = expand("~/Library/Application Support/Claude-\(name)")
        put(logs.appendingPathComponent("main.log").path, log.joined(separator: "\n") + "\n")
        try? fm.createDirectory(atPath: data, withIntermediateDirectories: true)
        if let id = config {
            put(data + "/config.json", #"{"lastKnownAccountUuid":"\#(id)"}"#)
            try? fm.setAttributes([.modificationDate: launched.addingTimeInterval(configAt * 60)], ofItemAtPath: data + "/config.json")
        }
        return (logs, data)
    }
    func read(_ h: (logs: URL, data: String), onlyApp: Bool = true) -> AppSignIn.Login {
        AppSignIn.current(dataDir: h.data, launched: launched, onlyApp: onlyApp, logs: h.logs, now: now)
    }
    let back = home("a2-back", log: story, config: a)
    check(AppSignIn.fromLog(logs: back.logs, launched: launched, lastKnown: a, now: now).state == .unknown,
          "the 26.11.14 reading of this sequence: the newest init (B) against config.json (A) gave unknown")
    appBack = read(back)
    check(appBack.account == a && appBack.org == oa && appBack.state == .known && appBack.source == "log",
          "switched to B in place and back to A: the app is on A, with A's organisation from the newest oauth-v2 line")
    // a "logged out" line older than config.json: still signed in; newer: signed out
    let oldOut = home("a2-oldout", log: story + ["\(at(300)) [info] [LocalSessionManager] Account logged out"], config: a)
    check(read(oldOut).state == .known && read(oldOut).account == a, "Account logged out older than config.json: still signed in to A")
    let newOut = home("a2-newout", log: story + ["\(at(400)) [info] [LocalSessionManager] Account logged out"], config: a)
    check(read(newOut).state == .loggedOut && read(newOut).account == nil, "Account logged out newer than config.json: signed out")
    let newTrans = home("a2-newtrans", log: story + ["\(at(400)) [info] [account] Login-state transition (loggedOut: false \u{2192} true, loading: false)"], config: a)
    check(read(newTrans).state == .loggedOut, "a login-state transition to signed out newer than config.json: signed out")
    let oldTrans = home("a2-oldtrans", log: story + ["\(at(300)) [info] [account] Login-state transition (loggedOut: false \u{2192} true, loading: false)"], config: a)
    check(read(oldTrans).state == .known, "a login-state transition to signed out older than config.json: still signed in")
    let again = home("a2-again", log: story + ["\(at(400)) [info] [LocalSessionManager] Account logged out",
                                               "\(at(410)) [info] [account] Login-state transition (loggedOut: true \u{2192} false, loading: false)"], config: a)
    check(read(again).state == .known && read(again).account == a, "signed out, then a newer transition back to signed in: signed in to config.json's account")
    let halfOut = home("a2-half", log: story, config: a)
    put(halfOut.logs.appendingPathComponent("main.log").path, (story + ["\(at(400)) [info] [LocalSessionManager] Account logged out"]).joined(separator: "\n"))
    check(read(halfOut).state == .known, "a signed-out line still being written (the file's last, no newline): not read yet")
    // a newer file says signed out, an older one names the organisation: both read
    let twoFiles = home("a2-two", log: ["\(at(400)) [info] [LocalSessionManager] Account logged out"], config: a)
    put(twoFiles.logs.appendingPathComponent("main1.log").path, story.joined(separator: "\n") + "\n")
    check(read(twoFiles).state == .loggedOut, "the signed-out line in the newest file decides")
    let orgOlder = home("a2-orgolder", log: ["\(at(350)) [info] something else"], config: a)
    put(orgOlder.logs.appendingPathComponent("main1.log").path, story.joined(separator: "\n") + "\n")
    check(read(orgOlder).org == oa && read(orgOlder).state == .known, "the organisation from an older file when the newest says nothing")
    // a line before the launch never counts
    let before = home("a2-before", log: ["\(at(-10)) [info] [oauth-v2] lookup orgId=\(oa) cacheKey=acct:\(a)",
                                         "\(at(-5)) [info] [LocalSessionManager] Account logged out"], config: a, configAt: -20)
    check(read(before).state == .known && read(before).org == nil && read(before).source == "config",
          "lines from before the launch (even newer than config.json): config.json's account, no organisation")
    // no line about A: the newest claude-code-sessions/A/<org> folder (a link never followed or taken)
    let noLine = home("a2-folder", log: Array(story[1...2]), config: a)
    let sess = noLine.data + "/claude-code-sessions/\(a)"
    for (n, m) in [(401, 10.0), (402, 20.0)] {
        try? fm.createDirectory(atPath: "\(sess)/\(uuid(n))", withIntermediateDirectories: true)
        try? fm.setAttributes([.modificationDate: launched.addingTimeInterval(m * 60)], ofItemAtPath: "\(sess)/\(uuid(n))")
    }
    try? fm.createDirectory(atPath: noLine.data + "/elsewhere", withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: "\(sess)/\(uuid(403))", withDestinationPath: noLine.data + "/elsewhere")
    put("\(sess)/\(uuid(404))", "a file, not a folder")
    try? fm.createDirectory(atPath: "\(sess)/not-an-id", withIntermediateDirectories: true)
    check(read(noLine).account == a && read(noLine).org == uuid(402) && read(noLine).state == .known,
          "no organisation line for A in the log: the newest claude-code-sessions/A/<org> folder (links, files and other names left out)")
    check(read(noLine, onlyApp: false).org == uuid(402) && read(noLine, onlyApp: false).source == "config", "another Claude app running too: config.json's account, the folder's organisation")
    let linked = home("a2-linked", log: Array(story[1...2]), config: a)
    try? fm.createDirectory(atPath: linked.data + "/claude-code-sessions", withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: linked.data + "/claude-code-sessions/\(a)", withDestinationPath: sess)
    check(read(linked).org == nil && read(linked).account == a, "the account's sessions folder is a link: not followed, no organisation")
    // no config.json: the log's own account line decides, as before
    let noConfig = home("a2-noconfig", log: story, config: nil)
    check(read(noConfig).account == b && read(noConfig).org == ob && read(noConfig).state == .known, "no config.json: the log's newest init line decides, as before")
    let noConfigOut = home("a2-noconfig-out", log: story + ["\(at(400)) [info] [LocalSessionManager] Account logged out"], config: nil)
    check(read(noConfigOut).state == .loggedOut, "no config.json: a signed-out line, as before")
    let badConfig = home("a2-badconfig", log: story, config: "nope")
    check(read(badConfig).account == b, "config.json without a valid id: the log's own account line, as before")
    check(read(noConfig, onlyApp: false) == .unknown, "no config.json and another Claude app running: unknown, as before")
    // plain string parsing of the three account lines
    check(AppSignIn.accountOrg("[sessions-bridge] identity reevaluate: \(oa):\(a) -> \(ob):\(b)").map { $0.account == b && $0.org == ob } == true
          && AppSignIn.accountOrg("[sessions-bridge] identity reevaluate: \(ob):\(b) \u{2192} <none>") == nil
          && AppSignIn.accountOrg("[oauth-v2] lookup orgId=\(oa) cacheKey=acct:nope") == nil
          && AppSignIn.accountOrg("[oauth-v2] lookup orgId=\(oa) cacheKey=acct:\(a)").map { $0.account == a && $0.org == oa } == true,
          "the account lines read by plain tests: the arrow's last target, ids that are UUIDs only")
    let longOauth = "\(at(500)) [info] [oauth-v2] lookup " + String(repeating: "orgId=", count: 200_000)
    let started = Date()
    let crafted = home("a2-long", log: story + [longOauth], config: a)
    check(read(crafted).org == oa && Date().timeIntervalSince(started) < 2, "a 1 MB crafted oauth-v2 line is skipped; the real line still decides")
}

// ============ 2. the resolver: one answer per case ============
let appU2 = AppSignIn.Login(account: u2.account, org: u2.organization, state: .known, source: "log", at: t0)
let appU1 = AppSignIn.Login(account: u1.account, org: u1.organization, state: .known, source: "log", at: t0)
let appOut = AppSignIn.Login(account: nil, org: nil, state: .loggedOut, source: "log", at: t0)
var main = profile("main", "~/.claude-main", u1)
main.standby = [StandbyAccount(email: u2.email!, seat: u2, configDir: "~/.claude-main-u2", id: "k2")]
var other = profile("other", "~/.claude-other", u3); other.claudeWindow = false
func res(_ e: AccountEntry, _ app: AppSignIn.Login, code: Seat?, numbers: String?, among: [AccountEntry]? = nil) -> ResolvedAccount {
    AccountResolver.resolve(e, among: among ?? [e, other], app: app, code: code, loginEmail: numbers, names: [:], now: t0)
}
do {
    let same = res(main, appU1, code: u1, numbers: u1.email)
    check(same.email == u1.email && !same.differs && same.line == nil && same.lit && same.fromApp, "the app and Claude Code on the same account: one account, no line")
    let diff = res(main, appU2, code: u1, numbers: u1.email)
    check(diff.email == u2.email && diff.differs && diff.numbersFor == u1.email && diff.line?.hasPrefix("Usage: Claude Code on ") == true && diff.lit,
          "the app on u2 (a standby account), Claude Code on u1: u2 in use, the numbers say they are Claude Code's on u1")
    let out = res(main, appOut, code: u1, numbers: u1.email)
    check(!out.fromApp && out.email == u1.email && out.line?.contains("signed out") == true, "the app signed out: Claude Code's account, with a muted line")
    var noWin = main; noWin.claudeWindow = false
    check(res(noWin, appU2, code: u1, numbers: u1.email).line == nil && !res(noWin, appU2, code: u1, numbers: u1.email).fromApp, "no Claude window: Claude Code's account, nothing to say")
    let clash = res(main, .unknown, code: u3, numbers: u3.email)
    check(clash.clash == "Other" && clash.line?.contains("Other") == true && !clash.lit, "Claude Code's folder on another profile's account in use: said, lamp off")
    // the kept folder (Accounts.swift readingFolder): the working folder on u3, the numbers read from u1's kept folder, the app on u1
    let kept = res(main, appU1, code: Seat(account: uuid(9), organization: uuid(109), email: "free@example.com"), numbers: u1.email)
    check(kept.email == u1.email && !kept.differs && kept.line == nil, "numbers from the account in use's kept folder agree with the app's account: no line")
    // the app signed out, the working folder on another account, the numbers from u1's kept folder: labelled all the same
    let keptNoApp = res(main, appOut, code: Seat(account: uuid(9), organization: uuid(109), email: "free@example.com"), numbers: u1.email)
    check(!keptNoApp.fromApp && keptNoApp.email == "free@example.com" && keptNoApp.differs && keptNoApp.numbersFor == u1.email
          && keptNoApp.line?.hasPrefix("Usage: Claude Code on ") == true, "no app: Claude Code's folder account in use, the kept folder's numbers say whose they are")
    check(AccountView.of({ var s = IconStatus(state: "ok"); s.resolved = res(main, AppSignIn.Login(account: uuid(77), org: nil, state: .known, source: "log", at: t0), code: u1, numbers: u1.email); return s }()).label == "account 00000000",
          "an app account no record names: by its id's first 8")
}

// ============ 3. every surface reads the same record alike ============
do {
    let cases: [(String, AppSignIn.Login, Seat?, String?)] = [
        ("same", appU1, u1, u1.email), ("different", appU2, u1, u1.email), ("app signed out", appOut, u1, u1.email),
        ("a standby's account in the app", appU2, u1, u1.email), ("another profile's account", .unknown, u3, u3.email),
        ("the app switched to u2 in place and back", appBack, u1, u1.email)]
    let model = SettingsModel()
    model.accounts = [main, other]
    for (name, app, code, numbers) in cases {
        var rec = IconStatus(state: "ok"); rec.loginEmail = numbers; rec.weekly = 40; rec.updatedAt = t0
        rec.resolved = res(main, app, code: code, numbers: numbers)
        _ = Store.writeStatus("main", rec)
        let want = AccountView.of(Store.status(for: main))
        let views: [(String, AccountView)] = [
            ("menu bar", MenuBarItems.Profile(entry: main, usage: nil, view: AccountView.of(Store.status("main"))).view),
            ("card", AccountRow(entry: main, status: Store.status(for: main)).view),
            ("palette row", { let row = AccountRow(entry: main, status: Store.status(for: main))
                              var v = row.view; v.label = row.needsLogin || row.view.clash != nil ? v.label : row.subtitle; return v }()),
            ("Settings", AccountSettings(entry: .constant(main), model: model).view)]
        for (s, v) in views { check(v == want, "\(name): \(s) agrees on the account, the numbers' owner and the line") }
        let panel = DetailsInfo(name: "x", icon: NSImage(), login: nil, expected: nil, mismatch: false, plan: nil, fiveHour: nil, fiveHourResets: nil,
                                weekly: nil, weeklyResets: nil, updated: nil, source: nil, problem: nil, renewNote: nil, needsLogin: false).taking(want)
        check(panel.active == want.label && panel.activeNote == want.line && panel.activeLit == want.lit, "\(name): the Dock panel agrees")
        check(SwitchMenu.dockTitle(name: "P", want, plan: nil) == (want.short.map { "Claude P · \($0) in use" } ?? "Claude P"), "\(name): the Dock menu agrees")
        check(QuickChatTarget(main).email == want.label, "\(name): quick chat agrees")
        check(Store.status(for: main)?.weekly == 40, "\(name): the record's own numbers show (they are the account the record names)")
        if name == "different" { check(want.label == u2.email && want.numbersOwner == u1.email, "different: u2 in use, the numbers u1's") }
        if app == appBack {
            check(want.label == u1.email && want.lit && want.line == nil && !(panel.activeNote ?? "").contains("can't be read"),
                  "\(name): u1 in use from the app, no screen says the app can't be read")
        }
        // no surface lists the active account on standby too; the in-use box's stored-seat line only under that seat
        let listed = main.listed(by: want)
        let activeOnStandby = listed.standby.contains { $0.seat?.account == app.account }
        let menuKeys = SwitchMenu.lines(listed).map(\.key) + listed.backOffers().map(\.key)
        let trayKeys = listed.cardTrays().map(\.id)
        let k2 = AccountEntry.standbyStatusID("main", "k2")
        let settingsView = AccountSettings(entry: .constant(main), model: model)
        if app.account == u2.account {
            check(!activeOnStandby && !menuKeys.contains(k2) && !trayKeys.contains(k2) && QuickChatSwitchOffer.best(main)?.key != k2,
                  "\(name): u2 (in use) is on no standby list: Settings, card trays, Dock and menu bar menus, Switch account ›, quick chat")
            check(!settingsView.seatShown, "\(name): the in-use box shows u2, so its note about u1's own folder is left out")
        } else {
            check(listed.standby.map(\.id) == main.standby.map(\.id), "\(name): the standby list is as it was")
            if app.account == u1.account { check(settingsView.seatShown, "\(name): the in-use box shows the stored account: its own notes stay") }
        }
    }
    // a record from before the resolver: the sign-in it was read for
    var old = IconStatus(state: "ok"); old.loginEmail = u1.email
    check(AccountView.of(old).label == u1.email && AccountView.of(old).line == nil, "an older record: its sign-in, no line")
    // a switch: the record already names ultra-2 as the numbers' owner, the store still holds ultra-1's numbers
    var mid = IconStatus(state: "ok"); mid.loginEmail = u1.email; mid.weekly = 88; mid.updatedAt = t0; mid.plan = "Ultra"
    mid.resolved = res(main, appU2, code: u2, numbers: u2.email)
    _ = Store.writeStatus("main", mid)
    let shownMid = Store.status(for: main)
    check(shownMid?.weekly == nil && shownMid?.updatedAt == nil, "after a switch, ultra-1's numbers never show under ultra-2, not even for a moment")
    check(AccountRow(entry: main, status: shownMid).limits.allSatisfy { $0.p == nil } && AccountView.of(shownMid).label == u2.email,
          "the card shows ultra-2 with no numbers until the new read")
    mid.loginEmail = u2.email; mid.weekly = 12; _ = Store.writeStatus("main", mid)
    check(Store.status(for: main)?.weekly == 12, "the new read: ultra-2's own numbers show")
    // the status line's numbers (no sign-in address) read from the account in use's kept folder, whose address the record
    // has as the numbers' owner while the working folder names another: they show
    var line = IconStatus(state: "ok"); line.loginEmail = nil; line.expectedEmail = "free@example.com"; line.weekly = 33; line.updatedAt = t0
    line.source = "Claude Code status line"
    line.resolved = res(main, appU1, code: u1, numbers: u1.email)
    _ = Store.writeStatus("main", line)
    check(Store.status(for: main)?.weekly == 33 && Store.status(for: main)?.updatedAt == t0, "status-line numbers from a kept folder show (no address to tell them apart by)")
}

// ============ 4. a standby account's old numbers are never shown ============
do {
    var st = IconStatus(state: "expired"); st.loginEmail = u2.email; st.weekly = 97; st.updatedAt = t0
    _ = Store.writeStatus(AccountEntry.standbyStatusID("main", "k2"), st)
    try? fm.createDirectory(atPath: expand("~/.claude-main-u2"), withIntermediateDirectories: true)
    let shown = Store.status(for: main, standby: main.standby[0])
    check(shown?.weekly == nil && shown?.updatedAt == t0 && shown?.state == "expired", "its kept sign-in ran out: no numbers, when they were read kept")
    st.state = "ok"; _ = Store.writeStatus(AccountEntry.standbyStatusID("main", "k2"), st)
    check(Store.status(for: main, standby: main.standby[0])?.weekly == 97, "a live kept sign-in: its numbers")
    try? fm.removeItem(atPath: expand("~/.claude-main-u2"))
    check(Store.status(for: main, standby: main.standby[0])?.weekly == nil, "its kept folder gone: no numbers")
    let look = StandbyLook.of(email: u2.email!, hasFolder: true, linked: true, folderSeat: u2, clash: nil, state: "expired", hasNumbers: true,
                              problem: nil, lastRead: t0, now: t0.addingTimeInterval(3600))
    check(look.line?.hasPrefix("Last read ") == true && look.keys == [.signInAgain], "an expired standby says when it was last read, with Sign in again")
    let live = StandbyLook.of(email: u2.email!, hasFolder: true, linked: true, folderSeat: u2, clash: nil, state: "ok", hasNumbers: false, problem: nil)
    check(live.line?.contains("renew") == false, "no promise that its sign-in renews by itself")
}

// ============ 6. a deleted kept folder is never made again: no claude for a folder that isn't there ============
do {
    var keychainAsks: [String] = []
    Login.runSecurity = { keychainAsks.append($0.joined(separator: " ")); return (44, Data()) }   // never the Keychain: "no such item"
    var launches: [String] = []
    FolderGuard.launchSeam = { what, dir in launches.append("\(what) \(dir)"); return false }
    let gone = "~/.claude-gone-kept"
    try? fm.removeItem(atPath: expand(gone))
    var p = profile("pk", "~/.claude-pk", u1); p.claudeWindow = false; p.autoRenew = true
    try? fm.createDirectory(atPath: expand("~/.claude-pk"), withIntermediateDirectories: true)
    p.standby = [StandbyAccount(email: u2.email!, seat: u2, configDir: gone, id: "kg")]
    check(p.readerEntry(for: p.standby[0]) == nil, "a kept folder that isn't there has no reader")
    check(p.readerEntry(for: StandbyAccount(email: u2.email!, seat: u2, configDir: "~/.claude-pk", id: "y"))?.autoRenew == true,
          "a standby account's kept sign-in is renewed while its folder is there (the absent one below never is)")
    // a kept folder that is a link to a real folder: read (only launching refuses links)
    try? fm.createSymbolicLink(atPath: expand("~/.claude-pk-link"), withDestinationPath: expand("~/.claude-pk"))
    check(p.readerEntry(for: StandbyAccount(email: u2.email!, seat: u2, configDir: "~/.claude-pk-link", id: "l")) != nil
          && FolderGuard.isFolder("~/.claude-pk-link") && !FolderGuard.folderReady("~/.claude-pk-link"),
          "a symlinked kept folder is read, never launched into")
    try! Store.save([p])
    // the agent: its readers made, ticked, the renew timer's work asked for
    let agent = AgentDelegate()
    agent.reload()
    agent.tick()
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    // a reader for the missing folder all the same (as an older build made it), asked to renew
    var r = p.readerEntry(for: StandbyAccount(email: u2.email!, seat: u2, configDir: "~/.claude-pk", id: "x")) ?? p
    r.configDir = gone; r.autoRenew = true
    let reader = UsageReader(r, defaults: UserDefaults(suiteName: "cl-audit-surfaces-test-\(getpid())")!)
    reader.renewLogin()
    reader.tick()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    reader.stop()
    check(!fm.fileExists(atPath: expand(gone)), "the deleted kept folder is still gone after the agent's tick and a renew")
    check(!launches.contains { $0.hasSuffix(gone) }, "no claude was started for it: \(launches)")
    let goneItems = Account(r).keychainServices
    check(!keychainAsks.contains { a in goneItems.contains { a.contains($0) } }, "and its sign-in was never read (no Keychain ask for its item)")
    check(ClaudeCLI.renew("/usr/bin/false", account: Account(r)) == false && !fm.fileExists(atPath: expand(gone)), "Renew sign-in refuses a missing folder")
    check(ClaudeCLI.logout("/usr/bin/false", configDir: gone) == false && !fm.fileExists(atPath: expand(gone)), "so does logout")
    try? fm.createSymbolicLink(atPath: expand("~/.claude-linked-kept"), withDestinationPath: expand("~/.claude-pk"))
    check(!FolderGuard.folderReady("~/.claude-linked-kept") && !FolderGuard.folderReady("~/.claude-linked-kept", creating: true), "a link is never used, nor made into a folder")
    check(FolderGuard.folderReady("~/.claude") && FolderGuard.folderReady("~/.claude-pk"), "the default folder, and a folder that is there, are fine")
    check(FolderGuard.mayLaunch("login", "~/.claude-new-signin", creating: true) == false && fm.fileExists(atPath: expand("~/.claude-new-signin")),
          "a sign-in the person starts makes its new folder first (the seam then stops the launch here)")
    check(launches.contains("login ~/.claude-new-signin"), "…and only then would it launch")
    FolderGuard.launchSeam = nil
}

// ============ 5. no screen reads the sign-in files or a seat itself ============
do {
    let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    let surfaceFiles = ["MenuBar.swift", "IconApp.swift", "Details.swift", "SwitchMenu.swift", "QuickChat.swift", "QuickChatViews.swift", "QuickChatCard.swift"]
    let forbidden = [".claude.json", "config.json", "main.log", "Logs/Claude", "claudeJSON(", "signedInSeat(", "lastKnownAccountUuid",
                     "expectedEmail(configDir", "FolderFactsCache", "seatMove(", "AppSignIn.", "entry.seat", "e.seat?.", "profile.entry.seat"]
    var reads: [String] = []
    for f in surfaceFiles {
        let lines = (try? String(contentsOf: src.appendingPathComponent(f), encoding: .utf8))?.components(separatedBy: "\n") ?? ["(missing \(f))"]
        for (i, l) in lines.enumerated() where !l.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !l.contains("Seat(account: \"sample\"") {
            for p in forbidden where l.contains(p) { reads.append("\(f):\(i + 1) \(p)") }
        }
    }
    func section(_ f: String, from a: String, to b: String) -> [String] {
        let t = (try? String(contentsOf: src.appendingPathComponent(f), encoding: .utf8)) ?? ""
        guard let r1 = t.range(of: a), let r2 = t.range(of: b, range: r1.upperBound..<t.endIndex) else { return ["(\(f): section not found)"] }
        return t[r1.lowerBound..<r2.lowerBound].components(separatedBy: "\n")
    }
    for (f, a, b) in [("Launcher.swift", "struct AccountCard", "\n}\n"), ("Settings.swift", "func inUseBox(", "    /// With more than one account, the one in use")] {
        for l in section(f, from: a, to: b) where !l.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            for p in forbidden where l.contains(p) { reads.append("\(f) \(p): \(l.trimmingCharacters(in: .whitespaces).prefix(60))") }
            if l.contains("section not found") { reads.append(l) }
        }
    }
    check(reads.isEmpty, "no screen reads .claude.json, config.json, the app's log or a seat itself: \(reads)")

    // every launcher of `claude` (or of the Claude app with CLAUDE_CONFIG_DIR) asks FolderGuard before it starts anything
    func body(_ f: String, from a: String, until b: String) -> String {
        let t = (try? String(contentsOf: src.appendingPathComponent(f), encoding: .utf8)) ?? ""
        guard let r1 = t.range(of: a), let r2 = t.range(of: b, range: r1.upperBound..<t.endIndex) else { return "" }
        return String(t[r1.lowerBound..<r2.upperBound])
    }
    let launchers: [(String, String, String, String)] = [
        ("Config.swift", "static func openLogin(", "openTerminal(file)", "login"),
        ("Config.swift", "static func logout(", "p.run()", "logout"),
        ("Config.swift", "static func renew(", "p.run()", "renew"),
        ("Launcher.swift", "static func openClaude(", "openApplication(", "the Claude window"),
        ("Launcher.swift", "private static func openTerminal(", "Installer.run(", "Terminal"),
        ("QuickChatEngine.swift", "func start(environment", "process.run()", "quick chat")]
    for (f, a, launch, what) in launchers {
        let b = body(f, from: a, until: launch)
        check(!b.isEmpty && b.contains("FolderGuard.mayLaunch("), "\(what): FolderGuard is asked before it launches")
    }
    // and nothing else in the app starts `claude` with a profile's folder
    var launchSites: [String] = []
    for f in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where f.hasSuffix(".swift") {
        let t = (try? String(contentsOf: src.appendingPathComponent(f), encoding: .utf8)) ?? ""
        for (i, l) in t.components(separatedBy: "\n").enumerated() where l.contains("env[\"CLAUDE_CONFIG_DIR\"] = ") && !l.contains("= nil") {
            launchSites.append("\(f):\(i + 1)")
        }
    }
    check(launchSites.allSatisfy { s in ["Config.swift", "Launcher.swift", "QuickChatEngine.swift"].contains { s.hasPrefix($0) } },
          "every place that hands a folder to claude is one of the guarded launchers: \(launchSites)")
    let script = body("Launcher.swift", from: "private static func openTerminal(", until: "exec \\(q(claude))")
    check(script.contains("[ -d \\\"$CLAUDE_CONFIG_DIR\\\" ] && [ ! -L \\\"$CLAUDE_CONFIG_DIR\\\" ]"), "the Terminal script checks the folder again itself before exec claude")
}

print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
