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
    for n in [Store.statusChanged, Store.changed, Installer.appsChangedNote] {
        dn.postNotificationName(n, object: n == Store.statusChanged ? id : nil, userInfo: nil, deliverImmediately: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }
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
let ann = Seat(account: "00000000-0000-4000-8000-000000000001", organization: "00000000-0000-4000-8000-000000000101", email: "ann@example.com")
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
    try? fm.removeItem(at: DockTile.folder)
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
check(beat().contains("build b1") && beat().contains("draw 5"), "the heartbeat: written on each draw, with the build (\(beat()))")
check(!goodLog.contains("@") && !beat().contains("@"), "no address in the plug-in's log or heartbeat")
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
check(clean(fifoLog, "fifo-log") && beat().contains("draw 5"), "a FIFO for the log: never opened, the heartbeat still written")

// 3. an update: the copy is now another build, so the old code leaves and the Dock loads the new one; not mid-install
plugInfo(build: "b1")
let half = child("half-install")
check(clean(half, "half-install") && !log().contains("leaving"), "an install half done (the app still on b1): the plug-in stays")
plugInfo(build: "b1")
let update = child("update")
check(!update.signal && update.code == 0 && !update.out.contains("still here") && log().contains("the copy is now build b2: leaving"),
      "an update to build b2: the plug-in leaves once the copy says b2 for 10 s (got \(update.code), signal \(update.signal))")

print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
