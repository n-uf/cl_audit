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
import ProfileCore
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
    // (ClaudeAuth's SignInScript since landing 2: a base URL and extra headers are unset too, and the lines it shows are
    // printed raw: `print -r --`, never zsh's echo, which takes a backslash in a path for an escape)
    let unset = "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS"
    let cmd = l1.firstIndex { $0.contains("auth login") } ?? 0
    check(l1.firstIndex(of: unset).map { $0 < cmd } == true, "a key, another provider, a base URL or extra headers from the shell's settings are unset before the sign-in")
    check(l1.contains("unset CLAUDE_CONFIG_DIR") && l1[cmd] == "'/opt/claude' auth login --claudeai --email 'ultra-2@example.com'",
          "~/.claude signs in with CLAUDE_CONFIG_DIR unset, the address filled in")
    check(!l1.contains { $0.contains(".done") }
          && l1.contains("if [ $s -eq 0 ]; then print -r -- 'Done. cl_audit picks up the new sign-in by itself within seconds.'; else print -r -- 'The sign-in did not finish. Close this window and try again from cl_audit.'; fi"),
          "no marker for a switch; \"Done.\" only when the login ended well, in cl_audit's words")
    check(l1.contains("print -r -- 'Signing in to Claude Code for ~/.claude…'") && !l1.contains { $0.hasPrefix("echo '") },
          "the folder named as ~, printed raw")
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
    let commands = ["/opt/homebrew/bin/claude --resume \(uuid(901).uppercased())", "/bin/zsh -c claude \(uuid(905))", "claude"]
    let owned = Processes.owned(commands: commands, codeDir: "~/.claude-p8", alive: { $0 == 4242 || $0 == 4444 })
    check(owned == [uuid(901), uuid(902)], "owned: an id on a claude command line, a live registration; not another program's, not a dead or mismatched registration: \(owned.sorted())")
    // the table those lines come from: a `claude` that can't be read (another user's, as with `sudo claude`) means "can't tell"
    let mine = Processes.Entry(pid: 9002, uid: getuid(), ruid: getuid(), name: "claude",
                               launch: Processes.Launch(exe: "/opt/homebrew/bin/claude", args: ["/opt/homebrew/bin/claude", "--resume", uuid(906)], configDir: nil))
    let rootClaude = Processes.Entry(pid: 9001, uid: 0, ruid: 0, name: "claude", launch: nil, hidden: true)
    let rootOther = Processes.Entry(pid: 9003, uid: 0, ruid: 0, name: "launchd", launch: nil)
    let unreadable = Processes.Entry(pid: 9004, uid: nil, ruid: nil, name: "", launch: nil, hidden: true)
    check(Processes.sessionsOwned(codeDir: "~/.claude-p8", table: [mine, rootOther])?.contains(uuid(906)) == true,
          "workers from a table: this user's claude is read, another user's other program isn't needed")
    check(Processes.sessionsOwned(codeDir: "~/.claude-p8", table: [mine, rootClaude]) == nil
          && Processes.sessionsOwned(codeDir: "~/.claude-p8", table: [mine, unreadable]) == nil
          && Processes.sessionsOwned(codeDir: "~/.claude-p8", table: .some(nil)) == nil,
          "workers: another user's claude that can't be read, a process that can't be read at all, no table: can't tell (nil)")
    check(Processes.sessionsOnCommandLines(table: [rootClaude]) == nil && Processes.commandLineNames(uuid(906), table: [mine, rootClaude]) == nil
          && Processes.commandLineNames(uuid(906), table: [mine]) == true && Processes.commandLineNames(uuid(907), table: [mine]) == false,
          "restore's running sessions and the switch's pgrep -f: nil when a claude can't be read; found or not otherwise")
    let held = expand("~/.claude-p8/projects/p/\(uuid(906)).jsonl")
    put(held, "{}\n")
    let later = Date().addingTimeInterval(60)
    check(SwitchEngine.busy(held, cli: uuid(906), now: later, table: [mine, rootClaude]) == "it couldn't be checked whether Claude Code runs it"
          && SwitchEngine.busy(held, cli: uuid(906), now: later, table: [mine]) == "Claude Code runs it"
          && SwitchEngine.busy(held, cli: uuid(907), now: later, table: [mine]) == nil,
          "the switch's pointer: held, and said, when a claude can't be read; held when one runs the session; free otherwise")
    check(Processes.looksLikeClaude("claude") && Processes.looksLikeClaude("2.1.318") && !Processes.looksLikeClaude("claude-helper")
          && !Processes.looksLikeClaude("launchd") && !Processes.looksLikeClaude("1password"),
          "a name that may be Claude Code: claude…, or the native installer's version number")
    // the new-account page: Code tab or terminal by the program as it was started (argv[0], what `ps -o comm` printed)
    let appClaude = home + "/Library/Application Support/Claude/claude-code/2.1.318/claude"
    let tab = Processes.Entry(pid: 9005, uid: getuid(), ruid: getuid(), name: "claude", launch: Processes.Launch(exe: appClaude, args: [appClaude], configDir: "/x/.claude-w"))
    let term = Processes.Entry(pid: 9006, uid: getuid(), ruid: getuid(), name: "claude", launch: Processes.Launch(exe: "/opt/homebrew/bin/claude", args: ["claude"], configDir: nil))
    check(Processes.codeRun(tab) == ClaudeRun(id: 9005, kind: .codeTab, folder: "/x/.claude-w") && Processes.codeRun(term) == ClaudeRun(id: 9006, kind: .terminal, folder: "~/.claude"),
          "new account: the app's claude is a Code tab's, a terminal's by name is a terminal's; the folder, or ~/.claude")
    // KERN_PROCARGS2 as the kernel lays it out: argc, the path, NULs to 8 bytes from the path's start, argv, the environment
    func procargs(_ exe: String, _ args: [String], _ env: [String]) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: 4)
        withUnsafeBytes(of: Int32(args.count)) { b in for k in 0..<4 { raw[k] = b[k] } }
        let path = Array(exe.utf8)
        raw += path + [UInt8](repeating: 0, count: (path.count + 1 + 7) / 8 * 8 - path.count)
        for s in args + env { raw += Array(s.utf8) + [0] }
        return raw + [0]
    }
    let env = ["CLAUDE_CONFIG_DIR=/c", "A=1"]
    let raw = procargs("/x/claude", ["claude", "", "-p"], env)
    check(Processes.parse(raw, size: raw.count) == Processes.Launch(exe: "/x/claude", args: ["claude", "", "-p"], configDir: "/c"),
          "argv by argc exactly, empty ones included; the environment isn't read as arguments")
    let emptyFirst = procargs("/x/claude", ["", "-p"], env), spaceFirst = procargs("/x/claude", [" --resume", uuid(906)], env)
    check(Processes.parse(emptyFirst, size: emptyFirst.count) == nil && Processes.parse(spaceFirst, size: spaceFirst.count) == nil
          && Processes.parse(Array(raw.prefix(24)), size: 24) == nil,
          "an empty or space-led first argument, or arguments cut short: not read (so hidden, never taken for not Claude)")
    // the padding rule on real processes: stand-ins (copies of /bin/sleep, never Claude) started at path lengths 7, 8, 15 and
    // 16 ("./" and a name, in their folder), then one with an empty argv[0]; each read back, then killed by its pid
    let standDir = home + "/standin"
    try? fm.createDirectory(atPath: standDir, withIntermediateDirectories: true)
    func spawn(_ path: String, _ argv: [String]) -> pid_t? {
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addchdir_np(&fa, standDir)
        let standinEnv: [String] = ["CLAUDE_CONFIG_DIR=/x/standin", "A=1"]
        let cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cenv: [UnsafeMutablePointer<CChar>?] = standinEnv.map { strdup($0) } + [nil]
        defer { cargv.forEach { free($0) }; cenv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, path, &fa, nil, cargv, cenv) == 0 ? pid : nil
    }
    func end(_ pid: pid_t) { kill(pid, SIGKILL); var st: Int32 = 0; waitpid(pid, &st, 0) }
    var standins: [String] = []
    for n in [5, 6, 13, 14] {
        let name = String(repeating: "s", count: n)
        try? fm.removeItem(atPath: standDir + "/" + name)
        try? fm.copyItem(atPath: "/bin/sleep", toPath: standDir + "/" + name)
        guard let pid = spawn("./" + name, ["standin", "30"]) else { standins.append("\(n + 2): not started"); continue }
        let got = Processes.launch(of: pid)
        end(pid)
        if got != Processes.Launch(exe: "./" + name, args: ["standin", "30"], configDir: "/x/standin") { standins.append("\(n + 2): \(String(describing: got))") }
    }
    check(standins.isEmpty, "a started stand-in reads back exactly at path lengths 7, 8, 15 and 16: \(standins)")
    if let pid = spawn("./sssss", ["", "30"]) {
        let got = Processes.launch(of: pid), entry = Processes.table()?.first { $0.pid == pid }
        end(pid)
        check(got == nil && entry?.hidden == true, "a stand-in with an empty argv[0]: not read, and hidden (\(String(describing: got)))")
    } else { check(false, "the stand-in with an empty argv[0] started") }
    // this Mac's own table reads (it is only read, never signalled): "can't tell" mustn't be the answer every time (a process
    // caught mid-start may be hidden for a moment: up to 3 reads)
    var real = Processes.table()
    for _ in 0..<2 where real?.contains(where: \.hidden) != false { real = Processes.table() }
    check(real != nil && Processes.commandLines(real) != nil && real?.contains { $0.pid == getpid() && $0.launch != nil } == true,
          "the real table reads, cl_audit's own process with its arguments; hidden: \(real?.filter(\.hidden).map(\.name) ?? [])")
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
    check(SwitchEngine.store.load(r2.id)?.linked != nil && (try? SwitchEngine.undo(r2.id, windowClosed: { true })) == nil, "linked: not undone")
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
    // a target with the same task id and another entry (same state): never dropped: both files stay as they are, and so do
    // the task's sessions; the rest of the switch goes on
    let tA = seat(951, "task-a@example.com"), tB = seat(952, "task-b@example.com"), tC = seat(953, "task-c@example.com"), tD = seat(954, "task-d@example.com")
    func taskSwitch(_ id: String, from a: Seat, to b: Seat, srcTask: String, dstTask: String) -> (e: AccountEntry, wd: String, src: String, dst: String) {
        let wd = home + "/wd-\(id)"
        let src = SwitchEngine.scopeDir(wd, SeatID(a)), dst = SwitchEngine.scopeDir(wd, SeatID(b))
        put("\(src)/local_\(uuid(961)).json", #"{"sessionId":"local_free"}"#)
        put("\(src)/local_\(uuid(962)).json", #"{"sessionId":"local_t","scheduledTaskId":"t1"}"#)
        put("\(src)/scheduled-tasks.json", #"{"scheduledTasks":[\#(srcTask)],"recordedSkips":{"t1":{"n":1}}}"#)
        put("\(dst)/scheduled-tasks.json", #"{"scheduledTasks":[\#(dstTask)],"recordedSkips":{"t1":{"n":1}}}"#)
        var e = profile(id, "~/.claude-\(id)", a, standby: [StandbyAccount(email: b.email!, seat: b, id: "kb")])
        e.desktop = .separate; e.desktopDataDir = wd
        return (e, wd, src, dst)
    }
    func bytes(_ path: String) -> Data? { fm.contents(atPath: path) }
    let clash = taskSwitch("tc1", from: tA, to: tB, srcTask: #"{"id":"t1","cron":"0 9 * * *"}"#, dstTask: #"{"id":"t1","cron":"0 10 * * *"}"#)
    check(SwitchEngine.taskProblem(source: clash.src, target: clash.dst) == "the new account has a task with the same id and other settings",
          "the same id with another entry: said as other settings")
    guard case .success(let pc) = SwitchEngine.plan(clash.e, standby: clash.e.standby[0], dataDir: clash.wd, owned: []) else { check(false, "plan clash"); exit(1) }
    check(pc.tasks == 0 && pc.held == ["local_\(uuid(962)).json"] && pc.taskHeld == pc.held && pc.move == ["local_\(uuid(961)).json"] && pc.taskStay?.contains("other settings") == true,
          "the plan: no task moves, the task's session is held, the free one moves, the reason is kept")
    check(SwitchRunner.stayWords(pc)?.contains("scheduled tasks stay") == true && SwitchRunner.stayWords(pc)?.contains("Claude Code is running") == false,
          "the user is told why the tasks stay (not that Claude Code runs the session)")
    let srcBefore = bytes(clash.src + "/scheduled-tasks.json"), dstBefore = bytes(clash.dst + "/scheduled-tasks.json")
    let rc = try! SwitchEngine.run(pc, windowClosed: { true }, backups: URL(fileURLWithPath: home + "/bk-tc1"))
    check(bytes(clash.src + "/scheduled-tasks.json") == srcBefore && bytes(clash.dst + "/scheduled-tasks.json") == dstBefore && srcBefore != nil && dstBefore != nil,
          "the blocked switch leaves both scheduled-tasks.json byte for byte")
    check(rc.tasksMoved == nil && !rc.steps.contains { $0.kind == .tasks }, "…and wrote no task step")
    check(fm.fileExists(atPath: "\(clash.src)/local_\(uuid(962)).json") && !fm.fileExists(atPath: "\(clash.dst)/local_\(uuid(962)).json")
          && fm.fileExists(atPath: "\(clash.dst)/local_\(uuid(961)).json"), "the task's session stays where it is, the free one moved")
    SwitchEngine.markLinked(rc.id)
    // the same entry and state: the task moves, the target keeps its one copy
    let same = taskSwitch("tc2", from: tC, to: tD, srcTask: #"{"id":"t1","cron":"0 9 * * *"}"#, dstTask: #"{"id":"t1","cron":"0 9 * * *"}"#)
    check(SwitchEngine.taskProblem(source: same.src, target: same.dst) == nil, "the same id, the same entry and state: no blocker")
    guard case .success(let ps) = SwitchEngine.plan(same.e, standby: same.e.standby[0], dataDir: same.wd, owned: []) else { check(false, "plan same"); exit(1) }
    check(ps.tasks == 1 && ps.taskStay == nil && ps.held.isEmpty && ps.move.count == 2, "the plan: the task and both sessions go")
    let rs = try! SwitchEngine.run(ps, windowClosed: { true }, backups: URL(fileURLWithPath: home + "/bk-tc2"))
    let sd = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: same.dst + "/scheduled-tasks.json")))) as? [String: Any]
    let ss = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: same.src + "/scheduled-tasks.json")))) as? [String: Any]
    check((sd?["scheduledTasks"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["t1"] && (ss?["scheduledTasks"] as? [Any])?.isEmpty == true,
          "the identical task: the source emptied, the target has one copy")
    SwitchEngine.markLinked(rs.id)
    // blocked runs: both files byte for byte, every task's session held, nothing of the tasks written
    func blocked(_ c: (e: AccountEntry, wd: String, src: String, dst: String), _ tag: String, held: [String], problem: String) {
        check(SwitchEngine.taskProblem(source: c.src, target: c.dst) == problem, "\(tag): said as \"\(problem)\"")
        guard case .success(let pb) = SwitchEngine.plan(c.e, standby: c.e.standby[0], dataDir: c.wd, owned: []) else { check(false, "plan \(tag)"); exit(1) }
        check(pb.tasks == 0 && pb.held.sorted() == held.sorted() && pb.move == ["local_\(uuid(961)).json"], "\(tag): no task moves, all their sessions are held, the free one moves")
        let before = (bytes(c.src + "/scheduled-tasks.json"), bytes(c.dst + "/scheduled-tasks.json"))
        let rb = try! SwitchEngine.run(pb, windowClosed: { true }, backups: URL(fileURLWithPath: home + "/bk-\(tag)"))
        check(before.0 != nil && before.1 != nil && bytes(c.src + "/scheduled-tasks.json") == before.0 && bytes(c.dst + "/scheduled-tasks.json") == before.1
              && rb.tasksMoved == nil && !rb.steps.contains { $0.kind == .tasks }, "\(tag): both scheduled-tasks.json byte for byte, no task step")
        SwitchEngine.markLinked(rb.id)
    }
    // the target's list has an element that isn't a task: no clash can be seen, so the tasks stay (its own are never overwritten)
    let odd = taskSwitch("tc3", from: tA, to: tB, srcTask: #"{"id":"t1","cron":"0 9 * * *"}"#, dstTask: #"{"id":"t1","cron":"0 10 * * *"},null"#)
    blocked(odd, "tc3", held: ["local_\(uuid(962)).json"], problem: "the new account's scheduled-tasks.json isn't a task list")
    // several tasks, one of them clashes: none moves, all their sessions are held
    let many = taskSwitch("tc4", from: tA, to: tB, srcTask: #"{"id":"t1","cron":"a"},{"id":"t2","cron":"b"},{"id":"t3","cron":"c"}"#, dstTask: #"{"id":"t2","cron":"b"},{"id":"t3","cron":"other"}"#)
    put("\(many.src)/local_\(uuid(963)).json", #"{"sessionId":"local_t2","scheduledTaskId":"t2"}"#)
    blocked(many, "tc4", held: ["local_\(uuid(962)).json", "local_\(uuid(963)).json"], problem: "the new account has a task with the same id and other settings")
    // another entry and other state: blocked too
    let both = taskSwitch("tc5", from: tA, to: tB, srcTask: #"{"id":"t1","cron":"0 9 * * *"}"#, dstTask: #"{"id":"t1","cron":"0 10 * * *"}"#)
    put("\(both.dst)/scheduled-tasks.json", #"{"scheduledTasks":[{"id":"t1","cron":"0 10 * * *"}],"recordedSkips":{"t1":{"n":9}}}"#)
    blocked(both, "tc5", held: ["local_\(uuid(962)).json"], problem: "the new account has a task with the same id and other settings")
    // what the user reads: the old account by name, and the way out
    let words = SwitchRunner.stayWords(pc) ?? ""
    check(words.contains("stay with task-a") && words.contains("Remove one of the two, then switch again."), "the words name the old account and say what to do: \(words)")
    // a source with no task says nothing about tasks, whatever the target's file is
    let none = taskSwitch("tc6", from: tA, to: tB, srcTask: "", dstTask: "")
    put("\(none.src)/scheduled-tasks.json", #"{"scheduledTasks":[]}"#)
    put("\(none.dst)/scheduled-tasks.json", "{ not json")
    guard case .success(let pn) = SwitchEngine.plan(none.e, standby: none.e.standby[0], dataDir: none.wd, owned: []) else { check(false, "plan none"); exit(1) }
    check(pn.taskStay == nil && SwitchRunner.stayWords(pn) == nil && pn.tasks == 0, "no task on the old account: no word about tasks")
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
    check(Flows.blocker(profile: "main", for: .restoring) == nil, "…and no longer stops a restore")
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
    check(hugeSeat == nil && Account.recordTooLarge(configDir: "~/.claude-huge12") && Date().timeIntervalSince(t) < 1, "a .claude.json over the cap (64 MB) isn't read (at once)")
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
    try! SwitchEngine.store.save(r)
    let crafted = try! SwitchEngine.undo(r.id, windowClosed: { true })
    check(fm.fileExists(atPath: victim) && crafted.problems.filter { $0.contains("outside this switch's folders") }.count == 2,
          "Undo: a crafted path outside the scope (or climbing out of it) is skipped and named: \(crafted.problems)")
    check(crafted.undone == nil && crafted.partlyUndone != nil && crafted.left?.count == 2 && SwitchEngine.unfinished(profile: "r3").contains { $0.id == r.id },
          "…so it is only partly undone, names what was left, and stays open for another Undo")
    try? fm.removeItem(at: SwitchEngine.root.appendingPathComponent(r.id))      // out of the way of the cases below

    // why a stopped switch may stay open beside a later restore or import: its Undo takes back only what is still exactly as
    // the switch wrote it. A file a restore or import changed (or wrote over) since is left byte for byte, and said.
    fixture()
    guard case .success(let pw) = SwitchEngine.plan(e, standby: e.standby[0], dataDir: wd, owned: []) else { check(false, "plan r3w"); exit(1) }
    let rw = try! SwitchEngine.run(pw, windowClosed: { true }, backups: place)       // moved, never linked: stopped half way, open
    check(SwitchEngine.unfinished(profile: "r3").map(\.id) == [rw.id], "the switch is open (stopped before the sign-in)")
    guard let placed = rw.steps.first(where: { $0.kind == .entry }), let parkedOriginal = placed.parked else { check(false, "an entry step"); exit(1) }
    let changedBytes = Data(#"{"sessionId":"local_1","changedByALaterRestore":true}"#.utf8)
    try! changedBytes.write(to: URL(fileURLWithPath: placed.path))
    let placedName = (placed.path as NSString).lastPathComponent
    let undoneW = try! SwitchEngine.undo(rw.id, windowClosed: { true })
    check(fm.contents(atPath: placed.path) == changedBytes, "stopped switch's Undo: a file changed since it wrote it stays byte for byte as it is now")
    check(undoneW.problems.contains("\(placedName) changed since; left as it is") && undoneW.left?.contains(placedName) == true && undoneW.undone == nil && undoneW.partlyUndone != nil,
          "…and Undo says it left it, and stays open: \(undoneW.problems)")
    check(fm.fileExists(atPath: parkedOriginal), "…its parked original is not moved over it")
    try? fm.removeItem(at: SwitchEngine.root.appendingPathComponent(rw.id))

    // SHOULD 1: the window opening during Undo stops it before the next step
    fixture()
    guard case .success(let p2) = SwitchEngine.plan(e, standby: e.standby[0], dataDir: wd, owned: []) else { check(false, "plan r3b"); exit(1) }
    let r2 = try! SwitchEngine.run(p2, windowClosed: { true }, backups: place)
    var asked = 0
    let opened = (try? SwitchEngine.undo(r2.id, windowClosed: { asked += 1; return asked <= 2 })) == nil
    check(opened && SwitchEngine.store.load(r2.id)?.undone == nil && SwitchEngine.store.load(r2.id)?.problems.contains { $0.contains("opened during Undo") } == true,
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
          && SwitchEngine.store.load(r3.id)?.linked != nil && SwitchEngine.unfinished(profile: "r3").isEmpty,
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
    // Leave it as it is: closed as it stands, nothing moved, and no longer holding up the next switch
    let open12 = SwitchEngine.unfinished(profile: "r3")
    let before12 = tree(wd)
    let words12 = (try? SwitchEngine.leaveAsIs(open12.first?.id ?? "")) ?? ""
    check(open12.count == 1 && SwitchEngine.unfinished(profile: "r3").isEmpty && tree(wd) == before12
          && words12.hasPrefix("Left as it is: 2 Code-tab sessions stay under the account the switch went to"),
          "Leave it as it is: the receipt closed, nothing moved, what stays where said: \(words12)")

    // SHOULD 7: the program is the executable's last path component, the path whole even with spaces
    check(Processes.isClaude(home + "/Library/Application Support/Claude/claude-code/2.1.318/claude --resume \(uuid(1220))")
          && Processes.isClaude("claude") && Processes.isClaude("/opt/homebrew/bin/claude -p hi")
          && !Processes.isClaude("/bin/zsh -c claude \(uuid(1220))") && !Processes.isClaude("/usr/bin/vim claude"),
          "claude by its executable's last path component, spaces in the path included; not as another program's argument")
    let command = home + "/Library/Application Support/Claude/claude-code/2.1.318/claude --resume \(uuid(1221))"
    check(Processes.owned(commands: [command], codeDir: "~/.claude-r3", alive: { _ in false }) == [uuid(1221)], "the Claude app's own claude, under a path with a space: its session is owned")
    try? fm.removeItem(atPath: expand("~/.claude-r3"))
}

// ============ 13. B2: one standby entry per account (the shape seen after B's install) ============
do {
    // three accounts across nine (account, organisation) folders of Main's window: P under o1..o4, M under o5, o1, o2,
    // S under o1, o4; S is Work's account in use (S / o3)
    func id(_ n: Int) -> String { uuid(1300 + n) }
    let P = id(1), M = id(2), S = id(3)
    let o1 = id(11), o2 = id(12), o3 = id(13), o4 = id(14), o5 = id(15)
    let wdB = expand("~/Library/Application Support/Claude-b2")
    try? fm.removeItem(atPath: wdB)
    let pairs: [(String, String, Double)] = [(P, o1, -40), (P, o2, -10), (P, o3, -30), (P, o4, -50), (M, o5, -5), (M, o1, -60),
                                             (M, o2, -70), (S, o1, -20), (S, o4, -80)]
    for (a, o, ago) in pairs {
        let f = "\(wdB)/claude-code-sessions/\(a)/\(o)/local_\(id(Int(-ago))).json"
        put(f, "{}")
        try? fm.setAttributes([.modificationDate: t0.addingTimeInterval(ago * 3600)], ofItemAtPath: f)
    }
    // P's own record (a backup of Main's folder) names P under o4: that is its organisation, whatever folder is newest
    put(expand("~/.claude-b2main/backups/.claude.json.backup.1"),
        #"{"oauthAccount":{"accountUuid":"\#(P)","organizationUuid":"\#(o4)","emailAddress":"p@example.com"}}"#)
    var mainB = profile("b2main", "~/.claude-b2main", u1); mainB.desktop = .separate; mainB.desktopDataDir = wdB
    let workB = profile("b2work", "~/.claude-b2work", Seat(account: S, organization: o3, email: "s@example.com"))
    let found = AccountList.find([mainB, workB])
    let added = AccountList.adding(found, to: [mainB, workB], now: t0)
    let sb = added[0].standby
    check(sb.count == 2 && Set(sb.compactMap { $0.seat?.account }) == [P, M], "nine pairs of three accounts: two standby entries on Main (P and M): \(sb.map { $0.seat?.account ?? "-" })")
    check(sb.first { $0.seat?.account == P }?.seat?.organization == o4, "P with its own record's organisation (o4), not its newest folder's")
    check(sb.first { $0.seat?.account == M }?.seat?.organization == o5, "M (no record) with its newest-used folder's organisation (o5)")
    check(!sb.contains { $0.seat?.account == S } && added[1].standby.isEmpty, "S, Work's account in use, nowhere on Main, whatever the organisation")
    check(AccountList.adding(found, to: added, now: t0) == added, "found again: nothing added twice")
    let m13 = SettingsModel(); m13.accounts = added
    let page13 = SwitchPage(entry: added[0], standby: sb[0], model: m13, runner: m13.runner(of: "b2main"))
    check(!page13.pickList.contains { $0.seat?.account == S } && !SwitchMenu.lines(added[0]).contains { $0.key.contains(S) },
          "S is never a switch target on Main (the Switch page, Switch account ›)")

    // the load-time tidy: Main's file with the nine entries (and a leftover folder) loads as two, saved once, said once
    var nine = mainB
    nine.standby = pairs.map { (a, o, ago) in
        StandbyAccount(email: "", seat: Seat(account: a, organization: o, email: nil), id: "s\(Int(-ago))", lastInUse: t0.addingTimeInterval(ago * 3600))
    }
    nine.leftoverFolders = ["~/.claude-old-b2"]
    let before13 = try! JSONEncoder().encode(ConfigFile(accounts: [nine, workB]))
    try! before13.write(to: Store.configURL)
    var writes = 0
    Store.announce = { writes += 1 }
    Store.version = "b2-test"
    let pre = Store.folder.appendingPathComponent("accounts.json.pre-b2-test").path
    try? fm.removeItem(atPath: pre)
    let loaded = Store.loadChecked() ?? []
    let mainL = loaded.first { $0.id == "b2main" }
    check(mainL?.standby.count == 2 && Set(mainL?.standby.compactMap { $0.seat?.account } ?? []) == [P, M]
          && mainL?.standby.first { $0.seat?.account == P }?.seat?.organization == o4,
          "a file with the nine entries loads as two, P with its record's organisation: \(mainL?.standby.map { $0.seat?.organization ?? "-" } ?? [])")
    check(mainL?.leftoverFolders == ["~/.claude-old-b2"] && mainL?.accountNote?.kind == .tidied && writes == 1,
          "leftovers untouched, saved once, the note said: \(mainL?.accountNote?.words ?? "-") (\(writes) writes)")
    check(mainL?.accountNote?.words == "Standby list tidied: one entry per account.", "the note in words")
    _ = Store.loadChecked()
    check(writes == 1, "a second load writes nothing")
    let preData = fm.contents(atPath: pre)
    let preMode = ((try? fm.attributesOfItem(atPath: pre))?[.posixPermissions] as? NSNumber)?.intValue
    check(preData == before13 && preMode == 0o600, "the tidy kept the file as it was in accounts.json.pre-<version>, owner only")
    Store.announce = {}
    Store.version = "dev"
    try? fm.removeItem(atPath: pre)
}

// ============ 14. a flow sees the others' unfinished work on the same profile (Flows.blocker) ============
do {
    let wd14 = expand("~/Library/Application Support/Claude-xf")
    let src14 = SwitchEngine.scopeDir(wd14, SeatID(u1))
    let k14 = StandbyAccount(email: u2.email!, seat: u2, id: "k2")
    try? fm.createDirectory(atPath: expand("~/.claude-xf/projects"), withIntermediateDirectories: true)
    sign("~/.claude-xf", u1)
    var e = profile("xf", "~/.claude-xf", u1, standby: [k14])
    e.desktop = .separate; e.desktopDataDir = wd14
    try! Store.save([e])
    let place14 = URL(fileURLWithPath: home + "/bk14")
    /// Nothing unfinished anywhere, a window folder with one session on the account in use.
    func fresh14() {
        for dir in [SwitchEngine.root, SessionsRestore.root, DefaultProfile.folder] { try? fm.removeItem(at: dir) }
        DefaultProfile.forgetCache()
        try? fm.removeItem(atPath: wd14)
        put("\(src14)/local_\(uuid(1401)).json", #"{"sessionId":"local_1"}"#)
    }
    /// A restore (or an import) that wrote one file and stopped: receipt and journal, as the engine leaves them.
    @discardableResult func stoppedRestore(_ profile: String, imported: Bool = false, when: Date = t0, finished: Date? = nil, undone: Date? = nil) -> SessionsRestore.Receipt {
        var r = SessionsRestore.Receipt(id: SessionsRestore.receiptID(when, profile), profile: profile, dataDir: wd14, codeDir: expand("~/.claude-xf"),
                                        backup: "b14", backupPlace: place14.path, started: when)
        if imported { r.importedFrom = "export.zip" }
        r.finished = finished; r.undone = undone
        try! SessionsRestore.store.save(r)
        put(SessionsRestore.root.appendingPathComponent("\(r.id)/journal.jsonl").path, #"{"op":"intent","kind":"file","path":"/x14","bytes":1}"# + "\n")
        return SessionsRestore.load(r.id)!
    }
    func move14(_ profile: String, old: String? = nil, finished: Date? = nil, undone: Date? = nil, receipt: String? = nil) {
        DefaultProfile.save(DefaultProfile.Record(id: "mv14", kind: .otherFolder, profile: profile, oldProfile: old, created: true, backup: "b14",
                                                  backupPlace: place14.path, started: t0, receipt: receipt, finished: finished, undone: undone))
    }
    /// The Switch page's runner starts a switch to ultra-2: the words it stopped with, nil when it went on (and then it is let go).
    func startedWith() -> String? {
        let m = SettingsModel(); m.accounts = [e]
        let r = m.runner(of: "xf")
        r.start(e.standby[0])
        if case .failed(let why) = r.phase { return why }
        let end = Date().addingTimeInterval(8)
        func busy() -> Bool { switch r.phase { case .closing, .moving: return true; default: return false } }
        while busy(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        r.reset()
        return nil
    }

    // a switch that stopped half way never holds a restore, an import or a re-point back (an old one can't be finished or undone)
    fresh14()
    guard case .success(let p) = SwitchEngine.plan(e, standby: e.standby[0], dataDir: wd14, owned: []) else { check(false, "plan xf"); exit(1) }
    let sw = try! SwitchEngine.run(p, windowClosed: { true }, backups: place14)
    check(SwitchEngine.unfinished(profile: "xf").map(\.id) == [sw.id] && Flows.blocker(profile: "xf", for: .restoring) == nil
          && Flows.blocker(profile: "xf", for: .restoring) == nil, "a switch stopped half way: no restore, import or re-point waits for it")
    check(Flows.blocker(profile: "xf", for: .switching) == nil, "…and the switch's own start check leaves its own receipt to the switch page's words")

    // a restore that stopped half way: a restore says what it always said; a switch is now refused, saying which and where
    fresh14()
    let rs = stoppedRestore("xf")
    let own = Flows.blocker(profile: "xf", for: .restoring)
    check(own == "A restore of this profile stopped half way on \(SessionsBackup.dateWords(t0)). Finish it or undo it first.", "restore on restore: the words are as they were: \(own ?? "-")")
    check(Flows.blocker(profile: "xf", except: rs.id, for: .restoring) == nil, "…and finishing or undoing it is the restore itself: allowed")
    check(Flows.blocker(profile: "other", for: .restoring) == nil && Flows.blocker(profile: "other", for: .switching) == nil, "another profile's unfinished restore blocks nothing here")
    var why = startedWith()
    check(why?.contains("A restore of this profile stopped half way on") == true && why?.contains("Finish it or undo it first") == true && why?.contains("the profile's tile in Settings opens its page") == true
          && why?.contains("“Restore stopped”") != true,
          "a switch while a restore of the profile stopped half way: refused, which one and where: \(why ?? "it went on")")
    check(SwitchEngine.unfinished(profile: "xf").isEmpty && (try? SwitchEngine.run(p, windowClosed: { true }, backups: place14)) == nil,
          "…also under the engine's lock (the page's check may be old by then), nothing moved")
    check(tree(src14).contains("local_\(uuid(1401)).json"), "…the session is still where it was")
    // an import says "import"
    fresh14(); stoppedRestore("xf", imported: true)
    why = startedWith()
    check(why?.hasPrefix("An import of this profile stopped half way on") == true, "a stopped import is named an import: \(why ?? "it went on")")
    // finished or undone: no longer in the way
    fresh14(); stoppedRestore("xf", finished: t0)
    check(startedWith()?.contains("stopped half way") != true, "a finished restore doesn't hold a switch back")

    // a move to the default profile that stopped: on either profile it names, a switch is refused; it holds no restore back by itself
    fresh14(); move14("xf")
    why = startedWith()
    check(why?.contains("default profile") == true && why?.contains("stopped half way") == true && why?.contains("in Settings ▸ General") == true
          && why?.contains("“The move stopped”") == true && why?.contains("default profile's page") != true,
          "a switch while this profile's move to the default profile is open: refused, said where: \(why ?? "it went on")")
    check(Flows.blocker(profile: "xf", for: .restoring) == nil, "…the move's own restore is not held back by its record")
    fresh14(); move14("newdefault", old: "xf")
    check(startedWith()?.contains("default profile") == true, "the profile the move came from is refused too")
    fresh14(); move14("xf", finished: t0)
    check(startedWith()?.contains("stopped half way") != true, "a finished move doesn't hold a switch back")
    fresh14(); move14("elsewhere", old: "else2")
    check(startedWith()?.contains("stopped half way") != true, "a move of other profiles doesn't")

    // undone: no longer in the way, a restore or a move
    fresh14(); stoppedRestore("xf", undone: t0)
    check(startedWith()?.contains("stopped half way") != true, "an undone restore doesn't hold a switch back")
    fresh14(); move14("xf", undone: t0)
    check(startedWith()?.contains("stopped half way") != true, "an undone move doesn't")
    // a move whose restore was finished from the Restore page since: the record catches up and holds nothing
    fresh14()
    let rf = stoppedRestore("xf", finished: t0)
    move14("xf", receipt: rf.id)
    check(startedWith()?.contains("stopped half way") != true && DefaultProfile.all().first { $0.id == "mv14" }?.finished != nil,
          "a move whose restore was finished elsewhere: the record catches up, nothing held back")

    // one still running holds cl_audit's lock: said to be under way, not stopped
    fresh14(); stoppedRestore("xf")
    let running = try! Flows.takeLock()
    why = startedWith()
    running.release()
    check(why == "Another restore, import or move is under way.", "a restore still running: under way, not stopped half way: \(why ?? "it went on")")

    // the switch's own unfinished receipt: still the switch page's own words, also beside a stopped restore
    fresh14()
    let sw2 = try! SwitchEngine.run(p, windowClosed: { true }, backups: place14)
    check(startedWith()?.contains("sign in as ultra-2 to finish it") == true && SwitchEngine.unfinished(profile: "xf").map(\.id) == [sw2.id], "an earlier switch of the profile: its own words, as before")
    stoppedRestore("xf")
    why = startedWith()
    check(why?.contains("sign in as ultra-2 to finish it") == true && why?.contains("restore") != true, "a stopped switch and a stopped restore: the switch's own words win: \(why ?? "-")")
    fresh14()
}

// ============ 15. receipts 26.11.29 wrote load through SafeFiles' ReceiptStore and save back byte for byte ============
// Checks/accounts/receipts-26.11.29: what 20489f5's own writers left in its check runs (a switch, an import's restore with
// its journal, a re-point, a move import; only the throwaway paths made sample ones) and what its save functions wrote for
// a switch with every step kind, a side files receipt and a default-profile move record. Each is read through its store and
// saved again: the same bytes (so an older cl_audit reads what this one writes), at the same place and mode.
do {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("receipts-26.11.29")
    let kinds = ["switches", "restores", "repoints", "sides", "moves", "default-moves"]
    for k in kinds {
        let dst = Store.folder.appendingPathComponent(k)
        try? fm.removeItem(at: dst)
        try! fm.copyItem(at: fixtures.appendingPathComponent(k), to: dst)
        // every copy 0644 to begin with, so a mode after the save is the store's own doing
        for rel in (fm.enumerator(atPath: dst.path)?.allObjects as? [String]) ?? [] {
            var isDir: ObjCBool = false
            let p = dst.appendingPathComponent(rel).path
            if fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue { chmod(p, 0o644) }
        }
    }
    DefaultProfile.forgetCache()
    func bytes(_ u: URL) -> Data? { fm.contents(atPath: u.path) }
    func mode(_ u: URL) -> Int { ((try? fm.attributesOfItem(atPath: u.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
    /// Every receipt of a store: read, encoded and saved again, the same bytes as the file 26.11.29 wrote.
    func roundTrip<R: StoredReceipt>(_ store: ReceiptStore<R>, _ what: String, count: Int, mode want: Int? = nil) {
        let ids = store.ids()
        check(ids.count == count, "\(what): \(count) old receipts found (\(ids.count))")
        for id in ids {
            let u = store.url(id), old = bytes(u)
            guard let r = store.load(id) else { check(false, "\(what) \(id): reads"); continue }
            check(r.id == id && (try? store.encoded(r)) == old, "\(what) \(id): encoded as 26.11.29 encoded it")
            check(mode(u) == 0o644, "\(what) \(id): 0644 before the save")
            try? store.save(r)
            check(bytes(u) == old && old != nil, "\(what) \(id): saved again byte for byte")
            if let want { check(mode(u) == want, "\(what) \(id): mode \(String(want, radix: 8)) (\(String(mode(u), radix: 8)))") }
        }
    }
    roundTrip(SwitchEngine.store, "switch", count: 2)
    roundTrip(SessionsRestore.store, "restore", count: 1)
    roundTrip(SessionsRepoint.store, "re-point", count: 1)
    roundTrip(SideFiles.store, "side files", count: 1, mode: 0o600)
    roundTrip(SessionsMove.store, "move import", count: 1, mode: 0o600)
    roundTrip(DefaultProfile.store, "default-profile move", count: 1)

    // the flows read them as before
    let sw = SwitchEngine.receipts(profile: "main")
    check(sw.count == 1 && sw[0].steps.map(\.kind) == [.entry, .tasks, .pointer] && sw[0].steps[2].ino == 987_654 && sw[0].tasksMoved == 2
          && sw[0].unfinished && SwitchEngine.receipts().count == 2 && SwitchEngine.receipts(profile: "ff").first?.left?.count == 1,
          "switch: old receipts read by the flow (every step kind, a partly undone one)")
    let rid = "20261114-170329-3175-studio"
    let rs = SessionsRestore.load(rid)
    check(rs?.steps.count == 22 && rs?.steps.allSatisfy { $0.done && $0.settled } == true && rs?.importedFrom == "resume move.dmg"
          && rs?.entriesAdded == 3 && SessionsRestore.headers().map(\.id) == [rid] && SessionsRestore.unfinished().isEmpty,
          "restore: the old journal folds into its 22 steps, done and settled")
    check(SessionsRepoint.store.list().first?.sessions.isEmpty == false && SessionsRepoint.store.list().first?.steps.isEmpty == false, "re-point: read with its sessions and steps")
    check(SideFiles.waiting(profile: "main").first?.trust.first?.allowedTools == ["Read"], "side files: the waiting session read by the flow")
    check(DefaultProfile.all().first?.oldHandled == "standby" && DefaultProfile.unfinished(involving: "home") == nil, "default-profile move: read by the flow")

    // the journal: lines Journal appends are read by the restore's fold (as 26.11.29 reads them), after the old ones
    struct Line: Codable { var op: String; var kind: String?; var path: String; var sha: String?; var bytes: Int64? }
    let first = rs?.steps.first?.path ?? ""
    if let j = SessionsRestore.store.journal(rid, of: Line.self) {
        j.add(Line(op: "intent", kind: "file", path: first + "-new", sha: "ab", bytes: 2), sync: true)
        j.add(Line(op: "done", kind: nil, path: first + "-new", sha: nil, bytes: nil), sync: false)
    }
    let after = SessionsRestore.load(rid)
    check(after?.steps.count == 23 && after?.steps.last?.path == first + "-new" && after?.steps.last?.done == true && after?.steps.last?.kind == .file,
          "journal: new lines appended after the old ones, folded the same way")
    let lines = (try? String(contentsOf: SessionsRestore.store.folder(rid).appendingPathComponent("journal.jsonl"), encoding: .utf8))?.split(separator: "\n") ?? []
    check(lines.count == 68 && mode(SessionsRestore.store.folder(rid).appendingPathComponent("journal.jsonl")) != -1, "journal: one line per event (\(lines.count))")
    for k in kinds { try? fm.removeItem(at: Store.folder.appendingPathComponent(k)) }
    DefaultProfile.forgetCache()
}

// ============ 16. SafeFiles: create-only writes and the one lock ============
do {
    let dir = home + "/safefiles"
    try? fm.removeItem(atPath: dir)
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let target = dir + "/a.json"
    check(CreateOnly.write(Data("1".utf8), as: target, temp: dir + "/.a.tmp", sync: true) == .created && fm.contents(atPath: target) == Data("1".utf8),
          "create-only: a new file is made")
    check(CreateOnly.write(Data("2".utf8), as: target, temp: dir + "/.a.tmp", sync: false) == .exists && fm.contents(atPath: target) == Data("1".utf8),
          "create-only: never over a file that is there")
    check(((try? fm.contentsOfDirectory(atPath: dir)) ?? []) == ["a.json"], "create-only: no temp file left")
    symlink(dir + "/elsewhere", dir + "/link.json")
    check(CreateOnly.write(Data("3".utf8), as: dir + "/link.json", temp: dir + "/.l.tmp", sync: false) == .exists && !fm.fileExists(atPath: dir + "/elsewhere"),
          "create-only: never through a link")
    check(CreateOnly.open(dir + "/link.json") < 0 && CreateOnly.open(target) < 0, "create-only open: a link or a name that is there is refused")
    let mine = CreateOnly.open(dir + "/b", mode: 0o600)
    var st = stat(); fstat(mine, &st); close(mine)
    check(mine >= 0 && (st.st_mode & 0o777) == 0o600, "create-only open: owner only")
    check(CreateOnly.rename(dir + "/b", to: target) == false && CreateOnly.rename(dir + "/b", to: dir + "/c") && fm.fileExists(atPath: dir + "/c"),
          "rename: only where nothing is")
    let pfd = open(dir, O_RDONLY | O_DIRECTORY)
    fm.createFile(atPath: dir + "/.w-1.tmp", contents: Data())
    CreateOnly.sweep(pfd, names: (try? fm.contentsOfDirectory(atPath: dir)) ?? [], prefix: ".w-")
    close(pfd)
    check(!fm.fileExists(atPath: dir + "/.w-1.tmp") && fm.fileExists(atPath: target), "sweep: only the writer's own temp names")

    // the lock: one holder in this process, a second take refused until it is released; the other tool's lock too
    let lock = FlowLock(path: dir + "/locks/.lock", other: dir + "/other/lock")
    let held = try? lock.take()
    var second: FlowLock.Busy?
    do { _ = try lock.take() } catch let b as FlowLock.Busy { second = b } catch {}
    check(held != nil && second == .held, "lock: a second take is refused while one holds it")
    let otherFD = open(dir + "/other/lock", O_RDWR)
    check(flock(otherFD, LOCK_EX | LOCK_NB) != 0, "lock: the other tool's lock file is held (flock)")
    held?.release()
    check(flock(otherFD, LOCK_EX | LOCK_NB) == 0, "lock: released with it")
    var third: FlowLock.Busy?
    do { _ = try lock.take() } catch let b as FlowLock.Busy { third = b } catch {}
    check(third == .otherHeld, "lock: the other tool holding its lock refuses the take (\(String(describing: third)))")
    flock(otherFD, LOCK_UN); close(otherFD)
    if let again = try? lock.take() { again.release(); check(true, "lock: free again") } else { check(false, "lock: free again") }
    // cl_audit's lock keeps its paths: switches/.lock and claude-transplant's lock
    check(Flows.lock.path == SwitchEngine.root.appendingPathComponent(".lock").path
          && Flows.lock.other == expand("~/Library/Application Support/claude-transplant/lock"), "cl_audit's lock: the same two files as before")
    // another process (claude-transplant takes its lock with /usr/bin/lockf, a flock) can't take the other lock while it is held
    if let held2 = try? lock.take() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        p.arguments = ["-t", "0", dir + "/other/lock", "/usr/bin/true"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        held2.release()
        check(p.terminationStatus != 0, "lock: another process's lockf on the other lock is refused while it is held (\(p.terminationStatus))")
    } else { check(false, "lock: taken for the second-process check") }
    // a lock file that can't be opened (a folder stands there): .unopenable, and the other tool's: .otherUnopenable
    try? fm.createDirectory(atPath: dir + "/bad/.lock", withIntermediateDirectories: true)
    var bad: FlowLock.Busy?
    do { try FlowLock(path: dir + "/bad/.lock").take().release() } catch let b as FlowLock.Busy { bad = b } catch {}
    try? fm.createDirectory(atPath: dir + "/bad/other", withIntermediateDirectories: true)
    var badOther: FlowLock.Busy?
    do { try FlowLock(path: dir + "/bad/own", other: dir + "/bad/other").take().release() } catch let b as FlowLock.Busy { badOther = b } catch {}
    check(bad == .unopenable && badOther == .otherUnopenable, "lock: a lock file that can't be opened is said so (\(String(describing: bad)), \(String(describing: badOther)))")
    if let again = try? FlowLock(path: dir + "/bad/own").take() { again.release(); check(true, "lock: its own lock let go after the other one failed") }
    else { check(false, "lock: its own lock let go after the other one failed") }

    // the journal: a last line cut short (a crash mid-write) or broken is skipped; the lines before it are read
    struct Ev: Codable, Equatable { var op: String; var path: String }
    let jurl = URL(fileURLWithPath: dir + "/journal.jsonl")
    if let j = Journal<Ev>(jurl) { j.add(Ev(op: "intent", path: "/a"), sync: true); j.add(Ev(op: "done", path: "/a"), sync: false) }
    if let h = FileHandle(forWritingAtPath: jurl.path) { h.seekToEndOfFile(); h.write(Data(#"{"op":"intent","pa"#.utf8)); h.closeFile() }
    check(Journal<Ev>.events(jurl) == [Ev(op: "intent", path: "/a"), Ev(op: "done", path: "/a")], "journal: a truncated last line is skipped")
    if let h = FileHandle(forWritingAtPath: jurl.path) { h.seekToEndOfFile(); h.write(Data("\n\u{0}garbage\n".utf8)); h.closeFile() }
    check(Journal<Ev>.events(jurl)?.count == 2, "journal: a broken line is skipped")
    check(Journal<Ev>.events(URL(fileURLWithPath: dir + "/none.jsonl")) == nil, "journal: none there: nil")
    symlink(jurl.path, dir + "/jlink.jsonl")
    check(Journal<Ev>(URL(fileURLWithPath: dir + "/jlink.jsonl")) == nil, "journal: never opened through a link")

    // bounded reads: a link or a FIFO is refused at once, by readPlain and by a store's capped load
    struct T: StoredReceipt { var id: String; var started: Date }
    let rs = ReceiptStore<T>(root: URL(fileURLWithPath: dir + "/r"), layout: .folders(file: "receipt.json"), readCap: 1 << 20,
                             validID: SessionsRestore.validReceiptID, idMustMatch: true)
    let good = "20270101-000000-aaaa-x", linked = "20270101-000000-bbbb-x", fifo = "20270101-000000-cccc-x"
    try? rs.save(T(id: good, started: t0))
    try? fm.createDirectory(at: rs.folder(linked), withIntermediateDirectories: true)
    try? fm.createDirectory(at: rs.folder(fifo), withIntermediateDirectories: true)
    symlink(rs.url(good).path, rs.url(linked).path)
    mkfifo(rs.url(fifo).path, 0o600)
    let t1 = Date()
    check(rs.load(good)?.id == good && rs.load(linked) == nil && rs.load(fifo) == nil, "store: a capped load refuses a link and a FIFO")
    check(SafeFiles.readPlain(rs.url(good).path, max: 1 << 20) != nil && SafeFiles.readPlain(rs.url(linked).path, max: 1 << 20) == nil
          && SafeFiles.readPlain(rs.url(fifo).path, max: 1 << 20) == nil && SafeFiles.readPlain(rs.url(good).path, max: 2) == nil
          && Date().timeIntervalSince(t1) < 2, "readPlain: a link, a FIFO and a file over the cap are refused, at once")
    // a "../" id is no receipt id: never read, whatever is there
    try? fm.createDirectory(atPath: dir + "/elsewhere/\(good)", withIntermediateDirectories: true)
    try? fm.copyItem(atPath: rs.url(good).path, toPath: dir + "/elsewhere/\(good)/receipt.json")
    check(rs.load("../elsewhere/\(good)") == nil && SessionsRestore.store.load("../restores/x") == nil && SessionsRepoint.store.load("../x") == nil
          && SideFiles.store.load("..") == nil && SessionsMove.store.load("../moves") == nil, "store: a \"../\" id is refused")
    try? fm.removeItem(atPath: dir)
}

// ============ 17. TaskRegistry: the task file's one owner (the twin rule, the same bytes, compare-and-swap) ============
do {
    let dir = home + "/tasks-registry"
    try? fm.removeItem(atPath: dir)
    let src = dir + "/src", dst = dir + "/dst"
    try? fm.createDirectory(atPath: src, withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: dst, withIntermediateDirectories: true)
    let a: [String: Any] = ["id": "nightly-digest", "cronExpression": "0 3 * * *", "displayName": "Nightly / digest", "enabled": true]
    let b: [String: Any] = ["id": "weekly-report", "cronExpression": "0 9 * * 1", "enabled": true]
    let c: [String: Any] = ["id": "kept-here", "cronExpression": "*/10 * * * *", "enabled": false]
    let srcJSON: [String: Any] = ["scheduledTasks": [a, b], "recordedSkips": ["nightly-digest": 2, "other": 1], "runRetries": ["weekly-report": 1]]
    let dstJSON: [String: Any] = ["scheduledTasks": [c, a], "recordedSkips": ["nightly-digest": 2]]
    let srcBytes = try! JSONSerialization.data(withJSONObject: srcJSON), dstBytes = try! JSONSerialization.data(withJSONObject: dstJSON)
    fm.createFile(atPath: TaskRegistry.path(src), contents: srcBytes)
    fm.createFile(atPath: TaskRegistry.path(dst), contents: dstBytes)

    // the twin rule, as the switch said it (SwitchEngine.taskProblem forwards to it)
    check(TaskRegistry.twinProblem(source: src, target: dst) == nil && SwitchEngine.taskProblem(source: src, target: dst) == nil,
          "the same task under the same id, with the same state: no twin problem")
    var other = dstJSON; other["scheduledTasks"] = [c, ["id": "nightly-digest", "cronExpression": "0 4 * * *", "enabled": true]]
    try? fm.createDirectory(atPath: dir + "/twin", withIntermediateDirectories: true)
    fm.createFile(atPath: TaskRegistry.path(dir + "/twin"), contents: try! JSONSerialization.data(withJSONObject: other))
    check(TaskRegistry.twinProblem(source: src, target: dir + "/twin") == "the new account has a task with the same id and other settings",
          "a differing twin is refused")

    // the joined files: the very bytes the switch wrote before TaskRegistry (its algorithm, kept here as it was)
    func before(_ source: [String: Any], _ target: [String: Any]) -> (Data, Data, Int) {
        var source = source, target = target
        let moving = source["scheduledTasks"] as? [[String: Any]] ?? []
        let movingIDs = moving.compactMap { $0["id"] as? String }
        var have = target["scheduledTasks"] as? [[String: Any]] ?? []
        let ids = Set(have.compactMap { $0["id"] as? String })
        have += moving.filter { ($0["id"] as? String).map { !ids.contains($0) } ?? true }
        target["scheduledTasks"] = have
        source["scheduledTasks"] = [[String: Any]]()
        for key in ["recordedSkips", "runRetries"] {
            guard var s = source[key] as? [String: Any] else { continue }
            var t = target[key] as? [String: Any] ?? [:]
            for id in movingIDs { if let v = s.removeValue(forKey: id) { t[id] = v } }
            source[key] = s; target[key] = t
        }
        return (try! JSONSerialization.data(withJSONObject: source, options: [.withoutEscapingSlashes]),
                try! JSONSerialization.data(withJSONObject: target, options: [.withoutEscapingSlashes]), movingIDs.count)
    }
    let old = before(srcJSON, dstJSON)
    let j = TaskRegistry.joined(source: srcJSON, target: dstJSON)
    check((try? TaskRegistry.encode(j.source)) == old.0 && (try? TaskRegistry.encode(j.target)) == old.1 && j.moved.count == old.2,
          "the joined files are byte for byte what the switch wrote before (slashes unescaped, state with its tasks)")
    let none = before(srcJSON, ["scheduledTasks": [[String: Any]]()])
    let jn = TaskRegistry.joined(source: srcJSON, target: ["scheduledTasks": [[String: Any]]()])
    check((try? TaskRegistry.encode(jn.target)) == none.1, "…and into an account with no task file")
    let base = Data(#"{"scheduledTasks":[],"version":2}"#.utf8)
    let pausedOld = try! JSONSerialization.data(withJSONObject: ["scheduledTasks": [a, b].map { t -> [String: Any] in var t = t; t["enabled"] = false; return t },
                                                                 "version": 2], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    check(TaskRegistry.paused(base: base, tasks: [a, b]) == pausedOld && SessionsRestore.pausedTasks(base: base, tasks: [a, b]) == pausedOld,
          "restore's paused file: the same bytes as before")
    check(TaskRegistry.taskList(srcBytes).count == 2 && SessionsRestore.taskList(srcBytes).count == 2 && TaskRegistry.ids(in: dst) == ["kept-here", "nightly-digest"]
          && TaskRegistry.tasks(in: src).count == 2 && SwitchEngine.tasks(in: src).count == 2, "reading: the list, the ids, the tasks")

    // compare-and-swap: written only while the file is exactly as it was read
    let next = try! TaskRegistry.encode(j.target)
    check(TaskRegistry.swap(next, at: TaskRegistry.path(dst), expected: srcBytes) == .changed && fm.contents(atPath: TaskRegistry.path(dst)) == dstBytes,
          "a file that isn't as it was read: .changed, nothing written")
    check(TaskRegistry.swap(next, at: TaskRegistry.path(dst), expected: dstBytes) == .written && fm.contents(atPath: TaskRegistry.path(dst)) == next,
          "as it was read: written")
    let mode = ((try? fm.attributesOfItem(atPath: TaskRegistry.path(dst)))?[.posixPermissions] as? NSNumber)?.intValue
    check(mode == 0o644, "written over: the file's own mode kept (\(String(mode ?? 0, radix: 8)))")
    let tight = dir + "/tight"
    try? fm.createDirectory(atPath: tight, withIntermediateDirectories: true)
    fm.createFile(atPath: TaskRegistry.path(tight), contents: dstBytes, attributes: [.posixPermissions: 0o600])
    let tightOK = TaskRegistry.swap(next, at: TaskRegistry.path(tight), expected: dstBytes) == .written
    let tightMode = ((try? fm.attributesOfItem(atPath: TaskRegistry.path(tight)))?[.posixPermissions] as? NSNumber)?.intValue
    check(tightOK && tightMode == 0o600, "a 0600 task file stays 0600 (\(String(tightMode ?? 0, radix: 8)))")
    // a temp an earlier stop left beside the file is swept
    fm.createFile(atPath: tight + "/" + TaskRegistry.tempPrefix + "stale.tmp", contents: Data("x".utf8))
    fm.createFile(atPath: tight + "/local_keep.json", contents: Data("{}".utf8))
    TaskRegistry.sweep(tight)
    check(!fm.fileExists(atPath: tight + "/" + TaskRegistry.tempPrefix + "stale.tmp") && fm.fileExists(atPath: tight + "/local_keep.json")
          && TaskRegistry.exists(tight), "sweep: a leftover temp goes, nothing else")
    let fresh = dir + "/fresh"
    try? fm.createDirectory(atPath: fresh, withIntermediateDirectories: true)
    check(TaskRegistry.swap(next, at: TaskRegistry.path(fresh), expected: dstBytes) == .changed && !TaskRegistry.exists(fresh),
          "none there, but one was expected: .changed, nothing made")
    check(TaskRegistry.swap(next, at: TaskRegistry.path(fresh), expected: nil) == .written && fm.contents(atPath: TaskRegistry.path(fresh)) == next,
          "none there and none expected: made")
    check(TaskRegistry.swap(next, at: TaskRegistry.path(fresh), expected: nil) == .changed, "made since (one there, none expected): .changed")
    // never through a link, and nothing else than a plain file is swapped
    let linkDir = dir + "/link"
    try? fm.createDirectory(atPath: linkDir, withIntermediateDirectories: true)
    fm.createFile(atPath: dir + "/elsewhere.json", contents: dstBytes)
    symlink(dir + "/elsewhere.json", TaskRegistry.path(linkDir))
    if case .failed = TaskRegistry.swap(next, at: TaskRegistry.path(linkDir), expected: dstBytes) {
        check(fm.contents(atPath: dir + "/elsewhere.json") == dstBytes, "a link at the name: refused, the file it points to untouched")
    } else { check(false, "a link at the name: refused") }
    let fifoDir = dir + "/fifo"
    try? fm.createDirectory(atPath: fifoDir, withIntermediateDirectories: true)
    mkfifo(TaskRegistry.path(fifoDir), 0o600)
    let t1 = Date()
    if case .failed = TaskRegistry.swap(next, at: TaskRegistry.path(fifoDir), expected: nil) { check(Date().timeIntervalSince(t1) < 2, "a FIFO at the name: refused at once") }
    else { check(false, "a FIFO at the name: refused") }
    // taken away only while unchanged
    check(TaskRegistry.remove(at: TaskRegistry.path(fresh), expected: dstBytes) == .changed && TaskRegistry.exists(fresh), "remove: not as expected, kept")
    check(TaskRegistry.remove(at: TaskRegistry.path(fresh), expected: next) == .written && !TaskRegistry.exists(fresh), "remove: as expected, gone")
    // no temp file is left behind
    let leftovers = ((try? fm.subpathsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".tmp") }
    check(leftovers.isEmpty, "no temp file left: \(leftovers)")
    try? fm.removeItem(atPath: dir)
}

print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
