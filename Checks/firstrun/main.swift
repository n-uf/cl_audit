// First-run checks for cl_audit: the first-run page, the Claude lookup, the sign-in step.
// Runs only with CFFIXED_USER_HOME = .../Checks/.work/firstrun/home (Checks/run.sh sets and guards it). Nothing here opens Terminal, the
// Dock or any app; "Sign in…" is checked up to the point Terminal would open.
//
// --- first run ---

import AppKit
import SwiftUI

var passed = 0, failed = 0
func check(_ ok: Bool, _ what: String, file: String = #fileID, line: Int = #line) {
    if ok { passed += 1 } else { failed += 1; print("FAIL (line \(line)): \(what)") }
}

let home = NSHomeDirectory()
guard home.hasSuffix("/Checks/.work/firstrun/home") else { print("refusing: HOME is \(home)"); exit(2) }
let fm = FileManager.default
func p(_ rel: String) -> String { (home as NSString).appendingPathComponent(rel) }

/// An empty throwaway home.
func resetHome() {
    for n in (try? fm.contentsOfDirectory(atPath: home)) ?? [] { try? fm.removeItem(atPath: p(n)) }
    try? fm.createDirectory(atPath: p("Library/Application Support"), withIntermediateDirectories: true)
    UserDefaults.standard.removeObject(forKey: "face")
}
func write(_ rel: String, _ text: String, exec: Bool = false) {
    let path = p(rel)
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
    if exec { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
}
/// A stub `claude`: a script printing a version.
func stub(_ rel: String, version: String = "2.1.99") { write(rel, "#!/bin/sh\necho \"\(version) (Claude Code)\"\n", exec: true) }
/// A Mach-O-looking stub (the first bytes of a real program, then a script is not needed: only the header is looked at).
func machO(_ rel: String) {
    let path = p(rel)
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    var bytes: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE]; bytes += Array("stub".utf8)
    fm.createFile(atPath: path, contents: Data(bytes), attributes: [.posixPermissions: 0o755])
}
func fakeAccount(dir: String, uuid: String, email: String, orgType: String = "individual", orgName: String = "", plan: String = "Max") {
    // obviously fake: ids and an address only, never a token
    let json: [String: Any] = ["oauthAccount": ["accountUuid": uuid, "emailAddress": email, "organizationUuid": "00000000-0000-4000-8000-0000000000ff",
                                                "organizationType": orgType, "organizationName": orgName, "planDisplayName": plan]]
    let file = dir == "~/.claude" ? p(".claude.json") : p("\(dir.dropFirst(2))/.claude.json")
    try? fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: file))
    if dir != "~/.claude" { write("\(dir.dropFirst(2))/settings.json", "{}") }
}
let none = ClaudeLocator.Lookup(candidates: { [] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
func wait(_ cond: () -> Bool, _ seconds: Double = 8) {
    let end = Date().addingTimeInterval(seconds)
    while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}
func entry(_ id: String, _ name: String, dir: String = "~/.claude") -> AccountEntry { AccountEntry(id: id, name: name, label: name.uppercased(), configDir: dir) }

_ = NSApplication.shared
SettingsModel.followsDock = false

// ============ 1. where claude is looked for ============
do {
    resetHome()
    check(ClaudeLocator.find(lookup: none) == nil, "nothing anywhere: not found")
    check(ClaudeLocator.find(quick: true, lookup: none) == nil, "nothing anywhere (quick): not found")

    // 26.11.1's places, in 26.11.1's order, and nothing else among them
    let places = ClaudeLocator.realCandidates(home: home)
    let tail = places.map { $0.replacingOccurrences(of: home, with: "~") }
    check(tail == ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.local/bin/claude", "~/.claude/local/claude",
                   "~/.npm-global/bin/claude", "~/.bun/bin/claude"], "26.11.1's order: \(tail)")
    // the new places: Volta, then nvm newest first (tried only after the login shell)
    for rel in [".nvm/versions/node/v9.11.2/bin/claude", ".nvm/versions/node/v22.1.0/bin/claude", ".nvm/versions/node/v20.19.0/bin/claude"] { stub(rel) }
    let more = ClaudeLocator.moreCandidates(home: home).map { $0.replacingOccurrences(of: home, with: "~") }
    check(more.first == "~/.volta/bin/claude", "Volta first among the new places: \(more)")
    let nvm = ClaudeLocator.moreCandidates(home: home).filter { $0.contains("/.nvm/") }.map { ($0 as NSString).deletingLastPathComponent }
        .map { String($0.split(separator: "/").dropLast().last ?? "") }
    check(nvm == ["v22.1.0", "v20.19.0", "v9.11.2"], "nvm newest first, by number: \(nvm)")
    check(ClaudeLocator.newer("v22.1.0", than: "v9.11.2") && !ClaudeLocator.newer("v9.11.2", than: "v22.1.0"), "9 is older than 22")
    check(ClaudeLocator.newer("2.1.10", than: "2.1.5"), "2.1.10 is newer than 2.1.5")

    // the old places only inside the throwaway home (the real /opt/homebrew and /usr/local aren't looked at)
    let inHome = { ClaudeLocator.realCandidates(home: home).filter { $0.hasPrefix(home) } }
    let real = ClaudeLocator.Lookup(candidates: inHome, npmPrefix: { nil }, shell: { nil }, appCopy: { nil },
                                    more: { ClaudeLocator.moreCandidates(home: home) })
    check(ClaudeLocator.find(lookup: real)?.path.contains("v22.1.0") == true, "nvm's newest is found when nothing older is there")
    stub(".volta/bin/claude"); check(ClaudeLocator.find(lookup: real)?.path == p(".volta/bin/claude"), "Volta before nvm")
    stub(".bun/bin/claude"); check(ClaudeLocator.find(lookup: real)?.path == p(".bun/bin/claude"), "26.11.1's places before Volta")
    stub(".npm-global/bin/claude"); check(ClaudeLocator.find(lookup: real)?.path == p(".npm-global/bin/claude"), "npm-global before bun")
    stub(".claude/local/claude"); check(ClaudeLocator.find(lookup: real)?.path == p(".claude/local/claude"), "~/.claude/local before npm-global")
    stub(".local/bin/claude"); check(ClaudeLocator.find(lookup: real)?.path == p(".local/bin/claude"), "~/.local/bin before ~/.claude/local")
    check(ClaudeLocator.find(lookup: real)?.fromApp == false, "a real install isn't 'from the app'")
    // the homebrew one wins over ~/.local/bin, as in 26.11.1 (injected: /opt/homebrew isn't touched)
    stub("fakebrew/claude")
    let brew = ClaudeLocator.Lookup(candidates: { [p("fakebrew/claude")] + inHome() }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
    check(ClaudeLocator.find(lookup: brew)?.path == p("fakebrew/claude"), "stubs at ~/.local/bin and homebrew: homebrew wins, as before")
    check(ClaudeLocator.find(quick: true, lookup: brew)?.path == p("fakebrew/claude"), "…and the quick look agrees")
    write(".local/bin/notexec", "x"); check(!ClaudeLocator.isExecutable(p(".local/bin/notexec")), "a file without x isn't a program")
    check(!ClaudeLocator.isExecutable(p(".local/bin")), "a folder isn't a program")

    // 26.11.1's places, the login shell, then Volta/nvm, npm's prefix, the app's copy: in that order
    resetHome()
    stub("old/claude"); stub("shellbin/claude"); stub("morebin/claude"); stub("npmprefix/bin/claude"); stub("appcopy/claude")
    var l = ClaudeLocator.Lookup(candidates: { [p("old/claude")] }, npmPrefix: { p("npmprefix") }, shell: { p("shellbin/claude") },
                                 appCopy: { p("appcopy/claude") }, more: { [p("morebin/claude")] })
    check(ClaudeLocator.find(lookup: l)?.path == p("old/claude"), "26.11.1's places first")
    check(ClaudeLocator.find(quick: true, lookup: l)?.path == p("old/claude"), "quick: 26.11.1's places")
    l.candidates = { [] }
    check(ClaudeLocator.find(quick: true, lookup: l) == nil, "quick: nothing else, never the shell, the new places or the app's copy")
    check(ClaudeLocator.find(lookup: l)?.path == p("shellbin/claude"), "the login shell right after 26.11.1's places")
    l.shell = { "claude" }                       // an alias or function: nothing usable
    check(ClaudeLocator.find(lookup: l)?.path == p("morebin/claude"), "an alias isn't a program; Volta/nvm next")
    l.more = { [] }
    check(ClaudeLocator.find(lookup: l)?.path == p("npmprefix/bin/claude"), "npm's prefix after those")
    l.npmPrefix = { nil }
    check(ClaudeLocator.find(lookup: l) == ClaudeFound(path: p("appcopy/claude"), fromApp: true), "the app's copy last, and says so")
    l.shell = { p("missing/claude") }
    check(ClaudeLocator.find(lookup: l)?.fromApp == true, "a shell answer that isn't there is ignored")

    // the Claude app's own copy
    resetHome()
    let support = p("Library/Application Support")
    func appBin(_ app: String, _ v: String, _ id: String) -> String { "Library/Application Support/\(app)/claude-code/\(v)/\(id)/claude.app/Contents/MacOS/claude" }
    machO(appBin("Claude", "2.1.5", "aaa")); write("Library/Application Support/Claude/claude-code/2.1.5/aaa.verified", "")
    machO(appBin("Claude", "2.1.10", "bbb")); write("Library/Application Support/Claude/claude-code/2.1.10/bbb.verified", "")
    machO(appBin("Claude", "2.1.20", "ccc"))                              // not marked finished
    write(appBin("Claude", "2.1.30", "ddd"), "#!/bin/sh\n", exec: true); write("Library/Application Support/Claude/claude-code/2.1.30/ddd.verified", "")   // a script, not a program
    machO("Library/Application Support/Claude/claude-code-vm/2.9.9/eee/claude")   // the Linux program's folder
    write("Library/Application Support/Claude/claude-code-vm/2.9.9/eee.verified", "")
    check(ClaudeLocator.appCopy(support: support) == p(appBin("Claude", "2.1.10", "bbb")), "app copy: newest finished Mach-O, numeric: \(ClaudeLocator.appCopy(support: support) ?? "nil")")
    machO(appBin("Claude-work", "2.2.0", "fff")); write("Library/Application Support/Claude-work/claude-code/2.2.0/fff/.verified", "")
    check(ClaudeLocator.appCopy(support: support) == p(appBin("Claude-work", "2.2.0", "fff")), "app copy: any Claude* folder, marker inside the folder counts")
    try? fm.removeItem(atPath: p("Library/Application Support/Claude-work")); try? fm.removeItem(atPath: p("Library/Application Support/Claude/claude-code/2.1.10"))
    try? fm.removeItem(atPath: p("Library/Application Support/Claude/claude-code/2.1.5"))
    check(ClaudeLocator.appCopy(support: support) == p(appBin("Claude", "2.1.20", "ccc")), "app copy: an unmarked one only as a last resort")
    try? fm.removeItem(atPath: p("Library/Application Support/Claude/claude-code/2.1.20"))
    check(ClaudeLocator.appCopy(support: support) == nil, "app copy: scripts and the VM folder never count")
    check(ClaudeLocator.appCopy(support: p("nowhere")) == nil, "app copy: no Application Support, none")

    // version, and a slow program can't hang it
    resetHome()
    stub("v/claude", version: "2.1.211")
    check(ClaudeLocator.version(of: p("v/claude")) == "2.1.211", "version parsed from '2.1.211 (Claude Code)'")
    write("slow/claude", "#!/bin/sh\nsleep 30\n", exec: true)
    let t0 = Date()
    check(ClaudeLocator.version(of: p("slow/claude"), timeout: 1) == nil, "a program that doesn't answer gives no version")
    check(Date().timeIntervalSince(t0) < 4, "…and doesn't block for long (\(Date().timeIntervalSince(t0)) s)")
    let t1 = Date()
    check(ClaudeLocator.run("/bin/sh", ["-c", "sleep 20"], path: nil, timeout: 0.5) == nil && Date().timeIntervalSince(t1) < 3, "run() stops a slow shell")
    check(ClaudeLocator.version(of: p("missing")) == nil, "no program, no version")
}

// ============ 2. a fresh Mac: no profiles, no claude anywhere ============
do {
    resetHome()
    ClaudeLocator.current = none
    let m = SettingsModel()
    check(m.accounts.isEmpty, "no automatic 'main': no profiles")
    check(m.isFirstRun && m.selection == SettingsModel.firstRunID, "the first-run page is what opens")
    check(m.claude == nil && m.claudePath == nil, "claude not found")
    check(!m.claudeLooked && !m.claudeKnownMissing, "before the first full look: not known, so never 'not installed'")
    check(FirstRun.step(claude: false, draft: m.firstRun) == .claudeCode, "step 1 while Claude Code is missing")
    check(m.claudeNow() == nil, "claudeNow: nothing")
    check(m.requireClaude() == nil, "requireClaude: nil")
    check(m.message.hasPrefix("Still looking"), "…before the look is done it says it is still looking: \(m.message)")
    check(!m.installHelp, "…and opens no install help")
    wait { m.claudeLooked }
    check(m.claudeLooked && m.claudeKnownMissing, "after the full look: known missing")
    check(m.requireClaude() == nil, "requireClaude: nil")
    check(m.message == ClaudeInstall.missingInstall, "…says why: \(m.message)")
    check(!m.installHelp, "…on the first-run page the install help is its step 1, no sheet")
    m.firstRunSignIn()
    check(m.firstRun.problem == ClaudeInstall.missing, "Sign in… says why: \(m.firstRun.problem ?? "nil")")
    check(m.firstRun.signInAsked == nil, "…and nothing started")
    m.selection = SettingsModel.dashboardID
    _ = m.requireClaude()
    check(m.installHelp, "elsewhere in Settings the install help opens as a sheet")
    check(ClaudeInstall.command == "curl -fsSL https://claude.ai/install.sh | bash", "the install command")
    check(ClaudeInstall.missingInstall == "Claude Code isn't installed on this Mac · Install…", "the reason line")

    // every sign-in route says why
    let rows = AddAccountPopup.rows(found: [], profile: "x", canSignIn: false)
    check(rows.contains { $0.kind == .installClaude && $0.title == ClaudeInstall.missingInstall && $0.enabled }, "Add account: a row says why")
    check(rows.first { $0.kind == .signInOther }?.enabled == false, "Add account: Sign in to another account… stays greyed, with that row above it")
    let idx = rows.firstIndex { $0.kind == .installClaude }!, idx2 = rows.firstIndex { $0.kind == .signInOther }!
    check(idx == idx2 - 1, "the reason sits right above the greyed key")
    var installed = 0
    let menu = AddAccountPopup.menu(rows, onAdd: { _ in }, onOther: {}, onInstall: { installed += 1 })
    let item = menu.items.first { $0.title == ClaudeInstall.missingInstall }
    check(item != nil && item!.isEnabled, "the menu has the enabled reason item")
    if let item, let a = item.target as? MenuAction { a.run() }
    check(installed == 1, "…and it opens the install help")
    let ok = AddAccountPopup.rows(found: [], profile: "x", canSignIn: true)
    check(!ok.contains { $0.kind == .installClaude } && ok.first { $0.kind == .signInOther }?.enabled == true, "with Claude Code there, no reason row and the key is live")

    // zero profiles everywhere
    let launcher = LauncherModel(); launcher.reload()
    check(launcher.rows.isEmpty && launcher.filtered.isEmpty && launcher.shownRows.isEmpty, "the launcher model has no rows and doesn't crash")
    launcher.selectMostRoom()
    check(ProfileOrder.apply([], to: [AccountEntry]()).isEmpty, "profile order of nothing")
    _ = ProfileDragPlan(count: 0, dragged: nil, offset: .zero, arrange: { $0.map { _ in .zero } })
    _ = ProfileDragPlan(count: 1, dragged: 0, offset: .zero, arrange: { $0.map { _ in .zero } })
    check(DockManager.plan([], accounts: [], prefs: DockPrefs.shared).count >= 0, "Dock plan for no profiles runs")
    check(!DockManager.planPins([], want: [:]).changed, "Dock pin plan for no profiles")
    _ = MenuBarItems(profiles: { [] }, refresh: { _ in }, renew: { _ in }).update()
    check(SettingsModel.merge(base: [], local: [], remote: []).isEmpty, "merge of nothing")
    check(Store.loadChecked() == nil && Store.load().isEmpty, "no accounts file: empty, not 'main'")
    m.startNew()                                   // New profile with zero profiles (no template to copy)
    check(m.draft != nil && m.draft?.template == nil, "New profile works with no profile to copy from")
    m.draft = nil
    let dock = AppDelegate().managerDockMenu()
    check(dock.items.contains { $0.title == "Set up cl_audit…" }, "the Dock menu offers 'Set up cl_audit…' with no profile: \(dock.items.map(\.title))")
    check(!dock.items.contains { $0.title.hasPrefix("Open Claude") }, "…and no 'Open Claude' lines")
    check(dock.items.first?.isSeparatorItem == false, "…and doesn't start with a separator")
    m.cancelNew()
}

// ============ 3. found: a stub claude, the version, step 2 ============
do {
    resetHome()
    stub(".local/bin/claude", version: "2.1.211")
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [p(".local/bin/claude")] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
    let m = SettingsModel()
    check(m.claude == ClaudeFound(path: p(".local/bin/claude")), "found at once (file lookup), before any process runs")
    m.detectClaude(force: true)
    wait { m.claudeVersion != nil }
    check(m.claudeVersion == "2.1.211", "version shown: \(m.claudeVersion ?? "nil")")
    check(m.claudeLooked, "a full look finished")
    check(FirstRun.step(claude: m.claude != nil, draft: m.firstRun) == .account, "step 2 is enabled")
    check(m.requireClaude() == p(".local/bin/claude") && m.message.isEmpty, "requireClaude gives the path, says nothing")
    check(!AddAccountPopup.rows(found: [], profile: "x", canSignIn: m.claudeNow() != nil).contains { $0.kind == .installClaude }, "no reason row once found")
    check(FirstRun.foundFolders().isEmpty, "no signed-in folder yet")
    check(FirstRun.signInFolder(email: "") == "~/.claude", "Sign in… uses ~/.claude while nothing is signed in there")

    // it goes away, and comes back: noticed by the timer's watch and by detectClaude
    try? fm.removeItem(atPath: p(".local/bin/claude"))
    m.watchClaude()
    check(m.claude == nil && m.claudeVersion == nil, "a removed claude is dropped")
    check(m.claudeNow() == nil, "…and not claimed")
    stub(".local/bin/claude", version: "2.1.212")
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))          // a look under way finishes first
    m.detectClaude(force: true); wait { m.claudeVersion == "2.1.212" }
    check(m.claude?.path == p(".local/bin/claude") && m.claudeVersion == "2.1.212", "installed afterwards: noticed, new version")
    // throttled: a second look inside the interval does nothing
    var done = 0
    m.detectClaude(then: { done += 1 }); m.detectClaude(then: { done += 1 })
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(done == 0, "throttled: no look inside \(SettingsModel.claudeEvery) s unless forced")
}

