// Surfaces checks for cl_audit: one answer about each profile's account (Sources/AccountResolver.swift), written once into its
// status record, and every screen reading it alike: the menu bar, the Dock icon's menu and panel, the dashboard card, Settings ▸
// Accounts, the Switch page and quick chat's profile line. Also the Claude app's account (Sources/AppSignIn.swift): its
// config.json names the account, its log gives the organisation and whether it signed out (an account switched in place and
// back included; the log's own account line without config.json); old numbers never shown (a stale status line, a passed
// reset, an expired sign-in); a deleted folder never made again (FolderGuard), and no screen reading the sign-in files itself.
//
// Runs only with HOME and CFFIXED_USER_HOME = .../Checks/.work/surfaces/home (Checks/run.sh sets and guards it). Fake data only:
// example.com addresses, zero-pattern ids, made-up log lines and config.json files in the throwaway home. Nothing here opens
// an app, the Dock or Terminal, and nothing touches the Keychain.

import AppKit
import ProfileCore
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
/// The Dock icon of a profile as the Dock app draws it from the one value (IconApp: its face, its panel, its right-click menu).
@MainActor func dockOf(_ e: AccountEntry, _ s: ProfileShow) -> (face: TileModel, panel: DetailsInfo, menu: NSMenu) {
    let d = AppDelegate(); d.entry = e; d.show = s
    return (d.model(), d.detailsInfo(), d.profileMenu())
}
/// The menu bar icon's menu of a profile, as the agent builds it (MenuBarItems.menuNeedsUpdate).
@MainActor func menuBarMenu(_ s: ProfileShow) -> NSMenu {
    let items = MenuBarItems(profiles: { [MenuBarItems.Profile(show: s)] }, refresh: { _ in })
    let m = NSMenu(title: s.entry.id)
    items.menuNeedsUpdate(m)
    return m
}
/// Every title of a menu and its submenus.
func titles(_ m: NSMenu) -> [String] { m.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) } }
/// The dashboard card's row of a profile, as the dashboard builds it (LauncherModel.reload): the one value of its saved record.
func cardRow(_ e: AccountEntry, now: Date = Date()) -> AccountRow { AccountRow(entry: e, show: ProfileShow.load(e, now: now)) }
/// The Dock icon's preview (Settings.swift's `preview`, which the Dock's tiles and Settings' tile draw) for a record that has no
/// numbers (signed out, expired, split) or none at all (an existing profile whose record is missing): the blank tile, never the
/// samples (23 % and 41 %), which only a profile that doesn't exist yet (`sample: true`, no record) draws.
func blankTile(_ p: AccountEntry) -> Data? {
    Painter.image(TileModel(label: p.label.isEmpty ? "?" : p.label, fiveHour: nil, weekly: nil, stale: false, style: p.style,
                            warn: false, tint: p.color, frame: p.frame), pixels: 128).tiffRepresentation
}
func previewShowsNone(_ p: AccountEntry, _ rec: IconStatus?) -> Bool {
    let blank = blankTile(p)
    let sample = preview(p, status: nil, sample: true).tiffRepresentation
    return blank != nil && sample != blank && preview(p, status: rec).tiffRepresentation == blank
        && preview(p, status: rec, sample: false).tiffRepresentation == blank
        && preview(p, status: nil).tiffRepresentation == blank                  // an existing profile without a record: blank too
}

/// Settings' panel preview (`samplePanel`) for a record that has no numbers: no limit, no full panel, never the samples (23 % and 58 %).
func panelShowsNone(_ p: AccountEntry, _ rec: IconStatus?) -> Bool {
    func none(_ info: DetailsInfo) -> Bool {
        info.fiveHour == nil && info.weekly == nil && info.fiveHourResets == nil && info.weeklyResets == nil
            && info.limits.allSatisfy { $0.p == nil && $0.resets == nil } && info.full == nil
    }
    return none(samplePanel(p, status: rec)) && none(samplePanel(p, status: nil))      // (a missing record: none either)
}

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
    // the same second as config.json (a stamp without milliseconds, config.json written half a second later): signed out
    let sameSecond = home("a2-samesec", log: story + ["\(AppSignIn.timeFormatShort.string(from: launched.addingTimeInterval(342 * 60))) [info] [LocalSessionManager] Account logged out"],
                          config: a, configAt: 342 + 0.5 / 60)
    check(read(sameSecond).state == .loggedOut, "Account logged out in the same second as config.json is written: signed out")
    // at most the newest maxLogFiles files are read: an account line only in the seventh isn't
    let many = home("a2-many", log: ["\(at(350)) [info] something else"], config: a)
    for n in 1...6 { put(many.logs.appendingPathComponent("main\(n).log").path, n == 6 ? story.joined(separator: "\n") + "\n" : "\(at(350)) [info] nothing\n") }
    check(AppSignIn.logFiles(many.logs).count == AppSignIn.maxLogFiles && read(many).org == nil && read(many).account == a,
          "at most the newest 5 log files are read")
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
main.standby = [StandbyAccount(email: u2.email!, seat: u2, id: "k2")]
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
    // a read from just before the folder's sign-in changed: the app signed out, the folder already on a free account, the
    // numbers still u1's: labelled with the address they were read for
    let late = res(main, appOut, code: Seat(account: uuid(9), organization: uuid(109), email: "free@example.com"), numbers: u1.email)
    var lateRec = IconStatus(state: "ok"); lateRec.loginEmail = u1.email; lateRec.weekly = 94; lateRec.resolved = late
    // (B8: numbersFor is only ever the reading's own account: u1's here, and the reading is stale, so they show nowhere)
    check(!late.fromApp && late.email == "free@example.com" && !late.differs && late.numbersFor == u1.email && late.readStale == true
          && late.codeName == "free@example.com",
          "no app: Claude Code's folder account in use; the numbers stay the reading's (u1's), marked stale")
    _ = Store.writeStatus("late", lateRec)
    check(Store.status(for: profile("late", "~/.claude-late", nil))?.weekly == nil,
          "an older read's numbers (ultra-1's) never show once the folder is on another account: none until its own read")
    check(res(main, AppSignIn.Login(account: u1.account.uppercased(), org: nil, state: .known, source: "config", at: nil), code: u1, numbers: u1.email).line == nil,
          "the same account in any case: no line")
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
            ("menu bar", MenuBarItems.Profile(show: ProfileShow.load(main)).view),
            ("card", cardRow(main).view),
            ("palette row", { let row = cardRow(main)
                              var v = row.view; v.label = row.needsLogin || row.view.clash != nil ? v.label : row.subtitle; return v }()),
            ("Settings", AccountSettings(entry: .constant(main), model: model).view),
            ("Switch page", SwitchPage(entry: main, standby: main.standby[0], model: model, runner: model.runner(of: main.id)).view)]
        for (s, v) in views { check(v == want, "\(name): \(s) agrees on the account, the numbers' owner and the line") }
        // the Dock panel from the one value (each case here is signed in and readable: the lamp is the record's)
        let panel = DetailsInfo.of(ProfileShow.load(main), name: "x", icon: NSImage(), problem: nil)
        let splitHere = ProfileShow.load(main).display.split != nil
        // (in a clash the app didn't decide, every surface names the profile's own account, never the folder's: step 3c)
        let named = want.clash != nil && Store.status("main")?.resolved?.fromApp != true ? main.seat?.email : want.label
        let mainShow = ProfileShow.load(main)
        check(panel.accountLine?.text == named && (panel.activeNote == want.line || splitHere) && panel.activeLit == want.lit,
              "\(name): the Dock panel agrees (as drawn: \(panel.accountLine?.text ?? "no account line"))")
        check(SwitchMenu.dockTitle(name: "P", mainShow.named, plan: nil) == (named.map { "Claude P · \(AccountNames.short($0))" } ?? "Claude P")
              && mainShow.named.inUseLine == named.map(AccountNames.short), "\(name): the Dock menu and the menu bar row agree")
        let qcMain = QuickChatTarget(main)
        check(qcMain.email == want.numbersOwner && qcMain.shownEmail == (want.clash != nil ? named : want.numbersOwner),
              "\(name): quick chat's process on the folder's account, even when the app decided the one in use; its header names it, except in a clash (the profile's own, as the menus): \(qcMain.shownEmail ?? "none")")
        // (B8: in the split, the Claude app on another account than Claude Code, they are not the profile's: none show)
        check(Store.status(for: main)?.weekly == (splitHere ? nil : 40),
              "\(name): the record's own numbers show, except in the split (the app on another account): \(splitHere)")
        if name == "different" { check(want.label == u2.email && want.numbersOwner == u1.email, "different: u2 in use, the numbers u1's") }
        if app == appBack {
            check(want.label == u1.email && want.lit && want.line == nil && !(panel.activeNote ?? "").contains("unreadable"),
                  "\(name): u1 in use from the app, no screen says the app can't be read")
        }
        // no surface lists the active account on standby too
        let listed = main.listed(by: want)
        let activeOnStandby = listed.standby.contains { $0.seat?.account == app.account }
        let menuKeys = SwitchMenu.lines(listed).map(\.key)
        let trayKeys = listed.cardTrays().map(\.id)
        let k2 = AccountEntry.switchKey("main", "k2")
        if app.account == u2.account {
            check(!activeOnStandby && !menuKeys.contains(k2) && !trayKeys.contains(k2) && QuickChatSwitchOffer.best(main)?.key != k2,
                  "\(name): u2 (in use) is on no standby list: Settings, card trays, Dock and menu bar menus, Switch account ›, quick chat")
        } else {
            check(listed.standby.map(\.id) == main.standby.map(\.id) && menuKeys.contains(k2), "\(name): the standby list is as it was")
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
    check(cardRow(main).limits.allSatisfy { $0.p == nil } && AccountView.of(shownMid).label == u2.email,
          "the card shows ultra-2 with no numbers until the new read")
    mid.loginEmail = u2.email; mid.weekly = 12; _ = Store.writeStatus("main", mid)
    check(Store.status(for: main)?.weekly == 12, "the new read: ultra-2's own numbers show")
    // the status line's numbers (no sign-in address): nothing to tell them apart by, so they show
    var line = IconStatus(state: "ok"); line.loginEmail = nil; line.expectedEmail = "free@example.com"; line.weekly = 33; line.updatedAt = t0
    line.source = "Claude Code status line"
    line.resolved = res(main, appU1, code: u1, numbers: u1.email)
    _ = Store.writeStatus("main", line)
    check(Store.status(for: main)?.weekly == 33 && Store.status(for: main)?.updatedAt == t0, "status-line numbers show (no address to tell them apart by)")
}

// ============ 3b. after a switch, every surface names the new account; the old one is only standby; TO never lists the account in use ============
do {
    let u4 = seat(4, "ultra-4@example.com")
    var sw = profile("sw", "~/.claude-sw", u1); sw.claudeWindow = false
    sw.standby = [StandbyAccount(email: u2.email!, seat: u2, id: "w2"), StandbyAccount(email: u4.email!, seat: u4, id: "w4")]
    // the record as it was before the switch (ultra-1 in use), then the folder signed in to ultra-2
    var rec = IconStatus(state: "ok"); rec.loginEmail = u1.email; rec.weekly = 40; rec.updatedAt = t0
    rec.resolved = AccountResolver.resolve(sw, among: [sw], app: .unknown, code: u1, loginEmail: u1.email, names: [:], now: t0)
    _ = Store.writeStatus("sw", rec)
    put(expand("~/.claude-sw/.claude.json"), #"{"oauthAccount":{"accountUuid":"\#(u2.account)","organizationUuid":"\#(u2.organization!)","emailAddress":"\#(u2.email!)"}}"#)
    let after = FolderRules.noteAccounts([sw], signedIn: { _ in u2 }, status: { _ in nil }, now: t0)[0]
    let m = SettingsModel()
    m.accounts = [after]
    m.resolveNow("sw")                                      // as the Switch page's end does: the record answered again at once
    let want = AccountView.of(Store.status(for: after))
    check(after.seat?.same(u2) == true && want.label == u2.email, "after the switch the record names ultra-2: \(want.label ?? "-")")
    let page = SwitchPage(entry: after, standby: after.standby[0], model: m, runner: m.runner(of: "sw"))
    let views: [(String, AccountView)] = [
        ("menu bar", MenuBarItems.Profile(show: ProfileShow.load(after)).view),
        ("card", cardRow(after).view),
        ("Settings", AccountSettings(entry: .constant(after), model: m).view),
        ("Switch page", page.view)]
    for (s, v) in views { check(v == want && v.label == u2.email, "after a switch: \(s) names ultra-2") }
    check(want.numbersOwner == u2.email && want.line == AccountResolver.staleWords && Store.status(for: after)?.weekly == nil,
          "after a switch ultra-1's numbers never show: none until a read for ultra-2 succeeds (the line says read for another account, and the way back if it stays)")
    let listed = after.listed(by: want)
    check(!listed.standby.contains { $0.seat?.same(u2) == true } && listed.standby.filter { $0.seat?.same(u1) == true }.count == 1,
          "the old account is on standby once, the new one never: \(listed.standby.map(\.email))")
    check(!page.pickList.contains { $0.seat?.same(u2) == true }, "the Switch page's TO never lists the account in use")
    // the Claude app on a standby account (ultra-4) while Claude Code is on ultra-2: ultra-4 is in use, so not in TO
    var rec4 = Store.status("sw") ?? rec
    var withWin = after; withWin.claudeWindow = true
    rec4.resolved = AccountResolver.resolve(withWin, among: [withWin], app: AppSignIn.Login(account: u4.account, org: u4.organization, state: .known, source: "log", at: t0),
                                            code: u2, loginEmail: u2.email, names: [:], now: t0)
    _ = Store.writeStatus("sw", rec4)
    m.accounts = [withWin]
    let page4 = SwitchPage(entry: withWin, standby: withWin.standby[0], model: m, runner: m.runner(of: "sw"))
    check(page4.view.label == u4.email && !page4.pickList.contains { $0.seat?.same(u4) == true } && page4.pickList.contains { $0.seat?.same(u1) == true },
          "the app on ultra-4: in use, so not offered as TO; ultra-1 is: \(page4.pickList.map(\.email))")
}

// ============ 3c. one writer: the cl_audit window never writes a record; the agent rewrites it when asked and at every read ============
do {
    let keepAnnounce = Store.announce, keepAnnounceStatus = Store.announceStatus
    Store.announce = {}; Store.announceStatus = { _ in }       // a throwaway home: no running cl_audit is told
    defer { Store.announce = keepAnnounce; Store.announceStatus = keepAnnounceStatus }
    Login.runSecurity = { _ in (44, Data()) }                   // no sign-in (a fake answer, never the Keychain)
    var posts: [String] = []
    UsageReader.testPoster = { _, title, _, _, _ in posts.append(title); return 0 }
    defer { UsageReader.testPoster = nil }
    let folder = Store.statusFolder
    func snapshot() -> [String: Data] {
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.map { ($0, (try? Data(contentsOf: folder.appendingPathComponent($0))) ?? Data()) })
    }
    func stamp(_ id: String) -> Store.FileStamp? { Store.FileStamp.of(folder.appendingPathComponent("\(id).json")) }
    func bytes(_ id: String) -> Data? { try? Data(contentsOf: folder.appendingPathComponent("\(id).json")) }
    // a profile on ultra-1 whose folder signed in to ultra-2 (a switch ended); its record, the agent's, still names ultra-1
    var ow = profile("ow", "~/.claude-ow", u1); ow.claudeWindow = false
    ow.standby = [StandbyAccount(email: u2.email!, seat: u2, id: "o2")]
    var old = IconStatus(state: "ok"); old.loginEmail = u1.email; old.weekly = 40; old.updatedAt = Date()
    old.resolved = AccountResolver.resolve(ow, among: [ow], app: .unknown, code: u1, loginEmail: u1.email, names: [:], now: t0)
    _ = Store.writeStatus("ow", old)
    let oldBytes = bytes("ow")
    put(expand("~/.claude-ow/.claude.json"), #"{"oauthAccount":{"accountUuid":"\#(u2.account)","organizationUuid":"\#(u2.organization!)","emailAddress":"\#(u2.email!)"}}"#)
    let after = FolderRules.noteAccounts([ow], signedIn: { _ in u2 }, status: { _ in nil }, now: t0)[0]
    var fresh = profile("ow2", "~/.claude-ow2", u3); fresh.claudeWindow = false       // a profile with no record yet
    try! Store.save([after, fresh])
    let before = snapshot(), beforeStamp = stamp("ow")
    let m = SettingsModel()
    m.accounts = [after, fresh]
    m.resolveNow("ow")                                          // as the Switch page's end does
    m.resolveWithoutAgent()                                     // as the window does every 3 s while the agent isn't running
    check(snapshot() == before && stamp("ow") == beforeStamp && bytes("ow2") == nil,
          "Settings' refresh (resolveNow, resolveWithoutAgent) writes nothing to status/: \(snapshot().keys.sorted())")
    check(Store.isHeld("ow") && AccountView.of(Store.status(for: after)).label == u2.email,
          "while it waits for the agent, the window shows its own answer from memory: ultra-2 in use")
    check(Store.isHeld("ow2") && Store.status("ow2")?.resolved != nil, "with the agent away, its answer for a profile with no record is held too")
    check(StatusCodec.decode(bytes("ow") ?? Data())?.resolved == old.resolved && Store.status("ow")?.loginEmail == u1.email,
          "the record on disk stays the agent's, whole (no lossy re-save of what the window was shown)")
    // the agent's reader: its first save lands its own record, and the window's answer is let go (the record wins)
    let reader = UsageReader(after, defaults: UserDefaults(suiteName: "cl-audit-surfaces-onewriter-\(getpid())")!)
    reader.save()
    let agentBytes = bytes("ow")
    check(agentBytes != nil && agentBytes != oldBytes && !Store.isHeld("ow") && Store.status("ow")?.resolved?.email == u2.email,
          "the agent's new record lands: the held answer goes, the record names ultra-2")
    // a wrong record (an older cl_audit window's write): a plain tick leaves it, the reader's state didn't change...
    _ = Store.writeStatus("ow", old)
    reader.save()
    check(bytes("ow") == oldBytes, "a save with nothing changed writes nothing (no write on every tick)")
    // ...but a refresh request rewrites the record at once, even with its state unchanged
    reader.refreshNow()
    check(bytes("ow") == agentBytes, "the agent rewrites its record on a refresh request even when its state is unchanged: the wrong one is gone")
    // and the next read replaces a wrong record, even a read that leaves the reader's state as it was (Anthropic busy twice)
    let busy = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 429, httpVersion: nil, headerFields: nil)
    reader.finish(data: nil, response: busy, error: nil, asked: Date(), gen: reader.generation)
    let busyBytes = bytes("ow")
    _ = Store.writeStatus("ow", old)
    reader.finish(data: nil, response: busy, error: nil, asked: Date(), gen: reader.generation)
    check(busyBytes != nil && busyBytes != oldBytes && bytes("ow") == busyBytes && Store.status("ow")?.resolved?.email == u2.email,
          "a wrong record is replaced on the agent's next read, though that read left its state unchanged")
    // a read with numbers lands them
    let reply = Data(#"{"seven_day":{"utilization":30,"resets_at":"2099-01-02T00:00:00Z"}}"#.utf8)
    let ok200 = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)
    reader.finish(data: reply, response: ok200, error: nil, asked: Date(), gen: reader.generation)
    let replacedWeek: Double? = Store.status("ow")?.weekly
    check(replacedWeek == 30, "a read with numbers saves them: \(String(describing: replacedWeek))")
    reader.stop()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))    // the refresh's sign-in read (no sign-in) ends, dropped
    check(posts.isEmpty, "no alert from these reads: \(posts)")
    // a record from before the resolver (an old Dock icon's file) still decodes, with or without a held answer over it
    put(folder.appendingPathComponent("oldrec.json").path, #"{"loginEmail":"ultra-1@example.com","state":"ok","updatedAt":1800000000,"weekly":12}"#)
    check(Store.status("oldrec")?.weekly == 12 && Store.status("oldrec")?.resolved == nil, "an old record decodes as before")
    let answer = AccountResolver.resolve(ow, among: [ow], app: .unknown, code: u1, loginEmail: u1.email, names: [:], now: t0)
    Store.hold("oldrec", answer, file: Store.stamp("oldrec"), lifetime: 600)
    check(Store.status("oldrec")?.weekly == 12 && Store.status("oldrec")?.resolved == answer, "a held answer over an old record: its numbers kept, the answer shown")
    var rewritten = StatusCodec.decode(bytes("oldrec") ?? Data()) ?? IconStatus(state: "ok"); rewritten.weekly = 13
    _ = Store.writeStatus("oldrec", rewritten)
    check(!Store.isHeld("oldrec") && Store.status("oldrec")?.weekly == 13 && Store.status("oldrec")?.resolved == nil,
          "the agent's write of it wins over the held answer")
    // the same bytes written again (the agent's rewrite of an unchanged state) let the held answer go too
    let same = bytes("oldrec")
    Store.hold("oldrec", answer, file: Store.stamp("oldrec"), lifetime: 600)
    _ = Store.writeStatus("oldrec", StatusCodec.decode(same ?? Data()) ?? rewritten)
    check(same != nil && bytes("oldrec") == same && !Store.isHeld("oldrec"), "the same bytes rewritten release the held answer")
    // a write landing while the window works out its answer (after its stamp was taken) counts as the agent's newer record
    let early = Store.stamp("oldrec")
    _ = Store.writeStatus("oldrec", rewritten)
    Store.hold("oldrec", answer, file: early, lifetime: 600)
    check(!Store.isHeld("oldrec"), "a write after the stamp, before the hold: the record wins at once")
    // removal releases it, also one held while there was no file (a removed profile's id given to a new one shows nothing of it)
    Store.removeStatus("oldrec")
    Store.hold("oldrec", answer, file: Store.stamp("oldrec"), lifetime: 600)
    check(Store.isHeld("oldrec"), "an answer held with no record yet")
    Store.removeStatus("oldrec")
    check(!Store.isHeld("oldrec") && Store.status("oldrec") == nil, "removing the record releases the held answer")
    // a held answer expires: a lost refresh or a hung agent can't keep it up
    var quick = ow; quick.pollMinutes = 5
    Store.hold("oldrec", answer, file: nil, lifetime: Store.heldLifetime(quick))
    check(Store.heldLifetime(quick) == 600 && Store.isHeld("oldrec", now: Date().addingTimeInterval(590))
          && !Store.isHeld("oldrec", now: Date().addingTimeInterval(601)) && !Store.isHeld("oldrec"),
          "a held answer lasts two read intervals (10 min at 5), then the record shows")
    // no one but the agent's reader writes a record: every Swift file of the app, the widget, the launcher and the libraries
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var writers: [String] = [], nearWrites: [String] = []
    for dir in ["Sources", "Widget", "Launcher", "Core", "Auth"] {
        let base = root.appendingPathComponent(dir)
        let files = (fm.enumerator(atPath: base.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".swift") }.sorted()
        for f in files {
            var text = (try? String(contentsOf: base.appendingPathComponent(f), encoding: .utf8)) ?? ""
            let name = "\(dir)/\(f)"
            // Config.swift's writeStatus itself (the record and its .prev copy) is the one write next to statusFolder
            if name == "Sources/Config.swift", let a = text.range(of: "    static func writeStatus("),
               let b = text.range(of: "\n    }\n", range: a.upperBound..<text.endIndex) {
                text.replaceSubrange(a.lowerBound..<b.upperBound, with: "\n")
            }
            let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let code = lines.map { $0.hasPrefix("//") || $0.hasPrefix("///") ? "" : $0 }
            for (i, l) in code.enumerated() where l.contains("writeStatus") && name != "Sources/Reader.swift" {
                writers.append("\(name):\(i + 1)")
            }
            guard name != "Sources/Reader.swift" else { continue }
            for (i, l) in code.enumerated() where l.contains(".write(") {
                let near = code[max(0, i - 3)...min(code.count - 1, i + 3)]
                if near.contains(where: { $0.contains("statusFolder") || $0.contains("\"status/") }) { nearWrites.append("\(name):\(i + 1)") }
            }
        }
    }
    check(writers.isEmpty, "writeStatus is used by the agent's reader alone: \(writers)")
    check(nearWrites.isEmpty, "nothing else writes next to the status folder: \(nearWrites)")
}

