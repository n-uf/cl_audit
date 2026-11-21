// Dock tile plug-in checks (DockTile/Plugin.swift): what the plug-in's entry points reach, and that nothing it reads can make
// it trap. The Dock runs every third-party Dock tile plug-in in one shared process (com.apple.dock.external.extra), so a
// stray read there would run in the Dock, and a crash would take the other apps' tiles down with it.
//
// Each scenario runs the plug-in in a child of this suite, under a sandbox that kills the child (SIGKILL) the moment it reads
// a sign-in (the profile's folder, ~/.claude, ~/.claude.json, the Claude app's folder), touches the Keychain (its files, or
// asks securityd), starts any program (the Keychain tool, claude), opens a network connection, or reads a standby account's
// record. Its entry points run there as the Dock runs them: loaded with a tile, the agent's notice, the profiles' notice,
// the apps' notice, the timer, released; then the same with a broken record, absurd numbers, a broken or empty profile list,
// no bundle, and an update to another build (it leaves, so the Dock loads the new one). Three tripwire scenarios prove the
// sandbox is armed: they do read a sign-in, start a program and read a standby record, and must be killed.
//
// Runs only with HOME and CFFIXED_USER_HOME = .../Checks/.work/docktile/home (Checks/run.sh sets and guards it). Fake data
// only: example.com addresses, made-up sign-in files in the throwaway home. The real home's sign-in paths are named in the
// sandbox only as more tripwires; nothing here reads them, opens an app, the Dock or Terminal, or touches the Keychain.

import AppKit
import ProfileCore

setbuf(stdout, nil)
let home = NSHomeDirectory()
guard home.hasSuffix("/Checks/.work/docktile/home"), expand("~") == home else { print("refusing: HOME is \(home)"); exit(2) }
let fm = FileManager.default
let args = CommandLine.arguments
let id = "dt1", standbyID = "k9"
// a Dock icon copy as Installer.install lays it out: the app, its plug-in in PlugIns
let app = URL(fileURLWithPath: home).appendingPathComponent("cl_audit Dock.app")
let bundle = app.appendingPathComponent("Contents/PlugIns/\(DockTile.bundleName)")
let profileDir = "\(home)/profile-dt1"