// ============ 4. only the Claude app's own copy ============
do {
    resetHome()
    machO("Library/Application Support/Claude/claude-code/2.1.50/abc/claude.app/Contents/MacOS/claude")
    write("Library/Application Support/Claude/claude-code/2.1.50/abc.verified", "")
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [] }, npmPrefix: { nil }, shell: { nil },
                                                 appCopy: { ClaudeLocator.appCopy(support: p("Library/Application Support")) })
    let m = SettingsModel()
    check(m.claude == nil, "the first value (quick look) is never the app's copy")
    m.detectClaude(force: true); wait { m.claudeLooked }
    check(m.claude?.fromApp == true, "only the app's copy: found by the full look, from the app")
    check(FirstRun.step(claude: m.claude != nil, draft: m.firstRun) == .account, "…step 2 is enabled")
    // a real install shows up: it wins
    stub(".local/bin/claude", version: "2.1.7")
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [p(".local/bin/claude")] }, npmPrefix: { nil }, shell: { nil },
                                                 appCopy: { ClaudeLocator.appCopy(support: p("Library/Application Support")) })
    m.detectClaude(force: true); wait { m.claude?.fromApp == false }
    check(m.claude == ClaudeFound(path: p(".local/bin/claude")), "a real install is preferred over the app's copy")
}

