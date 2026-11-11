// The one-folder model's checks for cl_audit (cl_quick's model): a profile is one Claude Code folder, its account in use is
// the one signed in there, its standby accounts are remembered signed out. What an older profiles file becomes, the folders
// it kept (offered to the Trash, never deleted silently, their Keychain items never touched), the folder's account followed
// by itself, the account book, the switch's watch, the sign-in script, the accounts found on this Mac (claude-transplant's
// way), the move inside the one folder with Undo, the menus' lines, the clean-up of the standby accounts' old files, and the
// old switches' receipts read only. The Claude app's account and the one account answer every surface reads are
// Checks/surfaces'.
//
// Runs only with HOME and CFFIXED_USER_HOME = .../Checks/.work/accounts/home (Checks/run.sh sets and guards it). Sample
// accounts only (example.com). Nothing opens Terminal, the Dock or any app, and nothing touches the Keychain: the Terminal
// opener is a stand-in that records the script, the Trash is a stand-in that records the folder, and `claude` is a stub
// script that is never run (the script that would run it is only written).

import AppKit
import SwiftUI

var passed = 0, failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passed += 1 } else { failed += 1; print("FAIL (line \(line)): \(what)") }
}

setbuf(stdout, nil)
let home = NSHomeDirectory()
guard home.hasSuffix("/Checks/.work/accounts/home"), expand("~") == home else { print("refusing: HOME is \(home)"); exit(2) }
let fm = FileManager.default
SettingsModel.followsDock = false
Store.announce = {}
Store.announceStatus = { _ in }
BackupPrefs.store = MemoryPrefs()
var opened: [String] = []                                // the scripts Terminal would have opened
ClaudeCLI.openTerminal = { url in opened.append((try? String(contentsOf: url, encoding: .utf8)) ?? ""); return true }
var trashed: [String] = []
Leftovers.toTrash = { url in trashed.append(url.path) }

