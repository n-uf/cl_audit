import AppKit
import SwiftUI
// Stage B1 renders: Settings ▸ a profile ▸ Sessions card, General ▸ Backups; the one-folder model's Switch page in each
// state, the dashboard card with standby accounts and the Accounts card (ONEFOLDER_ONLY=1: those alone); then the later
// stages' pages.
// Sample data only (example.com), a throwaway home, fake profiles, sign-ins, sessions and transcripts.

setbuf(stdout, nil)
BackupPrefs.store = MemoryPrefs()          // never the real ~/Library/Preferences
let out = CommandLine.arguments[1]
let home = NSHomeDirectory()
guard home.hasSuffix("/Checks/.work/render/pages/home"), expand("~") == home else { print("refusing: home is \(home)"); exit(1) }
let fm = FileManager.default
SettingsModel.followsDock = false
RunsMonitor.preview = []

func uuid(_ n: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", n) }
func seat(_ n: Int, _ email: String) -> Seat { Seat(account: uuid(n), organization: uuid(n + 100), email: email) }
let u1 = seat(1, "ultra-1@example.com"), u2 = seat(2, "ultra-2@example.com"), u3 = seat(3, "ultra-3@example.com")
func sign(_ dir: String, _ s: Seat) {
    let d = expand(dir); try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
    let o: [String: Any] = ["accountUuid": s.account, "organizationUuid": s.organization!, "emailAddress": s.email!,
                            "organizationType": "claude_max", "planDisplayName": "Ultra"]
    try! JSONSerialization.data(withJSONObject: ["oauthAccount": o]).write(to: URL(fileURLWithPath: dir == "~/.claude" ? expand("~/.claude.json") : d + "/.claude.json"))
}
sign("~/.claude", u1); sign("~/.claude-ultra-2", u2); sign("~/.claude-ultra-3", u3)

// the usual Claude app's folder: signed in to ultra-1
let wd = expand("~/Library/Application Support/Claude-main")   // the profile's own window data: the real Claude app is not it
let odir = "\(wd)/claude-code-sessions/\(u1.account)/\(u1.organization!)"
let odir2 = "\(wd)/claude-code-sessions/\(u2.account)/\(u2.organization!)"
try! fm.createDirectory(atPath: odir, withIntermediateDirectories: true)
try! fm.createDirectory(atPath: odir2, withIntermediateDirectories: true)
func addEntries(_ from: Int, _ to: Int, archivedBelow: Int) {
    for i in from..<to { fm.createFile(atPath: "\(odir)/local_\(uuid(1000 + i)).json", contents: Data((i < archivedBelow ? #"{"isArchived":true}"# : #"{"isArchived":false}"#).utf8)) }
}
func sparse(_ path: String, _ mb: Int, daysAgo: Int) {
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    fm.createFile(atPath: path, contents: Data(#"{"type":"user"}"#.utf8))
    let h = FileHandle(forWritingAtPath: path)!; try! h.truncate(atOffset: UInt64(mb) * 1_048_576); try! h.close()
    try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(daysAgo) * 86400)], ofItemAtPath: path)
}
func addTranscripts(_ from: Int, _ to: Int) {
    for i in from..<to { sparse(expand("~/.claude/projects/-Users-me-proj\(i % 3)/\(uuid(2000 + i)).jsonl"), 2 + (i * 7) % 38, daysAgo: i == 0 ? 84 : 1 + (i * 3) % 40) }
}
let scope = "\(u1.account)/\(u1.organization!)"
func writeWindow(tasks: Int) {
    fm.createFile(atPath: "\(odir)/scheduled-tasks.json", contents: Data(("{\"scheduledTasks\":[" + (0..<tasks).map { "{\"id\":\"t\($0)\"}" }.joined(separator: ",") + "]}").utf8))
    let prefs: [String: Any] = ["preferences": ["epitaxyPrefs": [
        "dframe-code-sections": [scope: ["sections": [["shown": true], ["shown": true]]]],
        "dframe-group-scopes": [scope: ["groups": [["id": "1"], ["id": "2"]]]]]]]
    try! JSONSerialization.data(withJSONObject: prefs).write(to: URL(fileURLWithPath: "\(wd)/claude_desktop_config.json"))
}
try! JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": u1.account]).write(to: URL(fileURLWithPath: "\(wd)/config.json"))
for i in 0..<4 { fm.createFile(atPath: "\(odir2)/local_\(uuid(1500 + i)).json", contents: Data(#"{"isArchived":false}"#.utf8)) }

try! fm.createDirectory(at: Store.statusFolder, withIntermediateDirectories: true)
func status(_ id: String, _ email: String, week: Double, fable: Double, resetsIn: Double) {
    var st = IconStatus(state: "ok"); st.loginEmail = email; st.expectedEmail = email; st.updatedAt = Date(); st.plan = "Ultra"
    st.weekly = week; st.weeklyResets = Date().addingTimeInterval(resetsIn); st.noFiveHour = true
    st.scoped = [ScopedLimit(name: "Fable", percent: fable, resets: Date().addingTimeInterval(resetsIn))]
    let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
    try! e.encode(st).write(to: Store.statusFolder.appendingPathComponent("\(id).json"))
}
status("main", u1.email!, week: 94, fable: 60, resetsIn: 7 * 3600)

func fixPatch(_ m: SessionsBackup.Manifest, seconds: Double) {   // made-up duration, in our own throwaway manifest
    let f = SessionsBackup.folder(profile: m.profile, place: BackupPrefs.placeURL).appendingPathComponent("\(m.id)/backup.json")
    var j = try! JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
    j["seconds"] = seconds
    try! JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]).write(to: f)
}

/// An old switch's receipt (26.11.13 and earlier wrote them; cl_audit only reads them now), written here as that version did.
func saveReceipt(_ r: SwitchReceipt) {
    let dir = SwitchEngine.root.appendingPathComponent(r.id)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try! enc.encode(r).write(to: dir.appendingPathComponent("receipt.json"))
}

@MainActor func snapshot(_ v: some View, _ name: String, _ w: CGFloat, _ h: CGFloat = 3600) {
    if ProcessInfo.processInfo.environment["ONEFOLDER_ONLY"] != nil, !name.hasPrefix("o") { return }  // the one-folder renders only
    if ProcessInfo.processInfo.environment["B2_ONLY"] != nil, !name.hasPrefix("6") { return }      // stage B2 renders only
    if ProcessInfo.processInfo.environment["E_ONLY"] != nil, !name.hasPrefix("7") { return }       // stage E renders only
    if ProcessInfo.processInfo.environment["E2_ONLY"] != nil, !name.hasPrefix("8") { return }      // stage E2 (the setup row) renders only
    if ProcessInfo.processInfo.environment["E2B_ONLY"] != nil, !name.hasPrefix("9") { return }     // stage E2b (MCP settings, scheduled tasks) renders only
    if ProcessInfo.processInfo.environment["E2C_ONLY"] != nil, !name.hasPrefix("m") { return }     // stage E2c (a move to another Mac) renders only
    if ProcessInfo.processInfo.environment["A_ONLY"] != nil, !["a1-", "a3-", "a4-"].contains(where: name.hasPrefix) { return }   // release A's a1, a3, a4 only
    // the Experimental panel (B6): one case per page that carries it, Std at 460 and 708
    if ProcessInfo.processInfo.environment["EXPERIMENTAL_ONLY"] != nil,
       !(["o1-switch-ready-", "8a-export-setup-zip-", "ma-export-move-", "8c-import-setup-left-out-", "8d-import-setup-added-open-",
          "8e-restore-setup-", "xdp-default-profile-", "xcs-consent-"].contains(where: name.hasPrefix)
         && (name.hasSuffix("-std-w460") || name.hasSuffix("-std-w708") || name.hasPrefix("xdp-") && name.hasSuffix("-std-w340"))) { return }
    _ = NSApplication.shared
    let host = NSHostingView(rootView: v)
    host.frame = NSRect(x: 0, y: 0, width: w, height: h)
    let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(2.5))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/\(name).png"))
    print(name)
}

// ==================================================================== the switch atlas (ATLAS_SWITCH=1)
// Every state of a switch from the account in use to a standby one, on every surface, drawn by the app's own views: each
// state is set up through the app's own paths (the profile's record answered by AccountResolver through resolveNow, the
// runner's phases, the engine's real plan, move, receipt and Undo, FolderRules' noting and linkReached), then each surface
// is drawn from it as the app builds it. Files atlas-<row>-<column>-std.png (Std only); Checks/render/atlas.py composes them
// into one page. Sample data only: profile Main on ann@ (the Claude app and Claude Code), ben@ on standby; Work on cat@.

/// A menu as the app builds it (its NSMenuItems), drawn as its words: separators as lines, a submenu's items indented
/// under it (the ticked one with ✓), disabled items grey, the lit lamp as a green dot. The menu itself (an NSMenu) can't be
/// drawn off screen.
struct AtlasMenu: View {
    struct Row { var text: String; var sep = false; var on = true; var indent = false; var bold = false; var lamp = false; var tick = false }
    let rows: [Row]
    init(_ items: [NSMenuItem]) {
        var out: [Row] = []
        for i in items {
            if i.isSeparatorItem { out.append(Row(text: "", sep: true)); continue }
            out.append(Row(text: i.title + (i.submenu == nil ? "" : "  ›"), on: i.isEnabled, bold: i.attributedTitle != nil, lamp: i.image != nil))
            for s in i.submenu?.items ?? [] {
                out.append(s.isSeparatorItem ? Row(text: "", sep: true)
                           : Row(text: s.title, on: s.isEnabled, indent: true, tick: s.state == .on))
            }
        }
        rows = out
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                if r.sep { Rectangle().fill(Color(white: 0.32)).frame(height: 1).padding(.vertical, 3) }
                else {
                    HStack(spacing: 5) {
                        if r.indent { Text(r.tick ? "✓" : " ").frame(width: 22, alignment: .trailing) }
                        if r.lamp { Circle().fill(Color.green).frame(width: 8, height: 8) }
                        Text(r.text).font(.system(size: 13, weight: r.bold ? .semibold : .regular))
                            .foregroundStyle(r.bold ? Color(red: 0.92, green: 0.27, blue: 0.36) : r.on ? Color.white : Color(white: 0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(10).frame(width: 340, alignment: .leading)
        .background(Color(white: 0.19)).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

@MainActor func atlasSwitch() {
    // never a real `claude`: nothing here may open Terminal or sign in (the runner's start is only reached for a gone folder)
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
    func aseat(_ n: Int, _ email: String) -> Seat { Seat(account: uuid(n), organization: uuid(n + 40), email: email) }
    let ann = aseat(11, "ann@example.com"), ben = aseat(12, "ben@example.com"), cat = aseat(13, "cat@example.com"), dan = aseat(14, "dan@example.com")
    let codeA = "~/.claude-ann", codeW = "~/.claude-cat"
    let wdTilde = "~/Library/Application Support/Claude-atlas"
    let wdA = expand(wdTilde)
    let backups = URL(fileURLWithPath: home + "/atlas-backups")
    /// A new file each time (a new inode), so no memo keyed by size, time and inode keeps the account before.
    func signNew(_ dir: String, _ s: Seat) { try? fm.removeItem(atPath: expand(dir) + "/.claude.json"); sign(dir, s) }
    func appOn(_ s: Seat) {
        let f = "\(wdA)/config.json"
        try? fm.removeItem(atPath: f)
        try! JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": s.account]).write(to: URL(fileURLWithPath: f))
    }
    let benStandby = StandbyAccount(email: ben.email!, seat: ben, id: "kb", plan: "Ultra", lastInUse: Date().addingTimeInterval(-3 * 86400),
                                    lastWeek: 12, lastWeekResets: Date().addingTimeInterval(4 * 86400))
    var main0 = AccountEntry(id: "main", name: "Main", label: "MAIN", configDir: codeA); main0.seat = ann
    main0.desktop = .separate; main0.desktopDataDir = wdTilde; main0.standby = [benStandby]
    var work0 = AccountEntry(id: "work", name: "Work", label: "WORK", configDir: codeW); work0.seat = cat; work0.claudeWindow = false
    try! Store.save([main0, work0])
    let model = SettingsModel()
    model.accounts = [main0, work0]
    let r = model.runner(of: "main")
    let acts = LauncherActions(open: { _ in }, terminal: { _ in }, logIn: { _ in }, mainScreen: {}, settings: {})
    let noop = DetailsActions(openClaude: {}, refresh: {}, settings: {}, logIn: {})
    let dummy = NSObject(), act = Selector(("atlasNoop:"))
    let face = FaceTheme.of(.std)
    func framed(_ v: some View, _ w: CGFloat) -> some View {
        v.environment(\.settingsColumnWidth, w).frame(width: w, alignment: .leading).padding(16).background(Color(white: 0.1))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)    // drawn from the top; trim.py crops the rest
            .environment(\.face, face).environment(\.colorScheme, .dark)
    }
    /// The agent's read: the numbers of the account Claude Code is on, then the record answered again (resolveNow).
    func read(_ email: String, week: Double, resetsIn: Double = 2 * 86400) {
        status("main", email, week: week, fable: 40, resetsIn: resetsIn)
        model.resolveNow("main")
    }
    /// What the folder is signed in to now, read as the app reads it.
    let signedIn: (String) -> Seat? = { Account.signedInSeat(configDir: $0) }
    /// As the runner's end does for an account reached or another one: the move linked when the folder is on the account it
    /// went to (linkReached), the profiles follow their folders (FolderRules.noteAccounts), the record answered again.
    func noteFolder() {
        SwitchEngine.linkReached(model.accounts, signedIn: signedIn)
        model.accounts = FolderRules.noteAccounts(model.accounts, signedIn: signedIn)
        try? Store.save(model.accounts)
        model.resolveNow("main")
    }
    /// Before every row: Main on ann (the Claude app and Claude Code), ben on standby, 6 Code-tab sessions and 2 scheduled
    /// tasks in the window's folder under ann, no switch made yet, ann's week at 40%.
    func base() {
        r.reset()
        for p in [wdA, expand(codeA), expand(codeW), backups.path, SwitchEngine.root.path] { try? fm.removeItem(atPath: p) }
        let src = SwitchEngine.scopeDir(wdA, SeatID(ann))
        try! fm.createDirectory(atPath: src, withIntermediateDirectories: true)
        for i in 0..<6 { fm.createFile(atPath: "\(src)/local_\(uuid(80 + i)).json", contents: Data(#"{"isArchived":false}"#.utf8)) }
        fm.createFile(atPath: "\(src)/scheduled-tasks.json", contents: Data(#"{"scheduledTasks":[{"id":"t1"},{"id":"t2"}]}"#.utf8))
        signNew(codeA, ann); signNew(codeW, cat); appOn(ann)
        model.accounts = [main0, work0]
        try! Store.save([main0, work0])
        r.reset()
        r.preview(.ready, goal: nil, target: benStandby)
        read(ann.email!, week: 40)
    }
    let goal = SwitchRunner.Goal(standby: "kb", wantedSeat: ben, wantedEmail: ben.email!, from: ann, started: Date().addingTimeInterval(-75))
    func plan() -> SwitchPlan? {
        if case .success(let p) = SwitchEngine.plan(model.accounts[0], standby: benStandby, owned: []) { return p }
        print("atlas: no plan"); return nil
    }
    /// The engine's real move (a backup first, then the sessions and tasks), with the window "closed" for `closedFor` asks
    /// (nil: all of them): the receipt it leaves.
    func move(closedFor: Int? = nil) -> SwitchReceipt? {
        guard let p = plan() else { return nil }
        var asked = 0
        do { try SwitchEngine.run(p, windowClosed: { asked += 1; return closedFor.map { asked <= $0 } ?? true }, backups: backups) }
        catch { print("atlas: the move stopped: \(error)") }
        return SwitchEngine.receipts(profile: "main").first
    }

    // ---- the surfaces, each as the app builds it from the state as it stands
    func draw(_ row: String, page: Bool, alert: (title: String, body: String, buttons: [String])? = nil) {
        let now = Date()
        let e = model.accounts[0]
        // the menu bar icon's menu (MenuBarItems: the agent's Profile, then menuNeedsUpdate's items)
        let rec = Store.status(for: e)
        let p = MenuBarItems.Profile(entry: e, usage: Usage.of(rec), problem: rec?.problem, needsLogin: MenuBarItems.needsLogin(rec),
                                     view: AccountView.of(Store.status(e.id)))
        var mb: [NSMenuItem] = []
        func info(_ s: String) -> NSMenuItem { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
        func item(_ s: String) -> NSMenuItem { let i = NSMenuItem(title: s, action: act, keyEquivalent: ""); i.target = dummy; return i }
        if let u = p.usage { mb.append(info("Updated \(DetailsFormat.ago(u.fetchedAt)) · \(u.source)")) }
        if let why = p.problem { mb.append(info(why)) }
        mb.append(.separator())
        let mbLines = SwitchMenu.lines(p.entry.listed(by: p.view), now: now)
        let mbFull = p.usage.flatMap { AtLimit.blocker(fiveHour: $0.fiveHour, fiveHourResets: $0.fiveHourResets, weekly: $0.weekly,
                                                       weeklyResets: $0.weeklyResets, now: now) } != nil
        var mbSwitches = SwitchMenu.group(p.view, lines: mbLines, inUseUsed: p.usage?.weekly ?? p.usage?.fiveHour,
                                          inUseWeek: p.usage?.weekly != nil, target: dummy, action: act)
        if mbFull, let best = SwitchMenu.best(mbLines) { mbSwitches.insert(SwitchMenu.bestItem(best, target: dummy, action: act), at: 0) }
        if !mbSwitches.isEmpty { mb += mbSwitches; mb.append(.separator()) }
        mb.append(item("Quick chat"))
        if e.claudeWindow { mb.append(item("Open Claude window")) }
        mb.append(item("Refresh now"))
        if p.needsLogin { mb.append(item("Log in…")) }
        mb += [.separator(), item("Dashboard"), item("Profile settings…"), .separator(), item("Hide from the menu bar")]
        let menuBar = VStack(alignment: .leading, spacing: 6) {
            MenuBarRow(profile: p, now: now).frame(width: 340).background(Color(white: 0.19)).clipShape(RoundedRectangle(cornerRadius: 9))
            AtlasMenu(mb)
        }
        snapshot(framed(menuBar, 460), "atlas-\(row)-menubar-std", 492, 1400)

        // the Dock icon (its tile), its menu (applicationDockMenu's items) and its usage panel (detailsInfo), all from the
        // Dock app's own copy of the record: Store.status(for:)
        let st = Store.status(for: e)
        let usage = Usage.of(st), view = AccountView.of(st)
        let expired = st?.state == "expired", noLogin = st?.state == "noLogin"
        let expected = st?.expectedEmail ?? Account(e).expectedEmail()
        let mismatch: Bool = { guard let a = st?.loginEmail, let b = expected else { return false }; return a.lowercased() != b.lowercased() }()
        let tile = TileModel(label: e.label, fiveHour: usage?.fiveHour, weekly: usage?.weekly, stale: expired || noLogin, style: e.style,
                             warn: mismatch, tint: e.color, frame: e.frame,
                             countdown: AtLimit.tileCountdown(fiveHour: usage?.fiveHour, fiveHourResets: usage?.fiveHourResets,
                                                              weekly: usage?.weekly, weeklyResets: usage?.weeklyResets))
        var dm: [NSMenuItem] = []
        let top = info(SwitchMenu.dockTitle(name: e.name, view, plan: st?.plan.map(Account.planWords)))
        if view.lit, SwitchMenu.inUseShort(view) != nil { top.image = SwitchMenu.lamp() }
        dm.append(top)
        if let n = view.line { dm.append(info(n)) }
        dm.append(.separator())
        let dLines = SwitchMenu.lines(e.listed(by: view))
        if let full = AtLimit.blocker(fiveHour: usage?.fiveHour, fiveHourResets: usage?.fiveHourResets, weekly: usage?.weekly, weeklyResets: usage?.weeklyResets) {
            let i = info("\(full.title) · \(full.both())")
            i.attributedTitle = NSAttributedString(string: i.title)
            dm.append(i)
            if let best = SwitchMenu.best(dLines) { dm.append(SwitchMenu.bestItem(best, target: dummy, action: act)) }
        }
        func line(_ title: String, _ v: Double?, _ at: Date?) { dm.append(info("\(title): \(Painter.pct(v))" + (at.map { " · resets \(AppDelegate.when($0))" } ?? ""))) }
        if usage?.noFiveHour != true { line("5-hour limit", usage?.fiveHour, usage?.fiveHourResets) }
        line("Weekly limit", usage?.weekly, usage?.weeklyResets)
        for s in e.showFable ? usage?.scoped ?? [] : [] {
            if AtLimit.isFull(s.percent), let at = s.resets { dm.append(info("\(s.name) weekly limit: full · \(TimeWords.back(at))")) }
            else { line("\(s.name) weekly limit", s.percent, s.resets) }
        }
        if let usage { dm.append(info("Updated \(AppDelegate.ago(usage.fetchedAt)) · \(usage.source)")) }
        if let why = st?.problem { dm.append(info(why)) }
        if let note = st?.renewNote { dm.append(info(note)) }
        if Privacy.shared.show || st?.loginEmail == nil { dm.append(info("Login: \(st?.loginEmail ?? "checking…")")) }
        if mismatch, let want = expected {
            dm.append(info(Privacy.shared.show ? "⚠︎ This folder is set up for \(want)" : "⚠︎ This folder is set up for a different account"))
        }
        if mismatch || noLogin || expired { dm.append(item("Log in…")) }
        dm.append(.separator())
        let dSwitches = SwitchMenu.group(view, lines: dLines, inUseUsed: usage?.weekly ?? usage?.fiveHour, inUseWeek: usage?.weekly != nil,
                                         target: dummy, action: act)
        if !dSwitches.isEmpty { dm += dSwitches; dm.append(.separator()) }
        dm.append(item("Quick chat"))
        if e.claudeWindow { dm.append(item("Open Claude window")) }
        dm += [item("Refresh now"), .separator(), item("Dashboard"), item("Profile settings…")]
        let panel = DetailsInfo(name: e.name, icon: Painter.image(tile, pixels: 128), login: st?.loginEmail, expected: expected, mismatch: mismatch,
                                plan: st?.plan, fiveHour: usage?.fiveHour, fiveHourResets: usage?.fiveHourResets, weekly: usage?.weekly,
                                weeklyResets: usage?.weeklyResets, updated: usage?.fetchedAt, source: usage?.source, problem: st?.problem,
                                renewNote: st?.renewNote, needsLogin: mismatch || noLogin || expired,
                                scoped: e.showFable ? usage?.scoped ?? [] : [], credits: usage?.credits,
                                noFiveHour: st?.noFiveHour == true, noNumbers: DetailsInfo.noNumbersWords(st)).taking(view)
        let dock = VStack(alignment: .leading, spacing: 10) {
            Image(nsImage: Painter.image(tile, pixels: 128)).resizable().frame(width: 96, height: 96)
            AtlasMenu(dm)
            DetailsView(info: panel, actions: noop).fixedSize()       // the panel at its own size, as it opens by the Dock
        }
        snapshot(framed(dock, 520), "atlas-\(row)-dock-std", 552, 2000)

        // the dashboard card at its own height; Settings ▸ the profile from the top through its Sessions card (Profile,
        // Claude Code with the accounts, Sessions with a stopped switch's Undo and Leave it as it is)
        snapshot(framed(AccountCard(row: AccountRow(entry: e, status: Store.status(for: e)), actions: acts).frame(width: 460)
                            .fixedSize(horizontal: false, vertical: true), 460),
                 "atlas-\(row)-card-std", 492, 1000)
        snapshot(framed(AccountSettings(entry: .constant(e), model: model, width: 460).frame(height: 1180, alignment: .top).clipped(), 460),
                 "atlas-\(row)-settings-std", 492, 1300)
        if page {
            let target = e.standby.first { $0.id == "kb" } ?? benStandby
            snapshot(framed(SwitchPage(entry: e, standby: target, model: model, runner: r, width: 708), 708), "atlas-\(row)-switch-std", 740, 2400)
        }
        if let a = alert {
            let note = VStack(alignment: .leading, spacing: 5) {
                Text("cl_audit").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(white: 0.6))
                Text(a.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                Text(a.body).font(.system(size: 13)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(a.buttons, id: \.self) { b in
                        Text(b).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Color(white: 0.32)).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }.padding(.top, 4)
            }
            .padding(14).frame(width: 360, alignment: .leading).background(Color(white: 0.22)).clipShape(RoundedRectangle(cornerRadius: 14))
            snapshot(framed(note, 460), "atlas-\(row)-alert-std", 492, 500)
        }
    }

    // 01 before: ann in use (the Claude app and Claude Code), ben on standby
    base()
    draw("01", page: false)
    // 02 ann's week full: the agent's full-limit alert (Reader.checkThresholds' words), ben offered first everywhere
    read(ann.email!, week: 100, resetsIn: 7 * 3600)
    if let st = Store.status(for: model.accounts[0]), let resets = st.weeklyResets {
        let e = model.accounts[0]
        let back = "Back \(UsageReader.backWords(resets)), in \(TimeWords.countdown(resets))"
        let offer = e.bestOffer()
        let body = SwitchWords.alertLine(offer, accounts: e.standby.count).map { "\(back). \($0)" } ?? back
        draw("02", page: true, alert: ("Claude \(e.name): weekly limit full", body, offer == nil ? [] : [SwitchWords.button]))
    }
    // 03 the Switch page open: now ann, to ben (the week back to where it was, so the row shows the page, not the limit)
    read(ann.email!, week: 40)
    r.preview(.ready, goal: nil, target: benStandby)
    draw("03", page: true)
    // 04 switching: a the window closing, b the move, c the sign-in waited for (the move made for real: its receipt)
    let p4 = plan()
    r.preview(.closing, goal: goal, target: benStandby, planned: p4)
    draw("04a", page: true)
    r.preview(.moving, goal: goal, target: benStandby, planned: p4)
    draw("04b", page: true)
    let moved = move()
    r.preview(.waiting, goal: goal, target: benStandby, planned: p4, receipt: moved, seen: ann)
    let w = SwitchWaiting.words(profile: model.accounts[0].name, phase: .waiting)
    draw("04c", page: true, alert: w.map { ($0.title, $0.body, [SwitchWaiting.showButton, SwitchWaiting.cancelButton]) })
    // 05 done: Claude Code signed in as ben, the Claude app still on ann (after the agent's next read: ben's numbers)
    signNew(codeA, ben)
    noteFolder()
    read(ben.email!, week: 12, resetsIn: 4 * 86400)
    r.preview(.reached, goal: goal, target: benStandby, planned: p4, receipt: moved.flatMap { SwitchEngine.load($0.id) }, seen: ben)
    draw("05", page: true)
    // 06 the Claude app signed in to ben too: ben in use, ann on standby
    appOn(ben)
    model.resolveNow("main")
    draw("06", page: true)
    // 07 the sign-in landed on another account (dan, no profile's): the profile follows the folder
    base()
    let p7 = plan()
    let moved7 = move()
    signNew(codeA, dan)
    noteFolder()
    read(dan.email!, week: 55, resetsIn: 5 * 86400)
    r.preview(.other(dan.email!), goal: goal, target: benStandby, planned: p7, receipt: moved7.flatMap { SwitchEngine.load($0.id) }, seen: dan)
    draw("07", page: true)
    // 08 timed out: the sessions moved, no sign-in in 10 minutes (the folder still on ann)
    base()
    let p8 = plan()
    let moved8 = move()
    let late = SwitchRunner.Goal(standby: "kb", wantedSeat: ben, wantedEmail: ben.email!, from: ann, started: Date().addingTimeInterval(-11 * 60))
    r.preview(.timedOut, goal: late, target: benStandby, planned: p8, receipt: moved8, seen: ann)
    draw("08", page: true)
    // 09 stopped part way: the window opened during the move after two sessions (the engine stops; its receipt is open)
    base()
    let p9 = plan()
    let stopped = move(closedFor: 4)
    r.preview(.failed(SwitchError.windowOpen.description), goal: goal, target: benStandby, planned: p9, receipt: stopped, failedAt: .move)
    draw("09", page: true)
    // 10 partly undone: one moved session changed since, so Undo leaves it (the runner's words for it), the rest back;
    // the Sessions card offers Undo again and Leave it as it is
    if let s = stopped, let placed = s.steps.first(where: { $0.kind == .entry && $0.done }) {
        fm.createFile(atPath: placed.path, contents: Data(#"{"isArchived":false,"title":"changed"}"#.utf8))
        do {
            let back = try SwitchEngine.undo(s.id, windowClosed: { true })
            r.preview(back.undone != nil ? .undone : .failed(SwitchRunner.partlyWords(back)), goal: goal, target: benStandby, planned: p9,
                      receipt: back, failedAt: .move)
        } catch { print("atlas: undo: \(error)") }
    } else { print("atlas: row 9 left no moved session") }
    draw("10", page: true)
    // 11 the folder gone: the runner's own start refuses before anything
    base()
    try? fm.removeItem(atPath: expand(codeA))
    r.reset()
    if ClaudeCLI.goneLine(codeA) != nil { r.start(benStandby) } else { print("atlas: the folder isn't gone; start not called") }
    draw("11", page: true)
    // 12 cancelled before starting: Cancel while the window was asked to close (the runner's own cancel), nothing moved
    base()
    r.preview(.closing, goal: goal, target: benStandby, planned: plan())
    r.cancel()
    draw("12", page: true)
}

if ProcessInfo.processInfo.environment["ATLAS_SWITCH"] != nil {
    MainActor.assumeIsolated { atlasSwitch() }
    print("done"); exit(0)
}

// ==================================================================== the split (SPLIT_ONLY=1, B8)
// The Claude app on pat@, Claude Code on mo@ with mo's week full: the Main card, the Dock icon with its panel and the menu
// bar strip with its row, drawn from the records as the app keeps them (the headline one, and Claude Code's own for its
// labelled line). Std, 340, 460 and 708. Files split-<surface>-std-w<width>.png.
@MainActor func splitRenders() {
    let pat = Seat(account: uuid(31), organization: uuid(71), email: "pat@example.com")
    let mo = Seat(account: uuid(32), organization: uuid(72), email: "mo@example.com")
    var e = AccountEntry(id: "main", name: "Main", label: "MAIN", configDir: "~/.claude-split"); e.seat = mo
    e.desktop = .separate; e.desktopDataDir = "~/Library/Application Support/Claude-split"
    e.standby = [StandbyAccount(email: pat.email!, seat: pat, id: "kp", plan: "Max", lastInUse: Date().addingTimeInterval(-86400))]
    sign(e.configDir, mo)
    try? fm.createDirectory(atPath: expand(e.desktopDataDir), withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": pat.account]).write(to: URL(fileURLWithPath: expand(e.desktopDataDir) + "/config.json"))
    try! Store.save([e])
    let now = Date()
    var rec = IconStatus(state: "ok"); rec.loginEmail = mo.email; rec.numbersOwner = mo.email; rec.expectedEmail = mo.email
    rec.weekly = 100; rec.weeklyResets = now.addingTimeInterval(41 * 3600); rec.noFiveHour = true; rec.plan = "Ultra"; rec.updatedAt = now
    rec.source = "Anthropic"
    rec.resolved = AccountResolver.resolve(e, among: [e], app: AppSignIn.cached(for: e), code: mo, loginEmail: mo.email, names: [:], now: now)
    _ = Store.writeStatus("main", rec)
    let head = Store.status(for: e), own = Store.status(for: e, headline: false)
    print("split:", SplitUsage.of(head) != nil ? "yes" : "NO (the app's account wasn't read)")
    let face = FaceTheme.of(.std)
    func framed(_ v: some View, _ w: CGFloat) -> some View {
        v.environment(\.settingsColumnWidth, w).frame(width: w, alignment: .leading).padding(16).background(Color(white: 0.1))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.face, face).environment(\.colorScheme, .dark)
    }
    let acts = LauncherActions(open: { _ in }, terminal: { _ in }, logIn: { _ in }, mainScreen: {}, settings: {})
    let usage = Usage.of(head), view = AccountView.of(head)
    let tile = TileModel(label: e.label, fiveHour: usage?.fiveHour, weekly: usage?.weekly, stale: false, style: e.style, warn: false,
                         tint: e.color, frame: e.frame,
                         countdown: AtLimit.tileCountdown(fiveHour: usage?.fiveHour, fiveHourResets: usage?.fiveHourResets,
                                                          weekly: usage?.weekly, weeklyResets: usage?.weeklyResets))
    var panel = DetailsInfo(name: e.name, icon: Painter.image(tile, pixels: 128), login: head?.loginEmail, expected: head?.expectedEmail,
                            mismatch: false, plan: head?.plan, fiveHour: usage?.fiveHour, fiveHourResets: usage?.fiveHourResets,
                            weekly: usage?.weekly, weeklyResets: usage?.weeklyResets, updated: head?.updatedAt, source: usage?.source,
                            problem: head?.problem, renewNote: nil, needsLogin: false, noFiveHour: head?.noFiveHour == true,
                            noNumbers: DetailsInfo.noNumbersWords(head)).taking(view)
    panel.splitKey = SplitUsage.of(head)?.key
    let profileItem = MenuBarItems.Profile(entry: e, usage: usage, problem: head?.problem, needsLogin: false, view: view, split: SplitUsage.of(head))
    let glyph = MenuBarGlyph(look: e.menuBarLook, item: MenuBarItems.item(profileItem, now: now)).image(dark: true)
    for w in [CGFloat(340), 460, 708] {
        snapshot(framed(AccountCard(row: AccountRow(entry: e, status: head, codeStatus: own), actions: acts).frame(width: min(w, 460))
                            .fixedSize(horizontal: false, vertical: true), w), "split-card-std-w\(Int(w))", w + 32, 1000)
        let dock = VStack(alignment: .leading, spacing: 10) {
            Image(nsImage: Painter.image(tile, pixels: 128)).resizable().frame(width: 96, height: 96)
            DetailsView(info: panel, actions: DetailsActions(openClaude: {}, refresh: {}, settings: {}, logIn: {})).fixedSize()
        }
        snapshot(framed(dock, w), "split-dock-std-w\(Int(w))", w + 32, 1400)
        let bar = VStack(alignment: .leading, spacing: 10) {
            Image(nsImage: glyph).padding(6).background(Color(white: 0.25)).clipShape(RoundedRectangle(cornerRadius: 5))
            MenuBarRow(profile: profileItem, now: now).frame(width: min(w, 320))
        }
        snapshot(framed(bar, w), "split-menubar-std-w\(Int(w))", w + 32, 600)
    }
    // the split as a switch waiting for the Claude app: the newest switch went from pat to mo (linked), the app still on
    // pat: the switched line, no key
    var moved = SwitchReceipt(id: SwitchEngine.receiptID(now, "main"), profile: "main", standby: "km", dataDir: "/x",
                              from: SeatID(pat), to: SeatID(mo), started: now.addingTimeInterval(-600))
    moved.steps = [SwitchReceipt.Step(kind: .entry, path: "/x/a", sha: nil, parked: nil, original: nil, done: true)]
    moved.linked = now.addingTimeInterval(-300)
    rec.resolved = AccountResolver.resolve(e, among: [e], app: AppSignIn.cached(for: e), code: mo, loginEmail: mo.email, names: [:],
                                           newestSwitch: moved, now: now)
    _ = Store.writeStatus("main", rec)
    let swHead = Store.status(for: e)
    print("switched:", SplitUsage.of(swHead)?.switched == true ? "yes" : "NO")
    snapshot(framed(AccountCard(row: AccountRow(entry: e, status: swHead, codeStatus: Store.status(for: e, headline: false)), actions: acts)
                        .frame(width: 460).fixedSize(horizontal: false, vertical: true), 460), "split-card-switched-std-w460", 492, 1000)
}

if ProcessInfo.processInfo.environment["SPLIT_ONLY"] != nil {
    MainActor.assumeIsolated { splitRenders() }
    print("done"); exit(0)
}

// ==================================================================== the Dock icon's preview (DOCKPREVIEW_ONLY=1, ProfileCore step 0)
// The preview Settings' tile and the Dock's tile draw (`preview(_:status:)`), from each record as the app keeps it: a good read, a
// signed-out, an expired and a split profile (no numbers, not the samples 23 % and 41 %), a login on another account (the warning
// dot), and no record at all (the Dock: none; Settings' tile: the samples). Std, 340 and 460. Files dockpreview-std-w<width>.png.
@MainActor func dockPreviewRenders() {
    let now = Date()
    func entry(_ id: String, _ label: String) -> AccountEntry {
        var e = AccountEntry(id: id, name: id, label: label, configDir: "~/.claude-\(id)"); e.desktop = .separate
        e.desktopDataDir = "~/Library/Application Support/Claude-\(id)"; return e
    }
    func record(_ state: String, _ who: Seat, week: Double?, five: Double?) -> IconStatus {
        var r = IconStatus(state: state); r.loginEmail = state == "noLogin" ? nil : who.email; r.expectedEmail = who.email
        r.weekly = week; r.fiveHour = five; r.updatedAt = now.addingTimeInterval(-60); r.source = "Anthropic"
        r.weeklyResets = now.addingTimeInterval(2 * 86400); r.fiveHourResets = now.addingTimeInterval(3600); r.plan = "Max"
        return r
    }
    let pat = Seat(account: uuid(41), organization: uuid(81), email: "pat@example.com")
    let mo = Seat(account: uuid(42), organization: uuid(82), email: "mo@example.com")
    let okE = entry("dok", "OK"), outE = entry("dout", "OUT"), expE = entry("dexp", "EXP"), splE = entry("dspl", "SPL"),
        mixE = entry("dmix", "MIX"), noneE = entry("dnone", "NEW")
    _ = Store.writeStatus(okE.id, record("ok", pat, week: 64, five: 12))
    _ = Store.writeStatus(outE.id, record("noLogin", pat, week: 61, five: 22))      // numbers saved, then signed out
    _ = Store.writeStatus(expE.id, record("expired", pat, week: 90, five: 100))
    var mix = record("ok", pat, week: 35, five: 20); mix.loginEmail = mo.email       // Claude Code on another account than the folder names
    _ = Store.writeStatus(mixE.id, mix)
    sign(splE.configDir, mo)
    try? fm.createDirectory(atPath: expand(splE.desktopDataDir), withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": pat.account]).write(to: URL(fileURLWithPath: expand(splE.desktopDataDir) + "/config.json"))
    var spl = record("ok", mo, week: 100, five: nil); spl.numbersOwner = mo.email; spl.noFiveHour = true
    spl.resolved = AccountResolver.resolve(splE, among: [splE], app: AppSignIn.cached(for: splE), code: mo, loginEmail: mo.email, names: [:], now: now)
    _ = Store.writeStatus(splE.id, spl)
    print("split:", SplitUsage.of(Store.status(for: splE)) != nil ? "yes" : "NO (the app's account wasn't read)")
    let face = FaceTheme.of(.std)
    func tile(_ e: AccountEntry, _ what: String, sample: Bool = false, note: String? = nil) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: preview(e, status: Store.status(for: e), sample: sample)).resizable().frame(width: 96, height: 96)
            Text(what).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
            Text(note ?? " ").font(.system(size: 10)).foregroundColor(Color(white: 0.65)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(width: 96)
    }
    for w in [CGFloat(340), 460] {
        let all = VStack(alignment: .leading, spacing: 14) {
            Text("The Dock icon's preview, from each profile's record").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            HStack(alignment: .top, spacing: 10) {
                tile(okE, "Good read", note: "12 % and 64 %")
                tile(outE, "Signed out", note: "saved numbers dropped")
                tile(expE, "Expired", note: "saved numbers dropped")
            }
            HStack(alignment: .top, spacing: 10) {
                tile(splE, "Split", note: "app on pat@, Claude Code on mo@")
                tile(mixE, "Other account", note: "the warning dot")
                tile(noneE, "No record", note: "Dock: none")
            }
            HStack(alignment: .top, spacing: 10) {
                tile(noneE, "No record", sample: true, note: "Settings' tile: samples")
            }
        }
        snapshot(VStack { all }.frame(width: w, alignment: .leading).padding(16).background(Color(white: 0.1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .environment(\.face, face).environment(\.colorScheme, .dark), "dockpreview-std-w\(Int(w))", w + 32, 640)
    }
}

if ProcessInfo.processInfo.environment["DOCKPREVIEW_ONLY"] != nil {
    MainActor.assumeIsolated { dockPreviewRenders() }
    print("done"); exit(0)
}

MainActor.assumeIsolated {
    // (named "Main": the app puts "Claude " before a profile's name itself)
    var main = AccountEntry(id: "main", name: "Main", label: "MAIN", configDir: "~/.claude"); main.seat = u1
    main.desktop = .separate; main.desktopDataDir = "~/Library/Application Support/Claude-main"
    let k2 = StandbyAccount(email: u2.email!, seat: u2, id: "k2", plan: "Ultra", lastInUse: Date().addingTimeInterval(-3 * 86400),
                            lastWeek: 12, lastWeekResets: Date().addingTimeInterval(4 * 86400))
    let k3 = StandbyAccount(email: u3.email!, seat: u3, id: "k3", plan: "Max", lastInUse: Date().addingTimeInterval(-9 * 86400),
                            lastWeek: 100, lastWeekResets: Date().addingTimeInterval(2 * 86400))
    main.standby = [k2, k3]
    var empty = main; empty.id = "nobackups"      // the same profile, but no backup of it yet
    try! JSONEncoder().encode(ConfigFile(accounts: [main])).write(to: Store.configURL)
    let model = SettingsModel()
    model.accounts = [main]

    // ---- the backups: an older one, one by Back up now, one an old switch made (26.11.13 and earlier)
    let src = SessionsBackup.Source(main)
    let place = BackupPrefs.placeURL
    let now = Date()
    addEntries(0, 22, archivedBelow: 6); addTranscripts(0, 19); writeWindow(tasks: 2)
    let mOld = try! SessionsBackup.make(src, kind: .manual, place: place, now: now.addingTimeInterval(-20 * 86400)); fixPatch(mOld, seconds: 2)
    addEntries(22, 41, archivedBelow: 9); addTranscripts(19, 37); writeWindow(tasks: 3)
    let mMan = try! SessionsBackup.make(src, kind: .manual, place: place, now: now.addingTimeInterval(-2 * 86400 - 3600)); fixPatch(mMan, seconds: 3)
    let rid = SessionsBackup.newID(now.addingTimeInterval(-86400)) + "-main"
    var rc = SwitchReceipt(id: rid, profile: "main", standby: "k2", dataDir: wd, from: SeatID(u1), to: SeatID(u2), started: now.addingTimeInterval(-86400))
    let mSw = try! SessionsBackup.make(src, kind: .beforeSwitch(rid), transcripts: true, place: place, now: now.addingTimeInterval(-86400 - 7200)); fixPatch(mSw, seconds: 4)
    rc.backup = mSw.id; rc.backupPlace = place.path
    rc.steps = (0..<24).map { _ in SwitchReceipt.Step(kind: .entry, path: "/x", sha: nil, parked: "/p", original: "/o", done: true) }
    var saved = rc; saved.linked = now.addingTimeInterval(-86400 + 600)      // a switch that finished: not "stopped half way"
    saveReceipt(saved)
    print("backups:", mOld.id, mMan.id, mSw.id)

    let bgDark = Color(white: 0.1), bgLight = Color(white: 0.84)
    @MainActor func framed(_ v: some View, _ f: Face, _ w: CGFloat, column: CGFloat? = nil) -> some View {
        let face = FaceTheme.of(f)
        return v.environment(\.settingsColumnWidth, column ?? w)
            .frame(width: w).padding(16)
            .background(face.light ? bgLight : bgDark)
            .environment(\.face, face).environment(\.colorScheme, face.light ? .light : .dark)
    }
    let widths: [(String, CGFloat)] = [("w460", 460), ("w340", 340)]

    // the default-profile page (its Experimental panel first): Main's own window as the one that becomes the usual app's
    if ProcessInfo.processInfo.environment["EXPERIMENTAL_ONLY"] != nil {
        let dpr = DefaultProfileRunner(situation: DefaultProfile.Situation(kind: .windowOnly, old: main, target: nil), model: model)
        for w in [CGFloat(340), 460, 708] {          // (340: its strip's short form fits)
            snapshot(framed(DefaultProfilePage(model: model, runner: dpr, width: w, counts: DefaultProfile.Preview(), importCarried: false), .std, w),
                     "xdp-default-profile-std-w\(Int(w))", w + 32, 3000)
        }
        // the consent sheet before a risky run: the box off (Continue dimmed), then ticked
        for (tag, on) in [("unticked", false), ("ticked", true)] { for w in [CGFloat(460), 708] {
            snapshot(framed(ExperimentalConsent(flow: "Account switching", onCancel: {}, onContinue: {}, understood: on).frame(width: w), .std, w),
                     "xcs-consent-\(tag)-std-w\(Int(w))", w + 32, 900)
        } }
    }

    // a. the one account answer (AccountResolver): every surface from the same record, side by side, for "the Claude app and
    // Claude Code on different accounts" and "the same account"; the Dock panel before its first read and after; a standby
    // account whose kept sign-in ran out
    let aWidths: [(String, CGFloat)] = [("w340", 340), ("w460", 460), ("w708", 708)]
    let acts = LauncherActions(open: { _ in }, terminal: { _ in }, logIn: { _ in }, mainScreen: {}, settings: {})
    let noop = DetailsActions(openClaude: {}, refresh: {}, settings: {}, logIn: {})
    // the record as it is before each run of record cases (taken again before the one-folder cards below), put back after
    var plainRecord = Store.status("main")
    for (tag, app) in [("a1-surfaces-different", AppSignIn.Login(account: u2.account, org: u2.organization, state: .known, source: "log", at: now)),
                       ("a2-surfaces-same", AppSignIn.Login(account: u1.account, org: u1.organization, state: .known, source: "log", at: now))] {
        var rec = plainRecord ?? IconStatus(state: "ok")
        rec.resolved = AccountResolver.resolve(main, among: [main], app: app, code: u1, loginEmail: u1.email, names: [:])
        _ = Store.writeStatus("main", rec)
        let st = Store.status(for: main)
        let v = AccountView.of(st)
        let usage = Usage(fiveHour: st?.fiveHour, fiveHourResets: st?.fiveHourResets, weekly: st?.weekly, weeklyResets: st?.weeklyResets,
                          fetchedAt: now, source: "test", noFiveHour: st?.noFiveHour == true)
        let mp = MenuBarItems.Profile(entry: main, usage: usage, view: v)
        let panel = DetailsInfo(name: main.name, icon: NSImage(size: NSSize(width: 64, height: 64)), login: st?.loginEmail, expected: nil, mismatch: false,
                                plan: st?.plan, fiveHour: st?.fiveHour, fiveHourResets: st?.fiveHourResets, weekly: st?.weekly, weeklyResets: st?.weeklyResets,
                                updated: now.addingTimeInterval(-60), source: nil, problem: nil, renewNote: nil, needsLogin: false).taking(v)
        for f in [Face.std, .silver] { for (wn, w) in aWidths {
            let col = VStack(alignment: .leading, spacing: 12) {
                Text("Menu bar").font(.caption.bold())
                MenuBarRow(profile: mp, now: now).frame(width: min(w, 320))
                Text("Dock menu").font(.caption.bold())
                VStack(alignment: .leading, spacing: 3) {
                    Text(SwitchMenu.dockTitle(name: main.name, v, plan: st?.plan)); if let l = v.line { Text(l).foregroundStyle(.secondary) }
                }.font(.system(size: 13))
                Text("Dock panel").font(.caption.bold())
                DetailsView(info: panel, actions: noop).frame(width: min(w, 340))
                Text("Card").font(.caption.bold())
                AccountCard(row: AccountRow(entry: main, status: st), actions: acts).frame(width: min(w, 460))
                Text("Quick chat").font(.caption.bold())
                Text("\(main.name) · " + (QuickChatTarget(main).email ?? "no account")).font(.system(size: 12))
                Text("Settings ▸ Accounts").font(.caption.bold())
                AccountSettings(entry: .constant(main), model: model, width: w)
            }
            snapshot(framed(col, f, w), "\(tag)-\(f.rawValue)-\(wn)", w + 32, 4200)
        } }
    }
    // the Dock panel before its first read, and after
    for (tag, updated) in [("a3-panel-reading", Date?.none), ("a4-panel-updated", Date?.some(now.addingTimeInterval(-60)))] {
        let info = DetailsInfo(name: main.name, icon: NSImage(size: NSSize(width: 64, height: 64)), login: u1.email, expected: nil, mismatch: false,
                               plan: "Ultra", fiveHour: nil, fiveHourResets: nil, weekly: updated == nil ? nil : 42, weeklyResets: now.addingTimeInterval(3 * 86400),
                               updated: updated, source: nil, problem: nil, renewNote: nil, needsLogin: false, noFiveHour: true)
            .taking(AccountView(label: u1.email, numbersOwner: u1.email, line: nil, lit: true, clash: nil))
        for f in [Face.std, .silver] { for (wn, w) in aWidths {
            snapshot(framed(DetailsView(info: info, actions: noop).frame(width: min(w, 340)), f, w), "\(tag)-\(f.rawValue)-\(wn)", w + 32, 900)
        } }
    }
    // a standby account whose kept sign-in ran out: no numbers, when they were last read
    var expired = IconStatus(state: "expired"); expired.loginEmail = u2.email; expired.weekly = 97; expired.updatedAt = now.addingTimeInterval(-3 * 86400)
    let keptStandby = Store.status("main~k2")
    _ = Store.writeStatus("main~k2", expired)
    try? fm.createDirectory(atPath: expand("~/.claude-ultra-2"), withIntermediateDirectories: true)
    for f in [Face.std, .silver] { for (wn, w) in aWidths {
        snapshot(framed(AccountSettings(entry: .constant(main), model: model, width: w), f, w), "a5-standby-expired-\(f.rawValue)-\(wn)", w + 32, 4200)
    } }
    if let k = keptStandby { _ = Store.writeStatus("main~k2", k) }
    if let p = plainRecord { _ = Store.writeStatus("main", p) }

    // 1. Sessions card with 3 backups; 2. with none
    for f in [Face.std, .silver] { for (wn, w) in widths {
        snapshot(framed(SessionsCard(entry: main, model: model), f, w), "1-sessions-3-backups-\(f.rawValue)-\(wn)", w + 32)
        snapshot(framed(SessionsCard(entry: empty, model: model), f, w), "2-sessions-none-\(f.rawValue)-\(wn)", w + 32)
    } }

    // 3. General: the whole column (cropped later): default place, then a custom one
    for f in [Face.std, .silver] { for (wn, w) in widths {
        snapshot(framed(DashboardSettings(width: w), f, w), "3a-general-default-\(f.rawValue)-\(wn)", w + 32, 4200)
    } }
    BackupPrefs.shared.place = "~/Documents/Claude backups/cl_audit"
    for f in [Face.std, .silver] { for (wn, w) in widths {
        snapshot(framed(DashboardSettings(width: w), f, w), "3b-general-custom-\(f.rawValue)-\(wn)", w + 32, 4200)
    } }
    BackupPrefs.shared.place = ""

    // o. the one-folder model: the Switch page in each state, the dashboard card with standby accounts, the Accounts card
    // (Add account's address row, the folders from before), at 340, 460 and 708, Std and Silver
    let oWidths: [(String, CGFloat)] = [("w340", 340), ("w460", 460), ("w708", 708)]
    let r = model.runner(of: "main")
    @MainActor func page(_ e: AccountEntry, _ s: StandbyAccount, _ name: String) {
        for f in [Face.std, .silver] { for (wn, w) in oWidths {
            snapshot(framed(SwitchPage(entry: e, standby: s, model: model, runner: r, width: w), f, w), "\(name)-\(f.rawValue)-\(wn)", w + 32, 2400)
        } }
    }
    let goal = SwitchRunner.Goal(standby: "k2", wantedSeat: u2, wantedEmail: u2.email!, from: u1, started: Date().addingTimeInterval(-75))
    r.preview(.ready, goal: nil, target: k2)
    page(main, k2, "o1-switch-ready")
    // the move: what it plans (the window's sessions under ultra-1), then the receipt it leaves (for Undo)
    let swPlan: SwitchPlan? = { if case .success(let p) = SwitchEngine.plan(main, standby: k2, owned: []) { return p }; return nil }()
    var moved = SwitchReceipt(id: SwitchEngine.receiptID(Date(), "main"), profile: "main", standby: "k2", dataDir: wd, from: SeatID(u1), to: SeatID(u2), started: Date())
    moved.steps = (swPlan?.move ?? []).map { SwitchReceipt.Step(kind: .entry, path: $0, sha: nil, parked: nil, original: nil, done: true) }
    r.preview(.closing, goal: goal, target: k2, planned: swPlan)
    page(main, k2, "o10-switch-closing")
    r.preview(.moving, goal: goal, target: k2, planned: swPlan)
    page(main, k2, "o11-switch-moving")
    r.preview(.waiting, goal: goal, target: k2, planned: swPlan, receipt: moved, note: SwitchRunner.heldWords(1), seen: u1)
    page(main, k2, "o2-switch-waiting")
    // the folder signed in to ultra-2: the profile follows it (FolderRules.noteAccounts), ultra-1 stands by
    // (each ends as the app's runner does: noteAccounts, then the record answered again, resolveNow; the window's Claude
    // app signed in to the same account, as the page asks; o3b: the app still on ultra-1)
    func appOn(_ s: Seat) { try! JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": s.account]).write(to: URL(fileURLWithPath: "\(wd)/config.json")) }
    sign("~/.claude", u2); appOn(u2)
    let after = FolderRules.noteAccounts([main], signedIn: { $0 == "~/.claude" ? u2 : nil }, status: { _ in Store.status(for: main) })[0]
    model.accounts = [after]
    model.resolveNow("main")             // as the runner's end does: the record names ultra-2 at once
    var linked = moved; linked.linked = Date()
    r.preview(.reached, goal: goal, target: k2, planned: swPlan, receipt: linked, seen: u2)
    page(after, k2, "o3-switch-reached")
    // the Claude app not signed in to ultra-2 yet: it is still on ultra-1, which is then the account in use (A's rule),
    // its numbers say they are Claude Code's on ultra-2, and ultra-1 isn't shown as "before" too
    appOn(u1)
    model.resolveNow("main")
    page(after, k2, "o3b-switch-reached-app-still-on-ultra-1")
    // the browser was signed in as ultra-3: the profile is on ultra-3 now
    sign("~/.claude", u3); appOn(u3)
    let onOther = FolderRules.noteAccounts([main], signedIn: { $0 == "~/.claude" ? u3 : nil }, status: { _ in Store.status(for: main) })[0]
    model.accounts = [onOther]
    model.resolveNow("main")
    r.preview(.other(u3.email!), goal: goal, target: k2, planned: swPlan, receipt: moved, seen: u3)
    page(onOther, k2, "o4-switch-other-account")
    sign("~/.claude", u1); appOn(u1)
    model.accounts = [main]
    model.resolveNow("main")
    r.preview(.timedOut, goal: goal, target: k2, planned: swPlan, receipt: moved, seen: u1)
    page(main, k2, "o5-switch-timed-out")
    var undone = moved; undone.undone = Date()
    r.preview(.undone, goal: goal, target: k2, planned: swPlan, receipt: undone)
    page(main, k2, "o12-switch-undone")
    let again = SwitchRunner.Goal(standby: nil, wantedSeat: u1, wantedEmail: u1.email!, from: u1, started: Date().addingTimeInterval(-30))
    r.preview(.waiting, goal: again, target: nil)
    page(main, k2, "o6-switch-sign-in-again")
    r.preview(.ready, goal: nil, target: k2)
    if swPlan?.moves != true { print("note: the render world has no window sessions to move; o1–o5 show no move") }

    // the dashboard card: the account in use's limits, the standby accounts in unlit trays (no levels); then its week full,
    // the one offered first selected (the card's actions: `acts`, as for the a-renders)
    for f in [Face.std, .silver] { for (wn, w) in oWidths {
        snapshot(framed(AccountCard(row: AccountRow(entry: main, status: Store.status(for: main)), actions: acts).frame(width: min(w, 460)), f, w),
                 "o7a-card-standby-\(f.rawValue)-\(wn)", w + 32, 900)
    } }
    status("main", u1.email!, week: 100, fable: 60, resetsIn: 7 * 3600)
    for f in [Face.std, .silver] { for (wn, w) in oWidths {
        snapshot(framed(AccountCard(row: AccountRow(entry: main, status: Store.status(for: main)), actions: acts).frame(width: min(w, 460)), f, w),
                 "o7b-card-standby-full-\(f.rawValue)-\(wn)", w + 32, 900)
    } }
    status("main", u1.email!, week: 94, fable: 60, resetsIn: 7 * 3600)
    // the Claude app signed in to ultra-2 while Claude Code is on ultra-1: ultra-2 is in use, the numbers say whose they are;
    // then the app signed out: Claude Code's account, with the muted line
    let appOn2 = AppSignIn.Login(account: u2.account, org: u2.organization, state: .known, source: "log", at: Date())
    let appOut = AppSignIn.Login(account: nil, org: nil, state: .loggedOut, source: "log", at: Date())
    plainRecord = Store.status(for: main)
    for (tag, app) in [("o7c-card-app-other", appOn2), ("o7d-card-app-signed-out", appOut)] {
        // the record as the agent writes it (AccountResolver), then every surface from it
        var rec = plainRecord ?? IconStatus(state: "ok")
        rec.resolved = AccountResolver.resolve(main, among: [main], app: app, code: u1, loginEmail: u1.email, names: [u2.account: u2.email!])
        _ = Store.writeStatus("main", rec)
        let row = AccountRow(entry: main, status: Store.status(for: main))
        for f in [Face.std, .silver] { for (wn, w) in oWidths {
            snapshot(framed(AccountCard(row: row, actions: acts).frame(width: min(w, 460)), f, w), "\(tag)-\(f.rawValue)-\(wn)", w + 32, 900)
        } }
        if tag == "o7c-card-app-other" {
            // all surfaces side by side: the menu bar row, the Dock menu's top lines, the Dock panel, the card, Settings ▸
            // Accounts, the Switch page's in-use box and quick chat's profile line
            let u = Usage(fiveHour: nil, fiveHourResets: nil, weekly: rec.weekly, weeklyResets: rec.weeklyResets, fetchedAt: Date(), source: "test", noFiveHour: true)
            let mp = MenuBarItems.Profile(entry: main, usage: u, view: AccountView.of(Store.status(for: main)))
            let v = AccountView.of(Store.status(for: main))
            let panel = DetailsInfo(name: main.name, icon: NSImage(size: NSSize(width: 64, height: 64)), login: rec.loginEmail, expected: nil, mismatch: false,
                                    plan: rec.plan, fiveHour: nil, fiveHourResets: nil, weekly: rec.weekly, weeklyResets: rec.weeklyResets,
                                    updated: Date(), source: nil, problem: nil, renewNote: nil, needsLogin: false, noFiveHour: true).taking(v)
            let noop = DetailsActions(openClaude: {}, refresh: {}, settings: {}, logIn: {})
            for f in [Face.std, .silver] {
                let side = HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Menu bar").font(.caption.bold())
                        MenuBarRow(profile: mp, now: Date()).frame(width: 300)
                        Text("Dock menu").font(.caption.bold())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(SwitchMenu.dockTitle(name: main.name, v, plan: rec.plan)); if let l = v.line { Text(l).foregroundStyle(.secondary) }
                        }.font(.system(size: 13)).frame(width: 300, alignment: .leading)
                        Text("Quick chat").font(.caption.bold())
                        Text("Claude \(main.name) · " + (QuickChatTarget(main).email ?? "no account")).font(.system(size: 12)).frame(width: 300, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Dock panel").font(.caption.bold())
                        DetailsView(info: panel, actions: noop).frame(width: 340)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Card").font(.caption.bold())
                        AccountCard(row: row, actions: acts).frame(width: 340)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Settings ▸ Accounts").font(.caption.bold())
                        AccountSettings(entry: .constant(main), model: model, width: 340).frame(width: 340, height: 700, alignment: .top).clipped()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Switch page").font(.caption.bold())
                        SwitchPage(entry: main, standby: k2, model: model, runner: r, width: 340).frame(width: 340, height: 700, alignment: .top).clipped()
                    }
                }.padding(16)
                snapshot(framed(side, f, 1880), "o13-surfaces-app-other-\(f.rawValue)", 1912, 900)
            }
        }
    }
    if let p = plainRecord { _ = Store.writeStatus("main", p) }

    // the Accounts card (the profile's settings page, cropped later): standby rows, a folder from before (~/.claude-ultra-2,
    // signed in, no profile's) offered to the Trash; then the accounts found on this Mac, one known by its id only
    var withOld = main; withOld.leftoverFolders = ["~/.claude-ultra-2"]
    withOld.standby.append(StandbyAccount(email: "ultra-4@example.com", id: "k4"))      // remembered by its address only
    model.accounts = [withOld]
    LeftoverCounts.shared.countNow(withOld.leftoverFolders)      // the card counts off the main thread; a picture can't wait
    var found = main
    found.standby.append(StandbyAccount(email: "", seat: Seat(account: "00000000-0000-4000-8000-000000000071", organization: nil, email: nil), id: "k7"))
    for f in [Face.std, .silver] { for (wn, w) in oWidths {
        snapshot(framed(AccountSettings(entry: .constant(withOld), model: model, width: w), f, w), "o8-accounts-leftover-\(f.rawValue)-\(wn)", w + 32, 3200)
        snapshot(framed(AccountSettings(entry: .constant(found), model: model, width: w), f, w), "o9-accounts-found-\(f.rawValue)-\(wn)", w + 32, 3200)
    } }
    // a folder from before that holds sessions: never offered for the Trash, Show in Finder instead
    sign("~/.claude-old-work", u3)
    for n in 0..<2 { try? fm.createDirectory(atPath: expand("~/.claude-old-work/projects/-p"), withIntermediateDirectories: true)
                     fm.createFile(atPath: expand("~/.claude-old-work/projects/-p/\(uuid(900 + n)).jsonl"), contents: Data("{}\n".utf8)) }
    var withWork = main; withWork.leftoverFolders = ["~/.claude-old-work"]
    model.accounts = [withWork]
    LeftoverCounts.shared.countNow(withWork.leftoverFolders)
    for f in [Face.std, .silver] { for (wn, w) in oWidths {
        snapshot(framed(AccountSettings(entry: .constant(withWork), model: model, width: w), f, w), "o8f-accounts-leftover-sessions-\(f.rawValue)-\(wn)", w + 32, 3200)
    } }
    model.accounts = [main]
    // the account in use signed out, then expired: no bars, Log in… the one key
    let keepRecord = Store.status("main")
    for (tag, state) in [("o14a-accounts-signed-out", "noLogin"), ("o14b-accounts-expired", "expired")] {
        var st = IconStatus(state: state); st.loginEmail = state == "expired" ? u1.email : nil; st.expectedEmail = u1.email
        st.resolved = AccountResolver.resolve(main, among: [main], app: .unknown, code: u1, loginEmail: st.loginEmail, names: [:])
        _ = Store.writeStatus("main", st)
        for f in [Face.std, .silver] { for (wn, w) in oWidths {
            snapshot(framed(AccountSettings(entry: .constant(main), model: model, width: w), f, w), "\(tag)-\(f.rawValue)-\(wn)", w + 32, 2400)
        } }
    }
    if let k = keepRecord { _ = Store.writeStatus("main", k) }
    // a sign-in on a profile whose Claude Code folder was deleted: the line, nothing started
    var goneEntry = main; goneEntry.configDir = "~/.claude-gone-render"
    try? fm.removeItem(atPath: expand(goneEntry.configDir))
    let goneWhy = ClaudeCLI.goneLine(goneEntry.configDir) ?? "?"
    r.preview(.failed(goneWhy), goal: goal, target: k2, failedAt: .notStarted)
    page(goneEntry, k2, "o15-switch-folder-gone")
    // a switch that stopped: at the window's close (nothing moved), and at the move with sessions moved (Undo)
    r.preview(.failed("Main's Claude window didn't close; it may be asking about work under way. Answer it, then try again. Nothing moved."),
              goal: goal, target: k2, planned: swPlan, failedAt: .closing)
    page(main, k2, "o16a-switch-failed-window")
    // stopped part way: 12 of the sessions already placed under ultra-2 (real files), the rest not: the tile and What
    // changed give that count, as the app does
    var stoppedPart = moved; stoppedPart.finished = nil
    let dstR = SwitchEngine.scopeDir(wd, SeatID(u2))
    stoppedPart.steps = (swPlan?.move ?? []).prefix(12).map { n in
        let p = (dstR as NSString).appendingPathComponent(n)
        try? fm.createDirectory(atPath: dstR, withIntermediateDirectories: true)
        fm.createFile(atPath: p, contents: Data(#"{"isArchived":false}"#.utf8))
        return SwitchReceipt.Step(kind: .entry, path: p, sha: nil, parked: nil, original: nil, done: true)
    }
    r.preview(.failed("A session couldn't be placed; stopped. Undo puts back what moved."), goal: goal, target: k2, planned: swPlan,
              receipt: stoppedPart, failedAt: .move)
    page(main, k2, "o16b-switch-stopped-part-way")
    stoppedPart.steps.forEach { try? fm.removeItem(atPath: $0.path) }
    r.preview(.ready, goal: nil, target: k2)
    if ProcessInfo.processInfo.environment["ONEFOLDER_ONLY"] != nil { print("done"); exit(0) }

    // ================================================================ stage B2: the Restore page, Undo this switch
    SessionsRestore.runningSessions = { [uuid(2000 + 25).lowercased()] }
    let b2Now = Date()
    // the live state moves on from the backup mSw: 4 entries and 13 transcripts gone, 3 entries changed, 6 made after, 1 deleted
    for i in 30..<34 { try? fm.removeItem(atPath: "\(odir)/local_\(uuid(1000 + i)).json") }
    for i in 20..<33 where i != 25 { try? fm.removeItem(atPath: expand("~/.claude/projects/-Users-me-proj\(i % 3)/\(uuid(2000 + i)).jsonl")) }
    try? fm.removeItem(atPath: expand("~/.claude/projects/-Users-me-proj0/\(uuid(2000)).jsonl"))
    for i in 10..<13 { fm.createFile(atPath: "\(odir)/local_\(uuid(1000 + i)).json", contents: Data(#"{"isArchived":false,"edited":true}"#.utf8)) }
    for k in 0..<6 { fm.createFile(atPath: "\(odir2)/local_\(uuid(3000 + k)).json", contents: Data(#"{"isArchived":false}"#.utf8)) }
    try? fm.removeItem(atPath: "\(odir)/local_\(uuid(1036)).json"); fm.createFile(atPath: "\(odir2)/deleted_\(uuid(1036))", contents: Data())
    let backupRef = SessionsRestore.Backup(profile: "main", id: mSw.id, place: place)
    var plan = SessionsRestore.plan(SessionsRestore.Target(after), backupRef)
    let sidebarSessions = plan.entries.prefix(3).map { "local_" + String($0.leaf.dropFirst(6).dropLast(5)) }
    plan.sidebar = SidebarPlan(groups: [SidebarPlan.Group(id: "cg-1", name: "Work", sort: nil, sessions: Array(sidebarSessions.prefix(2))),
                                        SidebarPlan.Group(id: "cg-2", name: "Notes", sort: nil, sessions: Array(sidebarSessions.suffix(1)))],
                               pinned: [sidebarSessions[0]], restored: true)
    plan.partial = ["-Users-me-proj1/\(uuid(2013)).jsonl"]            // a copy a crash cut short (the Partial copy row)
    print("plan:", plan.entries.count, "entries", plan.transcripts.count, "transcripts", plan.backEntries, "back", plan.changed.count, "changed", plan.inUse.count, "in use", plan.old, "old", plan.madeAfter, "after", plan.deletedSince.count, "deleted", plan.refusal ?? "")
    let rkey = RestoreKey(profile: "main", backup: mSw.id, place: place.path)
    let rrun = model.restoreRunner(rkey)
    @MainActor func restorePage(_ name: String) {
        for f in [Face.std, .silver] { for (wn, w) in [("page708", CGFloat(708)), ("page1248", CGFloat(1248))] {
            snapshot(framed(RestorePage(entry: after, key: rkey, model: model, runner: rrun, width: w), f, w), "\(name)-\(f.rawValue)-\(wn)", w + 32, 3000)
        } }
    }
    rrun.preview(.ready, plan: plan)
    restorePage("6a-restore-preview")
    let planN = plan.count
    rrun.preview(.writing, plan: plan, receipt: nil, progress: (52, 86))
    restorePage("6b-restore-restoring")
    var rcpt = SessionsRestore.Receipt(id: SessionsRestore.receiptID(b2Now, "main"), profile: "main", dataDir: wd, codeDir: expand("~/.claude"), backup: mSw.id,
                                       backupPlace: place.path, target: SeatID(u2), started: b2Now, planned: 86, finished: b2Now)
    rcpt.steps = (0..<86).map { SessionsRestore.Receipt.Step(kind: .entry, path: "/x/\($0)", sha: "x", bytes: 1, done: true) }
    rcpt.changedCount = plan.changed.count; rcpt.changed = plan.changed; rcpt.inUseCount = plan.inUse.count; rcpt.inUse = plan.inUse; rcpt.sidebar = plan.sidebar
    rrun.preview(.done, plan: plan, receipt: rcpt, progress: (86, 86))
    restorePage("6c-restore-restored")
    rrun.preview(.stopped("Stopped by you. What is back is kept."), plan: plan, receipt: { var r = rcpt; r.finished = nil; r.stopped = "Stopped by you. What is back is kept."; r.steps = Array(r.steps.prefix(52)); return r }(), progress: (52, 86))
    restorePage("6d-restore-stopped")
    rrun.preview(.ready, plan: plan, notYet: RestoreRunner.NotYet(title: "A restore of Main is unfinished",
        words: "A restore of this profile stopped half way on 5 Nov 18:40. Finish it or undo it first."))
    restorePage("6e-restore-not-yet")
    var refused = plan; refused.refusal = "A file in the backup isn't a plain file with one link, or isn't there (local_x.json). Nothing is restored from it."
    rrun.preview(.ready, plan: refused)
    restorePage("6f-restore-refused")
    _ = planN
    rrun.preview(.undoing, plan: plan, receipt: rcpt, progress: (86, 86))
    restorePage("6i-restore-undoing")
    var partly = rcpt; partly.undoLeft = 2
    rrun.preview(.done, plan: plan, receipt: partly, progress: (86, 86))
    restorePage("6k-restore-partly-undone")

    // a backup a receipt names in another place is listed in the Sessions card with where it is
    let placeOld = URL(fileURLWithPath: expand("~/Old/backups"))
    let mOther = try! SessionsBackup.make(src, kind: .manual, window: false, transcripts: false, place: placeOld, now: b2Now.addingTimeInterval(-3 * 86400))
    var rOther = SwitchReceipt(id: SwitchEngine.receiptID(b2Now.addingTimeInterval(-3 * 86400), "main"), profile: "main", standby: "k3", dataDir: wd,
                               from: SeatID(u1), to: SeatID(u3), started: b2Now.addingTimeInterval(-3 * 86400))
    rOther.backup = mOther.id; rOther.backupPlace = placeOld.path; rOther.linked = b2Now.addingTimeInterval(-3 * 86400 + 600)
    saveReceipt(rOther)
    for f in [Face.std, .silver] {
        snapshot(framed(SessionsCard(entry: after, model: model), f, 460), "6j-sessions-other-place-\(f.rawValue)-w460", 492)
    }
    // an old switch that stopped half way: the Sessions card says what it left where, once
    var stopped = rc; stopped.id = SwitchEngine.receiptID(b2Now.addingTimeInterval(-5 * 86400), "main"); stopped.started = b2Now.addingTimeInterval(-5 * 86400)
    stopped.steps = (0..<7).map { _ in SwitchReceipt.Step(kind: .entry, path: "/x", sha: nil, parked: "/p", original: "/o", done: true) }
    saveReceipt(stopped)
    for f in [Face.std, .silver] {
        snapshot(framed(SessionsCard(entry: after, model: model), f, 460), "6l-sessions-old-switch-\(f.rawValue)-w460", 492)
    }
    try? fm.removeItem(at: SwitchEngine.root.appendingPathComponent(stopped.id))

    // ================================================================ stage E: Export and Import
    // Sample data only: made-up profiles "Main" (what is exported), "Work" (the file imported) and "Main" again as the target,
    // example.com addresses, planted keys that are obviously fake.
    setbuf(stdout, nil)
    func settleE(_ what: String, secs: Double = 60, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(secs)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if !done() { print("(timed out waiting for \(what))") }
    }
    func exLine(_ i: Int, _ n: Int, cwd: String, extra: String = "") -> String {
        let c = String(data: try! JSONEncoder().encode(cwd), encoding: .utf8)!
        return "{\"type\":\"user\",\"n\":\(n),\"cwd\":\(c),\"text\":\"line \(i)-\(n) \(extra)\"}\n"
    }
    func exTranscript(_ i: Int, lines: Int = 3, cwd: String, extra: String = "") -> String { (1...lines).map { exLine(i, $0, cwd: cwd, extra: extra) }.joined() }
    func putE(_ path: String, _ text: String, mb: Int = 0, daysAgo: Double = 2) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data(text.utf8))
        if mb > 0 { let h = FileHandle(forWritingAtPath: path)!; try! h.truncate(atOffset: UInt64(mb) * 1_048_576); try! h.close() }
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86400)], ofItemAtPath: path)
    }
    let appCwd = expand("~/projects/app"), siteCwd = expand("~/projects/site"), infraCwd = expand("~/projects/infra-other")
    try! fm.createDirectory(atPath: appCwd, withIntermediateDirectories: true)
    try! fm.createDirectory(atPath: siteCwd, withIntermediateDirectories: true)
    let ghFake = "gh\("")p_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE0000", pemFake = "---\("")--BEGIN RSA PRIVATE KEY-----\\nFAKEFAKEFAKE\\n-----END RSA PRIVATE KEY-----"

    // Main: the profile the Export page is about. 40 sessions in three project folders, 5 holding fake keys, 2 in use.
    let mdata = expand("~/Library/Application Support/Claude-exmain"), mcode = expand("~/.claude-exmain")
    var inUseIDs: [String] = []
    for k in 0..<22 { putE("\(mcode)/projects/-app/\(uuid(7000 + k)).jsonl", exTranscript(k, cwd: appCwd, extra: k == 3 || k == 9 ? ghFake : ""), mb: k < 12 ? 160 : 4) }
    for k in 0..<12 { putE("\(mcode)/projects/-site/\(uuid(7100 + k)).jsonl", exTranscript(k, cwd: siteCwd), mb: k < 8 ? 130 : 6) }
    for k in 0..<6 { putE("\(mcode)/projects/-infra/\(uuid(7200 + k)).jsonl", exTranscript(k, cwd: infraCwd, extra: k < 3 ? pemFake : (k == 3 ? ghFake : "")), mb: 2) }
    putE("\(mcode)/projects/-infra/\(uuid(7205)).jsonl", exTranscript(5, cwd: infraCwd, extra: pemFake), mb: 2)
    inUseIDs = [uuid(7001).lowercased(), uuid(7002).lowercased()]
    let mscope = "\(mdata)/claude-code-sessions/\(u1.account)/\(u1.organization!)"
    for k in 0..<84 { putE("\(mscope)/local_\(uuid(7300 + k)).json", k % 4 == 0 ? #"{"isArchived":true}"# : #"{"isArchived":false}"#) }
    putE("\(mscope)/scheduled-tasks.json", "{\"scheduledTasks\":[" + (0..<12).map { "{\"id\":\"t\($0)\",\"name\":\"Task \($0)\"}" }.joined(separator: ",") + "]}")
    var exmain = AccountEntry(id: "exmain", name: "Main", label: "MAIN", configDir: mcode); exmain.seat = u1; exmain.desktop = .separate; exmain.desktopDataDir = mdata

    // Work: what gets exported to a file (small, real), and the target "Main" that imports it, with some of it already there
    let wdata = expand("~/Library/Application Support/Claude-exwork"), wcode = expand("~/.claude-exwork")
    let wscope = "\(wdata)/claude-code-sessions/\(u3.account)/\(u3.organization!)"
    for k in 0..<26 { putE("\(wcode)/projects/-app/\(uuid(7500 + k)).jsonl", exTranscript(100 + k, cwd: appCwd), daysAgo: k < 4 ? 50 : 3) }
    for k in 0..<10 { putE("\(wcode)/projects/-infra/\(uuid(7600 + k)).jsonl", exTranscript(200 + k, cwd: infraCwd), daysAgo: 3) }
    putE("\(wcode)/projects/-app/memory/MEMORY.md", "Remember: this project prefers tabs.\n", daysAgo: 3)
    putE("\(wcode)/projects/-app/memory/style.md", "Short sentences.\n", daysAgo: 3)
    for k in 0..<14 { putE("\(wscope)/local_\(uuid(7700 + k)).json", #"{"sessionId":"local_\#(uuid(7700 + k))","title":"w\#(k)"\#(k >= 12 ? #","scheduledTaskId":"t1""# : "")}"#) }
    putE("\(wscope)/scheduled-tasks.json", #"{"scheduledTasks":[{"id":"t1","name":"Nightly digest"}]}"#)
    var exwork = AccountEntry(id: "exwork", name: "Work", label: "WORK", configDir: wcode); exwork.seat = u3; exwork.desktop = .separate; exwork.desktopDataDir = wdata
    let tdata = expand("~/Library/Application Support/Claude-imain"), tcode = expand("~/.claude-imain")
    let tscope = "\(tdata)/claude-code-sessions/\(u2.account)/\(u2.organization!)"
    try! fm.createDirectory(atPath: tscope, withIntermediateDirectories: true)
    for k in 0..<6 { putE("\(tcode)/projects/-app/\(uuid(7500 + 4 + k)).jsonl", exTranscript(104 + k, cwd: appCwd), daysAgo: 4) }            // the same content
    for k in 0..<2 { putE("\(tcode)/projects/-app/\(uuid(7500 + 12 + k)).jsonl", exTranscript(112 + k, lines: 5, cwd: appCwd), daysAgo: 4) }   // longer here
    for k in 0..<3 { putE("\(tcode)/projects/-app/\(uuid(7500 + 16 + k)).jsonl", "{\"other\":\(k)}\n", daysAgo: 4) }                          // different
    var imain = AccountEntry(id: "imain", name: "Main", label: "MAIN", configDir: tcode); imain.seat = u2; imain.desktop = .separate; imain.desktopDataDir = tdata

    model.accounts = [exmain, exwork, imain]
    SessionsRestore.runningSessions = { Set(inUseIDs) }
    let exportsDir = expand("~/Exports")
    try! fm.createDirectory(atPath: exportsDir, withIntermediateDirectories: true)

    @MainActor func eShots<V: View>(_ name: String, _ make: (CGFloat) -> V, height: CGFloat = 3000) {
        for f in [Face.std, .silver] { for (wn, w) in [("page708", CGFloat(708)), ("page1248", CGFloat(1248))] {
            snapshot(framed(make(w), f, w), "\(name)-\(f.rawValue)-\(wn)", w + 32, height)
        } }
    }

    // ---- 7a/7b the Sessions card: Export and Import rows, never used and used
    for f in [Face.std, .silver] { for (wn, w) in [("w460", CGFloat(460)), ("w340", CGFloat(340))] {
        snapshot(framed(SessionsCard(entry: exmain, model: model), f, w), "7a-sessions-card-never-\(f.rawValue)-\(wn)", w + 32)
    } }
    ExportPrefs.remember(profile: "exmain", date: Date().addingTimeInterval(-2 * 86400), bytes: 5_500_000_000)
    var doneImport = SessionsRestore.Receipt(id: SessionsRestore.receiptID(Date().addingTimeInterval(-86400), "exmain"), profile: "exmain", dataDir: mdata, codeDir: mcode, backup: SessionsBackup.newID(),
                                              backupPlace: BackupPrefs.placeURL.path, target: SeatID(u1), started: Date().addingTimeInterval(-86400), finished: Date().addingTimeInterval(-86400 + 60))
    doneImport.importedFrom = "cl_audit Work 2026-10-30.zip"; doneImport.sessionsAdded = 180; doneImport.entriesAdded = 30
    try! SessionsRestore.save(doneImport)
    for f in [Face.std, .silver] { for (wn, w) in [("w460", CGFloat(460)), ("w340", CGFloat(340))] {
        snapshot(framed(SessionsCard(entry: exmain, model: model), f, w), "7b-sessions-card-last-\(f.rawValue)-\(wn)", w + 32)
    } }
    try? fm.removeItem(at: SessionsRestore.root)
    ExportPrefs.remember(profile: "exmain", date: Date().addingTimeInterval(-2 * 86400), bytes: 5_500_000_000)

    // ---- 7c.. the Export page
    let xr = model.exportRunner(for: "exmain")
    xr.refresh()
    settleE("the export preview") { xr.previews != nil }
    print("export preview:", xr.total?.sessions ?? -1, "sessions", xr.total?.keyedSessions ?? -1, "keyed", xr.total?.inUse ?? -1, "in use", xr.total?.keyKinds ?? [:])
    @MainActor func exportPage(_ name: String) { eShots(name, { ExportPage(entry: exmain, model: model, runner: xr, width: $0) }) }
    exportPage("7c-export-preview-zip")
    xr.keys = .keep
    exportPage("7d-export-keep-image")
    xr.password = "typed-in-a-secure-field"; xr.again = "typed-in-a-secure-field"
    exportPage("7d2-export-keep-image-password")
    xr.password = ""; xr.again = ""
    xr.keys = .leaveOut
    let oc = SessionsExport.Outcome(file: URL(fileURLWithPath: exportsDir + "/cl_audit Main 2026-11-05.zip"), bytes: 5_100_000_000,
                                    parts: [SessionsExport.PartOutcome(name: "Main", sessions: 35, entries: 84, tasks: 12, bytes: 5_300_000_000, keysLeftOut: 5, keysKept: 0, cut: 2)])
    xr.preview(.working("making the zip", 0.42), previews: xr.previews ?? [])
    exportPage("7e-export-exporting")
    xr.preview(.done(oc), previews: xr.previews ?? [])
    exportPage("7f-export-exported")
    xr.preview(.failed("The zip couldn't be made (No space left on device). Nothing was left behind."), previews: xr.previews ?? [])
    exportPage("7f2-export-failed")

    // ---- the Import page: Work's file, made for real
    let exportNow = Date().addingTimeInterval(-7 * 86400)
    let workZip = URL(fileURLWithPath: exportsDir + "/cl_audit Work 2026-10-30.zip")
    let made = try! SessionsExport.run(SessionsExport.Job(parts: [SessionsExport.Part(profile: "exwork", name: "Work", source: SessionsBackup.Source(exwork), emails: [u3.email!])], keys: .leaveOut,
                                                           destination: workZip, rootName: "cl_audit Work 2026-10-30", now: exportNow))
    print("work export:", made.sessions, "sessions", SessionsBackup.sizeWords(made.bytes))
    let ir0 = ImportRunner(profile: "imain", model: model)
    @MainActor func importPage(_ name: String, _ r: ImportRunner) { eShots(name, { ImportPage(entry: imain, model: model, runner: r, width: $0) }) }
    importPage("7g-import-choose", ir0)
    let irPw = ImportRunner(profile: "imain", model: model)
    irPw.preview(.password(nil), file: URL(fileURLWithPath: exportsDir + "/cl_audit Work 2026-10-30.dmg"))
    importPage("7h-import-password", irPw)
    irPw.preview(.password("That password isn't right."))
    importPage("7h2-import-password-wrong", irPw)
    let irRead = ImportRunner(profile: "imain", model: model)
    irRead.preview(.opening("unpacking"), file: workZip)
    importPage("7i-import-reading", irRead)
    let irBad = ImportRunner(profile: "imain", model: model)
    irBad.preview(.refused("The zip holds a link (profiles/p1/lnk); refused."), file: URL(fileURLWithPath: exportsDir + "/cl_audit Work 2026-10-30 (edited).zip"))
    importPage("7j-import-refused", irBad)

    let ir = model.importRunner(for: "imain")
    ir.setFile(workZip)
    settleE("the import preview") { ir.phase == .ready && ir.plan != nil && ir.counting?.notYet == nil && ir.counting?.plan != nil }
    var anotherMac = ir.opened!; anotherMac.sameMac = false
    let o0 = ir.opened!, s0 = ir.staged!, c0 = ir.counting!
    ir.preview(.ready, opened: anotherMac)
    if let p = ir.plan {
        print("import plan: new", p.transcripts.count, "transcripts", p.entries.count, "entries; here", p.backTranscripts, "/", p.backEntries, "; grown/different", p.changed.count + p.partial.count,
              "; tasks", p.taskSessions.count, "; folders", c0.foldersMissing, "; old", p.old, "; refusal", p.refusal ?? "none")
    }
    importPage("7k-import-preview", ir)
    c0.preview(.ready, plan: c0.plan, notYet: RestoreRunner.NotYet(title: "A restore of Main is unfinished",
        words: "A restore of this profile stopped half way on 5 Nov at 18:40. Finish it or undo it first."))
    importPage("7n-import-not-yet", ir)
    c0.preview(.ready, plan: c0.plan, notYet: nil)

    // importing: the Restore page's steps, in import words
    let key0 = RestoreKey(profile: "imain", backup: s0.id, place: s0.stage.path, resume: "render-only")      // (its own runner: the real run below has the same backup id)
    let irRun = ImportRunner(profile: "imain", model: model)
    irRun.preview(.running(key0))
    let rrMid = model.restoreRunner(key0)
    rrMid.preview(.writing, plan: c0.plan, receipt: nil, progress: (3, 8))
    importPage("7l-import-importing", irRun)
    _ = o0

    // the real thing: Close and import, Imported
    ir.preview(.ready, opened: o0)
    ir.commit()
    guard case .running(let key) = ir.phase else { fatalError("the import didn't start") }
    let rr = model.restoreRunner(key)
    settleE("the import") { rr.phase == .done }
    print("imported:", rr.receipt?.back ?? -1, "added", rr.receipt?.changedCount ?? -1, "listed", rr.receipt?.sessionsAdded ?? -1, "sessions", rr.receipt?.entriesAdded ?? -1, "entries")
    importPage("7m-import-imported", ir)
    rr.undo()
    settleE("the undo") { rr.phase == .undone }
    importPage("7o-import-undone", ir)

    // ================================================================ stage E2: Claude Code's setup (renders 8a..8e)
    // The setup row of the Export, Import and Restore pages, at 340, 460 and 708, Std and Silver. Sample data only: made-up profiles,
    // example.com addresses, fake keys.
    do {
        let c2 = expand("~/.claude-e2main"), d2 = expand("~/Library/Application Support/Claude-e2main")
        let away = expand("~/elsewhere-e2")
        func w2(_ c: String, _ rel: String, _ text: String, exec: Bool = false) {
            putE("\(c)/\(rel)", text, daysAgo: 30)
            if exec { chmod("\(c)/\(rel)", 0o755) }
        }
        func plant2(_ c: String, links: Bool) {
            w2(c, "CLAUDE.md", "# My rules\n@docs/style.md\nsee @~/notes-outside-e2/rules.md\n"); w2(c, "docs/style.md", "style")
            for (i, s) in ["pdf-tools", "release-notes", "git-helper", "sql-review", "writing-style", "data-clean"].enumerated() {
                w2(c, "skills/\(s)/SKILL.md", "skill \(s)"); if i < 3 { w2(c, "skills/\(s)/run.sh", "#!/bin/sh\n", exec: true) }
            }
            w2(c, "skills/keyed-skill/SKILL.md", "keyed"); w2(c, "skills/keyed-skill/deploy.py", "KEY = '\(ghFake)'\n")
            for a in ["reviewer", "planner", "tester", "writer"] { w2(c, "agents/\(a).md", "agent \(a)") }
            for k in ["ship", "triage", "standup", "changelog", "bump", "audit"] { w2(c, "commands/\(k).md", "command \(k)") }
            w2(c, "output-styles/terse.md", "terse"); w2(c, "keybindings.json", "{}")
            w2(c, "settings.json", "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(c)/bin/guard.sh\"}]}],\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/opt/tools-e2/notify.sh\"}]}],\"PostToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(c)/bin/fmt.sh\"}]}],\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(c)/bin/start.sh\"}]}]},\"statusLine\":{\"type\":\"command\",\"command\":\"\(c)/bin/line.sh\"}}")
            for s in ["guard", "fmt", "start"] { w2(c, "bin/\(s).sh", "#!/bin/sh\n", exec: true) }; w2(c, "bin/line.sh", "#!/bin/sh\n", exec: true)
            w2(c, "plugins/installed_plugins.json", "{\"plugins\":{\"a@m\":{},\"b@m\":{}}}"); w2(c, "plugins/known_marketplaces.json", "{}")
            if links {
                try? fm.createDirectory(atPath: away + "/skills/foo", withIntermediateDirectories: true)
                symlink(away + "/skills/foo", c + "/skills/linked-one"); symlink(away + "/skills/foo", c + "/skills/linked-two")
            }
        }
        putE(expand("~/notes-outside-e2/rules.md"), "outside", daysAgo: 30)
        plant2(c2, links: true)
        for k in 0..<6 { putE("\(c2)/projects/-app/\(uuid(8000 + k)).jsonl", exTranscript(k, cwd: appCwd, extra: k < 2 ? ghFake : ""), daysAgo: 3) }
        try! fm.createDirectory(atPath: "\(d2)/claude-code-sessions/\(u1.account)/\(u1.organization!)", withIntermediateDirectories: true)
        var e2main = AccountEntry(id: "e2main", name: "Main", label: "MAIN", configDir: c2); e2main.seat = u1; e2main.desktop = .separate; e2main.desktopDataDir = d2
        model.accounts = [exmain, exwork, imain, e2main]
        SessionsRestore.runningSessions = { [] }
        @MainActor func e2Shots<V: View>(_ name: String, _ make: (CGFloat) -> V, height: CGFloat = 3200) {
            for f in [Face.std, .silver] { for w in [CGFloat(340), 460, 708] {
                snapshot(framed(make(w), f, w), "\(name)-\(f.rawValue)-w\(Int(w))", w + 32, height)
            } }
        }

        // ---- 8a/8b the Export page: the setup row on a zip (sensitive part left out, links listed), then the image with a skill that holds a key
        let xr2 = model.exportRunner(for: "e2main")
        xr2.refresh()
        settleE("the setup export preview") { xr2.previews != nil }
        print("setup preview:", xr2.total?.setup.units.count ?? -1, "units", xr2.total?.setup.keyedUnits.count ?? -1, "keyed", xr2.total?.setup.linked.count ?? -1, "linked")
        @MainActor func exportPage2(_ name: String) { e2Shots(name, { ExportPage(entry: e2main, model: model, runner: xr2, width: $0) }) }
        exportPage2("8a-export-setup-zip")
        xr2.keys = .keep
        xr2.password = "typed-in-a-secure-field"; xr2.again = "typed-in-a-secure-field"
        exportPage2("8b-export-setup-image-keys")
        xr2.password = ""; xr2.again = ""; xr2.keys = .leaveOut

        // ---- 8c/8d the Import page: a real image made from another profile, and a target that has some of it
        let c3 = expand("~/.claude-e2work"), d3 = expand("~/Library/Application Support/Claude-e2work")
        plant2(c3, links: false)
        for k in 0..<4 { putE("\(c3)/projects/-app/\(uuid(8100 + k)).jsonl", exTranscript(300 + k, cwd: appCwd), daysAgo: 3) }
        let wscope3 = "\(d3)/claude-code-sessions/\(u3.account)/\(u3.organization!)"
        try! fm.createDirectory(atPath: wscope3, withIntermediateDirectories: true)
        var e2work = AccountEntry(id: "e2work", name: "Work", label: "WORK", configDir: c3); e2work.seat = u3; e2work.desktop = .separate; e2work.desktopDataDir = d3
        let tc = expand("~/.claude-e2imain"), td = expand("~/Library/Application Support/Claude-e2imain")
        let tscope3 = "\(td)/claude-code-sessions/\(u2.account)/\(u2.organization!)"
        try! fm.createDirectory(atPath: tscope3, withIntermediateDirectories: true)
        w2(tc, "skills/pdf-tools/SKILL.md", "my own version, different"); w2(tc, "skills/git-helper/SKILL.md", "skill git-helper"); w2(tc, "skills/git-helper/run.sh", "#!/bin/sh\n", exec: true)
        w2(tc, "agents/reviewer.md", "agent reviewer"); w2(tc, "settings.json", "{\"model\":\"opus\",\"env\":{\"MINE\":\"x\"}}")
        var e2imain = AccountEntry(id: "e2imain", name: "Main", label: "MAIN", configDir: tc); e2imain.seat = u2; e2imain.desktop = .separate; e2imain.desktopDataDir = td
        model.accounts = [exmain, exwork, imain, e2main, e2work, e2imain]
        let pw2 = "render-password-not-secret"
        let img2 = URL(fileURLWithPath: exportsDir + "/cl_audit Work 2026-11-07.dmg")
        try? fm.removeItem(at: img2)
        _ = try! SessionsExport.run(SessionsExport.Job(parts: [SessionsExport.Part(profile: "e2work", name: "Work", source: SessionsBackup.Source(e2work), emails: [u3.email!])], keys: .leaveOut,
                                                       password: pw2, destination: img2, rootName: "cl_audit Work 2026-11-07", now: Date().addingTimeInterval(-86400)))
        let ir2 = model.importRunner(for: "e2imain")
        ir2.setFile(img2)                              // (an image asks for its password: setFile empties it, so it is typed after)
        ir2.password = pw2
        ir2.open()
        settleE("the setup import preview") { ir2.phase == .ready && ir2.plan != nil && ir2.counting?.notYet == nil && ir2.counting?.plan != nil }
        @MainActor func importPage2(_ name: String) { e2Shots(name, { ImportPage(entry: e2imain, model: model, runner: ir2, width: $0) }, height: 3800) }
        importPage2("8c-import-setup-left-out")
        ir2.setSetup(true)
        settleE("the setup import counted again") { ir2.plan?.setup.leftOut == false }
        SetupRow.renderOpen = true
        importPage2("8d-import-setup-added-open")
        SetupRow.renderOpen = false

        // ---- 8e the Restore page: a backup of Main from before two things were deleted on purpose
        let bk2 = try! SessionsBackup.make(SessionsBackup.Source(e2main), kind: .manual, window: false, place: BackupPrefs.placeURL, now: Date().addingTimeInterval(-3600))
        try? fm.removeItem(atPath: c2 + "/skills/data-clean"); try? fm.removeItem(atPath: c2 + "/agents/tester.md"); try? fm.removeItem(atPath: c2 + "/commands/audit.md")
        let rk2 = RestoreKey(profile: "e2main", backup: bk2.id, place: BackupPrefs.placeURL.path)
        let rr2 = model.restoreRunner(rk2)
        rr2.refresh()
        settleE("the setup restore preview") { rr2.plan != nil }
        SetupRow.renderOpen = true
        e2Shots("8e-restore-setup", { RestorePage(entry: e2main, key: rk2, model: model, runner: rr2, width: $0) }, height: 3800)
        SetupRow.renderOpen = false

        // ---- 8f the Restore page: a backup that found keys (settings.json's values left blank, a script and the marketplaces left out)
        let c8f = expand("~/.claude-e2bscan")
        w2(c8f, "CLAUDE.md", "# My rules\n"); w2(c8f, "skills/review/SKILL.md", "skill review")
        w2(c8f, "bin/deploy.sh", "#!/bin/sh\ncurl -H 'Authorization: Bearer \(ghFake)' https://example.com\n", exec: true)
        w2(c8f, "bin/lint.sh", "#!/bin/sh\n", exec: true)
        w2(c8f, "plugins/known_marketplaces.json", "{\"m\":{\"url\":\"https://example.com/m.git\",\"token\":\"\(ghFake)\"}}")
        w2(c8f, "settings.json", "{\"apiKeyHelper\":\"echo \(ghFake)\",\"model\":\"opus\",\"permissions\":{\"allow\":[\"Bash(ls:*)\",\"WebFetch(curl -H 'Authorization: Bearer \(ghFake)')\"]},\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"http\",\"url\":\"https://hooks.example.com/check?token=\(ghFake)\"}]}],\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(c8f)/bin/deploy.sh\"},{\"type\":\"command\",\"command\":\"\(c8f)/bin/lint.sh\"}]}]}}")
        var e2bscan = AccountEntry(id: "e2bscan", name: "Work", label: "WORK", configDir: c8f); e2bscan.seat = u1
        model.accounts = model.accounts + [e2bscan]
        let bk8f = try! SessionsBackup.make(SessionsBackup.Source(e2bscan), kind: .manual, window: false, place: BackupPrefs.placeURL, now: Date().addingTimeInterval(-3600))
        print("keys backup:", bk8f.secretBlanked ?? [], bk8f.secretLeftOut ?? [])
        try? fm.removeItem(atPath: c8f + "/settings.json"); try? fm.removeItem(atPath: c8f + "/bin/lint.sh")
        let rk8f = RestoreKey(profile: "e2bscan", backup: bk8f.id, place: BackupPrefs.placeURL.path)
        let rr8f = model.restoreRunner(rk8f)
        rr8f.refresh()
        settleE("the keys restore preview") { rr8f.plan != nil }
        SetupRow.renderOpen = true
        e2Shots("8f-restore-keys-left-out", { RestorePage(entry: e2bscan, key: rk8f, model: model, runner: rr8f, width: $0) }, height: 3800)
        SetupRow.renderOpen = false

        // ---- 9: the Claude window's MCP settings and scheduled tasks (stage E2b) on the Export, Import and Restore pages
        let c9 = expand("~/.claude-e2bsrc"), d9 = expand("~/Library/Application Support/Claude-e2bsrc")
        let s9 = "\(d9)/claude-code-sessions/\(u3.account)/\(u3.organization!)"
        try! fm.createDirectory(atPath: s9, withIntermediateDirectories: true)
        let mcp: [String: Any] = ["mcpServers": ["github": ["command": "npx", "args": ["-y", "@example/server-github"], "env": ["GITHUB_TOKEN": "sample-value"]],
                                                 "postgres": ["command": "/opt/homebrew/bin/postgres-mcp", "args": ["--read-only"]],
                                                 "linear": ["url": "https://mcp.example.com/sse"]],
                                  "globalShortcut": "Alt+Space", "preferences": ["menuBarEnabled": true]]
        try! JSONSerialization.data(withJSONObject: mcp, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: d9 + "/claude_desktop_config.json"))
        let tasks9: [[String: Any]] = [
            ["id": "nightly-digest", "displayName": "Nightly digest", "cronExpression": "0 3 * * *", "enabled": true, "filePath": c9 + "/scheduled-tasks/nightly-digest/SKILL.md", "cwd": appCwd, "createdAt": 1],
            ["id": "weekly-report", "displayName": "Weekly report", "cronExpression": "0 9 * * 1", "enabled": true, "filePath": c9 + "/scheduled-tasks/weekly-report/SKILL.md", "cwd": appCwd, "createdAt": 1,
             "permissionMode": "bypassPermissions", "approvedPermissions": ["Bash(git push:*)"]],
            ["id": "dependency-check", "displayName": "Dependency check", "cronExpression": "0 8 * * *", "enabled": true, "filePath": c9 + "/scheduled-tasks/dependency-check/SKILL.md", "cwd": appCwd, "createdAt": 1]]
        try! JSONSerialization.data(withJSONObject: ["scheduledTasks": tasks9], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: s9 + "/scheduled-tasks.json"))
        for t in ["nightly-digest", "weekly-report"] { w2(c9, "scheduled-tasks/\(t)/SKILL.md", "---\nname: \(t)\n---\nThe \(t) prompt.\n") }
        for k in 0..<5 {
            let task = k == 4 ? ",\"scheduledTaskId\":\"nightly-digest\"" : ""
            putE("\(s9)/local_\(uuid(9000 + k)).json", "{\"sessionId\":\"local_\(uuid(9000 + k))\",\"cliSessionId\":\"\(uuid(9100 + k))\",\"title\":\"session \(k)\",\"cwd\":\"\(appCwd)\",\"isArchived\":false\(task)}", daysAgo: 2)
            putE("\(c9)/projects/-app/\(uuid(9100 + k)).jsonl", exTranscript(400 + k, cwd: appCwd), daysAgo: 2)
        }
        var e2bsrc = AccountEntry(id: "e2bsrc", name: "Work", label: "WORK", configDir: c9); e2bsrc.seat = u3; e2bsrc.desktop = .separate; e2bsrc.desktopDataDir = d9
        let tc9 = expand("~/.claude-e2bdst"), td9 = expand("~/Library/Application Support/Claude-e2bdst")
        try! fm.createDirectory(atPath: "\(td9)/claude-code-sessions/\(u2.account)/\(u2.organization!)", withIntermediateDirectories: true)
        try! fm.createDirectory(atPath: tc9 + "/projects", withIntermediateDirectories: true)
        var e2bdst = AccountEntry(id: "e2bdst", name: "Main", label: "MAIN", configDir: tc9); e2bdst.seat = u2; e2bdst.desktop = .separate; e2bdst.desktopDataDir = td9
        let hc9 = expand("~/.claude-e2bhas"), hd9 = expand("~/Library/Application Support/Claude-e2bhas")
        let hs9 = "\(hd9)/claude-code-sessions/\(u2.account)/\(u2.organization!)"
        try! fm.createDirectory(atPath: hs9, withIntermediateDirectories: true)
        try! fm.createDirectory(atPath: hc9 + "/projects", withIntermediateDirectories: true)
        putE(hd9 + "/claude_desktop_config.json", #"{"mcpServers":{"github":{"command":"npx"},"notes":{"command":"notes-mcp"}}}"#, daysAgo: 10)
        putE(hs9 + "/scheduled-tasks.json", #"{"scheduledTasks":[{"id":"weekly-report","displayName":"Weekly report","enabled":true}]}"#, daysAgo: 10)
        var e2bhas = AccountEntry(id: "e2bhas", name: "Laptop", label: "LAPTOP", configDir: hc9); e2bhas.seat = u2; e2bhas.desktop = .separate; e2bhas.desktopDataDir = hd9
        model.accounts = [exmain, exwork, imain, e2main, e2work, e2imain, e2bsrc, e2bdst, e2bhas]

        // 9a/9b the Export page: the MCP settings left out of a zip (and why), carried in the image; the tasks travel with their prompts
        let xr9 = model.exportRunner(for: "e2bsrc")
        xr9.refresh()
        settleE("the window export preview") { xr9.previews != nil }
        @MainActor func exportPage9(_ name: String) { e2Shots(name, { ExportPage(entry: e2bsrc, model: model, runner: xr9, width: $0) }) }
        exportPage9("9a-export-window-zip")
        xr9.container = .image
        xr9.password = "typed-in-a-secure-field"; xr9.again = "typed-in-a-secure-field"
        exportPage9("9b-export-window-image")
        xr9.password = ""; xr9.again = ""; xr9.container = .zip

        // 9c/9d the Import page: left out by default, then both added (the servers and the tasks listed)
        let img9 = URL(fileURLWithPath: exportsDir + "/cl_audit Work 2026-11-09.dmg")
        try? fm.removeItem(at: img9)
        _ = try! SessionsExport.run(SessionsExport.Job(parts: [SessionsExport.Part(profile: "e2bsrc", name: "Work", source: SessionsBackup.Source(e2bsrc), emails: [u3.email!])], keys: .leaveOut,
                                                       password: pw2, destination: img9, rootName: "cl_audit Work 2026-11-09", now: Date().addingTimeInterval(-3600)))
        @MainActor func openImport(_ id: String) -> ImportRunner {
            let ir = model.importRunner(for: id)
            ir.setFile(img9); ir.password = pw2; ir.open()
            settleE("the window import preview (\(id))") { ir.phase == .ready && ir.plan != nil && ir.counting?.notYet == nil && ir.counting?.plan != nil }
            return ir
        }
        let ir9 = openImport("e2bdst")
        @MainActor func importPage9(_ name: String, _ e: AccountEntry, _ ir: ImportRunner) { e2Shots(name, { ImportPage(entry: e, model: model, runner: ir, width: $0) }, height: 4400) }
        importPage9("9c-import-window-left-out", e2bdst, ir9)
        // 9i the tasks added (the config still left out), a task flagged for bypassed and approved permissions
        ir9.setTasks(true)
        settleE("the window import, tasks added") { ir9.plan?.taskPlan.leftOut == false }
        SetupRow.renderOpen = true
        importPage9("9i-import-task-flagged", e2bdst, ir9)
        ir9.setConfig(true)
        settleE("the window import, config added") { ir9.plan?.config.leftOut == false }
        importPage9("9d-import-window-added-open", e2bdst, ir9)
        // 9h the import run: the done page (tasks added paused, the config added, with its Undo line)
        ir9.commit()
        if case .running(let key9) = ir9.phase {
            let run9 = model.restoreRunner(key9)
            settleE("the window import ran") { run9.phase == .done }
            importPage9("9h-import-window-done", e2bdst, ir9)
        } else { print("the window import didn't start") }
        // 9e into a profile that has its own config and task file: both stay, what they lack is listed
        let ih9 = openImport("e2bhas")
        ih9.setConfig(true)
        settleE("the window import (has its own), config") { ih9.plan?.config.leftOut == false }
        ih9.setTasks(true)
        settleE("the window import (has its own), tasks") { ih9.plan?.taskPlan.leftOut == false }
        importPage9("9e-import-window-here-stays", e2bhas, ih9)
        SetupRow.renderOpen = false

        // 9f/9g the Restore page: a backup of Work from before its config, task file and a prompt went: left out, then added
        // (a plain backup keeps no MCP settings, and settings.json with its env values blank: the setup row says so)
        w2(c9, "settings.json", "{\"env\":{\"DEPLOY_TOKEN\":\"sample-value\",\"REGION\":\"eu-west-1\"},\"model\":\"opus\"}")
        let bk9 = try! SessionsBackup.make(SessionsBackup.Source(e2bsrc), kind: .manual, place: BackupPrefs.placeURL, now: Date().addingTimeInterval(-1800))
        try? fm.removeItem(atPath: d9 + "/claude_desktop_config.json"); try? fm.removeItem(atPath: s9 + "/scheduled-tasks.json"); try? fm.removeItem(atPath: c9 + "/scheduled-tasks/weekly-report")
        try? fm.removeItem(atPath: c9 + "/settings.json")
        let rk9 = RestoreKey(profile: "e2bsrc", backup: bk9.id, place: BackupPrefs.placeURL.path)
        let rr9 = model.restoreRunner(rk9)
        rr9.refresh()
        settleE("the window restore preview") { rr9.plan != nil }
        @MainActor func restorePage9(_ name: String) { e2Shots(name, { RestorePage(entry: e2bsrc, key: rk9, model: model, runner: rr9, width: $0) }, height: 4000) }
        restorePage9("9f-restore-window-left-out")
        rr9.setSetup(true)
        settleE("the window restore, setup added") { rr9.plan?.setup.leftOut == false }
        SetupRow.renderOpen = true
        restorePage9("9g-restore-window-setup-added")
        SetupRow.renderOpen = false

        // ---- m: a move to another Mac (stage E2c): the Export page with the Move preset on, the Import page of a move file (the profiles it
        // makes, the settings row), and the done page (the sign-ins to do, the Dock step). Two made-up profiles, Studio and Travel, are the
        // "other Mac" here: they are in the list only while the Export page is drawn. (No sidebar records and no Claude window for them:
        // the import's run opens nothing.)
        SessionsMove.prefs = MemoryPrefs()
        Store.announce = {}
        DockWriter.backend = DockWriter.Backend(read: { DockWriter.Lists(pinned: [], recent: []) }, write: { _ in }, restart: {})
        let u4 = seat(4, "studio-1@example.com"), u5 = seat(5, "studio-2@example.com"), u6 = seat(6, "travel-1@example.com")
        func mvProfile(_ id: String, _ name: String, _ s: Seat, standby: Seat?) -> AccountEntry {
            var e = AccountEntry(id: id, name: name, label: name.uppercased(), configDir: "~/.claude-\(id)")
            e.seat = s; e.desktop = .separate; e.desktopDataDir = "~/Library/Application Support/Claude-\(id)"; e.claudeWindow = false
            if let q = standby { e.standby = [StandbyAccount(email: q.email!, seat: q, id: "q\(id.prefix(3))")] }
            let scope = expand(e.desktopDataDir) + "/claude-code-sessions/\(s.account)/\(s.organization!)"
            for k in 0..<3 {
                putE("\(scope)/local_\(uuid(9500 + k + (id == "mvstudio" ? 0 : 10))).json", "{\"sessionId\":\"local_\(uuid(9500 + k))\",\"cliSessionId\":\"\(uuid(9600 + k + (id == "mvstudio" ? 0 : 10)))\",\"title\":\"\(name) session \(k)\",\"cwd\":\"\(appCwd)\",\"isArchived\":false}", daysAgo: 2)
                putE(expand(e.configDir) + "/projects/-app/\(uuid(9600 + k + (id == "mvstudio" ? 0 : 10))).jsonl", exTranscript(500 + k, cwd: appCwd), daysAgo: 2)
            }
            if id == "mvstudio" {
                let t: [[String: Any]] = [["id": "morning-brief", "displayName": "Morning brief", "cronExpression": "0 8 * * *", "enabled": true,
                                           "filePath": expand(e.configDir) + "/scheduled-tasks/morning-brief/SKILL.md", "cwd": appCwd, "createdAt": 1]]
                try! JSONSerialization.data(withJSONObject: ["scheduledTasks": t]).write(to: URL(fileURLWithPath: scope + "/scheduled-tasks.json"))
                w2(expand(e.configDir), "scheduled-tasks/morning-brief/SKILL.md", "The morning brief.\n")
                w2(expand(e.configDir), "CLAUDE.md", "# Studio rules\n")
                e.color = .teal; e.menuBar = true
            } else { e.iconHidden = true; e.color = .pink }
            return e
        }
        let mvStudio = mvProfile("mvstudio", "Studio", u4, standby: u5), mvTravel = mvProfile("mvtravel", "Travel", u6, standby: nil)
        let before = model.accounts
        model.accounts = [mvStudio, mvTravel]
        // the other Mac's settings: Silver, emails hidden, 7 backups kept
        SessionsMove.prefs.set("silver", forKey: "face"); SessionsMove.prefs.set(false, forKey: Privacy.key); BackupPrefs.store.set(7, forKey: BackupPrefs.lastKey)
        let xrM = model.exportRunner(for: "mvstudio")
        xrM.movePreset()
        xrM.refresh()
        settleE("the move export preview") { xrM.previews != nil }
        xrM.password = "typed-in-a-secure-field"; xrM.again = "typed-in-a-secure-field"
        e2Shots("ma-export-move", { ExportPage(entry: mvStudio, model: model, runner: xrM, width: $0) }, height: 3800)
        xrM.password = ""; xrM.again = ""
        let imgM = URL(fileURLWithPath: exportsDir + "/cl_audit all profiles 2026-11-09.dmg")
        try? fm.removeItem(at: imgM)
        var jobM = SessionsExport.Job(parts: [mvStudio, mvTravel].map { SessionsExport.Part(profile: $0.id, name: $0.name, source: SessionsBackup.Source($0), emails: [$0.seat?.email].compactMap { $0 }) },
                                      keys: .keep, password: pw2, destination: imgM, rootName: "cl_audit all profiles 2026-11-09", now: Date().addingTimeInterval(-600))
        jobM.move = true; jobM.profiles = SessionsMove.make([mvStudio, mvTravel], parts: ["mvstudio": "p1", "mvtravel": "p2"], all: [mvStudio, mvTravel], move: true)
        _ = try! SessionsExport.run(jobM)
        // the new Mac: Studio's and Travel's folders aren't on it (moved aside in this throwaway home), this Mac's own settings (none
        // stored), and the list without Studio and Travel
        for id in ["mvstudio", "mvtravel"] {
            for d in [expand("~/.claude-\(id)"), expand("~/Library/Application Support/Claude-\(id)")] { try? fm.moveItem(atPath: d, toPath: d + "-other-mac") }
        }
        SessionsMove.prefs = MemoryPrefs(); BackupPrefs.store.set(nil, forKey: BackupPrefs.lastKey)
        model.accounts = before
        try! Store.save(before)
        let irM = model.importRunner(for: "e2bdst")
        irM.setFile(imgM); irM.password = pw2; irM.open()
        settleE("the move import preview") { irM.phase == .ready && irM.movePlan != nil && irM.counting?.plan != nil }
        irM.takeSettings = true
        @MainActor func importPageM(_ name: String) { e2Shots(name, { ImportPage(entry: e2bdst, model: model, runner: irM, width: $0) }, height: 4400) }
        importPageM("mb-import-move-profiles")
        irM.takeSettings = false
        irM.applyMove()
        settleE("the move's profiles made") { irM.moved != nil && !irM.moveBusy && irM.counting?.plan != nil && irM.phase == .ready && irM.suggestedInto != nil }
        importPageM("mc-import-move-made")
        // Into stays the person's: the page offers Studio, and the person picks it
        irM.setInto("mvstudio")
        settleE("into Studio, counted") { irM.staged?.target == "mvstudio" && irM.counting?.plan != nil && irM.phase == .ready }
        irM.setTasks(true)
        settleE("the move import, tasks added") { irM.plan?.taskPlan.leftOut == false }
        irM.commit()
        if case .running(let keyM) = irM.phase {
            let runM = model.restoreRunner(keyM)
            settleE("the move import ran") { runM.phase == .done }
            importPageM("md-import-move-done")
        } else { print("the move import didn't start: \(irM.note ?? "")") }
    }
}
print("done")