// ============ 5. a signed-in folder: offered, one click, a profile ============
do {
    resetHome()
    stub(".local/bin/claude")
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [p(".local/bin/claude")] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
    fakeAccount(dir: "~/.claude-work", uuid: "00000000-0000-4000-8000-000000000001", email: "fake.person@example.invalid",
                orgType: "team", orgName: "Acme Test", plan: "Max")
    write(".claude-empty/settings.json", "{}")                          // a folder that isn't signed in: not offered
    let found = FirstRun.foundFolders()
    check(found.count == 1 && found[0].path == "~/.claude-work" && found[0].email == "fake.person@example.invalid", "step 2 offers the signed-in folder only: \(found)")
    check(found.first?.detail.contains("Max") == true && found.first?.detail.contains("Acme Test") == true, "…with its plan and organisation: \(found.first?.detail ?? "")")
    let m = SettingsModel()
    check(m.isFirstRun && m.accounts.isEmpty, "fresh")
    m.firstRunPick("~/.claude-work")
    check(m.firstRun.folder == "~/.claude-work" && m.firstRun.name == "Acme Test", "one click picks it; the name comes from the organisation: \(m.firstRun.name)")
    check(FirstRun.step(claude: true, draft: m.firstRun) == .name, "step 3")
    m.firstRun.name = "Work"; m.firstRun.nameEdited = true
    m.firstRun.color = .lime
    check(m.commitFirstRun() == nil, "Done")
    check(m.accounts.count == 1, "one profile")
    if let e = m.accounts.first {
        check(e.id == "work" && e.name == "Work" && e.configDir == "~/.claude-work", "profile on that folder: \(e.id) \(e.name) \(e.configDir)")
        check(e.color == .lime && e.seat?.email == "fake.person@example.invalid" && e.seat?.linkedAt != nil, "its colour, and linked to the account")
        check(e.desktop == .separate && fm.fileExists(atPath: expand(e.desktopDataDir)), "own Claude window folder made: \(e.desktopDataDir)")
        check(m.selection == "work" && !m.isFirstRun, "normal Settings for that profile")
    }
    check(m.firstRun == FirstRunDraft(color: .lime), "the page's choices are reset")
    // nothing from the account but an address and ids was read: the fixture has no token to find
    check(!(FirstRun.foundFolders().first.map { "\($0)" } ?? "").contains("token"), "no token anywhere in what's shown")

    // the address's name part when it's a personal account
    resetHome()
    fakeAccount(dir: "~/.claude-me", uuid: "00000000-0000-4000-8000-000000000002", email: "jane.doe@example.invalid", orgType: "individual", orgName: "jane.doe@example.invalid's Organization")
    check(FirstRun.suggestedName(folder: "~/.claude-me") == "jane.doe", "personal: the address's name part: \(FirstRun.suggestedName(folder: "~/.claude-me"))")
    fakeAccount(dir: "~/.claude-me", uuid: "00000000-0000-4000-8000-000000000002", email: "x@example.invalid", orgType: "team", orgName: "A/B: Team")
    check(FirstRun.suggestedName(folder: "~/.claude-me") == "A-B- Team", "a name can't hold / or :")
    check(FirstRun.suggestedName(folder: "~/.claude-none") == "Claude", "no account: a plain fallback")

    // refusals
    resetHome()
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
    let r = SettingsModel()
    check(r.commitFirstRun() != nil, "no account picked: refused")
    fakeAccount(dir: "~/.claude-w", uuid: "00000000-0000-4000-8000-000000000003", email: "w@example.invalid")
    r.firstRunPick("~/.claude-w"); r.firstRun.name = "  "
    check(r.commitFirstRun() == "Give the profile a name." && r.accounts.isEmpty, "empty name: refused, nothing made")
    r.firstRun.name = "a/b"
    check(r.commitFirstRun() != nil && r.accounts.isEmpty, "a name with / is refused")
    r.firstRunChangeAccount()
    check(r.firstRun.folder == nil && FirstRun.step(claude: true, draft: r.firstRun) == .account, "Change goes back to step 2")
}