func uuid(_ n: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", n) }
func seat(_ n: Int, _ email: String) -> Seat { Seat(account: uuid(n), organization: uuid(n + 100), email: email) }
let u1 = seat(1, "ultra-1@example.com"), u2 = seat(2, "ultra-2@example.com"), u3 = seat(3, "ultra-3@example.com"), u4 = seat(4, "ultra-4@example.com")
func put(_ path: String, _ text: String) {
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    fm.createFile(atPath: path, contents: Data(text.utf8))
}
/// A folder's .claude.json naming an account (ids and an address only, never a token).
func sign(_ dir: String, _ s: Seat?) {
    let file = dir == "~/.claude" ? expand("~/.claude.json") : expand(dir) + "/.claude.json"
    try? fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    guard let s else { try? fm.removeItem(atPath: file); return }
    let o: [String: Any] = ["accountUuid": s.account, "organizationUuid": s.organization!, "emailAddress": s.email!, "planDisplayName": "Ultra"]
    try! JSONSerialization.data(withJSONObject: ["oauthAccount": o]).write(to: URL(fileURLWithPath: file))
}
func tree(_ dir: String) -> String {
    ((fm.enumerator(atPath: dir)?.allObjects as? [String]) ?? []).sorted().map { r in
        let d = fm.contents(atPath: dir + "/" + r) ?? Data()
        return "\(r)=\(SwitchEngine.sha(d))"
    }.joined(separator: "\n")
}
func profile(_ id: String, _ dir: String, _ s: Seat?, standby: [StandbyAccount] = []) -> AccountEntry {
    var e = AccountEntry(id: id, name: id.capitalized, label: id.uppercased(), configDir: dir); e.seat = s; e.standby = standby
    return e
}
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
_ = NSApplication.shared

// ============ 1. an older profiles file: kept folders and standby folders become leftovers ============
do {
    let old = """
    {"accounts":[{"id":"main","name":"Main","label":"MAIN","configDir":"~/.claude","keptFolder":"~/.claude-ultra-1","sessionsFollow":false,
      "seat":{"account":"\(u1.account)","organization":"\(u1.organization!)","email":"ultra-1@example.com"},
      "standby":[{"id":"k2","email":"ultra-2@example.com","seat":{"account":"\(u2.account)","organization":"\(u2.organization!)","email":"ultra-2@example.com"},"configDir":"~/.claude-ultra-2","addedAt":784000000},
                 {"id":"k3","email":"ultra-3@example.com","configDir":"~/.claude-ultra-3"},
                 {"id":"bad","email":7},
                 {"id":"k4","email":"ultra-4@example.com","configDir":"~/.claude"}]},
     {"id":"work","name":"Work","label":"WORK","configDir":"~/.claude-work","keptFolder":"~/.claude-work"}]}
    """
    for d in ["~/.claude-ultra-1", "~/.claude-ultra-2", "~/.claude-ultra-3"] { put(expand(d) + "/settings.json", "{}") }
    sign("~/.claude-ultra-2", u2)
    try! fm.createDirectory(at: Store.folder, withIntermediateDirectories: true)
    try! Data(old.utf8).write(to: Store.configURL)
    let before = tree(home + "/.claude-ultra-1") + tree(home + "/.claude-ultra-2") + tree(home + "/.claude-ultra-3")
    let list = Store.load()
    let m = list.first { $0.id == "main" }, w = list.first { $0.id == "work" }
    check(list.count == 2 && m?.standby.map(\.id) == ["k2", "k3", "k4"], "an older file loads: its standby accounts stay (one that can't be read is left out)")
    check(m?.standby.first?.seat?.account == u2.account && m?.standby.first?.addedAt != nil, "a standby account keeps its seat and when it was added")
    check(m?.leftoverFolders == ["~/.claude-ultra-1", "~/.claude-ultra-2", "~/.claude-ultra-3"],
          "its kept folder and the standby accounts' folders are listed once each as left over (never the profile's own folder): \(m?.leftoverFolders ?? [])")
    check(w?.leftoverFolders == [], "a kept folder that is the profile's own folder isn't left over")
    try! Store.save(list)
    check(String(data: try! Data(contentsOf: Store.configURL), encoding: .utf8)!.contains("keptFolder"), "nothing changed: the file isn't written at all")
    var renamed = list; renamed[1].name = "Work 2"
    try! Store.save(renamed)                      // the next save of any change writes the file as it is now
    let saved = String(data: try! Data(contentsOf: Store.configURL), encoding: .utf8)!
    check(!saved.contains("keptFolder") && !saved.contains("sessionsFollow") && !saved.contains("\"configDir\" : \"~/.claude-ultra-2\""),
          "saved again: no keptFolder, no sessionsFollow, no standby folder")
    check(saved.contains("leftoverFolders"), "…and the leftovers list is saved")
    let again = Store.load()
    check(again == renamed, "read again: the same profiles (the leftovers listed once, not twice)")
    check(tree(home + "/.claude-ultra-1") + tree(home + "/.claude-ultra-2") + tree(home + "/.claude-ultra-3") == before && trashed.isEmpty,
          "nothing in those folders changed, nothing went to the Trash")
}

// ============ 2. the folders from before: offered, asked about, moved to the Trash ============
do {
    let all = [profile("main", "~/.claude", u1), profile("work", "~/.claude-work", u3)]
    put(expand("~/.claude-work/settings.json"), "{}")
    check(Leftovers.offerable("~/.claude-ultra-2", among: all), "a plain folder in the home folder that no profile uses is offered")
    check(!Leftovers.offerable("~/.claude-gone", among: all), "one that isn't there isn't")
    check(!Leftovers.offerable("~/.claude", among: all), "~/.claude never is")
    check(!Leftovers.offerable("~/.claude-work", among: all), "a profile's own folder isn't")
    try? fm.createSymbolicLink(atPath: expand("~/.claude-linked"), withDestinationPath: expand("~/.claude-ultra-1"))
    check(!Leftovers.offerable("~/.claude-linked", among: all), "a link isn't (it would be the link that moves)")
    put(expand("~/.claude-file"), "x")
    check(!Leftovers.offerable("~/.claude-file", among: all), "a file isn't")
    check(!Leftovers.offerable("/private/tmp", among: all), "a folder outside the home folder isn't")
    var e = all[0]; e.leftoverFolders = ["~/.claude-ultra-2", "~/.claude-gone", "~/.claude-linked"]
    let offered = Leftovers.offered(e, among: all)
    check(offered.map(\.path) == ["~/.claude-ultra-2"], "only the ones still there are listed")
    let item = offered.first?.keychainItem ?? ""
    check(item == "Claude Code-credentials-" + Account.sha8(expand("~/.claude-ultra-2")),
          "its Keychain item is named the way Claude Code names it (the first 8 hex of the path's SHA-256): \(item)")
    let q = Leftovers.question(offered[0])
    check(q.title == "Move ~/.claude-ultra-2 to the Trash?" && q.detail.contains(item) && q.detail.contains("doesn't touch it"),
          "the question names the folder and its Keychain item, and says cl_audit leaves the item alone")
    check(Leftovers.trash(offered[0], among: all) == nil && trashed == [expand("~/.claude-ultra-2")], "Move to Trash moves exactly that folder (to the Trash)")
    check(Leftovers.dropping("~/.claude-ultra-2", from: e).leftoverFolders == ["~/.claude-gone", "~/.claude-linked"], "…and it leaves the list (so does Keep it)")
    // changed since it was listed: a profile uses it now
    let now = all + [profile("x", "~/.claude-ultra-2", u4)]
    check(Leftovers.trash(offered[0], among: now) != nil && trashed.count == 1, "checked again before it moves: a profile uses it now, nothing moves")
}

// ============ 3. the folder's account is followed by itself (FolderRules.noteAccounts) ============
do {
    var st = IconStatus(state: "ok"); st.plan = "Ultra"; st.weekly = 97; st.weeklyResets = t0.addingTimeInterval(86400)
    let main = profile("main", "~/.claude", u1)
    var dirs: [String: Seat] = ["~/.claude": u2]
    func note(_ list: [AccountEntry]) -> [AccountEntry] { FolderRules.noteAccounts(list, signedIn: { dirs[$0] }, status: { _ in st }, now: t0) }
    let out = note([main])[0]
    check(out.seat.map { $0.same(u2) } == true && out.seat?.linkedAt == t0 && out.seat?.was == u1.email, "another account signed in to the folder is the one in use, by itself")
    let was = out.standby.first
    check(out.standby.count == 1 && was?.seat.map { $0.same(u1) } == true && was?.lastInUse == t0 && was?.plan == "Ultra" && was?.lastWeek == 97
          && was?.lastWeekResets == st.weeklyResets && was?.seat?.linkedAt == nil,
          "the account before stands by: its plan, when it left and its last week remembered, never a folder")
    check(note([out]) == [out], "noted twice: nothing more changes")
    dirs["~/.claude"] = nil
    check(note([out]) == [out], "the folder signed out: nothing changes (the account stays the profile's)")
    // back to the first: it leaves standby, the other one stands by
    dirs["~/.claude"] = u1
    let back = note([out])[0]
    check(back.seat.map { $0.same(u1) } == true && back.standby.map { $0.seat?.account } == [u2.account], "switched back: one standby entry each, never the one in use")
    // another profile's account in use: refused
    let work = profile("work", "~/.claude-work", u3)
    dirs = ["~/.claude": u3, "~/.claude-work": u3]
    let refused = note([main, work])
    check(refused == [main, work], "an account another profile works on is refused: nothing changes")
    check(FolderRules.inUseElsewhere(main, among: [main, work], signedIn: { dirs[$0] })?.owner.id == "work", "…and the profile says whose it is")
    // on another profile's standby: it comes here, with a note on both
    var w2 = profile("work", "~/.claude-work", u3, standby: [StandbyAccount(email: u4.email!, seat: u4, id: "w4")])
    dirs = ["~/.claude": u4, "~/.claude-work": u3]
    let moved = note([main, w2])
    check(moved[0].seat.map { $0.same(u4) } == true && moved[1].standby.isEmpty, "an account on another profile's standby list moves here (\"it moves to A\")")
    check(moved[0].accountNote?.kind == .came && moved[0].accountNote?.profile == "Work" && moved[1].accountNote?.kind == .left && moved[1].accountNote?.profile == "Main",
          "…said on both profiles")
    check(moved[1].accountNote?.words.contains("left for Main") == true, "the other profile's line says where it went")
    w2.standby = []
    // remembered by its address only: found by the address
    let byAddress = profile("main", "~/.claude", u1, standby: [StandbyAccount(email: "ULTRA-2@example.com", id: "a2")])
    dirs = ["~/.claude": u2]
    let found = note([byAddress])[0]
    check(found.seat.map { $0.same(u2) } == true && found.standby.map(\.email) == [u1.email!], "an account remembered by its address leaves standby once it signs in (by its address, any case)")
    // not linked yet: the first profile signed in to it takes it
    let a = profile("a", "~/.claude-a", nil), b = profile("b", "~/.claude-b", nil)
    dirs = ["~/.claude-a": u4, "~/.claude-b": u4]
    let linked = note([a, b])
    check(linked[0].seat.map { $0.same(u4) } == true && linked[1].seat == nil && linked[0].standby.isEmpty, "not linked yet: the first profile signed in to it takes it, no standby made")
    // the Claude window keeps its own sign-in: only its account id is compared, and only said
    var we = profile("main", "~/.claude", u2); we.claudeWindow = true
    check(!FolderRules.windowOnAnotherAccount(we, signedIn: { _ in u2 }, window: { _ in u2.account }), "window and Claude Code on the same account: nothing said")
    check(FolderRules.windowOnAnotherAccount(we, signedIn: { _ in u2 }, window: { _ in u1.account }), "the window on another account than Claude Code: said (a switch leaves the window alone)")
    check(!FolderRules.windowOnAnotherAccount(we, signedIn: { _ in u2 }, window: { _ in nil }), "no window sign-in known: nothing said")
}

// ============ 4. the account book: which standby account a full limit offers ============
do {
    let now = t0
    func s(_ id: String, week: Double?, resets: Date? = nil, last: Date? = nil, linked: Bool = true) -> StandbyAccount {
        StandbyAccount(email: "\(id)@example.com", seat: linked ? seat(Int(id.filter(\.isNumber)) ?? 9, "\(id)@example.com") : nil, id: id,
                       lastInUse: last, lastWeek: week, lastWeekResets: resets)
    }
    let full = s("s1", week: 100, resets: now.addingTimeInterval(3600))
    let reset = s("s2", week: 100, resets: now.addingTimeInterval(-60))
    let low = s("s3", week: 20), mid = s("s4", week: 60), unknown = s("s5", week: nil, last: now.addingTimeInterval(-60))
    let unknownOld = s("s6", week: nil, last: now.addingTimeInterval(-86400)), address = s("s7", week: nil, linked: false)
    let order = AccountBook.offerOrder([full, mid, unknownOld, address, unknown, low, reset], now: now).map(\.id)
    check(order == ["s2", "s3", "s4", "s5", "s6", "s1", "s7"],
          "not known to be full first, least used first (a week that started again counts as unused), then unknown by last in use; full, then address-only last: \(order)")
    check(AccountBook.best([full, mid, low], now: now)?.id == "s3", "the one offered: the least used not known to be full")
    check(AccountBook.best([full], now: now) == nil, "all known to be full: none offered")
    check(full.knownFull(now: now) && !reset.knownFull(now: now) && !low.knownFull(now: now), "known to be full only until its week starts again")
    check(AccountBook.ago(now.addingTimeInterval(-30), now: now) == "just now" && AccountBook.ago(now.addingTimeInterval(-3 * 86400), now: now) == "3 days ago"
          && AccountBook.ago(now.addingTimeInterval(-30 * 86400), now: now) == "4 weeks ago", "how long ago, in words")
    check(AccountBook.switchWords(folder: "~/.claude", email: "u2", isDefault: true)
          == "Terminal and editors on ~/.claude move to u2, sessions running now included; the Claude app keeps its own sign-in. Finish the sign-in in Terminal and the browser as that account.",
          "what a switch affects, for ~/.claude (under the row named Claude Code)")
    check(AccountBook.switchWords(folder: "~/.claude-work", email: "u2", isDefault: false).hasPrefix("Terminal and editors using ~/.claude-work move to u2"),
          "…and for another folder")
    var e = profile("main", "~/.claude", u1, standby: [full, low]); e.id = "main"
    let lines = SwitchMenu.lines(e, now: now)
    check(lines.map(\.key) == ["main~s3", "main~s1"] && lines[1].words == "" && !lines[1].room && SwitchMenu.best(lines)?.key == "main~s3",
          "the menus: the order offered, the kept week never shown (only when last in use), the best not known to be full")
    check(!SwitchOffer(profile: "main", standby: full).lineWords(now: now).contains("full"), "the card's tray never shows the kept week")
    check(!lines.contains { $0.words.contains("%") }, "the menus show no standby usage")
    check(SwitchWords.alertLine(SwitchOffer(profile: "main", standby: low), accounts: 2)?.contains("@") == false, "the alert names no account")
}

// ============ 5. the switch's watch (SwitchRunner.judge) ============
do {
    let g = SwitchRunner.Goal(standby: "k2", wantedSeat: u2, wantedEmail: u2.email!, from: u1, started: t0)
    func j(_ s: Seat?, after: Double = 10, marker: Bool = false, _ goal: SwitchRunner.Goal = g) -> SwitchRunner.Outcome? {
        SwitchRunner.judge(goal, now: s, markerDone: marker, at: t0.addingTimeInterval(after))
    }
    check(j(nil) == nil && j(u1) == nil, "signed out for a moment, or still the account it was on: still waiting")
    check(j(u2) == .reached, "the account wanted: reached")
    check(j(u3) == .other(u3), "another account: said at once")
    check(j(u1, after: 601) == .timedOut && j(u2, after: 601) == .timedOut, "past 10 minutes: timed out")
    let byAddress = SwitchRunner.Goal(standby: "k5", wantedSeat: nil, wantedEmail: "Ultra-3@example.com", from: u1, started: t0)
    check(j(u3, byAddress) == .reached && j(u4, byAddress) == .other(u4), "an address remembered without a seat: found by its address, any case")
    let again = SwitchRunner.Goal(standby: nil, wantedSeat: u1, wantedEmail: u1.email!, from: u1, started: t0)
    check(again.again && !g.again, "a sign-in again is the one with no standby account on an account in use")
    check(j(u1, again) == nil && j(u1, marker: true, again) == .reached && j(u3, again) == .other(u3),
          "signing in again: the same account only on Claude Code's done-marker, another account at once")
}

// ============ 6. the sign-in script (ClaudeCLI.loginLines) ============
do {
    let std = Account(profile("main", "~/.claude", u1)), other = Account(profile("work", "~/.claude-o'brien", u1))
    let l1 = ClaudeCLI.loginLines("/opt/claude", account: std, email: "ultra-2@example.com")
    let unset = "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY"
    let cmd = l1.firstIndex { $0.contains("auth login") } ?? 0
    check(l1.firstIndex(of: unset).map { $0 < cmd } == true, "a key or another provider from the shell's settings is unset before the sign-in")
    check(l1.contains("unset CLAUDE_CONFIG_DIR") && l1[cmd] == "'/opt/claude' auth login --claudeai --email 'ultra-2@example.com'",
          "~/.claude signs in with CLAUDE_CONFIG_DIR unset, the address filled in")
    check(!l1.contains { $0.contains(".done") } && l1.contains { $0.hasPrefix("if [ $s -eq 0 ]; then echo 'Done.") },
          "no marker for a switch; \"Done.\" only when the login ended well")
    let marker = URL(fileURLWithPath: home + "/m it's.done")
    let l2 = ClaudeCLI.loginLines("/opt/claude", account: other, email: "a'b@example.com", marker: marker)
    check(l2.contains("export CLAUDE_CONFIG_DIR='\(home)/.claude-o'\\''brien'") && l2.contains { $0.hasSuffix("--email 'a'\\''b@example.com'") },
          "another folder is exported, every path and address quoted")
    check(l2.contains("s=$?") && l2.contains("if [ $s -eq 0 ]; then : > '\(home)/m it'\\''s.done'; fi"), "a sign-in again leaves its marker only when the login ended well")
}

// ============ 7. a switch, through the page's runner, up to the outcome ============
do {
    put(home + "/fakebin/claude", "#!/bin/sh\necho '2.1.99 (Claude Code)'\n")
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home + "/fakebin/claude")
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [home + "/fakebin/claude"] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
    sign("~/.claude", u1)
    let k2 = StandbyAccount(email: u2.email!, seat: u2, id: "k2")
    let main = profile("main", "~/.claude", u1, standby: [k2])
    try! Store.save([main])
    let m = SettingsModel()
    m.accounts = [main]
    let r = m.runner(of: "main")
    opened = []
    r.start(k2)
    check(r.phase == .waiting && opened.count == 1 && opened[0].contains("--email 'ultra-2@example.com'") && opened[0].contains("unset CLAUDE_CONFIG_DIR"),
          "Switch to ultra-2: Claude Code's sign-in opens in Terminal for the profile's folder, the address filled in")
    check(m.waitingSwitches.map(\.step.key) == ["main~k2"], "it waits for the sign-in (the waiting alert's list)")
    check(SwitchWaiting.words(profile: "Main", phase: .waiting).map { !$0.body.contains("@") && !$0.title.contains("ultra") } == true, "the waiting alert names no account")
    r.look(); RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    check(r.phase == .waiting, "the folder still names ultra-1: waiting")
    sign("~/.claude", u2)
    let end = Date().addingTimeInterval(5)
    while r.phase == .waiting, Date() < end { r.look(); RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    check(r.phase == .reached, "the folder names ultra-2: reached")
    r.reset()
    sign("~/.claude", u1)
    r.start(k2)
    sign("~/.claude", u3)
    let end2 = Date().addingTimeInterval(5)
    while r.phase == .waiting, Date() < end2 { r.look(); RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    check(r.phase == .other(u3.email!), "the browser signed in as ultra-3: another account, said")
    r.reset(); r.start(k2); r.cancel()
    check(r.phase == .ready && !fm.fileExists(atPath: SwitchRunner.marker(for: "main").path), "Cancel stops waiting; nothing to put back")
    check(((try? fm.contentsOfDirectory(atPath: home)) ?? []).allSatisfy { !$0.hasPrefix(".claude-") || ["claude-ultra-1", "claude-ultra-2", "claude-ultra-3", "claude-work", "claude-linked", "claude-file"].contains(String($0.dropFirst())) },
          "a switch makes no folder")
    sign("~/.claude", u1)
}

// ============ 8. claude-transplant's way: the accounts found on this Mac, the Claude app's account, the move ============
do {
    let u5 = seat(5, "ultra-5@example.com"), u6 = seat(6, "ultra-6@example.com")
    // a profile with its own window: sessions under u2, an agent session under u5 naming its address; its folder's backup
    // names u3 (Personal); a transcript names u6's account id; another profile has u4 on standby
    let wd8 = expand("~/Library/Application Support/Claude-acc8")
    put("\(wd8)/claude-code-sessions/\(u2.account)/\(u2.organization!)/local_\(uuid(801)).json", #"{"sessionId":"local_x"}"#)
    put("\(wd8)/local-agent-mode-sessions/\(u5.account)/\(u5.organization!)/r.json", #"{"emailAddress":"ultra-5@example.com","token":"never-read"}"#)
    put("\(wd8)/claude-code-sessions/\(u4.account)/\(u4.organization!)/local_\(uuid(802)).json", "{}")
    put("\(wd8)/claude-code-sessions/not-an-id/\(u2.organization!)/local_\(uuid(803)).json", "{}")
    sign("~/.claude-p8", u1)
    let b = """
    {"oauthAccount":{"accountUuid":"\(u3.account)","organizationUuid":"\(u3.organization!)","emailAddress":"ultra-3@example.com","organizationType":"claude_max","organizationName":"ultra-3's Organization","planDisplayName":"Max"},"accessToken":"never-read"}
    """
    put(expand("~/.claude-p8/backups/.claude.json.backup.1700000000"), b)
    put(expand("~/.claude-p8/projects/-x/\(uuid(804)).jsonl"), #"{"type":"user","accountUuid":"\#(u6.account)"}"# + "\n")
    var p8 = profile("p8", "~/.claude-p8", u1); p8.desktop = .separate; p8.desktopDataDir = wd8
    var o8 = profile("o8", "~/.claude-o8", seat(9, "o9@example.com"), standby: [StandbyAccount(email: u4.email!, seat: u4, id: "o4")])
    o8.claudeWindow = false
    let found = AccountList.find([p8, o8])
    check(found.logins.emails[u5.account] == "ultra-5@example.com" && found.logins.emails[u3.account] == "ultra-3@example.com",
          "addresses from the agent sessions and the folder's backups")
    check(found.logins.orgs[u3.organization!] == "Personal" && found.logins.plans[u3.account] == "Max", "a personal plan's organisation is Personal; the plan is kept")
    check(found.window["p8"]?.keys.contains(SeatID(u2)) == true && found.window["p8"]?.keys.contains(SeatID(u5)) == true
          && found.window["p8"]?.keys.contains { $0.account == "not-an-id" } == false, "the window's pairs, from both session folders, only real ids")
    check(found.folder["p8"]?.contains(SeatID(u3)) == true && found.folder["p8"]?.contains(SeatID(u1)) == true, "the folder's pairs: its .claude.json and its backups")
    check(found.transcripts["p8"] == [u6.account], "the transcripts' account id")
    var forgetting = p8; forgetting.forgotten = [AccountList.key(u3)]
    let listed = AccountList.adding(found, to: [forgetting, o8], now: t0)
    let sb = listed[0].standby
    check(sb.contains { $0.seat?.same(u2) == true } && sb.contains { $0.seat?.same(u5) == true && $0.email == "ultra-5@example.com" },
          "the window's accounts go on standby, with an address where one is known")
    check(!sb.contains { $0.seat?.account == u3.account }, "a forgotten one doesn't come back")
    check(!sb.contains { $0.seat?.account == u4.account } && !sb.contains { $0.seat?.account == u1.account },
          "never another profile's account, never the one in use")
    check(sb.first { $0.seat?.account == u6.account }.map { $0.seat?.organization == nil && $0.label == "account 00000000" } == true,
          "a transcript's account id alone: listed by its id")
    check(sb.first { $0.seat?.same(u2) == true }?.lastInUse != nil, "last in use: when the window last wrote a session under it")
    check(AccountList.adding(found, to: listed, now: t0) == listed, "found again: nothing added twice")
    check(listed[1] == o8, "the other profile is left as it was")
    check(AccountList.label(Seat(account: u3.account, organization: u3.organization, email: nil), found.logins) == "ultra-3@example.com · Personal"
          && AccountList.label(Seat(account: uuid(77), organization: nil, email: nil), found.logins) == "account 00000000", "labels: address · organisation, or account and 8 characters")
    let tree8 = tree(wd8)
    check(tree(wd8) == tree8 && fm.contents(atPath: "\(wd8)/local-agent-mode-sessions/\(u5.account)/\(u5.organization!)/r.json") != nil, "finding changes nothing")
    // an account found by its id alone is reached by that id
    let idGoal = SwitchRunner.Goal(standby: "x", wantedSeat: Seat(account: u6.account, organization: nil, email: nil), wantedEmail: "", from: u1, started: t0)
    check(SwitchRunner.reached(idGoal, u6) && !SwitchRunner.reached(idGoal, u2), "an account known by its id alone: reached by that id")

    // the Claude app's account (its log, config.json), the active account and every surface reading one record: Checks/surfaces
    var p8u = p8; p8u.claudeWindow = true
    check(FolderRules.windowOnAnotherAccount(p8u, signedIn: { _ in u1 }, window: { _ in u2.account }) && !FolderRules.windowOnAnotherAccount(p8u, signedIn: { _ in u2 }, window: { _ in u2.account.uppercased() }),
          "the window on another account than Claude Code: said; the same (any case): not")
    check(FolderRules.windowWords(p8u, window: u2.account, names: [u2.account: u2.email!]).hasSuffix("Usage shown is Claude Code's.")
          && FolderRules.windowWords(p8u, window: uuid(55), names: [:]).contains("account 00000000"), "said plainly, by address or the id's first 8")

    // who owns a session now: `claude` processes' command lines and the folder's live registrations
    put(expand("~/.claude-p8/sessions/4242.json"), #"{"pid":4242,"sessionId":"\#(uuid(902))"}"#)
    put(expand("~/.claude-p8/sessions/4343.json"), #"{"pid":4343,"sessionId":"\#(uuid(903))"}"#)
    put(expand("~/.claude-p8/sessions/4444.json"), #"{"pid":1,"sessionId":"\#(uuid(904))"}"#)
    let ps = " 100 /opt/homebrew/bin/claude --resume \(uuid(901).uppercased())\n 101 /bin/zsh -c claude \(uuid(905))\n 102 claude\n"
    let owned = SwitchEngine.owned(ps: ps, codeDir: "~/.claude-p8", alive: { $0 == 4242 || $0 == 4444 })
    check(owned == [uuid(901), uuid(902)], "owned: an id on a claude command line, a live registration; not another program's, not a dead or mismatched registration: \(owned.sorted())")
}

// ============ 8b. the move inside the one folder: backup, held sessions, tasks with their state, Undo ============
do {
    let wdE = expand("~/Library/Application Support/Claude-move8")
    let src = SwitchEngine.scopeDir(wdE, SeatID(u1)), dst = SwitchEngine.scopeDir(wdE, SeatID(u2))
    let a = "local_\(uuid(811)).json", h = "local_\(uuid(812)).json", tk = "local_\(uuid(813)).json"
    let aBytes = #"{"sessionId":"local_a","cliSessionId":"\#(uuid(821))","error":"old","bridgeSessionIds":["b1"]}"#
    put("\(src)/\(a)", aBytes)
    put("\(src)/\(h)", #"{"sessionId":"local_h","cliSessionId":"\#(uuid(822))"}"#)
    put("\(src)/\(tk)", #"{"sessionId":"local_t","scheduledTaskId":"t1"}"#)
    put("\(src)/scheduled-tasks.json", #"{"scheduledTasks":[{"id":"t1","notifySessionId":"local_t"}],"recordedSkips":{"t1":{"n":2}},"runRetries":{}}"#)
    put("\(dst)/scheduled-tasks.json", #"{"scheduledTasks":[{"id":"t9"}],"runRetries":{"t9":1}}"#)
    var e = profile("mv", "~/.claude-mv", u1, standby: [StandbyAccount(email: u2.email!, seat: u2, id: "k2")])
    e.desktop = .separate; e.desktopDataDir = wdE
    let k2 = e.standby[0]
    try! Store.save([e])                    // Undo checks the receipt's folders against the profile's own (SwitchEngine.undoPlaces)
    guard case .success(let p) = SwitchEngine.plan(e, standby: k2, dataDir: wdE, owned: [uuid(822)]) else { check(false, "plan"); exit(1) }
    check(p.move == [a, tk].sorted() && p.held == [h] && p.tasks == 1 && p.moves, "the plan: the free sessions move, the owned one is held, the task goes")
    check(fm.fileExists(atPath: "\(src)/\(a)") && !fm.fileExists(atPath: dst + "/" + a), "planning moves nothing")
    let place = URL(fileURLWithPath: home + "/bk8")
    check((try? SwitchEngine.run(p, windowClosed: { false }, backups: place)) == nil && !fm.fileExists(atPath: dst + "/" + a), "the window open: refused, nothing moved")
    let r = try! SwitchEngine.run(p, windowClosed: { true }, backups: place)
    check(r.held == [h] && r.backup != nil && SessionsBackup.load(profile: "mv", id: r.backup!, place: place)?.kind == .beforeSwitch(r.id), "a backup first, naming the receipt; the held one noted")
    let moved = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dst + "/" + a)))) as? [String: Any]
    check(moved != nil && moved?["error"] == nil && (moved?["bridgeSessionIds"] as? [Any])?.isEmpty == true && moved?["sessionId"] as? String == "local_a",
          "moved without the old account's error keys and Remote Control ids, same id")
    check(!fm.fileExists(atPath: "\(src)/\(a)") && fm.fileExists(atPath: "\(src)/\(h)") && fm.fileExists(atPath: SwitchEngine.root.path + "/\(r.id)/parked/\(a)"),
          "the original parked, never deleted; the held one stays")
    let dt = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(dst)/scheduled-tasks.json")))) as? [String: Any]
    let st = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(src)/scheduled-tasks.json")))) as? [String: Any]
    check(((dt?["scheduledTasks"] as? [[String: Any]])?.compactMap { $0["id"] as? String }) == ["t9", "t1"]
          && (dt?["recordedSkips"] as? [String: Any])?["t1"] != nil && (dt?["runRetries"] as? [String: Any])?["t9"] as? Int == 1,
          "the task and its skips joined the new account's, its own kept")
    check((st?["scheduledTasks"] as? [Any])?.isEmpty == true && (st?["recordedSkips"] as? [String: Any])?["t1"] == nil, "the old account keeps no task and no state for it")
    check(SwitchEngine.unfinished(profile: "mv").map(\.id) == [r.id], "not linked yet: unfinished, for Undo")
    let back = try! SwitchEngine.undo(r.id, windowClosed: { true })
    check(back.undone != nil && (try? Data(contentsOf: URL(fileURLWithPath: "\(src)/\(a)"))) == Data(aBytes.utf8) && !fm.fileExists(atPath: dst + "/" + a),
          "Undo: the original back byte for byte, the copy gone")
    let st2 = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(src)/scheduled-tasks.json")))) as? [String: Any]
    check((st2?["scheduledTasks"] as? [Any])?.count == 1 && SwitchEngine.unfinished(profile: "mv").isEmpty, "Undo: the tasks back, nothing unfinished")
    // linked: the way back is a switch
    guard case .success(let p2) = SwitchEngine.plan(e, standby: k2, dataDir: wdE, owned: []) else { check(false, "plan 2"); exit(1) }
    let r2 = try! SwitchEngine.run(p2, windowClosed: { true }, backups: place)
    SwitchEngine.markLinked(r2.id)
    check(SwitchEngine.load(r2.id)?.linked != nil && (try? SwitchEngine.undo(r2.id, windowClosed: { true })) == nil, "linked: not undone")
    check(SwitchEngine.unfinished(profile: "mv").isEmpty, "linked: not unfinished")
    // a target with the same task and other state: the tasks stay, and so do their sessions
    put("\(wdE)/claude-code-sessions/\(u3.account)/\(u3.organization!)/scheduled-tasks.json", #"{"scheduledTasks":[{"id":"t1"}],"recordedSkips":{"t1":{"n":1}}}"#)
    put("\(SwitchEngine.scopeDir(wdE, SeatID(u2)))/scheduled-tasks.json", #"{"scheduledTasks":[{"id":"t1"}],"recordedSkips":{"t1":{"n":9}}}"#)
    var back2 = e; back2.seat = u2; back2.standby = [StandbyAccount(email: u3.email!, seat: u3, id: "k3")]
    guard case .success(let p3) = SwitchEngine.plan(back2, standby: back2.standby[0], dataDir: wdE, owned: []) else { check(false, "plan 3"); exit(1) }
    check(p3.tasks == 0 && p3.held.contains(tk) && p3.move.contains(a), "a task the new account has with other state: the tasks stay, the session of it is held, the rest move")
    check(SwitchEngine.taskProblem(source: SwitchEngine.scopeDir(wdE, SeatID(u2)), target: SwitchEngine.scopeDir(wdE, SeatID(u3)))?.contains("other state") == true,
          "said as a state collision")
    put("\(wdE)/claude-code-sessions/\(uuid(70))/\(uuid(71))/scheduled-tasks.json", "{ not json")
    check(SwitchEngine.taskProblem(source: "\(wdE)/claude-code-sessions/\(uuid(70))/\(uuid(71))", target: dst) == "its scheduled-tasks.json can't be read", "an unreadable registry stops the tasks")
    // nothing to move: only the sign-in (no receipt, no backup)
    let empty = expand("~/Library/Application Support/Claude-empty8")
    guard case .success(let p4) = SwitchEngine.plan(e, standby: k2, dataDir: empty, owned: []) else { check(false, "plan 4"); exit(1) }
    check(!p4.moves, "no session on the account in use: nothing to move")
    check(SessionsBackup.list(profile: "mv", place: place).count == 2, "a backup per switch that moved something")
}

// ============ 9. the standby accounts' old files, and old switches read only ============
do {
    let d = UserDefaults.standard                 // this program's own domain (run.sh removes its file afterwards)
    d.set("x", forKey: "sbfull.main~k2"); d.set("y", forKey: "keep.me")
    put(SwitchEngine.root.path + "/back/main~k2.json", "{}")
    LegacyCleanup.forgetBackOffers(defaults: d)
    check(d.string(forKey: "sbfull.main~k2") == nil && d.string(forKey: "keep.me") == "y" && !fm.fileExists(atPath: SwitchEngine.root.path + "/back"),
          "\"the other account is back\" goes: its offers and marks, nothing else")
    d.removeObject(forKey: "keep.me")
    // an old switch that stopped half way: read, never a reason to refuse a restore
    var r = SwitchReceipt(id: SwitchEngine.receiptID(t0, "main"), profile: "main", standby: "k2", dataDir: home + "/wd", from: SeatID(u1), to: SeatID(u2), started: t0)
    r.steps = (0..<3).map { _ in SwitchReceipt.Step(kind: .entry, path: "/x", sha: nil, parked: "/p", original: "/o", done: true) }
    r.backup = "b1"
    let dir = SwitchEngine.root.appendingPathComponent(r.id)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    try! enc.encode(r).write(to: dir.appendingPathComponent("receipt.json"))
    let receiptBytes = try! Data(contentsOf: dir.appendingPathComponent("receipt.json"))
    check(SwitchEngine.unfinished(profile: "main").map(\.id) == [r.id], "an old switch that stopped half way is still read")
    check(SessionsRestore.blocker(profile: "main") == nil, "…and no longer stops a restore")
    let e = profile("main", "~/.claude", u1, standby: [StandbyAccount(email: u2.email!, seat: u2, id: "k2")])
    let words = SessionsCard.oldSwitchWords(r, for: e)
    check(words.contains("moved 3 of the Claude window's sessions to ultra-2") && words.contains("Undo it") && words.contains("backup"),
          "the Sessions card says where its sessions are, Undo it, and the backup: \(words)")
    check(!SessionsCard.oldSwitchDismissed(r.id), "said until Not now")
    SessionsCard.dismissOldSwitch(r.id)
    check(SessionsCard.oldSwitchDismissed(r.id), "Not now: not said again")
    check((try? Data(contentsOf: dir.appendingPathComponent("receipt.json"))) == receiptBytes, "reading it never writes the receipt")
    try? fm.removeItem(at: dir)
    UserDefaults.standard.removeObject(forKey: "oldSwitchSeen")
}

// ============ 10. review round 1: crafted dates, leftovers, one standby list, the leaving week, the sweep, two writers ============
do {
    // crafted dates in the profiles file: read as nothing, never a trap
    let crafted = """
    {"accounts":[{"id":"cr","name":"Cr","label":"CR","configDir":"~/.claude-cr","standby":[
      {"id":"a","email":"a@example.com","lastInUse":-1e300,"addedAt":1e300,"lastWeekResets":-1e300,"lastWeek":1e308},
      {"id":"b","email":"b@example.com","lastInUse":4e9,"lastWeek":-5},
      {"id":"c","email":"c@example.com","lastInUse":-978307200,"lastWeek":42}]}]}
    """
    let list = (try? JSONDecoder().decode(ConfigFile.self, from: Data(crafted.utf8)))?.accounts ?? []
    let sb = list.first?.standby ?? []
    check(sb.count == 3 && sb.allSatisfy { $0.lastInUse == nil && $0.lastWeekResets == nil } && sb[0].addedAt == nil,
          "crafted dates (±1e300, far ahead, before 2000) are read as none")
    check(sb[0].lastWeek == nil && sb[1].lastWeek == nil && sb[2].lastWeek == 42, "a week that isn't 0…1000 is read as none")
    let words = [Date(timeIntervalSinceReferenceDate: -1e300), Date(timeIntervalSinceReferenceDate: 1e300), .distantPast, .distantFuture]
        .map { AccountBook.ago($0, now: t0) }
    check(words.count == 4 && words[1] == "just now" && words[3] == "just now" && words[0].hasSuffix("weeks ago"), "ago never traps: \(words)")
    var e = profile("cr", "~/.claude-cr", u1, standby: sb)
    e.id = "cr"
    check(SwitchMenu.lines(e, now: t0).count == 3 && e.cardTrays(now: t0).count == 3, "the menus and the card draw them")

    // the default-profile move's Keep it never lists the old profile's own folder
    var old = profile("old", "~/.claude-old", u2); old.leftoverFolders = ["~/.claude-old-u3", "~/.claude-old"]
    let def = profile("main", "~/.claude", u1)
    check(DefaultProfileRunner.leftovers(of: old, into: def) == ["~/.claude-old-u3"], "Keep it: only the old profile's own leftovers, never its own folder")

    // what a folder holds; one with sessions is never offered for the Trash
    put(expand("~/.claude-withwork/projects/-p/\(uuid(77)).jsonl"), "{}")
    put(expand("~/.claude-withwork/projects/-q/\(uuid(78)).jsonl"), "{}")
    put(expand("~/.claude-withwork/CLAUDE.md"), "# x")
    put(expand("~/.claude-withwork/skills/a/SKILL.md"), "x")
    let all = [def]
    var w = def; w.leftoverFolders = ["~/.claude-withwork"]
    let f = Leftovers.offered(w, among: all).first
    check(f?.inside == Leftovers.Inside(sessions: 2, settings: false, claudeMD: true, other: 1, projects: 2) && f?.trashable == false,
          "a folder's sessions, CLAUDE.md and other items are counted; one with sessions isn't trashable")
    check(Leftovers.line(f!).contains("holds 2 sessions") && Leftovers.line(f!).contains("Finder"), "…and its line says why and offers Finder")
    let before = trashed.count
    check(Leftovers.trash(f!, among: all) != nil && trashed.count == before, "…and Move to Trash refuses it")
    sign("~/.claude-ultra-1", u1)
    let plain = Leftovers.Folder(path: "~/.claude-ultra-1", keychainItem: "k", inside: Leftovers.Inside.of("~/.claude-ultra-1"))
    check(Leftovers.question(plain).detail.hasPrefix("In it: the account record (.claude.json)") && Leftovers.question(plain).detail.contains("isn't in the folder"),
          "the Trash question says what is in the folder, and that the sign-in itself is in the Keychain: \(Leftovers.question(plain).detail.prefix(60))")

    // offerable: only ~/.claude-<name> directly in the home folder, never a profile's window folder
    try? fm.createDirectory(atPath: expand("~/Documents/x"), withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: expand("~/.claude-deep/.claude-inner"), withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: expand("~/.claude-window"), withIntermediateDirectories: true)
    var withWindow = profile("win", "~/.claude-win", u4); withWindow.desktop = .separate; withWindow.desktopDataDir = "~/.claude-window"
    check(!Leftovers.offerable("~/Documents", among: all) && !Leftovers.offerable("~/Documents/x", among: all), "a folder not named ~/.claude-<name> isn't offered")
    check(!Leftovers.offerable("~/.claude-deep/.claude-inner", among: all), "nor one deeper than the home folder")
    check(!Leftovers.offerable("~/.claude-", among: all), "nor the bare prefix")
    check(Leftovers.offerable("~/.claude-window", among: all) && !Leftovers.offerable("~/.claude-window", among: all + [withWindow]),
          "nor a profile's Claude window folder")

    // one account on one standby list: a stale entry for the leaving account on another profile's list goes
    let p1 = profile("p1", "~/.claude-p1", u1)
    let p2 = profile("p2", "~/.claude-p2", u3, standby: [StandbyAccount(email: u1.email!, seat: u1, id: "x1")])
    let noted = FolderRules.noteAccounts([p1, p2], signedIn: { $0 == "~/.claude-p1" ? u2 : ($0 == "~/.claude-p2" ? u3 : nil) }, status: { _ in nil }, now: t0)
    let holders = noted.filter { $0.standby.contains { $0.seat.map { $0.same(u1) } == true } }.map(\.id)
    check(holders == ["p1"], "the leaving account stands by on one list only: \(holders)")

    // the leaving account's week, even after another account's numbers took its place
    let me = profile("lw", "~/.claude-lw", u1)
    var a = IconStatus(state: "ok"); a.loginEmail = u1.email; a.weekly = 88; a.weeklyResets = t0.addingTimeInterval(3600); a.plan = "Max"
    var b = IconStatus(state: "ok"); b.loginEmail = u2.email; b.weekly = 3
    _ = Store.writeStatus("lw", a)
    check(Store.lastStatus(of: me)?.weekly == 88, "the account's own numbers")
    _ = Store.writeStatus("lw", b)
    check(Store.lastStatus(of: me)?.weekly == 88 && fm.fileExists(atPath: Store.statusFolder.appendingPathComponent("lw.prev").path),
          "another account's numbers took their place: the leaving account's are still found (lw.prev)")
    let after = FolderRules.noteAccounts([me], signedIn: { _ in u2 }, now: t0)[0]
    check(after.standby.first?.lastWeek == 88 && after.standby.first?.plan == "Max", "…and remembered with it when it stands by")

    // Cleanup's sweep: a standby account's old status file and a removed profile's go, nothing else
    for n in ["keep.json", "keep.prev", "keep~k2.json", "gone.json", "gone.prev", "notes.txt"] { put(Store.statusFolder.appendingPathComponent("sweep/" + n).path, "{}") }
    let stale = Cleanup.staleStatus(in: Store.statusFolder.appendingPathComponent("sweep"), ids: ["keep"]).map(\.lastPathComponent).sorted()
    check(stale == ["gone.json", "gone.prev", "keep~k2.json"], "the clean-up sweeps a standby account's and a removed profile's saved numbers only: \(stale)")

    // two writers: the window's stale copy saved over the agent's note heals at the next note
    let base = [profile("tw", "~/.claude-tw", u1)]
    let remote = FolderRules.noteAccounts(base, signedIn: { _ in u2 }, now: t0)          // the agent noted ultra-2
    var local = base; local[0].name = "Tw renamed"                                       // the window renamed it meanwhile
    let merged = SettingsModel.merge(base: base, local: local, remote: remote)
    check(merged[0].name == "Tw renamed", "the window's change wins the merge (its copy still names ultra-1)")
    let healed = FolderRules.noteAccounts(merged, signedIn: { _ in u2 }, now: t0)
    check(healed[0].seat.map { $0.same(u2) } == true && healed[0].standby.map { $0.seat?.account } == [u1.account] && healed[0].name == "Tw renamed",
          "the next note puts the folder's account back, the rename kept, one standby entry")

    // the login script is written for its owner only
    opened = []
    // (New profile's sign-in: the only one that makes its folder)
    _ = ClaudeCLI.openLogin(home + "/fakebin/claude", account: Account(profile("ls", "~/.claude-ls", u1)), email: "ls@example.com", creating: true)
    let script = ClaudeCLI.loginScript(expand("~/.claude-ls"))
    let mode = ((try? fm.attributesOfItem(atPath: script.path))?[.posixPermissions] as? NSNumber)?.intValue
    check(mode == 0o700 && opened.count == 1, "the login script is 0700 (\(String(mode ?? 0, radix: 8))) and only handed to the Terminal stand-in")
    try? fm.removeItem(at: script)

    // a hand-edited profile id never names a marker outside cl_audit's folder
    let mk = SwitchRunner.marker(for: "../../evil")
    check(mk.deletingLastPathComponent().path == Store.folder.path && !mk.lastPathComponent.contains("/"), "the sign-in marker stays in cl_audit's folder")
}

// ============ 11. review round 2: sessions unknown, counted off the main thread, links, the agent's note, the other profile's note ============
do {
    let all = [profile("main", "~/.claude", u1)]
    func folder(_ p: String) -> Leftovers.Folder { Leftovers.offered({ var e = all[0]; e.leftoverFolders = [p]; return e }(), among: all).first! }
    // a projects folder that can't be listed: sessions unknown, never trashable, said so
    put(expand("~/.claude-locked/projects/-p/\(uuid(81)).jsonl"), "{}")
    chmod(expand("~/.claude-locked/projects"), 0o000)
    let locked = folder("~/.claude-locked")
    chmod(expand("~/.claude-locked/projects"), 0o700)
    check(!locked.inside.known && !locked.trashable, "a projects folder that can't be listed: sessions unknown, not trashable")
    check(Leftovers.line(locked).contains("couldn't be counted") && Leftovers.line(locked).contains("Finder"), "…and its line says so and offers Finder")
    check(Leftovers.question(locked).detail.contains("projects (its sessions couldn't be counted)"), "…and the Trash question names projects")
    chmod(expand("~/.claude-locked/projects"), 0o000)
    let before = trashed.count
    check(Leftovers.trash(locked, among: all) != nil && trashed.count == before, "…and Move to Trash refuses it at the click too")
    chmod(expand("~/.claude-locked/projects"), 0o700)
    // projects is a link: never followed
    put(expand("~/elsewhere/-p/\(uuid(82)).jsonl"), "{}")
    try? fm.createDirectory(atPath: expand("~/.claude-plink"), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: expand("~/.claude-plink/projects"), withDestinationPath: expand("~/elsewhere"))
    let plink = folder("~/.claude-plink")
    check(!plink.inside.known && plink.inside.sessions == 0 && !plink.trashable, "a projects link isn't followed: sessions unknown, not trashable")
    // a project folder that is a link: not looked into either
    put(expand("~/.claude-sublink/projects/-real/notes.txt"), "x")
    try? fm.createSymbolicLink(atPath: expand("~/.claude-sublink/projects/-q"), withDestinationPath: expand("~/elsewhere/-p"))
    check(!folder("~/.claude-sublink").inside.known, "a project folder that is a link: sessions unknown")
    // an empty projects and one with folders but no sessions
    put(expand("~/.claude-nosess/projects/-p/notes.txt"), "x"); put(expand("~/.claude-nosess/projects/-q/notes.txt"), "x")
    let nosess = folder("~/.claude-nosess")
    check(nosess.trashable && Leftovers.question(nosess).detail.contains("projects (2 folders, no sessions)"), "projects with folders but no sessions: trashable, said with its count")
    // the cap: a folder with more names than that is not counted
    for n in 0..<6 { put(expand("~/.claude-big/projects/-p\(n)/x.txt"), "x") }
    check(!Leftovers.Inside.of("~/.claude-big", cap: 4).known && Leftovers.Inside.of("~/.claude-big").known, "more names than the cap: sessions unknown")
    // a leaf swapped for a link between the offer and the click: nothing moves
    try? fm.createDirectory(atPath: expand("~/.claude-swap"), withIntermediateDirectories: true)
    let swap = folder("~/.claude-swap")
    check(swap.trashable, "a plain empty folder is offered for the Trash")
    try? fm.removeItem(atPath: expand("~/.claude-swap"))
    try? fm.createSymbolicLink(atPath: expand("~/.claude-swap"), withDestinationPath: expand("~/elsewhere"))
    check(Leftovers.trash(swap, among: all) != nil && trashed.count == before, "swapped for a link after the offer: refused at the click, nothing moves")
    // not counted yet: never trashable, and says it is looking
    let pending = Leftovers.offered({ var e = all[0]; e.leftoverFolders = ["~/.claude-nosess"]; return e }(), among: all, inside: { _ in nil }).first!
    check(!pending.trashable && Leftovers.line(pending).hasSuffix("Looking at what's in it…"), "not counted yet: not trashable, the line says it is looking")

    // the card's counts: off the main thread, kept until the folder changes, counted again when it appears
    MainActor.assumeIsolated {
        let c = LeftoverCounts()
        check(c.inside("~/.claude-nosess") == nil, "nothing counted yet")
        c.countNow(["~/.claude-nosess"])
        check(c.inside("~/.claude-nosess")?.projects == 2, "counted: kept")
        Thread.sleep(forTimeInterval: 1.1)
        put(expand("~/.claude-nosess/projects/-r/\(uuid(83)).jsonl"), "{}")
        check(c.inside("~/.claude-nosess") == nil, "the projects folder changed: counted again")
        c.refresh(["~/.claude-nosess"])
        let deadline = Date().addingTimeInterval(5)
        while c.inside("~/.claude-nosess") == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check(c.inside("~/.claude-nosess")?.sessions == 1, "refresh counts off the main thread and publishes it")
    }

    // the agent notes the folder's account under the profiles file's lock, end to end, and the other profile is told
    let n1 = profile("n1", "~/.claude-n1", u1)
    let n2 = profile("n2", "~/.claude-n2", u3, standby: [StandbyAccount(email: u1.email!, id: "r1")])     // remembered by address
    sign("~/.claude-n1", u2); sign("~/.claude-n2", u3)
    try! Store.save([n1, n2])
    AgentDelegate().noteAccounts()
    let after = Store.loadChecked() ?? []
    let a1 = after.first { $0.id == "n1" }, a2 = after.first { $0.id == "n2" }
    check(a1?.seat.map { $0.same(u2) } == true && a1?.standby.contains { $0.seat.map { $0.same(u1) } == true } == true,
          "the agent: n1 follows its folder to ultra-2, ultra-1 stands by on it (saved under the lock)")
    check(a2?.standby.isEmpty == true && a2?.accountNote?.kind == .standsBy && a2?.accountNote?.profile == "N1",
          "the remembered entry on n2 goes, and n2 says why: \(a2?.accountNote?.words ?? "no note")")
    check(a2?.accountNote?.words.contains("stands by on N1 now") == true, "…in words")
    let lock = Store.folder.appendingPathComponent("accounts.lock").path
    check(fm.fileExists(atPath: lock), "the profiles file's lock was taken")
    for d in ["~/.claude-n1", "~/.claude-n2"] { sign(d, nil) }
}

// ============ 12. review round 3: bounded reads, links inside the folders, Undo's places and window, linking, the program ============
do {
    // M2: a FIFO or a link to /dev/zero named like a .claude.json, a backup or a transcript returns at once, with nothing
    mkfifo(expand("~/.claude.json.backup.fifo"), 0o600)
    try? fm.createSymbolicLink(atPath: expand("~/.claude-zero"), withDestinationPath: "/dev/zero")
    try? fm.createDirectory(atPath: expand("~/.claude-fifo/projects/-x"), withIntermediateDirectories: true)
    mkfifo(expand("~/.claude-fifo/.claude.json"), 0o600)
    mkfifo(expand("~/.claude-fifo/projects/-x/\(uuid(1201)).jsonl"), 0o600)
    try? fm.createDirectory(atPath: expand("~/.claude-fifo/backups"), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: expand("~/.claude-fifo/backups/.claude.json.backup.1"), withDestinationPath: "/dev/zero")
    let pf = profile("pf", "~/.claude-fifo", u1)
    var t = Date()
    let foundF = AccountList.find([pf])
    check(Date().timeIntervalSince(t) < 3 && foundF.transcripts["pf"]?.isEmpty == true, "find: a FIFO .claude.json, backup and transcript and a /dev/zero link return at once")
    t = Date()
    _ = AccountList.names(now: Date().addingTimeInterval(3600))
    check(Date().timeIntervalSince(t) < 3, "names: the same")
    t = Date()
    check(Account.signedInSeat(configDir: "~/.claude-fifo") == nil && AccountFacts.of(configDir: "~/.claude-fifo") == nil && Date().timeIntervalSince(t) < 1,
          "signedInSeat and the folder's facts: a FIFO .claude.json is no sign-in, at once")
    t = Date()
    check(SwitchEngine.lastPointer(expand("~/.claude-fifo/projects/-x/\(uuid(1201)).jsonl")) == nil && SwitchEngine.lastPointer("/dev/zero") == nil
          && Date().timeIntervalSince(t) < 1, "the pointer's read: a FIFO transcript and /dev/zero return at once")
    // review r2: a FIFO named usage.json (read on the agent's main-thread tick) returns at once
    mkfifo(expand("~/.claude-fifo/usage.json"), 0o600)
    t = Date()
    check(UsageParser.fromStatusLine(Account(pf)) == nil && Date().timeIntervalSince(t) < 1, "a FIFO usage.json returns at once, no numbers")
    // a .claude.json larger than the cap: not read, and said as too large, never as signed out
    try? fm.createDirectory(atPath: expand("~/.claude-huge12"), withIntermediateDirectories: true)
    fm.createFile(atPath: expand("~/.claude-huge12/.claude.json"), contents: nil)
    if let h = FileHandle(forWritingAtPath: expand("~/.claude-huge12/.claude.json")) { try? h.truncate(atOffset: UInt64(SafeRead.claudeJSONMax + 1)); try? h.close() }
    t = Date()
    let hugeSeat = Account.signedInSeat(configDir: "~/.claude-huge12")
    check(hugeSeat == nil && Account.recordTooLarge(configDir: "~/.claude-huge12") && Date().timeIntervalSince(t) < 1, "a .claude.json over 256 MB isn't read (at once)")
    let hp = profile("hp", "~/.claude-huge12", u1)
    let hr = AccountResolver.resolve(hp, among: [hp], app: .unknown, code: nil, loginEmail: nil, names: [:], recordTooLarge: true, now: t0)
    var hst = IconStatus(state: "ok"); hst.resolved = hr
    check(hr.line?.contains("too large to read") == true && AccountView.of(hst).recordTooLarge && !(hr.line ?? "").contains("signed out"),
          "said as too large to read, never as signed out: \(hr.line ?? "-")")
    try? fm.removeItem(atPath: expand("~/.claude-huge12"))
    // a .claude.json read follows a link to a real file (reads follow links), and a changed file is read again
    sign("~/.claude-real12", u2)
    try? fm.createSymbolicLink(atPath: expand("~/.claude-lnk12"), withDestinationPath: expand("~/.claude-real12"))
    check(Account.signedInSeat(configDir: "~/.claude-lnk12")?.same(u2) == true, "a folder that is a link to a real one: read")
    Thread.sleep(forTimeInterval: 0.02); sign("~/.claude-real12", u3)
    check(Account.signedInSeat(configDir: "~/.claude-real12")?.same(u3) == true, "a .claude.json that changed is read again (the parse is kept by its stamp)")
    for p in ["~/.claude.json.backup.fifo", "~/.claude-zero", "~/.claude-fifo", "~/.claude-real12", "~/.claude-lnk12"] { try? fm.removeItem(atPath: expand(p)) }

    // the move's fixture: a profile with its own window folder, one session on ultra-1
    let wd = expand("~/Library/Application Support/Claude-r3")
    let src = SwitchEngine.scopeDir(wd, SeatID(u1)), dst = SwitchEngine.scopeDir(wd, SeatID(u2))
    let s1 = "local_\(uuid(1211)).json", s2 = "local_\(uuid(1212)).json"
    func fixture() {
        try? fm.removeItem(atPath: wd)
        put("\(src)/\(s1)", #"{"sessionId":"local_1"}"#); put("\(src)/\(s2)", #"{"sessionId":"local_2"}"#)
    }
    try? fm.createDirectory(atPath: expand("~/.claude-r3/projects"), withIntermediateDirectories: true)
    var e = profile("r3", "~/.claude-r3", u1, standby: [StandbyAccount(email: u2.email!, seat: u2, id: "k2")])
    e.desktop = .separate; e.desktopDataDir = wd
    try! Store.save([e])
    let place = URL(fileURLWithPath: home + "/bk12")

    // SHOULD 3: a link as a scope folder, or as projects/<p>: refused, and the plan says why
    fixture()
    try? fm.createDirectory(atPath: home + "/elsewhere12", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: "\(wd)/claude-code-sessions", withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: "\(wd)/claude-code-sessions/\(u2.account)", withDestinationPath: home + "/elsewhere12")
    if case .failure(let why) = SwitchEngine.plan(e, standby: e.standby[0], dataDir: wd, owned: []) {
        check(why.description.contains("isn't a plain folder"), "the new account's scope folder a link: refused, said why")
    } else { check(false, "a link as the scope folder is refused") }
    check(((try? fm.contentsOfDirectory(atPath: home + "/elsewhere12")) ?? []).isEmpty, "nothing written through it")
    try? fm.removeItem(atPath: "\(wd)/claude-code-sessions/\(u2.account)")
    try? fm.createSymbolicLink(atPath: expand("~/.claude-r3/projects/-linked"), withDestinationPath: home + "/elsewhere12")
    if case .failure(let why) = SwitchEngine.plan(e, standby: e.standby[0], dataDir: wd, owned: []) {
        check(why.description.contains("projects/-linked"), "a project folder that is a link: refused, said why")
    } else { check(false, "a link as projects/<p> is refused") }
    try? fm.removeItem(atPath: expand("~/.claude-r3/projects/-linked"))

    // SHOULD 6: a receipt whose step names a place outside the switch's folders: that step is skipped, said
    fixture()
    guard case .success(let p) = SwitchEngine.plan(e, standby: e.standby[0], dataDir: wd, owned: []) else { check(false, "plan r3"); exit(1) }
    var r = try! SwitchEngine.run(p, windowClosed: { true }, backups: place)
    let victim = home + "/victim12.json"
    put(victim, #"{"sessionId":"local_1"}"#)
    r.steps[0].path = victim
    r.steps[0].sha = SwitchEngine.sha(Data(#"{"sessionId":"local_1"}"#.utf8))
    r.steps[1].path = "\(dst)/../../../../../victim12.json"
    try! SwitchEngine.save(r)
    let crafted = try! SwitchEngine.undo(r.id, windowClosed: { true })
    check(fm.fileExists(atPath: victim) && crafted.problems.filter { $0.contains("outside this switch's folders") }.count == 2,
          "Undo: a crafted path outside the scope (or climbing out of it) is skipped and named: \(crafted.problems)")
    check(crafted.undone == nil && crafted.partlyUndone != nil && crafted.left?.count == 2 && SwitchEngine.unfinished(profile: "r3").contains { $0.id == r.id },
          "…so it is only partly undone, names what was left, and stays open for another Undo")
    try? fm.removeItem(at: SwitchEngine.root.appendingPathComponent(r.id))      // out of the way of the cases below

    // SHOULD 1: the window opening during Undo stops it before the next step
    fixture()
    guard case .success(let p2) = SwitchEngine.plan(e, standby: e.standby[0], dataDir: wd, owned: []) else { check(false, "plan r3b"); exit(1) }
    let r2 = try! SwitchEngine.run(p2, windowClosed: { true }, backups: place)
    var asked = 0
    let opened = (try? SwitchEngine.undo(r2.id, windowClosed: { asked += 1; return asked <= 2 })) == nil
    check(opened && SwitchEngine.load(r2.id)?.undone == nil && SwitchEngine.load(r2.id)?.problems.contains { $0.contains("opened during Undo") } == true,
          "Undo stops when the window opens mid-run; not marked undone, said")
    let window = Launcher.dataDirKey(of: Account(e))
    check(SwitchMarker.claim(window, profile: "other", standby: "x") && (try? SwitchEngine.undoHolding(r2.id, account: Account(e), windowClosed: { true })) == nil,
          "Undo holds the window like a switch: refused while another run holds it")
    SwitchMarker.release(window, profile: "other", standby: "x")
    let held = try? SwitchEngine.undoHolding(r2.id, account: Account(e), windowClosed: { true })
    check(held?.undone != nil && SwitchMarker.current(window) == nil, "…and runs once it's free, letting the window go after")

    // SHOULD 2: a receipt never linked while the folder reached the account: linked by the noting, and no longer blocking
    fixture()
    guard case .success(let p3) = SwitchEngine.plan(e, standby: e.standby[0], dataDir: wd, owned: []) else { check(false, "plan r3c"); exit(1) }
    let r3 = try! SwitchEngine.run(p3, windowClosed: { true }, backups: place)
    check(SwitchEngine.linkReached([e], signedIn: { _ in u1 }).isEmpty && SwitchEngine.unfinished(profile: "r3").map(\.id) == [r3.id], "still on ultra-1: not linked")
    check(SwitchEngine.linkReached([e], signedIn: { _ in Seat(account: u2.account.uppercased(), organization: u2.organization, email: nil) }) == [r3.id]
          && SwitchEngine.load(r3.id)?.linked != nil && SwitchEngine.unfinished(profile: "r3").isEmpty,
          "the folder reached ultra-2 (seen by the agent, not the page): linked, nothing left unfinished")
    var onU2 = e; onU2.seat = u2
    fixture()
    guard case .success(let p4) = SwitchEngine.plan(e, standby: e.standby[0], dataDir: wd, owned: []) else { check(false, "plan r3d"); exit(1) }
    let r4 = try! SwitchEngine.run(p4, windowClosed: { true }, backups: place)
    check(SwitchEngine.linkReached([onU2], signedIn: { _ in nil }) == [r4.id], "the profile's record on ultra-2: linked too")
    // an unfinished one says what the person can do
    fixture()
    guard case .success(let p5) = SwitchEngine.plan(e, standby: e.standby[0], dataDir: wd, owned: []) else { check(false, "plan r3e"); exit(1) }
    _ = try! SwitchEngine.run(p5, windowClosed: { true }, backups: place)
    let m12 = SettingsModel(); m12.accounts = [e]
    let run12 = m12.runner(of: "r3")
    run12.start(e.standby[0])
    if case .failed(let why) = run12.phase {
        check(why.contains("Undo it") && why.contains("sign in as ultra-2 to finish it"), "a switch that stopped half way: Undo it, or sign in to finish it: \(why)")
    } else { check(false, "an unfinished switch is said before a new one") }

    // SHOULD 7: the program is the executable's last path component, the path whole even with spaces
    check(SwitchEngine.isClaude(home + "/Library/Application Support/Claude/claude-code/2.1.318/claude --resume \(uuid(1220))")
          && SwitchEngine.isClaude("claude") && SwitchEngine.isClaude("/opt/homebrew/bin/claude -p hi")
          && !SwitchEngine.isClaude("/bin/zsh -c claude \(uuid(1220))") && !SwitchEngine.isClaude("/usr/bin/vim claude"),
          "claude by its executable's last path component, spaces in the path included; not as another program's argument")
    let ps = " 300 " + home + "/Library/Application Support/Claude/claude-code/2.1.318/claude --resume \(uuid(1221))\n"
    check(SwitchEngine.owned(ps: ps, codeDir: "~/.claude-r3", alive: { _ in false }) == [uuid(1221)], "the Claude app's own claude, under a path with a space: its session is owned")
    try? fm.removeItem(atPath: expand("~/.claude-r3"))
}

print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
