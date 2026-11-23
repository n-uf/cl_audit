// Surfaces checks for cl_audit: one answer about each profile's account (Sources/AccountResolver.swift), written once into its
// status record, and every screen reading it alike: the menu bar, the Dock icon's menu and panel, the dashboard card, Settings ▸
// Accounts and the Switch page. Also the Claude app's account (Sources/AppSignIn.swift): its
// config.json names the account, its log gives the organisation and whether it signed out (an account switched in place and
// back included; the log's own account line without config.json); old numbers never shown (a stale status line, a passed
// reset, an expired sign-in); a deleted folder never made again (FolderGuard), and no screen reading the sign-in files itself.
//
// Runs only with HOME and CFFIXED_USER_HOME = .../Checks/.work/surfaces/home (Checks/run.sh sets and guards it). Fake data only:
// example.com addresses, zero-pattern ids, made-up log lines and config.json files in the throwaway home. Nothing here opens
// an app, the Dock or Terminal, and nothing touches the Keychain.

import AddressPrivacy
import AppKit
import ClaudeAuth
import MenuRows
import ProfileCore
import Runs
import SwiftUI

setbuf(stdout, nil)
// a throwaway home: no running cl_audit or agent is told (a distributed notice isn't home-scoped; a check build stops if unset)
Store.announce = {}; Store.announceStatus = { _ in }
let home = NSHomeDirectory()
guard home.hasSuffix("/Checks/.work/surfaces/home"), expand("~") == home else { print("refusing: HOME is \(home)"); exit(2) }
AddressPrivacy.shared.apply(blur: false)     // Show emails on, as every suite reads addresses in clear unless it tests the setting (nothing is written)
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
/// The Dock panel of a profile as the Dock icon builds it (IconApp's detailsInfo), for the blocks that aren't main-actor isolated.
func dockPanelOf(_ e: AccountEntry, _ s: ProfileShow) -> DetailsInfo { MainActor.assumeIsolated { dockOf(e, s).panel } }
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
    // a sign-out undone by the app's sessions starting again for the same account (no loggedOut → false line, config.json older)
    let reinit = home("a2-reinit", log: story + ["\(at(400)) [info] [LocalSessionManager] Account logged out",
                                                 "\(at(420)) [info] [LocalSessionManager] Initialization succeeded in 8ms, accountId=\(a), orgId=\(oa), sessions=2"], config: a)
    check(read(reinit).state == .known && read(reinit).account == a && read(reinit).org == oa,
          "signed out, then a newer Initialization succeeded for config.json's account: signed in to it again")
    let reeval = home("a2-reeval", log: story + ["\(at(400)) [info] [account] Login-state transition (loggedOut: false \u{2192} true, loading: false)",
                                                 "\(at(420)) [info] [sessions-bridge] identity reevaluate: <none> \u{2192} \(oa):\(a)"], config: a)
    check(read(reeval).state == .known, "signed out, then a newer identity reevaluate to config.json's account: signed in again")
    let otherInit = home("a2-otherinit", log: story + ["\(at(400)) [info] [LocalSessionManager] Account logged out",
                                                       "\(at(420)) [info] [LocalSessionManager] Initialization succeeded in 8ms, accountId=\(b), orgId=\(ob), sessions=0"], config: a)
    check(read(otherInit).state == .loggedOut, "…a newer Initialization succeeded for another account: still signed out of config.json's")
    let lookupOnly = home("a2-lookuponly", log: story + ["\(at(400)) [info] [LocalSessionManager] Account logged out",
                                                         "\(at(420)) [info] [oauth-v2] lookup orgId=\(oa) cacheKey=acct:\(a)"], config: a)
    check(read(lookupOnly).state == .loggedOut, "…only an oauth-v2 lookup after it: still signed out")
    let sameStamp = home("a2-samestamp", log: story + ["\(at(400)) [info] [LocalSessionManager] Initialization succeeded in 8ms, accountId=\(a), orgId=\(oa), sessions=2",
                                                       "\(at(400)) [info] [LocalSessionManager] Account logged out"], config: a)
    check(read(sameStamp).state == .loggedOut, "…an init line in the same instant as the sign-out (not after it): still signed out")
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
    let rootLinked = home("a2-rootlinked", log: Array(story[1...2]), config: a)
    try? fm.createSymbolicLink(atPath: rootLinked.data + "/claude-code-sessions", withDestinationPath: noLine.data + "/claude-code-sessions")
    check(read(rootLinked).org == nil && read(rootLinked).account == a && AppSignIn.sessionsOrg(dataDir: rootLinked.data, account: a) == nil
          && AppSignIn.sessionsOrg(dataDir: noLine.data, account: a) == uuid(402),
          "claude-code-sessions itself a link (to a folder with A's organisations): not followed, no organisation")
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
    check(diff.email == u2.email && diff.differs && diff.numbersFor == u1.email && diff.line == nil && diff.codeUsageLine == true && diff.lineText()?.hasPrefix("Usage: Claude Code on ") == true && diff.lit,
          "the app on u2 (a standby account), Claude Code on u1: u2 in use, the numbers say they are Claude Code's on u1")
    let out = res(main, appOut, code: u1, numbers: u1.email)
    check(!out.fromApp && out.email == u1.email && out.line?.contains("signed out") == true, "the app signed out: Claude Code's account, with a muted line")
    var noWin = main; noWin.claudeWindow = false
    check(res(noWin, appU2, code: u1, numbers: u1.email).line == nil && !res(noWin, appU2, code: u1, numbers: u1.email).fromApp, "no Claude window: Claude Code's account, nothing to say")
    let shared = res(main, .unknown, code: u3, numbers: u3.email)
    // (no line of its own: the one a window with the app unknown has for any account)
    check(shared.clash == nil && shared.clashID == nil && shared.line == res(main, .unknown, code: u1, numbers: u1.email).line
          && shared.lit && shared.email == u3.email,
          "shared seats: Claude Code's folder on another profile's account in use: its numbers are this profile's too, no clash, lamp on")
    // a read from just before the folder's sign-in changed: the app signed out, the folder already on a free account, the
    // numbers still u1's: labelled with the address they were read for
    // (the read from before the sign-in changed: its sign-in isn't the kept one, so Anthropic's reply for it is no verified word)
    let late = AccountResolver.resolve(main, among: [main, other], app: appOut, code: Seat(account: uuid(9), organization: uuid(109), email: "free@example.com"),
                                       loginEmail: u1.email, readingVerified: false, names: [:], now: t0)
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
                              var v = row.view; v.label = row.needsLogin ? v.label : row.subtitle; return v }()),
            ("Settings", AccountSettings(entry: .constant(main), model: model).view),
            ("Switch page", SwitchPage(entry: main, standby: main.standby[0], model: model, runner: model.runner(of: main.id)).view)]
        for (s, v) in views { check(v == want, "\(name): \(s) agrees on the account, the numbers' owner and the line") }
        // the Dock panel from the one value (each case here is signed in and readable: the lamp is the record's)
        let panel = dockPanelOf(main, ProfileShow.load(main))         // (through the Dock app's own detailsInfo, as the Dock icon builds it)
        let splitHere = ProfileShow.load(main).display.split != nil
        // (every surface names the record's account in use; another profile's account is this one's too: shared seats)
        // (the split by hand: the Dock panel names Terminal's account, "· Terminal", as the sketch draws it)
        let splitByHand = panel.splitLink != nil
        let named = splitByHand ? ProfileShow.load(main).splitWords?.code : want.label
        let mainShow = ProfileShow.load(main)
        check(panel.accountLine.text == named && (panel.activeNote == want.line || splitHere) && panel.activeLit == want.lit
              && (panel.activeWho == "· Terminal") == splitByHand,
              "\(name): the Dock panel agrees (as drawn: \(panel.accountLine.text))")
        // (the menu bar menu's ticked row: the account in use, whole; the Dock menu lists no account)
        let barLines = DockTileMenu.lines(DockTileMenu.rows(main, mainShow, windowOpen: false, header: false), blur: false)
        let dockLines = DockTileMenu.lines(DockTileMenu.rows(main, mainShow, windowOpen: false), blur: false)
        // (the menu's tick and the view's in-use line are the account in use, the Claude app's in the split too; only the drawn row,
        // card and Dock panel name Terminal's account, "· Terminal", so `named` is not the menu's)
        check((want.label.map { n in barLines.contains { $0.hasPrefix("✓ " + n) } } ?? !barLines.contains { $0.hasPrefix("✓ ") })
              && !dockLines.contains { $0.hasPrefix("✓ ") }
              && mainShow.view.inUseLine == want.label.map(AccountNames.short),
              "\(name): the menu bar menu ticks the account in use and agrees with the view's line, the Dock menu has no account (\(barLines))")
        // (in the split the surfaces name Terminal's account, "· Terminal", so its numbers show there too: Store.ages opts in to
        // cl_kit's splitShowsNumbersOwner; each case here reads the folder's own account, so none is stale)
        check(Store.status(for: main)?.weekly == 40,
              "\(name): the record's own numbers show, in the split too (Terminal's, under its name): \(splitHere)")
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
            check(!activeOnStandby && !menuKeys.contains(k2) && !trayKeys.contains(k2) && main.fullOffer()?.key != k2,
                  "\(name): u2 (in use) is on no standby list: Settings, card trays, Dock and menu bar menus, Switch account ›, and never the full-limit offer")
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
    // Core and Auth are the vendored cl_kit tag's (Vendor/CL_KIT names it)
    let kitTag = ((try? String(contentsOf: root.appendingPathComponent("Vendor/CL_KIT"), encoding: .utf8)) ?? "")
        .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? "missing"
    let kit = root.appendingPathComponent("Vendor/cl_kit-\(kitTag)")
    for dir in ["Sources", "Widget", "Launcher", "Core", "Auth"] {
        let base = (["Core", "Auth"].contains(dir) ? kit : root).appendingPathComponent(dir)
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
        // (openLogin or startLogin, and the sign-in window ClaudeSignIn runs: SignInWindow.start, named with the function it is in)
        var inFunc = ""
        for l in t.components(separatedBy: "\n") {
            if let r = l.range(of: #"func (\w+)"#, options: .regularExpression) { inFunc = String(l[r].dropFirst(5)) }
            if (l.contains("openLogin(") || l.contains("startLogin(")) && l.contains("creating: true") { creators.append(f) }
            if l.contains("SignInWindow.start(") && l.contains("creating: true") { creators.append("\(f):\(inFunc)") }
        }
    }
    // (New profile's two Sign in keys are SettingsModel.startNewSignIn's one call: the window's only creating start)
    check(Set(creators) == ["Settings.swift:startNewSignIn", "FirstRun.swift", "DefaultProfileRunner.swift"] && creators.count == 3,
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
        let mb = MenuBarItems.Profile(show: show)
        let glyph = MenuBarItems.item(mb, now: now)
        check(mb.usage == nil && glyph.week == nil && glyph.five == nil && glyph.countdown == nil && show.needsLogin
              && show.display.key == .logIn && !show.display.lamp && show.display.grey,
              "\(what): the menu bar has no bars, no countdown, the Sign in key, the lamp off")
        let row = cardRow(p, now: now)
        check(row.limits.allSatisfy { $0.p == nil } && row.full == nil && row.needsLogin && row.subtitle == "sign-in expired",
              "\(what): the card (and Settings' in-use box, which draws its limits) says sign-in expired, no bars, Sign in…")
        check(previewShowsNone(p, rec) && panelShowsNone(p, rec), "\(what): the Dock icon's preview and Settings' panel preview have no numbers, never the samples")
        let panel = dockPanelOf(p, show)         // (through the Dock app's own detailsInfo, as the Dock icon builds it)
        check(panel.weekly == nil && panel.fiveHour == nil && panel.needsLogin && !panel.activeLit, "\(what): the Dock panel has no numbers, Sign in…, the lamp off")
        check(panel.noNumbers == "Sign-in expired", "\(what): the Dock panel's age line says Sign-in expired, never Reading usage…")
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
        let mb = MenuBarItems.Profile(show: show)
        let glyph = MenuBarItems.item(mb, now: now)
        check(mb.usage == nil && glyph.week == nil && glyph.five == nil && show.needsLogin && !show.display.lamp,
              "\(what): the menu bar has no bars, Sign in…, the lamp off")
        let row = cardRow(p, now: now)
        check(row.limits.allSatisfy { $0.p == nil } && row.needsLogin && row.subtitle == "no Claude Code sign-in",
              "\(what): the card and Settings' box: no bars, its state line, Sign in…")
        check(previewShowsNone(p, rec) && panelShowsNone(p, rec), "\(what): the Dock icon's preview and Settings' panel preview have no numbers, never the samples")
        check(rec?.needsLogin == true && rec?.fiveHour == nil && show.noNumbersWords == "Signed out",
              "\(what): the Dock panel (from the same record): no numbers, Sign in…, its age line says Signed out")
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
    check(Usage.of(back)?.weekly == 64 && cardRow(p).weekly == 64 && !cardRow(p).needsLogin,
          "…on the menu bar and the card alike, without Sign in…")
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
                        "Dock.swift"]
    // the sign-in files, and the folder's address read from .claude.json (`Account.expectedEmail(configDir:)` and the `expectedEmail()`
    // that calls it): a screen takes the expected address from the status record (`status.expectedEmail`)
    let fileReads = [".claude.json", "config.json", "main.log", "Logs/Claude", "claudeJSON(", "signedInSeat(", "lastKnownAccountUuid",
                     "expectedEmail(", "FolderFactsCache", "inUseElsewhere", "AppSignIn.", "ClaudeFiles."]
    let forbidden = fileReads + ["entry.seat", "e.seat?.", "profile.entry.seat"]
    var reads: [String] = []
    for f in surfaceFiles {
        let lines = (try? String(contentsOf: src.appendingPathComponent(f), encoding: .utf8))?.components(separatedBy: "\n") ?? ["(missing \(f))"]
        if lines == ["(missing \(f))"] { reads.append(lines[0]) }      // a surface file that isn't there is a finding of its own (no pattern matches the placeholder)
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
                      ("Settings.swift", "var inUseBox: some View", "    /// Sign in… on the account in use"),
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
        ("Config.swift", "static func startLogin(", ".startSignIn(", "login"),
        ("SignInWindow.swift", "static func start(", "run.start(", "the sign-in window"),            // (ClaudeSignIn: the guard once, then its own)
        ("Launcher.swift", "static func openClaude(", "openApplication(", "the Claude window"),
        ("Launcher.swift", "private static func openTerminal(", "Installer.run(", "Terminal"),
        ("Reader.swift", "private func ask(generation", "Self.askSeam(", "the short ask")]
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
    check(launchSites.allSatisfy { s in ["Config.swift", "Launcher.swift"].contains { s.hasPrefix($0) } },
          "every place that hands a folder to claude is one of the guarded launchers: \(launchSites)")
    // the plan beside the account in use is the value's (ProfileShow.plan: none in a clash) on the card's Switch menu and the Switch page's
    // in-use box: the helpers are checked on their own (tickedTitle, inUseDetail); this holds the wiring, which a headless run can't draw
    let cardTick = body("Launcher.swift", from: "var switchAccountMenu: SwitchAccountMenu", until: "pick:")
    let pageBox = body("SwitchPage.swift", from: "private var inUseBox: some View", until: "} content: {")
    let tickedBody = body("SwitchAccountMenu.swift", from: "if let label {", until: "m.addItem(i)")
    check(cardTick.contains("plan: row.show.plan") && !cardTick.contains("entry.plan") && !cardTick.contains("status?.plan")
          && tickedBody.contains("AccountCard.tickedTitle(label: words, plan: plan)") && tickedBody.contains("AddressSettings.words(label)"),
          "the card's Switch menu ticks the account with ProfileShow.plan (tickedTitle), never the record's or the profile's plan itself")
    check(pageBox.contains("Self.inUseDetail(plan: row.show.plan)") && pageBox.contains("detail: detail") && !pageBox.contains("entry.plan") && !pageBox.contains("status?.plan"),
          "the Switch page's in-use box draws inUseDetail(ProfileShow.plan) as its detail, never the record's or the profile's plan itself")
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
    // Core is the vendored cl_kit tag's (Vendor/CL_KIT names it)
    let kitTag = ((try? String(contentsOf: src.deletingLastPathComponent().appendingPathComponent("Vendor/CL_KIT"), encoding: .utf8)) ?? "")
        .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? "missing"
    let kitCore = src.deletingLastPathComponent().appendingPathComponent("Vendor/cl_kit-\(kitTag)/Core")
    check(fm.fileExists(atPath: kitCore.path), "the vendored cl_kit's Core/ found: \(kitCore.path)")
    for dir in [src, widgetSrc, kitCore] {
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

    // a tasks-only switch whose new account's file can't be written: the old account's file is put back as it was (the
    // tasks are never in neither account) and the tasks stay, said in the move's note; the move step finishes with nothing
    // to undo, and the switch goes on to the sign-in (which can't start here: no claude)
    let srcTasks = #"{"scheduledTasks":[{"id":"t1"},{"id":"t2"},{"id":"t3"}]}"#
    put("\(srcF)/scheduled-tasks.json", srcTasks)
    try? fm.createDirectory(atPath: dstF, withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dstF)
    rf.start(ef.standby[0])
    settle(failedPhase)
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dstF)
    check(failedPhase() && rf.failedStep == .signIn && rf.receipt?.finished != nil && rf.receipt?.steps.isEmpty == true
          && SwitchEngine.unfinished(profile: "ff").isEmpty
          && rf.moveNote?.contains("scheduled tasks stay where they were") == true
          && fm.contents(atPath: "\(srcF)/scheduled-tasks.json") == Data(srcTasks.utf8) && !fm.fileExists(atPath: "\(dstF)/scheduled-tasks.json"),
          "the new account's task file can't be written: the old account's tasks put back as they were, said, nothing to undo: \(rf.phase) \(rf.moveNote ?? "-")")
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
          && SwitchRunner.movedWords(rf.receipt!) == "2 sessions" && SwitchRunner.recordedWords(rf.receipt!) == "2 sessions",
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
    // the standby tidy-up (per seat since cl_kit 26.11.4): a list with two entries of one seat (one account, one organisation)
    let dup = Data(#"{"accounts":[{"id":"td","name":"Td","label":"TD","configDir":"~/.claude-td","standby":[{"id":"a1","email":"x@example.com","seat":{"account":"\#(uuid(901))","organization":"\#(uuid(902))"}},{"id":"a2","email":"x@example.com","seat":{"account":"\#(uuid(901))","organization":"\#(uuid(902))"}}]}]}"#.utf8)
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
    // (the runner's start refuses first when the profile's folder isn't there, goneLine: the fixture's folder is, so the steps below
    // reach the refusals they pin)
    try? fm.createDirectory(atPath: expand(m0.configDir), withIntermediateDirectories: true)
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
    // 05 in Settings ▸ Accounts: Claude Code's row on ben (a standby entry of this profile) is clickable like every standby
    // row; picked, it lights with the Switch account key. The view is read through its AccountBox's own props.
    do {
        var rec5 = IconStatus(state: "ok"); rec5.loginEmail = ben.email; rec5.weekly = 12
        // a split by hand: the profile's seat is still ann's and ben is still one of its standby entries (the folder not followed)
        rec5.resolved = AccountResolver.resolve(m0, among: [m0], app: app(ann), code: ben, loginEmail: ben.email, names: [:], now: t0)
        _ = Store.writeStatus(m0.id, rec5)
        func boxProps(_ v: Any) -> (tap: Bool, selected: Bool, unlit: Bool, litBadge: String?)? {
            let m = Mirror(reflecting: v)
            if "\(m.subjectType)".hasPrefix("AccountBox<") {
                func val(_ k: String) -> Any? { m.children.first { $0.label == k }?.value }
                func some(_ a: Any?) -> Any? { a.flatMap { Mirror(reflecting: $0).children.first?.value } }
                return (some(val("tap")) != nil, val("selected") as? Bool ?? false, val("unlit") as? Bool ?? false, some(val("litBadge")) as? String)
            }
            for c in m.children { if let p = boxProps(c.value) { return p } }
            return nil
        }
        let sm5 = SettingsModel(); sm5.accounts = [m0, w0]
        let idle = boxProps(AccountSettings(entry: .constant(m0), model: sm5).codeBox(ben.email!))
        let chosen = boxProps(AccountSettings(entry: .constant(m0), model: sm5, picked: m0.standby[0].id).codeBox(ben.email!))
        check(AccountSettings(entry: .constant(m0), model: sm5).view.codeRow == ben.email && idle?.tap == true && idle?.selected == false && idle?.unlit == true
              && chosen?.tap == true && chosen?.selected == true && chosen?.unlit == false && chosen?.litBadge == "Switch account",
              "05: Claude Code's row on a standby account of the profile: a click selects it, picked it lights Switch account: \(String(describing: idle)) / \(String(describing: chosen))")
    }

    // 05, the folder followed (the profile's seat is ben's, ann on standby, ben with NO standby entry: a switch made
    // elsewhere): Claude Code's row still selects on a click, its lit key opens the Switch page for Claude Code's own account
    // (AccountEntry.codeStandbyID), and that switch is the finish line: the sessions go from the Claude app's account (ann),
    // no sign-in opens (the folder is on ben already), only the Claude app's sign-in is left
    do {
        let e5 = r5.e
        // the Claude app's own sign-in (its window's account and organisation), as AppSignIn reads it
        var appLogin = AppSignIn.Login(account: ann.account, org: ann.organization, state: .known, source: "log", at: t0)
        let keepLogin = AccountEntry.appLogin
        AccountEntry.appLogin = { _ in appLogin }
        defer { AccountEntry.appLogin = keepLogin }
        check(e5.seat?.same(ben) == true && !e5.standby.contains { $0.seat?.same(ben) == true } && e5.standby.contains { $0.seat?.same(ann) == true },
              "05 followed: the seat is ben's, ann on standby, ben has no standby entry")
        var rec = IconStatus(state: "ok"); rec.loginEmail = ben.email; rec.weekly = 12
        rec.resolved = AccountResolver.resolve(e5, among: [e5, w0], app: app(ann), code: ben, loginEmail: ben.email, names: [:], now: t0)
        _ = Store.writeStatus(e5.id, rec)
        let v = AccountView.of(rec)
        let target = e5.codeTarget(v)
        check(v.codeRow == ben.email && target?.id == AccountEntry.codeStandbyID && target?.seat?.same(ben) == true && e5.appSeat(v)?.same(ann) == true,
              "05 followed: Claude Code's own account is the target (no standby entry), the Claude app's is ann: \(target?.id ?? "-")")
        func boxProps(_ v: Any) -> (tap: Bool, selected: Bool, litBadge: String?)? {
            let m = Mirror(reflecting: v)
            if "\(m.subjectType)".hasPrefix("AccountBox<") {
                func val(_ k: String) -> Any? { m.children.first { $0.label == k }?.value }
                func some(_ a: Any?) -> Any? { a.flatMap { Mirror(reflecting: $0).children.first?.value } }
                return (some(val("tap")) != nil, val("selected") as? Bool ?? false, some(val("litBadge")) as? String)
            }
            for c in m.children { if let p = boxProps(c.value) { return p } }
            return nil
        }
        let sm = SettingsModel(); sm.accounts = [e5, w0]
        let idle = boxProps(AccountSettings(entry: .constant(e5), model: sm).codeBox(ben.email!))
        let chosen = boxProps(AccountSettings(entry: .constant(e5), model: sm, picked: AccountEntry.codeStandbyID).codeBox(ben.email!))
        check(idle?.tap == true && idle?.selected == false && chosen?.selected == true && chosen?.litBadge == "Switch account",
              "05 followed: the row selects on a click and lights Switch account: \(String(describing: idle)) / \(String(describing: chosen))")
        sm.showSwitch(AccountEntry.switchKey(e5.id, AccountEntry.codeStandbyID))
        check(sm.selection == SettingsModel.switchID && sm.switchTarget?.standby.id == AccountEntry.codeStandbyID
              && sm.switchTarget?.standby.seat?.same(ben) == true,
              "05 followed: its Switch account opens the Switch page with ben as the target")
        let wd = home + "/wd-finish"
        if case .success(let p) = SwitchEngine.plan(e5, standby: target!, dataDir: wd, owned: []) {
            check(p.finishLine && p.from.same(ann) && p.to.same(ben), "05 followed: the plan is the finish line, from ann's sessions to ben")
        } else { check(false, "05 followed: the finish line's plan failed") }
        // with ann on standby a real standby target: an ordinary switch (no finish line); ben again: the refusal as before
        if case .success(let pa) = SwitchEngine.plan(e5, standby: e5.standby.first { $0.seat?.same(ann) == true }!, dataDir: wd, owned: []) {
            check(!pa.finishLine && pa.from.same(ben) && pa.to.same(ann), "05 followed: switching to ann is an ordinary switch from ben")
        } else { check(false, "05 followed: the switch to ann failed to plan") }
        // the runner: Claude Code on ben already reaches the goal at once (from ann), never "the same account, waiting"
        let g = SwitchRunner.Goal(standby: AccountEntry.codeStandbyID, wantedSeat: ben, wantedEmail: ben.email!, from: ann, started: t0)
        check(SwitchRunner.reached(g, ben) && SwitchRunner.judge(g, now: ben, markerDone: false, at: t0) == .reached,
              "05 followed: the folder on ben reaches the finish line's goal")
        // the app on ann's other organisation (its Team seat): the sessions go from the app's own folder, never the standby
        // entry's last organisation
        let annTeam = uuid(61)
        appLogin.org = annTeam
        if case .success(let pt) = SwitchEngine.plan(e5, standby: target!, dataDir: wd, owned: []) {
            check(pt.finishLine && pt.from.account == ann.account && pt.from.organization == annTeam,
                  "05 followed: the app on ann's other organisation: the sessions go from that one (\(pt.from.organization ?? "-"))")
        } else { check(false, "05 followed: the plan with the app on ann's other organisation failed") }
        check(e5.codeTargetMissing(v) == nil, "05 followed: everything the finish line needs is known: nothing said missing")
        // the app on an account that is no standby of the profile (or not known): the target is still offered (the Terminal
        // row's key always opens the Switch page), and the page says what's missing; the switch refuses with those words
        appLogin = AppSignIn.Login(account: uuid(14), org: uuid(54), state: .known, source: "log", at: t0)
        let vOther = AccountView.of(rec)
        check(e5.codeTarget(vOther)?.id == AccountEntry.codeStandbyID && e5.codeTargetMissing(vOther) == AccountEntry.appSeatMissingWords,
              "05 followed: the app's own sign-in not the record's active standby: still offered, the app's account said missing")
        appLogin = AppSignIn.Login(account: nil, org: nil, state: .unknown, source: "unknown", at: nil)
        check(e5.codeTarget(v)?.id == AccountEntry.codeStandbyID && e5.appSeat(v) == nil && e5.codeTargetMissing(v) == AccountEntry.appSeatMissingWords,
              "05 followed: the app's sign-in unknown: still offered, the app's account said missing")
        do {
            let smMissing = SettingsModel(); smMissing.accounts = [e5, w0]
            smMissing.showSwitch(AccountEntry.switchKey(e5.id, AccountEntry.codeStandbyID))
            check(smMissing.switchTarget?.standby.id == AccountEntry.codeStandbyID,
                  "05 followed: with the app's account unknown the Switch page still opens on Terminal's account")
            let rMissing = smMissing.runner(of: e5.id)
            rMissing.start(smMissing.switchTarget!.standby)
            check(rMissing.phase == .failed(AccountEntry.appSeatMissingWords) && rMissing.failedStep == .notStarted,
                  "05 followed: pressed with the app's account unknown, the switch refuses with the page's words, nothing started: \(rMissing.phase)")
        }
        // the folder's seat with no organisation: offered, the folder's account said missing
        var e5NoOrg = e5; e5NoOrg.seat?.organization = nil
        check(e5NoOrg.codeTarget(v)?.id == AccountEntry.codeStandbyID && e5NoOrg.codeTargetMissing(v) == AccountEntry.codeSeatMissingWords,
              "05 followed: the folder's account without its organisation: still offered, Terminal's account said missing")
        check(AccountEntry.sameAccountWords == "The Claude app is on Terminal's account already. There's nothing to switch.",
              "the Switch page's words when the Claude app is on Terminal's account already")
        // the split over (a Switch page left open from before): no codeRow, so Terminal's account as a target refuses at once
        // with its words, and a target without its seat never falls into a plain sign-in
        do {
            var oneRec = rec
            oneRec.resolved = AccountResolver.resolve(e5, among: [e5, w0], app: .unknown, code: ben, loginEmail: ben.email, names: [:], now: t0)
            _ = Store.writeStatus(e5.id, oneRec)
            let vOne = AccountView.of(oneRec)
            check(vOne.codeRow == nil && e5.codeTargetMissing(vOne) == AccountEntry.oneAccountWords
                  && AccountEntry.oneAccountWords == "Both are on one account already. There's nothing to switch.",
                  "05 followed, the split over: nothing to switch, said")
            let smOne = SettingsModel(); smOne.accounts = [e5, w0]
            let rOne = smOne.runner(of: e5.id)
            rOne.start(StandbyAccount(email: ben.email!, seat: nil, addedAt: nil, id: AccountEntry.codeStandbyID))
            check(rOne.phase == .failed(AccountEntry.oneAccountWords) && rOne.failedStep == .notStarted,
                  "05 followed, the split over: a stale Switch page's start refuses, nothing started (no sign-in): \(rOne.phase)")
            _ = Store.writeStatus(e5.id, rec)
        }
        appLogin = AppSignIn.Login(account: ann.account, org: ann.organization, state: .known, source: "log", at: t0)
        // the agent never links a finish line's receipt before its move finished (a stop keeps Undo); once finished it may
        var fr = SwitchReceipt(id: SwitchEngine.receiptID(t0, e5.id), profile: e5.id, standby: AccountEntry.codeStandbyID, dataDir: wd,
                               from: SeatID(ann), to: SeatID(ben), started: t0)
        fr.finishLine = true
        // one session placed (a receipt with no step is no move: not unfinished)
        var placed = SwitchReceipt.Step(kind: .entry, path: wd + "/placed.json", sha: "x", parked: wd + "/parked.json", original: wd + "/orig.json")
        placed.done = true
        fr.steps = [placed]
        try! SwitchEngine.store.save(fr)
        check(SwitchEngine.store.load(fr.id)?.unfinished == true && SwitchRunner.halfDoneFinishLine(fr),
              "05 followed: the half-done finish line's receipt is unfinished (Try again then says Undo or Leave it, no sign-in)")
        let linkedEarly = SwitchEngine.linkReached([e5], signedIn: { _ in ben })
        check(linkedEarly.isEmpty && SwitchEngine.store.load(fr.id)?.linked == nil,
              "05 followed: a finish line's receipt mid-move (not finished) is never linked by the folder being on ben")
        fr.finished = t0
        try! SwitchEngine.store.save(fr)
        let linkedLate = SwitchEngine.linkReached([e5], signedIn: { _ in ben })
        check(linkedLate == [fr.id], "05 followed: once its move finished, it is linked")
        try? fm.removeItem(at: SwitchEngine.root.appendingPathComponent(fr.id))
        Store.removeStatus(e5.id)
    }

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
        AccountSettings.inUseTitle(v, state: state, loginEmail: ben.email, expected: ann.email, mismatch: mismatch).text
    }
    check(title(r5.v, "expired") == ann.email && title(r5.v, "ok", mismatch: true) == ann.email && title(r5.v, "ok") == ann.email,
          "05: the IN USE title is ann (the app's) whether Claude Code's sign-in is fine, expired or another address")
    let t1 = AccountSettings.inUseTitle(r1.v, state: "expired", loginEmail: ann.email, expected: ann.email, mismatch: false)
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
    func words(_ newest: SwitchReceipt?, _ standby: [StandbyAccount], code: Seat, goal: SwitchRunner.Goal? = nil, now: Date = t0) -> String {
        AccountView.codeRowWords(code: code.email!, target: AccountSettings.switchTarget(goal: goal, newest: newest, standby: standby,
                                                                                       code: code.email, codeAccount: code.account.lowercased(), now: now))
    }
    let finish = "Claude Code is on it; sign the Claude app in to finish.", onIt = "Claude Code is on it."
    let notBen = "Claude Code signed in as dan, not ben: the switch didn't finish. Sign Claude Code in as ben from the Switch page, or Undo it."
    // 05 after a restart: the switch reached ben (its receipt linked), the app still on ann: the finish line
    let annOnly = [StandbyAccount(email: ann.email!, seat: ann, id: "ka")]
    check(words(linkedNew, annOnly, code: ben) == finish, "05 after a restart, the receipt linked: ben's row keeps the finish line: \(words(linkedNew, annOnly, code: ben))")
    check(words(linkedNew, annOnly, code: ben, now: t0.addingTimeInterval(2 * 86400)) == onIt,
          "a switch linked two days ago no longer decides the row: \(words(linkedNew, annOnly, code: ben, now: t0.addingTimeInterval(2 * 86400)))")
    // the clock set back after the link: a link a day ahead of now is no finish line; a minute ahead still is
    check(words(linkedNew, annOnly, code: ben, now: t0.addingTimeInterval(-86400)) == onIt
          && words(linkedNew, annOnly, code: ben, now: t0.addingTimeInterval(-60)) == finish,
          "a link dated a day ahead (clock set back) no longer decides the row, one a minute ahead still does: \(words(linkedNew, annOnly, code: ben, now: t0.addingTimeInterval(-86400)))")
    // the one rule both Settings' row and AccountResolver's switchWaits go through (the resolver passes ?? true for no link)
    check(newer.linkedLately(now: t0) == nil
          && linkedNew.linkedLately(now: t0.addingTimeInterval(-300)) == true && linkedNew.linkedLately(now: t0.addingTimeInterval(-301)) == false
          && linkedNew.linkedLately(now: t0.addingTimeInterval(86400)) == true && linkedNew.linkedLately(now: t0.addingTimeInterval(86401)) == false,
          "linkedLately: nil with no link; true from 5 minutes ahead to a day after the link, false past either end")
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
    try? fm.removeItem(at: log)
    // a hard link to another file of this user's: O_NOFOLLOW doesn't see it, the link count does
    let linked = link(elsewhere, log.path) == 0
    var lst = stat()
    let twoNames = linked && lstat(log.path, &lst) == 0 && lst.st_nlink == 2
    ConsentLog.accepted("Import")
    check(twoNames && (try? String(contentsOfFile: elsewhere, encoding: .utf8)) == "kept\n",
          "consent.log a hard link (made: \(twoNames)): never appended to")
    try? fm.removeItem(at: log); try? fm.removeItem(atPath: elsewhere)
    rc.reset()
}