// ============ 6. a sign-in that lands (Terminal is not opened here) ============
do {
    resetHome()
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
    let m = SettingsModel()
    check(FirstRun.addressProblem("") == nil && FirstRun.addressProblem("a@example.com") == nil, "the address is optional")
    check(FirstRun.addressProblem("nope") != nil && FirstRun.addressProblem("@x") != nil && FirstRun.addressProblem("a b@c") != nil, "a bad address is said")
    m.firstRun.email = "nope"; m.firstRunSignIn()
    check(m.firstRun.problem?.contains("email") == true && m.firstRun.signInAsked == nil, "a bad address stops Sign in…")
    m.firstRun.problem = nil
    m.firstRun.signInDir = "~/.claude"; m.firstRun.signInAsked = Date(); m.firstRun.seatAtAsk = nil
    check(m.firstRun.waiting, "waiting for the sign-in")
    m.followFirstRun()
    check(m.firstRun.folder == nil, "nothing signed in yet: keeps waiting")
    fakeAccount(dir: "~/.claude", uuid: "00000000-0000-4000-8000-000000000004", email: "new.person@example.invalid")
    m.followFirstRun()
    check(m.firstRun.folder == "~/.claude" && m.firstRun.name == "new.person" && !m.firstRun.waiting, "the sign-in landed: account taken, name prefilled: \(m.firstRun.name)")
    // signing in again with another account: only a different account counts
    m.firstRunChangeAccount()
    m.firstRun.signInDir = "~/.claude"; m.firstRun.signInAsked = Date()
    m.firstRun.seatAtAsk = Account.signedInSeat(configDir: "~/.claude")
    m.followFirstRun()
    check(m.firstRun.folder == nil, "same account as before Sign in… was pressed: still waiting")
    fakeAccount(dir: "~/.claude", uuid: "00000000-0000-4000-8000-000000000005", email: "other.person@example.invalid")
    m.followFirstRun()
    check(m.firstRun.folder == "~/.claude", "another account: taken")
    // the folder Sign in… uses now that ~/.claude has an account
    check(FirstRun.signInFolder(email: "other.person@example.invalid") == "~/.claude-other-person", "next sign-in goes to a new folder: \(FirstRun.signInFolder(email: "other.person@example.invalid"))")
    write(".claude-other-person/settings.json", "{}")
    check(FirstRun.signInFolder(email: "other.person@example.invalid") == "~/.claude-other-person-2", "…never an existing one")
    // an hour without the sign-in landing: gives up
    m.firstRunChangeAccount()
    m.firstRun.signInDir = "~/.claude-zz"; m.firstRun.signInAsked = Date().addingTimeInterval(-3700)
    m.followFirstRun()
    check(m.firstRun.signInAsked == nil, "gives up after an hour")
}

