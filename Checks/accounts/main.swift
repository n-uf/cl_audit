// The one-folder model's checks for cl_audit (cl_quick's model): a profile is one Claude Code folder, its account in use is
// the one signed in there, its standby accounts are remembered signed out. What an older profiles file becomes, the folders
// it kept (offered to the Trash, never deleted silently, their Keychain items never touched), the folder's account followed
// by itself, the account book, the switch's watch, the sign-in script, Add account, the menus' lines, the clean-up of the
// standby accounts' old files, and the old switches' receipts read only.
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
      "standby":[{"id":"k2","email":"ultra-2@example.com","seat":{"account":"\(u2.account)","organization":"\(u2.organization!)","email":"ultra-2@example.com"},"configDir":"~/.claude-ultra-2","addedAt":1700000000},
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
          == "Claude Code in Terminal and editors on ~/.claude moves to u2, sessions running now included; the Claude app keeps its own sign-in. Finish the sign-in in Terminal and the browser as that account.",
          "what a switch affects, for ~/.claude")
    check(AccountBook.switchWords(folder: "~/.claude-work", email: "u2", isDefault: false).hasPrefix("Claude Code pointed at ~/.claude-work with CLAUDE_CONFIG_DIR moves to u2"),
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
    check(!l1.contains { $0.contains("s=$?") }, "no marker for a switch")
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

// ============ 8. Add account remembers ============
do {
    let main = profile("main", "~/.claude", u1, standby: [StandbyAccount(email: u2.email!, seat: u2, id: "k2")])
    let work = profile("work", "~/.claude-work", u3)
    check((try? main.remembering("nope", among: [main, work]).get()) == nil, "not an address: refused")
    if case .failure(let why) = main.remembering(" Ultra-2@example.com ", among: [main, work]) { check(why == .already("Main"), "one of its own: refused") } else { check(false, "one of its own") }
    if case .failure(let why) = main.remembering("ultra-3@example.com", among: [main, work]) { check(why.words.contains("“Work”"), "another profile's: refused, by name") } else { check(false, "another profile's") }
    let added = try? main.remembering("ultra-5@example.com", among: [main, work]).get()
    check(added?.standby.last?.email == "ultra-5@example.com" && added?.standby.last?.seat == nil, "an address is remembered, signed out, with no seat yet")
    let before = opened.count
    _ = try? main.remembering("ultra-6@example.com", among: [main, work]).get()
    check(opened.count == before, "remembering opens no sign-in")
    let f = FoundAccount(seat: u4, plan: "Max", org: "Personal", folder: "~/.claude-somewhere")
    let viaFound = main.adding(f, among: [main, work], signedIn: { _ in nil })
    check(viaFound?.standby.last?.seat.map { $0.same(u4) } == true && viaFound?.standby.last?.plan == "Max", "a found account is remembered with its plan, no folder")
    check(main.adding(FoundAccount(seat: u3), among: [main, work], signedIn: { _ in nil }) == nil, "another profile's account can't be added")
    let rows = AddAccountPopup.rows(found: [f], profile: "Main")
    check(rows.last?.kind == .other && rows.last?.title == "Another address…" && rows.first { $0.kind == .account }?.detail?.contains("limits") == false,
          "the pop-up: found accounts (no limits promised), then Another address…")
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
    check(words.contains("3 of the Claude window's sessions sit under ultra-2") && words.contains("Restore…"), "the Sessions card says where its sessions are, and the backup")
    check(!SessionsCard.oldSwitchDismissed(r.id), "said until OK")
    SessionsCard.dismissOldSwitch(r.id)
    check(SessionsCard.oldSwitchDismissed(r.id), "OK: not said again")
    check((try? Data(contentsOf: dir.appendingPathComponent("receipt.json"))) == receiptBytes, "the receipt itself is never written or deleted")
    UserDefaults.standard.removeObject(forKey: "oldSwitchSeen")
}

print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