// ============ 6f. the split (B8): the Claude app on P, Terminal on M: M's numbers show under M's name ("· Terminal"), never P's ============
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
    // the headline record: Terminal's numbers and plan (mo's: the surfaces name it, "· Terminal", Store.ages' opt-in), the
    // label still the app's account in use, and the split's line
    check(head?.weekly == 100 && head?.fiveHour == nil && head?.plan == "Ultra" && AccountView.of(head).label == pat.email
          && AccountView.of(head).numbersOwner == mo.email
          && AccountView.of(head).line == "The Claude app and Terminal are signed in to different accounts.",
          "the profile's record keeps Terminal's numbers (mo's), pat in use, and its line says the split: \(AccountView.of(head).line ?? "-")")
    // the record holds the fact, not the sentence (the sentence names both accounts): the line is built when it is drawn, so the
    // same record read again with Show emails off says "hidden address" and a record never holds an address-bearing line
    let splitSentence = AccountView.of(head).line ?? ""
    AddressPrivacy.shared.apply(blur: true)
    let splitHidden = AccountView.of(head).line ?? ""
    AddressPrivacy.shared.apply(blur: false)
    check(head?.resolved?.line == nil && head?.resolved?.splitLine == true && head?.resolved?.lineText() == splitSentence
          && splitHidden == SplitUsage.bandHead && splitSentence == SplitUsage.bandHead
          && !splitHidden.contains("example.com") && !splitHidden.contains("@"),
          "the split's sentence is not stored in the record (a flag), and it is said by the setting when drawn: \(splitHidden)")
    let row = cardRow(e, now: now)
    check(row.full != nil && row.weekly == 100 && !row.needsLogin
          && AtLimit.tileCountdown(fiveHour: row.fiveHour, fiveHourResets: head?.fiveHourResets, weekly: row.weekly, weeklyResets: head?.weeklyResets) != nil,
          "the card and its tile: Terminal's full week, its full panel and countdown, no red Sign in")
    check(Usage.of(head)?.weekly == 100,
          "the menu bar strip and the Dock icon: Terminal's numbers (mo's)")
    check(!previewShowsNone(e, head) && !panelShowsNone(e, head),
          "the split: the Dock icon's preview and Settings' panel preview draw Terminal's numbers")
    check(row.show.splitWords?.key == "Sign Terminal in" && split?.loginEmail == pat.email,
          "the key: Sign Terminal in, with pat's address filled in")
    // no address in a sentence; the short form is the line itself (no "Can't read … / Terminal: …" any more)
    check(split?.numbersHint == "Sign Terminal in to the Claude app's account to see its numbers."
          && split?.shortLine == SplitUsage.bandHead,
          "the line under it and the short form: \(split?.numbersHint ?? "-") / \(split?.shortLine ?? "-")")
    let splitShow = ProfileShow.load(e, now: now)
    let panelInfo = dockPanelOf(e, splitShow)         // (through the Dock app's own detailsInfo)
    // the Dock panel as the card: no "Can't read … / Terminal: …" lines, the amber line with the same link (spl's Settings ▸
    // Accounts at the band), the compact Sign in in its keys row, the lamp lit (pat is in use)
    check(panelInfo.activeNote == nil && panelInfo.splitLink == SettingsLink.split("spl") && panelInfo.splitKey == "Sign in"
          && panelInfo.activeLit && !panelInfo.needsLogin,
          "the Dock panel: the amber line's link to spl's band, the compact Sign in, no old lines: \(panelInfo.splitKey ?? "-")")
    check(splitShow.display.none == nil && splitShow.display.usage?.weekly == 100 && splitShow.display.lamp
          && splitShow.display.full != nil && !splitShow.display.grey && splitShow.display.split != nil
          && splitShow.display.key == .logInCode(to: pat.email!)
          && splitShow.loginAddress == pat.email && splitShow.numbersHint == split?.numbersHint,
          "the value in the split: Terminal's numbers, full, not grey, lit, the key to pat, pat's address for Sign in")
    // the menu bar row's line: the short form in the split, the record's line otherwise (MenuBarRow.lineWords)
    let barProfile = MenuBarItems.Profile(show: splitShow)
    var notSplit = record(app: appPat, code: mo, reading: mo.email, weekly: 40)
    notSplit.resolved = AccountResolver.resolve(e, among: [e], app: .unknown, code: mo, loginEmail: mo.email, names: [:], now: now)
    let notSplitShow = ProfileShow.of(e, raw: notSplit, now: now)
    check(MenuBarRow.lineWords(barProfile) == split?.shortLine && notSplitShow.display.split == nil
          && MenuBarRow.lineWords(MenuBarItems.Profile(show: notSplitShow)) == notSplit.resolved?.lineText(),
          "the menu bar row's short split line, and the record's line outside the split")
    // the menu bar row draws the card's amber line in its place, the same link: this profile's Settings ▸ Accounts, at the
    // split's band; none outside the split
    check(MenuBarRow.splitLink(barProfile) == SettingsLink(profile: "spl", section: SettingsLink.splitBand)
          && MenuBarRow.splitLink(barProfile) == UsageNotice.of(row)?.link
          && MenuBarRow.splitLink(MenuBarItems.Profile(show: notSplitShow)) == nil,
          "the menu bar row's amber line links to spl's Settings ▸ Accounts at the split band: \(String(describing: MenuBarRow.splitLink(barProfile)))")
    // keys carry no ellipsis (menu items keep theirs)
    check(split?.key?.hasSuffix("…") == false && SplitUsage.appSignInKey.hasSuffix("…") == false && SplitUsage.panelSignInKey == "Sign in",
          "the split's keys have no ellipsis")
    // no split surface says "No usage" or "yet" (the lines, the key, the hint, the short form), whether the addresses show or
    // are hidden (AddressText.hidden: the setting itself is the operator's, never touched here) and with the app's account by id
    for (what, app, code) in [("shown", pat.email!, mo.email!), ("hidden", AddressText.hidden, AddressText.hidden),
                              ("by id", "account \(pat.account.prefix(8))", mo.email!)] {
        let s = SplitUsage(app: app, code: code)
        let said = [s.line, s.shortLine, s.numbersHint ?? "", s.key ?? "", AccountView.of(head).line ?? ""]
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
    // the menus' Sign in, wired for real (ClaudeCLI.logIn(profile:): its claude found, the guard asked, the
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
    // the Dock icon's Sign in (its panel's key; the Dock menu has none: it lists no account) through the Dock app's own delegate:
    // the same launch as the menu path, through the guard, pat's address, never mo's (the card's key is the same ClaudeCLI.logIn,
    // its closure lives in the launcher's window code, which a headless run can't build)
    MainActor.assumeIsolated {
    let dockApp = AppDelegate(); dockApp.entry = e; dockApp.show = ProfileShow.load(e)
    check(!dockApp.profileMenu().items.contains { $0.representedObject as? String == DockTileMenu.object(.signIn, e.id) },
          "(the Dock menu has no Sign in key: the panel and the menu bar menu have it)")
    let dockPresses: [(String, () -> Void)] = [("the Dock panel's Sign in", { dockApp.detailsActions().logIn() })]
    for (what, press) in dockPresses {
        launches.removeAll(); scripts.removeAll()
        press()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        check(launches == ["login \(Account(e).configDir)"] && scripts.count == 1 && scripts[0].contains(pat.email!) && !scripts[0].contains(mo.email!),
              "\(what), in the split: launched once through the guard, pat's address filled in, never mo's: \(launches)")
    }
    }
    let anon = AppSignIn.Login(account: uuid(34), org: uuid(74), state: .known, source: "log", at: now)
    var anonRec = record(app: anon, code: mo, reading: mo.email, weekly: 100)
    anonRec.resolved = AccountResolver.resolve(e, among: [e], app: anon, code: mo, loginEmail: mo.email, names: [:], now: now)
    _ = Store.writeStatus("spl", anonRec)
    let anonSplit = ProfileShow.load(e).splitWords
    check(anonSplit != nil && anonSplit?.key == nil
          && anonSplit?.numbersHint == "Sign Terminal in to the Claude app's account to see its numbers."
          && ProfileShow.load(e).loginAddress == nil
          && SplitUsage.appUnknownWords == "Open the Claude window once, so cl_audit learns its account.",
          "the app's account known by its id only: no key (Settings says to open the Claude window once), no address (never mo's): \(anonSplit?.app ?? "-")")
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
    let switchedLine = "Switching to \(AddressSettings.words(mo.email!)): one step left. Sign the Claude app in to \(AddressSettings.words(mo.email!)) to finish."
    for (what, r) in [("linked (Claude Code reached mo)", linkedToMo), ("still open", toMo)] {
        let s = splitWith(app: appPat, newest: r)
        check(s?.switched == true && s?.line == switchedLine && s?.key == nil && s?.loginEmail == nil
              && Store.status(for: e)?.weekly == nil && AccountView.of(Store.status(for: e)).line == switchedLine
              && ProfileShow.load(e, now: now).display.usage == nil && dockPanelOf(e, ProfileShow.load(e, now: now)).weekly == nil
              && Store.status(for: e, headline: false)?.weekly == 100,
              "a switch to mo waiting for the app (\(what)): the switched line, no key, no numbers for pat, mo's in its own record: \(s?.line ?? "-")")
    }
    let zed = Seat(account: uuid(33), organization: uuid(73), email: "zed@example.com")
    let appZed = AppSignIn.Login(account: zed.account, org: zed.organization, state: .known, source: "log", at: now)
    let third = splitWith(app: appZed, newest: linkedToMo, names: [zed.account.lowercased(): zed.email!])
    check(third?.switched == false && third?.key == SplitUsage.terminalSignInKey && third?.line == SplitUsage.bandHead,
          "the app on a third account (not the one the switch left): a split by hand, the B8 line and key")
    var undone = toMo; undone.undone = now
    var leftAsIs = toMo; leftAsIs.leftAsIs = now
    for (what, r) in [("undone", undone), ("left as it is", leftAsIs)] {
        let s = splitWith(app: appPat, newest: r)
        check(s?.switched == false && s?.key == SplitUsage.terminalSignInKey && s?.loginEmail == pat.email,
              "the switch \(what): a split by hand, the B8 line and key")
    }
    var dayOld = linkedToMo; dayOld.linked = now.addingTimeInterval(-25 * 3600)
    let dayOldSplit = splitWith(app: appPat, newest: dayOld)
    check(dayOldSplit?.switched == false && dayOldSplit?.key == SplitUsage.terminalSignInKey && dayOldSplit?.loginEmail == pat.email,
          "a switch linked 25 hours ago waits no more: a split by hand, the B8 line and key")
    let older = splitWith(app: appPat, newest: nil)
    check(older?.switched == false && older?.key != nil, "no switch at all: a split by hand")
    var toOther = toMo; toOther.to = SeatID(zed)
    check(splitWith(app: appPat, newest: toOther)?.switched == false, "the newest switch went to another account than Claude Code's: by hand")
    _ = Store.writeStatus("spl", record(app: appPat, code: mo, reading: mo.email, weekly: 100))

    // numbersFor comes from the reading itself: a .claude.json naming another account changes whose they are not
    // (a reading whose sign-in isn't the kept one: the record decides Claude Code's account, cl_kit's rule with no verified word)
    let staleCode = AccountResolver.resolve(e, among: [e], app: appPat, code: pat, loginEmail: mo.email, readingVerified: false, names: [:], now: now)
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
    // (the edge case: the split, its numbers naming no account: none under the app's label, no alert, no offer, though the
    // surfaces opt in to Terminal's numbers, which need to be known as Terminal's first)
    let unnamedShow = ProfileShow.of(e, raw: saved)
    check(posts.isEmpty && unnamedShow.display.split != nil && unnamedShow.display.usage == nil && unnamedShow.display.full == nil
          && Store.status(for: e)?.weekly == nil && e.fullOffer(view: unnamedShow.view) == nil,
          "the split with numbers of no named account: no full or back alert, no switch offer, no numbers for the profile: \(posts)")
    sr.stop()
    // the split with its reading's owner known (mo, Terminal's account): its numbers act under its name, so the full alert
    // goes out, exactly once (no second one from the same read); pat, the app's account, is in use, so nothing is offered
    posts.removeAll()
    let so = UsageReader(e, defaults: UserDefaults(suiteName: "cl-audit-surfaces-split-owned-\(getpid())")!)
    so.finish(data: reply, response: ok200, error: nil, asked: Date(), gen: so.generation, key: "s1")
    so.profileFound(mo.email!, key: "s1"); so.save()
    let soUntil = Date().addingTimeInterval(5)
    while !posts.contains(where: { $0.contains("full") }) && Date() < soUntil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))                // time for a second, unwanted one to show
    let splitFulls = posts.filter { $0.contains("full") }
    check(splitFulls == ["Claude Spl: weekly limit full"] && Store.status("spl")?.resolved?.numbersFor == mo.email
          && ProfileShow.load(e, now: Date()).display.split != nil,
          "the split, Terminal's week full under its name: the full alert, exactly once: \(splitFulls)")
    so.stop()
    SharedReads.alerted = [:]; SharedReads.last = [:]                         // (mo's alert must not quiet the twins below)
    try! Store.save([e])
    // the same read with the app on mo (no split): the full alert goes out (the check above isn't empty by accident). Shared
    // seats: a second profile whose folder is signed in to mo too shows the same numbers, but the full limit alerts exactly
    // once, from the first profile that alerts (SharedReads' ledger: the twin, same level and window, doesn't)
    var same = profile("spm", "~/.claude-spm", mo); same.claudeWindow = false
    var twin = profile("spt", "~/.claude-spt", nil); twin.claudeWindow = false
    signIn(same.configDir, mo, plan: "Ultra"); signIn(twin.configDir, mo, plan: "Ultra")
    try! Store.save([same, twin])
    posts.removeAll()
    let mr = UsageReader(same, defaults: UserDefaults(suiteName: "cl-audit-surfaces-same-\(getpid())")!)
    let tr = UsageReader(twin, defaults: UserDefaults(suiteName: "cl-audit-surfaces-twin-\(getpid())")!)
    // (a reading is whose the token's account is, never the folder's record: each is read with its own key, whose lookup says mo,
    // with the seat's id and organisation, which is what the ledger keys the alert by; without one the seat is not known and the
    // ledger shares nothing. spm's lookup returns first, so spm is the first one that alerts)
    mr.finish(data: reply, response: ok200, error: nil, asked: Date(), gen: mr.generation, key: "m1")
    tr.finish(data: reply, response: ok200, error: nil, asked: Date(), gen: tr.generation, key: "t1")
    mr.profileFound(mo.email!, key: "m1", account: mo.account, organization: mo.organization); mr.save()
    tr.profileFound(mo.email!, key: "t1", account: mo.account, organization: mo.organization); tr.save()
    let until = Date().addingTimeInterval(5)
    while !posts.contains(where: { $0.contains("full") }) && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))                // time for a second, unwanted one to show
    let fulls = posts.filter { $0.contains("full") }
    check(fulls == ["Claude Spm: weekly limit full"],
          "two profiles' folders on one account: exactly one full alert, from the first one that alerts: \(fulls)")
    check(Store.status("spt")?.resolved?.clash == nil && Store.status(for: twin)?.weekly == 100,
          "the twin shares the seat: no clash, its card shows the same numbers, and it stays quiet")
    // and the plan: both records have it, so every reader of them, the widget too, shows it on both
    let widgetShared = AgentFiles.load(from: Store.folder, now: now)
    check(Store.status("spm")?.plan == "Ultra" && Store.status("spt")?.plan == "Ultra"
          && widgetShared.first { $0.id == "spm" }?.plan == "Ultra" && widgetShared.first { $0.id == "spt" }?.plan == "Ultra",
          "a shared seat's plan shows on both profiles, the widget's too: \(Store.status("spt")?.plan ?? "nil")")
    mr.stop(); tr.stop()
    SharedReads.alerted = [:]; SharedReads.last = [:]                         // the next checks start with no shared seat's past
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
    // whose the numbers are is the record's answer only (the resolver's, through Headline), never the profile's seat
    // address: a reading of the seat's id under another address shows in the widget as on the card
    var renamedRec = IconStatus(state: "ok"); renamedRec.weekly = 40; renamedRec.updatedAt = now
    renamedRec.loginEmail = "mo-renamed@example.com"; renamedRec.numbersOwner = renamedRec.loginEmail; renamedRec.numbersAccount = mo.account
    renamedRec.resolved = AccountResolver.resolve(same, among: [same], app: .unknown, code: mo, loginEmail: renamedRec.loginEmail,
                                                  loginAccount: mo.account, names: [:], now: now)
    _ = Store.writeStatus("spm", renamedRec)
    w = AgentFiles.load(from: Store.folder, now: now)
    check(renamedRec.resolved?.readStale == nil && Store.status(for: same, now: now)?.weekly == 40 && w.first { $0.id == "spm" }?.week == 40,
          "the widget: the seat's id read under another address shows, as on the card (no seat address of its own)")
    var otherRec = renamedRec
    otherRec.resolved = AccountResolver.resolve(same, among: [same], app: .unknown, code: mo, loginEmail: "else@example.com", readingVerified: false,
                                                names: [:], now: now)
    otherRec.loginEmail = "else@example.com"; otherRec.numbersOwner = otherRec.loginEmail; otherRec.numbersAccount = nil
    _ = Store.writeStatus("spm", otherRec)
    w = AgentFiles.load(from: Store.folder, now: now)
    check(otherRec.resolved?.readStale == true && Store.status(for: same, now: now)?.weekly == nil && w.first { $0.id == "spm" }?.week == nil,
          "…and another account's reading (stale) shows in neither")

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
    // the token on mo, the folder's .claude.json naming pat (signed in since that token was read): never decided from the
    // folder alone, and the reply for a sign-in read before the record changed is no verified word (UsageReader seeds it
    // with the record's generation as the Keychain read started; this token wasn't read after the change): its owner known
    // (mo), the reading is stale, shown nowhere. The sign-in changed, so the reader asks Claude Code itself (the short ask,
    // once): a running claude that says pat confirms the folder moved on; the reading stays stale and is read again
    signIn(same.configDir, pat)
    hr.finish(data: reply, response: ok200, error: nil, asked: Date(), gen: hr.generation, key: "k3")
    check(Store.status(for: same)?.weekly != 100, "token mo, folder pat, owner not yet known: the new reading isn't shown")
    var asks: [String] = []
    UsageReader.askSeam = { folder in asks.append(folder.path); return SignedInAccount(email: pat.email, origin: .process) }
    hr.profileFound(mo.email!, key: "k3"); hr.save()
    let mixed = Store.status("spm")
    check(mixed?.resolved?.numbersFor == mo.email && mixed?.resolved?.readStale == true && mixed?.resolved?.codeName == pat.email
          && Store.status(for: same)?.weekly == nil,
          "…its owner known (mo), read before the folder moved to pat: not a verified word, stale, no numbers shown: \(mixed?.resolved?.codeName ?? "-")")
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    let told = Store.status("spm")
    check(asks == [expand(same.configDir)] && told?.resolved?.readStale == true && told?.resolved?.codeName == pat.email
          && Store.status(for: same)?.weekly == nil,
          "the short ask, once, in the profile's own folder (the sign-in changed): Claude Code says pat, mo's reading stays stale, shown nowhere: \(asks.count) ask(s)")
    hr.save(); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(asks.count == 1, "…and not again for the same state (never on every save or tick)")
    UsageReader.askSeam = { _ in nil }
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