// ============ 7. who sees the first-run page ============
do {
    resetHome()
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
    let main = FirstRun.implicitMain
    check(main == AccountEntry(id: "main", name: "main", label: "MAIN", configDir: "~/.claude"), "the implicit main is what 26.11.1 made")
    check(FirstRun.needed([]), "no profile: yes")
    check(FirstRun.needed([main]), "only the implicit, never-signed-in main: yes")
    // a Mac stuck on the first-run page: that main, persisted, ~/.claude not signed in
    try? Store.save([main])
    let stuck = SettingsModel()
    check(stuck.isFirstRun && stuck.selection == SettingsModel.firstRunID && stuck.accounts == [main], "stuck Mac: first-run page, the file untouched")
    check((try? Data(contentsOf: Store.configURL)).map { String(decoding: $0, as: UTF8.self).contains("\"main\"") } == true, "…the profiles file still has it (nothing rewritten)")
    fakeAccount(dir: "~/.claude-work", uuid: "00000000-0000-4000-8000-000000000006", email: "stuck.person@example.invalid")
    stuck.firstRunPick("~/.claude-work")
    check(stuck.commitFirstRun() == nil, "stuck: Done")
    check(stuck.accounts.map(\.id) == ["stuck-person"] && !stuck.accounts.contains { $0.id == "main" }, "…the implicit main is gone, the new profile is there: \(stuck.accounts.map(\.id))")
    let merged = SettingsModel.merge(base: [main], local: stuck.accounts, remote: [main])
    check(merged.map(\.id) == ["stuck-person"], "…and the save (merge with the file) drops it too: \(merged.map(\.id))")
    // ~/.claude gets signed in outside cl_audit: main is a real profile then
    fakeAccount(dir: "~/.claude", uuid: "00000000-0000-4000-8000-000000000007", email: "main.person@example.invalid")
    check(!FirstRun.needed([main]), "main with ~/.claude signed in: never the first-run page")
    try? fm.removeItem(atPath: p(".claude.json"))
    // used profiles never see it
    var changed = main; changed.color = .lime
    check(!FirstRun.needed([changed]), "a main whose colour was changed is a used profile")
    var renamed = main; renamed.name = "Personal"
    check(!FirstRun.needed([renamed]), "a renamed main is a used profile")
    var styled = main; styled.style = .number
    check(!FirstRun.needed([styled]), "a main with another setting is a used profile")
    var withStandby = main; withStandby.standby = [StandbyAccount(email: "s@example.invalid")]
    check(!FirstRun.needed([withStandby]), "a main with a standby account is a used profile")
    var seated = main; seated.seat = Seat(account: "00000000-0000-4000-8000-000000000008", organization: nil, email: "x@example.invalid")
    check(!FirstRun.needed([seated]), "a linked main is a used profile")
    check(!FirstRun.needed([main, entry("work", "Work", dir: "~/.claude-work")]), "two profiles: no")
    check(!FirstRun.needed([entry("work", "Work", dir: "~/.claude-work")]), "one real profile: no")
    try? Store.save([entry("work", "Work", dir: "~/.claude-work"), entry("home", "Home", dir: "~/.claude-home")])
    let used = SettingsModel()
    check(!used.isFirstRun && used.selection == SettingsModel.dashboardID && used.accounts.count == 2, "an existing install: the Dashboard, its profiles, no first-run page")
    check(used.homeSelection == SettingsModel.dashboardID && used.isValid(SettingsModel.dashboardID) && !used.isValid(SettingsModel.firstRunID), "…selection rules agree")
    // removing every profile: the empty state is the first-run page, never a dead end
    used.remove("work"); used.remove("home")
    check(used.isFirstRun && used.selection == SettingsModel.firstRunID, "all profiles removed: the first-run page")
    check(used.commitFirstRun() != nil, "…and Done needs an account")
}