func put(_ path: String, _ text: String) {
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    fm.createFile(atPath: path, contents: Data(text.utf8))
}
/// The copy's two Info.plists: the plug-in's (its profile, build and class) and the app's (its build), each as an install
/// writes them.
func plugInfo(build: String, appBuild: String? = nil) {
    let p: NSDictionary = ["CFBundleIdentifier": "local.usage-n-uf.check.docktile", "UsageAccountID": id, "UsageBuild": build,
                           "NSPrincipalClass": DockTile.className(id, build: build)]
    try? fm.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try? p.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    try? (["UsageAccountID": id, "UsageBuild": appBuild ?? build] as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
}

// ============ the child: one scenario in the sandbox ============
if args.count >= 3, args[1] == "--child" {
    let scenario = args[2]
    switch scenario {
    case "trip-signin": _ = try? Data(contentsOf: URL(fileURLWithPath: "\(profileDir)/.credentials.json")); print("not killed"); exit(4)
    case "trip-stat": _ = try? fm.attributesOfItem(atPath: "\(home)/.claude/.credentials.json"); print("not killed"); exit(4)
    case "trip-run": let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try? p.run(); p.waitUntilExit(); print("not killed"); exit(4)
    case "trip-standby": _ = Store.status(standbyID); print("not killed"); exit(4)
    default: break
    }
    _ = NSApplication.shared
    // loaded as the Dock loads a copy: its load-time function with its executable's path registers the copy's class, which
    // is then the one made (no bundle: nothing registered, the plug-in's own class)
    var p = DockTilePlugIn()
    if scenario != "no-bundle" {
        docktileLoaded(bundle.appendingPathComponent("Contents/MacOS/DockTile").path)
        guard let cls = NSClassFromString(DockTile.className(id, build: "b1")) as? NSObject.Type, cls != DockTilePlugIn.self,
              let made = cls.init() as? DockTilePlugIn,
              DockTilePlugIn.profileID == id, DockTilePlugIn.loadedBuild == "b1" else { print("no class"); exit(5) }
        p = made
    }
    p.setDockTile(NSApp.dockTile)
    let dn = DistributedNotificationCenter.default()
    for n in [Store.statusChanged, Store.changed, Installer.appsChangedNote, DockTile.windowNote] {
        dn.postNotificationName(n, object: n == Store.statusChanged || n == DockTile.windowNote ? id : nil, userInfo: nil, deliverImmediately: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }
    // another profile's window notice: not this tile's (no draw; the heartbeat's count says so)
    dn.postNotificationName(DockTile.windowNote, object: "other", userInfo: nil, deliverImmediately: true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    p.redraw("timer")
    if scenario == "update" {
        // an update replaced the copy: seen, then still there 10 s later, the plug-in leaves (its own redraw at 11 s)
        plugInfo(build: "b2")
        p.redraw("timer")
        RunLoop.main.run(until: Date().addingTimeInterval(12))
        print("still here"); exit(3)
    }
    if scenario == "half-install" {
        // an install half done: the plug-in's Info.plist says b2, the app's not yet: it stays
        plugInfo(build: "b2", appBuild: "b1")
        p.redraw("timer")
        RunLoop.main.run(until: Date().addingTimeInterval(12))
        p.redraw("timer")
    }
    if scenario == "menu" {
        // the Dock asks for the menu, then a click on Open Claude window: a notice to the agent, nothing started here
        var heard: [String] = []
        let o = dn.addObserver(forName: DockTile.menuNote, object: nil, queue: .main) { heard.append($0.object as? String ?? "?") }
        guard let m = p.dockMenu() else { print("no menu"); exit(6) }
        let titles = m.items.map(\.title)
        print("menu: \(titles.joined(separator: " | "))")
        if let open = m.items.first(where: { $0.title == "Open Claude window" }) { p.picked(open) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        dn.removeObserver(o)
        print("heard: \(heard.joined(separator: ","))")
    }
    p.setDockTile(nil)
    print("done \(scenario)")
    exit(0)
}

// ============ the parent: the throwaway home, the sandbox, the scenarios ============
var passed = 0, failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passed += 1 } else { failed += 1; print("FAIL (line \(line)): \(what)") }
}
let now = Date()
let ann = Seat(account: "00000000-0000-4000-8000-000000000001", organization: "00000000-0000-4000-8000-0000000000d1", email: "ann@example.com")
var e = AccountEntry(id: id, name: "Dock", label: "DOCK", configDir: profileDir); e.seat = ann
e.standby = [StandbyAccount(email: "bob@example.com", id: standbyID)]
func saveProfiles() { try! Store.save([e]) }
func record(five: Double? = 12, week: Double? = 40, fiveIn: TimeInterval = 3600, weekIn: TimeInterval = 2 * 86400) -> IconStatus {
    var s = IconStatus(state: "ok"); s.loginEmail = ann.email; s.expectedEmail = ann.email; s.fiveHour = five; s.weekly = week
    s.fiveHourResets = now.addingTimeInterval(fiveIn); s.weeklyResets = now.addingTimeInterval(weekIn)
    s.updatedAt = now.addingTimeInterval(-60); s.source = "Anthropic"
    s.resolved = AccountResolver.resolve(e, among: [e], app: .unknown, code: ann, loginEmail: ann.email, names: [:], now: now)
    return s
}
saveProfiles()
// the sign-ins and the standby record the plug-in must never read (sample contents)
put("\(profileDir)/.credentials.json", #"{"sample":"not a real sign-in"}"#)
put("\(profileDir)/.claude.json", #"{"oauthAccount":{"emailAddress":"ann@example.com"}}"#)
put("\(home)/.claude.json", #"{"oauthAccount":{"emailAddress":"ann@example.com"}}"#)
put("\(home)/.claude/.credentials.json", #"{"sample":"not a real sign-in"}"#)
put("\(home)/Library/Application Support/Claude/config.json", "{}")
put("\(home)/Library/Keychains/login.keychain-db", "sample")
_ = Store.writeStatus(standbyID, record(week: 77))
put(Store.statusFolder.appendingPathComponent("\(standbyID).prev").path, "{}")

let real = String(cString: getpwuid(getuid())!.pointee.pw_dir)
func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
// the sign-ins: not even looked at (no stat, no extended attributes), never written
var signIns = ["(subpath \(q(profileDir)))", "(subpath \"/Library/Keychains\")"]
for h in [home, real] {
    signIns += ["(subpath \(q("\(h)/.claude")))", "(literal \(q("\(h)/.claude.json")))",
                "(subpath \(q("\(h)/Library/Application Support/Claude")))", "(subpath \(q("\(h)/Library/Keychains")))"]
}
// the agent's records: only the profile's own is read (the last matching rule wins), none written
let profile = """
(version 1)
(allow default)
(deny file-read-data file-read-metadata file-read-xattr file-write* \(signIns.joined(separator: " ")) (with send-signal SIGKILL))
(deny file-read-data file-write* (subpath \(q(Store.statusFolder.path))) (with send-signal SIGKILL))
(allow file-read-data (literal \(q(Store.statusFolder.appendingPathComponent("\(id).json").path))))
(deny process-fork (with send-signal SIGKILL))
(deny network-outbound (remote ip) (with send-signal SIGKILL))
(deny mach-lookup (global-name "com.apple.securityd") (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd.xpc")
      (global-name "com.apple.secd") (with send-signal SIGKILL))
"""
let profileURL = URL(fileURLWithPath: home).appendingPathComponent("tripwires.sb")
try! profile.write(to: profileURL, atomically: true, encoding: .utf8)

/// One scenario in the sandbox: how it ended (exit code, or the signal that ended it) and what it printed. A trap's own
/// words (its standard error) are printed here, so a failure says where.
func child(_ scenario: String, prepare: () -> Void = {}) -> (code: Int32, signal: Bool, out: String) {
    // a fresh log and heartbeat (the agent's word on the window, in the same folder, stays)
    for u in [DockTile.logURL(id), DockTile.beatURL(id), DockTile.logURL(id).appendingPathExtension("1")] { try? fm.removeItem(at: u) }
    prepare()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    p.arguments = ["-f", profileURL.path, Bundle.main.executablePath!, "--child", scenario]
    let errURL = URL(fileURLWithPath: home).appendingPathComponent("child-\(scenario).err")
    fm.createFile(atPath: errURL.path, contents: nil)
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = try? FileHandle(forWritingTo: errURL)
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let signal = p.terminationReason == .uncaughtSignal
    if signal, p.terminationStatus != SIGKILL, let err = try? String(contentsOf: errURL, encoding: .utf8) {
        print("  \(scenario) ended by signal \(p.terminationStatus): " + err.split(separator: "\n").filter { $0.contains("error") || $0.contains("Fatal") }.prefix(3).joined(separator: " | "))
    }
    return (p.terminationStatus, signal, String(decoding: data, as: UTF8.self))
}
func log() -> String { (try? String(contentsOf: DockTile.logURL(id), encoding: .utf8)) ?? "" }
func beat() -> String { (try? String(contentsOf: DockTile.beatURL(id), encoding: .utf8)) ?? "" }
/// Ended by itself, normally (not killed by a tripwire, not trapped).
func clean(_ r: (code: Int32, signal: Bool, out: String), _ scenario: String) -> Bool {
    !r.signal && r.code == 0 && r.out.contains("done \(scenario)")
}

// the tripwires are armed: a sign-in read or looked at, a program started, a standby record read each end the child at once
for t in ["trip-signin", "trip-stat", "trip-run", "trip-standby"] {
    let r = child(t)
    check(r.signal && r.code == SIGKILL && !r.out.contains("not killed"), "tripwire \(t): the sandbox kills the child (got \(r.code), signal \(r.signal))")
}

// 1. a good record: every entry point runs, none trips a wire; the heartbeat and the log say each draw
plugInfo(build: "b1")
_ = Store.writeStatus(id, record())
let good = child("draw"), goodLog = log()
check(clean(good, "draw"), "a good record: the plug-in ran every entry point and ended normally (got \(good.code), signal \(good.signal))")
check(goodLog.contains("loaded build b1 in ") && goodLog.contains("drew (load) #1: numbers") && goodLog.contains("drew (record)")
      && goodLog.contains("drew (profiles)") && goodLog.contains("drew (apps)") && goodLog.contains("drew (timer)") && goodLog.contains("released"),
      "the log: loaded, drawn on load, on the agent's notice, the profiles' and the apps' notice, the timer; released")
check(goodLog.contains("drew (window)") && !goodLog.contains("· window"), "the agent's window notice redraws it; no word on the window: no open dot")
check(beat().contains("build b1") && beat().contains("draw 6"), "the heartbeat: written on each draw, with the build (\(beat()))")
check(!goodLog.contains("@") && !beat().contains("@"), "no address in the plug-in's log or heartbeat")
check(DockTile.plainID("café") == "café" && DockTile.plainID("привет-2") == "привет-2" && DockTile.plainID("a_b-c") == "a_b-c"
      && [String(repeating: "é", count: 101), "", ".hidden", "../x", "a/b", "a\u{0}b", "a\nb"].allSatisfy { DockTile.plainID($0) == nil }
      && DockTile.className("café", build: "b1").allSatisfy { $0.isASCII },
      "profile ids: any letters (as Store.newID makes them), never a folder step, a hidden name, a control character or >200 bytes")
let stamp = DockTile.lastBeat(id)
check(stamp.map { abs($0.timeIntervalSinceNow) < 60 } == true && DockTile.lastBeat("nobody") == nil, "lastBeat: the heartbeat's time; none for another profile")

// 2. nothing it reads makes it trap: a broken record, absurd numbers, a broken or empty profile list, no bundle
put(Store.statusFolder.appendingPathComponent("\(id).json").path, "{ not json")
let broken = child("bad-record")
check(clean(broken, "bad-record") && log().contains("drew (load) #1: no numbers"), "a broken record: the blank face, no trap")
_ = Store.writeStatus(id, record(five: 1e300, week: -1e300, fiveIn: 1e300, weekIn: -1e300))
let absurd = child("absurd")
check(clean(absurd, "absurd") && log().contains("drew (load) #1: no numbers"),
      "absurd numbers and resets: left out as not read (StatusCodec.drawable), no trap (got \(absurd.code), signal \(absurd.signal))")
_ = Store.writeStatus(id, record(five: 1e300, week: 40, fiveIn: 3600, weekIn: 2 * 86400))
let fullAbsurd = child("absurd-five")
check(clean(fullAbsurd, "absurd-five") && log().contains("drew (load) #1: numbers"),
      "an absurd 5-hour percent beside a good week: the week drawn, no trap (got \(fullAbsurd.code), signal \(fullAbsurd.signal))")
_ = Store.writeStatus(id, record(five: 100, week: 100))
let full = child("full")
check(clean(full, "full") && log().contains("drew (load) #1: numbers"), "both limits full: the countdown face, no trap")
put(Store.configURL.path, "{ not json")
let badList = child("bad-profiles")
check(clean(badList, "bad-profiles") && log().contains("drew (load) #1: no numbers"), "a broken profile list: the unknown face, no trap")
try? fm.removeItem(at: Store.configURL)
try! Store.save([])
let gone = child("gone-profile")
check(clean(gone, "gone-profile") && log().contains("drew (load) #1: no numbers"), "its profile gone from the list: the unknown face, no trap")
try? fm.removeItem(at: Store.configURL)
saveProfiles()
_ = Store.writeStatus(id, record())
let noBundle = child("no-bundle")
check(clean(noBundle, "no-bundle") && log().isEmpty && beat().isEmpty, "no bundle (no profile id): nothing drawn or written, no trap")
var huge = e; huge.pollMinutes = .max
try! JSONEncoder().encode(ConfigFile(accounts: [huge])).write(to: Store.configURL)
let poll = child("poll")
check(clean(poll, "poll") && log().contains("drew (load) #1: numbers"), "an absurd read interval in the profile list: drawn, no overflow")
saveProfiles()
// a FIFO where the record or the log is: never waited on (the Dock's thread would hang), drawn without it
let recordPath = Store.statusFolder.appendingPathComponent("\(id).json").path
try? fm.removeItem(atPath: recordPath); mkfifo(recordPath, 0o644)
let fifoRecord = child("fifo-record")
check(clean(fifoRecord, "fifo-record") && log().contains("drew (load) #1: no numbers"), "a FIFO for the record: no numbers, no wait")
try? fm.removeItem(atPath: recordPath)
_ = Store.writeStatus(id, record())
let fifoLog = child("fifo-log") {
    try? fm.createDirectory(at: DockTile.folder, withIntermediateDirectories: true)
    mkfifo(DockTile.logURL(id).path, 0o644)
}
check(clean(fifoLog, "fifo-log") && beat().contains("draw 6"), "a FIFO for the log: never opened, the heartbeat still written")
// the window dot: the agent's word on the profile's Claude window (DockTile.setWindowOpen), drawn when the profile shows it
DockTile.setWindowOpen(id, true)
let window = child("window")
check(clean(window, "window") && log().contains("drew (load) #1: numbers · window") && DockTile.windowOpen(id),
      "the agent says the window is open: the tile draws the open dot")
DockTile.setWindowOpen(id, false)
check(!DockTile.windowOpen(id), "the agent says it closed: no dot")
var noDot = e; noDot.windowDot = false
try! JSONEncoder().encode(ConfigFile(accounts: [noDot])).write(to: Store.configURL)
DockTile.setWindowOpen(id, true)
let windowNoDot = child("window-no-dot")
check(clean(windowNoDot, "window-no-dot") && !log().contains("· window"), "the profile shows no window dot: none drawn")
DockTile.setWindowOpen(id, false)
saveProfiles()

// 3. the agent's rule while the Dock draws the tiles (TileTracker), tick by tick (every 30 s): quit what it started once
// drawn, open a copy once in a run, then as before until a heartbeat comes back; a minute's patience after sleep
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
func facts(pinned: Bool = true, running: Bool = false, ours: Bool = false, front: Bool = false, beat: Date? = nil) -> TileTracker.Facts {
    TileTracker.Facts(pinned: pinned, running: running, ours: ours, inFront: front, lastBeat: beat)
}
/// Ticks of one profile: (seconds, its facts then) → what the tracker said at each.
func run(_ ticks: [(TimeInterval, TileTracker.Facts)], _ t: inout TileTracker) -> [TileTracker.Act] {
    ticks.map { s, f in t.tick(now: at(s)); return t.step("p", f, now: at(s)) }
}
do {
    var t = TileTracker(now: t0)
    check(run([(30, facts(running: true, ours: true, beat: at(20)))], &t) == [.quit], "drawn, the agent's app running: it quits")
    t = TileTracker(now: t0)
    check(run([(30, facts(running: true, beat: at(20))), (60, facts(running: true, ours: true, front: true, beat: at(50)))], &t) == [.none, .none],
          "drawn, but an app you started, or the agent's while it's in front: it stays")
    t = TileTracker(now: t0)
    // no tile, not running: patience for a minute and two stale ticks, then opened once; running and still none: as before
    let opened = run([(30, facts()), (60, facts()), (90, facts(running: true, ours: true)), (120, facts(running: true, ours: true)),
                      (150, facts(running: true, ours: true))], &t)
    check(opened == [.none, .openOnce, .none, .asBefore, .none], "no tile: opened once after a minute, as before a minute later (got \(opened))")
    check(t.asBefore("p"), "as before is remembered: the rules start its Dock icon app again")
    let back = run([(180, facts(running: true, ours: true, beat: at(175)))], &t)
    check(back == [.quit] && !t.asBefore("p"), "a heartbeat comes back (Dock Tiles on again): the app the agent ran quits")
    // a tile that beats only while its app runs: quit once, then none again → the app keeps running (no restart loop)
    t.ready("p", now: at(190))
    let loop = run([(220, facts(beat: at(175))), (250, facts(beat: at(175))), (280, facts(beat: at(175))), (310, facts(beat: at(175))),
                    (340, facts(running: true, ours: true, beat: at(335))), (370, facts(running: true, ours: true, beat: at(365)))], &t)
    check(loop == [.none, .none, .none, .asBefore, .none, .none] && t.asBefore("p"),
          "drawn only while running: after one quit and no tile again, it runs as before and isn't quit again (got \(loop))")
    t.forget("p")
    check(!t.asBefore("p") && run([(400, facts()), (430, facts())], &t) == [.none, .openOnce],
          "a new copy (another build): it starts over, its one open included")
    check(DockTile.agentStarted(["/x", "--no-follow"]) && !DockTile.agentStarted(["/x"])
          && !DockTile.agentStarted(["/x", "--no-follow", DockTile.startedByYou]),
          "the agent's own start: --no-follow, and not an update's restart of one you started")
    t = TileTracker(now: t0)
    // once in a run: opened, then quit (by you, or its window's rule) with still no tile: as before, not opened again
    _ = run([(30, facts()), (60, facts())], &t)
    t.ready("p", now: at(70))
    let again = run([(90, facts()), (120, facts()), (150, facts())], &t)
    check(again == [.none, .none, .asBefore], "opened once in a run: no tile after it quit means as before, never opened again (got \(again))")
    t = TileTracker(now: t0)
    // after sleep (a tick long after the last one) every heartbeat is old: a minute's patience, not a launch of every copy
    _ = run([(30, facts(beat: at(25))), (60, facts(beat: at(55)))], &t)
    let woke = run([(700, facts(beat: at(55))), (730, facts(beat: at(55))), (760, facts(beat: at(55)))], &t)
    check(woke == [.none, .none, .openOnce], "after a 10-minute gap: patience again, opened only a minute later (got \(woke))")
    t = TileTracker(now: t0)
    _ = run([(30, facts(beat: at(25)))], &t)
    t.woke(now: at(40))
    check(run([(70, facts(beat: at(-100))), (90, facts(beat: at(-100))), (100, facts(beat: at(-100)))], &t) == [.none, .none, .openOnce],
          "the wake notice: patience again from it (a minute after the wake, not after the last heartbeat)")
    t = TileTracker(now: t0)
    check(run([(30, facts(beat: at(3600))), (60, facts(beat: at(3600))), (90, facts(beat: at(3600)))], &t) == [.none, .openOnce, .none],
          "a heartbeat in the future (a clock change) counts as none")
    t = TileTracker(now: t0)
    check(run([(30, facts(pinned: false)), (60, facts(pinned: false)), (90, facts(pinned: false))], &t) == [.none, .none, .none],
          "not in the Dock: never opened for a tile")
    t = TileTracker(now: t0)
    check(run([(30, facts(running: true)), (60, facts(running: true)), (90, facts(running: true))], &t) == [.none, .none, .none],
          "an app you started, no tile: left alone")
    t = TileTracker(now: t0)
    check(run([(60, facts(beat: at(-31)))], &t) == [.none], "one stale tick after a minute isn't enough (two in a row)")
}

// 4. the Dock tile's own menu (DockTileMenu): the usage and the actions, no address; its actions are notices to the agent
do {
    var win = e; win.claudeWindow = true
    let show = ProfileShow.of(win, raw: record(), now: now)
    let rows = DockTileMenu.rows(win, show, windowOpen: false, now: now)
    let infos = rows.compactMap { if case .info(let s) = $0 { return s } else { return nil } }
    let acts = rows.compactMap { if case .action(let s, let a) = $0 { return "\(s)=\(a.rawValue)" } else { return nil } }
    check(infos.first == "Dock" && infos.contains { $0.hasPrefix("5-hour limit: 12% · resets ") } && infos.contains { $0.hasPrefix("Weekly limit: 40% · resets ") }
          && infos.contains("Updated 1 min ago"),
          "the menu: the profile's name, its limits with their resets and the reading's age (got \(infos))")
    check(acts == ["Quick chat=quickChat", "Open Claude window=openWindow", "Refresh now=refresh", "Dashboard=dashboard", "Profile settings…=settings"],
          "the menu's actions, in order (got \(acts))")
    let open = DockTileMenu.rows(win, show, windowOpen: true, now: now).compactMap { if case .action(let s, _) = $0 { return s } else { return nil } }
    check(open.contains("Show Claude window") && open.contains("Quit Claude window"), "its window open: Show and Quit Claude window")
    var noWin = e; noWin.claudeWindow = false
    let noWinActs = DockTileMenu.rows(noWin, show, windowOpen: false, now: now).compactMap { if case .action(_, let a) = $0 { return a } else { return nil } }
    check(!noWinActs.contains(.openWindow) && !noWinActs.contains(.quitWindow), "no Claude window: no window actions")
    let none = DockTileMenu.rows(win, ProfileShow.of(win, raw: nil, now: now), windowOpen: false, now: now)
    check(none.contains(.info("No usage read yet")), "no reading yet: said so")
    let full = DockTileMenu.rows(win, ProfileShow.of(win, raw: record(five: 100, week: 40), now: now), windowOpen: false, now: now)
    check(full.contains { if case .full(let s) = $0 { return s.hasPrefix("5-hour full") } else { return false } }, "a full limit: its crimson line first")
    let all = [rows, none, full].flatMap { $0 }.map { r -> String in
        switch r { case .info(let s), .full(let s), .action(let s, _): return s; case .separator: return "" }
    }
    check(!all.contains { $0.contains("@") }, "the menu never shows an address")
    let noAgent = DockTileMenu.rows(win, show, windowOpen: false, agentRuns: false, now: now)
    check(noAgent.contains(.info("cl_audit's agent isn't running: open cl_audit"))
          && !noAgent.contains { if case .action = $0 { return true } else { return false } },
          "no agent running: the menu says so and offers no action (none would happen)")
    // the agent's mark (a capped read): written within three beats counts as running; none, old or in the future: not
    try? fm.removeItem(at: Agent.markURL)
    check(!DockTile.agentRuns(), "no agent mark: not running")
    func mark(_ beat: Date) { Agent.writeMark(AgentMark(pid: getpid(), started: beat, beat: beat, version: "check", build: "check", path: "/check")) }
    mark(Date())
    check(DockTile.agentRuns(), "a mark just written: running")
    mark(Date().addingTimeInterval(-200))
    check(!DockTile.agentRuns(), "a mark 200 s old (three beats are 90 s): not running")
    mark(Date().addingTimeInterval(3600))
    check(!DockTile.agentRuns(), "a mark an hour in the future: not running")
    mark(Date().addingTimeInterval(3))
    check(DockTile.agentRuns(), "a mark 3 s ahead (a small clock step): running")
    var paused = AgentMark(pid: getpid(), started: Date(), beat: Date(), version: "check", build: "check", path: "/check")
    paused.pausedUntil = Date().addingTimeInterval(300)
    Agent.writeMark(paused)
    check(!DockTile.agentRuns(), "a fresh mark of an agent paused after crashes: not listening, so not running")
    check(DockTileMenu.parse(DockTileMenu.object(.openWindow, "dt1")).map { "\($0.0.rawValue) \($0.1)" } == "openWindow dt1"
          && DockTileMenu.parse(DockTileMenu.object(.settings, "a:b")).map { $0.1 } == "a:b"
          && DockTileMenu.parse("nonsense:dt1") == nil && DockTileMenu.parse("openWindow:") == nil && DockTileMenu.parse(nil) == nil,
          "the agent's notice: <action>:<id>, the id may hold a colon; anything else ignored")
    // a Dock icon app you started quits once left for a minute while the Dock draws the icon
    check(DockTile.quitsWhenIdle(agentStarted: false, drawn: true, inFront: false, windowShown: false, idleFor: 60)
          && !DockTile.quitsWhenIdle(agentStarted: false, drawn: true, inFront: false, windowShown: false, idleFor: 59)
          && !DockTile.quitsWhenIdle(agentStarted: true, drawn: true, inFront: false, windowShown: false, idleFor: 600)
          && !DockTile.quitsWhenIdle(agentStarted: false, drawn: false, inFront: false, windowShown: false, idleFor: 600)
          && !DockTile.quitsWhenIdle(agentStarted: false, drawn: true, inFront: true, windowShown: false, idleFor: 600)
          && !DockTile.quitsWhenIdle(agentStarted: false, drawn: true, inFront: false, windowShown: true, idleFor: 600),
          "your Dock icon app quits after a minute left alone, only while the Dock draws the icon; never the agent's, in front or showing a panel")
}
plugInfo(build: "b1")
_ = Store.writeStatus(id, record())
Agent.writeMark(AgentMark(pid: getpid(), started: Date(), beat: Date(), version: "check", build: "check", path: "/check"))
let menu = child("menu")
check(clean(menu, "menu") && menu.out.contains("menu: Dock | ") && menu.out.contains("Open Claude window")
      && menu.out.contains("heard: openWindow:\(id)") && !menu.out.contains("@") && log().contains("menu: openWindow"),
      "the plug-in's menu in the Dock's place: built from the record, Open Claude window asks the agent, no tripwire (got \(menu.out))")

// 5. an update: the copy is now another build, so the old code leaves and the Dock loads the new one; not mid-install
plugInfo(build: "b1")
let half = child("half-install")
check(clean(half, "half-install") && !log().contains("leaving"), "an install half done (the app still on b1): the plug-in stays")
plugInfo(build: "b1")
let update = child("update")
check(!update.signal && update.code == 0 && !update.out.contains("still here") && log().contains("the copy is now build b2: leaving"),
      "an update to build b2: the plug-in leaves once the copy says b2 for 10 s (got \(update.code), signal \(update.signal))")

print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