// ============ 8. the status record's one codec (cl_kit's StatusCodec): today's bytes, older files, the headline over them ============
do {
    // written by main 20489f5's own writer (its IconStatus and ResolvedAccount, Store.writeStatus's settings): every field the
    // agent writes; the split with a switch waiting and a stale reading; a file from before the resolver, numbersOwner and
    // ownerUnconfirmed; a resolver answer from before its newer keys, with a clash, expired and unconfirmed
    let fixtures: [(String, String)] = [
        ("full", #"{"credits":{"cap":50,"currency":"USD","enabled":true,"out":false,"spentAt":1799999400,"used":4.2},"expectedEmail":"ultra-1@example.com","fiveHour":37.5,"fiveHourResets":1800003600,"loginEmail":"ultra-1@example.com","numbersOwner":"ultra-1@example.com","plan":"Ultra","renewNote":"Renewed 09:12","renewing":false,"resolved":{"account":"00000000-0000-4000-8000-000000000001","at":1800000000,"codeAccount":"00000000-0000-4000-8000-000000000001","codeName":"ultra-1@example.com","differs":false,"email":"ultra-1@example.com","fromApp":true,"lit":true,"numbersFor":"ultra-1@example.com"},"scoped":[{"name":"Fable","percent":12,"resets":1800259200}],"source":"Anthropic","state":"ok","updatedAt":1800000000.25,"weekly":64,"weeklyResets":1800259200}"#),
        ("split", #"{"expectedEmail":"mo@example.com","loginEmail":"mo@example.com","noFiveHour":true,"numbersOwner":"mo@example.com","plan":"max","resolved":{"account":"00000000-0000-4000-8000-000000000002","at":1800000000,"codeAccount":"00000000-0000-4000-8000-000000000003","codeName":"mo@example.com","codeUsageLine":true,"differs":true,"email":"pat@example.com","fromApp":true,"lit":true,"numbersFor":"mo@example.com","readStale":true,"switchWaits":true},"state":"ok","updatedAt":1800000000,"weekly":100,"weeklyResets":1800007200}"#),
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
    // (an older build's clash field is decoded only: never used, so that record is the split as without it, shared seats)
    var elsewhere = fresh; elsewhere.resolved?.clash = "Home"
    var nameless = fresh; nameless.resolved?.codeName = nil; nameless.resolved?.numbersFor = nil
    for (name, rec, waits) in [("unconfirmed", unsure, Bool?.none), ("fresh", fresh, true), ("by hand", byHand, false),
                               ("an older clash record", elsewhere, true), ("nameless", nameless, nil)] {
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
    func items(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
    /// The menu's ticked row (the account in use), if any.
    func ticked(_ m: NSMenu) -> [String] { items(m).filter { $0.state == .on }.map(\.title) }
    /// The menu has the one key, Claude Code's sign-in ("Sign Terminal in to …", or "Sign in…" with no address to fill in).
    func signIn(_ m: NSMenu) -> Bool { items(m).contains { ($0.representedObject as? String)?.hasPrefix("signIn:") == true } }

    // the one formula for the thresholds: the app's and the widget's
    // (the app's surfaces name Terminal's account in the split, so they opt in to its numbers; the widget names none and
    // stays out; a record that doesn't say whose the numbers are, or a switch waiting for the app, keeps the app's out too)
    let unnamed = ResolvedAccount(account: nil, email: nil, fromApp: false, numbersFor: nil, differs: true, line: nil, lit: true,
                                  clash: nil, at: now)
    var waits = unnamed; waits.numbersFor = "mo@example.com"; waits.switchWaits = true
    var namedOwner = unnamed; namedOwner.numbersFor = "mo@example.com"
    check(Store.ages(e, resolved: namedOwner).splitShowsNumbersOwner
          && Store.ages(e) == StatusAges.of(pollMinutes: 5, splitShowsNumbersOwner: true) && Store.ages(e).splitShowsNumbersOwner
          && AgentFiles.ages(pollMinutes: 5) == StatusAges.of(pollMinutes: 5) && !AgentFiles.ages(pollMinutes: 5).splitShowsNumbersOwner
          && !Store.ages(e, resolved: unnamed).splitShowsNumbersOwner && !Store.ages(e, resolved: waits).splitShowsNumbersOwner,
          "the split's opt-in: the app's ages on, the widget's off; off for numbers of no named account and while a switch waits")
    check(StatusAges.freshFor(pollMinutes: 5) == 6 * 60
          && StatusAges.greyAfter(pollMinutes: 5) == 30 * 60 && StatusAges.freshFor(pollMinutes: 20) == 21 * 60
          && StatusAges.greyAfter(pollMinutes: 20) == 60 * 60 && StatusAges.freshFor(pollMinutes: 1) == 6 * 60,
          "the thresholds: fresh for the read interval (5 min at least) plus a minute, grey after three reads (30 min at least)")

    // fresh, the profile's own: numbers, lit, no key, not grey, on every 3a surface
    let ok = show(rec())
    let okDock = dockOf(e, ok), okItem = MenuBarItems.item(MenuBarItems.Profile(show: ok), now: now)
    check(ok.display.usage?.weekly == 40 && ok.display.tier == .fresh && ok.display.lamp && ok.display.key == nil && !ok.display.grey
          && okItem.week == 40 && !okItem.stale && !okDock.face.stale && okDock.face.weekly == 40 && okDock.panel.activeLit
          && !ticked(menuBarMenu(ok)).isEmpty && ticked(okDock.menu).isEmpty && !titles(okDock.menu).contains { $0.contains("%") },
          "fresh: the numbers, the lamp lit, no key; the menu bar, the Dock face and its panel alike, the menu bar menu's account ticked; the Dock menu shows no account or number")

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
          && !titles(fullDock.menu).contains { $0.hasPrefix("Week full") } && !titles(fullDock.menu).contains(u2.email!)
          && titles(fullBar).contains(u2.email!),
          "a fresh full week: the countdown on both icons, the full panel, and the standby account (the way back) in the menu bar menu; the Dock menu shows neither")
    let fullOld = show(rec(week: 100, age: 10 * 60, weekIn: 3 * 3600))
    check(fullOld.display.full == nil && dockOf(e, fullOld).face.countdown == nil && !titles(dockOf(e, fullOld).menu).contains { $0.hasPrefix("Week full") }
          && titles(menuBarMenu(fullOld)).contains(u2.email!), "the same full week read 10 minutes ago: nothing full (its standby account still listed)")

    // the Dock tile plug-in (DockTile/Plugin.swift) draws the Dock icon app's own face from the same value, fresh, grey and full
    func pic(_ m: TileModel) -> Data? { Painter.image(m, pixels: 128).tiffRepresentation }
    check([ok, old, full, fullOld].allSatisfy { s in
        let a = pic(dockOf(e, s).face), b = pic(TileModel.face(e, s, windowOpen: false))
        return a != nil && a == b
    }, "the Dock tile plug-in's face is the Dock icon app's: fresh, grey, full and full but old")
    // each profile's copy registers its own class, per build: copies in one Dock process never stand for each other
    let names = [DockTile.className("a", build: "0011"), DockTile.className("b", build: "0011"), DockTile.className("a", build: "0022"),
                 DockTile.className("a-b", build: "0011"), DockTile.className("a_b", build: "0011")]
    check(Set(names).count == names.count && names.allSatisfy { NSClassFromString($0) == nil && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } }
          && !names.contains(DockTile.baseClass), "Dock tile classes: one per profile and build, plain names, none the base class")
    // Settings ▸ Dock icon ▸ Runs: while the Dock draws the icon (a fresh heartbeat) no app needs to run, whatever Runs says;
    // otherwise Runs applies, in each choice's own words
    var runs = e
    func words(_ r: DockRuns, window: Bool, drawn: Bool) -> String {
        runs.dockRuns = r; runs.claudeWindow = window; return AccountSettings.runsWords(runs, dockDraws: drawn)
    }
    let drawnLine = "The Dock draws the icon itself, so its app needn't run: a click starts it."
    check(DockRuns.allCases.allSatisfy { r in [true, false].allSatisfy { words(r, window: $0, drawn: true) == drawnLine } },
          "Runs while the Dock draws the icon: no app needs to run, for every choice, with or without a Claude window")
    let notYet = "The Dock isn't drawing the icon (yet), so Runs applies: "
    check(words(.atLogin, window: true, drawn: false) == notYet + "always there, from when you sign in."
          && words(.atLogin, window: false, drawn: false) == notYet + "always there, from when you sign in."
          && words(.withWindow, window: true, drawn: false) == notYet + "it starts with the Claude window and quits 10 s after it."
          && words(.withWindow, window: false, drawn: false) == notYet + "no Claude window, so only when you start it."
          && words(.whenStarted, window: true, drawn: false) == notYet + "only when you start it: its Dock tile, or its switch on the dashboard.",
          "Runs when the Dock isn't drawing the icon: each choice's own words, the same lead for all")
    let info = AccountSettings.runsInfo(name: "Main")
    check(info.hasPrefix("Normally the Dock draws Main's icon itself, so no app needs to run and Runs has no effect.")
          && info.contains("If it can't (Dock Tiles turned off in System Settings ▸ General ▸ Login Items & Extensions)"),
          "Runs' help: it has no effect while the Dock draws the icon, and says where Dock Tiles is")
    // the one freshness test (DockTile.fresh), for the agent's tracker and Settings alike: under 90 s and not in the future
    let beatAt = Date(timeIntervalSince1970: 1_800_000_000)
    check(DockTile.fresh(beatAt, now: beatAt) && DockTile.fresh(beatAt, now: beatAt.addingTimeInterval(89.9))
          && !DockTile.fresh(beatAt, now: beatAt.addingTimeInterval(90)) && !DockTile.fresh(beatAt, now: beatAt.addingTimeInterval(-1))
          && !DockTile.fresh(nil, now: beatAt), "DockTile.fresh: 0 and 89.9 s fresh; 90 s, a future heartbeat (-1 s) and none: not")
    var agrees = TileTracker(now: beatAt)
    agrees.tick(now: beatAt.addingTimeInterval(30))
    let atFresh = agrees.step("x", TileTracker.Facts(pinned: true, running: true, ours: true, inFront: false, lastBeat: beatAt.addingTimeInterval(-59.9)),
                              now: beatAt.addingTimeInterval(30))
    check(atFresh == .quit, "the agent's tracker uses the same test: a heartbeat 89.9 s old counts as drawn")
    // DockTile.drawn reads the profile's heartbeat file (an id of its own, removed whatever happens)
    do {
        let beatID = "runs-check-\(getpid())"
        let beatFile = DockTile.beatURL(beatID)
        defer { DockTile.forget(beatID) }
        try? fm.createDirectory(at: DockTile.folder, withIntermediateDirectories: true)
        check(!DockTile.drawn(beatID), "no heartbeat: the Dock doesn't draw it")
        fm.createFile(atPath: beatFile.path, contents: Data("beat".utf8))
        let stamp = (try? fm.attributesOfItem(atPath: beatFile.path))?[.modificationDate] as? Date ?? Date()
        check(DockTile.drawn(beatID, now: stamp.addingTimeInterval(89)) && !DockTile.drawn(beatID, now: stamp.addingTimeInterval(90))
              && !DockTile.drawn(beatID, now: stamp.addingTimeInterval(-1)), "DockTile.drawn: the file's time through the one test")
        DockTile.forget(beatID)
        check(!fm.fileExists(atPath: beatFile.path), "DockTile.forget removes the heartbeat")
    }

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
        check(s.display.usage?.weekly == 40 && !s.display.lamp && s.display.key == nil && !dk.panel.activeLit
              && !signIn(dk.menu) && !signIn(menuBarMenu(s)),
              "a sign-in \(words): the numbers as read, the lamp off on the menu bar row and the Dock panel, no Sign in in either menu")
    }
    for state in ["expired", "noLogin"] {
        let s = show(rec(state))
        let dk = dockOf(e, s)
        check(s.display.usage == nil && !s.display.lamp && s.display.needsLogin && dk.face.stale && !dk.panel.activeLit
              && !signIn(dk.menu) && signIn(menuBarMenu(s)) && dk.face.countdown == nil
              && dk.panel.noNumbers == (state == "expired" ? "Sign-in expired" : "Signed out"),
              "\(state): no numbers, grey, the lamp off, the panel's age line says why, the sign-in in the menu bar menu (the Dock menu has none)")
    }
    let mixed = show(rec(login: u3.email, code: u1))
    let mixedDock = dockOf(e, mixed)
    check(mixed.display.otherAccount && mixed.display.needsLogin && !mixed.display.lamp && mixedDock.face.warn && mixedDock.panel.mismatch
          && signIn(menuBarMenu(mixed)) && !signIn(mixedDock.menu),
          "the sign-in on another account than the folder's: the warning, the sign-in in the menu bar menu (the Dock menu has none), the lamp off")

    // shared seats: another profile's account in use is this profile's too, lit, no clash (the folder's own record names it, as
    // a real folder on that account does: rec's default expectedEmail is the profile's u1)
    var sharedRec = rec(login: u3.email, code: u3); sharedRec.expectedEmail = u3.email
    let sharedShow = show(sharedRec)
    check(Store.status("show")?.resolved?.clash == nil && sharedShow.display.clash == nil && sharedShow.display.lamp,
          "Claude Code's folder on another profile's account: a shared seat, no clash, the lamp on")
    // an older build's clash record (its clash fields decoded, never used): the surfaces show it as the record's account,
    // lit, no key, nothing red
    let appClash = #"{"expectedEmail":"ultra-1@example.com","loginEmail":"ultra-1@example.com","resolved":{"account":"\#(u1.account)","at":1800000000,"clash":"Other","clashID":"other","differs":false,"email":"ultra-1@example.com","fromApp":true,"lit":true,"numbersFor":"ultra-1@example.com"},"state":"ok","updatedAt":\#(Int(now.timeIntervalSince1970) - 60),"weekly":40}"#
    let appClashShow = show(StatusCodec.decode(Data(appClash.utf8))!)
    let appClashDock = dockOf(e, appClashShow)
    check(appClashShow.display.clash == nil && appClashShow.display.lamp && appClashDock.panel.activeLit && appClashShow.display.key == nil
          && !titles(appClashDock.menu).contains { $0.hasPrefix("Sign Terminal in to ") } && appClashShow.loginAddress == u1.email,
          "an older build's clash record: no clash on any surface, lit, no sign-in key, the folder's own address")

    // a value made a moment before a full limit's reset: drawn after it, no countdown (the face and the icon look again)
    let beforeReset = ProfileShow.of(e, raw: rec(week: 100, weekIn: -60), now: now.addingTimeInterval(-120))
    check(beforeReset.display.full != nil && beforeReset.display.full(now: Date()) == nil && dockOf(e, beforeReset).face.countdown == nil
          && MenuBarItems.item(MenuBarItems.Profile(show: beforeReset), now: Date()).countdown == nil,
          "a full week whose reset passed since the value was made: no countdown on the Dock face or the menu bar icon")

    // standby is never read: no surface shows a standby account with numbers
    for (what, s) in [("fresh", ok), ("full", full)] {
        // (a menu item's object is "<action>:<target>": DockTileMenu.object)
        let key = DockTileMenu.object(.switchTo, AccountEntry.switchKey("show", "k2"))
        let standbyLines = items(menuBarMenu(s)).filter { ($0.representedObject as? String) == key }.map(\.title)
        check(!standbyLines.isEmpty && standbyLines.allSatisfy { !$0.contains("%") }
              && !items(dockOf(e, s).menu).contains { ($0.representedObject as? String) == key },
              "\(what): the standby account is listed in the menu bar menu, never with numbers; the Dock menu lists no account: \(standbyLines)")
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

// ============ 10. the alerts through the one Headline (ProfileCore step 3d) ============
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
    // the profile's own full-limit offer is the alert's (the record is saved by now)
    check(e.fullOffer()?.key == AccountEntry.switchKey("qa", "kpat") && e.fullOffer()?.key == fullPost?.key,
          "the profile's offer is the alert's: \(e.fullOffer()?.key ?? "none")")
    // the split with Terminal's account full: the numbers are Terminal's (mo's), so the offer never names mo, though mo is
    // on standby (the app's account, pat, in use) and the least used by its last week; the menus' best is the same
    do {
        let quinn = Seat(account: uuid(43), organization: uuid(83), email: "quinn@example.com")
        var q = profile("qb", "~/.claude-qb", pat)
        q.standby = [StandbyAccount(email: mo.email!, seat: mo, id: "kmo", lastInUse: t0, lastWeek: 5),
                     StandbyAccount(email: quinn.email!, seat: quinn, id: "kq", lastInUse: t0, lastWeek: 40)]
        let appPat = AppSignIn.Login(account: pat.account, org: pat.organization, state: .known, source: "log", at: t0)
        var s = IconStatus(state: "ok"); s.loginEmail = mo.email; s.numbersOwner = mo.email; s.weekly = 100; s.updatedAt = t0
        s.resolved = AccountResolver.resolve(q, among: [q], app: appPat, code: mo, loginEmail: mo.email, names: [:], now: t0)
        let v = AccountView.of(s)
        let codeRow: (StandbyAccount) -> Bool = { v.isCodeRow(id: $0.seat?.account, email: $0.seat?.email ?? $0.email) }
        let lines = SwitchMenu.lines(q.listed(by: v), notOffered: codeRow, now: t0)
        check(v.codeRow == mo.email && AccountBook.best(q.listed(by: v).standby, now: t0)?.id == "kmo"
              && q.fullOffer(view: v, now: t0)?.key == AccountEntry.switchKey("qb", "kq")
              && SwitchMenu.best(lines)?.key == AccountEntry.switchKey("qb", "kq") && lines.contains { $0.key == AccountEntry.switchKey("qb", "kmo") },
              "the split, Terminal's account (mo) full: the offer and the menus' best are quinn, never mo (still listed): \(q.fullOffer(view: v, now: t0)?.key ?? "none")")
    }
    var onlyMo = e; onlyMo.standby = [e.standby[0]]
    check(onlyMo.fullOffer() == nil, "only the account in use on standby: no offer anywhere")
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

}

// ============ 11. ClaudeFiles: the one reader of .claude.json's account, the one lister of the window's sessions ============
do {
    let dir = home + "/cf"
    try? fm.removeItem(atPath: dir)
    // the record: field by field, a guess; read again when the file changed; through a link named by the path; never a FIFO
    let rec = dir + "/code/.claude.json"
    put(rec, #"{"oauthAccount":{"accountUuid":"\#(u1.account)","organizationUuid":"\#(u1.organization!)","emailAddress":"\#(u1.email!)","organizationType":"claude_max","organizationName":"x","planDisplayName":"Ultra"},"projects":{}}"#)
    let r = ClaudeFiles.record(at: rec)
    check(r?.seat == Seat(account: u1.account, organization: u1.organization, email: u1.email) && r?.plan == "Ultra" && r?.organizationType == "claude_max",
          "the record: its seat, plan and fields")
    // Claude Code's account through ClaudeAuth's one folder reader (Account.records), fed by this reader: a guess, its fields
    let look = Account.records.look(path: rec)
    check(look.account == SignedInAccount(accountID: u1.account, email: u1.email, organizationID: u1.organization, organizationName: "x",
                                          plan: "Ultra", origin: .record)
          && ClaudeFiles.recordPath(folder: dir + "/code", isDefault: true, home: "/h") == "/h/.claude.json",
          "the one folder reader: the record's account, guessed; the default folder's record is in the home folder")
    put(rec, #"{"oauthAccount":{"accountUuid":"\#(u2.account)","emailAddress":"\#(u2.email!)","planDisplayName":"  "}}"#)
    let again = ClaudeFiles.record(at: rec)
    check(again?.seat?.account == u2.account && again?.plan == nil && again?.planDisplayName == "  ", "read again once the file changed; a blank plan is none (the field kept as written)")
    // an edit in place that keeps the size, the inode and the date (put back): read again too (its status-change time moved)
    let kept = (try? fm.attributesOfItem(atPath: rec))?[.modificationDate] as? Date
    let inode = (try? fm.attributesOfItem(atPath: rec))?[.systemFileNumber] as? Int
    let sameSize = #"{"oauthAccount":{"accountUuid":"\#(u3.account)","emailAddress":"\#(u3.email!)","planDisplayName":"  "}}"#
    if let h = FileHandle(forWritingAtPath: rec) { h.write(Data(sameSize.utf8)); h.closeFile() }
    if let kept { try? fm.setAttributes([.modificationDate: kept], ofItemAtPath: rec) }
    let inPlace = ClaudeFiles.record(at: rec)
    check(u3.email!.count == u2.email!.count && (try? fm.attributesOfItem(atPath: rec))?[.systemFileNumber] as? Int == inode
          && inPlace?.seat?.account == u3.account, "an edit in place keeping its size, inode and date: read again (by its status-change time)")
    put(rec, #"{"oauthAccount":{"accountUuid":"\#(u2.account)","emailAddress":"\#(u2.email!)","planDisplayName":"  "}}"#)
    try? fm.createDirectory(atPath: dir + "/linked", withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: dir + "/linked/.claude.json", withDestinationPath: rec)
    check(ClaudeFiles.record(at: dir + "/linked/.claude.json")?.seat?.account == u2.account, "a .claude.json that is a link to the real one: read")
    // the one folder reader through the link: a change of the file behind it is a change (its stamp follows the link), and
    // its generation moves only when the record names someone else
    let linkLook = Account.records.look(path: dir + "/linked/.claude.json")
    put(rec, #"{"oauthAccount":{"accountUuid":"\#(u3.account)","emailAddress":"\#(u3.email!)"}}"#)
    let linkAfter = Account.records.look(path: dir + "/linked/.claude.json")
    check(linkLook.account?.accountID == u2.account && linkAfter.account?.accountID == u3.account && linkAfter.generation == linkLook.generation + 1,
          "the one folder reader through a link: the file behind it changed to another account, read again, one change counted")
    // A1: a record that names an address and no account id is signed in (by the address), never signed out
    put(dir + "/addr/.claude.json", #"{"oauthAccount":{"emailAddress":"\#(u2.email!)"}}"#)
    check(Account.records.look(path: dir + "/addr/.claude.json").account?.email == u2.email
          && ClaudeFiles.record(at: dir + "/addr/.claude.json")?.seat == nil,
          "A1: an address without an id names Claude Code's account (a guess), while the saved-seat reader still needs the id")
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
    // ClaudeAuth's record read in the app goes through the one folder reader (ClaudeCLI.authTools.reader: Account.records, fed
    // by ClaudeFiles): the same account as ClaudeAuth's own RecordFile gives, nothing for none
    let full = dir + "/auth/.claude.json"
    put(full, #"{"oauthAccount":{"accountUuid":"\#(u1.account)","organizationUuid":"\#(u1.organization!)","emailAddress":"\#(u1.email!)","organizationName":"x","planDisplayName":"Ultra"},"projects":{}}"#)
    let authed = Authenticator(AuthFolder(path: dir + "/auth", isDefault: false), tools: ClaudeCLI.authTools)
    let viaApp = authed.record(), viaAuth = SignedInAccount.record(RecordFile.oauthAccount(full))
    check(ClaudeCLI.authTools.reader === Account.records && viaApp != nil && viaApp == viaAuth && viaApp?.accountID == u1.account && viaApp?.plan == "Ultra"
          && Account.records.look(path: dir + "/none/.claude.json").account == nil && Account.records.look(path: dir + "/missing/.claude.json").account == nil,
          "the app's Authenticator reads the record through the one folder reader: the same account as RecordFile's, none for none")

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
    // the cap on a folder's listing (AppSignIn.maxListed): a folder of very many names is read to its first 256 (the "." and ".." the
    // disk gives first count among them), never to the end; the answer is one of those organisations, whichever the disk gives first
    let big = dir + "/bigwindow", bigAccount = uuid(14)
    let bigCount = AppSignIn.maxListed + 44
    for i in 0..<bigCount { try? fm.createDirectory(atPath: big + "/claude-code-sessions/\(bigAccount)/\(uuid(4000 + i))", withIntermediateDirectories: true) }
    let capped = ClaudeFiles.sessionScopes(dataDir: big, account: bigAccount, limit: AppSignIn.maxListed)
    let uncapped = ClaudeFiles.sessionScopes(dataDir: big, account: bigAccount)
    check(uncapped.count == bigCount && capped.count <= AppSignIn.maxListed && capped.count >= AppSignIn.maxListed - 2 && Set(capped.map(\.organization)).isSubset(of: Set(uncapped.map(\.organization))),
          "the listing cap: \(bigCount) organisation folders, at most \(AppSignIn.maxListed) looked at (the dot entries among them): \(capped.count) of \(uncapped.count)")
    check(AppSignIn.sessionsOrg(dataDir: big, account: bigAccount).map { o in uncapped.contains { $0.organization.lowercased() == o } } == true
          && Set(ClaudeFiles.sessionScopes(dataDir: big, account: bigAccount, limit: AppSignIn.maxListed).map(\.organization)).count == capped.count,
          "the Claude app's organisation from a folder past the cap: one of the folders there, no folder twice")
    try? fm.removeItem(atPath: big)
    // the sign-out line against config.json's time (AppSignIn.scan, configSlack 2 s: a sign-out logged just before config.json is
    // rewritten still counts): the edges at 2 s, in the same second (a stamp without milliseconds), and across a clock change (the
    // stamps are local time: the comparison is of instants, never of the wall clock's numbers). The formatters' zone is set per case
    func signOutCounts(_ stamp: String, config: String, zone: String = "GMT") -> Bool? {
        guard let tz = TimeZone(identifier: zone) else { return nil }
        let keep = (AppSignIn.timeFormat.timeZone, AppSignIn.timeFormatShort.timeZone)
        AppSignIn.timeFormat.timeZone = tz; AppSignIn.timeFormatShort.timeZone = tz
        defer { (AppSignIn.timeFormat.timeZone, AppSignIn.timeFormatShort.timeZone) = keep }
        guard let at = AppSignIn.timeFormat.date(from: config) else { return nil }
        var s = AppSignIn.Scan()
        let lines = ["\(stamp) [info] [LocalSessionManager] Account logged out", ""].map { Substring($0) }
        AppSignIn.scan(lines: lines, into: &s, launched: at.addingTimeInterval(-3 * 86400), account: u1.account, configTime: at, now: at.addingTimeInterval(86400))
        return s.loggedOut != nil
    }
    let signOut = "2026-11-15 12:00:00.000"
    check(signOutCounts(signOut, config: "2026-11-15 12:00:01.999") == true && signOutCounts(signOut, config: "2026-11-15 12:00:02.000") == false
          && signOutCounts(signOut, config: "2026-11-15 12:00:00.000") == true && signOutCounts(signOut, config: "2026-11-15 11:59:00.000") == true
          && signOutCounts(signOut, config: "2026-11-15 12:00:10.000") == false,
          "a sign-out line against config.json: before it by less than 2 s, with it, after it: signed out; 2 s before it or more: not")
    check(signOutCounts("2026-11-15 12:00:00", config: "2026-11-15 12:00:01.900") == true && signOutCounts("2026-11-15 12:00:00", config: "2026-11-15 12:00:02.100") == false
          && signOutCounts("2026-11-15 12:00:00", config: "2026-11-15 12:00:00.800") == true,
          "a stamp without milliseconds (the same second as config.json's time): counts while config.json is less than 2 s later")
    check(signOutCounts("2026-03-08 01:59:59.000", config: "2026-03-08 03:00:00.999", zone: "America/New_York") == true
          && signOutCounts("2026-03-08 01:59:59.000", config: "2026-03-08 03:00:01.000", zone: "America/New_York") == false,
          "the clock springing forward (01:59:59 then 03:00:00 local): 2 s apart in real time, so the same edge, never an hour")
    check(signOutCounts("2026-11-01 02:00:00.000", config: "2026-11-01 02:00:01.500", zone: "America/New_York") == true
          && signOutCounts("2026-11-01 01:30:00.000", config: "2026-11-01 01:30:01.000", zone: "America/New_York") == true
          && signOutCounts("2026-11-01 00:30:00.000", config: "2026-11-01 02:30:00.000", zone: "America/New_York") == false,
          "the clock falling back (01:00 to 02:00 local twice): a sign-out just before config.json counts, one an hour or more before doesn't")
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
              && c.notice?.line == "Sign in as \(AddressSettings.words(u1.email!)) to read Card's usage." && c.row.limits.allSatisfy { $0.p == nil }
              && c.row.tile.stale && !c.row.lit && c.row.needsLogin, "\(state): red, Sign in… to the folder's address, no numbers, grey, the lamp off")
    }
    let mixed = card(rec(login: u2.email, code: u1), nil, "another account")
    check(mixed.notice?.heading == "Terminal is signed in to another account" && mixed.notice?.key == .signIn && mixed.row.tile.warn
          && !mixed.row.lit && mixed.row.subtitle == "sign-in is a different account", "the sign-in on another account than the folder's: red, Sign in…, the warning, the lamp off")

    // shared seats: the folder on another profile's account (u3) is this profile's account too: no red, no key, its
    // numbers its own
    let shared = card(rec(login: u3.email, code: u3), nil, "another profile's account")
    check(shared.row.display.clash == nil && shared.notice == nil && shared.row.display.key == nil && shared.row.lit && shared.row.weekly == 40,
          "another profile's account: a shared seat, no notice, no key, lit, its numbers: \(shared.notice?.heading ?? "-")")
    // the record keeps the folder account's organisation beside its id; when the Claude app decided the account in use (the app
    // on the profile's own u1, the folder on Other's u3) the record says the app decided, and names no clash
    var win = e; win.claudeWindow = true
    func appRec(_ app: AppSignIn.Login, code: Seat) -> IconStatus {
        var s = rec(week: nil, five: nil, login: code.email, code: code)
        s.resolved = AccountResolver.resolve(win, among: [win, other], app: app, code: code, loginEmail: code.email, names: [:], now: now)
        return s
    }
    _ = Store.writeStatus(e.id, appRec(appU1, code: u3))
    check(Store.status(e.id)?.resolved?.fromApp == true && Store.status(e.id)?.resolved?.clash == nil,
          "an app-decided account with the folder on Other's: the record says the app decided, and names no clash (shared seats)")
    _ = Store.writeStatus(e.id, rec())
    check(Store.status(e.id)?.resolved?.codeOrganization == u1.organization?.lowercased(),
          "the record keeps the folder account's organisation beside its id")
    // the organisation in three states: an id, none ("": the folder's record names the seat with no organisation) and not
    // known (nil: a record from before codeOrganization)
    let bare = Seat(account: u1.account, organization: nil, email: u1.email)
    _ = Store.writeStatus(e.id, rec(code: bare))
    check(Store.status(e.id)?.resolved?.codeOrganization == "",
          "a seat its record names with no organisation: the record keeps \"\" (none, known): \(Store.status(e.id)?.resolved?.codeOrganization ?? "nil")")
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

    try? fm.createDirectory(atPath: expand(e.configDir), withIntermediateDirectories: true)
    _ = Store.writeStatus(e.id, rec(week: nil, five: nil, login: u3.email, code: u3))
    // Settings ▸ Accounts' Sign in… keys on a shared seat: both on the folder's own account (u3, this profile's too)
    let keysModel = SettingsModel(); keysModel.accounts = [e, other]
    let keys = AccountSettings(entry: .constant(e), model: keysModel)
    check(keys.inUseKeyAddress == u3.email && keys.codeKeyAddress == u3.email,
          "Settings' Sign in… keys on a shared seat: on the folder's u3: \(keys.inUseKeyAddress ?? "-") / \(keys.codeKeyAddress ?? "-")")
    // the plan beside the account in use: one rule (ProfileShow.plan), the record's, a shared seat's too
    let sharedPlanShow = ProfileShow.load(e, now: now)
    check(sharedPlanShow.plan == "Max" && dockPanelOf(e, sharedPlanShow).plan == "Max"
          && SwitchPage.inUseDetail(plan: nil) == "" && SwitchPage.inUseDetail(plan: "max") == Account.planWords("max"),
          "a shared seat: the record's plan beside the account, in the Dock panel and the Switch page's in-use box")
    check(fresh.row.show.plan == "Max" && dockPanelOf(e, fresh.row.show).plan == "Max",
          "the record's plan, in the Dock panel too")
    // an older build's record that still names a clash, the app's u2 deciding: no clash anywhere, the app's address for
    // the key, the menu bar's and the Dock menu's too
    let appClash = #"{"expectedEmail":"ultra-3@example.com","loginEmail":"ultra-3@example.com","resolved":{"account":"\#(u2.account)","at":1800000000,"clash":"Other","clashID":"other","differs":true,"email":"ultra-2@example.com","fromApp":true,"lit":true,"numbersFor":"ultra-3@example.com"},"state":"ok","updatedAt":\#(Int(now.timeIntervalSince1970) - 60),"weekly":40}"#
    let appDecided = card(StatusCodec.decode(Data(appClash.utf8))!, nil, "an older clash record, the app's account")
    check(appDecided.row.display.clash == nil && appDecided.notice?.heading != "Terminal is signed in to Other's account",
          "an older build's clash record: no clash notice: \(appDecided.notice?.heading ?? "-")")
    var noSeat = e; noSeat.seat = nil
    let clashModel = SettingsModel(); clashModel.accounts = [noSeat, other]
    // the address pop-up's Sign in… on a profile with no seat whose sign-in is on another account (u2; the folder names
    // u1): the folder's u1, never the account the sign-in is on (the pop-up's ticked line, u2)
    var onOther = IconStatus(state: "ok"); onOther.loginEmail = u2.email; onOther.expectedEmail = u1.email; onOther.updatedAt = now
    _ = Store.writeStatus(e.id, onOther)
    let popUp = AccountSettings(entry: .constant(noSeat), model: clashModel)
    let popUpItems = popUp.loginItems
    check(popUp.popUpSignInAddress == u1.email && popUpItems.contains { $0.id == "again" }
          && popUpItems.first { $0.id == "here" }?.title.contains(AddressSettings.words(u2.email!)) == true,
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
    check(split.notice?.heading == "Claude window on another account" && split.notice?.tone == .amber
          && split.notice?.key == UsageNotice.Key.none && split.notice?.line == ""
          && split.row.lit && split.row.full != nil && split.row.weekly == 100
          && split.row.show.loginAddress == pat.email,
          "the split: one amber line (a warning), no key on the card, lit (pat is in use), Terminal's numbers (mo's, the week full) above it")
    // the amber line is a link to this profile's Settings ▸ Accounts, at the split's band; the window key amber, then
    // Terminal and ⋯ (the keys row: Show window, Terminal, ⋯)
    let splitActs = LauncherActions(open: { _ in }, terminal: { _ in }, logIn: { _ in }, mainScreen: {}, settings: {})
    check(split.notice?.link == SettingsLink(profile: "csp", section: SettingsLink.splitBand) && split.notice?.windowAmber == true
          && AccountCard(row: split.row, actions: splitActs).windowKeyAmber && split.terminalInRow,
          "the split: the amber line links to csp's Settings ▸ Accounts at the band, the window key amber, Terminal in the row")
    let anonApp = AppSignIn.Login(account: uuid(63), org: uuid(163), state: .known, source: "log", at: now)
    let anon = card(splitRec(app: anonApp), s, "split, the app's account by id")
    check(anon.notice?.key == UsageNotice.Key.none && anon.notice?.heading == SplitUsage.windowLine
          && anon.notice?.link == SettingsLink.split("csp") && anon.row.show.loginAddress == nil && anon.terminalInRow,
          "the split with the app's account known by its id only: the same amber line and link, no key, Terminal in the keys row")
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
    // which notice shows when several apply at once (UsageNotice.of's order, pinned as it is): the split (while Terminal is signed in,
    // or a switch waits for the app), then the sign-in on another account than the folder's, then expired, then signed out,
    // then not readable (only without numbers). Another profile's account is no notice of its own (shared seats): the state
    // says it. Every pair that can co-occur in a record:
    let anotherAccount = "Terminal is signed in to another account"
    let expiredHead = "Terminal's sign-in has expired", outHead = "Terminal is signed out"
    let ownMo = SplitUsage.windowLine
    try! Store.save([e, other, s])
    let precedence: [(String, IconStatus, AccountEntry?, String?)] = [
        // (the profile `card`: Claude Code on u1; Other's account is u3)
        ("expired + the sign-in on another account", rec("expired", week: nil, five: nil, login: u2.email, code: u1), nil, anotherAccount),
        ("signed out + the sign-in on another account", rec("noLogin", week: nil, five: nil, login: u2.email, code: u1), nil, outHead),
        ("not readable (denied, no numbers) + another account", rec("denied", week: nil, five: nil, login: u2.email, code: u1), nil, anotherAccount),
        ("not readable (unreadable, no numbers) + another account", rec("unreadable", week: nil, five: nil, login: u2.email, code: u1), nil, anotherAccount),
        ("expired + another profile's account", rec("expired", week: nil, five: nil, login: u3.email, code: u3), nil, expiredHead),
        ("signed out + another profile's account (the folder's record names Other's u3)", rec("noLogin", week: nil, five: nil, login: nil, code: u3), nil, outHead),
        ("not readable (denied, no numbers) + another profile's account", rec("denied", week: nil, five: nil, login: u3.email, code: u3), nil, "Can't read Terminal's sign-in yet"),
        ("not readable (unreadable, no numbers) + another profile's account", rec("unreadable", week: nil, five: nil, login: u3.email, code: u3), nil, "Can't read Terminal's sign-in"),
        ("another account + another profile's account (the sign-in on u2, the folder on Other's u3)", rec(login: u2.email, code: u3), nil, anotherAccount),
        // (the profile `csp`: the Claude app on pat, Claude Code on mo)
        ("the split + expired", { var r = splitRec(app: appPat); r.state = "expired"; return r }(), s, expiredHead),
        ("the split + signed out", { var r = splitRec(app: appPat); r.state = "noLogin"; r.loginEmail = nil; return r }(), s, outHead),
        ("the split + not readable (denied)", { var r = splitRec(app: appPat); r.state = "denied"; return r }(), s, ownMo),
        ("the split + not readable (unreadable)", { var r = splitRec(app: appPat); r.state = "unreadable"; return r }(), s, ownMo),
        ("the split + the sign-in on another account", { var r = splitRec(app: appPat); r.expectedEmail = "zed@example.com"; return r }(), s, ownMo),
    ]
    var order: [String] = []
    for (what, r, p, want) in precedence {
        let got = card(r, p, what).notice?.heading
        if got != want { order.append("\(what): shows \(got.map { "\"\($0)\"" } ?? "nothing"), pinned \(want.map { "\"\($0)\"" } ?? "nothing")") }
    }
    check(order.isEmpty, "the notice's order when several apply (the split, another account, another profile's, expired, signed out, not readable): \(order)")
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
    // shared seats: the folder on another profile's account (Other's u3) is this profile's account too: lit, its numbers,
    // no Open, the in-use box named u3 on every surface (the clash checks that stood here are retired below)
    let sharedSeat = surfaces(rec(login: u3.email, code: u3))
    check(sharedSeat.settings.inUseRow.lit && sharedSeat.page.inUseRow.lit && sharedSeat.page.inUseRow.weekly == 40
          && UsageNotice.of(sharedSeat.settings.inUseRow) == nil && !sharedSeat.settings.inUseSignInKey
          && sharedSeat.panel.accountLine.text == u3.email && sharedSeat.settings.inUsePlan == "Max",
          "a shared seat: lit, its numbers and plan, no notice and no key, the panel naming u3")
#if RETIRED_ONEOWNER
    // (one profile per account, retired with shared seats 2026-11-22: the clash's surfaces, the move back, Open Other)
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
          && clashDock.menu.items.first?.title == "Claude Acc" && clashDock.menu.items.contains { $0.state == .on && $0.title == u1.email! }
          && !naming(clashDock.menu).contains { $0.contains(u3Short) }
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
    let noSeatShow = ProfileShow.load(noSeat, now: now)
    let noSeatDock = dockOf(noSeat, noSeatShow), noSeatPanel = noSeatDock.panel          // (through the Dock app's own detailsInfo)
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
    let backTitle = "ultra-1@example.com · move back here", backKey = AccountEntry.switchKey("acc", "k1")
    func allItems(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) } }
    func rowsOf(_ m: NSMenu, _ short: String) -> Int { titles(m).filter { $0.hasPrefix(short) && !$0.hasPrefix("Claude") }.count }
    func ownRow(_ m: NSMenu) -> NSMenuItem? { allItems(m).first { $0.title == backTitle } }
    check(bothShow.ownStandbyID == "k1" && bothShow.named.label == u1.email, "a clash: the own account is the ticked one and the standby id k1 (ProfileShow.ownStandbyID)")
    check(rowsOf(bothBar, u1Short) == 1 && rowsOf(bothBar, u2Short) == 1 && !titles(bothBar).contains(u1.email!)
          && rowsOf(bothDock.menu, u1Short) == 0 && rowsOf(bothDock.menu, u2Short) == 0,
          "a clash, the own account also on the standby list: one row in the menu bar menu, never on standby too (u2 once); none in the Dock menu")
    for (what, m) in [("menu bar", bothBar)] {
        let row = ownRow(m)
        check(row?.state == .on && row?.isEnabled == true && row?.action != nil
              && row?.representedObject as? String == DockTileMenu.object(.switchTo, backKey),
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
          && SwitchPage.boxWords(k2, back: false, name: "Acc", moveCount: "41 Code-tab sessions", now: now) == "Last used yesterday.",
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
    // the move-back's words: the Switch page says cat stays with its own profile and never calls it a standby account
    check(SwitchOffer.moveBackTitle(u1Short) == "Move Claude Code back to \(u1Short)…",
          "the move-back's title in a clash names the own account: \(SwitchOffer.moveBackTitle(u1Short))")
    let stays = SwitchPage.staysLine(from: "cat", name: "Acc", moveBack: true, owner: "Work")
    let staysNoOwner = SwitchPage.staysLine(from: "cat", name: "Acc", moveBack: true, owner: nil)
    let staysNormal = SwitchPage.staysLine(from: "ann", name: "Acc", moveBack: false, owner: "Work")
    check(stays == "cat stays with Work: nothing read here." && staysNoOwner == "cat stays with the profile it belongs to: nothing read here."
          && !stays.contains("standby") && !staysNoOwner.contains("standby") && !stays.contains("Acc")
          && staysNormal == "ann stays on Acc as a standby account: nothing read, switch back any time.",
          "the Switch page's move-back line: cat stays with its own profile (never Acc's standby); a normal switch unchanged: \(stays)")
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
    let calmShow = ProfileShow.load(both, now: now), calmDock = dockOf(both, calmShow), calmBar = menuBarMenu(calmShow)
    check(calmShow.ownStandbyID == nil && ownRow(calmBar) == nil
          && rowsOf(calmBar, u1Short) == 1 && rowsOf(calmDock.menu, u1Short) == 0
          && calmBar.items.contains { $0.state == .on && $0.title == u1.email! } && !titles(calmBar).contains { $0.contains("move Claude Code") },
          "no clash: the active account ticked once in the menu bar menu, whole, off the standby list, no move words; none in the Dock menu")
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
#endif

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
    check(split.panel.weekly == 30 && abs((split.panel.updated?.timeIntervalSince(now) ?? 0) + 120) < 1 && split.panel.noNumbers == nil
          && split.settings.inUseRow.lit && split.settings.splitBand && split.settings.popUpSignInAddress == pat.email
          && split.settings.show.loginAddress == pat.email && same(split.preview, split.panel) && split.preview.splitKey != nil,
          "the split: the panel's age line says when (not Reading usage…), Settings lit with its band, pat's address for Sign Terminal in, the preview as the panel")
    // the band (Settings ▸ Accounts): its words, its two rows (lamps, the TERMINAL APP badge with each row's half green and
    // the missing half bright red, Terminal's row not selectable) and their keys
    func bandBox(_ v: Any) -> (lamp: Color?, split: SplitBadge?, tap: Bool, selected: Bool)? {
        let m = Mirror(reflecting: v)
        if "\(m.subjectType)".hasPrefix("AccountBox<") {
            func val(_ k: String) -> Any? { m.children.first { $0.label == k }?.value }
            func some(_ a: Any?) -> Any? { a.flatMap { Mirror(reflecting: $0).children.first?.value } }
            return (some(val("lamp")) as? Color, some(val("split")) as? SplitBadge, some(val("tap")) != nil, val("selected") as? Bool ?? false)
        }
        for c in m.children { if let p = bandBox(c.value) { return p } }
        return nil
    }
    let termBox = bandBox(split.settings.splitTerminalBox(mo.email!)), appBox = bandBox(split.settings.splitAppBox)
    check(termBox?.lamp == FaceTheme.ledAmber && termBox?.split == .terminal && termBox?.tap == false && termBox?.selected == false
          && appBox?.lamp == FaceTheme.ledAmber && appBox?.split == .app && appBox?.tap == false,
          "the band's rows, both lamps amber (a warning): Terminal's with its badge, not selectable (no click); the Claude app's with its badge: \(String(describing: termBox)) / \(String(describing: appBox))")
    check(SplitBadge.terminal.terminal == .ok && SplitBadge.terminal.app == .warn && SplitBadge.app.terminal == .warn && SplitBadge.app.app == .ok
          && SplitBadge.terminalWord == "Terminal" && SplitBadge.appWord == "App",
          "the badge: TERMINAL then APP; Terminal's row TERMINAL green, APP bright red; the Claude app's row TERMINAL bright red, APP green")
    check(SplitUsage.bandHead == "The Claude app and Terminal are signed in to different accounts."
          && SplitUsage.bandWhy == "cl_audit can read usage only through Terminal's sign-in, so the Claude app's account shows no numbers."
          && SplitUsage.bandFix == "Use the key on either account to put both on the same account."
          && SplitUsage.appSignInKey == "Sign the app in" && SplitUsage.terminalSignInKey == "Sign Terminal in"
          && SplitUsage.windowLine == "Claude window on another account",
          "the band's headline and two lines, the two keys, and the card's amber line, as worded")
    // Terminal's key opens the Switch page for Terminal's account (here mo has no standby entry: Claude Code's own)
    let bandTarget = split.settings.splitSwitchTarget(mo.email!)
    model.showSwitch(AccountEntry.switchKey(s.id, bandTarget?.id ?? "-"))
    check(bandTarget?.id == AccountEntry.codeStandbyID && model.selection == SettingsModel.switchID && model.switchTarget?.standby.id == AccountEntry.codeStandbyID,
          "the band's Sign the app in opens the Switch page on Terminal's account: \(bandTarget?.id ?? "none")")
    model.selection = s.id
    let anon = surfaces(splitRec(AppSignIn.Login(account: uuid(83), org: uuid(183), state: .known, source: "log", at: now)), s)
    check(anon.settings.splitBand && anon.settings.show.loginAddress == nil && anon.settings.popUpSignInAddress == nil && same(anon.preview, anon.panel)
          && anon.settings.splitSwitchTarget(mo.email!)?.id == AccountEntry.codeStandbyID,
          "the split with the app's account by id only: the band, Sign Terminal in fills in no address (never mo's), Terminal's key still offered")
    // the band takes the in-use box's place: its red box's Sign in… key is never drawn in the split
    check(!anon.settings.inUseSignInKey && !split.settings.inUseSignInKey, "the split: no red in-use box key (the band's rows have the keys)")
    model.accounts = [e, twin, other]; try! Store.save([e, twin, other])
    check(!surfaces(rec()).settings.inUseSignInKey && surfaces(rec("expired")).settings.inUseSignInKey
          && !surfaces(rec("denied", week: nil, five: nil)).settings.inUseSignInKey,
          "Settings' box key by state: none when fresh, Sign in… when expired, none (amber, Refresh now) when it can't be read")
    model.accounts = [e, twin]
    // a standby box says when it was last in use, never numbers (even with a last week remembered)
    var remembered = e.standby[0]; remembered.lastWeek = 77; remembered.lastWeekResets = now.addingTimeInterval(86400)
    let words = surfaces(rec()).settings.standbyWords(remembered, name: "Acc")
    check(words == "Last used on Acc " + AccountBook.ago(remembered.lastInUse!) && !words.contains("%") && !words.contains("77"),
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
    // (kept as a template, the old account a marker, said when drawn)
    check(SwitchRunner.leftBehind(p)?.replacingOccurrences(of: SwitchRunner.oldMark, with: p.from.email.map(AccountNames.short) ?? "the old account") == left
          && SwitchRunner.leftBehind(p)?.contains(SwitchRunner.oldMark) == true && SwitchRunner.stayWords(p) == nil && SwitchRunner.leftBehind(none) == nil,
          "the runner's leftNote is the past tense, apart from its other note: \(SwitchRunner.leftBehind(p) ?? "nil")")
    // after a switch that moved nothing: no left-behind line (a flag, not a string match); after a move, as it is
    check(SwitchPage.leftShown(left, movedNothing: true) == nil && SwitchPage.leftShown(left, movedNothing: false) == left && SwitchPage.leftShown(nil, movedNothing: false) == nil,
          "a failed switch that moved nothing: the left-behind line hidden; a switch that moved: shown")
    // the plan card's line: "Will stay with" until something moved (a receipt), also while closing and after a Cancel back
    // to Ready (during Closing, and while waiting when the plan moved nothing); "Left with" once it moved
    let rr = SwitchRunner(profile: "sw", model: SettingsModel())
    func cardLeft() -> String? { SwitchPage.leftInPlan(left: rr.leftText, moved: SwitchPage.movedForPlanLine(receipt: rr.receipt, phase: rr.phase), plan: rr.planned) }
    rr.preview(.closing, goal: nil, planned: p, left: SwitchRunner.leftBehind(p), old: p.from.email)
    check(cardLeft() == will, "closing: the card still says Will stay with: \(cardLeft() ?? "nil")")
    rr.cancel()
    check(rr.phase == .ready && cardLeft() == will, "Cancel during Closing: back at Ready, Will stay with (nothing moved)")
    rr.preview(.waiting, goal: nil, planned: p, left: SwitchRunner.leftBehind(p), old: p.from.email)
    rr.cancel()
    check(rr.phase == .ready && cardLeft() == will, "Cancel while waiting, the plan moved nothing: Will stay with")
    var receipt = SwitchReceipt(id: SwitchEngine.receiptID(Date(), "sw"), profile: "sw", standby: "k2", dataDir: "/x", from: SeatID(u1), to: SeatID(u2), started: Date())
    receipt.steps = []
    rr.preview(.waiting, goal: nil, planned: p, receipt: receipt, left: SwitchRunner.leftBehind(p), old: p.from.email)
    check(cardLeft() == left, "after a move: Left with: \(cardLeft() ?? "nil")")
    // back at Ready with an unfinished receipt kept (a reset): the card describes the next switch's plan again
    check(SwitchPage.movedForPlanLine(receipt: receipt, phase: .ready) == false && SwitchPage.movedForPlanLine(receipt: receipt, phase: .waiting)
          && !SwitchPage.movedForPlanLine(receipt: nil, phase: .waiting)
          && SwitchPage.leftInPlan(left: nil, moved: SwitchPage.movedForPlanLine(receipt: receipt, phase: .ready), plan: p) == will,
          "Ready with a kept receipt: Will stay with, from the plan")
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
    // shared seats: another profile's account in use is never a clash (ids in any case, with or without an organisation)
    check(clash(upper(h1)) == nil && clash(h1) == nil, "no clash: another profile's account in use, ids in another case, is shared")
    check(clash(Seat(account: h1.account, organization: "", email: h1.email), profile("hnil", "~/.claude-hnil", Seat(account: h1.account, organization: nil, email: h1.email))) == nil,
          "no clash: no organisation (nil) and an empty one")
    check(clash(otherOrg) == nil && clash(otherID) == nil, "no clash: the same address in another organisation, or another id")
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
    let oneEmpty = AccountResolver.resolve(me, among: [me], app: .unknown, code: empty, loginEmail: h2.email, readingVerified: false, names: [:], now: t0)
    check(oneEmpty.readStale == true, "one address empty, the other not, the reading not verified: stale, as before")
    let oneEmptyV = AccountResolver.resolve(me, among: [me], app: .unknown, code: empty, loginEmail: h2.email, names: [:], now: t0)
    check(oneEmptyV.readStale == nil && oneEmptyV.email == h2.email && oneEmptyV.codeName == h2.email,
          "A3: one address empty, the reading verified: Anthropic's word names Claude Code's account, not stale")
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
    check(own.readStale == nil && !own.differs && own.email == h2.email && own.line != AccountResolver.staleWords
          && shownWeekly(own, id: h2.account.uppercased()) == 40,
          "folder {id, no address} + a reading with the folder's id (any case): the profile's numbers show, named by the reading's address")
    let elseID = AccountResolver.resolve(me, among: [me], app: .unknown, code: idOnly, loginEmail: foreign, loginAccount: otherAcct, readingVerified: false,
                                         names: [:], now: t0)
    check(elseID.readStale == true && elseID.email == nil && elseID.line == AccountResolver.staleWords
          && shownWeekly(elseID, id: otherAcct) == nil,
          "folder {id, no address} + a reading with another id, not verified: stale, shown nowhere (another account, said as before)")
    // A3: the same reading verified (its sign-in is the kept one): Anthropic's word is Claude Code's account, the record a guess
    let elseIDv = AccountResolver.resolve(me, among: [me], app: .unknown, code: idOnly, loginEmail: foreign, loginAccount: otherAcct, names: [:], now: t0)
    check(elseIDv.readStale == nil && elseIDv.email == foreign && elseIDv.codeAccount == otherAcct && elseIDv.line != AccountResolver.staleWords
          && shownWeekly(elseIDv, id: otherAcct) == 40,
          "A3: folder {id, no address} + a verified reading with another id: Claude Code is on the reading's account, its numbers show")
    let sameAddrOtherID = AccountResolver.resolve(me, among: [me], app: .unknown, code: h2, loginEmail: h2.email, loginAccount: otherAcct, names: [:], now: t0)
    check(sameAddrOtherID.readStale == nil && !sameAddrOtherID.differs && sameAddrOtherID.email == h2.email
          && sameAddrOtherID.line != AccountResolver.staleWords && shownWeekly(sameAddrOtherID, id: otherAcct) == 40 && sameAddrOtherID.codeAccount == otherAcct,
          "folder {id, address} + a verified reading for that address with another id: no split, the reading's id is Claude Code's (the ids decide)")
    let bothOther = AccountResolver.resolve(me, among: [me], app: .unknown, code: h2, loginEmail: foreign, loginAccount: otherAcct, readingVerified: false,
                                            names: [:], now: t0)
    check(bothOther.readStale == true && bothOther.codeName == h2.email && shownWeekly(bothOther, id: otherAcct) == nil,
          "…another id and another address: stale, shown nowhere")
    // …and the way back shows where the reason does: the card, the Dock panel and menu, the menu bar row (its record is the
    // one shownWeekly just wrote); the Dock panel's age line says they aren't this account's, never "Reading usage…"
    let staleShow = ProfileShow.load(me, now: t0)
    let (staleNote, staleMenu, staleAge) = MainActor.assumeIsolated { let d = dockOf(me, staleShow); return (d.panel.activeNote, titles(d.menu), d.panel.noNumbers) }
    let staleLine = AccountResolver.staleWords
    check(bothOther.line == staleLine && cardRow(me, now: t0).line == staleLine && staleNote == staleLine && !staleMenu.contains(DockTileMenu.fit(staleLine))
          && MenuBarRow.lineWords(MenuBarItems.Profile(show: staleShow)) == staleLine && staleLine.contains("sign in to read again") && staleLine.count <= 70
          && staleAge == "Not read for this account",
          "a stale reading: \"\(staleLine)\" on the card, in the Dock panel (not the Dock menu: no states there), on the menu bar row; the age line: \(staleAge ?? "-")")
    // (a record that names its account by id alone against a reading known by its address alone: whose the numbers are isn't
    // known from the record; with the reading not verified they are stale, said by the one stale line, as every other
    // reading for another account is; the record's own line for it went with the kit's rule)
    let lone = AccountResolver.resolve(me, among: [me], app: .unknown, code: idOnly, loginEmail: foreign, readingVerified: false, names: [:], now: t0)
    let loneWeekly = shownWeekly(lone), loneShow = ProfileShow.load(me, now: t0)
    let (loneNote, loneMenu) = MainActor.assumeIsolated { let d = dockOf(me, loneShow); return (d.panel.activeNote, titles(d.menu)) }
    let words = AccountResolver.staleWords
    check(lone.readStale == true && !lone.differs && lone.email == nil && lone.account == h2.account && lone.numbersFor == foreign
          && lone.codeName == short8 && lone.line == words && loneWeekly == nil
          && AccountView.of(Store.status(for: me, now: t0)).label == short8,
          "folder {id, no address} + an unverified reading with an address and no id, no app: stale, numbers shown nowhere, never labelled with the reading's address")
    // A3: verified, the reading's address is Claude Code's account (Anthropic's word), the record's id alone only a guess
    let loneV = AccountResolver.resolve(me, among: [me], app: .unknown, code: idOnly, loginEmail: foreign, names: [:], now: t0)
    check(loneV.readStale == nil && loneV.email == foreign && loneV.codeName == foreign && loneV.line != words && loneV.lit,
          "A3: folder {id, no address} + a verified reading by its address: Claude Code's account is the reading's")
    // (the Dock menu, stale or not: only the kept items, the same as one built from the profile alone)
    let keptTitles = titles(DockTileMenu.menu(DockTileMenu.dockRows(me, windowOpen: false, appRunning: true), light: nil, views: false,
                                              target: NSObject(), action: Selector(("x:"))))
    check(staleMenu == keptTitles && loneMenu == keptTitles && keptTitles.contains("Profile settings…") && keptTitles.contains("Dashboard"),
          "the Dock menu, with a stale reading or an unknown owner: only the kept items, nothing of the record (\(staleMenu))")
    check(cardRow(me, now: t0).line == words && loneNote == words && !loneMenu.contains(DockTileMenu.fit(words))
          && MenuBarRow.lineWords(MenuBarItems.Profile(show: loneShow)) == words && words.contains("sign in")
          && words.count <= "Claude Code's .claude.json is too large to read: its account isn't known here.".count,
          "…and the reason shows: on the card, in the Dock panel (not the Dock menu), on the menu bar row (sign in, the sweep's verb), no longer than the too-large line those rows show")
    let appOnIt = AccountResolver.resolve(me, among: [me], app: appH2, code: idOnly, loginEmail: foreign, readingVerified: false, names: [:], now: t0)
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
    let moved = AccountResolver.resolve(me, among: [me], app: .unknown, code: h2, loginEmail: foreign, readingVerified: false, names: [:], now: t0)
    check(moved.readStale == true && moved.email == h2.email && moved.codeName == h2.email && moved.line == words && shownWeekly(moved) == nil,
          "folder {id, address} + another address's reading, not verified: stale, as before")
    let movedV = AccountResolver.resolve(me, among: [me], app: .unknown, code: h2, loginEmail: foreign, names: [:], now: t0)
    check(movedV.readStale == nil && movedV.email == foreign && movedV.codeName == foreign && movedV.account == nil && shownWeekly(movedV) == 40,
          "A3: folder {id, address} + another address's verified reading: Claude Code is on the reading's account (no ids from the record)")
    let noSeat = AccountResolver.resolve(me, among: [me], app: .unknown, code: nil, loginEmail: foreign, names: [:], now: t0)
    check(noSeat.readStale == nil && noSeat.email == foreign && noSeat.numbersFor == foreign && shownWeekly(noSeat) == 40 && noSeat.lit,
          "no folder seat, a verified reading's address only: the reading names Claude Code's account, lit (A3: the record signed out is only a guess)")
    let noSeatOut = AccountResolver.resolve(me, among: [me], app: .unknown, code: nil, loginEmail: foreign, readingVerified: false, names: [:], now: t0)
    check(noSeatOut.readStale == nil && noSeatOut.email == foreign && !noSeatOut.lit,
          "…the reading's sign-in gone: nobody is Claude Code's account (not lit), the reading only labels its numbers, as before")
    // the record too large to read: not known, said so; a verified reading names the account all the same
    let hugeV = AccountResolver.resolve(me, among: [me], app: .unknown, code: nil, loginEmail: foreign, names: [:], recordTooLarge: true, now: t0)
    let hugeOut = AccountResolver.resolve(me, among: [me], app: .unknown, code: nil, loginEmail: nil, names: [:], recordTooLarge: true, now: t0)
    check(hugeV.recordTooLarge == nil && hugeV.email == foreign && hugeOut.recordTooLarge == true && hugeOut.line?.contains("too large") == true,
          "a .claude.json too large to read: not known with no reading; a verified reading names Claude Code's account")
    // the seat by the reading's organisation (the profile reply's organization.uuid): one login's personal and Team seats share
    // the account id and the address, so another organisation, both known, is another seat: stale, whatever the address
    // says; the id proof stays as it was; one organisation not known on either side never makes a mismatch
    let teamOrg = "00000000-0000-4000-8000-0000000000c2"
    func orgRead(_ code: Seat?, _ org: String?, account: String? = h2.account, verified: Bool = true) -> ResolvedAccount {
        AccountResolver.resolve(me, among: [me], app: .unknown, code: code, loginEmail: h2.email, loginAccount: account, loginOrganization: org,
                                readingVerified: verified, names: [:], now: t0)
    }
    let otherSeatRead = orgRead(h2, teamOrg, verified: false)
    check(otherSeatRead.readStale == true && !otherSeatRead.differs && otherSeatRead.line == AccountResolver.staleWords
          && otherSeatRead.email == h2.email && shownWeekly(otherSeatRead, id: h2.account) == nil,
          "folder {id, org, address} + an unverified reading with that id and address on another organisation: stale (the other seat), shown nowhere, the way back said")
    // A2 + A3: verified, the reading's seat (the Team one) is Claude Code's; the record's personal seat only a guess, no
    // organisation of it borrowed
    let otherSeatV = orgRead(h2, teamOrg)
    check(otherSeatV.readStale == nil && otherSeatV.codeOrganization == teamOrg && otherSeatV.codeAccount == h2.account
          && shownWeekly(otherSeatV, id: h2.account) == 40,
          "A2/A3: a verified reading on the other seat of the record's account: that seat is Claude Code's, its numbers show")
    // a seat not known (the reading names no organisation, the record does): the same account, its organisation not known
    let notKnown = orgRead(h2, nil)
    check(notKnown.codeAccount == h2.account && notKnown.codeOrganization == nil && notKnown.readStale == nil,
          "A2: one side names no organisation: the account, with no organisation taken from the record (not known)")
    let sameSeat = orgRead(h2, h2.organization!.uppercased())
    check(sameSeat.readStale == nil && !sameSeat.differs && shownWeekly(sameSeat, id: h2.account) == 40,
          "…on the folder's organisation (any case): the profile's numbers")
    let noOrgFolder = orgRead(Seat(account: h2.account, organization: nil, email: h2.email), teamOrg)
    let emptyOrgFolder = orgRead(Seat(account: h2.account, organization: "", email: h2.email), teamOrg)
    let noOrgRead = orgRead(h2, nil), emptyOrgRead = orgRead(h2, "")
    check([noOrgFolder, emptyOrgFolder, noOrgRead, emptyOrgRead].allSatisfy { $0.readStale == nil && !$0.differs },
          "an organisation not known on either side (nil or empty): never a mismatch")
    let orgWithoutID = orgRead(h2, teamOrg, account: nil)
    check(orgWithoutID.readStale == nil && !orgWithoutID.differs, "an organisation without the reading's account id: not taken (kept only with the id)")
    let guardKept = orgRead(h2, h2.organization, account: otherAcct)
    check(guardKept.readStale == nil && !guardKept.differs, "the ids' guard unchanged: another id, the folder's organisation and address keep the reading")
    var withOrgRec = IconStatus(state: "ok"); withOrgRec.numbersOwner = h2.email; withOrgRec.numbersAccount = h2.account; withOrgRec.numbersOrganization = teamOrg
    let orgBack = StatusCodec.encode(withOrgRec).flatMap(StatusCodec.decode)
    var orgNoAcct = withOrgRec; orgNoAcct.numbersAccount = nil
    check(orgBack?.readingOrganization == teamOrg && orgNoAcct.readingOrganization == nil
          && StatusCodec.decode(Data(#"{"state":"ok","numbersOwner":"hex-2@example.com","numbersAccount":"x"}"#.utf8))?.readingOrganization == nil,
          "status record: the reading's organisation kept with its id; none without it, none in an older record")
    // differs on a stale reading: the folder's account against the app's by the ids, never the addresses (an address
    // changed on the same id is no split; another id with the app's address is one)
    let renamed = Seat(account: h2.account, organization: h2.organization, email: "renamed-2@example.com")
    let staleSameID = AccountResolver.resolve(me, among: [me], app: appH2, code: renamed, loginEmail: foreign, readingVerified: false, names: [:], now: t0)
    check(staleSameID.readStale == true && staleSameID.fromApp && !staleSameID.differs,
          "a stale reading, the app on the folder's id under another address: no split (by the ids)")
    let otherIDSameAddr = Seat(account: otherAcct, organization: h2.organization, email: h2.email)
    let staleOtherID = AccountResolver.resolve(me, among: [me], app: appH2, code: otherIDSameAddr, loginEmail: foreign, readingVerified: false,
                                               names: [:], now: t0)
    check(staleOtherID.readStale == true && staleOtherID.differs, "…the folder on another id with the app's address: a split (by the ids)")
    // the short ask's word (a running claude's own initialize account: an address and an organisation name, no ids)
    let word = SignedInAccount(email: h2.email, organizationName: "Team Two", origin: .process)
    let recNamed = SignedInAccount(accountID: h2.account, email: h2.email, organizationID: h2.organization, organizationName: "team two", origin: .record)
    let confirmed = AccountResolver.resolve(me, among: [me], app: .unknown, code: recNamed, loginEmail: h2.email, loginAccount: h2.account,
                                            loginOrganization: h2.organization, process: word, names: [:], now: t0)
    check(confirmed.readStale == nil && confirmed.codeAccount == h2.account && confirmed.codeOrganization == h2.organization?.lowercased()
          && confirmed.email == h2.email,
          "A3/A5: the short ask names the record's seat (its organisation's name in another case): the same seat, its ids from the record, the numbers stand")
    let asked = AccountResolver.resolve(me, among: [me], app: .unknown, code: h2, loginEmail: foreign, loginAccount: otherAcct,
                                        process: SignedInAccount(email: h2.email, origin: .process), names: [:], now: t0)
    check(asked.readStale == true && asked.line == AccountResolver.staleWords && asked.codeName == h2.email && shownWeekly(asked, id: otherAcct) == nil,
          "A3: the short ask names another account than the reading's (the Keychain moved on): Claude Code's account is the process's, the reading stale, shown nowhere")
    let askedSame = AccountResolver.resolve(me, among: [me], app: .unknown, code: h2, loginEmail: foreign, loginAccount: otherAcct,
                                            process: SignedInAccount(email: foreign, origin: .process), names: [:], now: t0)
    check(askedSame.readStale == nil && askedSame.email == foreign && askedSame.line != AccountResolver.staleWords,
          "A3: the short ask confirms the reading's account over the record: the record is stale, the numbers stand")
    // A2 with the short ask: its word names the organisation by name only. A reading that names its organisation by id
    // only can't be told from the other seat on the address: not that seat's numbers (stale, read again). With the
    // reply's organisation name the two are told apart: the same name stands, another name is the other seat
    let personalWord = SignedInAccount(email: h2.email, organizationName: "Personal Two", origin: .process)
    func teamReading(_ name: String?, word: SignedInAccount) -> ResolvedAccount {
        AccountResolver.resolve(me, among: [me], app: .unknown, code: h2, loginEmail: h2.email, loginAccount: h2.account,
                                loginOrganization: teamOrg, loginOrganizationName: name, process: word, names: [:], now: t0)
    }
    let unbridged = teamReading(nil, word: personalWord)
    check(unbridged.readStale == true && unbridged.line == AccountResolver.staleWords && shownWeekly(unbridged, id: h2.account) == nil,
          "A2: the short ask names a seat by name, the reading its seat by id only: the seat can't be told, stale, shown nowhere")
    check(teamReading("Personal Two", word: personalWord).readStale == nil
          && teamReading("Team Two", word: personalWord).readStale == true,
          "A2/A5: with the reply's organisation name: the same name (any case) stands, another name (the Team seat) is stale")
    // the ids' guard on the unverified path: a reading for the record's address under another id is the same account
    let guardedRead = AccountResolver.resolve(me, among: [me], app: .unknown, code: h2, loginEmail: h2.email, loginAccount: otherAcct,
                                              readingVerified: false, names: [:], now: t0)
    let guardedOtherSeat = AccountResolver.resolve(me, among: [me], app: .unknown, code: h2, loginEmail: h2.email, loginAccount: otherAcct,
                                                   loginOrganization: teamOrg, readingVerified: false, names: [:], now: t0)
    check(guardedRead.readStale == nil && !guardedRead.differs && guardedRead.codeAccount == h2.account && shownWeekly(guardedRead, id: otherAcct) == 40
          && guardedOtherSeat.readStale == true,
          "the ids' guard, reading not verified: the record's address under another id keeps the reading (no split); another organisation still stales")
    // codeOrganization the other way: the record names no organisation, the verified reading does: the reading's seat
    let readingOrgOnly = orgRead(Seat(account: h2.account, organization: nil, email: h2.email), teamOrg)
    check(readingOrgOnly.codeOrganization == teamOrg && readingOrgOnly.readStale == nil,
          "a record with no organisation, a verified reading with one: Claude Code's seat is the reading's (its organisation)")
    // the Switch page's target for Terminal's account: the profile's seat only when it is Claude Code's very seat
    let teamView = AccountView(label: h1.email, numbersOwner: h2.email, lit: true, account: h1.account, differs: true, codeAccount: h2.account,
                               codeOrganization: teamOrg)
    var orgView = teamView; orgView.codeOrganization = h2.organization?.lowercased()
    var oldView = teamView; oldView.codeOrganization = nil
    check(!teamView.isCodeSeat(h2) && orgView.isCodeSeat(h2) && oldView.isCodeSeat(h2),
          "isCodeSeat: the same id on another organisation isn't Claude Code's seat; the same organisation is; not known decides by the id")
    // A1: a record that names an address and no id is signed in (by the address)
    let addrOnly = AccountResolver.resolve(me, among: [me], app: .unknown, code: SignedInAccount(email: h2.email, origin: .record), loginEmail: nil,
                                           names: [:], now: t0)
    check(addrOnly.lit && addrOnly.email == h2.email && addrOnly.account == nil && addrOnly.codeName == h2.email,
          "A1: a record with an address and no id: Claude Code is on that address (lit), no id known")
    // the short ask's rule: only on a sign-in change or a disagreement, each state once, at most every ShortAsk.floor
    let s0 = ShortAsk.State(generation: 0, reading: "a"), s1 = ShortAsk.State(generation: 1, reading: "a")
    let long = t0.addingTimeInterval(-ShortAsk.floor - 1), lately = t0.addingTimeInterval(-60)
    func due(_ last: ShortAsk.State?, _ now: ShortAsk.State, differs: Bool = false, lastAsk: Date = .distantPast, asking: Bool = false,
             ready: Bool = true) -> Bool {
        ShortAsk.due(last: last, now: now, differs: differs, lastAsk: lastAsk, at: t0, asking: asking, folderReady: ready)
    }
    check(!due(nil, s0) && due(nil, s0, differs: true), "the short ask: the first look asks only when the record and the reply disagree")
    check(!due(s0, s0) && !due(s0, s0, differs: true), "…never twice about one state (not on every tick)")
    check(due(s0, s1) && due(s0, s1, lastAsk: long) && !due(s0, s1, lastAsk: lately), "…a sign-in change asks, at most once every \(Int(ShortAsk.floor / 60)) minutes")
    check(due(s0, ShortAsk.State(generation: 0, reading: "b"), differs: true) && !due(s0, ShortAsk.State(generation: 0, reading: "b")),
          "…another reading that disagrees with the record asks; one that agrees doesn't")
    check(!due(s0, s1, asking: true) && !due(s0, s1, ready: false), "…never while one runs, never on a folder that isn't there")
    // the record's new field: an older record (no numbersAccount) decodes, with no id; a new one keeps it
    let olderRec = StatusCodec.decode(Data(#"{"state":"ok","numbersOwner":"hex-2@example.com","weekly":40}"#.utf8))
    var withID = IconStatus(state: "ok"); withID.numbersOwner = h2.email; withID.numbersAccount = h2.account
    let back = StatusCodec.encode(withID).flatMap(StatusCodec.decode)
    var noOwner = withID; noOwner.numbersOwner = nil
    check(olderRec?.numbersOwner == h2.email && olderRec?.numbersAccount == nil && olderRec?.readingAccount == nil
          && back?.numbersAccount == h2.account && back?.readingAccount == h2.account && noOwner.readingAccount == nil,
          "status record: an older one decodes without the reading's id; a new one keeps it; no id without the reading's owner")
    // the lists' helpers: the record names ids and addresses, no organisation
    let v = AccountView(label: h1.email, numbersOwner: h2.email, lit: true, account: h1.account, differs: true, codeAccount: h2.account)
    check(v.isActive(StandbyAccount(email: "", seat: upper(h1), id: "a")) && v.isActive(StandbyAccount(email: "HEX-1@example.com", id: "b"))
          && v.isActive(StandbyAccount(email: h1.email!, seat: otherOrg, id: "c")) && !v.isActive(StandbyAccount(email: h1.email!, seat: otherID, id: "d")),
          "isActive: ids in any case; an address only by the address; the record names no organisation; another id never by the address")
    check(v.isCodeRow(id: h2.account.uppercased(), email: nil) && v.isCodeRow(id: nil, email: "HEX-2@example.com") && !v.isCodeRow(id: otherID.account, email: h2.email),
          "isCodeRow: by the id in any case, else the address; another id never by the address")

    // the window's own answers (Settings.resolveNow right after a switch or log-in, resolveWithoutAgent while the agent is
    // away) with a record read on the login's other seat (the same id and address, the Team organisation) while the folder
    // is on its own: stale in both, as in the agent's; on the folder's own organisation, the numbers stand
    let keepAnnounce = Store.announce, keepAnnounceStatus = Store.announceStatus
    Store.announce = {}; Store.announceStatus = { _ in }        // a throwaway home: no running cl_audit is told
    defer { Store.announce = keepAnnounce; Store.announceStatus = keepAnnounceStatus }
    func folderOn(_ dir: String, _ s: Seat) {
        put(expand(dir + "/.claude.json"),
            #"{"oauthAccount":{"accountUuid":"\#(s.account)","organizationUuid":"\#(s.organization!)","emailAddress":"\#(s.email!)"}}"#)
    }
    func seatRecord(_ id: String, org: String) {
        var r = IconStatus(state: "ok"); r.loginEmail = h2.email; r.numbersOwner = h2.email; r.numbersAccount = h2.account
        r.numbersOrganization = org; r.weekly = 40; r.updatedAt = Date()
        _ = Store.writeStatus(id, r)
    }
    var seatNow = profile("hseatnow", "~/.claude-hseatnow", h2); seatNow.claudeWindow = false
    var seatAway = profile("hseataway", "~/.claude-hseataway", h1); seatAway.claudeWindow = false
    folderOn("~/.claude-hseatnow", h2); folderOn("~/.claude-hseataway", h1)
    seatRecord("hseatnow", org: teamOrg)
    var awayRec = IconStatus(state: "ok"); awayRec.loginEmail = h1.email; awayRec.numbersOwner = h1.email; awayRec.numbersAccount = h1.account
    awayRec.numbersOrganization = otherOrg.organization; awayRec.weekly = 40; awayRec.updatedAt = Date()
    _ = Store.writeStatus("hseataway", awayRec)
    try! Store.save([seatNow, seatAway])                        // (profiles on file: not the first run, which answers nothing)
    let seatModel = SettingsModel()
    seatModel.accounts = [seatNow, seatAway]
    seatModel.resolveNow("hseatnow")
    let nowAnswer = Store.status("hseatnow")?.resolved
    // (section 4 ran the agent in this very process: its mark names this pid with a fresh beat, so the window would rightly
    // leave the answer to it. Gone, the agent is away as resolveWithoutAgent expects)
    try? fm.removeItem(at: Agent.markURL)
    let agentAway = !Agent.isAlive(Agent.readMark())
    seatModel.resolveWithoutAgent()
    let awayAnswer = Store.status("hseataway")?.resolved
    check(Store.isHeld("hseatnow") && nowAnswer?.readStale == true && nowAnswer?.line == AccountResolver.staleWords
          && Store.status(for: seatNow)?.weekly == nil,
          "resolveNow, a record read on the other seat (Team organisation): stale, its numbers shown nowhere")
    check(agentAway && Store.isHeld("hseataway") && awayAnswer?.readStale == true && awayAnswer?.line == AccountResolver.staleWords
          && Store.status(for: seatAway)?.weekly == nil,
          "resolveWithoutAgent, a record read on the other seat: stale, its numbers shown nowhere (agent away \(agentAway), held \(Store.isHeld("hseataway")), first run \(seatModel.isFirstRun), \(String(describing: awayAnswer?.readStale)))")
    seatRecord("hseatnow", org: h2.organization!.uppercased())
    seatModel.resolveNow("hseatnow")
    let sameAnswer = Store.status("hseatnow")?.resolved
    check(sameAnswer?.readStale == nil && Store.status(for: seatNow)?.weekly == 40,
          "resolveNow, the record read on the folder's own organisation (any case): the profile's numbers")
}

// MARK: Claude window off: what is kept. A profile made with the window off never had a folder or a sign-in, so Settings
// must not say they are kept or show a data folder that isn't there (throwaway folder in the throwaway home).
do {
    let madeDir = home + "/Library/Application Support/Claude-hwinkept"
    let neverDir = "~/Library/Application Support/Claude-hwinnever"
    try? fm.removeItem(atPath: madeDir); try? fm.removeItem(atPath: expand(neverDir))
    try! fm.createDirectory(atPath: madeDir, withIntermediateDirectories: true)
    let madeTilde = "~/Library/Application Support/Claude-hwinkept"
    check(DesktopMode.hasKept(.standard, dataDir: ""), "hasKept: the usual Claude app always has something kept")
    check(DesktopMode.hasKept(.separate, dataDir: madeTilde), "hasKept: an own window whose folder exists (path with ~)")
    check(!DesktopMode.hasKept(.separate, dataDir: neverDir), "hasKept: an own window whose folder was never made")
    check(!DesktopMode.hasKept(.separate, dataDir: ""), "hasKept: an own window with no folder named")

    let keptInfo = DesktopMode.switchInfo(name: "Ann", mode: .separate, dataDir: madeTilde, windowOn: false)
    let neverInfo = DesktopMode.switchInfo(name: "Ann", mode: .separate, dataDir: neverDir, windowOn: false)
    let stdInfo = DesktopMode.switchInfo(name: "Ann", mode: .standard, dataDir: "", windowOn: true)
    let goneInfo = DesktopMode.switchInfo(name: "Ann", mode: .separate, dataDir: neverDir, windowOn: true)
    check(goneInfo.contains("Its data folder: \(neverDir), missing (deleted outside cl_audit?).") && !goneInfo.contains("none yet"),
          "Claude window row help, window on but its folder gone: the path, said missing, never \"none yet\"")
    check(DesktopMode.switchInfo(name: "Ann", mode: .separate, dataDir: madeTilde, windowOn: true) == DesktopMode.switchInfo(name: "Ann", mode: .separate, dataDir: madeTilde, windowOn: false),
          "Claude window row help, folder exists: the same words whether the window is on or off")
    check(keptInfo.contains("its folder and sign-in are kept, so turning it back on needs no new sign-in")
          && keptInfo.contains("Its data folder: \(madeTilde).") && !keptInfo.contains("none yet"),
          "Claude window row help, folder exists: kept words and the folder's path")
    check(!neverInfo.contains("are kept") && !neverInfo.contains("needs no new sign-in") && !neverInfo.contains("Claude-hwinnever")
          && neverInfo.contains("asks for a sign-in on its first start")
          && neverInfo.contains("Its data folder: none yet (made when the window is turned on)."),
          "Claude window row help, folder never made: no kept words, no path, says it asks for a sign-in on its first start")
    check(stdInfo.contains("are kept") && stdInfo.contains("Its data folder: \(FolderKey.standardDataDir)."),
          "Claude window row help, the usual app: kept words and the usual data folder")
    let unnamedOn = DesktopMode.switchInfo(name: "Ann", mode: .separate, dataDir: "", windowOn: true)
    check(unnamedOn.contains("Its data folder: none named yet.") && !unnamedOn.contains("made when the window is turned on"),
          "Claude window row help, window on with no folder named (an older profile): \"none named yet\", never \"made when turned on\"")

    func offNote(_ e: AccountEntry) -> String? {
        var on = e; on.claudeWindow = true
        var off = e; off.claudeWindow = false
        return SettingNotes.note(from: on, to: off)?.text
    }
    var keptEntry = profile("hwinkept", "~/.claude-hwinkept", nil); keptEntry.desktop = .separate; keptEntry.desktopDataDir = madeTilde
    var neverEntry = profile("hwinnever", "~/.claude-hwinnever", nil); neverEntry.desktop = .separate; neverEntry.desktopDataDir = neverDir
    let usualEntry = profile("hwinusual", "~/.claude-hwinusual", nil)
    check(offNote(keptEntry)?.contains("Its sign-in is kept, so turning it back on needs no new sign-in.") == true,
          "note on switching the window off, folder exists: today's words")
    check(offNote(usualEntry)?.contains("Its sign-in is kept") == true, "note on switching the window off, the usual app: today's words")
    let neverNote = offNote(neverEntry) ?? ""
    check(neverNote.contains("nothing opens one") && !neverNote.contains("is kept") && !neverNote.contains("needs no new sign-in")
          && neverNote.contains("gets its own folder and asks for a sign-in on its first start"),
          "note on switching the window off, folder never made: no kept words, own folder and sign-in on the first start")
    func onNote(_ e: AccountEntry) -> String? {
        var on = e; on.claudeWindow = true
        var off = e; off.claudeWindow = false
        return SettingNotes.note(from: off, to: on)?.text
    }
    check(onNote(keptEntry)?.contains("has a Claude window again, signed in to its account") == true,
          "note on switching the window on, folder exists: today's words")
    check(onNote(usualEntry)?.contains("has a Claude window again") == true, "note on switching the window on, the usual app: today's words")
    let neverOn = onNote(neverEntry) ?? ""
    check(neverOn.contains("has a Claude window now") && !neverOn.contains("again") && !neverOn.contains("signed in to its account")
          && neverOn.contains("asks for a sign-in on its first start"),
          "note on switching the window on, folder never made: no \"again\" or \"signed in\", a sign-in on the first start")

    // on, then off, with the folder made by the switch (setClaudeWindow): the folder is there, so what the helper says follows it
    let wm = SettingsModel()
    var ownOff = neverEntry; ownOff.claudeWindow = false
    wm.accounts = [ownOff]
    check(!DesktopMode.hasKept(ownOff.desktop, dataDir: ownOff.desktopDataDir), "before the window is first turned on: nothing kept")
    wm.setClaudeWindow(ownOff.id, true)
    check(DesktopMode.hasKept(.separate, dataDir: neverDir), "setClaudeWindow on makes the window's folder")
    try? fm.removeItem(atPath: madeDir); try? fm.removeItem(atPath: expand(neverDir))
}

// a profile's own light (ProfileLED, the Settings tile bar and the dashboard card's name): each colour gives its LED, lit in
// that colour; a profile with no colour of its own (its Dock icon by usage or graphite, none picked) gives the unlit one
do {
    check(TileColor.accents.allSatisfy { c in
        let l = ProfileLED.lamp(c)
        return l.lit && l.color == c.color(fiveHour: nil, stale: false)
    }, "each of the ten colours gives its LED, lit in that colour")
    check(ProfileLED.lamp(.teal).color == TileColor.hex(0x14b8a6) && ProfileLED.lamp(.pink).color == TileColor.hex(0xec4899)
          && ProfileLED.lamp(.lime).color == TileColor.hex(0x84cc16), "…the swatches' own colours (teal, pink, lime by value)")
    check(!ProfileLED.lamp(nil).lit && ProfileLED.lamp(nil).color == nil && !ProfileLED.lamp(.usage).lit && !ProfileLED.lamp(.graphite).lit,
          "no colour of its own (or by usage): the unlit LED")
    var e = AccountEntry(id: "led", name: "Led", label: "LED", configDir: "~/.claude-led")
    e.accent = nil; e.color = .usage
    let usage = e.ownColor
    e.color = .graphite
    let graphite = e.ownColor
    e.color = .teal
    let tile = e.ownColor
    e.accent = .pink
    let picked = e.ownColor
    check(usage == nil && graphite == nil && tile == .teal && picked == .pink && !ProfileLED.lamp(usage).lit && ProfileLED.lamp(picked).lit,
          "the profile's own colour: its pick, else its Dock icon's colour; none (unlit) for a Dock icon by usage or graphite")
    e.accent = nil; e.color = .usage
    check(e.accentColor == .orange, "accentColor keeps its orange for the places that must draw a colour (the menu bar icon's style, the picker)")
    // a profile's colour reads the same everywhere: every dot before a profile's name is its light (ProfileLED), never a
    // flat dot in accentColor (orange for a profile with none) — the tile bar, the card, the launcher palette, the menu bar's
    // menu, the Dock panels
    let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    var flat: [String] = [], lights: [String: Int] = [:]
    for f in ["Launcher.swift", "MenuBar.swift", "Details.swift", "Settings.swift"] {
        let lines = (try? String(contentsOf: src.appendingPathComponent(f), encoding: .utf8))?.components(separatedBy: "\n") ?? ["(missing \(f))"]
        for (i, l) in lines.enumerated() where l.contains("Circle().fill") && l.contains("accent") {
            flat.append("\(f):\(i + 1)")
        }
        lights[f] = lines.filter { $0.contains("ProfileLED(color:") && $0.contains("ownColor") }.count
    }
    check(flat.isEmpty && lights["Launcher.swift", default: 0] >= 2 && lights["MenuBar.swift", default: 0] >= 1
          && lights["Details.swift", default: 0] >= 2 && lights["Settings.swift", default: 0] >= 1,
          "every dot before a profile's name is its own light (ownColor, unlit for none), never an orange fallback: flat \(flat), lights \(lights)")
    // the Dock panel takes the profile's own colour as the icon app builds it (DetailsInfo.of): pink lit, none unlit
    e.accent = .pink
    let pinkPanel = DetailsInfo.of(ProfileShow.of(e, raw: nil), name: e.name, icon: NSImage(), problem: nil)
    e.accent = nil; e.color = .usage
    let nonePanel = DetailsInfo.of(ProfileShow.of(e, raw: nil), name: e.name, icon: NSImage(), problem: nil)
    check(pinkPanel.ownColor == .pink && ProfileLED.lamp(pinkPanel.ownColor).lit && nonePanel.ownColor == nil && !ProfileLED.lamp(nonePanel.ownColor).lit,
          "the Dock panel's light: the profile's own colour (pink lit), unlit for a profile with none, never orange")
    // keys and charts that stand for a profile (the hub's ruling): its own colour; none: a plain key, an unlit strip, a
    // neutral grey series (a shade of its own each); never an orange that isn't the profile's
    // (compared by their sRGB hex, never by Color's own equality)
    func hex(_ c: Color?) -> String? {
        guard let c, let n = NSColor(c).usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02x%02x%02x", Int((n.redComponent * 255).rounded()), Int((n.greenComponent * 255).rounded()), Int((n.blueComponent * 255).rounded()))
    }
    let orange = hex(Color(nsColor: Painter.orange))
    check(hex(ProfileLED.keyTint(.teal)) == "14b8a6" && ProfileLED.keyTint(nil) == nil && ProfileLED.keyTint(.graphite) == nil
          && hex(ProfileLED.neutral) != orange && orange != nil,
          "a profile's key: its own colour, none (a plain key) for a profile with none; the state light's neutral isn't orange")
    var pinkE = e; pinkE.id = "s-pink"; pinkE.accent = .pink
    var noneA = e; noneA.id = "s-none-a"; noneA.accent = nil; noneA.color = .usage
    var noneB = e; noneB.id = "s-none-b"; noneB.accent = nil; noneB.color = .graphite
    let all = [noneB, pinkE, noneA]
    let series = ProfileLED.seriesColors(all, among: all).mapValues { hex($0) }
    let shownOnlyB = ProfileLED.seriesColors([noneB], among: all).mapValues { hex($0) }
    let reordered = ProfileLED.seriesColors(all.reversed(), among: all.reversed()).mapValues { hex($0) }
    check(series["s-pink"] == "ec4899" && series["s-none-a"].map { $0 != nil } == true && series["s-none-a"] != series["s-none-b"]
          && !series.values.contains(orange),
          "a chart's series: the profile's own colour, a grey of its own each for profiles with none, never orange: \(series)")
    check(shownOnlyB["s-none-b"] == series["s-none-b"] && reordered == series,
          "…the greys stay put when another profile is hidden or the profiles are reordered")
    // only the menu bar icon's "Profile colour" style and the colour picker keep accentColor's orange
    var accentUses: [String] = []
    for f in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where f.hasSuffix(".swift") && f != "Config.swift" {
        let lines = (try? String(contentsOf: src.appendingPathComponent(f), encoding: .utf8))?.components(separatedBy: "\n") ?? []
        for (i, l) in lines.enumerated() where l.contains("accentNSColor") || l.contains("accentColor") { accentUses.append("\(f):\(i + 1)") }
    }
    check(Set(accentUses.map { String($0.prefix { $0 != ":" }) }) == ["MenuBar.swift", "Settings.swift"] && accentUses.count == 3,
          "accentColor's orange only in the menu bar icon's colour style and the colour picker: \(accentUses)")
}

// why Claude Code's sign-in didn't open (ClaudeCLI.startLogin), each said in the switch's step (SwitchRunner.loginWords):
// a sign-in already open on the folder, processes that can't be read, a folder that isn't there, Terminal not opening
do {
    let dir = "~/.claude-refusal"
    try? fm.createDirectory(atPath: expand(dir), withIntermediateDirectories: true)
    let acct = Account(profile("rf", dir, seat(71, "rf@example.com")))
    let keepTerminal = ClaudeCLI.openTerminal
    var opened = 0
    ClaudeCLI.openTerminal = { _ in opened += 1; return true }
    defer { ClaudeCLI.openTerminal = keepTerminal; ClaudeCLI.loginTableSeam = nil }
    let me = getuid()
    let login = ProcessTable.Entry(pid: 901, uid: me, ruid: me, name: "claude",
                                   launch: ProcessTable.Launch(exe: "/usr/local/bin/claude", args: ["claude", "auth", "login"],
                                                               configDir: expand(dir), environmentRead: true))
    ClaudeCLI.loginTableSeam = { [login] }
    let already = ClaudeCLI.startLogin("/usr/bin/false", account: acct, email: nil)
    ClaudeCLI.loginTableSeam = { nil }
    let cantTell = ClaudeCLI.startLogin("/usr/bin/false", account: acct, email: nil)
    ClaudeCLI.loginTableSeam = { [] }
    ClaudeCLI.openTerminal = { _ in opened += 1; return false }
    let terminal = ClaudeCLI.startLogin("/usr/bin/false", account: acct, email: nil)
    ClaudeCLI.openTerminal = { _ in opened += 1; return true }
    let ok = ClaudeCLI.startLogin("/usr/bin/false", account: acct, email: nil)
    let gone = ClaudeCLI.startLogin("/usr/bin/false", account: Account(profile("rg", "~/.claude-refusal-gone", seat(72, "rg@example.com"))), email: nil)
    check(already == .alreadyOpen && cantTell == .cantTell && terminal == .terminalFailed && ok == .opened && gone == .folderNotReady && opened == 2,
          "startLogin says why: already open, can't tell, Terminal failed, opened, folder gone (Terminal asked only twice): \(already) \(cantTell) \(terminal) \(ok) \(gone) \(opened)")
    check(ClaudeCLI.openLogin("/usr/bin/false", account: acct, email: nil) == true, "openLogin is startLogin's .opened")
    let w = { (s: ClaudeCLI.LoginStart) in SwitchRunner.loginWords(s, folder: dir) }
    check(w(.alreadyOpen).contains("already open for ~/.claude-refusal") && w(.alreadyOpen).hasSuffix("Then Try again.")
          && w(.cantTell).contains("couldn't tell") && w(.terminalFailed) == "Terminal didn't open." && !w(.alreadyOpen).contains("Terminal didn't open"),
          "the switch's step says each reason, never \"Terminal didn't open\" for a sign-in already open: \(w(.alreadyOpen))")
    // the shared words (the default profile and first run say them too): no switch key named; a gone folder by goneLine
    let goneDir = "~/.claude-refusal-gone"
    check(!ClaudeCLI.loginWords(.alreadyOpen, folder: dir).contains("Try again")
          && ClaudeCLI.loginWords(.folderNotReady, folder: goneDir) == ClaudeCLI.goneLine(goneDir) && ClaudeCLI.goneLine(goneDir) != nil,
          "the shared words name no page's key; a folder that's gone says goneLine's words")
    try? fm.removeItem(atPath: expand(dir))
}

// ============ hidden addresses (AddressPrivacy): nothing of an address is drawn, spoken or put in a sentence ============
// With Show emails off an address is one fixed stand-in (drawn) and "hidden address" (spoken, in a sentence, a menu's title):
// never its first letter, its length, its domain or a hash. The suites read addresses in clear (the setting is applied "shown"
// at the top); this block turns it on for a moment (AddressPrivacy.apply writes nothing) and puts it back. Sample addresses only.
final class PickProbe: NSObject {
    var got: String?
    @objc func pick(_ s: NSMenuItem) { got = s.representedObject as? String }
}
MainActor.assumeIsolated {
    let now = Date()
    let a1 = "zedekiah@example.com", a2 = "orla-quinn@example.com"
    let a3 = "a-much-longer-address-than-the-stand-in@subdomain.example.test"
    let addrs = [a1, a2, a3]
    func leaks(_ s: String, of a: String) -> Bool {
        let local = String(a.split(separator: "@")[0]), domain = String(a.split(separator: "@")[1])
        let label = String(domain.split(separator: ".")[0])
        return s.localizedCaseInsensitiveContains(local) || s.localizedCaseInsensitiveContains(label)
            || s.localizedCaseInsensitiveContains(domain) || s.contains("•")
    }
    func clean(_ s: String) -> Bool { !addrs.contains { leaks(s, of: $0) } }
    AddressPrivacy.shared.apply(blur: true)
    defer { AddressPrivacy.shared.apply(blur: false); try? Store.save([]); Store.removeStatus("pa") }

    // the one setting: hidden unless it says shown; its key, its legacy key and its sense (a dictionary, never the real domain)
    final class Dict: AddressPrefs {
        var d: [String: Bool] = [:]
        func addressBool(_ key: String) -> Bool? { d[key] }
        func setAddressBool(_ value: Bool, _ key: String) { d[key] = value }
        func removeAddressKey(_ key: String) { d[key] = nil }
    }
    let prefs = Dict(), store = AddressSettings.makeStore(prefs: prefs)
    check(store.blurAddresses == true, "the setting: nothing stored means hidden")
    prefs.d["showEmails"] = true
    check(store.blurAddresses == false, "the setting: showEmails true = shown")
    prefs.d["showEmails"] = false
    check(store.blurAddresses == true, "the setting: showEmails false = hidden")
    prefs.d = ["blurEmails": true]
    check(store.blurAddresses == true, "the setting: the older blurEmails true = hidden")
    prefs.d = ["blurEmails": false]
    check(store.blurAddresses == false, "the setting: the older blurEmails false = shown")
    prefs.d = ["blurEmails": true, "showEmails": true]
    check(store.blurAddresses == false, "the setting: showEmails wins over the older key")
    check(AddressSettings.key == "showEmails" && Installer.managerID == "local.usage-n-uf", "the setting: the key and the domain the Settings app and every process share")

    // D1, the default settled once at the settings app's first start of this version: an install already set up (its profiles file is
    // there) keeps showing addresses, a fresh one stays hidden; a stored key, of either sense, is never overwritten
    do {
        // a check build's own note (AddressSettings.changeNote): never the real one, which would reach the operator's cl_audit
        check(AddressSettings.changeNote.hasPrefix("local.usage-n-uf.privacy-changed.checks-"),
              "the setting: a check build posts its own change note, never the real one (\(AddressSettings.changeNote))")
        let noteName = Notification.Name(rawValue: AddressSettings.changeNote)
        var posted = 0
        let obs = DistributedNotificationCenter.default().addObserver(forName: noteName, object: nil, queue: .main) { _ in posted += 1 }
        defer { DistributedNotificationCenter.default().removeObserver(obs) }
        func settle(_ start: [String: Bool], setUp: Bool) -> (wrote: Bool?, prefs: [String: Bool], blur: Bool) {
            let p = Dict(); p.d = start
            let s = AddressSettings.makeStore(prefs: p)
            let w = AddressSettings.settleDefault(prefs: p, store: s, setUp: setUp)
            return (w, p.d, s.blurAddresses)
        }
        let existing = settle([:], setUp: true)
        check(existing.wrote == true && existing.prefs == ["showEmails": true] && existing.blur == false,
              "D1: an existing install (profiles file there) with no key: showEmails true is written once, addresses shown: \(existing)")
        let fresh = settle([:], setUp: false)
        check(fresh.wrote == false && fresh.prefs == ["showEmails": false] && fresh.blur == true,
              "D1: a fresh install (no profiles file): hidden, written as showEmails false so it stays so: \(fresh)")
        let kept1 = settle(["showEmails": false], setUp: true), kept2 = settle(["showEmails": true], setUp: false)
        check(kept1.wrote == nil && kept1.prefs == ["showEmails": false] && kept1.blur
              && kept2.wrote == nil && kept2.prefs == ["showEmails": true] && !kept2.blur,
              "D1: a set key is never overwritten, either way, whether or not the install was set up")
        let legacy1 = settle(["blurEmails": true], setUp: true), legacy2 = settle(["blurEmails": false], setUp: false)
        check(legacy1.wrote == nil && legacy1.prefs == ["blurEmails": true] && legacy1.blur
              && legacy2.wrote == nil && legacy2.prefs == ["blurEmails": false] && !legacy2.blur,
              "D1: the older blurEmails alone is respected (hidden stays hidden on an existing install, shown stays shown on a fresh one), nothing written")
        let again = Dict(); again.d = [:]
        let againStore = AddressSettings.makeStore(prefs: again)
        _ = AddressSettings.settleDefault(prefs: again, store: againStore, setUp: true)
        againStore.blurAddresses = true                // the person hides them
        check(AddressSettings.settleDefault(prefs: again, store: againStore, setUp: true) == nil && againStore.blurAddresses,
              "D1: settled once: a later start never turns them on again")
        let until = Date().addingTimeInterval(3)
        while posted < 4 && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check(posted >= 4, "D1: each write of the default posts the change note, so the other processes follow (\(posted) notes)")
        // the wiring: only the settings app settles it, in start(), from the profiles file's presence
        let settingsSrc = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AddressSettings.swift"), encoding: .utf8)) ?? ""
        let settleCalls = settingsSrc.components(separatedBy: "settleDefault(prefs:").count - 1
        check(settingsSrc.contains("if isSettingsApp, let prefs { settleDefault(prefs: prefs, store: store, setUp: Store.exists) }") && settleCalls == 2
              && settingsSrc.contains("static let store = makeStore(prefs: prefs)"),
              "D1: start() settles it in the settings app only, from Store.exists (the profiles file), through the store's own prefs, and nowhere else")
    }

    // what is an address to hide: an address, an account id, an id prefix label; a phrase is no address
    check(["zedekiah@example.com", "account 1a2b3c4d", "1a2b3c4d", "1a2b3c4d-5e6f-4a7b"].allSatisfy(AddressSettings.hides)
          && !["another account", "Choose an account", "the sign-in", "its account", ""].contains(where: AddressSettings.hides),
          "hides: addresses, account ids and \"account <id prefix>\"; plain words stay as they are")
    check(addrs.allSatisfy { AddressSettings.words($0, blur: true) == "hidden address" && AddressSettings.words($0, blur: false) == $0 }
          && AddressSettings.words("account 1a2b3c4d", blur: true) == "hidden address" && AddressSettings.words("another account", blur: true) == "another account",
          "words: \"hidden address\" for every address and id, the address itself while shown, a phrase untouched (the override reaches it)")
    check(addrs.allSatisfy { AccountNames.shortName($0, shown: false) == "hidden address" && AccountNames.short($0) == "hidden address" }
          && AccountNames.shortName(a1, shown: true) == "zedekiah" && AccountNames.shortName("its account", shown: false) == "its account"
          && AccountNames.shortName("account 1a2b3c4d", shown: false) == "hidden address",
          "short names: the local part while shown, \"hidden address\" for every account while hidden (no first letter, no dots), a phrase as it is")

    // lines, notes, alerts and keys written from addresses: none holds a part of one
    let split = SplitUsage(app: a1, code: a2), switched = SplitUsage(app: a1, code: a2, switched: true)
    let said = [split.line, split.shortLine, split.numbersHint ?? "", split.key ?? "", switched.line, switched.shortLine,
                SplitUsage.switchingHead(a3), AccountNote(kind: .came, email: a3, profile: "Work", at: now).words,
                FolderChoice(path: "~/.claude-x", detail: a1).title, NewAccountSetup.folderWho("~/.claude-none")]
    check(said.allSatisfy(clean) && switched.shortLine.contains("hidden address")
          && split.line == SplitUsage.bandHead && split.key == SplitUsage.terminalSignInKey,
          "hidden: the usage lines, keys and notes written from addresses say \"hidden address\" and hold no part of any: \(said)")
    func server(_ s: Seat) -> SignedInAccount { SignedInAccount(accountID: s.account, email: s.email, organizationID: s.organization, origin: .server) }
    // the shared note after a sign-in line: no address in any form, whatever the setting
    let note = FolderRules.sharedNote([FolderRules.SeatOwner(profile: profile("other", "~/.claude-other", nil), standby: false)])
    let wrong = SignInSaid(.wrongAccount(signedIn: server(seat(8, a1)), wanted: server(seat(9, a2))), configDir: "~/.claude-x", shared: note)
    check(wrong.map { clean($0.text(emailsShown: false)) && $0.text(emailsShown: false).hasSuffix("\n" + (note ?? "-")) } == true
          && note.map { !$0.contains("@") && !$0.contains("hidden address") } == true,
          "hidden: the sign-in line holds no part of an address; the shared note after it names none in any form: \(note ?? "-")")
    AddressPrivacy.shared.apply(blur: false)
    check(switched.shortLine == "Switching to \(a2): one step left", "shown: the switch's short line names the address")
    AddressPrivacy.shared.apply(blur: true)

    // the Forget… question: its text says "hidden address", the address only in an accessory view that follows the pointer
    let standby = StandbyAccount(email: a3, seat: seat(43, a3), id: "k3")
    let alertHidden = AccountSettings.forgetAlert(standby, profile: "Work", blur: true)
    check(alertHidden.messageText == "Forget hidden address?" && clean(alertHidden.messageText) && clean(alertHidden.informativeText)
          && (alertHidden.accessoryView as? AddressLabel)?.accessibilityLabel() == "hidden address"
          && (alertHidden.accessoryView as? AddressLabel)?.drawnText == AddressText.standIn,
          "Forget…: hidden, the alert says \"hidden address\" and holds the address in an AddressLabel (the stand-in, \"hidden address\" to accessibility)")
    let alertShown = AccountSettings.forgetAlert(standby, profile: "Work", blur: false)
    check(alertShown.messageText == "Forget \(a3)?" && alertShown.accessoryView == nil, "Forget…: shown, the address is in the text, no accessory")

    // the switch menus: the rows of several hidden accounts are drawn (the kit's MenuAccountRowView), their words are the same for all
    var e = profile("pa", "~/.claude-pa", seat(41, a1)); e.claudeWindow = false
    e.standby = [StandbyAccount(email: a2, seat: seat(42, a2), id: "k2", plan: "Max", lastInUse: now.addingTimeInterval(-86400)),
                 StandbyAccount(email: a3, seat: seat(43, a3), id: "k3", plan: "Max", lastInUse: now.addingTimeInterval(-2 * 86400))]
    try! Store.save([e])
    var rec = IconStatus(state: "ok"); rec.loginEmail = a1; rec.expectedEmail = a1; rec.weekly = 100; rec.fiveHour = 12
    rec.weeklyResets = now.addingTimeInterval(3 * 3600); rec.fiveHourResets = now.addingTimeInterval(3600)
    rec.updatedAt = now.addingTimeInterval(-60); rec.source = "Anthropic"; rec.plan = "Max"
    rec.resolved = AccountResolver.resolve(e, among: [e], app: .unknown, code: seat(41, a1), loginEmail: a1, names: [:], now: now)
    _ = Store.writeStatus("pa", rec)
    let show = ProfileShow.load(e, now: now)
    func all(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
    // the menu bar's menu (this process draws it): the account in use and the standby accounts are the kit's account rows
    let barMenu = menuBarMenu(show)
    let rows = all(barMenu).compactMap { i in (i.view as? MenuAccountRowView).map { (i, $0) } }
    let keys = rows.compactMap { $0.0.representedObject as? String }
    check(rows.count == 3 && Set(keys) == [DockTileMenu.object(.switchTo, "pa~k2"), DockTileMenu.object(.switchTo, "pa~k3")],
          "hidden, the menu bar icon's menu: the account in use and the standby accounts are the kit's account rows, each standby one naming its Switch page: \(keys)")
    check(rows.allSatisfy { clean($0.0.title) && clean($0.1.accessibilityLabel() ?? "") && $0.0.title.contains("hidden address") && $0.1.accessibilityLabel() == $0.0.title }
          && titles(barMenu).allSatisfy(clean),
          "hidden, the menu bar icon's menu: no title or accessibility label holds any part of any address: \(titles(barMenu))")
    let standbyRows = rows.filter { $0.0.state != .on }, tickedRow = rows.first { $0.0.state == .on }
    check(Set(standbyRows.map { $0.1.naturalWidth }).count == 1 && standbyRows.count == 2 && standbyRows.allSatisfy { $0.0.title == "hidden address" },
          "hidden, the menu bar icon's menu: the two standby rows (a short and a long address) are the same width")
    check(tickedRow?.1.row.inUse == true && tickedRow?.0.title == "hidden address" && tickedRow?.1.row.prefix == "",
          "hidden, the menu bar icon's menu: the account in use ticks as the native rows do (its state, a mark in the margin), "
          + "no \"✓\" in its words, its address in the standby rows' column")
    // the Dock icon's menu (the Dock draws it, no item views): no account rows at all (the panel has them), so nothing of
    // any address
    let dockMenu = dockOf(e, show).menu
    check(!all(dockMenu).contains { $0.view != nil } && titles(dockMenu).allSatisfy(clean)
          && !all(dockMenu).contains { ($0.representedObject as? String)?.hasPrefix("switchTo:") == true }
          && !titles(dockMenu).contains("hidden address"),
          "hidden, the Dock icon's menu: plain titles, no account row and nothing of any address: \(titles(dockMenu))")
    // picking a row sends its action with the Switch page's key (as a native item does)
    let probe = PickProbe()
    let pickRow = DockTileMenu.AddressRow(address: a2, act: .switchTo, target: "pa~k2")
    let pickItem = DockTileMenu.item(pickRow, views: true, target: probe, action: #selector(PickProbe.pick(_:)))
    (pickItem.view as? MenuAccountRowView)?.fire()
    check(pickItem.view is MenuAccountRowView && pickItem.title == "hidden address" && probe.got == DockTileMenu.object(.switchTo, "pa~k2")
          && pickItem.representedObject as? String == DockTileMenu.object(.switchTo, "pa~k2"),
          "hidden: a standby row is the kit's account row whose Return and click send the action with its Switch page's key: \(pickItem.title) \(probe.got ?? "nil")")
    // a row that can't switch now (enabled false): the kit's row, disabled, with no action, and its Return does nothing
    let offProbe = PickProbe()
    let offItem = DockTileMenu.item(DockTileMenu.AddressRow(address: a3, act: .switchTo, target: "pa~k3", enabled: false),
                                    views: true, target: offProbe, action: #selector(PickProbe.pick(_:)))
    (offItem.view as? MenuAccountRowView)?.fire()
    check(offItem.view is MenuAccountRowView && offItem.action == nil && !offItem.isEnabled
          && (offItem.view as? MenuAccountRowView)?.lit == false && offProbe.got == nil,
          "hidden: a row that can't switch now is the kit's row, disabled, with no action, never lit, and Return sends nothing")
    // shown: native items with the whole address
    AddressPrivacy.shared.apply(blur: false)
    let shownItem = DockTileMenu.item(pickRow, views: true, target: probe, action: #selector(PickProbe.pick(_:)))
    check(shownItem.view == nil && shownItem.title == DockTileMenu.fit(a2), "shown: a native item with the whole address: \(shownItem.title)")
    AddressPrivacy.shared.apply(blur: true)
    // (the row itself, its words, width, picture, override and a disabled row, is the kit's: cl_kit's menurows suite)

    // ---- S4, the hidden pass: the suites above read addresses in clear (the setting is applied "shown" at the top), and many of
    // their expectations are written "…\(AddressSettings.words(x))…", which reads the address back while shown: a raw address in
    // such a sentence passes them. Here the setting is hidden and every sentence maker below goes through `clean`, with its
    // words asserted too (so a sentence that is simply empty doesn't pass).
    // M1: the one line "Usage: Claude Code on …": the record keeps only the fact (the account is codeName), the sentence is built
    // when a surface shows it, so it follows the setting both ways
    do {
        var pm = profile("pm", "~/.claude-pm", seat(61, a1)); pm.claudeWindow = true
        pm.standby = [StandbyAccount(email: a2, seat: seat(62, a2), id: "k2", plan: "Max", lastInUse: now.addingTimeInterval(-86400))]
        try! Store.save([pm])
        let appIn = AppSignIn.Login(account: uuid(61), org: uuid(161), state: .known, source: "log", at: now)
        AddressPrivacy.shared.apply(blur: false)
        let resolved = AccountResolver.resolve(pm, among: [pm], app: appIn, code: seat(63, a3), loginEmail: a3, names: [:], now: now)
        check(resolved.differs && resolved.line == nil && resolved.codeUsageLine == true && resolved.codeName == a3
              && resolved.lineText() == "Usage: Claude Code on \(a3)" && resolved.lineText(blur: true) == "Usage: Claude Code on hidden address",
              "M1: resolved while shown: the record holds the fact and the account, no sentence; the sentence is built per setting")
        var rec = IconStatus(state: "ok"); rec.loginEmail = a3; rec.expectedEmail = a1; rec.weekly = 40; rec.fiveHour = 12
        rec.weeklyResets = now.addingTimeInterval(2 * 86400); rec.fiveHourResets = now.addingTimeInterval(3600); rec.updatedAt = now.addingTimeInterval(-60)
        rec.source = "Anthropic"; rec.plan = "Max"; rec.resolved = resolved
        _ = Store.writeStatus("pm", rec)
        let onDisk = (try? String(contentsOf: Store.statusFolder.appendingPathComponent("pm.json"), encoding: .utf8)) ?? ""
        check(!onDisk.isEmpty && !onDisk.contains("Usage: Claude Code on") && onDisk.contains("codeUsageLine"), "M1: the written record holds no \"Usage: Claude Code on …\" text")
        let shownLine = AccountView.of(Store.status("pm")).line
        check(shownLine == "Usage: Claude Code on \(a3)", "M1: shown, the line names the account: \(shownLine ?? "nil")")
        AddressPrivacy.shared.apply(blur: true)          // the setting changes after the record was written
        let hiddenLine = AccountView.of(Store.status("pm")).line
        let pmShow = ProfileShow.load(pm, now: now)
        check(hiddenLine == "Usage: Claude Code on hidden address" && clean(hiddenLine ?? ""), "M1: hidden since the record was written: the same record now reads \"hidden address\": \(hiddenLine ?? "nil")")
        // a record from before (the sentence stored with its address) is turned into the fact when it is read
        var legacy = rec; legacy.resolved?.line = "Usage: Claude Code on \(a3)"; legacy.resolved?.codeUsageLine = nil
        let legacyRead = StatusCodec.encode(legacy).flatMap(StatusCodec.decode)
        check(legacyRead?.resolved?.line == nil && legacyRead?.resolved?.codeUsageLine == true && legacyRead?.resolved?.lineText() == hiddenLine,
              "M1: an older record that stored the sentence reads as the fact, hidden")
        // every surface that shows it
        let words = [pmShow.lineWords(short: false) ?? "", pmShow.lineWords(short: true) ?? ""] + titles(dockOf(pm, pmShow).menu) + titles(menuBarMenu(pmShow))
        check(words.allSatisfy(clean) && words.contains { $0.contains("hidden address") }, "M1: the Dock menu, the menu bar and the one line say \"hidden address\" and hold nothing of any address: \(words)")
        // N3: the menu bar's top row is a hosted SwiftUI view (MenuBarRow), which titles() can't read: its texts are read from what it
        // draws them from (the in-use line, the one line of state, the numbers' hint)
        let barRow = [pmShow.view.inUseLine ?? "", MenuBarRow.lineWords(MenuBarItems.Profile(show: pmShow)) ?? "", pmShow.numbersHint ?? ""]
        check(menuBarMenu(pmShow).items.first?.view is NSHostingView<MenuBarRow> && barRow[0] == "hidden address" && barRow.allSatisfy(clean),
              "N3: the menu bar's top row (a hosted view): its in-use line says \"hidden address\", it and its other lines hold nothing of any address: \(barRow)")
        let panel = dockPanelOf(pm, pmShow)
        // (the panel's account line holds the address itself: its view draws it as AccountValue, the blurred stand-in while
        // addresses are hidden (AddressSettings.hides asks AddressText.needsHiding about this very text), so the check is that
        // the text is one it hides)
        let panelWords = [panel.activeNote ?? "", panel.splitKey ?? ""]
        let panelLine = panel.accountLine.text
        check(panelWords.allSatisfy(clean) && (clean(panelLine) || AddressText.needsHiding(panelLine)),
              "M1: the Dock panel's note and key hold nothing of any address, and its account line is one its view draws as the stand-in: \(panelWords) \(panel.accountLine.text)")

        // the dashboard card: its notice, line, terminal and sign-in words, and the Switch account menu
        let acts = LauncherActions(open: { _ in }, terminal: { _ in }, logIn: { _ in }, mainScreen: {}, settings: {})
        let row = cardRow(pm, now: now)
        let card = AccountCard(row: row, actions: acts)
        let cardWords = [row.line ?? "", card.terminalWords, card.signInHelp, UsageNotice.of(row)?.heading ?? "", UsageNotice.of(row)?.line ?? "", row.subtitle == a1 ? "" : row.subtitle]
        check(cardWords.allSatisfy(clean), "hidden: the card's line, Terminal and Sign in words, notice hold nothing of any address: \(cardWords)")
        let cardMenu = card.switchAccountMenu.menu()
        check(titles(cardMenu).allSatisfy(clean) && titles(cardMenu).contains("Sign in to another account…"), "hidden: the card's Switch account menu titles: \(titles(cardMenu))")

        // D2: the card's Switch account menu is an NSMenu: the ticked account, a divider, its standby accounts as the kit's rows, a
        // divider, "Sign in to another account…", in that order, each doing what it did
        var chosen: [String] = [], signIns = 0
        func perform(_ i: NSMenuItem?) { if let i, let a = i.action { NSApp.sendAction(a, to: i.target, from: i) } }
        let dm = SwitchAccountMenu(label: a1, plan: "max", standby: [.init(key: "pm~k2", address: a2), .init(key: "pm~k3", address: a3)],
                                   pick: { chosen.append($0) }, newAccount: { signIns += 1 })
        let dmenu = dm.menu()
        let dRows = dmenu.items.compactMap { i in (i.view as? MenuAccountRowView).map { (i, $0) } }
        check(dmenu.items.count == 6 && dmenu.items[0].state == .on && dmenu.items[0].title == "hidden address  " + Account.planWords("max") && dmenu.items[1].isSeparatorItem
              && dRows.count == 2 && dmenu.items[2].view is MenuAccountRowView && dmenu.items[3].view is MenuAccountRowView && dmenu.items[4].isSeparatorItem
              && dmenu.items[5].title == "Sign in to another account…",
              "D2: the Switch account menu: the ticked account with its plan, a divider, the standby accounts (the kit's rows), a divider, Sign in to another account…: \(dmenu.items.map(\.title))")
        check(titles(dmenu).allSatisfy(clean) && dRows.allSatisfy { $0.1.accessibilityLabel() == "hidden address" && $0.0.title == "hidden address" && $0.1.drawnAddress == AddressText.standIn }
              && Set(dRows.map { $0.1.naturalWidth }).count == 1,
              "D2: hidden, no title or accessibility label holds any part of any address, both rows draw the same stand-in at the same width: \(titles(dmenu))")
        dRows[1].1.highlighted = true
        check(dRows[1].1.drawnAddress == a3 && dRows[0].1.drawnAddress == AddressText.standIn, "D2: only a highlighted row shows its address")
        dRows[0].1.fire(); dRows[1].1.fire(); perform(dmenu.items[5])
        check(chosen == ["pm~k2", "pm~k3"] && signIns == 1, "D2: a row picks its Switch page key, Sign in to another account… signs in: \(chosen) \(signIns)")
        AddressPrivacy.shared.apply(blur: false)
        let shownMenu = dm.menu()
        check(shownMenu.items[0].title == a1 + "  " + Account.planWords("max") && (shownMenu.items[2].view as? MenuAccountRowView)?.title == a2 && (shownMenu.items[3].view as? MenuAccountRowView)?.drawnAddress == a3,
              "D2: shown, the same menu holds the addresses: \(shownMenu.items.map(\.title))")
        AddressPrivacy.shared.apply(blur: true)

        // an expired sign-in on the card: the notice names "hidden address"
        var px = profile("px", "~/.claude-px", seat(71, a1)); px.claudeWindow = false
        try! Store.save([pm, px])
        var exp = IconStatus(state: "expired"); exp.loginEmail = a1; exp.expectedEmail = a1; exp.updatedAt = now
        exp.resolved = AccountResolver.resolve(px, among: [px], app: .unknown, code: seat(71, a1), loginEmail: a1, names: [:], now: now)
        _ = Store.writeStatus("px", exp)
        let notice = UsageNotice.of(cardRow(px, now: now))
        check(notice != nil && clean(notice!.heading) && clean(notice!.line) && notice!.line.contains("hidden address") && notice!.line.hasPrefix("Sign in as hidden address"),
              "hidden: the card's expired-sign-in notice says \"Sign in as hidden address…\": \(notice?.line ?? "nil")")
        Store.removeStatus("px")

        // M3: the switch engine's errors reach the Switch page as they were made: no name in them
        var pe = profile("pe", "~/.claude-pe", seat(81, a1))
        pe.standby = [StandbyAccount(email: a2, seat: Seat(account: uuid(82), organization: nil, email: a2), id: "k9")]
        let plan = SwitchEngine.plan(pe, standby: pe.standby[0])
        var planWhy = ""
        if case .failure(let why) = plan { planWhy = why.description }
        check(!planWhy.isEmpty && clean(planWhy) && !planWhy.contains("@"), "M3: the switch's \"not signed in here yet\" error names no account: \(planWhy)")
        let errorWords = [SwitchRunner.windowStaysClosed(AccountNames.short(a2)),
                          SwitchPage.phaseTitle(.other(a2), name: "Pm", to: AccountNames.short(a3)),
                          SwitchPage.boxWords(pe.standby[0], name: "Pm"),
                          AccountBook.switchWords(folder: "~/.claude-pe", email: AddressSettings.words(a2), isDefault: false),
                          SwitchPage.inUseName(pmShow, expected: a1)]
        check(errorWords.dropLast().allSatisfy(clean) && errorWords.dropLast().contains { $0.contains("hidden address") },
              "hidden: the Switch page's title, standby box words, what a switch affects and the window note hold nothing of any address: \(errorWords)")
        check(AddressSettings.hides(errorWords.last ?? ""), "hidden: the in-use box's title is an address, drawn by AccountValue (never as text)")

        // Settings: the Account pop-up's lines, the linked line, the Forget… question
        let sm = SettingsModel(); sm.accounts = [pm]
        let settingsView = AccountSettings(entry: .constant(pm), model: sm)
        let popUp = settingsView.loginItems.map(\.title)
        let linked = String(settingsView.linkedWords(was: a2, at: now).characters)
        check(popUp.allSatisfy(clean) && clean(linked) && linked.contains("hidden address"), "hidden: Settings' Account pop-up and linked line hold nothing of any address: \(popUp) \(linked)")

        // New profile: the sign-in checks and the folder pop-up rows; first run's found folder and line; the sign-in window's lines
        let found = [FolderChoice(path: "~/.claude-x", detail: a1).title, FolderChoice(path: "~/.claude-y", detail: nil).title, NewAccountSetup.folderWho("~/.claude-none"),
                     AccountNote(kind: .came, email: a3, profile: "Work", at: now).words, AccountNote(kind: .left, email: a3, profile: "Work", at: now).words,
                     AccountNote(kind: .standsBy, email: a3, profile: "Work", at: now).words]
        check(found.allSatisfy(clean), "hidden: New profile's folder rows and the account notes hold nothing of any address: \(found)")
        let wrongSaid = SignInSaid(.wrongAccount(signedIn: server(seat(8, a1)), wanted: server(seat(9, a2))), configDir: "~/.claude-x")
        let unconfirmed = SignInSaid(.unverified(server(seat(8, a1))), configDir: "~/.claude-x", previous: a2)
        let signInLines = [wrongSaid?.text ?? "", unconfirmed?.text ?? ""]
        check(signInLines.allSatisfy { !$0.isEmpty && clean($0) } && signInLines.contains { $0.contains("hidden address") },
              "hidden: the sign-in window's lines say \"hidden address\" and hold nothing of any address: \(signInLines)")
        let ws = SplitUsage(app: a1, code: a2, switched: false)
        check([ws.line, ws.shortLine, ws.key ?? "", ws.numbersHint ?? ""].allSatisfy(clean), "hidden: the split's sentences and keys")
        Store.removeStatus("pm")
    }

    // S4, the source scan: a user-facing interpolation of an email, label, address, account id or Claude Code's account name that is not
    // wrapped in AddressSettings.words, AccountNames.short, AddressText or BlurredAddress is flagged. The allow-list is short and each
    // entry says why it is fine. (A value first held in a variable and interpolated later is beyond a scan; the hidden pass above
    // covers the sentence makers it can reach.) Sessions*.swift files (but SessionsMove and SessionsCard, which are scanned) name
    // sessions, folders and settings by a `label`, never an account.
    do {
        let srcDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let identifier = try! NSRegularExpression(pattern: #"\b(email|emailAddress|address|codeName|numbersFor|numbersOwner|loginEmail|expectedEmail|wantedEmail|accountID|label|\w+Email|\w+Address)\b"#)
        let wrapped = ["AddressSettings.words", "AccountNames.short", "AccountNames.shortName", "AddressText.", "AddressPrivacy.", "BlurredAddress", ".short(", "shortName("]
        let skipFiles: Set<String> = ["SessionsBackup.swift", "SessionsExport.swift", "SessionsRepoint.swift", "SessionsSide.swift", "SessionsSideApply.swift", "SessionsSetup.swift"]
        // (file, a snippet of the line, why it is fine)
        let allowed: [(String, String, String)] = [
            ("Accounts.swift", "move to \\(email)", "switchWords' parameter: its one caller hands AddressSettings.words (SwitchPage), as its comment says"),
            ("AppIcon.swift", ".help(\"\\(label): ", "the profile's icon label (\"MAIN\") in the icon designs' picker, not an account"),
            ("ExportPage.swift", "\\($0.label) points to", "a linked setup folder's label (a path), not an account"),
            ("SessionsMove.swift", "\\(k.label): changed since", "a setting's label (\"Emails\"), not an account"),
            ("SessionsMove.swift", "\\(d.label): \\(d.hereWords)", "a setting's label and its words (\"hidden\"/\"shown\"), not an account"),
            ("Settings.swift", "\\($0.id)|\\($0.name)|\\($0.label)", "a change-detection key of the profiles (id, name, icon label), never drawn"),
            ("SetupRow.swift", "out.append(label + \":\")", "a setup row's label (\"Skills\"), not an account"),
        ]
        var flagged: [String] = [], usedAllow = Set<Int>()
        for f in ((try? FileManager.default.contentsOfDirectory(atPath: srcDir.path)) ?? []).filter({ $0.hasSuffix(".swift") && !skipFiles.contains($0) }).sorted() {
            let lines = (try? String(contentsOf: srcDir.appendingPathComponent(f), encoding: .utf8))?.components(separatedBy: "\n") ?? []
            for (i, l) in lines.enumerated() {
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") { continue }
                // every \( … ) of the line, and every  "…" + name / name + "…"  concatenation
                var exprs: [String] = []
                var rest = Substring(l)
                while let r = rest.range(of: "\\(") {
                    var depth = 1, k = r.upperBound
                    while k < rest.endIndex, depth > 0 { if rest[k] == "(" { depth += 1 } else if rest[k] == ")" { depth -= 1 }; k = rest.index(after: k) }
                    exprs.append(String(rest[r.upperBound..<rest.index(before: k)]))
                    rest = rest[k...]
                }
                for m in (try! NSRegularExpression(pattern: #""\s*\+\s*([A-Za-z_.?!]+)|([A-Za-z_.?!]+)\s*\+\s*""#)).matches(in: l, range: NSRange(l.startIndex..., in: l)) {
                    for g in 1...2 where m.range(at: g).location != NSNotFound { exprs.append((l as NSString).substring(with: m.range(at: g))) }
                }
                for x in exprs where identifier.firstMatch(in: x, range: NSRange(x.startIndex..., in: x)) != nil && !wrapped.contains(where: { x.contains($0) }) {
                    if let n = allowed.firstIndex(where: { $0.0 == f && l.contains($0.1) }) { usedAllow.insert(n); continue }
                    flagged.append("\(f):\(i + 1) [\(x)]")
                }
            }
        }
        check(flagged.isEmpty, "no user-facing interpolation or concatenation of an email, label, address or account name outside words/short/BlurredAddress: \(flagged)")
        check(usedAllow.count == allowed.count, "the scan's allow-list holds only lines that still exist: \(allowed.indices.filter { !usedAllow.contains($0) }.map { allowed[$0].1 })")
    }

    // ---- S5, the setting turned off AFTER a value was built. The scan above reads the source's text, and the blocks above build
    // their values with the setting already off; a value that holds a finished sentence (the one line "Usage: Claude Code on …",
    // a switch's notes) passes both and still shows the address once Show emails goes off. Each case here is
    // built while addresses are SHOWN, the setting is turned off, and the same value (or its holder) is read again.
    do {
        let wasBlur = AddressPrivacy.shared.blur
        defer { AddressPrivacy.shared.apply(blur: wasBlur) }
        func spinFor(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func hexRun(_ s: String) -> Bool { s.range(of: "[0-9a-fA-F]{8,}", options: .regularExpression) != nil }

        // F1: "Usage: Claude Code on <address>" in every holder that kept the value: ProfileShow (the menu bar's, the Dock menu's
        // and panel's line), the dashboard card's row, the account view, the Dock icon's panel and menu
        var pf = profile("pf", "~/.claude-pf", seat(71, a1)); pf.claudeWindow = true
        try! Store.save([pf])
        let appIn = AppSignIn.Login(account: uuid(71), org: uuid(171), state: .known, source: "log", at: now)
        AddressPrivacy.shared.apply(blur: false)
        let resolvedF = AccountResolver.resolve(pf, among: [pf], app: appIn, code: seat(73, a3), loginEmail: a3, names: [:], now: now)
        var recF = IconStatus(state: "ok"); recF.loginEmail = a3; recF.expectedEmail = a1; recF.weekly = 40; recF.fiveHour = 12
        recF.weeklyResets = now.addingTimeInterval(2 * 86400); recF.fiveHourResets = now.addingTimeInterval(3600); recF.updatedAt = now.addingTimeInterval(-60)
        recF.source = "Anthropic"; recF.plan = "Max"; recF.resolved = resolvedF
        _ = Store.writeStatus("pf", recF)
        // (this record reads as the split, whose words are built live already; the value kept here is the one ProfileShow.of made for
        // a record that is not the split, whose line was `.given("Usage: Claude Code on …")`, the sentence fixed when it was made)
        var givenDisplay = ProfileShow.load(pf, now: now).display
        givenDisplay.line = .given("Usage: Claude Code on \(a3)")
        let held = ProfileShow(entry: pf, display: givenDisplay, record: recF, view: AccountView.of(recF), splitWords: nil)
        let heldRow = AccountRow(entry: pf, show: held)
        let heldView = AccountView.of(Store.status("pf"))
        let icon = AppDelegate(); icon.entry = pf; icon.show = held; icon.watchPrivacy()
        let manager = ManagerUI()
        func holderTexts() -> [String] {
            MainActor.assumeIsolated {
                [held.lineWords(short: false), held.lineWords(short: true), heldRow.line, heldView.line, icon.detailsInfo().activeNote,
                 MenuBarRow.lineWords(MenuBarItems.Profile(show: held))].compactMap { $0 }
                    + titles(icon.profileMenu()) + titles(dockOf(pf, held).menu) + titles(menuBarMenu(held))
            }
        }
        let shownTexts = holderTexts()
        check(shownTexts.filter { $0 == "Usage: Claude Code on \(a3)" }.count >= 6 && heldView.line == "Usage: Claude Code on \(a3)",
              "S5/F1: built shown, every holder says the account: \(shownTexts.filter { $0.hasPrefix("Usage") })")
        AddressPrivacy.shared.apply(blur: true)          // …and the setting goes off, the values kept
        let hiddenTexts = holderTexts()
        icon.show = nil; manager.model.rows = []         // (what is left of them to be made again only by the subscriptions, below)
        check(hiddenTexts.allSatisfy(clean) && hiddenTexts.filter { $0 == "Usage: Claude Code on hidden address" }.count >= 6 && heldRow.view.line == "Usage: Claude Code on hidden address",
              "S5/F1: the same ProfileShow, card row, account view, Dock panel and menus read again: nothing of the address: \(hiddenTexts.filter { $0.contains("Usage") })")
        // the holders that rebuild on the change (IconApp's loadStatus, the dashboard's model.reload) did, with no timer
        spinFor(0.3)
        check(icon.show != nil && !manager.model.rows.isEmpty && clean(icon.show?.lineWords(short: false) ?? "")
              && manager.model.rows.compactMap(\.line).allSatisfy(clean),
              "S5/F1: the Dock icon (loadStatus) and the dashboard (model.reload) made their values again when Show emails went off")
        AddressPrivacy.shared.apply(blur: false)

        // F2: a switch's finished notes (SwitchRunner) and the failure text of a switch that stopped
        let planF = SwitchPlan(profile: "pf", standby: "k2", dataDir: "/tmp/cl-audit-s5-data", codeDir: "/tmp/cl-audit-s5-code", from: seat(81, a1), to: seat(82, a2))
        var planNotes = planF; planNotes.held = ["local_1"]; planNotes.taskStay = "the new account has the same task, switched on"; planNotes.odd = [.link, .unknownName]
        let runner = SwitchRunner(profile: "pf", model: SettingsModel())
        let stoppedWords = "An earlier switch of Pf stopped half way. Undo it, sign in as \(SwitchRunner.toMark) to finish it, or Leave it as it is; then switch again."
        runner.preview(.failed(stoppedWords), goal: nil, note: SwitchRunner.stayWords(planNotes), left: SwitchRunner.leftBehind(planNotes), failedAt: .notStarted,
                       window: SwitchRunner.windowStaysClosed(SwitchRunner.toMark), old: a1, stoppedTo: a2)
        func runnerTexts() -> [String] { [runner.moveText, runner.leftText, runner.windowText, runner.said(stoppedWords)].compactMap { $0 } }
        let shownNotes = runnerTexts()
        check(shownNotes.count == 4 && shownNotes[0].contains("stay with \(AccountNames.short(a1))") && shownNotes[1].contains("Left with \(AccountNames.short(a1))")
              && shownNotes[2].contains("sign in as \(AccountNames.short(a2))") && shownNotes[3].contains("sign in as \(AccountNames.short(a2))"),
              "S5/F2: built shown, the switch's notes name the two accounts: \(shownNotes)")
        check([runner.moveNote, runner.leftNote, runner.windowNote].compactMap { $0 }.allSatisfy(clean), "S5/F2: the notes the runner keeps hold no address")
        AddressPrivacy.shared.apply(blur: true)
        let hiddenNotes = runnerTexts()
        check(hiddenNotes.count == 4 && hiddenNotes.allSatisfy(clean) && hiddenNotes.allSatisfy { $0.contains("hidden address") },
              "S5/F2: the same runner read again: nothing of either address: \(hiddenNotes)")
        AddressPrivacy.shared.apply(blur: false)

        // F3: what is thrown holds no folder under claude-code-sessions and no id (the account's and the organisation's are the folder names)
        let gone = expand("~/cl-audit-s5/claude-code-sessions/\(uuid(91))/\(uuid(191))/never-made")
        var thrown = ""
        do { try SwitchEngine.writeNew(gone + "/local_x.json", Data("{}".utf8)) } catch { thrown = "\(error)" }
        var swapped = ""
        if case .failed(let why) = TaskRegistry.swap(Data("[]".utf8), at: gone + "/scheduled-tasks.json", expected: nil) { swapped = why }
        check(thrown == "couldn't write in the account's sessions folder" && swapped == "couldn't write in the account's sessions folder"
              && ![thrown, swapped].contains(where: { hexRun($0) || $0.contains("claude-code-sessions") }),
              "S5/F3: the thrown texts of a failed write name no folder and no id: \(thrown) | \(swapped)")
        let said = tildeNoIds(gone + "/local_x.json")
        check(!hexRun(said) && said.hasSuffix("/claude-code-sessions/…/never-made/local_x.json"), "S5/F3: a path in a sentence leaves the account and organisation folders out: \(said)")
        // each id folder on its own: a folder that is no id before it (the account's name, x) stays, an id after it goes
        let oneId = tildeNoIds("/data/claude-code-sessions/x/\(uuid(92))/local_x.json")
        let twoIds = tildeNoIds("/data/local-agent-mode-sessions/\(uuid(93))/\(uuid(94))/local_x.json")
        let noId = tildeNoIds("/data/claude-code-sessions/x/y/local_x.json")
        check(oneId == "/data/claude-code-sessions/x/…/local_x.json" && twoIds == "/data/local-agent-mode-sessions/…/local_x.json"
              && noId == "/data/claude-code-sessions/x/y/local_x.json" && ![oneId, twoIds].contains(where: hexRun),
              "S5/F3: tildeNoIds replaces each id folder on its own (x/<id> keeps x): \(oneId) | \(twoIds) | \(noId)")
    }

    // no first-letter-and-dots mask left anywhere in the app's sources
    let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    let files = (try? FileManager.default.contentsOfDirectory(atPath: src.path))?.filter { $0.hasSuffix(".swift") } ?? []
    var masks: [String] = []
    for f in files {
        let lines = (try? String(contentsOf: src.appendingPathComponent(f), encoding: .utf8))?.components(separatedBy: "\n") ?? []
        for (i, l) in lines.enumerated() where l.contains("•••") || l.contains("repeating: \"•\"") || l.contains("Privacy.mask") || l.contains("Privacy.masked") || l.contains("settingsEmail") {
            masks.append("\(f):\(i + 1)")
        }
    }
    check(!files.isEmpty && masks.isEmpty && !files.contains("Privacy.swift"), "no source builds the old mask (a first letter, dots, the domain) or calls Privacy: \(masks)")
}

// ============ cl_quick's chat link, and what cl_audit's own quick chat left behind ============
do {
    // the menus' "Quick chat" opens cl_quick on the profile's Claude Code folder: cl-quick://chat?folder=<path>
    let tilde = "~/.claude-work"
    let url = ClQuick.chatURL(configDir: tilde)
    let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
    check(url?.scheme == "cl-quick" && url?.host == "chat" && items?.count == 1 && items?.first?.name == "folder"
          && items?.first?.value == expand(tilde) && !(items?.first?.value ?? "~").hasPrefix("~"),
          "cl_quick's link: cl-quick://chat with the folder's tilde-expanded path: \(url?.absoluteString ?? "none")")
    let odd = "/tmp/a&b#c+d e/.claude-x"
    let oddItems = ClQuick.chatURL(configDir: odd).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
    check(oddItems?.count == 1 && oddItems?.first?.name == "folder" && oddItems?.first?.value == odd,
          "a folder with &, #, + and a space in its name comes back whole through the query item: \(oddItems?.first?.value ?? "none")")

    // the item's words: Quick chat with cl_quick on the Mac, Get cl_quick… without
    let keepProbe = ClQuick.installedProbe
    ClQuick.installedProbe = { true }
    let withIt = ClQuick.itemTitle
    ClQuick.installedProbe = { false }
    let without = ClQuick.itemTitle
    ClQuick.installedProbe = keepProbe
    check(withIt == "Quick chat" && without == "Get cl_quick…", "the item: Quick chat with cl_quick, Get cl_quick… without: \(withIt) / \(without)")

    // the quick chat's old project folders: exactly Claude Code's name for each profile's old work folder
    check(OldQuickChats.projectKey("/private/var/x/Library/Application Support/usage-n-uf/quick-chat") == "-private-var-x-Library-Application-Support-usage-n-uf-quick-chat",
          "a project key: every character but a letter or digit becomes \"-\"")
    check(OldQuickChats.projectName("oqc1") == OldQuickChats.projectKey(OldQuickChats.folder.appendingPathComponent("oqc1").path),
          "a profile's old chat folder: the key of usage-n-uf/quick-chat/<its id>")
    let oqc = home + "/oqc"
    try? fm.removeItem(atPath: oqc)
    let fakeTrash = oqc + "/Trash"
    try? fm.createDirectory(atPath: fakeTrash, withIntermediateDirectories: true)
    // (a throwaway Trash in the suite's home: never the real one)
    let keepTrash = OldQuickChats.toTrash
    OldQuickChats.toTrash = { u in (try? fm.moveItem(atPath: u.path, toPath: fakeTrash + "/" + UUID().uuidString + "-" + u.lastPathComponent)) != nil }
    func oldProfile(_ id: String) -> (e: AccountEntry, dir: String) {
        let cfg = oqc + "/claude-\(id)"
        return (profile(id, cfg, nil), cfg + "/projects/" + OldQuickChats.projectName(id))
    }
    let chat = oldProfile("oqc1"), empty = oldProfile("oqc2"), linked = oldProfile("oqc3"), notes = oldProfile("oqc4")
    let locked = oldProfile("oqc5"), dsOnly = oldProfile("oqc6")
    put(chat.dir + "/a.jsonl", "{}\n")
    put(chat.dir + "-x/b.jsonl", "{}\n")                                  // a near-miss name: never taken for an old chat folder
    put(oqc + "/claude-oqc1/projects/other-project/c.jsonl", "{}\n")
    try? fm.createDirectory(atPath: empty.dir + "/sub", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: linked.dir, withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: linked.dir + "/link", withDestinationPath: "/nonexistent")
    put(notes.dir + "/notes.txt", "x\n")
    try? fm.createDirectory(atPath: locked.dir + "/closed", withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.dir + "/closed")
    put(dsOnly.dir + "/.DS_Store", "x")
    defer {
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.dir + "/closed")
        OldQuickChats.toTrash = keepTrash
        try? fm.removeItem(atPath: oqc)
    }
    let all = [chat.e, empty.e, linked.e, notes.e, locked.e, dsOnly.e]
    let before = OldQuickChats.left(all)
    check(before.chats == 1 && Set(before.folders.map(\.path)) == [chat.dir, linked.dir, notes.dir, locked.dir],
          "left: the chat, a link, a non-chat file and an unreadable folder count as holding something; the empty one, a .DS_Store "
          + "alone, a near-miss name and another project don't: \(before.folders.map(\.lastPathComponent)) / \(before.chats)")
    _ = OldQuickChats.tidy(all)
    check(!fm.fileExists(atPath: empty.dir) && !fm.fileExists(atPath: dsOnly.dir)
          && [chat.dir + "/a.jsonl", chat.dir + "-x/b.jsonl", notes.dir + "/notes.txt", locked.dir].allSatisfy(fm.fileExists(atPath:))
          && (try? fm.destinationOfSymbolicLink(atPath: linked.dir + "/link")) != nil,
          "tidied: the empty folder and the .DS_Store-only one went to the Trash; everything that holds something stays")
    // the quick chat's own folder: a plain settings.json and empty work folders go; a work folder with a file keeps it there
    let own = OldQuickChats.folder.path
    try? fm.removeItem(atPath: own)
    put(own + "/settings.json", "{}")
    try? fm.createDirectory(atPath: own + "/oqc1", withIntermediateDirectories: true)
    put(own + "/oqc2/scratch.txt", "x")
    _ = OldQuickChats.tidy(all)
    check(!fm.fileExists(atPath: own + "/settings.json") && !fm.fileExists(atPath: own + "/oqc1") && fm.fileExists(atPath: own + "/oqc2/scratch.txt"),
          "the quick chat's own folder keeps a work folder that holds a file; its settings.json and the empty work folder go")
    try? fm.removeItem(atPath: own + "/oqc2")
    _ = OldQuickChats.tidy(all)
    check(!fm.fileExists(atPath: own), "…and with nothing else in it, the folder itself goes")
    // once only, and only with the profiles known
    let once = UserDefaults(suiteName: "cl-audit-surfaces-test-\(getpid())")!
    once.removeObject(forKey: OldQuickChats.tidiedKey)
    let emptyAgain = oldProfile("oqc7")
    try? fm.createDirectory(atPath: emptyAgain.dir, withIntermediateDirectories: true)
    let noProfiles = OldQuickChats.tidyOnce([], defaults: once)
    let first = OldQuickChats.tidyOnce([emptyAgain.e], defaults: once)
    try? fm.createDirectory(atPath: emptyAgain.dir, withIntermediateDirectories: true)
    let second = OldQuickChats.tidyOnce([emptyAgain.e], defaults: once)
    check(noProfiles.isEmpty && first.map(\.path) == [emptyAgain.dir] && second.isEmpty && fm.fileExists(atPath: emptyAgain.dir),
          "the tidy runs once, and not before the profiles are known: \(first.map(\.lastPathComponent)) / \(second.count)")
    once.removePersistentDomain(forName: "cl-audit-surfaces-test-\(getpid())")
    // their chats stay out of counts and backups: a path is in a profile's old chat folder by its exact name
    check(OldQuickChats.isOldProject(OldQuickChats.projectName("oqc1"), profile: "oqc1")
          && OldQuickChats.isOldProject(OldQuickChats.projectName("oqc1") + "/a.jsonl", profile: "oqc1")
          && !OldQuickChats.isOldProject(OldQuickChats.projectName("oqc1") + "-x/a.jsonl", profile: "oqc1")
          && !OldQuickChats.isOldProject(OldQuickChats.projectName("oqc1") + "/a.jsonl", profile: "oqc2")
          && !OldQuickChats.isOldProject("other-project/a.jsonl", profile: "oqc1"),
          "a profile's old chat folder, exactly by its name, and only its own profile's")
    // the line's and the question's words
    check(OldQuickChats.lineWords(.init(folders: [URL(fileURLWithPath: "/x")], chats: 1)) == "1 old quick chat from cl_audit is still here."
          && OldQuickChats.lineWords(.init(folders: [URL(fileURLWithPath: "/x")], chats: 3)) == "3 old quick chats from cl_audit are still here."
          && OldQuickChats.lineWords(.init(folders: [URL(fileURLWithPath: "/x")], chats: 0)) == "Old quick chat files from cl_audit are still here."
          && OldQuickChats.trashWords(.init(folders: [], chats: 0)) == "This moves the old quick chat folders to the Trash."
          && OldQuickChats.trashWords(.init(folders: [], chats: 2)) == "This moves 2 chats and the folders they were kept in to the Trash.\nNothing is deleted until you empty the Trash.",
          "the line and Move to Trash…'s words")
}

// ============ the status record and the Dock face are cl_kit's (ProfileCore: StatusRecord, StatusCodec, StatusFace) ============
do {
    let now = Date()
    var e = profile("kitface", "~/.claude-kitface", seat(81, "kit@example.com"))
    e.pollMinutes = 7; e.windowDot = false
    var rec = IconStatus(state: "ok")
    rec.loginEmail = "kit@example.com"; rec.expectedEmail = "kit@example.com"; rec.updatedAt = now
    rec.fiveHour = 42; rec.fiveHourResets = now.addingTimeInterval(2 * 3600); rec.weekly = 61; rec.weeklyResets = now.addingTimeInterval(3 * 86400)
    func face(_ r: IconStatus, windowOpen: Bool = true) -> TileModel { TileModel.face(e, ProfileShow.of(e, raw: r, now: now), windowOpen: windowOpen, now: now) }
    func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.01 } ?? false }
    check(e.look == ProfileLook(name: "Kitface", label: "KITFACE", pollMinutes: 7, windowDot: false), "a profile's look in the kit's terms")
    // fresh numbers: the label, both percents, the share of each window gone (5-hour: 2 h of 5 left, 60; week: 3 days of 7
    // left, 57.14), not grey, no warning, no countdown, and no window dot (the profile's look has it off)
    let fresh = face(rec)
    check(fresh.label == "KITFACE" && fresh.fiveHour == 42 && fresh.weekly == 61 && near(fresh.fiveHourElapsed, 60)
          && near(fresh.weeklyElapsed, 400.0 / 7) && !fresh.stale && !fresh.warn && fresh.countdown == nil && !fresh.windowOpen,
          "the Dock face from the kit: KITFACE, 42 and 61, 60 and 57.1 of the windows gone, not grey, no warning or countdown, no dot: "
          + "\(fresh.label) \(fresh.fiveHour ?? -1) \(fresh.weekly ?? -1) \(fresh.fiveHourElapsed ?? -1) \(fresh.weeklyElapsed ?? -1)")
    // old numbers (read 2 h ago, past the 30 minutes a 7-minute profile is grey after): drawn grey
    var old = rec; old.updatedAt = now.addingTimeInterval(-2 * 3600)
    check(face(old).stale, "numbers read 2 h ago: the face is grey")
    // the sign-in on another account than the folder names: the warning
    var other = rec; other.loginEmail = "someone-else@example.com"
    check(face(other).warn, "a sign-in on another account: the face warns")
    // the week full: the countdown to its reset instead of the numbers
    var full = rec; full.weekly = 100
    check(face(full).countdown != nil, "the week full: the face shows the countdown")
}

print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
