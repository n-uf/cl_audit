// Surfaces checks for cl_audit: one answer about each profile's account (Sources/AccountResolver.swift), written once into its
// status record, and every screen reading it alike: the menu bar, the Dock icon's menu and panel, the dashboard card, Settings ▸
// Accounts and quick chat's profile line. Also the Claude app's account read from its log the way claude-transplant reads it
// (Sources/AppSignIn.swift), a standby account's old numbers never shown, and no screen reading the sign-in files itself.
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
    let wd = expand("~/Library/Application Support/Claude-check")
    put("\(wd)/config.json", #"{"lastKnownAccountUuid":"\#(u2.account.uppercased())","oauth:tokenCache":"never-read"}"#)
    check(AppSignIn.lastKnown(dataDir: wd) == u2.account, "config.json: only lastKnownAccountUuid")
    check(AppSignIn.current(dataDir: wd, launched: nil, onlyApp: false, logs: logs).source == "config", "the app not running alone: config.json says it")
    check(AppSignIn.current(dataDir: wd, launched: launched, onlyApp: true, logs: logs, now: launched.addingTimeInterval(3600)).org == u2.organization,
          "the only Claude app running: its log says it, with the organisation")
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
    check(AccountView.of({ var s = IconStatus(state: "ok"); s.resolved = res(main, AppSignIn.Login(account: uuid(77), org: nil, state: .known, source: "log", at: t0), code: u1, numbers: u1.email); return s }()).label == "account 00000000",
          "an app account no record names: by its id's first 8")
}

// ============ 3. every surface reads the same record alike ============
do {
    let cases: [(String, AppSignIn.Login, Seat?, String?)] = [
        ("same", appU1, u1, u1.email), ("different", appU2, u1, u1.email), ("app signed out", appOut, u1, u1.email),
        ("a standby's account in the app", appU2, u1, u1.email), ("another profile's account", .unknown, u3, u3.email)]
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
            ("Settings", AccountSettings(entry: .constant(main), model: model).view)]
        for (s, v) in views { check(v == want, "\(name): \(s) agrees on the account, the numbers' owner and the line") }
        let panel = DetailsInfo(name: "x", icon: NSImage(), login: nil, expected: nil, mismatch: false, plan: nil, fiveHour: nil, fiveHourResets: nil,
                                weekly: nil, weeklyResets: nil, updated: nil, source: nil, problem: nil, renewNote: nil, needsLogin: false).taking(want)
        check(panel.active == want.label && panel.activeNote == want.line && panel.activeLit == want.lit, "\(name): the Dock panel agrees")
        check(SwitchMenu.dockTitle(name: "P", want, plan: nil) == (want.short.map { "Claude P · \($0) in use" } ?? "Claude P"), "\(name): the Dock menu agrees")
        check(QuickChatTarget(main).email == want.label, "\(name): quick chat agrees")
        check(Store.status(for: main)?.weekly == (want.clash == nil ? 40 : 40), "\(name): the record's numbers are never dropped by a screen")
        if name == "different" { check(want.label == u2.email && want.numbersOwner == u1.email, "different: u2 in use, the numbers u1's") }
    }
    // a record from before the resolver: the sign-in it was read for
    var old = IconStatus(state: "ok"); old.loginEmail = u1.email
    check(AccountView.of(old).label == u1.email && AccountView.of(old).line == nil, "an older record: its sign-in, no line")
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
    Login.runSecurity = { _ in (44, Data()) }                 // never the Keychain: "no such item"
    var launches: [String] = []
    ClaudeCLI.launchSeam = { what, dir in launches.append("\(what) \(dir)"); return false }
    let gone = "~/.claude-gone-kept"
    try? fm.removeItem(atPath: expand(gone))
    var p = profile("pk", "~/.claude-pk", u1); p.claudeWindow = false; p.autoRenew = true
    try? fm.createDirectory(atPath: expand("~/.claude-pk"), withIntermediateDirectories: true)
    p.standby = [StandbyAccount(email: u2.email!, seat: u2, configDir: gone, id: "kg")]
    check(p.readerEntry(for: p.standby[0]) == nil, "a kept folder that isn't there has no reader")
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
    check(ClaudeCLI.renew("/usr/bin/false", account: Account(r)) == false && !fm.fileExists(atPath: expand(gone)), "Renew sign-in refuses a missing folder")
    check(ClaudeCLI.logout("/usr/bin/false", configDir: gone) == false && !fm.fileExists(atPath: expand(gone)), "so does logout")
    try? fm.createSymbolicLink(atPath: expand("~/.claude-linked-kept"), withDestinationPath: expand("~/.claude-pk"))
    check(!ClaudeCLI.folderReady("~/.claude-linked-kept") && !ClaudeCLI.folderReady("~/.claude-linked-kept", creating: true), "a link is never used, nor made into a folder")
    check(ClaudeCLI.folderReady("~/.claude") && ClaudeCLI.folderReady("~/.claude-pk"), "the default folder, and a folder that is there, are fine")
    check(ClaudeCLI.mayLaunch("login", "~/.claude-new-signin", creating: true) == false && fm.fileExists(atPath: expand("~/.claude-new-signin")),
          "a sign-in the person starts makes its new folder first (the seam then stops the launch here)")
    check(launches.contains("login ~/.claude-new-signin"), "…and only then would it launch")
    ClaudeCLI.launchSeam = nil
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
}

print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