// ============ 9. never a guess: a claude only the login shell finds ============
do {
    resetHome()
    stub("shellbin/claude", version: "2.1.50"); stub("appcopy/claude", version: "2.1.1")
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [] }, npmPrefix: { nil }, shell: { p("shellbin/claude") },
                                                 appCopy: { p("appcopy/claude") })
    let m = SettingsModel()
    check(m.claude == nil, "shell-only claude: the first value is nil, never the app's copy")
    check(m.requireClaude() == nil && m.message.hasPrefix("Still looking"), "a sign-in before the full look: 'still looking', not the app's copy, not 'not installed'")
    check(!m.installHelp, "…and no install help")
    wait { m.claudeLooked }
    check(m.claude == ClaudeFound(path: p("shellbin/claude")), "the full look: the shell's claude, not the app's copy: \(String(describing: m.claude))")
    check(m.requireClaude() == p("shellbin/claude"), "sign-in uses it")
    check(m.claudeNow() == p("shellbin/claude"), "claudeNow too")
    // Remove profile, Cancel new profile and Uninstall call ClaudeCLI.find() in their background block: the same lookup
    check(ClaudeCLI.find() == p("shellbin/claude"), "sign-out (remove, cancel, uninstall) finds the shell's claude, never nil, never the app's copy")
    var got: String??
    DispatchQueue.global().async { got = .some(ClaudeCLI.find()) }
    wait { got != nil }
    check(got == .some(p("shellbin/claude")), "…also from a background thread")
    // nothing is cached past a re-detect: the shell's answer changes, the next look has it
    stub("shellbin2/claude")
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [] }, npmPrefix: { nil }, shell: { p("shellbin2/claude") }, appCopy: { p("appcopy/claude") })
    check(ClaudeCLI.find() == p("shellbin2/claude"), "ClaudeCLI.find() has no cache: the next look is the new answer")
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    m.detectClaude(force: true); wait { m.claude?.path == p("shellbin2/claude") }
    check(m.claude?.path == p("shellbin2/claude"), "the model replaces its claude on a re-detect")
    // the app's copy found by a full look yields to a real install in 26.11.1's places
    resetHome()
    stub("appcopy/claude"); stub("real/claude")
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [] }, npmPrefix: { nil }, shell: { nil }, appCopy: { p("appcopy/claude") })
    let a = SettingsModel(); a.detectClaude(force: true); wait { a.claudeLooked }
    check(a.claude?.fromApp == true && a.claudeNow() == p("appcopy/claude"), "only the app's copy: used")
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [p("real/claude")] }, npmPrefix: { nil }, shell: { nil }, appCopy: { p("appcopy/claude") })
    check(a.claudeNow() == p("real/claude") && a.claude?.fromApp == false, "a real install appearing is used at once, before the next full look")
}