// ============ 4. a deleted folder is never made again: no claude for a folder that isn't there ============
do {
    var keychainAsks: [String] = []
    Login.runSecurity = { keychainAsks.append($0.joined(separator: " ")); return (44, Data()) }   // never the Keychain: "no such item"
    var launches: [String] = []
    FolderGuard.launchSeam = { what, dir in launches.append("\(what) \(dir)"); return false }
    let gone = "~/.claude-gone"
    try? fm.removeItem(atPath: expand(gone))
    var p = profile("pk", gone, u1); p.claudeWindow = false; p.autoRenew = true
    try? fm.createDirectory(atPath: expand("~/.claude-pk"), withIntermediateDirectories: true)
    // a profile's folder that is a link to a real folder: read, never launched into
    try? fm.createSymbolicLink(atPath: expand("~/.claude-pk-link"), withDestinationPath: expand("~/.claude-pk"))
    check(FolderGuard.isFolder("~/.claude-pk-link") && !FolderGuard.folderReady("~/.claude-pk-link"), "a symlinked folder is read, never launched into")
    try! Store.save([p])
    // the agent: its readers made, ticked, the renew timer's work asked for
    let agent = AgentDelegate()
    agent.reload()
    agent.tick()
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    // a reader for the missing folder, asked to renew
    let reader = UsageReader(p, defaults: UserDefaults(suiteName: "cl-audit-surfaces-test-\(getpid())")!)
    reader.renewLogin()
    reader.tick()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    reader.stop()
    check(!fm.fileExists(atPath: expand(gone)), "the deleted folder is still gone after the agent's tick and a renew")
    check(!launches.contains { $0.hasSuffix(gone) }, "no claude was started for it: \(launches)")
    let goneItems = Account(p).keychainServices
    check(!keychainAsks.contains { a in goneItems.contains { a.contains($0) } }, "and its sign-in was never read (no Keychain ask for its item)")
    check(ClaudeCLI.renew("/usr/bin/false", account: Account(p)) == false && !fm.fileExists(atPath: expand(gone)), "Renew sign-in refuses a missing folder")
    check(ClaudeCLI.logout("/usr/bin/false", configDir: gone) == false && !fm.fileExists(atPath: expand(gone)), "so does logout")
    try? fm.createSymbolicLink(atPath: expand("~/.claude-linked"), withDestinationPath: expand("~/.claude-pk"))
    check(!FolderGuard.folderReady("~/.claude-linked") && !FolderGuard.folderReady("~/.claude-linked", creating: true), "a link is never used, nor made into a folder")
    check(FolderGuard.folderReady("~/.claude") && FolderGuard.folderReady("~/.claude-pk"), "the default folder, and a folder that is there, are fine")
    check(FolderGuard.mayLaunch("login", "~/.claude-new-signin", creating: true) == false && fm.fileExists(atPath: expand("~/.claude-new-signin")),
          "New profile's sign-in makes its brand-new folder first (the seam then stops the launch here)")
    check(launches.contains("login ~/.claude-new-signin"), "…and only then would it launch")

    // no sign-in makes a deleted folder again (A4, on B's sign-in paths): nothing launched, no Terminal, the line or alert
    var terminals: [String] = [], alerts: [String] = []
    ClaudeCLI.openTerminal = { terminals.append($0.path); return true }
    ClaudeCLI.goneSeam = { alerts.append($0) }
    launches.removeAll()
    let goneLine = "Its Claude Code folder is gone (~/.claude-gone): nothing was signed in."
    check(ClaudeCLI.openLogin("/usr/bin/false", account: Account(p), email: u1.email) == false && !fm.fileExists(atPath: expand(gone)),
          "a sign-in for a deleted folder doesn't start and doesn't make it")
    ClaudeCLI.logIn(profile: p)
    ClaudeCLI.logIn(Account(p), email: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(alerts == [goneLine, goneLine] && !fm.fileExists(atPath: expand(gone)),
          "the menus', the Dock menu's and the launcher's Sign in… on a deleted folder: the alert says so, nothing made: \(alerts)")
    let sm = SettingsModel()
    var withStandby = p; withStandby.standby = [StandbyAccount(email: u2.email!, seat: nil, id: "g2")]
    var noSeat = withStandby; noSeat.seat = nil
    sm.accounts = [withStandby]
    AccountSettings(entry: .constant(noSeat), model: sm).signInAgain(email: u1.email)
    check(sm.message == goneLine && !fm.fileExists(atPath: expand(gone)), "Settings' sign-in on a deleted folder: the line, nothing made: \(sm.message)")
    // the switch (to a standby account, and Sign in again): nothing closes, moves or signs in; the line, with Back
    let gr = sm.runner(of: withStandby.id)
    gr.start(withStandby.standby[0])
    check(gr.phase == .failed(goneLine) && !fm.fileExists(atPath: expand(gone)), "a switch on a deleted folder: the line, nothing made: \(gr.phase)")
    gr.reset(); gr.signInAgain()
    check(gr.phase == .failed(goneLine) && !fm.fileExists(atPath: expand(gone)), "Sign in again on a deleted folder: the same")
    // a link says so instead of "gone"
    let linkLine = "Its Claude Code folder (~/.claude-linked) isn't a plain folder (a link?): nothing was signed in."
    check(ClaudeCLI.goneLine("~/.claude-linked") == linkLine && ClaudeCLI.goneLine("~/.claude-pk") == nil, "a link: 'isn't a plain folder'; a folder: no line")
    var lp = p; lp.configDir = "~/.claude-linked"
    sm.accounts = [lp]
    sm.runner(of: lp.id).signInAgain()
    check(sm.runner(of: lp.id).phase == .failed(linkLine), "Sign in again on a folder that is a link: that line")
    check(launches.isEmpty && terminals.isEmpty, "no claude and no Terminal for any of them: \(launches) \(terminals)")
    // the Claude window and Terminal keys on a deleted folder: the alert says why (in the sign-in keys' words), nothing starts;
    // a window opened without a click (the agent reopening it) says nothing
    alerts.removeAll()
    var pw = p; pw.claudeWindow = true; pw.desktop = .separate; pw.desktopDataDir = "~/Library/Application Support/Claude-pk-gone"
    Launcher.openClaude(Account(pw))
    Launcher.openClaude(Account(pw), activate: false)
    Launcher.openTerminal(Account(p))
    check(alerts == ["Its Claude Code folder is gone (~/.claude-gone): the Claude window wasn't opened.",
                     "Its Claude Code folder is gone (~/.claude-gone): nothing was started."]
          && launches.isEmpty && terminals.isEmpty && !fm.fileExists(atPath: expand(gone)),
          "the Claude window's and Terminal's keys on a deleted folder: the alert says why, nothing started or made: \(alerts)")
    // a brand-new folder the person just chose (New profile, first run): still made, owner only, and launched
    let fresh = "~/.claude-new-profile"
    try? fm.removeItem(atPath: expand(fresh))
    FolderGuard.launchSeam = { what, dir in launches.append("\(what) \(dir)"); return true }
    let freshAccount = Account(profile("np", fresh, nil))
    let made = ClaudeCLI.openLogin("/usr/bin/false", account: freshAccount, email: "ultra-8@example.com", creating: true)
    let mode = ((try? fm.attributesOfItem(atPath: expand(fresh)))?[.posixPermissions] as? NSNumber)?.intValue
    check(made && mode == 0o700 && launches == ["login \(freshAccount.configDir)"] && terminals.count == 1, "New profile's sign-in makes its folder (owner only) and launches: \(launches) \(String(mode ?? -1, radix: 8))")
    terminals.forEach { try? fm.removeItem(atPath: $0) }
    ClaudeCLI.goneSeam = nil
    // only the new-folder sign-ins may make a folder
    var creators: [String] = []
    let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    for f in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where f.hasSuffix(".swift") {
        let t = (try? String(contentsOf: src.appendingPathComponent(f), encoding: .utf8)) ?? ""
        for l in t.components(separatedBy: "\n") where l.contains("openLogin(") && l.contains("creating: true") { creators.append(f) }
    }
    check(Set(creators) == ["NewAccount.swift", "FirstRun.swift", "DefaultProfileRunner.swift"] && creators.count == 4,
          "only New profile, first run and the default profile's offer sign in with creating: \(creators)")
    FolderGuard.launchSeam = nil
}

// ============ 5. old numbers are never shown: a stale status line, a passed reset, an expired sign-in ============
do {
    let now = Date()
    let dir = "~/.claude-stale"
    try? fm.createDirectory(atPath: expand(dir), withIntermediateDirectories: true)
    var p = profile("stale", dir, Seat(account: uuid(41), organization: uuid(141), email: "stale-1@example.com"))
    p.claudeWindow = false; p.autoRenew = false
    try! Store.save([p])
    func usageJSON(updated: Date, week: Double, weekResets: Date, five: Double = 100, fiveResets: Date) {
        put(expand(dir) + "/usage.json", """
            {"five_hour":{"used_percentage":\(five),"resets_at":\(Int(fiveResets.timeIntervalSince1970))},\
            "seven_day":{"used_percentage":\(week),"resets_at":\(Int(weekResets.timeIntervalSince1970))},\
            "updated_at":\(Int(updated.timeIntervalSince1970)),"source":"cli"}
            """)
    }
    // the status line file as it was in 26.11.15: written 7 days ago, its week's reset since passed
    let weekAgo = now.addingTimeInterval(-7 * 86400 - 43 * 60)
    usageJSON(updated: weekAgo, week: 90, weekResets: now.addingTimeInterval(-60), fiveResets: weekAgo.addingTimeInterval(3600))
    check(UsageParser.fromStatusLine(Account(p), now: now) == nil, "a 7-day-old status line is ignored as if it weren't there")
    usageJSON(updated: now.addingTimeInterval(-16 * 60), week: 40, weekResets: now.addingTimeInterval(86400), fiveResets: now.addingTimeInterval(3600))
    check(UsageParser.fromStatusLine(Account(p), now: now) == nil, "written 16 minutes ago: ignored")
    usageJSON(updated: now.addingTimeInterval(-60), week: 40, weekResets: now.addingTimeInterval(86400), fiveResets: now.addingTimeInterval(-1))
    let halfPast = UsageParser.fromStatusLine(Account(p), now: now)
    check(halfPast?.weekly == 40 && halfPast?.fiveHour == nil && halfPast?.fiveHourResets == nil,
          "fresh, its 5-hour reset just passed: the week still shows, the 5-hour percent doesn't")
    usageJSON(updated: now.addingTimeInterval(-60), week: 40, weekResets: now.addingTimeInterval(-1), fiveResets: now.addingTimeInterval(-1))
    check(UsageParser.fromStatusLine(Account(p), now: now) == nil, "fresh, both resets passed: nothing left, ignored")
    usageJSON(updated: now.addingTimeInterval(3600), week: 40, weekResets: now.addingTimeInterval(86400), fiveResets: now.addingTimeInterval(7200))
    check(UsageParser.fromStatusLine(Account(p), now: now) == nil, "dated an hour ahead: ignored")
    usageJSON(updated: now.addingTimeInterval(-14 * 60), week: 40, weekResets: now.addingTimeInterval(86400), five: 12, fiveResets: now.addingTimeInterval(3600))
    let fresh = UsageParser.fromStatusLine(Account(p), now: now)
    check(fresh?.weekly == 40 && fresh?.fiveHour == 12 && fresh?.source == "Claude Code status line", "written 14 minutes ago, resets ahead: its numbers")

    // the saved record of 26.11.15 (week 90% from the status line a week ago, the sign-in expired): no numbers on any screen
    var old = IconStatus(state: "expired"); old.expectedEmail = "stale-1@example.com"; old.weekly = 90; old.fiveHour = 100
    old.weeklyResets = now.addingTimeInterval(-60); old.fiveHourResets = weekAgo.addingTimeInterval(3600); old.updatedAt = weekAgo
    old.source = "Claude Code status line"; old.problem = FetchState.expired.menuText
    _ = Store.writeStatus("stale", old)
    func noNumbersAnywhere(_ what: String) {
        let rec = Store.status(for: p)
        check(rec?.state == "expired" && rec?.weekly == nil && rec?.fiveHour == nil && rec?.weeklyResets == nil && rec?.fiveHourResets == nil,
              "\(what): the record as every screen reads it has no numbers, state expired")
        let show = ProfileShow.load(p, now: now)
        let mb = MenuBarItems.Profile(show: show, problem: rec?.problem)
        let glyph = MenuBarItems.item(mb, now: now)
        check(mb.usage == nil && glyph.week == nil && glyph.five == nil && glyph.countdown == nil && show.needsLogin
              && show.keyWords(short: false) == "Sign in…" && !show.display.lamp && show.display.grey,
              "\(what): the menu bar has no bars, no countdown, Sign in…, the lamp off")
        let row = cardRow(p, now: now)
        check(row.limits.allSatisfy { $0.p == nil } && row.full == nil && row.needsLogin && row.subtitle == "sign-in expired",
              "\(what): the card (and Settings' in-use box, which draws its limits) says sign-in expired, no bars, Sign in…")
        check(previewShowsNone(p, rec) && panelShowsNone(p, rec), "\(what): the Dock icon's preview and Settings' panel preview have no numbers, never the samples")
        let panel = DetailsInfo.of(show, name: p.name, icon: NSImage(), problem: rec?.problem)
        check(panel.weekly == nil && panel.fiveHour == nil && panel.needsLogin && !panel.activeLit, "\(what): the Dock panel has no numbers, Sign in…, the lamp off")
        check(panel.noNumbers == "Sign-in expired", "\(what): the Dock panel's age line says Sign-in expired, never Reading usage…")
        let target = QuickChatTarget(p), level = QuickChatLevel(Usage.of(rec), now: now)
        check(target.loginWords == "sign-in expired" && level.week == nil && level.fiveHour == nil && level.full(now) == nil,
              "\(what): quick chat's line says sign-in expired, no level")
    }
    noNumbersAnywhere("the saved record")

    // the agent's reader: the sign-in expired (a fake Keychain answer, never the Keychain), the old status line in the folder
    usageJSON(updated: weekAgo, week: 90, weekResets: now.addingTimeInterval(-60), fiveResets: weekAgo.addingTimeInterval(3600))
    Login.runSecurity = { _ in (0, Data(#"{"claudeAiOauth":{"accessToken":"fake-expired-sign-in","expiresAt":1000}}"#.utf8)) }
    let reader = UsageReader(p, defaults: UserDefaults(suiteName: "cl-audit-surfaces-stale-\(getpid())")!)
    reader.tick()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    check(reader.state == .expired, "the reader sees the sign-in expired")
    check(reader.usage == nil, "the reader took nothing from the 7-day-old status line nor the old record")
    noNumbersAnywhere("after the reader's save")
    // a fresh status line (written now) while the sign-in is expired: still no numbers on any screen (hub decision: an
    // expired or absent sign-in shows none, however new); they come back only with a good read
    usageJSON(updated: Date(), week: 53, weekResets: now.addingTimeInterval(3 * 86400), five: 100, fiveResets: now.addingTimeInterval(1800))
    reader.tick()
    check(reader.usage?.weekly == 53, "the reader took the fresh status line")
    noNumbersAnywhere("a fresh status line with the sign-in expired")
    reader.stop()
    // a fresh status line with a good sign-in: its numbers show (the record's state ok)
    var live = IconStatus(state: "ok"); live.expectedEmail = "stale-1@example.com"; live.weekly = 53; live.weeklyResets = now.addingTimeInterval(86400)
    live.updatedAt = now.addingTimeInterval(-60); live.source = "Claude Code status line"
    _ = Store.writeStatus("stale", live)
    let liveShown = Store.status(for: p)
    check(liveShown?.weekly == 53 && ProfileShow.load(p).noNumbersWords == nil, "a fresh status line still shows its numbers, and the panel its age")
    check(Usage.of(liveShown)?.weekly == 53 && cardRow(p).weekly == 53, "…on the menu bar and the card alike")
    Login.runSecurity = { _ in (44, Data()) }

    // a limit whose reset has passed never shows its percent, from Anthropic too, whatever the state
    var a = IconStatus(state: "ok"); a.expectedEmail = "stale-1@example.com"; a.source = "Anthropic"; a.updatedAt = now.addingTimeInterval(-120)
    a.fiveHour = 100; a.fiveHourResets = now.addingTimeInterval(-30); a.weekly = 53; a.weeklyResets = now.addingTimeInterval(86400)
    a.scoped = [ScopedLimit(name: "Fable", percent: 77, resets: now.addingTimeInterval(-5))]
    _ = Store.writeStatus("stale", a)
    let shown = Store.status(for: p)
    check(shown?.fiveHour == nil && shown?.fiveHourResets == nil && shown?.weekly == 53 && shown?.scoped?.first?.percent == nil,
          "Anthropic's numbers: the 5-hour limit past its reset has no percent (no 100% \"in 0 min\"), the week stays, Fable past its reset none")
    let mbA = MenuBarItems.item(MenuBarItems.Profile(show: ProfileShow.load(p, now: now)), now: now)
    check(mbA.five == nil && mbA.week == 53 && mbA.countdown == nil, "the menu bar: no 5-hour percent, no countdown")
    check(cardRow(p, now: now).full == nil, "the card: nothing full")
    var u = Usage(fiveHour: 100, fiveHourResets: now.addingTimeInterval(-30), weekly: 53, weeklyResets: now.addingTimeInterval(86400),
                  fetchedAt: now, source: "Anthropic")
    check(u.current(now: now).fiveHour == nil && u.current(now: now).weekly == 53, "a Usage past a reset drops that limit")
    u.fiveHourResets = now.addingTimeInterval(60)
    check(u.current(now: now).fiveHour == 100, "…and keeps one whose reset is ahead")
    var ql = QuickChatLevel(nil); ql.week = 99; ql.weekResets = now.addingTimeInterval(-1)
    check(ql.shown(now).percent == nil && ql.current(now).week == nil, "quick chat: a kept week past its reset is neither shown nor merged")
    // numbers read a minute ago, then the sign-in lost: none, expired or signed out alike, when they were read kept
    var e = a; e.state = "expired"; e.fiveHourResets = now.addingTimeInterval(600); e.updatedAt = now.addingTimeInterval(-60)
    check(e.current(now: now).fiveHour == nil && e.current(now: now).weekly == nil && e.current(now: now).updatedAt == e.updatedAt,
          "expired, numbers a minute old: none, when they were read kept")
    e.state = "noLogin"
    check(e.current(now: now).fiveHour == nil && e.current(now: now).weekly == nil && e.current(now: now).updatedAt == e.updatedAt,
          "signed out, numbers a minute old: none, when they were read kept")
    e.state = "ok"
    check(e.current(now: now).fiveHour == 100 && e.current(now: now).weekly == 53, "the same numbers with a good read (ok): shown")

    // signed out (no sign-in at all) with saved numbers: none on any screen, the same as expired; a good read brings them back
    var out = IconStatus(state: "noLogin"); out.expectedEmail = "stale-1@example.com"; out.weekly = 61; out.fiveHour = 22
    out.weeklyResets = now.addingTimeInterval(2 * 86400); out.fiveHourResets = now.addingTimeInterval(3600)
    out.updatedAt = now.addingTimeInterval(-3 * 3600); out.source = "Anthropic"; out.problem = FetchState.noLogin.menuText
    _ = Store.writeStatus("stale", out)
    try? fm.removeItem(atPath: expand(dir) + "/usage.json")
    func noneSignedOut(_ what: String, keepsWhen: Bool) {
        let rec = Store.status(for: p)
        check(rec?.state == "noLogin" && rec?.weekly == nil && rec?.fiveHour == nil && (!keepsWhen || rec?.updatedAt != nil),
              "\(what): the record as every screen reads it has no numbers\(keepsWhen ? ", when they were read kept" : "")")
        let show = ProfileShow.load(p, now: now)
        let mb = MenuBarItems.Profile(show: show, problem: rec?.problem)
        let glyph = MenuBarItems.item(mb, now: now)
        check(mb.usage == nil && glyph.week == nil && glyph.five == nil && show.needsLogin && !show.display.lamp,
              "\(what): the menu bar has no bars, Sign in…, the lamp off")
        let row = cardRow(p, now: now)
        check(row.limits.allSatisfy { $0.p == nil } && row.needsLogin && row.subtitle == "no Claude Code sign-in",
              "\(what): the card and Settings' box: no bars, its state line, Sign in…")
        check(previewShowsNone(p, rec) && panelShowsNone(p, rec), "\(what): the Dock icon's preview and Settings' panel preview have no numbers, never the samples")
        check(rec?.needsLogin == true && rec?.fiveHour == nil && show.noNumbersWords == "Signed out",
              "\(what): the Dock panel (from the same record): no numbers, Sign in…, its age line says Signed out")
        let q = QuickChatTarget(p), ql2 = QuickChatLevel(Usage.of(rec), now: now)
        check(q.loginWords == "no Claude Code sign-in" && ql2.week == nil && ql2.fiveHour == nil, "\(what): quick chat's line says so, no level")
    }
    noneSignedOut("a signed-out record", keepsWhen: true)
    UsageReader.testPoster = { _, _, _, _, _ in 0 }        // no alert leaves the check
    Login.runSecurity = { _ in (44, Data()) }              // no sign-in (a fake answer, never the Keychain)
    let outReader = UsageReader(p, defaults: UserDefaults(suiteName: "cl-audit-surfaces-out-\(getpid())")!)
    outReader.tick()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    check(outReader.state == .noLogin, "the reader sees no sign-in")
    // (the reader adopts no numbers it may not show, so its own save has no read time either, as with expired)
    noneSignedOut("after the reader's save", keepsWhen: false)
    // a good read (Anthropic's answer handed to the reader): state ok, its numbers on every screen
    let reply = Data(#"{"five_hour":{"utilization":7,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":64,"resets_at":"2099-01-02T00:00:00Z"}}"#.utf8)
    outReader.finish(data: reply, response: HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil),
                     error: nil, asked: Date(), gen: outReader.generation)
    let back = Store.status(for: p)
    check(outReader.state == .ok && back?.state == "ok" && back?.weekly == 64 && back?.fiveHour == 7,
          "a good read: the numbers come back")
    check(Usage.of(back)?.weekly == 64 && cardRow(p).weekly == 64 && !cardRow(p).needsLogin
          && QuickChatTarget(p).loginWords == nil, "…on the menu bar, the card and quick chat alike, without Sign in…")
    check(preview(p, status: back, sample: false).tiffRepresentation != preview(p, status: Store.status(for: p).map { var s = $0; s.dropNumbers(); return s }, sample: false).tiffRepresentation,
          "…and in the Dock icon's preview: the record's own numbers (7 % and 64 %), not a blank tile")
    let goodPanel = samplePanel(p, status: back), samplePanelNow = samplePanel(p, status: nil, sample: true)
    check(goodPanel.fiveHour == 7 && goodPanel.weekly == 64 && samplePanelNow.fiveHour == 23 && samplePanelNow.weekly == 58
          && samplePanelNow.fiveHourResets != nil && samplePanelNow.weeklyResets != nil,
          "…and in Settings' panel preview: the record's own numbers; a profile that doesn't exist yet (no record, sample on) the samples, 23 % and 58 %")
    check(samplePanel(p, status: back, sample: true).fiveHour == 7, "…a record is never replaced by the samples, even with sample on")
    outReader.stop()
    UsageReader.testPoster = nil
    // an existing profile whose record is gone (missing or unreadable): no numbers in Settings' list tile, its panel preview and
    // the Dock's tile (DockManager.tileImage, which reads the saved profiles); a new profile's tile shows the samples
    try? Store.save([p])
    Store.removeStatus("stale")
    check(Store.status(for: p) == nil && previewShowsNone(p, nil) && panelShowsNone(p, nil),
          "an existing profile without a record: no numbers in the list tile, the panel preview or the preview's default")
    check(DockManager.tileImage(Installer.appURL(p)).tiffRepresentation == blankTile(p),
          "…and the Dock's tile (DockManager.tileImage) of a profile without a record is blank: no sample numbers")
    check(preview(p, status: nil, sample: true).tiffRepresentation != blankTile(p), "a new profile's tile (no record, sample on) shows the samples")
    try? Store.save([])
    Store.removeStatus("stale")
}

// ============ 6. no screen reads the sign-in files or a seat itself ============
do {
    let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    let widgetSrc = src.deletingLastPathComponent().appendingPathComponent("Widget")
    // (the Dock's own file too: its tiles are drawn from the record, like the icon app's)
    let surfaceFiles = ["MenuBar.swift", "IconApp.swift", "Details.swift", "SwitchMenu.swift", "SwitchView.swift", "SwitchPage.swift",
                        "QuickChat.swift", "QuickChatViews.swift", "QuickChatCard.swift", "QuickChatLevel.swift", "Dock.swift"]
    // the sign-in files, and the folder's address read from .claude.json (`Account.expectedEmail(configDir:)` and the `expectedEmail()`
    // that calls it): a screen takes the expected address from the status record (`status.expectedEmail`)
    let fileReads = [".claude.json", "config.json", "main.log", "Logs/Claude", "claudeJSON(", "signedInSeat(", "lastKnownAccountUuid",
                     "expectedEmail(", "FolderFactsCache", "inUseElsewhere", "AppSignIn.", "ClaudeFiles."]
    let forbidden = fileReads + ["entry.seat", "e.seat?.", "profile.entry.seat"]
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
    // the parts of bigger files that draw a profile: the card and the palette's row (Launcher.swift), Settings' IN USE box and
    // its Dock icon preview (Settings.swift)
    for (f, a, b) in [("Launcher.swift", "struct AccountCard", "\n}\n"), ("Launcher.swift", "struct AccountRow: Identifiable", "\n}\n"),
                      ("Settings.swift", "func inUseBox(", "    /// Sign in… on the account in use"),
                      ("Settings.swift", "func preview(_ e: AccountEntry", "/// Settings is a page of the one cl_audit window")] {
        for l in section(f, from: a, to: b) where !l.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            for p in forbidden where l.contains(p) { reads.append("\(f) \(p): \(l.trimmingCharacters(in: .whitespaces).prefix(60))") }
            if l.contains("section not found") { reads.append(l) }
        }
    }
    // the widget: built on its own, and it may read the profiles file for its profiles and their seats (its decoder, until it
    // takes the record's answer), but never the sign-in files or the folder's address itself
    for f in ["WidgetViews.swift"] {
        let lines = (try? String(contentsOf: widgetSrc.appendingPathComponent(f), encoding: .utf8))?.components(separatedBy: "\n") ?? ["(missing Widget/\(f))"]
        for (i, l) in lines.enumerated() where !l.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            for p in fileReads where l.contains(p) { reads.append("Widget/\(f):\(i + 1) \(p)") }
            if l.hasPrefix("(missing") { reads.append(l) }
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
        ("Config.swift", "static func openLogin(", ".startSignIn(", "login"),
        ("Launcher.swift", "static func openClaude(", "openApplication(", "the Claude window"),
        ("Launcher.swift", "private static func openTerminal(", "Installer.run(", "Terminal"),
        ("QuickChatEngine.swift", "func start(environment", "r.start(", "quick chat")]          // (its claude: Runs' RunningProgram)
    for (f, a, launch, what) in launchers {
        let b = body(f, from: a, until: launch)
        check(!b.isEmpty && b.contains("FolderGuard.mayLaunch("), "\(what): FolderGuard is asked before it launches")
    }
    // logout and renew run through ClaudeAuth with cl_audit's tools, whose guard is FolderGuard (ClaudeAuth asks it
    // before every run, the auth suite holds that)
    check(body("Config.swift", from: "static var authTools", until: "return t").contains("FolderGuard.mayLaunch("),
          "ClaudeAuth's tools in cl_audit: FolderGuard is the launch guard")
    for (a, launch, what) in [("static func logout(", ".signOut(", "logout"), ("static func renew(", ".renew(claude:", "renew")] {
        let b = body("Config.swift", from: a, until: launch)
        check(!b.isEmpty && b.contains("tools: authTools"), "\(what): runs through ClaudeAuth with FolderGuard as its guard")
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

    // the words are "sign in / sign-in / signed in / sign out" everywhere (the operator's ruling): no string literal in Sources,
    // Widget or Core says "log in", "login", "logging in", "log out" or "logout" (nor "logged in" / "logged out" as a sign-in),
    // except what isn't ours to word: macOS's own "At login" and "Login Items", `claude auth login`, /login and /logout, the
    // Claude app's log lines we parse, our own log lines, the launch names ("login", "logout") and test sample text
    let wordsRe = try! NSRegularExpression(pattern: #"(?i)\blog(?:ged|ging)?[ -](?:in|out)\b|\blogin\b|\blogout\b"#)
    let wordsExempt = ["at login", "login items", "login item", "login shell", "login session", "auth login", "/login", "/logout",
                       "login-state transition", "account logged out", "loggedout", "usage-n-uf-login", "-login-page-",
                       "login-item"]          // a command-line flag (--forget-login-item), macOS's Login Items, never shown
    func loginWording(inLiteral s: String) -> Bool {
        let t = s.lowercased()
        if t == "login" || t == "logout" { return false }          // launch names (FolderGuard's seam), never shown
        if wordsExempt.contains(where: { t.contains($0) }) { return false }
        return wordsRe.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    // the rule itself: old words are caught, the new ones and the exemptions are not
    check(["Log in…", "Logged in.", "login expired", "Log out", "when you log in", "Logging in: finish it"].allSatisfy(loginWording(inLiteral:))
          && ["Sign in…", "Signed in.", "sign-in expired", "Sign out", "At login: always there", "Login Items & Extensions", "claude auth login",
              "Not logged in · Please run /login", "login", "noLogin", "loginEmail", "[account] Login-state transition", "Account logged out"]
              .allSatisfy { !loginWording(inLiteral: $0) },
          "the log-in wording rule catches the old words and lets the new words and the exemptions through")
    var oldWords: [String] = [], scanned = 0
    let literalRe = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
    for dir in [src, widgetSrc, src.deletingLastPathComponent().appendingPathComponent("Core")] {
        for f in ((try? fm.subpathsOfDirectory(atPath: dir.path)) ?? []).sorted() where f.hasSuffix(".swift") {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) else { oldWords.append("(unreadable \(f))"); continue }
            for (i, l) in text.components(separatedBy: "\n").enumerated() where !l.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let ns = l as NSString
                for m in literalRe.matches(in: l, range: NSRange(location: 0, length: ns.length)) {
                    scanned += 1
                    let lit = ns.substring(with: m.range(at: 1))
                    if loginWording(inLiteral: lit) { oldWords.append("\(dir.lastPathComponent)/\(f):\(i + 1) \(lit.prefix(60))") }
                }
            }
        }
    }
    check(scanned > 1000 && oldWords.isEmpty, "no visible log in / login / logged in / log out is left in Sources, Widget or Core (\(scanned) literals read): \(oldWords)")
}

// ============ 6b. a switch that stops: the step that failed, the ones before done, the tile's words ============
do {
    func states(_ phase: SwitchRunner.Phase, _ at: SwitchRunner.FailedStep?, moves: Bool) -> [SwitchPage.StepState] {
        (1...(moves ? 5 : 3)).map { SwitchPage.stepState($0, phase: phase, failedAt: at, moves: moves) }
    }
    var rc = SwitchReceipt(id: "r-fail", profile: "pf", standby: "s", dataDir: "/tmp/x", from: SeatID(u1), to: SeatID(u2), started: t0)
    rc.steps = (0..<3).map { SwitchReceipt.Step(kind: .entry, path: "/x\($0)", sha: nil, parked: nil, original: nil, done: true) }
    let f = SwitchRunner.Phase.failed("why")
    check(states(f, .closing, moves: true) == [.failed, .pending, .pending, .pending, .pending] && SwitchRunner.failedWords(nil) == ("Not started", "nothing changed"),
          "the window didn't close: step 1 failed, nothing else; the tile: Not started · nothing changed")
    check(states(f, .backup, moves: true) == [.done, .failed, .pending, .pending, .pending], "the backup failed: step 1 done, step 2 failed")
    check(states(f, .move, moves: true) == [.done, .failed, .pending, .pending, .pending], "the move stopped part way: step 2 failed")
    check(SwitchRunner.failedWords(rc) == ("Stopped part way", "changed · Undo puts them back"),
          "a receipt with something to undo but nothing countable left: 'changed', never 'nothing changed'")
    check(states(f, .signIn, moves: true) == [.done, .done, .failed, .pending, .pending], "the sign-in didn't open after the move: step 3 failed, 1 and 2 done")
    check(states(f, .signIn, moves: false) == [.failed, .pending, .pending] && SwitchRunner.failedWords(nil).l2 == "nothing changed",
          "the sign-in didn't open, nothing to move: its first step failed; nothing changed")
    check(states(.other("x@example.com"), nil, moves: true) == [.done, .done, .done, .done, .failed], "the account check: another account: the last step failed")
    check(states(f, .notStarted, moves: true).allSatisfy { $0 == .pending }, "refused before anything: no step marked failed")
    var undone = rc; undone.undone = t0
    check(SwitchRunner.failedWords(undone) == ("Not started", "nothing changed"), "a receipt already undone: nothing left changed")

    // through the runner's own fail sites, with real files
    let wdF = expand("~/Library/Application Support/Claude-fail")
    try? fm.removeItem(atPath: wdF)
    let srcF = SwitchEngine.scopeDir(wdF, SeatID(u1)), dstF = SwitchEngine.scopeDir(wdF, SeatID(u2))
    var ef = profile("ff", "~/.claude-ff", u1); ef.claudeWindow = true; ef.desktop = .separate; ef.desktopDataDir = wdF
    ef.standby = [StandbyAccount(email: u2.email!, seat: u2, id: "f2")]
    try? fm.createDirectory(atPath: expand("~/.claude-ff"), withIntermediateDirectories: true)
    try! Store.save([ef])
    // no claude on this Mac (so a sign-in can't start); never the real one
    let keepLocator = ClaudeLocator.current
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
    defer { ClaudeLocator.current = keepLocator }
    let mf = SettingsModel(); mf.accounts = [ef]
    let rf = mf.runner(of: "ff")
    func settle(_ done: () -> Bool) { let end = Date().addingTimeInterval(20); while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) } }
    func failedPhase() -> Bool { if case .failed = rf.phase { return true }; return false }

    // a tasks-only stop inside the tasks' step: the new account's file can't be written. Since TaskRegistry the old account's
    // file is put back as it was (the tasks are never in neither account), so nothing changed and the receipt has nothing to
    // undo (it blocks no other flow)
    let srcTasks = #"{"scheduledTasks":[{"id":"t1"},{"id":"t2"},{"id":"t3"}]}"#
    put("\(srcF)/scheduled-tasks.json", srcTasks)
    try? fm.createDirectory(atPath: dstF, withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dstF)
    rf.start(ef.standby[0])
    settle(failedPhase)
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dstF)
    check(failedPhase() && rf.failedStep == .move && rf.receipt == nil && SwitchEngine.unfinished(profile: "ff").isEmpty
          && SwitchRunner.failedWords(rf.receipt) == ("Not started", "nothing changed")
          && fm.contents(atPath: "\(srcF)/scheduled-tasks.json") == Data(srcTasks.utf8) && !fm.fileExists(atPath: "\(dstF)/scheduled-tasks.json"),
          "a stop inside the tasks' step: the move step failed, the old account's tasks put back as they were, nothing changed: \(rf.phase) \(SwitchRunner.failedWords(rf.receipt))")
    if let r = rf.receipt { _ = try? SwitchEngine.undo(r.id, windowClosed: { true }) }
    rf.reset()

    // two sessions moved, then Claude Code's sign-in couldn't start (no claude here): the sign-in step failed, the tile
    // and What changed give the receipt's own count
    try? fm.removeItem(atPath: wdF)
    put("\(srcF)/local_\(uuid(951)).json", #"{"sessionId":"local_a"}"#)
    put("\(srcF)/local_\(uuid(952)).json", #"{"sessionId":"local_b"}"#)
    rf.start(ef.standby[0])
    settle(failedPhase)
    check(rf.failedStep == .signIn && SwitchRunner.failedWords(rf.receipt) == ("Stopped part way", "2 sessions moved · Undo puts them back")
          && SwitchRunner.movedWords(rf.receipt!) == "2 sessions",
          "moved, then the sign-in didn't start: the sign-in step failed; 2 sessions moved: \(SwitchRunner.failedWords(rf.receipt))")
    // the retry can't hold the window (another run has it): the sign-in it was retrying is the step marked
    let winF = Launcher.dataDirKey(of: Account(ef))
    check(SwitchMarker.claim(winF, profile: "other", standby: "x"), "another run holds the window")
    rf.retry()
    check(rf.failedStep == .signIn && SwitchPage.stepState(3, phase: rf.phase, failedAt: rf.failedStep, moves: true) == .failed,
          "a retry that can't hold the window marks the sign-in, not step 1")
    SwitchMarker.release(winF, profile: "other", standby: "x")
    // a partial Undo: one placed session changed since stays; the tile counts only what's still moved
    put("\(dstF)/local_\(uuid(951)).json", #"{"sessionId":"local_a","edited":true}"#)
    rf.undo()
    settle { failedPhase() && rf.receipt?.partlyUndone != nil }
    check(rf.receipt?.partlyUndone != nil && SwitchRunner.failedWords(rf.receipt) == ("Stopped part way", "1 session moved · Undo puts them back"),
          "after a partial Undo the tile counts only what's still moved: \(SwitchRunner.failedWords(rf.receipt))")
    rf.reset()
    try? fm.removeItem(atPath: wdF)
}

// ============ 7. a copy of the profiles file before it's rewritten in a new shape ============
do {
    Store.announce = {}                         // a throwaway home: no running cl_audit is told
    let fmode: (String) -> Int? = { ((try? fm.attributesOfItem(atPath: $0))?[.posixPermissions] as? NSNumber)?.intValue }
    func copies() -> [String] { ((try? fm.contentsOfDirectory(atPath: Store.folder.path)) ?? []).filter { $0.hasPrefix("accounts.json.pre-") }.sorted() }
    copies().forEach { try? fm.removeItem(at: Store.folder.appendingPathComponent($0)) }
    // the one-time migration: an older file (a kept folder) rewritten at the next change
    let legacy = Data(#"{"accounts":[{"id":"mg","name":"Mg","label":"MG","configDir":"~/.claude-mg","keptFolder":"~/.claude-mg-kept"}]}"#.utf8)
    try! legacy.write(to: Store.configURL)
    Store.version = "m1"
    Store.update("mg") { $0.name = "Mg2" }
    let mPre = Store.folder.appendingPathComponent("accounts.json.pre-m1").path
    check(copies() == ["accounts.json.pre-m1"] && fm.contents(atPath: mPre) == legacy && fmode(mPre) == 0o600,
          "the migration keeps the old file once, as it was, owner only: \(copies())")
    Store.update("mg") { $0.name = "Mg3" }
    _ = Store.loadChecked()
    check(copies() == ["accounts.json.pre-m1"] && fm.contents(atPath: mPre) == legacy, "a second save and a load make no new copy, the copy unchanged")
    // the standby tidy-up: a list with two entries of one account
    let dup = Data(#"{"accounts":[{"id":"td","name":"Td","label":"TD","configDir":"~/.claude-td","standby":[{"id":"a1","email":"x@example.com","seat":{"account":"\#(uuid(901))","organization":"\#(uuid(902))"}},{"id":"a2","email":"x@example.com","seat":{"account":"\#(uuid(901))","organization":"\#(uuid(903))"}}]}]}"#.utf8)
    try! dup.write(to: Store.configURL)
    Store.version = "t1"
    let tidied = Store.loadChecked()
    let tPre = Store.folder.appendingPathComponent("accounts.json.pre-t1").path
    check(tidied?.first?.standby.count == 1 && copies() == ["accounts.json.pre-m1", "accounts.json.pre-t1"] && fm.contents(atPath: tPre) == dup && fmode(tPre) == 0o600,
          "the tidy keeps the old file once, as it was, owner only: \(copies())")
    _ = Store.loadChecked()
    check(copies().count == 2, "a second load makes no new copy")
    // an ordinary save in another version: no copy
    Store.version = "o1"
    Store.update("td") { $0.name = "Td2" }
    check(copies().count == 2, "an ordinary save makes no copy")
    // a link where the copy would go: never written through, the edit goes ahead, the copy is kept under the next name
    func pre(_ n: String) -> String { Store.folder.appendingPathComponent(n).path }
    try? fm.createSymbolicLink(atPath: pre("accounts.json.pre-l1"), withDestinationPath: home + "/elsewhere-pre")
    try! legacy.write(to: Store.configURL)
    Store.version = "l1"
    Store.update("mg") { $0.name = "Mg4" }
    check(!fm.fileExists(atPath: home + "/elsewhere-pre") && Store.loadRaw()?.first?.name == "Mg4"
          && fm.contents(atPath: pre("accounts.json.pre-l1-2")) == legacy && fmode(pre("accounts.json.pre-l1-2")) == 0o600
          && Store.loadRaw()?.first?.accountNote == nil,
          "a link at the copy's name: nothing written through it, the edit goes ahead, the copy kept as …-2, no line")
    // a cut-off copy from before (interrupted): never counted as done; the copy is made again under the next name
    try! legacy.write(to: Store.configURL)
    Store.version = "c1"
    fm.createFile(atPath: pre("accounts.json.pre-c1"), contents: legacy.prefix(10), attributes: [.posixPermissions: 0o600])
    Store.update("mg") { $0.name = "Mg5" }
    check(fm.contents(atPath: pre("accounts.json.pre-c1")) == legacy.prefix(10) && fm.contents(atPath: pre("accounts.json.pre-c1-2")) == legacy,
          "a cut-off copy is left as it is and the copy made again as …-2")
    // a complete copy from before: nothing new
    try! legacy.write(to: Store.configURL)
    let beforeC = copies()
    Store.update("mg") { $0.name = "Mg6" }
    check(copies() == beforeC, "a complete copy for this version: nothing new is made")
    // neither name usable: the edit still goes ahead, and the Accounts card says the copy couldn't be kept
    try! legacy.write(to: Store.configURL)
    Store.version = "f1"
    // every name it may use is taken by a link (none is ever written through)
    let fNames = ["accounts.json.pre-f1"] + (2...20).map { "accounts.json.pre-f1-\($0)" }
    for n in fNames { try? fm.createSymbolicLink(atPath: pre(n), withDestinationPath: home + "/elsewhere-pre") }
    Store.update("mg") { $0.name = "Mg7" }
    let noted = Store.loadRaw()?.first
    check(noted?.name == "Mg7", "the edit went ahead all the same")
    check(!fm.fileExists(atPath: home + "/elsewhere-pre"), "never through the link")
    check(noted?.accountNote?.kind == .noCopy && noted?.accountNote?.words.contains("couldn't be kept") == true,
          "no copy could be kept: the line on the Accounts card says so: \(noted?.accountNote?.words ?? "-") (\(noted?.name ?? "-"))")
    for n in fNames { try? fm.removeItem(atPath: pre(n)) }
    Store.version = "dev"
    copies().forEach { try? fm.removeItem(at: Store.folder.appendingPathComponent($0)) }
}

// ============ 6d. Settings ▸ Accounts after a switch (B5): every account once, no note against the boxes, whose numbers ============
// The atlas's fixture (Checks/render/pages/main.swift, ATLAS_SWITCH): Main on ann (the Claude app and Claude Code), ben on
// standby, Work on cat; dan is no profile's. Each state through the app's own steps: the folder noted (FolderRules), the
// record answered (AccountResolver), then what Settings ▸ Accounts lists from it.
do {
    let ann = Seat(account: uuid(11), organization: uuid(51), email: "ann@example.com"), ben = Seat(account: uuid(12), organization: uuid(52), email: "ben@example.com")
    let cat = Seat(account: uuid(13), organization: uuid(53), email: "cat@example.com"), dan = Seat(account: uuid(14), organization: uuid(54), email: "dan@example.com")
    var m0 = profile("atl", "~/.claude-atl-ann", ann)
    m0.standby = [StandbyAccount(email: ben.email!, seat: ben, id: "kb", plan: "Ultra", lastInUse: t0.addingTimeInterval(-3 * 86400))]
    var w0 = profile("atw", "~/.claude-atl-cat", cat); w0.claudeWindow = false
    func app(_ s: Seat) -> AppSignIn.Login { AppSignIn.Login(account: s.account, org: s.organization, state: .known, source: "log", at: t0) }
    /// The folder signed in to `s`: the profiles follow it, then the record answered with the app on `appOn` and the numbers
    /// read for Claude Code's account.
    func after(_ s: Seat, appOn: Seat) -> (e: AccountEntry, v: AccountView) {
        let noted = FolderRules.noteAccounts([m0, w0], signedIn: { $0 == m0.configDir ? s : ($0 == w0.configDir ? cat : nil) }, status: { _ in nil }, now: t0)
        var rec = IconStatus(state: "ok"); rec.loginEmail = s.email; rec.weekly = 12
        rec.resolved = AccountResolver.resolve(noted[0], among: noted, app: app(appOn), code: s, loginEmail: s.email, names: [:], now: t0)
        return (noted[0], AccountView.of(rec))
    }
    func standby(_ e: AccountEntry, _ v: AccountView) -> [String] { e.standbyRows(by: v).map(\.email) }
    let was = { (e: AccountEntry) in e.seat?.was ?? "-" }

    // 05: Claude Code on ben, the app still on ann
    let r5 = after(ben, appOn: ann)
    check(r5.v.label == ann.email && r5.v.codeRow == ben.email && standby(r5.e, r5.v).isEmpty,
          "05: ann in the IN USE box, ben in a row of its own (Claude Code's, with the numbers), no standby row: \(r5.v.label ?? "-") / \(r5.v.codeRow ?? "-") / \(standby(r5.e, r5.v))")
    check(was(r5.e) == ann.email && !r5.v.mayCallStandby(was(r5.e)), "05: no \"was ann, now on standby\" while ann is the active account")
    check(r5.v.numbersOwner == ben.email && r5.v.line?.hasPrefix("Usage: Claude Code on ") == true, "05: the numbers are ben's, said under ben's row")
    // 06: the app signed in to ben too
    let r6 = after(ben, appOn: ben)
    check(r6.v.label == ben.email && r6.v.codeRow == nil && standby(r6.e, r6.v) == [ann.email!],
          "06: ben in use with the numbers, ann on standby, nothing twice: \(standby(r6.e, r6.v))")
    check(r6.v.mayCallStandby(was(r6.e)), "06: the note may say ann is on standby (she is)")
    // 07: the sign-in landed on dan, the app still on ann
    let r7 = after(dan, appOn: ann)
    check(r7.v.label == ann.email && r7.v.codeRow == dan.email && standby(r7.e, r7.v) == [ben.email!],
          "07: ann in use, dan's own row with the numbers, ben on standby: \(r7.v.codeRow ?? "-") / \(standby(r7.e, r7.v))")
    check(!r7.v.mayCallStandby(ann.email!) && !r7.v.mayCallStandby(dan.email!) && r7.v.mayCallStandby(ben.email!),
          "07: a note calls only ben on standby")
    // the line of Claude Code's row: on the account the switch went for, only the app's sign-in is left; on another, the
    // switch didn't finish
    check(AccountView.codeRowWords(code: r5.v.codeRow!, target: ben.email) == "Claude Code is on it; sign the Claude app in to finish.",
          "05: ben's row: sign the Claude app in to finish")
    let w7 = AccountView.codeRowWords(code: r7.v.codeRow!, target: ben.email)
    check(w7 == "Claude Code signed in as dan, not ben: the switch didn't finish. Sign Claude Code in as ben from the Switch page, or Undo it."
          && !w7.contains("sign the Claude app in"), "07: dan's row says the switch didn't finish, never \"sign the Claude app in to finish\": \(w7)")
    // the account in use on the app and Claude Code alike: no own row for Claude Code, the numbers in the IN USE box
    let r1 = after(ann, appOn: ann)
    check(r1.v.codeRow == nil && standby(r1.e, r1.v) == [ben.email!], "01: one IN USE box with the numbers, ben on standby")

    // 04a–04c: one line in the Switch page's strip words while it runs; the Sessions card never says "stopped" then
    let started = t0
    for (p, words) in [(SwitchRunner.Phase.closing, "Switching · closing the window"), (.moving, "Switching · moving sessions")] {
        let s = SwitchPage.settingsStrip(p, again: false, canUndo: false, failedAt: nil, started: started)
        check(s.map { "\($0.text) \($0.dim ?? "")" } == words, "\(p): Settings says \(words)")
    }
    let w = SwitchPage.settingsStrip(.waiting, again: false, canUndo: true, failedAt: nil, started: started)
    check(w?.text == "Switching" && w?.dim?.hasPrefix("· waiting · until ") == true
          && w.map { "\($0.text) \($0.dim ?? "")" } == SwitchPage.strip(.waiting, again: false, canUndo: true, started: started).map { "\($0.text) \($0.dim ?? "")" },
          "04c: Settings says the strip's own words: \(w?.text ?? "-") \(w?.dim ?? "-")")
    check(SwitchPage.settingsStrip(.reached, again: false, canUndo: false, failedAt: nil, started: started) == nil
          && SwitchPage.settingsStrip(.waiting, again: true, canUndo: false, failedAt: nil, started: started) == nil
          && SwitchPage.settingsStrip(.failed("x"), again: false, canUndo: true, failedAt: .move, started: started) == nil,
          "no line once it ended, for a sign-in again, or for a stop the Sessions card offers Undo for")
    let open = SwitchReceipt(id: "r", profile: "atl", standby: "kb", dataDir: "/x", from: SeatID(ann), to: SeatID(ben), started: t0)
    check(SessionsCard.showsStopped(open, running: true, again: false) == nil && SessionsCard.showsStopped(open, running: false, again: false)?.id == "r",
          "04c: a switch still running is never \"A switch stopped\" (no Undo it / Leave it as it is); once it stopped, it is")
    check(SessionsCard.showsStopped(open, running: true, again: true)?.id == "r",
          "a sign-in again running (it moves nothing): the stopped switch and its Undo stay")

    // the IN USE box's title: always the active account while Claude Code is on another, even expired or another address
    func title(_ v: AccountView, _ state: String, mismatch: Bool = false) -> String {
        AccountSettings.inUseTitle(v, state: state, loginEmail: ben.email, expected: ann.email, mismatch: mismatch, moveEmail: nil).text
    }
    check(title(r5.v, "expired") == ann.email && title(r5.v, "ok", mismatch: true) == ann.email && title(r5.v, "ok") == ann.email,
          "05: the IN USE title is ann (the app's) whether Claude Code's sign-in is fine, expired or another address")
    let t1 = AccountSettings.inUseTitle(r1.v, state: "expired", loginEmail: ann.email, expected: ann.email, mismatch: false, moveEmail: nil)
    check(t1.text == ann.email && t1.tone == .caution, "one account, expired: its address in caution, as before")
    // the plan under the IN USE box: the active account's, never Claude Code's
    var m5 = r5.e; m5.standby = m5.standby.map { var s = $0; if s.email == ann.email { s.plan = "Max" }; return s }
    check(m5.activePlan(r5.v, recordPlan: "Ultra") == "Max" && r1.e.activePlan(r1.v, recordPlan: "Ultra") == "Ultra",
          "05: the plan under ann is ann's (Max), Claude Code's (Ultra) under its own row")

    // the target of Claude Code's row: this profile's current switch only
    let kb = m0.standby[0]
    var older = SwitchReceipt(id: "o", profile: "atl", standby: "kc", dataDir: "/x", from: SeatID(ann), to: SeatID(cat), started: t0.addingTimeInterval(-86400))
    older.steps = [SwitchReceipt.Step(kind: .entry, path: "/x/a", sha: nil, parked: nil, original: nil, done: true)]
    var newer = SwitchReceipt(id: "n", profile: "atl", standby: "kb", dataDir: "/x", from: SeatID(ann), to: SeatID(ben), started: t0)
    newer.steps = older.steps
    let withCat = [kb, StandbyAccount(email: cat.email!, seat: cat, id: "kc")]
    var linkedNew = newer; linkedNew.linked = t0
    let newestOf = { (rs: [SwitchReceipt]) in rs.sorted { $0.started > $1.started }.first }
    /// The row's words after a restart (no runner goal), Claude Code on `code`.
    func words(_ newest: SwitchReceipt?, _ standby: [StandbyAccount], code: Seat, goal: SwitchRunner.Goal? = nil) -> String {
        AccountView.codeRowWords(code: code.email!, target: AccountSettings.switchTarget(goal: goal, newest: newest, standby: standby,
                                                                                       code: code.email, codeAccount: code.account.lowercased()))
    }
    let finish = "Claude Code is on it; sign the Claude app in to finish.", onIt = "Claude Code is on it."
    let notBen = "Claude Code signed in as dan, not ben: the switch didn't finish. Sign Claude Code in as ben from the Switch page, or Undo it."
    // 05 after a restart: the switch reached ben (its receipt linked), the app still on ann: the finish line
    let annOnly = [StandbyAccount(email: ann.email!, seat: ann, id: "ka")]
    check(words(linkedNew, annOnly, code: ben) == finish, "05 after a restart, the receipt linked: ben's row keeps the finish line: \(words(linkedNew, annOnly, code: ben))")
    check(words(newestOf([older, linkedNew]), withCat, code: dan) == onIt,
          "the newest switch linked to ben, an older one still open, Claude Code on dan by hand: never the older one's cat, no finish: \(words(newestOf([older, linkedNew]), withCat, code: dan))")
    // 07 after a restart: the switch to ben still open, Claude Code on dan
    check(words(newestOf([older, newer]), withCat, code: dan) == notBen, "07 after a restart: the newest switch still open to ben: didn't finish")
    let addressOnly = [StandbyAccount(email: ben.email!, id: "kb")]
    check(words(newer, addressOnly, code: dan) == notBen, "a standby account remembered by its address only: found by the switch's standby entry")
    var undoneNew = newer; undoneNew.undone = t0
    check(words(undoneNew, withCat, code: dan) == onIt, "a switch undone names nothing")
    let goalBen = SwitchRunner.Goal(standby: "kb", wantedSeat: ben, wantedEmail: ben.email!, from: ann, started: t0)
    let goalAgain = SwitchRunner.Goal(standby: nil, wantedSeat: ann, wantedEmail: ann.email!, from: ann, started: t0)
    check(words(older, withCat, code: dan, goal: goalBen) == notBen && words(older, withCat, code: ben, goal: goalBen) == finish
          && words(newer, withCat, code: dan, goal: goalAgain) == onIt,
          "the runner's switch decides while it has one; a sign-in again has no target")
    // a sign-in by hand as dan, no switch: Claude Code's row says only that it is on it
    check(words(nil, withCat, code: dan) == onIt, "no switch at all (a sign-in by hand): \"Claude Code is on it.\", no \"finish\"")

    // the Claude app signed out: Claude Code's account is the active one; no own row, nothing twice
    let noted7 = FolderRules.noteAccounts([m0, w0], signedIn: { $0 == m0.configDir ? dan : nil }, status: { _ in nil }, now: t0)
    var recOut = IconStatus(state: "ok"); recOut.loginEmail = dan.email
    recOut.resolved = AccountResolver.resolve(noted7[0], among: noted7, app: appOut, code: dan, loginEmail: dan.email, names: [:], now: t0)
    let vOut = AccountView.of(recOut)
    check(vOut.label == dan.email && vOut.codeRow == nil && Set(standby(noted7[0], vOut)) == [ann.email!, ben.email!],
          "the app signed out: dan in use with the numbers, ann and ben on standby: \(standby(noted7[0], vOut))")

    // Claude Code's account known by its id only ("account <8>", no address): its row, and never on standby too
    let noMail = Seat(account: uuid(15), organization: uuid(55), email: nil)
    var m8 = m0; m8.seat = noMail; m8.standby = [kb, StandbyAccount(email: "", seat: noMail, id: "kx"), StandbyAccount(email: ann.email!, seat: ann, id: "ka")]
    var rec8 = IconStatus(state: "ok")
    rec8.resolved = AccountResolver.resolve(m8, among: [m8, w0], app: app(ann), code: noMail, loginEmail: nil, names: [:], now: t0)
    let v8 = AccountView.of(rec8)
    check(v8.codeRow?.hasPrefix("account ") == true && standby(m8, v8) == [ben.email!] && !v8.mayCallStandby("", id: noMail.account),
          "Claude Code on an account known by its id only: its own row (\(v8.codeRow ?? "-")), not on standby too: \(standby(m8, v8))")

    // 11: the folder gone: the runner's own start refuses; Settings says it in the strip's words
    let keepLocator = ClaudeLocator.current
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
    defer { ClaudeLocator.current = keepLocator }
    try? fm.removeItem(atPath: expand(m0.configDir))
    try! Store.save([m0, w0])
    let ma = SettingsModel(); ma.accounts = [m0, w0]
    let ra = ma.runner(of: "atl")
    if ClaudeCLI.goneLine(m0.configDir) != nil { ra.start(m0.standby[0]) }
    let s11 = SwitchPage.settingsStrip(ra.phase, again: ra.goal?.again == true, canUndo: ra.canUndo, failedAt: ra.failedStep, started: ra.goal?.started)
    check(ra.failedStep == .notStarted && s11.map { "\($0.text) \($0.dim ?? "")" } == "Not started · nothing changed",
          "11: the folder gone: refused before anything, Settings says \"Not started · nothing changed\": \(ra.phase)")
    let r11 = after(ann, appOn: ann)
    check(r11.v.label == ann.email && standby(r11.e, r11.v) == [ben.email!], "11: the rows stay as they are")
    ra.reset()
}

// ============ 6e. consent before a risky run (B6): Cancel runs and writes nothing; Continue, ticked, logs one line and starts ============
do {
    let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    let log = ConsentLog.url
    try? fm.removeItem(at: log)
    func lines() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    // each flow's final button only makes a request (the page's sheet runs it from Continue), and the page shows the sheet
    let finals: [(String, String, [String])] = [
        ("Account switching", "SwitchPage.swift", ["runner.start(standby)", "runner.retry()"]),
        ("Import", "ImportPage.swift", ["runner.commit()", "runner.applyMove()"]),
        ("Restoring a backup / Import", "RestorePage.swift", ["runner.start()"]),
        ("Export and Move to another Mac", "ExportPage.swift", ["runner.start()"]),
        ("Making the default profile", "DefaultProfilePage.swift", ["runner.start()"])]
    for (flow, f, calls) in finals {
        let t = (try? String(contentsOf: src.appendingPathComponent(f), encoding: .utf8)) ?? ""
        // (a sign-in again's retry moves nothing: it stays outside the sheet, on the same line as the switch's request)
        let bare = t.components(separatedBy: "\n").filter { l in
            !l.trimmingCharacters(in: .whitespaces).hasPrefix("//") && calls.contains { l.contains($0) } && !l.contains("ConsentRequest(")
        }
        let uses = t.components(separatedBy: "\n").filter { l in calls.contains { l.contains($0) } }.count
        check(uses > 0 && bare.isEmpty && t.contains(".experimentalConsent($consent)"),
              "\(flow): every final button goes through the consent sheet (\(uses) found): \(bare.map { $0.trimmingCharacters(in: .whitespaces).prefix(70) })")
    }

    // per flow: Cancel (the request dropped) runs nothing and logs nothing; Continue unticked neither; ticked, one line, then the run
    for (flow, plural) in [("Account switching", false), ("Import", false), ("Restoring a backup", false), ("Export and Move to another Mac", true), ("Making the default profile", false)] {
        var ran = 0
        var r: ConsentRequest? = ConsentRequest(flow: flow, plural: plural) { ran += 1 }
        r = nil                                                    // Cancel: the sheet drops it
        check(r == nil && ran == 0 && lines().isEmpty, "\(flow): Cancel starts nothing and writes nothing")
        let q = ConsentRequest(flow: flow, plural: plural) { ran += 1 }
        check(!q.proceed(understood: false) && ran == 0 && lines().isEmpty, "\(flow): Continue without the box ticked starts nothing")
        check(q.proceed(understood: true) && ran == 1 && lines().last?.contains("\t\(flow)\t\(Store.version)\taccepted") == true,
              "\(flow): Continue, ticked: one line, then its start: \(lines().last ?? "-")")
        try? fm.removeItem(at: log)
    }
    // the words: "is"/"are" kept right, the licence named, the box off by default
    check(ExperimentalConsent.paragraphs("Export and Move to another Mac", plural: true)[0].hasPrefix("Export and Move to another Mac are experimental. They are still unstable")
          && ExperimentalConsent.paragraphs("Import")[0].hasPrefix("Import is experimental. It is still unstable")
          && ExperimentalConsent.paragraphs("Import")[2].contains("PolyForm Perimeter License 1.0.1, No Liability"),
          "the sheet's words, singular and plural")

    // the switch, for real: Cancel leaves no receipt and the runner where it was; Continue reaches the runner's own start
    let goneDir = "~/.claude-consent-gone"
    try? fm.removeItem(atPath: expand(goneDir))
    var cp = profile("cns", goneDir, Seat(account: uuid(21), organization: uuid(61), email: "eve@example.com"))
    cp.standby = [StandbyAccount(email: "fay@example.com", seat: Seat(account: uuid(22), organization: uuid(62), email: "fay@example.com"), id: "kf")]
    try! Store.save([cp])
    let keepLocator = ClaudeLocator.current
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
    defer { ClaudeLocator.current = keepLocator }
    let mc = SettingsModel(); mc.accounts = [cp]
    let rc = mc.runner(of: "cns")
    var pending: ConsentRequest? = ConsentRequest(flow: "Account switching") { rc.start(cp.standby[0]) }
    pending = nil
    check(rc.phase == .ready && rc.goal == nil && SwitchEngine.receipts(profile: "cns").isEmpty && lines().isEmpty,
          "the switch, Cancel: nothing started, no receipt, no line")
    pending = ConsentRequest(flow: "Account switching") { rc.start(cp.standby[0]) }
    pending?.proceed(understood: true)
    check(rc.failedStep == .notStarted && rc.goal?.standby == "kf" && lines().count == 1,
          "the switch, Continue: the runner's own start ran (refused here: the folder is gone): \(rc.phase)")
    // consent.log: owner-only, one plain line, no address, id or path; never written through a link
    var st = stat()
    check(stat(log.path, &st) == 0 && st.st_mode & 0o777 == 0o600 && !(lines().first ?? "@").contains("@") && !(lines().first ?? "/").contains("/"),
          "consent.log is 0600 and its line has no address or path: \(lines().first ?? "-")")
    try? fm.removeItem(at: log)
    let elsewhere = home + "/consent-elsewhere"
    fm.createFile(atPath: elsewhere, contents: Data("kept\n".utf8))
    try? fm.createSymbolicLink(atPath: log.path, withDestinationPath: elsewhere)
    ConsentLog.accepted("Import")
    check((try? String(contentsOfFile: elsewhere, encoding: .utf8)) == "kept\n", "consent.log a link: never written through")
    try? fm.removeItem(at: log); try? fm.removeItem(atPath: elsewhere)
    rc.reset()
}

// ============ 6f. the split (B8): the Claude app on P, Claude Code on M: M's numbers are never the profile's ============
do {
    let pat = Seat(account: uuid(31), organization: uuid(71), email: "pat@example.com")
    let mo = Seat(account: uuid(32), organization: uuid(72), email: "mo@example.com")
    let wdS = "~/Library/Application Support/Claude-split"
    var e = profile("spl", "~/.claude-spl", mo)
    e.desktop = .separate; e.desktopDataDir = wdS; e.claudeWindow = true
    e.standby = [StandbyAccount(email: pat.email!, seat: pat, id: "kp", plan: "Max")]
    func signIn(_ dir: String, _ s: Seat, plan: String? = nil) {
        try? fm.removeItem(atPath: expand(dir) + "/.claude.json")
        let planKey = plan.map { #","planDisplayName":"\#($0)""# } ?? ""
        put(expand(dir) + "/.claude.json", #"{"oauthAccount":{"accountUuid":"\#(s.account)","organizationUuid":"\#(s.organization!)","emailAddress":"\#(s.email!)"\#(planKey)}}"#)
    }
    signIn(e.configDir, mo)
    try? fm.removeItem(atPath: expand(wdS) + "/config.json")
    put(expand(wdS) + "/config.json", #"{"lastKnownAccountUuid":"\#(pat.account)"}"#)
    try! Store.save([e])
    let now = Date()
    let appPat = AppSignIn.Login(account: pat.account, org: pat.organization, state: .known, source: "log", at: now)
    func record(app: AppSignIn.Login, code: Seat?, reading: String?, weekly: Double, age: TimeInterval = 0) -> IconStatus {
        var s = IconStatus(state: "ok"); s.loginEmail = reading; s.numbersOwner = reading; s.weekly = weekly
        s.weeklyResets = now.addingTimeInterval(2 * 86400); s.noFiveHour = true; s.plan = "Ultra"; s.updatedAt = now.addingTimeInterval(-age)
        s.resolved = AccountResolver.resolve(e, among: [e], app: app, code: code, loginEmail: reading, names: [:], now: now)
        return s
    }
    _ = Store.writeStatus("spl", record(app: appPat, code: mo, reading: mo.email, weekly: 100))
    let head = Store.status(for: e), own = Store.status(for: e, headline: false)
    let split = ProfileShow.load(e, now: now).splitWords
    check(split?.app == pat.email && split?.code == mo.email, "the split: the app on pat, Claude Code on mo")
    // the headline record: no numbers, no plan, the line instead; nothing full, red or counting down
    check(head?.weekly == nil && head?.fiveHour == nil && head?.plan == nil && AccountView.of(head).label == pat.email
          && AccountView.of(head).line == "cl_audit can't read \(Privacy.masked(pat.email!))'s usage: Claude Code in Terminal is signed in to \(Privacy.masked(mo.email!)).",
          "the profile's record has no numbers for pat, and its line says so: \(AccountView.of(head).line ?? "-")")
    let row = cardRow(e, now: now)
    check(row.full == nil && row.limits.allSatisfy { $0.p == nil } && !row.needsLogin
          && AtLimit.tileCountdown(fiveHour: row.fiveHour, fiveHourResets: head?.fiveHourResets, weekly: row.weekly, weeklyResets: head?.weeklyResets) == nil,
          "the card and its tile: no limits, no full panel, no countdown, no red Sign in")
    check(Usage.of(head) == nil && QuickChatLevel(Usage.of(head), now: now).week == nil,
          "the menu bar strip, the Dock icon and quick chat: no numbers for pat (neutral)")
    check(previewShowsNone(e, head) && panelShowsNone(e, head),
          "the split: the Dock icon's preview (Settings' tile, the Dock's tile) and Settings' panel preview have no numbers, never the samples")
    check(row.show.splitWords?.key == "Sign Claude Code in Terminal in to \(Privacy.masked(pat.email!))…" && split?.loginEmail == pat.email,
          "the key: Sign Claude Code in Terminal in to pat, with pat's address filled in")
    check(split?.numbersHint == "Sign Claude Code in Terminal in to \(Privacy.masked(pat.email!)) to see its numbers."
          && split?.shortLine == "Can't read \(Privacy.masked(pat.email!))'s usage\nTerminal: \(Privacy.masked(mo.email!))",
          "the line under it and the short form: \(split?.numbersHint ?? "-") / \(split?.shortLine ?? "-")")
    let splitShow = ProfileShow.load(e, now: now)
    let panelInfo = DetailsInfo.of(splitShow, name: "x", icon: NSImage(), problem: nil)
    check(split?.shortKey == "Sign in to \(Privacy.masked(pat.email!)) in Terminal…"
          && panelInfo.activeNote == split?.shortLine && panelInfo.splitKey == split?.shortKey && panelInfo.activeLit && !panelInfo.needsLogin,
          "the Dock panel takes the short line and the short key, the lamp lit (pat is in use): \(split?.shortKey ?? "-")")
    check(splitShow.display.none == .split && splitShow.display.lamp && splitShow.display.full == nil && splitShow.display.grey
          && splitShow.display.key == .logInCode(to: pat.email!) && splitShow.keyWords(short: false) == split?.key
          && splitShow.loginAddress == pat.email && splitShow.numbersHint == split?.numbersHint,
          "the value in the split: no numbers (the split), nothing full, grey, lit, the key to pat, pat's address for Sign in")
    // the menu bar row's line: the short form in the split, the record's line otherwise (MenuBarRow.lineWords)
    let barProfile = MenuBarItems.Profile(show: splitShow, problem: head?.problem)
    var notSplit = record(app: appPat, code: mo, reading: mo.email, weekly: 40)
    notSplit.resolved = AccountResolver.resolve(e, among: [e], app: .unknown, code: mo, loginEmail: mo.email, names: [:], now: now)
    let notSplitShow = ProfileShow.of(e, raw: notSplit, now: now)
    check(MenuBarRow.lineWords(barProfile) == split?.shortLine && notSplitShow.display.split == nil
          && MenuBarRow.lineWords(MenuBarItems.Profile(show: notSplitShow)) == notSplit.resolved?.line,
          "the menu bar row says the short split line, and the record's line outside the split")
    // every key and menu item reads its label once, with its ellipsis (the menus no longer add one)
    check(split?.key?.hasSuffix("…") == true && split?.key?.hasSuffix("……") == false && split?.shortKey?.hasSuffix("…") == true,
          "the keys carry their ellipsis once")
    // no split surface says "No usage" or "yet" (the lines, the key, the hint, the short form), whether the addresses show or
    // are masked (Privacy.mask: the setting itself is the operator's, never touched here) and with the app's account by id
    for (what, app, code) in [("shown", pat.email!, mo.email!), ("masked", Privacy.mask(pat.email!), Privacy.mask(mo.email!)),
                              ("by id", "account \(pat.account.prefix(8))", mo.email!)] {
        let s = SplitUsage(app: app, code: code)
        let said = [s.line, s.shortLine, s.numbersHint ?? "", s.key ?? "", s.shortKey ?? "", s.hint ?? "", AccountView.of(head).line ?? ""]
        check(said.allSatisfy { !$0.contains("No usage") && !$0.contains(" yet") && !$0.contains("No numbers") },
              "no split surface says No usage, No numbers or yet (addresses \(what)): \(said)")
    }
    check(own?.weekly == 100 && AccountView.of(own).line?.hasPrefix("Usage: Claude Code on ") == true && AccountView.of(head).codeRow == mo.email,
          "Settings: mo's numbers in mo's own row (labelled), never in the IN USE box")
    // the key starts the existing login: Claude Code's own sign-in on the profile's folder, pat's address filled in, the
    // folder never made (creating: false), no consent sheet (nothing moves)
    var launches: [String] = [], scripts: [String] = []
    FolderGuard.launchSeam = { what, dir in launches.append("\(what) \(dir)"); return true }
    let keepTerminal = ClaudeCLI.openTerminal
    ClaudeCLI.openTerminal = { u in scripts.append((try? String(contentsOf: u, encoding: .utf8)) ?? ""); return true }
    let started = ClaudeCLI.openLogin("/usr/bin/false", account: Account(e), email: ProfileShow.load(e).loginAddress)
    check(started && launches == ["login \(Account(e).configDir)"] && scripts.first?.contains(pat.email!) == true && scripts.first?.contains(mo.email!) == false,
          "the key's login: launched once on the folder, pat's address in it: \(launches)")
    ClaudeCLI.openTerminal = keepTerminal; FolderGuard.launchSeam = nil
    // the menus' and quick chat's Sign in, wired for real (ClaudeCLI.logIn(profile:): its claude found, the guard asked, the
    // script made; nothing runs): pat's address, never mo's; with the app's account known by its id only, no address at all
    let keepLocator = ClaudeLocator.current
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { ["/usr/bin/false"] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
    launches.removeAll(); scripts.removeAll()
    FolderGuard.launchSeam = { what, dir in launches.append("\(what) \(dir)"); return true }
    ClaudeCLI.openTerminal = { u in scripts.append((try? String(contentsOf: u, encoding: .utf8)) ?? ""); return true }
    ClaudeCLI.logIn(profile: e)
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    check(launches == ["login \(Account(e).configDir)"] && scripts.count == 1 && scripts[0].contains(pat.email!) && !scripts[0].contains(mo.email!),
          "Sign in from the menus in the split: launched once through the guard, pat's address filled in, never mo's: \(launches)")
    let anon = AppSignIn.Login(account: uuid(34), org: uuid(74), state: .known, source: "log", at: now)
    var anonRec = record(app: anon, code: mo, reading: mo.email, weekly: 100)
    anonRec.resolved = AccountResolver.resolve(e, among: [e], app: anon, code: mo, loginEmail: mo.email, names: [:], now: now)
    _ = Store.writeStatus("spl", anonRec)
    let anonSplit = ProfileShow.load(e).splitWords
    check(anonSplit != nil && anonSplit?.key == nil && anonSplit?.hint == "Sign Claude Code in Terminal in to the Claude app's account"
          && anonSplit?.numbersHint == "Sign Claude Code in Terminal in to the Claude app's account to see its numbers."
          && ProfileShow.load(e).loginAddress == nil,
          "the app's account known by its id only: no key, the hint, and no address (never mo's): \(anonSplit?.app ?? "-")")
    launches.removeAll(); scripts.removeAll()
    ClaudeCLI.logIn(profile: e)
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    check(launches.count == 1 && scripts.count == 1 && !scripts[0].contains(mo.email!) && !scripts[0].contains("--email"),
          "…and a Sign in then fills in no address at all")
    ClaudeCLI.openTerminal = keepTerminal; FolderGuard.launchSeam = nil; ClaudeLocator.current = keepLocator
    _ = Store.writeStatus("spl", record(app: appPat, code: mo, reading: mo.email, weekly: 100))

    // the split as a switch waiting for the Claude app (the hub's ruling): the newest switch went from pat to mo (Claude
    // Code's account now), it is linked or still open, and the app is still on pat: the switched line, no key
    var toMo = SwitchReceipt(id: SwitchEngine.receiptID(now, "spl"), profile: "spl", standby: "km", dataDir: "/x", from: SeatID(pat), to: SeatID(mo), started: now)
    toMo.steps = [SwitchReceipt.Step(kind: .entry, path: "/x/a", sha: nil, parked: nil, original: nil, done: true)]
    var linkedToMo = toMo; linkedToMo.linked = now
    func splitWith(app: AppSignIn.Login, newest: SwitchReceipt?, names: [String: String] = [:]) -> SplitUsage? {
        var s = record(app: app, code: mo, reading: mo.email, weekly: 100)
        s.resolved = AccountResolver.resolve(e, among: [e], app: app, code: mo, loginEmail: mo.email, names: names, newestSwitch: newest, now: now)
        _ = Store.writeStatus("spl", s)
        return ProfileShow.load(e, now: now).splitWords
    }
    // the card's after-switch words on every surface: the heading, then what's left; the short form is the heading
    let switchedLine = "Switching to \(Privacy.masked(mo.email!)): one step left. Sign the Claude app in to \(Privacy.masked(mo.email!)) to finish."
    for (what, r) in [("linked (Claude Code reached mo)", linkedToMo), ("still open", toMo)] {
        let s = splitWith(app: appPat, newest: r)
        check(s?.switched == true && s?.line == switchedLine && s?.key == nil && s?.loginEmail == nil
              && Store.status(for: e)?.weekly == nil && AccountView.of(Store.status(for: e)).line == switchedLine
              && Store.status(for: e, headline: false)?.weekly == 100,
              "a switch to mo waiting for the app (\(what)): the switched line, no key, no numbers for pat, mo's in its own record: \(s?.line ?? "-")")
    }
    let zed = Seat(account: uuid(33), organization: uuid(73), email: "zed@example.com")
    let appZed = AppSignIn.Login(account: zed.account, org: zed.organization, state: .known, source: "log", at: now)
    let third = splitWith(app: appZed, newest: linkedToMo, names: [zed.account.lowercased(): zed.email!])
    check(third?.switched == false && third?.key?.hasPrefix("Sign Claude Code in Terminal in to ") == true && third?.line.hasPrefix("cl_audit can't read ") == true,
          "the app on a third account (not the one the switch left): a split by hand, the B8 line and key")
    var undone = toMo; undone.undone = now
    var leftAsIs = toMo; leftAsIs.leftAsIs = now
    for (what, r) in [("undone", undone), ("left as it is", leftAsIs)] {
        let s = splitWith(app: appPat, newest: r)
        check(s?.switched == false && s?.key == "Sign Claude Code in Terminal in to \(Privacy.masked(pat.email!))…" && s?.loginEmail == pat.email,
              "the switch \(what): a split by hand, the B8 line and key")
    }
    var dayOld = linkedToMo; dayOld.linked = now.addingTimeInterval(-25 * 3600)
    let dayOldSplit = splitWith(app: appPat, newest: dayOld)
    check(dayOldSplit?.switched == false && dayOldSplit?.key == "Sign Claude Code in Terminal in to \(Privacy.masked(pat.email!))…",
          "a switch linked 25 hours ago waits no more: a split by hand, the B8 line and key")
    let older = splitWith(app: appPat, newest: nil)
    check(older?.switched == false && older?.key != nil, "no switch at all: a split by hand")
    var toOther = toMo; toOther.to = SeatID(zed)
    check(splitWith(app: appPat, newest: toOther)?.switched == false, "the newest switch went to another account than Claude Code's: by hand")
    _ = Store.writeStatus("spl", record(app: appPat, code: mo, reading: mo.email, weekly: 100))

    // numbersFor comes from the reading itself: a .claude.json naming another account changes whose they are not
    let staleCode = AccountResolver.resolve(e, among: [e], app: appPat, code: pat, loginEmail: mo.email, names: [:], now: now)
    check(staleCode.numbersFor == mo.email && staleCode.readStale == true && staleCode.codeName == pat.email,
          "the folder names pat, the reading was mo's: numbersFor stays mo (the reading's), and the reading is stale: \(staleCode.numbersFor ?? "-")")
    var staleRec = record(app: appPat, code: pat, reading: mo.email, weekly: 40); staleRec.resolved = staleCode
    _ = Store.writeStatus("spl", staleRec)
    check(Store.status(for: e)?.weekly == nil && Store.status(for: e, headline: false)?.weekly == nil,
          "a stale reading's numbers show nowhere until a read for the folder's account")
    // the reader: numbers whose reading doesn't name its account (no profile looked up for its token) carry none
    signIn(e.configDir, mo)
    var posts: [String] = []
    // the poster runs on a background queue: its titles join the list on the main thread, where the checks read it
    UsageReader.testPoster = { _, title, _, _, _ in DispatchQueue.main.async { posts.append(title) }; return 0 }
    let reply = Data(#"{"seven_day":{"utilization":100,"resets_at":"2099-01-02T00:00:00Z"}}"#.utf8)
    let ok200 = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)
    let sr = UsageReader(e, defaults: UserDefaults(suiteName: "cl-audit-surfaces-split-\(getpid())")!)
    sr.finish(data: reply, response: ok200, error: nil, asked: Date(), gen: sr.generation)
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    let saved = Store.status("spl")
    check(saved?.weekly == 100 && saved?.resolved?.numbersFor == nil && saved?.numbersOwner == nil,
          "the reader: numbers with no account from their reading say none (never .claude.json's mo): \(saved?.resolved?.numbersFor ?? "nil")")
    check(posts.isEmpty && ProfileShow.of(e, raw: saved).display.split != nil && Store.status(for: e)?.weekly == nil,
          "the split: no full or back alert, no switch offer, and no numbers for the profile: \(posts)")
    sr.stop()
    // the same read with the app on mo (no split): the full alert goes out (the check above isn't empty by accident). One
    // account belongs to one profile: a second profile whose folder is signed in to mo too (a clash) shows no numbers
    // and raises no alert, so the full limit alerts exactly once, from the profile whose account it is
    var same = profile("spm", "~/.claude-spm", mo); same.claudeWindow = false
    var twin = profile("spt", "~/.claude-spt", nil); twin.claudeWindow = false
    signIn(same.configDir, mo, plan: "Ultra"); signIn(twin.configDir, mo, plan: "Ultra")
    try! Store.save([same, twin])
    posts.removeAll()
    let mr = UsageReader(same, defaults: UserDefaults(suiteName: "cl-audit-surfaces-same-\(getpid())")!)
    let tr = UsageReader(twin, defaults: UserDefaults(suiteName: "cl-audit-surfaces-twin-\(getpid())")!)
    mr.finish(data: reply, response: ok200, error: nil, asked: Date(), gen: mr.generation)
    tr.finish(data: reply, response: ok200, error: nil, asked: Date(), gen: tr.generation)
    let until = Date().addingTimeInterval(5)
    while !posts.contains(where: { $0.contains("full") }) && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))                // time for a second, unwanted one to show
    let fulls = posts.filter { $0.contains("full") }
    check(fulls == ["Claude Spm: weekly limit full"],
          "two profiles' folders on one account: exactly one full alert, from the profile whose account it is: \(fulls)")
    check(Store.status("spt")?.resolved?.clash == "Spm" && Store.status(for: twin)?.weekly == nil,
          "the twin is the clash: its card shows no numbers, and it stays quiet")
    // nor the plan: the reader writes none into a clash record (it is mo's, Spm's), so every reader of it, the widget too,
    // shows none; the profile whose account it is keeps it
    let widgetClash = AgentFiles.load(from: Store.folder, now: now)
    check(Store.status("spm")?.plan == "Ultra" && Store.status("spt")?.plan == nil && Store.status("spt")?.problem == Store.status("spt")?.resolved?.line
          && widgetClash.first { $0.id == "spm" }?.plan == "Ultra" && widgetClash.first { $0.id == "spt" }.map { $0.plan == nil && $0.week == nil } == true,
          "the reader's clash record has no plan (Spm's Ultra stays on Spm): the widget shows none for the twin: \(Store.status("spt")?.plan ?? "nil")")
    mr.stop(); tr.stop()
    Store.removeStatus("spt")                                               // the widget checks below read every record
    try! Store.save([e, same])
    UsageReader.testPoster = nil

    // old numbers are only last known: never full, never a countdown or an offer
    _ = Store.writeStatus("spm", record(app: .unknown, code: mo, reading: mo.email, weekly: 100, age: 20 * 60))
    let old = Store.status(for: same)
    check(old?.weekly == nil && cardRow(same, now: now).full == nil, "numbers 20 minutes old: a full limit is left out (last known, never full)")
    _ = Store.writeStatus("spm", record(app: .unknown, code: mo, reading: mo.email, weekly: 100, age: 60))
    check(Store.status(for: same)?.weekly == 100 && cardRow(same).full != nil, "a minute old: full, as read")

    // the widget (its own copy of the rules, over the same records): the split shows nothing for the profile, a fresh full
    // limit shows, an old one doesn't
    _ = Store.writeStatus("spl", record(app: appPat, code: mo, reading: mo.email, weekly: 100))
    _ = Store.writeStatus("spm", record(app: .unknown, code: mo, reading: mo.email, weekly: 100, age: 60))
    var w = AgentFiles.load(from: Store.folder, now: now)
    check(w.first { $0.id == "spl" }.map { $0.week == nil && $0.five == nil && $0.plan == nil && $0.full(now: now) == nil } == true,
          "the widget in the split: no numbers, no plan, nothing full for the profile")
    check(w.first { $0.id == "spm" }?.week == 100 && w.first { $0.id == "spm" }?.full(now: now) != nil, "the widget without the split: the full week, as read")
    _ = Store.writeStatus("spm", record(app: .unknown, code: mo, reading: mo.email, weekly: 100, age: 20 * 60))
    w = AgentFiles.load(from: Store.folder, now: now)
    check(w.first { $0.id == "spm" }.map { $0.week == nil && $0.full(now: now) == nil } == true, "the widget: 20-minute-old numbers never full")

    // the owner arrives later: numbers read with a token whose account isn't known yet are held (none shown, no alert);
    // when its account comes back they are taken, with their alerts (spm: no split, Claude Code's account in use)
    Store.removeStatus("spm")
    try! Store.save([same])          // (spm alone: spl's seat is mo too, which would make mo another profile's account)
    posts.removeAll()
    UsageReader.testPoster = { _, title, _, _, _ in posts.append(title); return 0 }
    let hr = UsageReader(same, defaults: UserDefaults(suiteName: "cl-audit-surfaces-held-\(getpid())")!)
    hr.finish(data: reply, response: ok200, error: nil, asked: Date(), gen: hr.generation, key: "k1")
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    check(hr.heldReading?.key == "k1" && Store.status("spm")?.weekly == nil && posts.isEmpty,
          "a reading whose owner isn't known yet: held, no numbers anywhere, no alert")
    hr.profileFound(mo.email!, key: "k1"); hr.save()       // (as the lookup's return does; no tick: nothing is read here)
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    check(hr.heldReading == nil && Store.status("spm")?.weekly == 100 && Store.status("spm")?.resolved?.numbersFor == mo.email
          && posts.contains { $0.contains("full") }, "its owner known (mo): the numbers, labelled mo, and the full alert then: \(posts)")
    // a renewed token of the same account: the numbers don't blank while its owner is looked up again
    let half = Data(#"{"seven_day":{"utilization":50,"resets_at":"2099-01-02T00:00:00Z"}}"#.utf8)
    hr.finish(data: half, response: ok200, error: nil, asked: Date(), gen: hr.generation, key: "k2")
    check(Store.status(for: same)?.weekly == 100 && hr.heldReading?.key == "k2", "a token refresh: the last owned numbers stay (no flapping) until its owner is known")
    hr.profileFound(mo.email!, key: "k2"); hr.save()
    check(Store.status(for: same)?.weekly == 50 && Store.status("spm")?.resolved?.numbersFor == mo.email, "…then the new reading's, the same account")
    // the token on mo, the folder's .claude.json naming pat: never decided from the folder; once the reading's owner is
    // known (mo), the folder has left it: stale, shown nowhere
    signIn(same.configDir, pat)
    hr.finish(data: reply, response: ok200, error: nil, asked: Date(), gen: hr.generation, key: "k3")
    check(Store.status(for: same)?.weekly != 100, "token mo, folder pat, owner not yet known: the new reading isn't shown")
    hr.profileFound(mo.email!, key: "k3"); hr.save()
    let mixed = Store.status("spm")
    check(mixed?.resolved?.numbersFor == mo.email && mixed?.resolved?.readStale == true && Store.status(for: same)?.weekly == nil,
          "…its owner known: numbersFor mo (the reading's), the folder on pat: stale, no numbers shown: \(mixed?.resolved?.numbersFor ?? "-")")
    hr.stop()

    // a lookup outage: a token whose account was confirmed keeps it (its numbers stay current); a new token's reading is
    // held, then, its lookup still failing, shown as "account not confirmed" (as read, never full, no alert); its owner
    // back, the usual rules
    signIn(same.configDir, mo)
    Store.removeStatus("spm"); posts.removeAll()
    func week(_ p: Int) -> Data { Data(#"{"seven_day":{"utilization":\#(p),"resets_at":"2099-01-02T00:00:00Z"}}"#.utf8) }
    let lr = UsageReader(same, defaults: UserDefaults(suiteName: "cl-audit-surfaces-lookup-\(getpid())")!)
    lr.profileFound(mo.email!, key: "c1")
    lr.finish(data: week(50), response: ok200, error: nil, asked: Date(), gen: lr.generation, key: "c1")
    lr.lookupFailed()
    lr.finish(data: week(60), response: ok200, error: nil, asked: Date(), gen: lr.generation, key: "c1")
    check(Store.status(for: same)?.weekly == 60 && lr.heldReading == nil && !lr.unconfirmed && Store.status("spm")?.resolved?.numbersFor == mo.email,
          "the lookup failing with a known token: its numbers stay current, still mo's")
    lr.finish(data: week(100), response: ok200, error: nil, asked: Date(), gen: lr.generation, key: "c2"); lr.lookupFailed()
    check(lr.heldReading?.key == "c2" && Store.status(for: same)?.weekly == 60, "a new token: its first reading held, the last owned numbers stay")
    lr.finish(data: week(100), response: ok200, error: nil, asked: Date(), gen: lr.generation, key: "c2"); lr.lookupFailed()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    let un = Store.status("spm"), unHead = Store.status(for: same)
    check(lr.unconfirmed && un?.ownerUnconfirmed == true && un?.weekly == 100 && unHead?.weekly == nil
          && AccountView.of(unHead).line == Store.unconfirmedWords && cardRow(same).full == nil && posts.isEmpty,
          "its second reading still without an owner: \"account not confirmed\", never full, no alert: \(posts)")
    lr.finish(data: week(70), response: ok200, error: nil, asked: Date(), gen: lr.generation, key: "c2")
    check(Store.status(for: same)?.weekly == 70 && AccountView.of(Store.status(for: same)).line == Store.unconfirmedWords
          && Store.status(for: same)?.updatedAt != nil, "…not full: the percent shows, with its age and the line")
    lr.profileFound(mo.email!, key: "c2"); lr.save()
    let back2 = Store.status("spm")
    check(!lr.unconfirmed && back2?.ownerUnconfirmed == nil && back2?.resolved?.numbersFor == mo.email && Store.status(for: same)?.weekly == 70
          && AccountView.of(Store.status(for: same)).line == nil, "its owner back (mo): the usual rules")
    lr.stop()
    UsageReader.testPoster = nil
    try? Store.save([])
    Store.removeStatus("spl"); Store.removeStatus("spm")
}

// ============ 8. the status record's one codec (StatusRecord.swift): today's bytes, older files, the headline over them ============
do {
    // written by main 20489f5's own writer (its IconStatus and ResolvedAccount, Store.writeStatus's settings): every field the
    // agent writes; the split with a switch waiting and a stale reading; a file from before the resolver, numbersOwner and
    // ownerUnconfirmed; a resolver answer from before its newer keys, with a clash, expired and unconfirmed
    let fixtures: [(String, String)] = [
        ("full", #"{"credits":{"cap":50,"currency":"USD","enabled":true,"out":false,"spentAt":1799999400,"used":4.2},"expectedEmail":"ultra-1@example.com","fiveHour":37.5,"fiveHourResets":1800003600,"loginEmail":"ultra-1@example.com","numbersOwner":"ultra-1@example.com","plan":"Ultra","renewNote":"Renewed 09:12","renewing":false,"resolved":{"account":"00000000-0000-4000-8000-000000000001","at":1800000000,"codeAccount":"00000000-0000-4000-8000-000000000001","codeName":"ultra-1@example.com","differs":false,"email":"ultra-1@example.com","fromApp":true,"lit":true,"numbersFor":"ultra-1@example.com"},"scoped":[{"name":"Fable","percent":12,"resets":1800259200}],"source":"Anthropic","state":"ok","updatedAt":1800000000.25,"weekly":64,"weeklyResets":1800259200}"#),
        ("split", #"{"expectedEmail":"mo@example.com","loginEmail":"mo@example.com","noFiveHour":true,"numbersOwner":"mo@example.com","plan":"max","resolved":{"account":"00000000-0000-4000-8000-000000000002","at":1800000000,"codeAccount":"00000000-0000-4000-8000-000000000003","codeName":"mo@example.com","differs":true,"email":"pat@example.com","fromApp":true,"line":"Usage: Claude Code on m…@example.com","lit":true,"numbersFor":"mo@example.com","readStale":true,"switchWaits":true},"state":"ok","updatedAt":1800000000,"weekly":100,"weeklyResets":1800007200}"#),
        ("old", #"{"fiveHour":5,"loginEmail":"free@example.com","source":"Claude Code status line","state":"ok","updatedAt":1800000000,"weekly":33}"#),
        ("mid", #"{"expectedEmail":"ultra-2@example.com","loginEmail":"ultra-2@example.com","ownerUnconfirmed":true,"plan":"pro","problem":"Sign-in expired","resolved":{"at":1799999970,"clash":"Home","differs":false,"fromApp":false,"line":"Claude Code's folder is signed in to Home's account: its numbers show on Home.","lit":false,"numbersFor":"account 00000000","recordTooLarge":true},"state":"expired"}"#)]
    var decoded: [String: IconStatus] = [:]
    for (name, json) in fixtures {
        let rec = StatusCodec.decode(Data(json.utf8))
        decoded[name] = rec
        check(rec != nil && rec.flatMap(StatusCodec.encode).map { String(decoding: $0, as: UTF8.self) } == json,
              "\(name): today's file decodes and encodes back byte for byte")
    }
    check(decoded["full"]?.updatedAt == Date(timeIntervalSince1970: 1_800_000_000.25) && decoded["full"]?.credits?.used == 4.2
          && decoded["full"]?.scoped?.first?.percent == 12 && decoded["full"]?.resolved?.codeAccount == "00000000-0000-4000-8000-000000000001",
          "every field read as written (dates as seconds, fractions kept)")
    let old = decoded["old"], mid = decoded["mid"]
    check(old?.resolved == nil && old?.numbersOwner == nil && old?.ownerUnconfirmed == nil && old?.noFiveHour == nil && old?.weekly == 33,
          "a file from before the newer keys: they are empty, the numbers as written")
    check(mid?.resolved?.codeName == nil && mid?.resolved?.readStale == nil && mid?.resolved?.switchWaits == nil && mid?.resolved?.clash == "Home"
          && mid?.resolved?.clashID == nil, "a resolver answer from before its newer keys (clashID too): they are empty")
    // today's writer with the clash's profile id (step 3a): the field is only added, and round-trips
    let withID = #"{"resolved":{"at":1800000000,"clash":"Home","clashID":"home","differs":false,"fromApp":false,"lit":false},"state":"ok"}"#
    let idRec = StatusCodec.decode(Data(withID.utf8))
    check(idRec?.resolved?.clashID == "home" && idRec.flatMap(StatusCodec.encode).map { String(decoding: $0, as: UTF8.self) } == withID,
          "a record naming the clash's profile id decodes and encodes back byte for byte")
    check(StatusCodec.decode(Data(#"{"state":"ok","weekly":12,"later":{"x":1}}"#.utf8))?.weekly == 12 && StatusCodec.decode(Data("{}".utf8)) == nil
          && StatusCodec.decode(Data("not json".utf8)) == nil, "a key from a newer version is skipped; no state, or not JSON: no record")

    // the one writer: Store.writeStatus writes the codec's bytes, and the one reader reads them back
    if let full = decoded["full"] {
        let written = Store.writeStatus("codec", full)
        let onDisk = try? Data(contentsOf: Store.statusFolder.appendingPathComponent("codec.json"))
        check(written != nil && written == onDisk && onDisk.map { String(decoding: $0, as: UTF8.self) } == fixtures[0].1,
              "Store.writeStatus writes exactly the codec's bytes")
        Store.removeStatus("codec")
    }

    // the headline over the fixtures: ProfileCore's split is the one rule (SplitUsage only words it, SplitUsage.words)
    let at = Date(timeIntervalSince1970: 1_800_000_060)
    for (name, rec) in decoded {
        let split = Headline.split(rec.owner)
        check((split != nil) == (name == "split") && (SplitUsage.words(rec, split) != nil) == (split != nil),
              "\(name): the split only in the split's file, and its words with it")
    }
    var fresh = decoded["split"]!; fresh.resolved?.readStale = nil
    var unsure = fresh; unsure.ownerUnconfirmed = true
    var byHand = fresh; byHand.resolved?.switchWaits = nil
    var elsewhere = fresh; elsewhere.resolved?.clash = "Home"
    var nameless = fresh; nameless.resolved?.codeName = nil; nameless.resolved?.numbersFor = nil
    for (name, rec, waits) in [("unconfirmed", unsure, Bool?.none), ("fresh", fresh, true), ("by hand", byHand, false),
                               ("elsewhere", elsewhere, nil), ("nameless", nameless, nil)] {
        let words = SplitUsage.words(rec, Headline.split(rec.owner))
        check(Headline.split(rec.owner)?.switchWaits == waits && words?.switched == waits
              && (waits == nil || (words?.app == "pat@example.com" && words?.code == "mo@example.com")),
              "\(name): the headline's split (switch waiting: \(waits.map(String.init) ?? "no split")), and the words name pat and mo")
    }
    let ages = Headline.Ages(freshFor: 6 * 60)
    let splitShown = fresh.shown(fresh.headline(now: at, ages: ages), now: at)
    check(splitShown.weekly == nil && splitShown.plan == nil && splitShown.updatedAt == fresh.updatedAt
          && fresh.shown(fresh.headline(now: at, ages: ages), split: false, now: at).weekly == 100,
          "the split: no numbers or plan on the headline; Claude Code's own (split false) keep them")
    let staleShown = decoded["split"]!.shown(decoded["split"]!.headline(now: at, ages: ages), split: false, now: at)
    check(staleShown.weekly == nil && staleShown.plan == nil && staleShown.updatedAt == nil, "a stale reading: nothing, nowhere, not even when")
    let oldFull = fresh.shown(fresh.headline(now: at.addingTimeInterval(10 * 60), ages: ages), split: false, now: at.addingTimeInterval(10 * 60))
    check(oldFull.weekly == nil && oldFull.weeklyResets == nil, "11 minutes old: a full limit is left out (last known)")
    let unsureShown = unsure.shown(unsure.headline(now: at, ages: ages), now: at)
    check(unsureShown.weekly == nil && unsureShown.plan == "max", "unconfirmed: no split, but a full limit never shows")
    var signedOut = decoded["old"]!; signedOut.state = "noLogin"
    check(signedOut.shown(signedOut.headline(now: at, ages: ages), now: at).weekly == nil, "signed out: no numbers")
    let fullShown = decoded["full"]!.shown(decoded["full"]!.headline(now: at, ages: ages), now: at)
    check(fullShown.weekly == 64 && fullShown.fiveHour == 37.5 && fullShown.scoped?.first?.percent == 12 && fullShown.credits?.used == 4.2
          && fullShown.plan == "Ultra", "the profile's own numbers: all of them")
}

// ============ 9. ProfileCore step 3a: one value per profile (ProfileShow), drawn by the menu bar, the Dock icon and its panel ============
// (on the main actor: the Dock app's delegate and the menu bar's items are drawn there)
MainActor.assumeIsolated {
    let now = Date()
    var e = profile("show", "~/.claude-show", u1); e.claudeWindow = false
    e.standby = [StandbyAccount(email: u2.email!, seat: u2, id: "k2", plan: "Max", lastInUse: now.addingTimeInterval(-86400))]
    try! Store.save([e, other])
    func rec(_ state: String = "ok", week: Double? = 40, five: Double? = 12, age: TimeInterval = 60, weekIn: TimeInterval = 2 * 86400,
             fiveIn: TimeInterval = 3600, login: String? = u1.email, code: Seat? = u1) -> IconStatus {
        var s = IconStatus(state: state); s.loginEmail = login; s.expectedEmail = u1.email; s.weekly = week; s.fiveHour = five
        s.weeklyResets = now.addingTimeInterval(weekIn); s.fiveHourResets = now.addingTimeInterval(fiveIn)
        s.updatedAt = now.addingTimeInterval(-age); s.source = "Anthropic"; s.plan = "Max"
        s.resolved = AccountResolver.resolve(e, among: [e, other], app: .unknown, code: code, loginEmail: login, names: [:], now: now)
        return s
    }
    func show(_ r: IconStatus, _ entry: AccountEntry? = nil) -> ProfileShow {
        _ = Store.writeStatus("show", r); return ProfileShow.load(entry ?? e, now: now)
    }
    func lamp(_ m: NSMenu) -> Bool { m.items.first?.image != nil }
    func items(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
    let u2Short = AccountNames.short(u2.email!)

    // the one formula for the thresholds: the app's and the widget's
    check(Store.ages(e) == StatusAges.of(pollMinutes: 5) && StatusAges.freshFor(pollMinutes: 5) == 6 * 60
          && StatusAges.greyAfter(pollMinutes: 5) == 30 * 60 && StatusAges.freshFor(pollMinutes: 20) == 21 * 60
          && StatusAges.greyAfter(pollMinutes: 20) == 60 * 60 && StatusAges.freshFor(pollMinutes: 1) == 6 * 60,
          "the thresholds: fresh for the read interval (5 min at least) plus a minute, grey after three reads (30 min at least)")

    // fresh, the profile's own: numbers, lit, no key, not grey, on every 3a surface
    let ok = show(rec())
    let okDock = dockOf(e, ok), okItem = MenuBarItems.item(MenuBarItems.Profile(show: ok), now: now)
    check(ok.display.usage?.weekly == 40 && ok.display.tier == .fresh && ok.display.lamp && ok.display.key == nil && !ok.display.grey
          && okItem.week == 40 && !okItem.stale && !okDock.face.stale && okDock.face.weekly == 40 && okDock.panel.activeLit && lamp(okDock.menu)
          && titles(okDock.menu).contains("Weekly limit: 40% · resets \(AppDelegate.when(now.addingTimeInterval(2 * 86400)))"),
          "fresh: the numbers, the lamp lit, no key; the menu bar, the Dock face, its panel and its menu alike")

    // the tiers: last known at 10 minutes (a full week left out, the 5-hour shown), grey past 30 minutes
    let known = show(rec(week: 100, age: 10 * 60))
    let knownDock = dockOf(e, known)
    check(known.display.tier == .lastKnown && known.display.usage?.weekly == nil && known.display.usage?.fiveHour == 12 && known.display.full == nil
          && !known.display.grey && MenuBarItems.item(MenuBarItems.Profile(show: known), now: now).countdown == nil
          && knownDock.face.countdown == nil && !knownDock.face.stale && knownDock.panel.full == nil,
          "10 minutes old: last known, a full week left out, no countdown anywhere, not grey")
    check(show(rec(age: 29 * 60)).display.tier == .lastKnown, "29 minutes old: last known, not grey yet")
    let old = show(rec(age: 40 * 60))
    let oldDock = dockOf(e, old), oldItem = MenuBarItems.item(MenuBarItems.Profile(show: old), now: now)
    check(old.display.tier == .stale && old.display.grey && old.display.usage?.weekly == 40 && old.display.level(40) == .none
          && oldItem.stale && oldItem.week == 40 && oldDock.face.stale && oldDock.face.weekly == 40,
          "40 minutes old: grey on the menu bar (as on the Dock face, one threshold), the numbers still drawn")
    var slow = e; slow.pollMinutes = 20
    check(show(rec(age: 40 * 60), slow).display.tier == .lastKnown && show(rec(age: 61 * 60), slow).display.tier == .stale,
          "a 20-minute read interval: grey only after an hour")

    // full and fresh: the countdown, the full line and the offer; full and old: none of them
    let full = show(rec(week: 100, weekIn: 3 * 3600))
    let fullDock = dockOf(e, full), fullBar = menuBarMenu(full)
    check(full.display.full?.kind == .week && MenuBarItems.item(MenuBarItems.Profile(show: full), now: now).countdown != nil
          && fullDock.face.countdown != nil && fullDock.panel.full != nil
          && titles(fullDock.menu).contains { $0.hasPrefix("Week full · ") } && titles(fullDock.menu).contains("Switch to \(u2Short)…")
          && titles(fullBar).contains("Switch to \(u2Short)…"),
          "a fresh full week: the countdown on both icons, the full panel, the full line and the offer in both menus")
    let fullOld = show(rec(week: 100, age: 10 * 60, weekIn: 3 * 3600))
    check(fullOld.display.full == nil && dockOf(e, fullOld).face.countdown == nil && !titles(dockOf(e, fullOld).menu).contains("Switch to \(u2Short)…")
          && !titles(menuBarMenu(fullOld)).contains("Switch to \(u2Short)…"), "the same full week read 10 minutes ago: nothing full, no offer")

    // a reset that has passed: that limit has no percent; both passed: no numbers at all
    let pastReset = show(rec(week: 100, weekIn: -60))
    check(pastReset.display.usage?.weekly == nil && pastReset.display.usage?.weeklyResets == nil && pastReset.display.usage?.fiveHour == 12
          && pastReset.display.full == nil && dockOf(e, pastReset).face.countdown == nil, "the week's reset passed: no week, nothing full, the 5-hour shown")
    let gone = show(rec(weekIn: -60, fiveIn: -60))
    check(gone.display.usage == nil && gone.display.none == .notRead && gone.display.grey && dockOf(e, gone).face.stale
          && dockOf(e, gone).panel.weekly == nil, "both resets passed: no numbers (nothing left), grey")

    // the lamp agrees with the face (Settings' rule): off while the sign-in needs the person or can't be read
    for (state, words) in [("denied", "refused"), ("unreadable", "unreadable")] {
        let s = show(rec(state))
        let dk = dockOf(e, s)
        check(s.display.usage?.weekly == 40 && !s.display.lamp && s.display.key == nil && !dk.panel.activeLit && !lamp(dk.menu)
              && !titles(dk.menu).contains("Sign in…") && !titles(menuBarMenu(s)).contains("Sign in…"),
              "a sign-in \(words): the numbers as read, the lamp off on the menu bar row, the Dock panel and its menu, no Sign in")
    }
    for state in ["expired", "noLogin"] {
        let s = show(rec(state))
        let dk = dockOf(e, s)
        check(s.display.usage == nil && !s.display.lamp && s.display.needsLogin && dk.face.stale && !dk.panel.activeLit && !lamp(dk.menu)
              && titles(dk.menu).contains("Sign in…") && titles(menuBarMenu(s)).contains("Sign in…") && dk.face.countdown == nil,
              "\(state): no numbers, grey, the lamp off, Sign in… in both menus")
    }
    let mixed = show(rec(login: u3.email, code: u1))
    let mixedDock = dockOf(e, mixed)
    check(mixed.display.otherAccount && mixed.display.needsLogin && !mixed.display.lamp && mixedDock.face.warn && mixedDock.panel.mismatch
          && !lamp(mixedDock.menu) && titles(mixedDock.menu).contains("Sign in…"),
          "the sign-in on another account than the folder's: the warning, Sign in…, the lamp off")

    // another profile's account: the clash names that profile by its id (names needn't be unique), the lamp off
    let clash = show(rec(login: u3.email, code: u3))
    check(Store.status("show")?.resolved?.clashID == "other" && clash.display.clash == ProfileDisplay.Clash(id: "other", name: "Other")
          && !clash.display.lamp && !dockOf(e, clash).panel.activeLit,
          "Claude Code's folder on another profile's account: the clash by id (other) and name, the lamp off")
    // the review's record: the Claude app decided the account, Claude Code's folder on Other's account, the same address,
    // state ok. Lit before on the menus only; Settings' in-use box is off (its `elsewhere` finds Other by name: `move == nil`
    // fails), and now the 3a surfaces agree with it
    let appClash = #"{"expectedEmail":"ultra-1@example.com","loginEmail":"ultra-1@example.com","resolved":{"account":"\#(u1.account)","at":1800000000,"clash":"Other","clashID":"other","differs":false,"email":"ultra-1@example.com","fromApp":true,"lit":true,"numbersFor":"ultra-1@example.com"},"state":"ok","updatedAt":\#(Int(now.timeIntervalSince1970) - 60),"weekly":40}"#
    let appClashShow = show(StatusCodec.decode(Data(appClash.utf8))!)
    let settingsModel = SettingsModel(); settingsModel.accounts = [e, other]
    let appClashDock = dockOf(e, appClashShow)
    check(AccountView.of(appClashShow.record).lit && !appClashShow.display.lamp && !appClashDock.panel.activeLit && !lamp(appClashDock.menu)
          && AccountSettings(entry: .constant(e), model: settingsModel).elsewhere?.owner.id == "other",
          "an app-decided account with Claude Code on Other's: the lamp off on the menu bar row, the Dock panel and menu, as Settings' (its move is Other)")
    check(appClashShow.display.key == .logIn && appClashShow.loginAddress == u1.email && appClashDock.panel.needsLogin
          && titles(appClashDock.menu).contains("Sign in…") && titles(menuBarMenu(appClashShow)).contains("Sign in…"),
          "…and Sign in… (to the profile's own u1) on the Dock panel, the Dock menu and the menu bar menu, as on the card")

    // a value made a moment before a full limit's reset: drawn after it, no countdown (the face and the icon look again)
    let beforeReset = ProfileShow.of(e, raw: rec(week: 100, weekIn: -60), now: now.addingTimeInterval(-120))
    check(beforeReset.display.full != nil && beforeReset.display.full(now: Date()) == nil && dockOf(e, beforeReset).face.countdown == nil
          && MenuBarItems.item(MenuBarItems.Profile(show: beforeReset), now: Date()).countdown == nil,
          "a full week whose reset passed since the value was made: no countdown on the Dock face or the menu bar icon")

    // standby is never read: no surface shows a standby account with numbers
    for (what, s) in [("fresh", ok), ("full", full)] {
        let key = AccountEntry.switchKey("show", "k2")
        let standbyLines = (items(dockOf(e, s).menu) + items(menuBarMenu(s))).filter { ($0.representedObject as? String) == key }.map(\.title)
        check(!standbyLines.isEmpty && standbyLines.allSatisfy { !$0.contains("%") },
              "\(what): the standby account is listed in both menus, never with numbers: \(standbyLines)")
    }
    // unconfirmed: as read, never full, said so
    var unsure = rec(week: 100, weekIn: 3 * 3600); unsure.ownerUnconfirmed = true
    let us = show(unsure)
    check(us.display.usage?.fiveHour == 12 && us.display.usage?.weekly == nil && us.display.full == nil && us.lineWords(short: true) == Store.unconfirmedWords
          && dockOf(e, us).panel.activeNote == Store.unconfirmedWords && dockOf(e, us).face.countdown == nil,
          "unconfirmed: as read, a full week left out, the line says so on the row and the panel")
    // …but a record from before the resolver has no line for it (as Store.shown, which only sets a resolved block's line)
    var unsureOld = rec(); unsureOld.resolved = nil; unsureOld.ownerUnconfirmed = true
    let usOld = show(unsureOld)
    check(usOld.display.line == nil && usOld.lineWords(short: true) == nil && dockOf(e, usOld).panel.activeNote == nil,
          "unconfirmed in a record from before the resolver: no line, as before")
    // no record at all: nothing, grey, no lamp
    Store.removeStatus("show")
    let noRec = ProfileShow.load(e, now: now)
    check(noRec.record == nil && noRec.display.usage == nil && noRec.display.grey && !noRec.display.lamp && dockOf(e, noRec).face.stale,
          "no record: no numbers, grey, the lamp off")
    try? Store.save([])
}

// ============ 10. quick chat and the alerts through the one Headline (ProfileCore step 3d) ============
do {
    let pat = Seat(account: uuid(41), organization: uuid(81), email: "pat@example.com")
    let mo = Seat(account: uuid(42), organization: uuid(82), email: "mo@example.com")
    let ok200 = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)
    let fullWeek = Data(#"{"seven_day":{"utilization":100,"resets_at":"2099-01-02T00:00:00Z"}}"#.utf8)
    // the folder on mo; its standby list (a hand-edited or older file) still has mo too, the least used by its last week,
    // so a pick over the raw list names the account in use
    var e = profile("qa", "~/.claude-qa", mo); e.claudeWindow = false
    e.standby = [StandbyAccount(email: mo.email!, seat: mo, id: "kmo", lastInUse: t0, lastWeek: 5),
                 StandbyAccount(email: pat.email!, seat: pat, id: "kpat", lastInUse: t0, lastWeek: 40)]
    put(expand(e.configDir) + "/.claude.json",
        #"{"oauthAccount":{"accountUuid":"\#(mo.account)","organizationUuid":"\#(mo.organization!)","emailAddress":"\#(mo.email!)"}}"#)
    try! Store.save([e])
    try? fm.removeItem(at: Store.statusFolder.appendingPathComponent("qa.json"))
    check(AccountBook.best(e.standby)?.id == "kmo", "the raw list's pick is mo, the account in use (what the alert used to offer)")

    // the full-limit alert's offer: never the account in use, though no record was saved yet (the reader's own answer)
    // the poster runs on a background queue: its list behind a lock, and waits that end when it says so (or after 5 s)
    let postLock = NSLock()
    var postList: [(title: String, key: String?)] = []
    var posts: [(title: String, key: String?)] { postLock.lock(); defer { postLock.unlock() }; return postList }
    func clearPosts() { postLock.lock(); postList.removeAll(); postLock.unlock() }
    func waitFor(_ done: () -> Bool, seconds: TimeInterval = 5) {
        let until = Date().addingTimeInterval(seconds)
        while !done() && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    UsageReader.testPoster = { _, title, _, _, key in postLock.lock(); postList.append((title, key)); postLock.unlock(); return 0 }
    let r = UsageReader(e, defaults: UserDefaults(suiteName: "cl-audit-surfaces-offer-\(getpid())")!)
    r.finish(data: fullWeek, response: ok200, error: nil, asked: Date(), gen: r.generation)
    waitFor { posts.contains { $0.title.contains("full") } && Store.status("qa") != nil }
    let fullPost = posts.first { $0.title.contains("full") }
    check(fullPost?.key == AccountEntry.switchKey("qa", "kpat"),
          "the full alert offers pat, never mo (in use): \(fullPost.map { "\($0.title) → \($0.key ?? "none")" } ?? "no full alert")")
    // quick chat and the alert make the one offer (the record is saved by now)
    check(QuickChatSwitchOffer.best(e)?.key == AccountEntry.switchKey("qa", "kpat") && e.fullOffer()?.key == fullPost?.key,
          "quick chat's offer is the alert's: \(QuickChatSwitchOffer.best(e)?.key ?? "none")")
    var onlyMo = e; onlyMo.standby = [e.standby[0]]
    check(onlyMo.fullOffer() == nil && QuickChatSwitchOffer.best(onlyMo) == nil, "only the account in use on standby: no offer anywhere")
    var byAddress = e; byAddress.standby = [StandbyAccount(email: "lee@example.com", id: "klee")]
    check(byAddress.fullOffer() == nil, "an account remembered by its address only is never offered")
    r.stop()

    // the alerts act only on numbers that may act (the Headline): a reading confirmed 10 minutes after it was read (its
    // account looked up late) is only last known; its alerts wait for the next read
    clearPosts()
    let r2 = UsageReader(e, defaults: UserDefaults(suiteName: "cl-audit-surfaces-agealert-\(getpid())")!)
    let now = Date()
    var oldRead = Usage(fetchedAt: now.addingTimeInterval(-10 * 60), source: "Anthropic")
    oldRead.weekly = 100; oldRead.weeklyResets = now.addingTimeInterval(86400); oldRead.noFiveHour = true
    r2.apply(oldRead, now: now)
    waitFor({ !posts.isEmpty }, seconds: 1)
    check(posts.isEmpty, "a reading 10 minutes old: no full, level or credits alert, no offer: \(posts.map(\.title))")
    var freshRead = oldRead; freshRead.fetchedAt = now.addingTimeInterval(-60)
    r2.apply(freshRead, now: now)
    waitFor { posts.contains { $0.title.contains("full") } }
    check(posts.contains { $0.title.contains("full") }, "a minute old: the full alert goes, as before: \(posts.map(\.title))")
    r2.stop()
    UsageReader.testPoster = nil

    // quick chat's live numbers count only while the Headline says the record's are the profile's
    func rec(_ resolved: ResolvedAccount?, unconfirmed: Bool = false) -> IconStatus {
        var s = IconStatus(state: "ok"); s.loginEmail = mo.email; s.numbersOwner = mo.email; s.weekly = 30
        s.weeklyResets = now.addingTimeInterval(2 * 86400); s.noFiveHour = true; s.updatedAt = now; s.resolved = resolved
        s.ownerUnconfirmed = unconfirmed ? true : nil
        return s
    }
    let own = AccountResolver.resolve(e, among: [e], app: .unknown, code: mo, loginEmail: mo.email, names: [:], now: now)
    _ = Store.writeStatus("qa", rec(own))
    check(QuickChatTarget(e, now: now).liveCounts, "the profile's own numbers: Claude Code's live ones after an answer count")
    _ = Store.writeStatus("qa", rec(own, unconfirmed: true))
    check(!QuickChatTarget(e, now: now).liveCounts, "numbers whose account isn't confirmed: the live ones don't count (never full from them)")
    var moved = own; moved.readStale = true
    _ = Store.writeStatus("qa", rec(moved))
    check(!QuickChatTarget(e, now: now).liveCounts, "a reading the sign-in moved on from: the live ones don't count")
    var inSplit = own; inSplit.fromApp = true; inSplit.account = pat.account.lowercased(); inSplit.email = pat.email; inSplit.differs = true
    _ = Store.writeStatus("qa", rec(inSplit))
    check(Headline.split(Store.status("qa")!.owner) != nil && !QuickChatTarget(e, now: now).liveCounts,
          "the split: Claude Code's live limits aren't the profile's")
    check(QuickChatTarget(e, now: now).split, "...and the target knows it is the split")
    var clashed = own; clashed.clash = "Home"
    _ = Store.writeStatus("qa", rec(clashed))
    check(!QuickChatTarget(e, now: now).liveCounts && !QuickChatTarget(e, now: now).split,
          "a clash (the folder on another profile's account in use): the live ones are that profile's, not this one's")
    var signedOut = rec(own); signedOut.state = "noLogin"
    _ = Store.writeStatus("qa", signedOut)
    check(!QuickChatTarget(e, now: now).liveCounts, "signed out: the live ones don't count")
    try? fm.removeItem(at: Store.statusFolder.appendingPathComponent("qa.json"))
    check(!QuickChatTarget(e, now: now).liveCounts, "no record yet: the live ones don't count")

    // the merge itself: the record's level alone unless the live numbers count, for the same account
    var record = QuickChatLevel(nil); record.noFiveHour = true                  // the record shows no numbers
    var live = QuickChatLevel(nil); live.week = 100; live.weekResets = now.addingTimeInterval(86400); live.refusedUntil = now.addingTimeInterval(600)
    let notCounted = QuickChatLevel.kept(record: record, shown: live, sameAccount: true, counts: false, refusals: false, now: now)
    check(notCounted?.week == nil && notCounted?.refusedUntil == nil && notCounted?.full(now) == nil,
          "the split: live numbers never bring back numbers the record doesn't show (the old merge did), nor a refusal")
    let refusalOnly = QuickChatLevel.kept(record: record, shown: live, sameAccount: true, counts: false, refusals: true, now: now)
    check(refusalOnly?.week == nil && refusalOnly?.refusedUntil != nil && refusalOnly?.full(now) != nil,
          "numbers that don't count yet (no record, not confirmed): no live percent, but Claude Code's refusal still holds the bar")
    check(QuickChatLevel.kept(record: record, shown: live, sameAccount: false, counts: true, refusals: true, now: now)?.week == nil,
          "another account since: the record's level alone")
    let counted = QuickChatLevel.kept(record: record, shown: live, sameAccount: true, counts: true, refusals: true, now: now)
    check(counted?.week == 100 && counted?.refusedUntil != nil && counted?.full(now) != nil, "counted, same account: Claude Code's fuller week stays")
    var lower = QuickChatLevel(nil); lower.week = 20; lower.weekResets = now.addingTimeInterval(86400)
    var higher = lower; higher.week = 60
    check(QuickChatLevel.kept(record: higher, shown: lower, sameAccount: true, counts: true, refusals: true, now: now)?.week == 60,
          "the record's fuller reading wins")
    var beforeReset = live; beforeReset.weekResets = now.addingTimeInterval(-60)
    check(QuickChatLevel.kept(record: record, shown: beforeReset, sameAccount: true, counts: true, refusals: true, now: now)?.week == nil,
          "a live percent from before its reset is never kept")

    // Claude Code's own limit event when its numbers don't count: the refusal and its real reset, never the percent
    var event = QuickChatLevel(nil); event.noFiveHour = false
    let soon = now.addingTimeInterval(8 * 60)
    event.apply(type: "five_hour", used: 1, status: "rejected", resets: soon, counts: false)
    check(event.fiveHour == nil && event.refusedUntil == soon && event.full(now)?.resets == soon,
          "a refusal while the numbers don't count: held until its own reset (8 minutes), no percent")
    event.apply(type: "five_hour", used: 0.2, status: "allowed", resets: soon, counts: false)
    check(event.refusedUntil == nil && event.fiveHour == nil, "allowed again: the hold goes")
    event.apply(type: "five_hour", used: 0.42, status: "allowed", resets: soon, counts: true)
    check(event.fiveHour == 42 && event.fiveHourResets == soon, "numbers that count: the percent and its reset, as before")

    // the model: a refusal holds the bar whatever the record says; the offer comes only from numbers that count
    let model = QuickChatModel()
    var t = QuickChatTarget(e, now: now); t.liveCounts = false; t.split = false
    model.target = t
    var refused = QuickChatLevel(nil); refused.refusedUntil = now.addingTimeInterval(600)
    model.level = refused
    let offered = QuickChatSwitchOffer(key: "qa~kpat", short: "pat", words: "")
    model.update(target: t, level: QuickChatLevel(nil), offer: { offered })
    check(model.blocked && model.offer == nil, "a refusal before the numbers count: the bar holds, but no offer (it could name the account in use)")
    var counting = t; counting.liveCounts = true
    model.update(target: counting, level: QuickChatLevel(nil), offer: { offered })
    check(model.blocked && model.offer == offered, "numbers that count: the bar holds and offers the switch")
    var inTheSplit = t; inTheSplit.split = true
    model.update(target: inTheSplit, level: QuickChatLevel(nil), offer: { offered })
    check(!model.blocked && model.offer == nil, "the split: Claude Code's refusal is its account's, never the profile's limit")
}

// ============ 11. ClaudeFiles: the one reader of .claude.json's account, the one lister of the window's sessions ============
do {
    let dir = home + "/cf"
    try? fm.removeItem(atPath: dir)
    // the record: field by field, a guess; read again when the file changed; through a link named by the path; never a FIFO
    let rec = dir + "/code/.claude.json"
    put(rec, #"{"oauthAccount":{"accountUuid":"\#(u1.account)","organizationUuid":"\#(u1.organization!)","emailAddress":"\#(u1.email!)","organizationType":"claude_max","organizationName":"x","planDisplayName":"Ultra"},"projects":{}}"#)
    let r = ClaudeFiles.record(at: rec)
    check(r?.seat == Seat(account: u1.account, organization: u1.organization, email: u1.email) && r?.plan == "Ultra" && r?.organizationType == "claude_max"
          && r?.identity == AccountIdentity(account: u1.account, email: u1.email, organization: u1.organization, source: .guessed),
          "the record: its seat, plan and fields, and the identity guessed from the file")
    check(ClaudeFiles.identity(folder: dir + "/code", isDefault: false) == r?.identity
          && ClaudeFiles.recordPath(folder: dir + "/code", isDefault: true, home: "/h") == "/h/.claude.json",
          "a folder in, its identity out; the default folder's record is in the home folder")
    put(rec, #"{"oauthAccount":{"accountUuid":"\#(u2.account)","emailAddress":"\#(u2.email!)","planDisplayName":"  "}}"#)
    let again = ClaudeFiles.record(at: rec)
    check(again?.seat?.account == u2.account && again?.plan == nil && again?.planDisplayName == "  ", "read again once the file changed; a blank plan is none (the field kept as written)")
    try? fm.createDirectory(atPath: dir + "/linked", withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: dir + "/linked/.claude.json", withDestinationPath: rec)
    check(ClaudeFiles.record(at: dir + "/linked/.claude.json")?.seat?.account == u2.account, "a .claude.json that is a link to the real one: read")
    try? fm.createDirectory(atPath: dir + "/fifo", withIntermediateDirectories: true)
    mkfifo(dir + "/fifo/.claude.json", 0o600)
    let tf = Date()
    check(ClaudeFiles.record(at: dir + "/fifo/.claude.json") == nil && Date().timeIntervalSince(tf) < 2, "a FIFO named like it: nothing, at once")
    put(dir + "/none/.claude.json", #"{"projects":{}}"#)
    check(ClaudeFiles.record(at: dir + "/none/.claude.json") == nil, "no oauthAccount block: no record")
    put(dir + "/big/.claude.json", "{}")
    if let h = FileHandle(forWritingAtPath: dir + "/big/.claude.json") { try? h.truncate(atOffset: UInt64(ClaudeFiles.recordMax + 1)); try? h.close() }
    check(ClaudeFiles.tooLarge(dir + "/big/.claude.json") && ClaudeFiles.record(at: dir + "/big/.claude.json") == nil, "larger than recordMax: too large, not read")
    try? fm.removeItem(atPath: dir + "/big")

    // the sessions: account and organisation folders named like a UUID and real (no link), entries local_<UUID>.json and regular
    let data = dir + "/window", cs = dir + "/window/claude-code-sessions"
    let a = uuid(11), o = uuid(12).uppercased(), o2 = uuid(13)
    let odir = cs + "/\(a)/\(o)"
    put(odir + "/local_\(uuid(21)).json", "{}")
    put(odir + "/local_\(uuid(22).uppercased()).json", #"{"isArchived":true}"#)
    put(odir + "/local_notes.json", "{}")
    put(odir + "/scheduled-tasks.json", #"{"scheduledTasks":[]}"#)
    try? fm.createSymbolicLink(atPath: odir + "/local_\(uuid(23)).json", withDestinationPath: odir + "/local_\(uuid(21)).json")
    put(cs + "/\(a)/not-an-org/local_\(uuid(24)).json", "{}")
    put(dir + "/elsewhere/local_\(uuid(25)).json", "{}")
    try? fm.createSymbolicLink(atPath: cs + "/\(a)/\(o2)", withDestinationPath: dir + "/elsewhere")
    let scopes = ClaudeFiles.sessionScopes(dataDir: data)
    check(scopes.map(\.organization) == [o] && scopes.first?.account == a,
          "folders: UUID-named real folders only, names as on disk (a linked one and one not named like a UUID aren't): \(scopes.map(\.organization))")
    let names = ClaudeFiles.sessionEntries(in: odir).map(\.name)
    let want = ["local_\(uuid(21)).json", "local_\(uuid(22).uppercased()).json"].sorted()
    check(names == want, "entries: local_<UUID>.json regular files only (no link, no other name), case as on disk: \(names)")
    check(ClaudeFiles.sessionScopes(dataDir: data, account: a).count == 1 && ClaudeFiles.sessionScopes(dataDir: data, account: uuid(99)).isEmpty
          && ClaudeFiles.sessionScopes(dataDir: data, limit: 1).isEmpty, "one account's folders; at most `limit` names looked at in each folder")
    check(AppSignIn.sessionsOrg(dataDir: data, account: a) == o.lowercased(), "the Claude app's organisation from the sessions folder: the newest, lower case")
    // the listers that use it agree
    check(DefaultProfile.entryNames(data).keys.sorted() == want.map { $0.lowercased() }.sorted(), "the default move's preview: the same entries, keyed lower case")
    let counts = SidebarCounts.read(dataDir: data, account: a)
    check(counts?.sessions == 1 && counts?.archived == 1, "the Switch page's counts: the same entries (one archived)")
    let now = SessionsRestore.WindowNow.read(data)
    check(Set(now.entries.keys) == Set(want.map { $0.lowercased() }) && now.hasTasks == [SeatID(account: a, organization: o)],
          "restore's view of the window: the same entries, and its task list")

    // the Claude app's config.json and main.log (AppSignIn)
    put(data + "/config.json", #"{"lastKnownAccountUuid":"\#(u1.account.uppercased())","oauth:tokenCache":"x"}"#)
    check(AppSignIn.config(dataDir: data)?.id == u1.account && AppSignIn.storedSignIn(dataDir: data) == .account(u1.account),
          "config.json: the account (lower case), and a sign-in kept (the token cache key's name only)")
    put(data + "/config.json", #"{"lastKnownAccountUuid":"\#(u1.account)"}"#)
    check(AppSignIn.storedSignIn(dataDir: data) == .none, "…no token cache key: no sign-in kept")
    put(data + "/config.json", #"{"lastKnownAccountUuid":"not-an-id","oauth:tokenCache":"x"}"#)
    check(AppSignIn.storedSignIn(dataDir: data) == .unknown && AppSignIn.config(dataDir: data) == nil, "…an id that isn't one: can't be told (New account says unknown, not signed out)")
    put(data + "/config.json", #"{"oauth:tokenCache":"x","pad":""# + String(repeating: "x", count: AppSignIn.configBytes) + #"","lastKnownAccountUuid":"\#(u1.account)"}"#)
    check(AppSignIn.storedSignIn(dataDir: data) == .unknown, "…larger than its cap: can't be told")
    try? fm.removeItem(atPath: data + "/config.json")
    check(AppSignIn.storedSignIn(dataDir: data) == .none, "…no config.json: no sign-in kept")

    // the export's leak check takes every id-named name in the sessions folder (more than the lister, never less), and a record
    // too large to read is noted, so the export refuses
    put(cs + "/\(uuid(31))/.keep", "")
    var known = Identities()
    known.add(windowDir: data)
    check(known.ids.isSuperset(of: [a, o, o2, uuid(31)].map { $0.lowercased() }),
          "the leak check's ids: an account folder with no organisation and a linked organisation folder included")
    put(dir + "/huge/.claude.json", "{}")
    if let h = FileHandle(forWritingAtPath: dir + "/huge/.claude.json") { try? h.truncate(atOffset: UInt64(ClaudeFiles.recordMax + 1)); try? h.close() }
    known.add(claudeJSON: dir + "/huge/.claude.json")
    check(known.unread == [dir + "/huge/.claude.json"], "a record too large to read: noted for the export to refuse, not skipped")
    try? fm.removeItem(atPath: dir + "/huge")
    let logs = URL(fileURLWithPath: dir + "/logs")
    put(logs.path + "/main.log", "2026-11-15 10:00:00.123 [info] [stealth-update] Triggering stealth update\n2026-11-15 10:00:05.000 [info] other\n")
    check(AppSignIn.lastStealthUpdate(logs: logs) == AppSignIn.timeFormatShort.date(from: "2026-11-15 10:00:00"), "main.log: the last stealth update, to the second")

    // both readers are app-neutral: Foundation and ProfileCore only, no app type, no log or print
    let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    for f in ["ClaudeFiles.swift", "AppSignIn.swift"] {
        let t = (try? String(contentsOf: src.appendingPathComponent(f), encoding: .utf8)) ?? ""
        let imports = t.components(separatedBy: "\n").filter { $0.hasPrefix("import ") }
        let app = ["AccountEntry", "Account(", "FolderKey", "expand(", "tilde(", "Store.", "NSWorkspace", "NSRunningApplication", "AccountDiscovery",
                   "Processes.", "print(", "NSLog", "os_log", "Logger"].filter { t.contains($0) }
        check(!t.isEmpty && Set(imports).isSubset(of: ["import Foundation", "import ProfileCore"]) && app.isEmpty, "\(f): app-neutral (imports \(imports), app names \(app))")
    }
}

// ============ 12. ProfileCore step 3b: the dashboard card (and the palette's row) draw the one value ============
do {
    let now = Date()
    var e = profile("card", "~/.claude-card", u1); e.claudeWindow = false
    e.standby = [StandbyAccount(email: u2.email!, seat: u2, id: "k2", plan: "Max", lastInUse: now.addingTimeInterval(-86400))]
    try! Store.save([e, other])
    func rec(_ state: String = "ok", week: Double? = 40, five: Double? = 12, age: TimeInterval = 60, weekIn: TimeInterval = 2 * 86400,
             login: String? = u1.email, code: Seat? = u1) -> IconStatus {
        // (the folder's .claude.json names Claude Code's account: another profile's in a clash)
        var s = IconStatus(state: state); s.loginEmail = state == "noLogin" ? nil : login; s.expectedEmail = code?.email
        s.weekly = week; s.fiveHour = five; s.weeklyResets = now.addingTimeInterval(weekIn); s.fiveHourResets = now.addingTimeInterval(3600)
        s.updatedAt = now.addingTimeInterval(-age); s.source = "Anthropic"; s.plan = "Max"
        s.resolved = AccountResolver.resolve(e, among: [e, other], app: .unknown, code: code, loginEmail: login, names: [:], now: now)
        return s
    }
    /// The card's row for a record of profile `p` (default the card's), checked against the value it draws: the lamp, the
    /// line, what is full, the tile's grey and warning, the numbers (each state below says its notice and key itself).
    func card(_ r: IconStatus?, _ p: AccountEntry? = nil, _ what: String) -> (row: AccountRow, notice: UsageNotice?, terminalInRow: Bool) {
        let p = p ?? e
        if let r { _ = Store.writeStatus(p.id, r) } else { Store.removeStatus(p.id) }
        let row = cardRow(p, now: now), d = row.show.display
        check(row.lit == d.lamp && row.line == row.show.lineWords(short: false) && row.full == d.full(now: Date())
              && row.tile.stale == d.grey && row.tile.warn == d.otherAccount && (row.tile.countdown == nil) == (row.full == nil)
              && row.fiveHour == d.usage?.fiveHour && row.weekly == d.usage?.weekly,
              "\(what): the card draws the value (lamp, line, full, grey, warning, numbers)")
        let acts = LauncherActions(open: { _ in }, terminal: { _ in }, logIn: { _ in }, mainScreen: {}, settings: {})
        return (row, UsageNotice.of(row), AccountCard(row: row, actions: acts).terminalInRow)
    }

    // the tiers: fresh; last known at 10 minutes (a full week left out); grey past three missed reads (30 minutes at the
    // usual read interval), where the card's own rule greyed only after an hour
    let fresh = card(rec(), nil, "fresh")
    check(fresh.notice == nil && fresh.row.lit && !fresh.row.tile.stale && fresh.row.limits.first { $0.id == "wk" }?.p == 40
          && fresh.row.line == nil && fresh.row.subtitle == u1.email, "fresh: the numbers, lit, not grey, no notice")
    let known = card(rec(week: 100, age: 10 * 60, weekIn: 3 * 3600), nil, "last known")
    check(known.row.full == nil && known.row.tile.countdown == nil && !known.row.tile.stale && known.row.weekly == nil
          && known.row.fiveHour == 12 && known.notice == nil, "10 minutes old: last known, the full week left out, no countdown, not grey, no key")
    let grey = card(rec(age: 40 * 60), nil, "40 minutes old")
    check(grey.row.tile.stale && grey.row.weekly == 40 && grey.notice == nil, "40 minutes old: the card's tile greys (as the Dock icon), the numbers still drawn")
    check(card(rec(age: 61 * 60), nil, "an hour old").row.tile.stale, "61 minutes old: grey")
    var slow = e; slow.pollMinutes = 20
    check(!card(rec(age: 40 * 60), slow, "a 20-minute read interval").row.tile.stale, "a 20-minute read interval: 40 minutes old isn't grey yet")
    try! Store.save([e, other])
    // full and fresh: the full box and the countdown on the tile
    let full = card(rec(week: 100, weekIn: 3 * 3600), nil, "full")
    check(full.row.full?.kind == .week && full.row.tile.countdown != nil && full.notice == nil, "a fresh full week: full, the countdown, Switch account (no notice)")
    // a reset that has passed: no percent, nothing full
    let past = card(rec(week: 100, weekIn: -60), nil, "a passed reset")
    check(past.row.weekly == nil && past.row.full == nil && past.row.fiveHour == 12 && past.notice == nil,
          "the week's reset passed: no week, nothing full, no key")

    // the sign-in: not readable (the numbers as read, the lamp off; the amber notice only without numbers), expired and
    // signed out (red, Sign in…, no numbers, grey), on another account (the warning dot, red, Sign in…)
    for (state, heading) in [("denied", "Can't read Terminal's sign-in yet"), ("unreadable", "Can't read Terminal's sign-in")] {
        let withNumbers = card(rec(state), nil, "\(state), numbers")
        check(withNumbers.notice == nil && withNumbers.row.weekly == 40 && !withNumbers.row.lit, "\(state) with numbers: as read, no notice, the lamp off")
        let without = card(rec(state, week: nil, five: nil), nil, "\(state), none")
        check(without.notice?.heading == heading && without.notice?.tone == .amber && without.notice?.key == .refresh && !without.row.lit,
              "\(state) without numbers: the amber notice, Refresh now, the lamp off")
    }
    for (state, heading) in [("expired", "Terminal's sign-in has expired"), ("noLogin", "Terminal is signed out")] {
        let c = card(rec(state), nil, state)
        check(c.notice?.heading == heading && c.notice?.tone == .red && c.notice?.key == .signIn && c.notice?.signedOut == true
              && c.notice?.line == "Sign in as \(Privacy.masked(u1.email!)) to read Card's usage." && c.row.limits.allSatisfy { $0.p == nil }
              && c.row.tile.stale && !c.row.lit && c.row.needsLogin, "\(state): red, Sign in… to the folder's address, no numbers, grey, the lamp off")
    }
    let mixed = card(rec(login: u2.email, code: u1), nil, "another account")
    check(mixed.notice?.heading == "Terminal is signed in to another account" && mixed.notice?.key == .signIn && mixed.row.tile.warn
          && !mixed.row.lit && mixed.row.subtitle == "sign-in is a different account", "the sign-in on another account than the folder's: red, Sign in…, the warning, the lamp off")

    // another profile's account: by its id, and by its name in a record from before the id; the profile renamed since.
    // The folder's .claude.json names Other's account (u3): the key signs Terminal in to Card's own (u1), never Other's
    let ownLine = "Sign in as \(Privacy.masked(u1.email!)) to read Card's usage."
    let clash = card(rec(login: u3.email, code: u3), nil, "clash by id")
    check(clash.row.display.clash == ProfileDisplay.Clash(id: "other", name: "Other") && clash.notice?.heading == "Terminal is signed in to Other's account"
          && clash.notice?.key == .signIn && clash.row.display.key == .logIn && clash.notice?.line == ownLine
          && clash.row.show.loginAddress == u1.email && clash.row.status?.expectedEmail == u3.email && !clash.row.lit,
          "Claude Code on Other's account (by id): red, Sign in… as Card's own u1 (never Other's u3), the lamp off: \(clash.notice?.line ?? "-")")
    // a clash has no numbers (the Reader drops a clash record's): the Dock panel's age line says there are none, never
    // "Reading usage…" (they aren't on their way)
    let clashNone = card(rec(week: nil, five: nil, login: u3.email, code: u3), nil, "clash, no numbers")
    let clashPanel = DetailsInfo.of(clashNone.row.show, name: e.name, icon: NSImage(), problem: nil)
    check(clashNone.row.show.display.usage == nil && clashPanel.noNumbers == "No usage: Terminal is on Other's account",
          "a clash with no numbers: the Dock panel's age line says no usage here and whose account, never Reading usage…: \(clashPanel.noNumbers ?? "-")")
    // quick chat in a clash: its header names the profile's own account (u1), never the folder's (u3); its `claude` process,
    // the kept level's account and the switch wait follow the folder's u3 (by its id and organisation), so moving back, which
    // changes it, replaces the process
    func qkey(_ t: QuickChatTarget) -> QuickChatProcessKey { t.processKey(claude: "/c", model: "m", effort: nil) }
    let clashChat = QuickChatTarget(e, now: now)
    check(clashChat.clash && clashChat.email == u3.email && clashChat.shownEmail == u1.email
          && clashChat.account?.account == u3.account.lowercased() && clashChat.account?.organization == u3.organization?.lowercased(),
          "a clash: quick chat's header names the profile's own u1, its process the folder's u3 (id and organisation): \(clashChat.shownEmail ?? "-") / \(clashChat.email ?? "-")")
    var seatless = e; seatless.seat = nil
    let noSeatChat = QuickChatTarget(seatless, now: now)
    check(noSeatChat.clash && noSeatChat.shownEmail == nil && noSeatChat.email == u3.email,
          "a clash with no own account known: the header names no address, never the folder's u3: \(noSeatChat.shownEmail ?? "none")")
    _ = Store.writeStatus(e.id, rec())
    let backChat = QuickChatTarget(e, now: now)
    check(backChat.email == u1.email && backChat.shownEmail == u1.email && !backChat.clash && !qkey(backChat).keeps(qkey(clashChat)),
          "moved back to the profile's own account: quick chat's process key changes, so the open process is replaced")
    // the same when the Claude app decided the account in use: the app on the profile's own u1, the folder on Other's u3.
    // The header names u1, the process runs on the folder's u3 (its key, the kept level's account, the switch wait); moving
    // the folder back to u1 changes the key. The split (the app on u2, the folder on u1), unchanged: the header and the
    // process on u1; Claude Code signing in to u2 changes the key
    var win = e; win.claudeWindow = true
    func appRec(_ app: AppSignIn.Login, code: Seat) -> IconStatus {
        var s = rec(week: nil, five: nil, login: code.email, code: code)
        s.resolved = AccountResolver.resolve(win, among: [win, other], app: app, code: code, loginEmail: code.email, names: [:], now: now)
        return s
    }
    _ = Store.writeStatus(e.id, appRec(appU1, code: u3))
    let qcAppClash = QuickChatTarget(win, now: now)
    check(Store.status(e.id)?.resolved?.fromApp == true && Store.status(e.id)?.resolved?.clash == "Other"
          && qcAppClash.clash && qcAppClash.email == u3.email && qcAppClash.shownEmail == u1.email,
          "an app-decided clash: quick chat's header on the app's u1 (the profile's own), its process on the folder's u3: \(qcAppClash.shownEmail ?? "-") / \(qcAppClash.email ?? "-")")
    _ = Store.writeStatus(e.id, appRec(appU1, code: u1))
    let appBackChat = QuickChatTarget(win, now: now)
    check(appBackChat.email == u1.email && appBackChat.shownEmail == u1.email && !appBackChat.clash
          && !qkey(appBackChat).keeps(qkey(qcAppClash)) && !QuickChatTarget.sameAccount(appBackChat.account, qcAppClash.account),
          "an app-decided clash moved back to u1: the process key changes (the old process on u3 isn't kept, nor its refusals) and the switch wait sees the move")
    _ = Store.writeStatus(e.id, appRec(appU2, code: u1))
    let splitChat = QuickChatTarget(win, now: now)
    check(splitChat.split && !splitChat.clash && splitChat.email == u1.email && splitChat.shownEmail == u1.email,
          "the split, unchanged: quick chat's header and process on Claude Code's own u1, never the app's u2: \(splitChat.shownEmail ?? "-")")
    _ = Store.writeStatus(e.id, appRec(appU2, code: u2))
    let splitDone = QuickChatTarget(win, now: now)
    check(!splitDone.split && splitDone.email == u2.email && !qkey(splitDone).keeps(qkey(splitChat)),
          "the split ended, Claude Code signed in to the app's u2: the process key changes")

    // the key by the folder's seat: its address in capitals, readings alternating between the status line (no address of
    // its own) and the endpoint, and a record with no seat (its address only) are one account; one login's Team seat (u1's
    // id in another organisation) is another
    _ = Store.writeStatus(e.id, rec())
    let base = QuickChatTarget(e, now: now)
    check(Store.status(e.id)?.resolved?.codeOrganization == u1.organization?.lowercased() && base.account?.organization == u1.organization?.lowercased(),
          "the record keeps the folder account's organisation beside its id, and quick chat's key takes it")
    let caps = Seat(account: u1.account.uppercased(), organization: u1.organization?.uppercased(), email: u1.email!.uppercased())
    _ = Store.writeStatus(e.id, rec(login: caps.email, code: caps))
    let loud = QuickChatTarget(e, now: now)
    check(loud.email == caps.email && qkey(loud).keeps(qkey(base)) && qkey(base).keeps(qkey(loud)),
          "the folder's address, id and organisation in capitals: the same seat, the process kept")
    _ = Store.writeStatus(e.id, rec(login: nil, code: u1))
    let viaLine = QuickChatTarget(e, now: now)
    _ = Store.writeStatus(e.id, rec(login: u1.email!.uppercased(), code: u1))
    let viaEndpoint = QuickChatTarget(e, now: now)
    check(viaLine.email != viaEndpoint.email && qkey(viaLine).keeps(qkey(viaEndpoint)) && qkey(viaEndpoint).keeps(qkey(viaLine)),
          "the status line, then the endpoint (its address in another case), then the status line: the process kept: \(viaLine.email ?? "-") / \(viaEndpoint.email ?? "-")")
    _ = Store.writeStatus(e.id, rec(login: u1.email!.uppercased(), code: nil))
    let noSeatRec = QuickChatTarget(e, now: now)
    check(noSeatRec.account?.account == nil && noSeatRec.account?.organization == nil && qkey(noSeatRec).keeps(qkey(base)),
          "a record with no seat (its address only): matched by the address, any case: the process kept")
    // a record from before codeOrganization (the gap before the agent's first write after an update): the organisation
    // isn't known there, so it is left out of the comparison: the same key, no restart, and no "switched to" the same account
    var noOrg = rec(); noOrg.resolved?.codeOrganization = nil
    _ = Store.writeStatus(e.id, noOrg)
    let oldRec = QuickChatTarget(e, now: now)
    check(oldRec.account?.organization == nil && qkey(oldRec).keeps(qkey(base)) && qkey(base).keeps(qkey(oldRec))
          && QuickChatTarget.sameAccount(oldRec.account, base.account),
          "a record with no organisation for the folder's account: the same seat as with it, the process kept")
    let team = Seat(account: u1.account, organization: uuid(301), email: u1.email)
    _ = Store.writeStatus(e.id, rec(code: team))
    let teamChat = QuickChatTarget(e, now: now)
    check(teamChat.email == base.email && !qkey(teamChat).keeps(qkey(base)) && !QuickChatTarget.sameAccount(teamChat.account, base.account),
          "one login's personal and Team seats: two keys, the process replaced")
    // the organisation in three states: an id, none ("": the folder's record names the seat with no organisation) and not
    // known (nil: a record from before codeOrganization). A seat with none and the same login's Team seat are two keys both
    // ways; none and none one (an empty organisation as none, any case); an id and another id two; not known with either one
    let bare = Seat(account: u1.account, organization: nil, email: u1.email)
    _ = Store.writeStatus(e.id, rec(code: bare))
    let bareChat = QuickChatTarget(e, now: now)
    check(Store.status(e.id)?.resolved?.codeOrganization == "" && bareChat.account?.organization == "" && bareChat.account?.account == u1.account.lowercased(),
          "a seat its record names with no organisation: the record keeps \"\" (none, known), quick chat's key takes it: \(Store.status(e.id)?.resolved?.codeOrganization ?? "nil")")
    check(!qkey(bareChat).keeps(qkey(teamChat)) && !qkey(teamChat).keeps(qkey(bareChat))
          && !QuickChatTarget.sameAccount(bareChat.account, teamChat.account) && !QuickChatTarget.sameAccount(teamChat.account, bareChat.account),
          "one login's seat with no organisation and its Team seat: two keys both ways, the process replaced")
    let emptyOrg = Seat(account: u1.account.uppercased(), organization: "", email: u1.email!.uppercased())
    _ = Store.writeStatus(e.id, rec(login: emptyOrg.email, code: emptyOrg))
    let emptyChat = QuickChatTarget(e, now: now)
    check(emptyChat.account?.organization == "" && qkey(emptyChat).keeps(qkey(bareChat)) && qkey(bareChat).keeps(qkey(emptyChat))
          && QuickChatTarget.sameAccount(emptyChat.account, bareChat.account),
          "no organisation and an empty one (the id and address in capitals): one seat, the process kept")
    check(qkey(oldRec).keeps(qkey(bareChat)) && qkey(bareChat).keeps(qkey(oldRec)) && qkey(oldRec).keeps(qkey(teamChat)) && qkey(teamChat).keeps(qkey(oldRec))
          && QuickChatTarget.sameAccount(oldRec.account, bareChat.account) && QuickChatTarget.sameAccount(teamChat.account, oldRec.account),
          "a record from before codeOrganization with a seat of none or a Team seat: one seat, as before")
    check(!qkey(teamChat).keeps(qkey(base)) && !qkey(base).keeps(qkey(teamChat)), "two organisation ids: two keys both ways")
    // the status record's bytes keep none ("") apart from not known (nil: the key left out)
    let noneRec = rec(code: bare)
    let noneBytes = StatusCodec.encode(noneRec)
    var unknownRec = noneRec; unknownRec.resolved?.codeOrganization = nil
    let unknownBytes = StatusCodec.encode(unknownRec)
    check(noneBytes.flatMap(StatusCodec.decode)?.resolved?.codeOrganization == ""
          && unknownBytes.flatMap(StatusCodec.decode).map { $0.resolved != nil && $0.resolved?.codeOrganization == nil } == true
          && unknownBytes.map { !String(decoding: $0, as: UTF8.self).contains("codeOrganization") } == true,
          "the status JSON round trip: none stays \"\", not known stays nil (no key)")
    // the resolver over the folder's own .claude.json: no organizationUuid, null and "" are none (""), an id is that id
    // (lower case), no record is not known (nil)
    func orgFromFile(_ name: String, _ org: String) -> String? {
        let path = expand("~/.claude-orgs/\(name).json")
        put(path, #"{"oauthAccount":{"accountUuid":"\#(u1.account)",\#(org)"emailAddress":"\#(u1.email!)"}}"#)
        let seat = ClaudeFiles.record(at: path)?.seat
        return AccountResolver.resolve(e, among: [e, other], app: .unknown, code: seat, loginEmail: u1.email, names: [:], now: now).codeOrganization
    }
    let fromAbsent = orgFromFile("absent", ""), fromNull = orgFromFile("null", #""organizationUuid":null,"#)
    let fromEmpty = orgFromFile("empty", #""organizationUuid":"","#)
    let fromID = orgFromFile("id", #""organizationUuid":"\#(uuid(301).uppercased())","#)
    let fromNone = AccountResolver.resolve(e, among: [e, other], app: .unknown, code: ClaudeFiles.record(at: expand("~/.claude-orgs/missing.json"))?.seat,
                                           loginEmail: u1.email, names: [:], now: now).codeOrganization
    check(fromAbsent == "" && fromNull == "" && fromEmpty == "" && fromID == uuid(301).lowercased() && fromNone == nil,
          "the resolver over .claude.json: absent, null and \"\" are none, an id is the id, no record not known: \([fromAbsent, fromNull, fromEmpty, fromID, fromNone].map { $0.map { "\"\($0)\"" } ?? "nil" })")

    // the model, as the agent drives it (update) and as Claude Code's events reach it (handle). In a clash, Other's limit
    // event and refusal never mark the header's account full or hold typing, and the bubble names no account as full;
    // outside a clash they do (and the bubble says this account's week); in the split, the bubble as in a clash
    let soon = now.addingTimeInterval(3600)
    var filled = 0
    func chat(_ t: QuickChatTarget, level: QuickChatLevel?) -> QuickChatModel {
        let m = QuickChatModel(); m.resolveClaude = { _ in }; m.limitFilled = { filled += 1 }
        m.update(target: t, level: level, offer: { nil })
        // (as `ask` records it: what the turn is asked on)
        m.turns = [QuickChatTurn(question: "q", asked: QuickChatAsked(account: t.account, other: m.otherLimit))]
        return m
    }
    func refuse(_ m: QuickChatModel) {
        m.handle(.message(text: "You've hit your limit", model: "claude-haiku-5-5", error: "rate_limit"))
        m.handle(.done(isError: true, text: "You've hit your limit", ms: 5, session: "s"))
    }
    // the last turn's bubble, as QCTurnView draws it (its problem as the turn keeps it)
    func bubbleView(_ m: QuickChatModel) -> QCProblemView {
        QCProblemView(problem: m.turns.last?.problem ?? .noProfile, model: m, answered: true)
    }
    func bubble(_ m: QuickChatModel) -> String { bubbleView(m).title }
    /// A turn's stored bubble (an older one: not the last), as QCTurnView draws it: its title and next words.
    func stored(_ m: QuickChatModel, _ i: Int = 0) -> String {
        let v = QCProblemView(problem: m.turns[i].problem ?? .noProfile, model: m, answered: false, last: i == m.turns.count - 1)
        return v.title + "|" + v.more
    }
    /// The bar's own live bubble under the chat, as QCWindow draws it.
    func liveBelow(_ m: QuickChatModel) -> QCProblemView {
        QCProblemView(problem: .limitFull(m.fullNow), model: m, answered: false, live: true, keyOnly: m.limitRepeated)
    }
    /// Whose the last turn's full limit is (nil: the account in use's, or none).
    func whose(_ m: QuickChatModel) -> QuickChatOtherLimit? {
        if case .limitFull(let f)? = m.turns.last?.problem { return f.other }
        return nil
    }
    let cardOffer = QuickChatSwitchOffer(key: "card~k2", short: "ultra-2", words: "")
    _ = Store.writeStatus(e.id, rec(week: nil, five: nil, login: u3.email, code: u3))
    let inClash = chat(QuickChatTarget(e, now: now), level: QuickChatLevel(nil))
    inClash.handle(.limit(type: "seven_day", used: 1, status: "rejected", resets: soon))
    check(inClash.inClash && inClash.level?.full() == nil && !inClash.blocked, "a clash: Other's limit event marks nothing full, typing stays free")
    refuse(inClash)
    inClash.update(target: QuickChatTarget(e, now: now), level: QuickChatLevel(nil), offer: { nil })
    let clashBubble = bubble(inClash), clashMore = bubbleView(inClash).more
    check(whose(inClash) == .clash(name: "Other", own: true) && inClash.level?.full() == nil && !inClash.blocked
          && inClash.offer == nil && filled == 0
          && clashBubble == QCProblemView.otherLimitTitle && !clashBubble.contains("This account") && !clashBubble.contains("@"),
          "a clash: Other's refusal is said, but nothing full, no hold, no offer, no look for one; the bubble names no account as full: \(clashBubble)")
    check(clashMore.contains("Other's account") && clashMore.contains("Move it back to Card's own account on the Switch page")
          && !clashMore.contains("@"),
          "a clash: the bubble's next words name whose account (Other's, no address) and the way out: \(clashMore)")
    // with no account of its own known: no "move it back", Other's account named and the Switch page pointed to
    let seatlessChat = chat(QuickChatTarget(seatless, now: now), level: QuickChatLevel(nil))
    refuse(seatlessChat)
    let seatlessMore = bubbleView(seatlessChat).more
    check(whose(seatlessChat) == .clash(name: "Other", own: false) && seatlessMore.contains("Other's account")
          && seatlessMore.contains("Switch page") && !seatlessMore.contains("Move it back") && !seatlessMore.contains("@"),
          "a clash with no own account known: no move back, Other's account and the Switch page: \(seatlessMore)")
    // the folder moves back to u1 afterwards: the old bubble keeps its words (it never calls u1 full)
    _ = Store.writeStatus(e.id, rec())
    inClash.update(target: QuickChatTarget(e, now: now), level: QuickChatLevel(Usage.of(Store.status(for: e, now: now))), offer: { nil })
    check(!inClash.inClash && bubble(inClash) == clashBubble && bubbleView(inClash).more == clashMore,
          "moved back to u1 after a clash's refusal: the old bubble's words are unchanged: \(bubble(inClash))")
    // …and u1's own week is full: the chat draws the bar's bubble below (this account's week, with the switch), since the
    // last turn's bubble is the clash's, which says nothing of u1
    _ = Store.writeStatus(e.id, rec(week: 100, weekIn: 3 * 3600))
    inClash.update(target: QuickChatTarget(e, now: now), level: QuickChatLevel(Usage.of(Store.status(for: e, now: now))), offer: { cardOffer })
    let below = liveBelow(inClash)
    check(inClash.blocked && inClash.limitBubbleBelow && !inClash.limitRepeated && below.title.hasPrefix("This account's week is full")
          && inClash.offer == cardOffer && below.more.contains("ultra-2") && bubble(inClash) == clashBubble,
          "a clash's refusal, then back on u1 with its week full: the bar's bubble shows below, with the switch: \(below.title) \(below.more)")
    _ = Store.writeStatus(e.id, rec())
    let ownLevel = QuickChatLevel(Usage.of(Store.status(for: e, now: now)))
    let outside = chat(QuickChatTarget(e, now: now), level: ownLevel)
    check(outside.liveCounts && !outside.inClash && !outside.blocked, "outside a clash, the profile's own numbers: free to type")
    outside.handle(.limit(type: "seven_day", used: 1, status: "rejected", resets: soon))
    check(outside.level?.full()?.kind == .week && outside.blocked, "outside a clash: Claude Code's limit event marks the week full and holds typing")
    let refusedOnly = chat(QuickChatTarget(e, now: now), level: ownLevel)
    refuse(refusedOnly)
    let ownBubble = bubble(refusedOnly)
    check(refusedOnly.level?.full() != nil && refusedOnly.blocked && filled == 1 && ownBubble.hasPrefix("This account's ")
          && !refusedOnly.limitBubbleBelow,
          "outside a clash: a refusal holds typing, the controller looks for an offer, the bubble says this account's limit: \(ownBubble)")
    // the turn's bubble is fixed as the turn ends: the limit and until when, no offer, no key. The offer comes later, in
    // the live bubble below, which says only the offer and its key while the turn's bubble names the same hold. Then
    // Switch account… with a question typed, the folder on u2: the question goes, the old bubble unchanged, nothing below
    let heldWords = stored(refusedOnly)
    refusedOnly.update(target: QuickChatTarget(e, now: now), level: ownLevel, offer: { cardOffer })
    let keyLine = liveBelow(refusedOnly)
    check(refusedOnly.offer == cardOffer && heldWords.contains("back") && heldWords.hasSuffix("|") && stored(refusedOnly) == heldWords
          && refusedOnly.limitBubbleBelow && refusedOnly.limitRepeated && keyLine.title.isEmpty && keyLine.more.contains("ultra-2"),
          "a refusal: its bubble says until when, with no offer; the offer and its key come below, alone: \(heldWords) / \(keyLine.more)")
    refusedOnly.field = "next"
    refusedOnly.switchAccount()
    _ = Store.writeStatus(e.id, rec(week: 10, login: u2.email, code: u2))
    refusedOnly.update(target: QuickChatTarget(e, now: now), level: QuickChatLevel(Usage.of(Store.status(for: e, now: now))), offer: { nil })
    check(refusedOnly.turns.count == 2 && !refusedOnly.blocked && !refusedOnly.limitBubbleBelow && stored(refusedOnly) == heldWords,
          "a refusal, a switch, the question sent on u2: the old bubble's words are unchanged, nothing below: \(stored(refusedOnly))")
    _ = Store.writeStatus(e.id, rec())
    _ = Store.writeStatus(e.id, appRec(appU2, code: u1))
    let inSplit = chat(QuickChatTarget(win, now: now), level: QuickChatLevel(nil))
    refuse(inSplit)
    check(inSplit.inSplit && !inSplit.blocked && filled == 1 && bubble(inSplit) == QCProblemView.otherLimitTitle
          && whose(inSplit) == .split,
          "the split: the refusal holds nothing, and the bubble names no account as full: \(bubble(inSplit))")

    // a turn's bubble is never rewritten, whatever holds the bar later; the live bubble below says what holds it now:
    // A. the 5-hour limit refused a turn; it resets, then the week fills
    _ = Store.writeStatus(e.id, rec())
    let otherOffer = QuickChatSwitchOffer(key: "card~k3", short: "spare", words: "")
    var fiveFull = QuickChatLevel(nil)
    fiveFull.fiveHour = 100; fiveFull.fiveHourResets = now.addingTimeInterval(3600); fiveFull.week = 60; fiveFull.weekResets = now.addingTimeInterval(2 * 86400)
    let caseA = chat(QuickChatTarget(e, now: now), level: fiveFull)
    refuse(caseA)
    let aWords = stored(caseA)
    var weekFull = QuickChatLevel(nil)
    weekFull.fiveHour = 10; weekFull.fiveHourResets = now.addingTimeInterval(5 * 3600); weekFull.week = 100; weekFull.weekResets = now.addingTimeInterval(3 * 3600)
    caseA.update(target: QuickChatTarget(e, now: now), level: weekFull, offer: { cardOffer })
    let aBelow = liveBelow(caseA)
    check(aWords.contains("5-hour limit is full") && stored(caseA) == aWords && caseA.level?.full()?.kind == .week
          && caseA.limitBubbleBelow && !caseA.limitRepeated && aBelow.title.hasPrefix("This account's week is full") && aBelow.more.contains("ultra-2"),
          "A: the 5-hour refusal's bubble stays; the week that filled since shows below, with the switch: \(aWords) / \(aBelow.title)")
    // B. Switch account… with nothing typed; the account switched to is full too
    let caseB = chat(QuickChatTarget(e, now: now), level: ownLevel)
    refuse(caseB)
    let bWords = stored(caseB)
    caseB.update(target: QuickChatTarget(e, now: now), level: ownLevel, offer: { cardOffer })
    caseB.switchAccount()
    _ = Store.writeStatus(e.id, rec(week: 100, weekIn: 5 * 3600, login: u2.email, code: u2))
    caseB.update(target: QuickChatTarget(e, now: now), level: QuickChatLevel(Usage.of(Store.status(for: e, now: now))), offer: { otherOffer })
    let bBelow = liveBelow(caseB)
    check(stored(caseB) == bWords && !bWords.contains("spare") && caseB.blocked && caseB.limitBubbleBelow && !caseB.limitRepeated
          && bBelow.title.hasPrefix("This account's week is full") && bBelow.more.contains("spare") && caseB.turns.count == 1,
          "B: switched with nothing typed to an account that is full too: the old bubble keeps u1's words; u2's limit and offer show below: \(bBelow.title) \(bBelow.more)")
    // C. a refusal's made-up hour, then the reading's real reset
    _ = Store.writeStatus(e.id, rec())
    let caseC = chat(QuickChatTarget(e, now: now), level: ownLevel)
    refuse(caseC)
    let cWords = stored(caseC)
    _ = Store.writeStatus(e.id, rec(week: 100, weekIn: 3 * 3600))
    caseC.update(target: QuickChatTarget(e, now: now), level: QuickChatLevel(Usage.of(Store.status(for: e, now: now))), offer: { cardOffer })
    let cBelow = liveBelow(caseC)
    check(stored(caseC) == cWords && caseC.limitBubbleBelow && !caseC.limitRepeated && !cBelow.title.isEmpty
          && cBelow.title != String(cWords.prefix { $0 != "|" }) && cBelow.more.contains("ultra-2"),
          "C: the refusal's bubble keeps its hour; the real reset shows below, with the switch: \(cWords) / \(cBelow.title)")
    // the same reset said by Claude Code's event (whole seconds) and by a reading (fractions): the bubble below doesn't
    // say the limit again; a renewal hours later does
    _ = Store.writeStatus(e.id, rec())
    let eventReset = Date(timeIntervalSince1970: (now.timeIntervalSince1970 + 2 * 3600).rounded())
    for (shift, same) in [(0.4, true), (5 * 3600.0, false)] {
        let m = chat(QuickChatTarget(e, now: now), level: ownLevel)
        m.handle(.limit(type: "seven_day", used: 1, status: "rejected", resets: eventReset))
        refuse(m)
        var reading = QuickChatLevel(nil)
        reading.week = 100; reading.weekResets = eventReset.addingTimeInterval(shift); reading.fiveHour = 12; reading.fiveHourResets = now.addingTimeInterval(3600)
        m.update(target: QuickChatTarget(e, now: now), level: reading, offer: { cardOffer })
        check(m.limitRepeated == same && liveBelow(m).title.isEmpty == same,
              "the event's reset R, a reading's R+\(shift) s: the same limit \(same ? "(the key line alone below)" : "no more (said again below)")")
    }
    // a turn asked in the clash (on Other's u3) still running when the folder moves back to u1: u3's limit event and
    // refusal are judged by what it was asked on: Other's, so u1 is neither held nor called full
    _ = Store.writeStatus(e.id, rec(week: nil, five: nil, login: u3.email, code: u3))
    let lateClash = chat(QuickChatTarget(e, now: now), level: QuickChatLevel(nil))
    _ = Store.writeStatus(e.id, rec())
    lateClash.update(target: QuickChatTarget(e, now: now), level: ownLevel, offer: { nil })
    let filledBefore = filled
    lateClash.handle(.limit(type: "seven_day", used: 1, status: "rejected", resets: soon))
    refuse(lateClash)
    // (its words are decided as they're fixed: the folder is back on u1 by then, so no "move it back")
    check(!lateClash.inClash && whose(lateClash) == .moved && !lateClash.blocked && lateClash.level?.full() == nil
          && filled == filledBefore && bubble(lateClash) == QCProblemView.otherLimitTitle && bubbleView(lateClash).more.isEmpty,
          "asked in the clash, refused after the move back: not u1's, u1 not held nor called full, no move back: \(bubble(lateClash))")
    // asked on u1, the folder moving to Other's u3 (a clash) before the turn ends: the turn ran on u1, so not "Other's limit"
    _ = Store.writeStatus(e.id, rec())
    let intoClash = chat(QuickChatTarget(e, now: now), level: ownLevel)
    _ = Store.writeStatus(e.id, rec(week: nil, five: nil, login: u3.email, code: u3))
    intoClash.update(target: QuickChatTarget(e, now: now), level: QuickChatLevel(nil), offer: { nil })
    let filledInto = filled
    intoClash.handle(.limit(type: "seven_day", used: 1, status: "rejected", resets: soon))
    refuse(intoClash)
    check(intoClash.inClash && whose(intoClash) == .moved && !intoClash.blocked && filled == filledInto
          && bubble(intoClash) == QCProblemView.otherLimitTitle && !bubbleView(intoClash).more.contains("Other"),
          "asked on u1, a clash started before it ended: no one's limit here, never \"Other's limit\", no hold: \(bubbleView(intoClash).more)")
    // asked outside the split, the split starting mid-turn (the folder stays on u1): no hold, no block
    _ = Store.writeStatus(e.id, appRec(appU1, code: u1))
    let lateSplit = chat(QuickChatTarget(win, now: now), level: QuickChatLevel(nil))
    _ = Store.writeStatus(e.id, appRec(appU2, code: u1))
    lateSplit.update(target: QuickChatTarget(win, now: now), level: QuickChatLevel(nil), offer: { nil })
    let filledSplit = filled
    lateSplit.handle(.limit(type: "seven_day", used: 1, status: "rejected", resets: soon))
    refuse(lateSplit)
    check(lateSplit.inSplit && !lateSplit.blocked && lateSplit.level?.full() == nil && filled == filledSplit
          && whose(lateSplit) == .split && bubble(lateSplit) == QCProblemView.otherLimitTitle,
          "asked outside the split, the split started mid-turn: the limit event and refusal hold nothing: \(bubble(lateSplit))")
    // asked on u1, the folder on u2 (its own standby, no clash) before the turn ends: u1's limit, said as no one's here
    _ = Store.writeStatus(e.id, rec())
    let lateMove = chat(QuickChatTarget(e, now: now), level: ownLevel)
    _ = Store.writeStatus(e.id, rec(week: 10, login: u2.email, code: u2))
    lateMove.update(target: QuickChatTarget(e, now: now), level: QuickChatLevel(Usage.of(Store.status(for: e, now: now))), offer: { nil })
    let filledMove = filled
    lateMove.handle(.limit(type: "seven_day", used: 1, status: "rejected", resets: soon))
    refuse(lateMove)
    check(!lateMove.inClash && !lateMove.inSplit && whose(lateMove) == .moved && !lateMove.blocked && filled == filledMove
          && bubble(lateMove) == QCProblemView.otherLimitTitle && bubbleView(lateMove).more.isEmpty,
          "asked on u1, the folder on u2 before it ended: no account called full, no address, no hold: \(bubble(lateMove))")
    // another limit with a reset under a minute apart: not the same (said again below)
    _ = Store.writeStatus(e.id, rec())
    let kindReset = now.addingTimeInterval(2 * 3600)
    var fiveAt = QuickChatLevel(nil)
    fiveAt.fiveHour = 100; fiveAt.fiveHourResets = kindReset; fiveAt.week = 60; fiveAt.weekResets = now.addingTimeInterval(2 * 86400)
    let otherKind = chat(QuickChatTarget(e, now: now), level: fiveAt)
    refuse(otherKind)
    var weekAt = QuickChatLevel(nil)
    weekAt.fiveHour = 10; weekAt.fiveHourResets = now.addingTimeInterval(9 * 3600); weekAt.week = 100; weekAt.weekResets = kindReset.addingTimeInterval(0.4)
    otherKind.update(target: QuickChatTarget(e, now: now), level: weekAt, offer: { cardOffer })
    check(otherKind.level?.full()?.kind == .week && !otherKind.limitRepeated && !liveBelow(otherKind).title.isEmpty,
          "the 5-hour limit said, then the week with a reset 0.4 s apart: another limit, said again below")
    // the same limit and reset on another account (the folder on u2 since): not the same, said again below
    _ = Store.writeStatus(e.id, rec())
    var weekAtR = QuickChatLevel(nil)
    weekAtR.week = 100; weekAtR.weekResets = kindReset; weekAtR.fiveHour = 10; weekAtR.fiveHourResets = now.addingTimeInterval(3600)
    let otherSeat = chat(QuickChatTarget(e, now: now), level: weekAtR)
    refuse(otherSeat)
    _ = Store.writeStatus(e.id, rec(week: 10, login: u2.email, code: u2))
    otherSeat.update(target: QuickChatTarget(e, now: now), level: weekAtR, offer: { cardOffer })
    check(otherSeat.blocked && otherSeat.level?.full()?.resets == kindReset && !otherSeat.limitRepeated && !liveBelow(otherSeat).title.isEmpty,
          "the same week and reset, but on u2 since: another account's limit, said again below")
    _ = Store.writeStatus(e.id, rec())

    // Switch account… with a question waiting: a folder signed out on the way (no id: its address kept, or none) hasn't
    // moved, so nothing goes and no note names the old address; on another seat (u2) the question goes, the note naming
    // what the header names; a move into a clash names the profile's own account, never the folder's
    func typedThenSwitch(_ r: IconStatus) -> (QuickChatModel, () -> Int) {
        _ = Store.writeStatus(e.id, r)
        var asked = 0
        let m = QuickChatModel(); m.resolveClaude = { _ in asked += 1 }
        let full = QuickChatLevel(Usage.of(Store.status(for: e, now: now)))
        m.update(target: QuickChatTarget(e, now: now), level: full, offer: { QuickChatSwitchOffer(key: "card~k2", short: "ultra-2", words: "") })
        m.field = "what's typed"
        m.switchAccount()
        return (m, { asked })
    }
    func move(_ m: QuickChatModel, _ r: IconStatus, as p: AccountEntry? = nil) {
        _ = Store.writeStatus(e.id, r)
        m.update(target: QuickChatTarget(p ?? e, now: now), level: QuickChatLevel(Usage.of(Store.status(for: e, now: now))), offer: { nil })
    }
    let fullWeek = rec(week: 100, weekIn: 3 * 3600)
    let (w1, asked1) = typedThenSwitch(fullWeek)
    check(w1.blocked && w1.offer != nil, "a full week: the bar holds and offers the switch")
    move(w1, rec("ok", week: nil, five: nil, login: u1.email, code: nil))
    move(w1, rec("noLogin", week: nil, five: nil, login: nil, code: nil))
    check(w1.turns.isEmpty && w1.note == nil && asked1() == 0 && w1.field == "what's typed",
          "the folder signed out on the way (its address kept, then none): not moved, nothing sent, no note: \(w1.note ?? "none")")
    move(w1, rec(week: 10, login: u2.email, code: u2))
    check(w1.turns.map(\.question) == ["what's typed"] && asked1() == 1 && w1.note == "Card switched to \(AccountNames.short(u2.email!)). Sending what you typed.",
          "on another seat (u2): what was typed goes, the note names u2 as the header does: \(w1.note ?? "none")")
    // the same seat in a record with no organisation (from before codeOrganization): not a move, nothing goes
    let (w3, asked3) = typedThenSwitch(fullWeek)
    var sameNoOrg = rec(week: 10); sameNoOrg.resolved?.codeOrganization = nil
    move(w3, sameNoOrg)
    check(w3.turns.isEmpty && w3.note == nil && asked3() == 0, "the same seat, its organisation not recorded: no \"switched to\" the same account: \(w3.note ?? "none")")
    // moved into a clash: Claude Code would answer on Other's u3 under a header naming u1, so nothing goes (the stand-in
    // claude gets no turn), the wait ends, what was typed stays in the field, and the note names no account as answering
    let clashNote = "Card's Claude Code folder is now on Other's account, so what you typed wasn't sent. Move it back to Card's own account on the Switch page."
    func unsent(_ m: QuickChatModel, _ asked: () -> Int, _ words: String) -> Bool {
        m.inClash && asked() == 0 && m.turns.isEmpty && m.field == "what's typed" && m.note == words
            && m.note?.contains(AccountNames.short(u1.email!)) == false && m.note?.contains(AccountNames.short(u3.email!)) == false
    }
    let (w2, asked2) = typedThenSwitch(fullWeek)
    move(w2, rec(week: nil, five: nil, login: u3.email, code: u3))
    check(unsent(w2, asked2, clashNote), "moved into a clash (the app not deciding): nothing sent, the question kept, no address: \(w2.note ?? "none")")
    // still in the clash (another reading): the note stays
    move(w2, rec(week: nil, five: nil, login: u3.email!.uppercased(), code: u3))
    check(w2.note == clashNote && asked2() == 0, "another reading of the same clash: the note stays, nothing sent")
    // …and the clash clearing later (back on u1 with room, then on u2): the note goes, nothing is sent by itself, the
    // question stays; the person sending it again: it goes
    move(w2, rec())
    check(!w2.inClash && asked2() == 0 && w2.turns.isEmpty && w2.field == "what's typed" && w2.note == nil,
          "the clash cleared (back on u1): its note gone, nothing sent by itself, the question still there: \(w2.note ?? "none")")
    move(w2, rec(week: 10, login: u2.email, code: u2))
    check(asked2() == 0 && w2.turns.isEmpty && w2.field == "what's typed" && w2.note == nil,
          "then on u2: the wait is gone, so nothing goes and no \"switched to\": \(w2.note ?? "none")")
    w2.send()
    check(asked2() == 1 && w2.turns.map(\.question) == ["what's typed"] && w2.note == nil && w2.field.isEmpty,
          "sent again by the person: it goes")
    // an app-decided clash (the app on the profile's own u1, the folder on Other's u3): the same
    let (w7, asked7) = typedThenSwitch(fullWeek)
    move(w7, appRec(appU1, code: u3), as: win)
    check(w7.target?.shownEmail == u1.email && unsent(w7, asked7, clashNote),
          "moved into an app-decided clash: nothing sent, the question kept, the note as above: \(w7.note ?? "none")")
    move(w7, appRec(appU1, code: u1), as: win)
    check(asked7() == 0 && w7.turns.isEmpty && w7.field == "what's typed", "the app-decided clash cleared: nothing sent by itself")
    // a clash with no account of its own known: no "move it back", an account to pick on the Switch page
    let (w8, asked8) = typedThenSwitch(fullWeek)
    move(w8, rec(week: nil, five: nil, login: u3.email, code: u3), as: seatless)
    check(unsent(w8, asked8, "Card's Claude Code folder is now on Other's account, so what you typed wasn't sent. Pick an account for Card on the Switch page."),
          "moved into a clash with no own account known: nothing sent, the Switch page to pick one: \(w8.note ?? "none")")
    // the split (the app on u1, Claude Code moved to u2, no clash): as before, it goes on u2, and the note names u2, the
    // account that answers there
    let (w9, asked9) = typedThenSwitch(fullWeek)
    move(w9, appRec(appU1, code: u2), as: win)
    check(w9.inSplit && !w9.inClash && asked9() == 1 && w9.turns.map(\.question) == ["what's typed"] && w9.target?.email == u2.email
          && w9.note == "Card switched to \(AccountNames.short(u2.email!)). Sending what you typed.",
          "moved into the split: what was typed goes on u2, the note naming u2 (the account answering): \(w9.note ?? "none")")
    // one login's seat with no organisation (the record says none) and its Team seat: a move either way is a move (the
    // question goes, the note says it), never "the organisation not known"; the same seat with none, or a record from
    // before codeOrganization, isn't one
    let switchedNote = "Card switched to \(AccountNames.short(u1.email!)). Sending what you typed."
    let (w4, asked4) = typedThenSwitch(rec(week: 100, weekIn: 3 * 3600, code: bare))
    check(w4.blocked && w4.offer != nil && w4.target?.account?.organization == "", "a seat with no organisation, its week full: the bar holds and offers the switch")
    move(w4, rec(week: 10, code: team))
    check(asked4() == 1 && w4.turns.map(\.question) == ["what's typed"] && w4.note == switchedNote,
          "from a login's seat with no organisation to its Team seat: a move, what was typed goes: \(w4.note ?? "none")")
    let (w5, asked5) = typedThenSwitch(rec(week: 100, weekIn: 3 * 3600, code: team))
    move(w5, rec(week: 10, code: bare))
    check(asked5() == 1 && w5.note == switchedNote, "from a login's Team seat to its seat with no organisation: a move, what was typed goes: \(w5.note ?? "none")")
    let (w6, asked6) = typedThenSwitch(rec(week: 100, weekIn: 3 * 3600, code: bare))
    move(w6, rec(week: 10, login: emptyOrg.email, code: emptyOrg))
    var bareNoOrg = rec(week: 10, code: bare); bareNoOrg.resolved?.codeOrganization = nil
    move(w6, bareNoOrg)
    check(asked6() == 0 && w6.note == nil && w6.turns.isEmpty,
          "a seat with no organisation, then an empty one, then a record from before codeOrganization: not a move, nothing goes: \(w6.note ?? "none")")
    // the kept level: Claude Code's refusal on the seat with no organisation stays for it, never for the Team seat
    _ = Store.writeStatus(e.id, rec(week: 10, code: bare))
    let tenPct = QuickChatLevel(Usage.of(Store.status(for: e, now: now)))
    let keptOn = chat(QuickChatTarget(e, now: now), level: tenPct)
    refuse(keptOn)
    keptOn.update(target: QuickChatTarget(e, now: now), level: tenPct, offer: { nil })
    let heldOnBare = keptOn.blocked
    _ = Store.writeStatus(e.id, rec(week: 10, code: team))
    keptOn.update(target: QuickChatTarget(e, now: now), level: tenPct, offer: { nil })
    _ = Store.writeStatus(e.id, rec(week: 10, code: bare))
    let keptOld = chat(QuickChatTarget(e, now: now), level: tenPct)
    refuse(keptOld)
    _ = Store.writeStatus(e.id, bareNoOrg)
    keptOld.update(target: QuickChatTarget(e, now: now), level: tenPct, offer: { nil })
    check(heldOnBare && keptOld.blocked && !keptOn.blocked && keptOn.level?.refusedUntil == nil,
          "a refusal on a seat with no organisation: kept for it (and over a record from before codeOrganization), dropped on the Team seat")
    _ = Store.writeStatus(e.id, rec())

    // the process itself, against the stand-in claude (Checks/quick-chat/stub-claude, which numbers its answers from 1 for
    // each process it is): a clash's process, on the folder's u3, is kept while the folder stays there (its address in
    // capitals included), and replaced once it moves back to u1; Other's live limits never reach the header's account
    let stub = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("quick-chat/stub-claude").path
    try? fm.createDirectory(atPath: expand(e.configDir), withIntermediateDirectories: true)
    let keepSeam = FolderGuard.launchSeam
    FolderGuard.launchSeam = nil
    let live = QuickChatModel(); live.resolveClaude = { $0(stub) }
    func say(_ q: String, on r: IconStatus) -> String {
        _ = Store.writeStatus(e.id, r)
        live.update(target: QuickChatTarget(e, now: now), level: QuickChatLevel(Usage.of(Store.status(for: e, now: now))), offer: { nil })
        live.field = q
        live.send()
        let until = Date().addingTimeInterval(10)
        while live.busy && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return live.turns.last?.answer ?? ""
    }
    let a1 = say("one", on: rec(week: nil, five: nil, login: u3.email, code: u3))
    check(a1 == "Answer 1" && live.level?.week == nil && live.level?.full() == nil && !live.blocked,"a clash: the stand-in answers; its live limits (62 %) never reach the header's account: \(a1)")
    let a2 = say("two", on: rec(week: nil, five: nil, login: u3.email!.uppercased(), code: u3))
    check(a2 == "Answer 2", "still on u3 (its address in capitals): the same process goes on: \(a2)")
    let a3 = say("three", on: rec())
    check(a3 == "Answer 1" && abs((live.level?.week ?? 0) - 62) < 0.01,"moved back to u1: a new process (it numbers from 1 again); its live week counts here: \(a3), \(live.level?.week ?? -1)")
    // one login's seat with no organisation, then its Team seat, then back: each move a new process; the same seat goes on
    let a4 = say("four", on: rec(code: bare))
    let a5 = say("five", on: rec(code: team))
    let a6 = say("six", on: rec(code: team))
    let a7 = say("seven", on: rec(code: bare))
    check(a4 == "Answer 1" && a5 == "Answer 1" && a6 == "Answer 2" && a7 == "Answer 1",
          "a login's seat with no organisation, its Team seat (twice), then back: a new process at each move, kept on the same seat: \([a4, a5, a6, a7])")
    // a question waiting for a switch that lands in a clash, against the process: nothing reaches the stand-in (no turn,
    // no process asked for); once the clash clears the note goes, and the person's send is the second answer of the
    // process still on that seat, so it had no turn in between
    var resolved = 0
    live.resolveClaude = { resolved += 1; $0(stub) }
    let turnsBefore = live.turns.count
    _ = Store.writeStatus(e.id, rec(week: 100, weekIn: 3 * 3600, code: bare))
    live.update(target: QuickChatTarget(e, now: now), level: QuickChatLevel(Usage.of(Store.status(for: e, now: now))), offer: { cardOffer })
    live.field = "eight"
    live.switchAccount()
    _ = Store.writeStatus(e.id, rec(week: nil, five: nil, login: u3.email, code: u3))
    live.update(target: QuickChatTarget(e, now: now), level: QuickChatLevel(Usage.of(Store.status(for: e, now: now))), offer: { nil })
    let pumpUntil = Date().addingTimeInterval(0.5)
    while Date() < pumpUntil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(live.inClash && resolved == 0 && live.turns.count == turnsBefore && !live.busy && live.field == "eight" && live.note == clashNote,
          "the stand-in, a switch landing in a clash: no turn, no process asked for, the question kept: \(live.note ?? "none")")
    _ = Store.writeStatus(e.id, rec(code: bare))
    live.update(target: QuickChatTarget(e, now: now), level: QuickChatLevel(Usage.of(Store.status(for: e, now: now))), offer: { nil })
    let noteAfter = live.note
    let a8 = say("eight", on: rec(code: bare))
    check(noteAfter == nil && resolved == 1 && a8 == "Answer 2" && live.turns.count == turnsBefore + 1,
          "the clash cleared: the note gone; sent by the person, the process on the seat answers its second: \(a8)")
    live.shutdown()
    FolderGuard.launchSeam = keepSeam
    _ = Store.writeStatus(e.id, rec(week: nil, five: nil, login: u3.email, code: u3))
    // Settings ▸ Accounts' Sign in… keys: the in-use box's on the profile's own account (u1), Claude Code's own row's on its
    // own (the folder's u3)
    let keysModel = SettingsModel(); keysModel.accounts = [e, other]
    let keys = AccountSettings(entry: .constant(e), model: keysModel)
    check(keys.inUseKeyAddress == u1.email && keys.codeKeyAddress == u3.email,
          "Settings' Sign in… keys in a clash: the in-use box's on u1, Claude Code's own row's on its own account u3: \(keys.inUseKeyAddress ?? "-") / \(keys.codeKeyAddress ?? "-")")
    // the plan beside the account in use: one rule (ProfileShow.plan), none in a clash, the record's outside one
    let clashPlanShow = clashNone.row.show
    check(clashPlanShow.record?.plan == "Max" && clashPlanShow.plan == nil && clashPanel.plan == nil
          && SwitchPage.inUseDetail(plan: clashPlanShow.plan) == "" && SwitchPage.inUseDetail(plan: "max") == Account.planWords("max"),
          "a clash: no plan beside the account (the record's Max is Other's account's) in the Dock panel and the Switch page's in-use box")
    check(fresh.row.show.plan == "Max" && DetailsInfo.of(fresh.row.show, name: e.name, icon: NSImage(), problem: nil).plan == "Max",
          "outside a clash: the record's plan, in the Dock panel too")
    // a clash whose sign-in is also expired: the panel's age line agrees with the card's notice (the clash), in its long and short form
    let clashExpired = card(rec("expired", week: nil, five: nil, login: u3.email, code: u3), nil, "clash, expired")
    let clashExpiredPanel = DetailsInfo.of(clashExpired.row.show, name: e.name, icon: NSImage(), problem: nil)
    check(clashExpired.notice?.heading == "Terminal is signed in to Other's account"
          && clashExpiredPanel.noNumbers == "No usage: Terminal is on Other's account" && clashExpiredPanel.noNumbersShort == "No usage here",
          "a clash with the sign-in expired: the panel's age line says the clash like the card, not Sign-in expired: \(clashExpiredPanel.noNumbers ?? "-")")
    var byName = rec(login: u3.email, code: u3); byName.resolved?.clashID = nil
    let oldClash = card(byName, nil, "clash by old name")
    check(oldClash.row.display.clash == ProfileDisplay.Clash(id: nil, name: "Other") && oldClash.notice?.heading == "Terminal is signed in to Other's account"
          && oldClash.notice?.key == .signIn && oldClash.notice?.line == ownLine && !oldClash.row.lit,
          "a record from before the clash's id: by its name, the same notice and key to u1, the lamp off")
    var renamed = other; renamed.name = "Work"
    try! Store.save([e, renamed])
    let renamedClash = card(rec(login: u3.email, code: u3), nil, "renamed clash profile")
    check(renamedClash.notice?.tone == .red && renamedClash.notice?.key == .signIn && renamedClash.notice?.line == ownLine
          && !renamedClash.row.lit && renamedClash.row.display.clash?.id == "other",
          "the clash's profile renamed since the record: still red, Sign in… to u1, unlit, the clash by its id")
    try! Store.save([e, other])
    // the app decided the account in use (u2, not the seat's u1), Claude Code's folder on Other's: the app's address, never
    // the folder's nor the seat's
    let appClash = #"{"expectedEmail":"ultra-3@example.com","loginEmail":"ultra-3@example.com","resolved":{"account":"\#(u2.account)","at":1800000000,"clash":"Other","clashID":"other","differs":true,"email":"ultra-2@example.com","fromApp":true,"lit":true,"numbersFor":"ultra-3@example.com"},"state":"ok","updatedAt":\#(Int(now.timeIntervalSince1970) - 60),"weekly":40}"#
    let appDecided = card(StatusCodec.decode(Data(appClash.utf8))!, nil, "clash, the app's account")
    check(appDecided.notice?.key == .signIn && appDecided.notice?.line == "Sign in as \(Privacy.masked(u2.email!)) to read Card's usage."
          && appDecided.row.show.loginAddress == u2.email,
          "a clash with the app's account in use: Sign in… as the app's u2, never the folder's u3: \(appDecided.notice?.line ?? "-")")
    // the menu bar and the Dock icon offer the same key there (the value's), to the same address
    let clashShow = ProfileShow.load(e, now: now)
    check(clashShow.keyWords(short: false) == "Sign in…" && clashShow.loginAddress == u2.email,
          "the menu bar's and the Dock menu's key in a clash: Sign in…, to the app's u2")
    // Settings ▸ Accounts' Sign in in a clash on a profile with no seat (the app not deciding): no address of its own is
    // known, so the plain sign-in with none filled in, never the folder's (Other's u3). Wired for real up to the script
    // (its claude found, the guard asked, nothing runs)
    var noSeat = e; noSeat.seat = nil
    _ = Store.writeStatus(e.id, rec(login: u3.email, code: u3))
    try? fm.createDirectory(atPath: expand(e.configDir), withIntermediateDirectories: true)
    let settingsAddress = ProfileShow.load(noSeat, now: now).loginAddress
    var launched: [String] = [], scripts: [String] = []
    let keepLocator = ClaudeLocator.current, keepTerminal = ClaudeCLI.openTerminal
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { ["/usr/bin/false"] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
    FolderGuard.launchSeam = { what, dir in launched.append("\(what) \(dir)"); return true }
    ClaudeCLI.openTerminal = { u in scripts.append((try? String(contentsOf: u, encoding: .utf8)) ?? ""); return true }
    let clashModel = SettingsModel(); clashModel.accounts = [noSeat, other]
    AccountSettings(entry: .constant(noSeat), model: clashModel).signInAgain(email: settingsAddress)
    check(settingsAddress == nil && launched == ["login \(Account(noSeat).configDir)"] && scripts.count == 1
          && !scripts[0].contains(u3.email!) && !scripts[0].contains("--email") && clashModel.runner(of: e.id).goal == nil,
          "Settings' Sign in in a clash, no seat: the plain sign-in, no address, never Other's u3: \(launched)")
    ClaudeLocator.current = keepLocator; ClaudeCLI.openTerminal = keepTerminal; FolderGuard.launchSeam = nil
    // the address pop-up's Sign in… on a profile with no seat whose sign-in is on another account (u2; the folder names
    // u1): the folder's u1, never the account the sign-in is on (the pop-up's ticked line, u2)
    var onOther = IconStatus(state: "ok"); onOther.loginEmail = u2.email; onOther.expectedEmail = u1.email; onOther.updatedAt = now
    _ = Store.writeStatus(e.id, onOther)
    let popUp = AccountSettings(entry: .constant(noSeat), model: clashModel)
    let popUpItems = popUp.loginItems
    check(popUp.popUpSignInAddress == u1.email && popUpItems.contains { $0.id == "again" }
          && popUpItems.first { $0.id == "here" }?.title.contains(Privacy.masked(u2.email!)) == true,
          "the pop-up's Sign in… on a no-seat profile signed in to another account: the folder's u1, never u2: \(popUp.popUpSignInAddress ?? "nil")")
    // …and with an address (the app's u2) the runner signs in to that one, not the seat's u1 nor the folder's u3 (on a
    // folder that isn't there: the goal is set, nothing runs)
    var gone = e; gone.configDir = "~/.claude-card-gone"; gone.id = "cardgone"
    let goneModel = SettingsModel(); goneModel.accounts = [gone]
    goneModel.runner(of: gone.id).signInAgain(email: u2.email)
    let goal = goneModel.runner(of: gone.id).goal
    check(goal?.wantedEmail == u2.email && goal?.wantedSeat == nil && goneModel.runner(of: gone.id).phase != .ready,
          "the runner's Sign in again takes the address it is given (u2), never the seat's or the folder's")

    // unconfirmed: as read, never full, said so
    var unsure = rec(week: 100, weekIn: 3 * 3600); unsure.ownerUnconfirmed = true
    let us = card(unsure, nil, "unconfirmed")
    check(us.row.fiveHour == 12 && us.row.weekly == nil && us.row.full == nil && us.row.line == Store.unconfirmedWords && us.notice == nil,
          "unconfirmed: as read, a full week left out, the line says so")

    // standby is never read: the card's numbers are the account in use's only, its switch menu names standby by address
    var standbyRec = IconStatus(state: "ok"); standbyRec.loginEmail = u2.email; standbyRec.weekly = 77; standbyRec.updatedAt = now
    _ = Store.writeStatus("card~k2", standbyRec)
    let withStandby = card(rec(week: 100, weekIn: 3 * 3600), nil, "standby")
    let trays = withStandby.row.entry.listed(by: withStandby.row.view).cardTrays().map(\.offer.standby.label)
    check(withStandby.row.limits.allSatisfy { $0.p != 77 } && trays == [u2.email!] && trays.allSatisfy { !$0.contains("%") },
          "standby: never the standby's numbers on the card; Switch account lists it by address only: \(trays)")
    Store.removeStatus("card~k2")

    // no record at all: nothing, grey, unlit, no notice
    let none = card(nil, nil, "no record")
    check(none.row.status == nil && none.row.limits.allSatisfy { $0.p == nil } && none.row.tile.stale && !none.row.lit && none.notice == nil
          && none.row.subtitle == e.configDir, "no record: no numbers, grey, unlit, no notice")

    // the split: the Claude app on pat (in use), Claude Code on mo
    let pat = Seat(account: uuid(61), organization: uuid(161), email: "pat@example.com")
    let mo = Seat(account: uuid(62), organization: uuid(162), email: "mo@example.com")
    var s = profile("csp", "~/.claude-csp", mo); s.claudeWindow = true
    s.standby = [StandbyAccount(email: pat.email!, seat: pat, id: "kp", plan: "Max")]
    try! Store.save([s])
    func splitRec(app: AppSignIn.Login, newest: SwitchReceipt? = nil) -> IconStatus {
        var r = IconStatus(state: "ok"); r.loginEmail = mo.email; r.numbersOwner = mo.email; r.expectedEmail = mo.email
        r.weekly = 100; r.weeklyResets = now.addingTimeInterval(2 * 86400); r.noFiveHour = true; r.plan = "Ultra"; r.updatedAt = now
        r.resolved = AccountResolver.resolve(s, among: [s], app: app, code: mo, loginEmail: mo.email, names: [:], newestSwitch: newest, now: now)
        return r
    }
    let appPat = AppSignIn.Login(account: pat.account, org: pat.organization, state: .known, source: "log", at: now)
    let split = card(splitRec(app: appPat), s, "split")
    check(split.notice?.heading == "Terminal is signed in to \(Privacy.masked(mo.email!))" && split.notice?.tone == .red
          && split.notice?.key == .signIn && split.notice?.line == "Sign in as \(Privacy.masked(pat.email!)) to read Csp's usage."
          && split.row.lit && split.row.full == nil && split.row.limits.allSatisfy { $0.p == nil } && split.row.status?.plan == nil
          && split.row.show.loginAddress == pat.email, "the split: red, Sign in… as pat, lit (pat is in use), no numbers or plan, nothing full")
    let anonApp = AppSignIn.Login(account: uuid(63), org: uuid(163), state: .known, source: "log", at: now)
    let anon = card(splitRec(app: anonApp), s, "split, the app's account by id")
    check(anon.notice?.key == UsageNotice.Key.none && anon.notice?.line == "Sign Claude Code in Terminal in to the Claude app's account."
          && anon.row.show.loginAddress == nil && anon.terminalInRow,
          "the split with the app's account known by its id only: no key (the value's), the hint, Terminal in the keys row")
    check(!split.terminalInRow, "the split with its Sign in…: Terminal steps into ⋯")
    var toMo = SwitchReceipt(id: SwitchEngine.receiptID(now, "csp"), profile: "csp", standby: "km", dataDir: "/x", from: SeatID(pat), to: SeatID(mo), started: now)
    toMo.steps = [SwitchReceipt.Step(kind: .entry, path: "/x/a", sha: nil, parked: nil, original: nil, done: true)]
    toMo.linked = now
    let waiting = card(splitRec(app: appPat, newest: toMo), s, "split, a switch waiting")
    check(waiting.notice?.tone == .amber && waiting.notice?.heading == SplitUsage.switchingHead(mo.email!) && waiting.notice?.key == UsageNotice.Key.none
          && waiting.row.lit && waiting.terminalInRow, "a switch to mo waiting for the app: amber, no key, lit, Terminal in the row")
    // …while Terminal's sign-in has run out, is gone or is on another account: the switch still waits, and Sign in… shows
    for (what, state, expected) in [("expired", "expired", mo.email!), ("signed out", "noLogin", mo.email!), ("another account", "ok", "zed@example.com")] {
        var r = splitRec(app: appPat, newest: toMo); r.state = state; r.expectedEmail = expected
        let c = card(r, s, "a switch waiting, \(what)")
        check(c.notice?.tone == .amber && c.notice?.heading == SplitUsage.switchingHead(mo.email!) && c.notice?.key == .signIn
              && c.row.display.key == .logIn && !c.terminalInRow,
              "a switch waiting, Terminal's sign-in \(what): still the switch's notice, with Sign in…")
    }
    Store.removeStatus("card"); Store.removeStatus("csp")
    try? Store.save([])
}

// ============ 13. ProfileCore step 3c: Settings ▸ Accounts, the Switch page, the Dock panel and its preview draw the one value ============
MainActor.assumeIsolated {
    let now = Date()
    var e = profile("acc", "~/.claude-acc", u1); e.claudeWindow = false
    e.standby = [StandbyAccount(email: u2.email!, seat: u2, id: "k2", plan: "Max", lastInUse: now.addingTimeInterval(-86400))]
    // a second profile called "Other" (names needn't be unique), listed before the real one: a match by name finds it
    var twin = profile("other2", "~/.claude-other2", nil); twin.name = "Other"; twin.claudeWindow = false
    let model = SettingsModel(); model.accounts = [e, twin, other]
    try! Store.save([e, twin, other])
    func rec(_ state: String = "ok", week: Double? = 40, five: Double? = 12, age: TimeInterval = 60, login: String? = u1.email,
             code: Seat? = u1) -> IconStatus {
        var s = IconStatus(state: state); s.loginEmail = state == "noLogin" ? nil : login; s.expectedEmail = code?.email
        s.weekly = week; s.fiveHour = five; s.weeklyResets = now.addingTimeInterval(2 * 86400); s.fiveHourResets = now.addingTimeInterval(3600)
        s.updatedAt = now.addingTimeInterval(-age); s.source = "Anthropic"; s.plan = "Max"
        s.resolved = AccountResolver.resolve(e, among: [e, other], app: .unknown, code: code, loginEmail: login, names: [:], now: now)
        return s
    }
    /// Settings ▸ Accounts, the Switch page and the panel preview for profile `p` with record `r` written.
    func surfaces(_ r: IconStatus?, _ p: AccountEntry? = nil) -> (settings: AccountSettings, page: SwitchPage, preview: DetailsInfo, panel: DetailsInfo) {
        let p = p ?? e
        if let r { _ = Store.writeStatus(p.id, r) } else { Store.removeStatus(p.id) }
        let preview = samplePanel(p, status: Store.status(for: p), now: now)
        return (AccountSettings(entry: .constant(p), model: model),
                SwitchPage(entry: p, standby: p.standby.first ?? StandbyAccount(email: u2.email!, id: "x"), model: model, runner: model.runner(of: p.id)),
                preview, DetailsInfo.of(ProfileShow.load(p, now: now), name: preview.name, icon: preview.icon, problem: nil))
    }
    /// The preview draws what the Dock icon's own panel draws.
    func same(_ a: DetailsInfo, _ b: DetailsInfo) -> Bool {
        a.active == b.active && a.activeLit == b.activeLit && a.activeNote == b.activeNote && a.needsLogin == b.needsLogin
            && a.splitKey == b.splitKey && a.fiveHour == b.fiveHour && a.weekly == b.weekly && a.updated == b.updated
            && a.stale == b.stale && a.noNumbers == b.noNumbers && a.mismatch == b.mismatch
    }

    // fresh: lit everywhere, numbers, no key; the preview is the panel
    let fresh = surfaces(rec())
    check(fresh.settings.inUseRow.lit && fresh.page.inUseRow.lit && UsageNotice.of(fresh.settings.inUseRow) == nil
          && fresh.settings.inUseRow.weekly == 40 && fresh.page.inUseRow.weekly == 40 && same(fresh.preview, fresh.panel)
          && fresh.panel.activeLit && !fresh.panel.stale && fresh.panel.limits.allSatisfy { !$0.stale },
          "fresh: Settings and the Switch page lit with the numbers, the preview as the panel, nothing grey")
    // old numbers: the panel's bars grey (its limits carry it), the preview too
    let old = surfaces(rec(age: 40 * 60))
    check(old.panel.stale && old.panel.limits.allSatisfy { $0.stale } && old.panel.weekly == 40 && same(old.preview, old.panel),
          "40 minutes old: the Dock panel's bars grey (the menu bar row's rule), the numbers still drawn; the preview the same")
    check(!surfaces(rec(age: 10 * 60)).panel.stale, "10 minutes old: last known, not grey")
    // the sign-in: can't be read (numbers, unlit), expired (red, Sign in…, no numbers): on the Switch page as in Settings
    let denied = surfaces(rec("denied"))
    check(!denied.settings.inUseRow.lit && !denied.page.inUseRow.lit && denied.page.inUseRow.weekly == 40 && same(denied.preview, denied.panel),
          "a sign-in that can't be read: unlit in Settings and on the Switch page (as the card), the numbers as read")
    let expired = surfaces(rec("expired"))
    check(UsageNotice.of(expired.settings.inUseRow)?.key == .signIn && !expired.page.inUseRow.lit && expired.page.inUseRow.weekly == nil
          && expired.preview.needsLogin && expired.preview.noNumbers == "Sign-in expired" && same(expired.preview, expired.panel),
          "expired: Settings' Sign in…, the Switch page unlit with no numbers, the preview with Sign in… and its words as the panel")
    // the short age line is the clash's alone: outside a clash it is the long one (expired, signed out, none)
    let signedOut = surfaces(rec("noLogin", week: nil, five: nil))
    check(expired.panel.noNumbersShort == expired.panel.noNumbers && signedOut.panel.noNumbersShort == signedOut.panel.noNumbers
          && signedOut.panel.noNumbers == "Signed out" && fresh.panel.noNumbersShort == nil && fresh.panel.noNumbers == nil,
          "outside a clash the panel's short age line is its long one: \(expired.panel.noNumbersShort ?? "-") / \(signedOut.panel.noNumbersShort ?? "-")")

    // a clash, by the record's profile id: Other (id other), though a profile listed before it is called Other too
    let clash = surfaces(rec(login: u3.email, code: u3))
    check(clash.settings.elsewhere?.owner.id == "other" && !clash.settings.inUseRow.lit && !clash.page.inUseRow.lit
          && UsageNotice.of(clash.settings.inUseRow)?.key == .signIn && clash.settings.popUpSignInAddress == u1.email,
          "a clash: Open Other by its id (not the first profile called Other), unlit, Sign in… to the profile's own u1")
    // the account line: the profile's own account (its seat, u1), never the folder's (Other's u3), on the card and the page
    let clashShow = ProfileShow.load(e, now: now), clashDock = dockOf(e, clashShow)
    let u1Short = AccountNames.short(u1.email!), u3Short = AccountNames.short(u3.email!)
    /// A menu's titles that name an account as the profile's (the Dock menu's "Sign-in: …" line says what Terminal is
    /// signed in to, as the card's heading does: it is that account's by design).
    func naming(_ m: NSMenu) -> [String] { titles(m).filter { !$0.hasPrefix("Sign-in: ") } }
    check(cardRow(e, now: now).show.inUseLabel == u1.email && clash.page.inUseRow.show.inUseLabel == u1.email && clash.settings.view.label == u3.email
          && clash.panel.accountLine?.text == u1.email && clashShow.named.inUseLine == u1Short
          && clashDock.menu.items.first?.title == "Claude Acc · \(u1Short)" && !naming(clashDock.menu).contains { $0.contains(u3Short) }
          && !titles(menuBarMenu(clashShow)).contains { $0.contains(u3Short) },
          "a clash the app didn't decide: the card, the Switch page, the Dock panel (as drawn), the Dock menu and the menu bar name u1, never the folder's u3")
    check(clash.settings.inUseKeys.signIn && clash.settings.inUseKeys.open?.id == "other", "a clash: Settings' red box has Sign in… and Open Other")
    // no plan in Settings' in-use box nor its pop-up in a clash, even from a record that still has one (the Reader writes
    // none there: dropForClash); outside a clash the record's
    check(Store.status("acc")?.plan == "Max" && clash.settings.inUsePlan == nil
          && clash.settings.loginItems.first { $0.id == "here" }.map { !$0.title.contains("Max") } == true,
          "a clash: Settings' in-use box and its pop-up show no plan (the record's Max is Other's account's): \(clash.settings.loginItems.map(\.title))")
    let plain = surfaces(rec())
    check(plain.settings.inUsePlan == "Max" && plain.settings.loginItems.first { $0.id == "here" }?.title.contains("Max") == true,
          "outside a clash: Settings' in-use box and its pop-up show the record's plan")
    _ = Store.writeStatus("acc", rec(login: u3.email, code: u3))
    // the record as the Reader writes it in a clash: the numbers and the plan dropped, the problem the line; the status
    // file only loses those keys (same codec, no other change)
    var asRead = rec(login: u3.email, code: u3); asRead.dropForClash(asRead.resolved?.line)
    func keys(_ s: IconStatus) -> Set<String> {
        Set(((try? JSONSerialization.jsonObject(with: StatusCodec.encode(s) ?? Data())) as? [String: Any] ?? [:]).keys)
    }
    let before = rec(login: u3.email, code: u3)
    check(asRead.plan == nil && asRead.weekly == nil && asRead.problem == before.resolved?.line && asRead.resolved == before.resolved
          && StatusCodec.decode(StatusCodec.encode(asRead)!).map { $0.plan == nil && $0.resolved?.clash == "Other" } == true
          && keys(before).subtracting(keys(asRead)) == ["plan", "weekly", "fiveHour", "weeklyResets", "fiveHourResets"]
          && keys(asRead).subtracting(keys(before)) == ["problem"],
          "the Reader's clash record: no plan nor numbers, the problem the line; the status JSON only loses those keys: \(keys(before).symmetricDifference(keys(asRead)).sorted())")
    // …with no seat: no account named anywhere (the card says the line instead), never the sign-in's u3
    var noSeat = e; noSeat.seat = nil
    let noSeatShow = ProfileShow.load(noSeat, now: now), noSeatPanel = DetailsInfo.of(noSeatShow, name: "x", icon: NSImage(), problem: nil)
    let noSeatDock = dockOf(noSeat, noSeatShow)
    check(noSeatShow.inUseLabel == nil && noSeatShow.inUseUnknown && noSeatPanel.login == u3.email && noSeatPanel.accountLine == nil
          && noSeatShow.named.inUseLine == nil && !naming(noSeatDock.menu).contains { $0.contains(u3Short) }
          && !titles(menuBarMenu(noSeatShow)).contains { $0.contains(u3Short) },
          "a clash with no seat: the panel draws no account line (never its sign-in's u3), the menus name none")
    // …nor the other account's plan: the Dock menu's title is the profile's name alone (it read "Claude Acc · Max"), the
    // Dock panel (as the Dock icon builds it) and the card have none
    check(noSeatDock.menu.items.first?.title == "Claude Acc" && noSeatDock.panel.plan == nil && clashDock.panel.plan == nil
          && cardRow(noSeat, now: now).show.plan == nil,
          "a clash: no plan in the Dock menu's title, the Dock panel or the card: \(noSeatDock.menu.items.first?.title ?? "-")")
    // the Switch page's in-use name: the profile's own in a clash, none known there "its account" (never the folder's u3);
    // a record with no account worked out, outside a clash: the folder's own address, else "its account"
    var unworked = IconStatus(state: "noLogin"); unworked.expectedEmail = u1.email
    unworked.resolved = AccountResolver.resolve(e, among: [e, other], app: .unknown, code: nil, loginEmail: nil, names: [:], now: now)
    let unworkedShow = ProfileShow.of(e, raw: unworked, now: now)
    check(SwitchPage.inUseName(clashShow, expected: u3.email) == u1.email && SwitchPage.inUseName(noSeatShow, expected: u3.email) == "its account"
          && unworkedShow.inUseLabel == nil && SwitchPage.inUseName(unworkedShow, expected: u1.email) == u1.email
          && SwitchPage.inUseName(unworkedShow, expected: nil) == "its account",
          "the Switch page's in-use name: u1 in a clash, \"its account\" with none of its own (never u3), the folder's address for a record with none worked out")
    // one account, one row: the profile's own account (u1, ticked in a clash) is also remembered on its standby list. It is
    // that one row everywhere: ticked, saying what choosing it does, still switchable (the way to move Claude Code back);
    // never a second row on standby
    var both = e; both.standby.append(StandbyAccount(email: u1.email!, seat: u1, id: "k1"))
    _ = Store.writeStatus("acc", rec(login: u3.email, code: u3))
    let bothShow = ProfileShow.load(both, now: now), bothDock = dockOf(both, bothShow), bothBar = menuBarMenu(bothShow)
    let u2Short = AccountNames.short(u2.email!)
    let backTitle = "\(u1Short) · move Claude Code back here", backKey = AccountEntry.switchKey("acc", "k1")
    func allItems(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) } }
    func rowsOf(_ m: NSMenu, _ short: String) -> Int { titles(m).filter { $0.hasPrefix(short) && !$0.hasPrefix("Claude") }.count }
    func ownRow(_ m: NSMenu) -> NSMenuItem? { allItems(m).first { $0.title == backTitle } }
    check(bothShow.ownStandbyID == "k1" && bothShow.named.label == u1.email, "a clash: the own account is the ticked one and the standby id k1 (ProfileShow.ownStandbyID)")
    check(rowsOf(bothDock.menu, u1Short) == 1 && rowsOf(bothBar, u1Short) == 1 && rowsOf(bothDock.menu, u2Short) == 1 && rowsOf(bothBar, u2Short) == 1
          && !titles(bothDock.menu).contains(u1Short + "…") && !titles(bothBar).contains(u1Short + "…"),
          "a clash, the own account also on the standby list: one row in the Dock menu and the menu bar menu, never on standby too (u2 once)")
    for (what, m) in [("Dock", bothDock.menu), ("menu bar", bothBar)] {
        let row = ownRow(m)
        check(row?.state == .on && row?.isEnabled == true && row?.action != nil && row?.representedObject as? String == backKey,
              "\(what) menu: the own account's row is ticked, says it moves Claude Code back, and switches to k1 (\(row?.title ?? "none"))")
    }
    let bothPage = surfaces(rec(login: u3.email, code: u3), both).page
    check(bothPage.pickList.map(\.id).filter { $0 == "k1" }.count == 1 && Set(bothPage.pickList.map(\.id)) == ["k1", "k2"],
          "the Switch page's TO list: the own account once, with ben: \(bothPage.pickList.map(\.id))")
    // …picked on purpose (the button names it): in the list, once, and selected
    let ownPicked = SwitchPage(entry: both, standby: both.standby[1], model: model, runner: model.runner(of: both.id))
    check(ownPicked.pickList.filter { $0.id == ownPicked.standby.id }.count == 1 && ownPicked.standby.id == "k1",
          "the own account picked in a clash: in the TO list once and selected: \(ownPicked.pickList.map(\.id))")
    let k1 = both.standby[1], k2 = both.standby[0]
    check(SwitchPage.boxWords(k1, back: true, name: "Acc", moveCount: nil, now: now) == "Move Claude Code back here."
          && SwitchPage.boxWords(k1, back: true, name: "Acc", moveCount: "41 Code-tab sessions", now: now) == "Move Claude Code back here (41 Code-tab sessions)."
          && SwitchPage.boxWords(k2, back: false, name: "Acc", moveCount: "41 Code-tab sessions", now: now) == "Last in use yesterday.",
          "the TO box's words: the own account says it moves Claude Code back (count once picked); another says its last use")
    // the card's menu takes the same rule from the profile's value (Launcher.switchMenu: ticks `named`, the own id, no second row)
    check(cardRow(both, now: now).show.ownStandbyID == "k1" && cardRow(both, now: now).show.named.label == u1.email
          && cardRow(both, now: now).entry.listed(by: cardRow(both, now: now).view).standby.filter { $0.id != cardRow(both, now: now).show.ownStandbyID }.map(\.id) == ["k2"],
          "the card's Switch account menu: u1 ticked once (the own id k1), ben on standby")
    // the full-limit offer: the own account is offered once and stays switchable (it is the profile's way back); the move
    // words are one string for every surface
    var onlyOwn = e; onlyOwn.standby = [k1]
    let ownOffer = onlyOwn.fullOffer(view: AccountView.of(Store.status(for: onlyOwn, now: now)), now: now)
    check(ownOffer?.key == backKey && ownOffer?.standby.seat != nil && SwitchOffer.moveBackWords == "move Claude Code back here",
          "fullOffer in a clash: the own account offered once, switchable")
    // the move-back's words: quick chat's line and key say Claude Code moves back to the own account (the menus' decision,
    // ProfileShow.ownStandbyID), the Switch page says cat stays with its own profile and never calls it a standby account
    let ownQC = QuickChatSwitchOffer.best(onlyOwn, now: now)
    check(ownQC?.own == true && ownQC?.lineWords(name: "Acc") == "Acc can move Claude Code back to its own account, \(u1Short)."
          && ownQC?.keyTitle == "Move Claude Code back…" && SwitchOffer.moveBackTitle(u1Short) == "Move Claude Code back to \(u1Short)…",
          "quick chat in a clash, the own account offered: it says Claude Code moves back: \(ownQC?.lineWords(name: "Acc") ?? "none")")
    let stays = SwitchPage.staysLine(from: "cat", name: "Acc", moveBack: true, owner: "Work")
    let staysNoOwner = SwitchPage.staysLine(from: "cat", name: "Acc", moveBack: true, owner: nil)
    let staysNormal = SwitchPage.staysLine(from: "ann", name: "Acc", moveBack: false, owner: "Work")
    check(stays == "cat stays with Work: nothing read here." && staysNoOwner == "cat stays with the profile it belongs to: nothing read here."
          && !stays.contains("standby") && !staysNoOwner.contains("standby") && !stays.contains("Acc")
          && staysNormal == "ann stays on Acc as a standby account: nothing read, switch back any time.",
          "the Switch page's move-back line: cat stays with its own profile (never Acc's standby); a normal switch unchanged: \(stays)")
    // the clash wording is reachable through the model: with no live numbers in a clash (liveCounts false) an offer comes only
    // from the record's own full level, and then it is the move-back one
    let qcModel = QuickChatModel()
    var clashTarget = QuickChatTarget(onlyOwn, now: now); clashTarget.liveCounts = false; clashTarget.split = false
    var fullLevel = QuickChatLevel(nil); fullLevel.week = 100; fullLevel.weekResets = now.addingTimeInterval(86400)
    qcModel.update(target: clashTarget, level: QuickChatLevel(nil), offer: { QuickChatSwitchOffer.best(onlyOwn, now: now) })
    check(qcModel.offer == nil, "a clash, no live numbers, the record's level not full: no offer")
    qcModel.update(target: clashTarget, level: fullLevel, offer: { QuickChatSwitchOffer.best(onlyOwn, now: now) })
    check(qcModel.blocked && qcModel.offer?.own == true && qcModel.offer?.key == backKey && qcModel.offer?.keyTitle == "Move Claude Code back…"
          && qcModel.offer?.lineWords(name: "Acc").contains("move Claude Code back to its own account") == true,
          "a clash, the record's own full level: the model offers the move-back (words reached through update): \(qcModel.offer?.lineWords(name: "Acc") ?? "none")")
    // the Switch page's remembered move-back is used only for its own switch, while one is under way or ended: not after a
    // Cancel (ready again), another pick, or another profile's page
    let started = SwitchPage.ClashBack(key: backKey, owner: "Work")
    check(SwitchPage.backNote(started, key: backKey, phase: .waiting) == started && SwitchPage.backNote(started, key: backKey, phase: .reached) == started
          && SwitchPage.backNote(started, key: backKey, phase: .ready) == nil,
          "a move-back's note: kept while the switch runs or ended, gone after a Cancel (ready again)")
    check(SwitchPage.backNote(started, key: AccountEntry.switchKey("acc", "k2"), phase: .waiting) == nil
          && SwitchPage.backNote(started, key: AccountEntry.switchKey("other", "k1"), phase: .reached) == nil
          && SwitchPage.backNote(nil, key: backKey, phase: .waiting) == nil,
          "a move-back's note: never for another pick or another profile's page (then a normal switch says its usual words)")
    check(SwitchPage.readyTitle(name: "Acc", to: "ann", moveBack: true) == "Move Claude Code back to ann"
          && SwitchPage.goTitle(to: "ann", moveBack: true) == "Move back to ann"
          && SwitchPage.readyTitle(name: "Acc", to: "ben", moveBack: false) == "Switch Claude Acc to ben"
          && SwitchPage.goTitle(to: "ben", moveBack: false) == "Switch to ben",
          "the Switch page's title and key: a clash move-back says Move back; a normal switch is unchanged")
    check(AccountCard.tickedTitle(label: "ann", plan: "max") == "ann  " + Account.planWords("max")
          && AccountCard.tickedTitle(label: "ann", plan: nil) == "ann",
          "the card's ticked account: its address and the plan it is given (ProfileShow.plan, none in a clash)")
    check(SwitchPage.phaseTitle(.ready, name: "Acc", to: "ann", moveBack: true) == "Move Claude Code back to ann"
          && SwitchPage.phaseTitle(.failed("x"), name: "Acc", to: "ann", moveBack: true) == "Switch Claude Acc to ann"
          && SwitchPage.phaseTitle(.timedOut, name: "Acc", to: "ann", moveBack: true) == "Switch Claude Acc to ann"
          && SwitchPage.phaseTitle(.undone, name: "Acc", to: "ann", moveBack: true) == "Switch Claude Acc to ann"
          && SwitchPage.phaseTitle(.reached, name: "Acc", to: "ann", moveBack: true) == "Switched Claude Acc to ann"
          && SwitchPage.phaseTitle(.waiting, name: "Acc", to: "ann", moveBack: true) == "Switching Claude Acc to ann",
          "the Switch page's title: only the ready one says Move Claude Code back; a failed, timed-out or undone move keeps the usual title")
    // outside a clash nothing changes: the active account is off the standby list, ticked with its week, no move words
    _ = Store.writeStatus("acc", rec())
    let calmQC = QuickChatSwitchOffer.best(both, now: now)
    check(calmQC?.own == false && calmQC?.keyTitle == "Switch account…" && calmQC?.lineWords(name: "Acc").hasPrefix("Acc can switch to its other account, ") == true
          && !(calmQC?.lineWords(name: "Acc").contains("move Claude Code") ?? true),
          "quick chat, no clash: the usual switch words: \(calmQC?.lineWords(name: "Acc") ?? "none")")
    let calmShow = ProfileShow.load(both, now: now), calmDock = dockOf(both, calmShow), calmBar = menuBarMenu(calmShow)
    check(calmShow.ownStandbyID == nil && ownRow(calmDock.menu) == nil && ownRow(calmBar) == nil
          && rowsOf(calmDock.menu, u1Short) == 1 && rowsOf(calmBar, u1Short) == 1 && !titles(calmDock.menu).contains(u1Short + "…")
          && titles(calmBar).contains { $0.hasPrefix(u1Short + " · week") } && !titles(calmBar).contains { $0.contains("move Claude Code") },
          "no clash: the active account ticked once with its week, off the standby list, no move words")
    _ = Store.writeStatus("acc", rec(login: u3.email, code: u3))
    // a record from before the id: by its name (the first profile so called)
    var byName = rec(login: u3.email, code: u3); byName.resolved?.clashID = nil
    let oldClash = surfaces(byName)
    check(oldClash.settings.elsewhere?.owner.name == "Other" && !oldClash.settings.inUseRow.lit, "a record from before the clash's id: by its name, unlit")
    // the clash's profile renamed since: still found by its id, and unlit; removed: no Open, still unlit (the value's lamp)
    var renamed = other; renamed.name = "Work"
    model.accounts = [e, twin, renamed]
    let renamedClash = surfaces(rec(login: u3.email, code: u3))
    check(renamedClash.settings.elsewhere?.owner.id == "other" && !renamedClash.settings.inUseRow.lit,
          "the clash's profile renamed: Open Work (by its id), unlit")
    model.accounts = [e, twin]
    let removed = surfaces(rec(login: u3.email, code: u3))
    check(removed.settings.elsewhere == nil && !removed.settings.inUseRow.lit && UsageNotice.of(removed.settings.inUseRow)?.tone == .red,
          "the clash's profile removed: no Open, still unlit and red (Settings lit before, the value off)")
    model.accounts = [e, twin, other]
    // the app decided the account in use (u2), Claude Code's folder on Other's: the app's u2 on the line
    let appClash = #"{"expectedEmail":"ultra-3@example.com","loginEmail":"ultra-3@example.com","resolved":{"account":"\#(u2.account)","at":1800000000,"clash":"Other","clashID":"other","differs":true,"email":"ultra-2@example.com","fromApp":true,"lit":true,"numbersFor":"ultra-3@example.com"},"state":"ok","updatedAt":\#(Int(now.timeIntervalSince1970) - 60),"weekly":40}"#
    let app = surfaces(StatusCodec.decode(Data(appClash.utf8))!)
    check(app.page.inUseRow.show.inUseLabel == u2.email && app.settings.popUpSignInAddress == u2.email && app.settings.elsewhere?.owner.id == "other",
          "a clash with the app's account in use: the line and Sign in… name the app's u2")

    // unconfirmed: as read, never full, said so in Settings and on the page
    var unsure = rec(week: 100); unsure.ownerUnconfirmed = true
    let us = surfaces(unsure)
    check(us.settings.inUseRow.line == Store.unconfirmedWords && us.settings.inUseRow.full == nil && us.page.inUseRow.line == Store.unconfirmedWords
          && us.page.inUseRow.weekly == nil && us.page.inUseRow.fiveHour == 12, "unconfirmed: the line says so, a full week left out")
    // standby never shown: the standby's own numbers nowhere in the in-use boxes, and it isn't listed in use
    var standbyRec = IconStatus(state: "ok"); standbyRec.loginEmail = u2.email; standbyRec.weekly = 77; standbyRec.updatedAt = now
    _ = Store.writeStatus("acc~k2", standbyRec)
    let withStandby = surfaces(rec())
    check(withStandby.settings.inUseRow.limits.allSatisfy { $0.p != 77 } && withStandby.page.inUseRow.limits.allSatisfy { $0.p != 77 }
          && e.standbyRows(by: withStandby.settings.view).map(\.id) == ["k2"], "standby: never its numbers in an in-use box, listed on standby once")
    Store.removeStatus("acc~k2")
    // no record: unlit, no numbers; the preview none either (not the samples)
    let none = surfaces(nil)
    check(!none.settings.inUseRow.lit && !none.page.inUseRow.lit && none.preview.weekly == nil && none.preview.fiveHour == nil && same(none.preview, none.panel),
          "no record: unlit, no numbers, the preview none (as the panel)")

    // the split: by hand (Sign in… to pat), the app's account by id only (no key, the pop-up's plain sign-in), the panel's
    // age line from when the numbers were read, though none show
    let pat = Seat(account: uuid(81), organization: uuid(181), email: "pat@example.com")
    let mo = Seat(account: uuid(82), organization: uuid(182), email: "mo@example.com")
    var s = profile("asp", "~/.claude-asp", mo); s.claudeWindow = true
    s.standby = [StandbyAccount(email: pat.email!, seat: pat, id: "kp", plan: "Max")]
    model.accounts = [s]; try! Store.save([s])
    func splitRec(_ app: AppSignIn.Login) -> IconStatus {
        var r = IconStatus(state: "ok"); r.loginEmail = mo.email; r.numbersOwner = mo.email; r.expectedEmail = mo.email
        r.weekly = 30; r.weeklyResets = now.addingTimeInterval(2 * 86400); r.noFiveHour = true; r.updatedAt = now.addingTimeInterval(-120)
        r.resolved = AccountResolver.resolve(s, among: [s], app: app, code: mo, loginEmail: mo.email, names: [:], now: now)
        return r
    }
    let split = surfaces(splitRec(AppSignIn.Login(account: pat.account, org: pat.organization, state: .known, source: "log", at: now)), s)
    check(split.panel.weekly == nil && abs((split.panel.updated?.timeIntervalSince(now) ?? 0) + 120) < 1 && split.panel.noNumbers == nil
          && split.settings.inUseRow.lit && UsageNotice.of(split.settings.inUseRow)?.key == .signIn && split.settings.popUpSignInAddress == pat.email
          && same(split.preview, split.panel) && split.preview.splitKey != nil,
          "the split: the panel's age line says when (not Reading usage…), Settings lit with Sign in… to pat, the preview as the panel")
    let anon = surfaces(splitRec(AppSignIn.Login(account: uuid(83), org: uuid(183), state: .known, source: "log", at: now)), s)
    check(UsageNotice.of(anon.settings.inUseRow)?.key == UsageNotice.Key.none && anon.settings.popUpSignInAddress == nil && same(anon.preview, anon.panel),
          "the split with the app's account by id only: no Sign in… in Settings' box, the pop-up's plain sign-in (never mo's)")
    // Settings' red box's keys as the view draws them (inUseKeys): the value's key, Open only on a clash; none, no row
    // (the views read the saved record when asked: each record is written again before its view is asked)
    let anonKeys = anon.settings.inUseKeys
    let byHandKeys = surfaces(splitRec(AppSignIn.Login(account: pat.account, org: pat.organization, state: .known, source: "log", at: now)), s).settings.inUseKeys
    check(!anonKeys.signIn && anonKeys.open == nil && byHandKeys.signIn && byHandKeys.open == nil,
          "Settings' red box: the split by id only has no key and no Open (no empty row); by hand, Sign in…")
    model.accounts = [e, twin, other]; try! Store.save([e, twin, other])
    check(!surfaces(rec()).settings.inUseKeys.signIn && surfaces(rec("expired")).settings.inUseKeys.signIn
          && !surfaces(rec("denied", week: nil, five: nil)).settings.inUseKeys.signIn,
          "Settings' box keys by state: none when fresh, Sign in… when expired, none (amber, Refresh now) when it can't be read")
    model.accounts = [e, twin]
    let gone = surfaces(rec(login: u3.email, code: u3))
    check(gone.settings.inUseKeys.signIn && gone.settings.inUseKeys.open == nil, "a clash whose profile was removed: Sign in…, no Open")
    // a standby box says when it was last in use, never numbers (even with a last week remembered)
    var remembered = e.standby[0]; remembered.lastWeek = 77; remembered.lastWeekResets = now.addingTimeInterval(86400)
    let words = surfaces(rec()).settings.standbyWords(remembered, name: "Acc")
    check(words == "Last in use on Acc " + AccountBook.ago(remembered.lastInUse!) && !words.contains("%") && !words.contains("77"),
          "Settings' standby box: its last use only, never numbers: \(words)")
    Store.removeStatus("acc"); Store.removeStatus("asp")
    try? Store.save([])
}

// ============ 14. the Switch page: what a switch leaves behind, said before Switch is pressed ("Will stay with") and after ("Left with") ============
do {
    var p = SwitchPlan(profile: "sw", standby: "k2", dataDir: "/x", codeDir: "/y", from: u1, to: u2)
    p.odd = [.unknownName, .link]
    let rest = "2 files named like a Code-tab session that aren't one (a link, a file not named by an id)."
    let will = "Will stay with \(AccountNames.short(u1.email!)): " + rest, left = "Left with \(AccountNames.short(u1.email!)): " + rest
    check(SwitchPage.leftBefore(p, started: false) == will, "before Switch: the plan's files that will stay, in the future tense: \(SwitchPage.leftBefore(p, started: false) ?? "nil")")
    var none = p; none.odd = []
    check(SwitchPage.leftBefore(p, started: true) == nil && SwitchPage.leftBefore(nil, started: false) == nil
          && SwitchPage.leftBefore(none, started: false) == nil, "once started the runner's leftNote says it; no plan or none left: no line")
    // the runner keeps them apart from the rest of its note: "Left with …" in the past tense, never in stayWords
    check(SwitchRunner.leftBehind(p) == left && SwitchRunner.stayWords(p) == nil && SwitchRunner.leftBehind(none) == nil,
          "the runner's leftNote is the past tense, apart from its other note: \(SwitchRunner.leftBehind(p) ?? "nil")")
    // after a switch that moved nothing: no left-behind line (a flag, not a string match); after a move, as it is
    check(SwitchPage.leftShown(left, movedNothing: true) == nil && SwitchPage.leftShown(left, movedNothing: false) == left && SwitchPage.leftShown(nil, movedNothing: false) == nil,
          "a failed switch that moved nothing: the left-behind line hidden; a switch that moved: shown")
    // the plan card's line: "Will stay with" until something moved (a receipt), also while closing and after a Cancel back
    // to Ready (during Closing, and while waiting when the plan moved nothing); "Left with" once it moved
    let rr = SwitchRunner(profile: "sw", model: SettingsModel())
    func cardLeft() -> String? { SwitchPage.leftInPlan(left: rr.leftNote, moved: rr.receipt != nil, plan: rr.planned) }
    rr.preview(.closing, goal: nil, planned: p, left: SwitchRunner.leftBehind(p))
    check(cardLeft() == will, "closing: the card still says Will stay with: \(cardLeft() ?? "nil")")
    rr.cancel()
    check(rr.phase == .ready && cardLeft() == will, "Cancel during Closing: back at Ready, Will stay with (nothing moved)")
    rr.preview(.waiting, goal: nil, planned: p, left: SwitchRunner.leftBehind(p))
    rr.cancel()
    check(rr.phase == .ready && cardLeft() == will, "Cancel while waiting, the plan moved nothing: Will stay with")
    var receipt = SwitchReceipt(id: SwitchEngine.receiptID(Date(), "sw"), profile: "sw", standby: "k2", dataDir: "/x", from: SeatID(u1), to: SeatID(u2), started: Date())
    receipt.steps = []
    rr.preview(.waiting, goal: nil, planned: p, receipt: receipt, left: SwitchRunner.leftBehind(p))
    check(cardLeft() == left, "after a move: Left with: \(cardLeft() ?? "nil")")
    var held = p; held.held = ["s1"]
    check(SwitchRunner.stayWords(held) == SwitchRunner.heldWords(1) && SwitchPage.noteLine(SwitchRunner.stayWords(held), SwitchPage.leftShown(left, movedNothing: true)) == SwitchRunner.heldWords(1)
          && SwitchPage.noteLine(SwitchRunner.stayWords(held), left) == SwitchRunner.heldWords(1) + " " + left && SwitchPage.noteLine(nil, nil) == nil,
          "…the rest of the note stays (a session a running Claude Code holds), then the left-behind line when something moved")
    // a session held because its record can't be read: said apart, never "Claude Code is running it"
    var unread = p; unread.held = ["s1", "s2"]; unread.unreadable = ["s2"]
    check(SwitchRunner.stayWords(unread) == SwitchRunner.heldWords(1) + " " + SwitchRunner.unreadableWords(1)
          && SwitchRunner.unreadableWords(1) == "1 session stays with the account in use: its record couldn't be read. A later switch moves it once it can be read.",
          "one owned, one unreadable: each said in its own words: \(SwitchRunner.stayWords(unread) ?? "nil")")
    // a partial Undo names what stayed by kind and count, never by file name
    var partly = receipt; partly.partlyUndone = Date()
    partly.left = ["local_\(uuid(1301)).json", "local_\(uuid(1302)).json", "scheduled-tasks.json"]
    let partlyLine = SwitchRunner.partlyWords(partly)
    check(partlyLine == "Partly undone: 2 Code-tab sessions and the scheduled tasks file were left as they were. The rest is back; Undo again once that's sorted."
          && !partlyLine.contains("local_") && !partlyLine.contains(".json"),
          "Partly undone: what kind, how many: \(partlyLine)")
    partly.left = ["local_\(uuid(1303)).json"]
    check(SwitchRunner.partlyWords(partly) == "Partly undone: 1 Code-tab session was left as it was. The rest is back; Undo again once that's sorted.",
          "one: \(SwitchRunner.partlyWords(partly))")
}

// ============ 15. one owner rule in the resolver and the lists (AccountIdentity.sameAccount) ============
do {
    // ids with letters, so a case can differ (uuid(n) has none)
    func hx(_ n: Int, _ email: String?, org: String? = nil) -> Seat {
        Seat(account: "00000000-0000-4000-8000-0000000000a\(n)", organization: org ?? "00000000-0000-4000-8000-0000000000b\(n)", email: email)
    }
    func upper(_ s: Seat) -> Seat { Seat(account: s.account.uppercased(), organization: s.organization?.uppercased(), email: s.email) }
    let h1 = hx(1, "hex-1@example.com"), h2 = hx(2, "hex-2@example.com")
    let otherOrg = hx(1, h1.email, org: "00000000-0000-4000-8000-0000000000c1"), otherID = Seat(account: "00000000-0000-4000-8000-0000000000d1", organization: h1.organization, email: h1.email)
    let me = profile("hme", "~/.claude-hme", h2)
    var them = profile("hthem", "~/.claude-hthem", h1); them.claudeWindow = false
    func clash(_ code: Seat, _ owner: AccountEntry = them) -> String? {
        AccountResolver.resolve(me, among: [me, owner], app: .unknown, code: code, loginEmail: code.email, names: [:], now: t0).clash
    }
    // the clash owner: another profile's account in use
    check(clash(upper(h1)) == "Hthem", "clash: another profile's account in use, ids in another case")
    check(clash(Seat(account: h1.account, organization: "", email: h1.email), profile("hnil", "~/.claude-hnil", Seat(account: h1.account, organization: nil, email: h1.email))) == "Hnil",
          "clash: no organisation (nil) and an empty one: the same account")
    check(clash(otherOrg) == nil && clash(otherID) == nil, "clash: the same address in another organisation, or another id: another account, never the address")
    // the Claude app's account among the profile's (`mine`), differs and the switch waiting for the app: by the id (the app
    // names no organisation for certain, so a seat's is left out)
    var sw = profile("hsw", "~/.claude-hsw", upper(h2)); sw.standby = [StandbyAccount(email: h1.email!, seat: upper(h1), id: "k1")]
    let appH1 = AppSignIn.Login(account: h1.account, org: h1.organization, state: .known, source: "log", at: t0)
    let appH2 = AppSignIn.Login(account: h2.account, org: nil, state: .known, source: "config", at: nil)
    let same = AccountResolver.resolve(sw, among: [sw], app: appH2, code: h2, loginEmail: nil, names: [:], now: t0)
    check(same.email == h2.email && !same.differs && same.fromApp, "mine: the app's id against a seat with its ids in another case, the app's organisation not known: that seat")
    let noAddr = AccountResolver.resolve(sw, among: [sw], app: appH2, code: otherID, loginEmail: nil, names: [:], now: t0)
    check(noAddr.differs, "differs, no address to compare: by the ids, another id is another account (never the address)")
    var toH2 = SwitchReceipt(id: SwitchEngine.receiptID(t0, "hsw"), profile: "hsw", standby: "k2", dataDir: "/x",
                             from: SeatID(account: h1.account.uppercased(), organization: h1.organization!.uppercased()), to: SeatID(h2), started: t0)
    toH2.linked = t0
    let waits = AccountResolver.resolve(sw, among: [sw], app: appH1, code: h2, loginEmail: h2.email, names: [:], newestSwitch: toH2, now: t0)
    check(waits.differs && waits.email == h1.email && waits.switchWaits == true, "a switch waiting for the app: the switch's from, ids in another case, is the app's account")
    var fromOther = toH2; fromOther.from = SeatID(otherID)
    check(AccountResolver.resolve(sw, among: [sw], app: appH1, code: h2, loginEmail: h2.email, names: [:], newestSwitch: fromOther, now: t0).switchWaits == nil,
          "…from another id with the app's address: not that switch")
    // stale and differs with empty addresses: the plain comparison, as before (two empty ones never make a reading stale)
    let empty = Seat(account: h2.account, organization: h2.organization, email: "")
    let bothEmpty = AccountResolver.resolve(me, among: [me], app: .unknown, code: empty, loginEmail: "", names: [:], now: t0)
    check(bothEmpty.readStale == nil && !bothEmpty.differs, "an empty reading address and an empty folder address: not stale, no split")
    let oneEmpty = AccountResolver.resolve(me, among: [me], app: .unknown, code: empty, loginEmail: h2.email, names: [:], now: t0)
    check(oneEmpty.readStale == true, "one address empty, the other not: stale, as before")
    check(AccountResolver.sameAddress("", "") && !AccountResolver.sameAddress("", "x@example.com") && AccountResolver.sameAddress("X@example.com", "x@example.com"),
          "sameAddress: empty ones by the plain comparison, else the address-only rule")
    // Claude Code's record names an id but no address (ClaudeFiles.Record.seat keeps a missing emailAddress as nil). A reading
    // with its account's id (the profile reply's account.uuid, ReaderMachine.numbersAccount) is known by the id: the folder's
    // own shows, another id stays stale. A reading known by its address only: whose the numbers are isn't known, so they are
    // stale (shown nowhere), never labelled with the reading's address, and one line says why on every surface
    let idOnly = Seat(account: h2.account, organization: h2.organization, email: nil), foreign = "hex-9@example.com"
    let otherAcct = "00000000-0000-4000-8000-0000000000e9"
    func shownWeekly(_ r: ResolvedAccount, id: String? = nil) -> Double? {
        var rec = IconStatus(state: "ok"); rec.loginEmail = r.numbersFor; rec.numbersOwner = r.numbersFor; rec.numbersAccount = id
        rec.weekly = 40; rec.updatedAt = t0; rec.resolved = r
        _ = Store.writeStatus(me.id, rec)
        return Store.status(for: me, now: t0)?.weekly
    }
    let short8 = "account \(h2.account.prefix(8))"
    let own = AccountResolver.resolve(me, among: [me], app: .unknown, code: idOnly, loginEmail: h2.email, loginAccount: h2.account.uppercased(),
                                      names: [:], now: t0)
    check(own.readStale == nil && !own.differs && own.email == h2.email && own.line != AccountResolver.ownerUnknownWords
          && shownWeekly(own, id: h2.account.uppercased()) == 40,
          "folder {id, no address} + a reading with the folder's id (any case): the profile's numbers show, named by the reading's address")
    let elseID = AccountResolver.resolve(me, among: [me], app: .unknown, code: idOnly, loginEmail: foreign, loginAccount: otherAcct, names: [:], now: t0)
    check(elseID.readStale == true && elseID.email == nil && elseID.line != AccountResolver.ownerUnknownWords
          && shownWeekly(elseID, id: otherAcct) == nil,
          "folder {id, no address} + a reading with another id: stale, shown nowhere (another account, said as before)")
    let sameAddrOtherID = AccountResolver.resolve(me, among: [me], app: .unknown, code: h2, loginEmail: h2.email, loginAccount: otherAcct, names: [:], now: t0)
    check(sameAddrOtherID.readStale == nil && !sameAddrOtherID.differs && sameAddrOtherID.email == h2.email
          && sameAddrOtherID.line != AccountResolver.ownerUnknownWords && shownWeekly(sameAddrOtherID, id: otherAcct) == 40,
          "the ids' guard: folder {id, address} + a reading for that address with another id: the same address keeps it (no split)")
    let bothOther = AccountResolver.resolve(me, among: [me], app: .unknown, code: h2, loginEmail: foreign, loginAccount: otherAcct, names: [:], now: t0)
    check(bothOther.readStale == true && bothOther.codeName == h2.email && shownWeekly(bothOther, id: otherAcct) == nil,
          "…another id and another address: stale, shown nowhere")
    // …and the way back shows where the reason does: the card, the Dock panel and menu, the menu bar row (its record is the
    // one shownWeekly just wrote); the Dock panel's age line says they aren't this account's, never "Reading usage…"
    let staleShow = ProfileShow.load(me, now: t0)
    let (staleNote, staleMenu, staleAge) = MainActor.assumeIsolated { let d = dockOf(me, staleShow); return (d.panel.activeNote, titles(d.menu), d.panel.noNumbers) }
    let staleLine = AccountResolver.staleWords
    check(bothOther.line == staleLine && cardRow(me, now: t0).line == staleLine && staleNote == staleLine && staleMenu.contains(staleLine)
          && MenuBarRow.lineWords(MenuBarItems.Profile(show: staleShow)) == staleLine && staleLine.contains("sign in to read again") && staleLine.count <= 70
          && staleAge == "Not read for this account",
          "a stale reading: \"\(staleLine)\" on the card, in the Dock panel and menu, on the menu bar row; the age line: \(staleAge ?? "-")")
    let lone = AccountResolver.resolve(me, among: [me], app: .unknown, code: idOnly, loginEmail: foreign, names: [:], now: t0)
    let loneWeekly = shownWeekly(lone), loneShow = ProfileShow.load(me, now: t0)
    let (loneNote, loneMenu) = MainActor.assumeIsolated { let d = dockOf(me, loneShow); return (d.panel.activeNote, titles(d.menu)) }
    let words = AccountResolver.ownerUnknownWords
    check(lone.readStale == true && !lone.differs && lone.email == nil && lone.account == h2.account && lone.numbersFor == foreign
          && lone.codeName == short8 && lone.line == words && loneWeekly == nil
          && AccountView.of(Store.status(for: me, now: t0)).label == short8,
          "folder {id, no address} + a reading with an address and no id, no app: stale, numbers shown nowhere, never labelled with the reading's address")
    check(cardRow(me, now: t0).line == words && loneNote == words && loneMenu.contains(words)
          && MenuBarRow.lineWords(MenuBarItems.Profile(show: loneShow)) == words && words.contains("sign in")
          && words.count <= "Claude Code's .claude.json is too large to read: its account isn't known here.".count,
          "…and the reason shows: on the card, in the Dock panel and menu, on the menu bar row (sign in, the sweep's verb), no longer than the too-large line those rows show")
    let loneChat = QuickChatTarget(me, now: t0)
    check(!loneChat.liveCounts && !loneChat.split && loneChat.account?.account == AccountID.normal(h2.account)
          && loneChat.email != foreign && loneChat.shownEmail != foreign,
          "…quick chat: the folder's seat by its id, its live numbers never count, the reading's address never named")
    let appOnIt = AccountResolver.resolve(me, among: [me], app: appH2, code: idOnly, loginEmail: foreign, names: [:], now: t0)
    check(appOnIt.readStale == true && !appOnIt.differs && appOnIt.fromApp && appOnIt.email == h2.email && appOnIt.line == words
          && shownWeekly(appOnIt) == nil,
          "…the Claude app on the folder's account: stale too, no split with the reading's numbers, the same reason")
    let mute = AccountResolver.resolve(me, among: [me], app: .unknown, code: idOnly, loginEmail: nil, names: [:], now: t0)
    check(mute.readStale == nil && mute.email == nil && mute.codeName == short8 && mute.line != words,
          "folder {id, no address} + a reading that names no account (the status line): not stale, as before")
    // unchanged: ids and addresses on the folder's side and a reading without an id (its address decides), and no folder seat
    let both = AccountResolver.resolve(me, among: [me], app: .unknown, code: h2, loginEmail: "HEX-2@example.com", names: [:], now: t0)
    check(both.readStale == nil && !both.differs && both.email == h2.email && shownWeekly(both) == 40,
          "folder {id, address} + a reading for that address: the profile's numbers, as before")
    let bothIDs = AccountResolver.resolve(me, among: [me], app: .unknown, code: h2, loginEmail: h2.email, loginAccount: h2.account, names: [:], now: t0)
    check(bothIDs.readStale == nil && !bothIDs.differs && bothIDs.email == h2.email && shownWeekly(bothIDs, id: h2.account) == 40,
          "folder {id, address} + a reading with that id and address: the profile's numbers")
    let moved = AccountResolver.resolve(me, among: [me], app: .unknown, code: h2, loginEmail: foreign, names: [:], now: t0)
    check(moved.readStale == true && moved.email == h2.email && moved.codeName == h2.email && moved.line != words && shownWeekly(moved) == nil,
          "folder {id, address} + another address's reading: stale, as before")
    let noSeat = AccountResolver.resolve(me, among: [me], app: .unknown, code: nil, loginEmail: foreign, names: [:], now: t0)
    check(noSeat.readStale == nil && noSeat.email == foreign && noSeat.numbersFor == foreign && shownWeekly(noSeat) == 40,
          "no folder seat, a reading's address only: the reading names the account, as before")
    // the record's new field: an older record (no numbersAccount) decodes, with no id; a new one keeps it
    let olderRec = StatusCodec.decode(Data(#"{"state":"ok","numbersOwner":"hex-2@example.com","weekly":40}"#.utf8))
    var withID = IconStatus(state: "ok"); withID.numbersOwner = h2.email; withID.numbersAccount = h2.account
    let back = StatusCodec.encode(withID).flatMap(StatusCodec.decode)
    var noOwner = withID; noOwner.numbersOwner = nil
    check(olderRec?.numbersOwner == h2.email && olderRec?.numbersAccount == nil && olderRec?.readingAccount == nil
          && back?.numbersAccount == h2.account && back?.readingAccount == h2.account && noOwner.readingAccount == nil,
          "status record: an older one decodes without the reading's id; a new one keeps it; no id without the reading's owner")
    // the lists' helpers: the record names ids and addresses, no organisation
    let v = AccountView(label: h1.email, numbersOwner: h2.email, line: nil, lit: true, clash: nil, account: h1.account, differs: true, codeAccount: h2.account)
    check(v.isActive(StandbyAccount(email: "", seat: upper(h1), id: "a")) && v.isActive(StandbyAccount(email: "HEX-1@example.com", id: "b"))
          && v.isActive(StandbyAccount(email: h1.email!, seat: otherOrg, id: "c")) && !v.isActive(StandbyAccount(email: h1.email!, seat: otherID, id: "d")),
          "isActive: ids in any case; an address only by the address; the record names no organisation; another id never by the address")
    check(v.isCodeRow(id: h2.account.uppercased(), email: nil) && v.isCodeRow(id: nil, email: "HEX-2@example.com") && !v.isCodeRow(id: otherID.account, email: h2.email),
          "isCodeRow: by the id in any case, else the address; another id never by the address")
}

print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