// ============ 10. the look runs only while something shows it ============
do {
    resetHome()
    let lock = NSLock(); var shellCalls = 0
    func counting() -> ClaudeLocator.Lookup {
        ClaudeLocator.Lookup(candidates: { [] }, npmPrefix: { nil }, shell: { lock.lock(); shellCalls += 1; lock.unlock(); return nil }, appCopy: { nil })
    }
    func calls() -> Int { lock.lock(); defer { lock.unlock() }; return shellCalls }
    ClaudeLocator.current = counting()
    // an existing install (profiles), claude missing, nothing on screen: the timer's watch does nothing
    try? Store.save([entry("work", "Work", dir: "~/.claude-work"), entry("home", "Home", dir: "~/.claude-home")])
    let m = SettingsModel()
    for _ in 0..<5 { m.watchClaude() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    check(calls() == 0, "no page, no note: no lookups (\(calls()))")
    // an 'isn't installed' note on screen: it looks, then backs off
    m.claudeNotes = 1
    m.watchClaude(); wait { calls() >= 1 }
    check(calls() == 1 && m.claudeKnownMissing, "a note on screen: one look")
    for _ in 0..<5 { m.watchClaude() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    check(calls() == 1, "…then it backs off (no second look inside 6 s): \(calls())")
    // a hidden window shows nothing
    m.windowShowsSettings = { false }
    let before = calls()
    m.claudeNotes = 1
    for _ in 0..<3 { m.watchClaude() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(calls() == before, "window not showing Settings: no look")
    // the note goes: nothing again; Check again (force) always looks
    m.windowShowsSettings = { true }; m.claudeNotes = 0
    m.watchClaude(); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(calls() == before, "note gone: no look")
    m.detectClaude(force: true); wait { calls() > before }
    check(calls() == before + 1, "Check again looks")
    // the first-run page on screen looks; off screen it doesn't
    resetHome()
    shellCalls = 0
    let f = SettingsModel()
    check(f.isFirstRun && f.selection == SettingsModel.firstRunID, "first-run page up")
    f.watchClaude(); wait { calls() >= 1 }
    check(calls() == 1, "the first-run page on screen: it looks")
    for _ in 0..<4 { f.watchClaude() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(calls() == 1, "…and backs off")
    shellCalls = 0
    let g = SettingsModel(); g.windowShowsSettings = { false }
    for _ in 0..<3 { g.watchClaude() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(calls() == 0, "the first-run page in a hidden window: no look")
}

// ============ 11. the first-run page is decided at load and stays until Done ============
do {
    resetHome()
    ClaudeLocator.current = none
    // the stuck Mac: a persisted pristine main, ~/.claude not signed in; the sign-in lands in ~/.claude from the page
    try? Store.save([FirstRun.implicitMain])
    let m = SettingsModel()
    check(m.isFirstRun, "stuck Mac: first-run page")
    m.firstRun.signInDir = "~/.claude"; m.firstRun.signInAsked = Date(); m.firstRun.seatAtAsk = nil
    fakeAccount(dir: "~/.claude", uuid: "00000000-0000-4000-8000-000000000011", email: "late.person@example.invalid")
    m.followFirstRun()
    check(m.firstRun.folder == "~/.claude", "the sign-in landed in ~/.claude")
    check(m.isFirstRun && m.selection == SettingsModel.firstRunID, "the page stays: it doesn't vanish mid-flow")
    m.refreshFirstRun()
    check(m.isFirstRun, "…even after the rule is looked at again (sign-in left out while the page is up)")
    check(FirstRun.foundFolders(among: m.accounts).contains { $0.path == "~/.claude" }, "~/.claude is still offered (the pristine main doesn't own it)")
    check(m.commitFirstRun() == nil, "Done")
    check(m.accounts.map(\.name) == ["late.person"] && m.accounts[0].configDir == "~/.claude", "main is gone, one profile on ~/.claude (no clash): \(m.accounts.map(\.name))")
    check(!m.isFirstRun && m.problem == nil, "page gone, no clash problem: \(m.problem ?? "none")")
    // decided at load: an unreadable .claude.json can't flip a redraw
    resetHome()
    fakeAccount(dir: "~/.claude", uuid: "00000000-0000-4000-8000-000000000012", email: "main.person@example.invalid")
    try? Store.save([FirstRun.implicitMain])
    let n = SettingsModel()
    check(!n.isFirstRun && n.selection == SettingsModel.dashboardID, "main with ~/.claude signed in: a normal profile")
    write(".claude.json", "{ broken")
    check(!n.isFirstRun && n.homeSelection == SettingsModel.dashboardID, "the file turns unreadable: reading isFirstRun/homeSelection doesn't flip it")
}

// ============ 8. the pages draw (the render harness looks at them) ============
do {
    resetHome()
    ClaudeLocator.current = none
    let m = SettingsModel()
    let host = NSHostingView(rootView: FirstRunPage(model: m, width: 708).face(.std))
    host.frame = NSRect(x: 0, y: 0, width: 708, height: 900)
    host.layoutSubtreeIfNeeded()
    check(host.fittingSize.height > 200, "the first-run page lays out (\(host.fittingSize))")
}

print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
