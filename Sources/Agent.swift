// The cl_audit agent: a small helper inside cl_audit.app (Contents/Library/LoginItems/cl_audit Agent.app), the same
// program in a third role, and cl_audit's one login item. It has no window and no Dock icon.
//
// It reads the usage for every profile (one UsageReader each, Reader.swift, on the profile's own interval), checks the
// account, renews the sign-in and sends every alert, as "cl_audit". It saves what it sees to status/<id>.json, which
// the Dock icons and the cl_audit window only read, and writes an "alive" mark, usage-n-uf/agent.json, every 30 s,
// so the window can tell "nothing is reading" from "Anthropic didn't answer". Nothing that quits a Dock icon or a
// Claude window stops it; launchd starts it at login and again after a crash.

import AppKit
import ServiceManagement
import UserNotifications
import os

let agentLog = Logger(subsystem: "local.usage-n-uf", category: "agent")

/// The agent's "alive" mark. No secrets, no e-mail addresses.
struct AgentMark: Codable, Equatable {
    var pid: Int32
    var started: Date
    var beat: Date
    var version: String
    var build: String
    var path: String
    var profiles: Int? = nil          // how many profiles it reads
    var failing: [String]? = nil      // profiles Anthropic didn't answer for the last time
    var pollRange: [Int]? = nil       // the shortest and longest refresh interval, in minutes
    var pausedUntil: Date? = nil      // it crashed several times in a row and waits before reading again
    var actions: [String: AgentAction]? = nil   // what it's doing for a profile now (Opening and closing)
    var stamp: String? = nil          // its program's fingerprint (an update with the same build number differs here)
}

enum Agent {
    /// Its own bundle id, outside "local.usage-n-uf.<profile id>", so it's never taken for a Dock icon app or for a
    /// removed profile's leftovers.
    static let bundleID = "local.usage-n-uf-agent"
    static let appName = "cl_audit Agent.app"
    static let beatSeconds: TimeInterval = 30
    static var markURL: URL { Store.folder.appendingPathComponent("agent.json") }

    /// This process is the agent.
    static var isAgent: Bool { Bundle.main.bundleIdentifier == bundleID }

    /// The helper inside a cl_audit.app.
    static func helperURL(in app: URL = Bundle.main.bundleURL) -> URL {
        app.appendingPathComponent("Contents/Library/LoginItems/\(appName)")
    }

    /// A launch agent (Contents/Library/LaunchAgents in cl_audit.app) that runs the helper: launchd starts it at
    /// login and again after a crash.
    static let plistName = "\(bundleID).plist"
    static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    static func statusText(_ s: SMAppService.Status) -> String {
        switch s {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notFound: return "not found"
        @unknown default: return "unknown (\(s.rawValue))"
        }
    }

    // MARK: the mark

    static func readMark() -> AgentMark? {
        guard let data = try? Data(contentsOf: markURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(AgentMark.self, from: data)
    }

    static func writeMark(_ m: AgentMark) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(m) else { return }
        try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
        try? data.write(to: markURL, options: .atomic)
    }

    /// The mark is fresh (at most three beats old) and its process still runs.
    static func isAlive(_ m: AgentMark?) -> Bool {
        guard let m else { return false }
        return Date().timeIntervalSince(m.beat) < beatSeconds * 3 && kill(m.pid, 0) == 0
    }

    // MARK: cl_audit's side

    /// The build of a cl_audit.app on disk (CFBundleVersion).
    static func build(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String
    }

    /// Run by cl_audit when it starts and after an install (blocks up to ~25 s, so off the main thread): registers the
    /// agent once (macOS then starts it now and at every login), and restarts it when it runs an older build than
    /// this cl_audit.app holds. An update changes only the agent, not the launcher launchd starts, so a restart is
    /// enough. Only if the launcher itself changed (a new compiler) does macOS refuse it: then it's registered
    /// again, which shows macOS's "background item added" notice once.
    @discardableResult
    static func ensureRunning() -> String {
        let app = Bundle.main.bundleURL
        guard FileManager.default.fileExists(atPath: helperURL(in: app).path), let want = build(of: app) else {
            return "agent: none in this build"
        }
        var log = "agent: \(statusText(service.status))"
        defer { agentLog.log("\(log, privacy: .public)") }
        clearDownloadMark(app)
        if service.status != .enabled {
            log += register() ? " → registered" : " → couldn't register"
            log += waitForMark(build: want) ? ", build \(want) running" : ", build \(want) didn't start"
            return log
        }
        let stamp = Installer.buildStamp(helperURL(in: app))
        if let m = readMark(), m.build == want, m.stamp.map({ $0 == stamp }) ?? true, isAlive(m) { return log + " · build \(want) running" }
        log += isAlive(readMark()) ? " · running build \(readMark()?.build ?? "?"), restarting for \(want)" : " · not running, starting"
        restart()
        if waitForMark(build: want) { return log + " → build \(want) running" }
        // macOS knows a program it may start by its exact hash: let Launch Services see this copy, give the
        // background-item records a moment to catch up, then register again.
        log += " → refused; registering again"
        Installer.run(AccountRemoval.lsregister, ["-f", app.path])
        Thread.sleep(forTimeInterval: 10)
        try? service.unregister()
        Thread.sleep(forTimeInterval: 2)
        log += register() && waitForMark(build: want) ? " → build \(want) running" : " → build \(want) didn't start"
        return log
    }

    /// A downloaded cl_audit carries macOS's download mark on every file in it, the agent's too. You allowed cl_audit
    /// itself when you first opened it; launchd starts the agent's launcher directly, so the mark is taken off the
    /// agent's parts here (as for the Dock icon copies). The code signature doesn't cover it and stays valid.
    static func clearDownloadMark(_ app: URL) {
        for part in ["Contents/Helpers", "Contents/Library"] {
            let u = app.appendingPathComponent(part)
            guard FileManager.default.fileExists(atPath: u.path) else { continue }
            Installer.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", u.path])
        }
    }

    private static func register() -> Bool {
        do { try service.register(); return true }
        catch { agentLog.error("agent: couldn't register: \(error.localizedDescription, privacy: .public)"); return false }
    }

    /// Waits up to `seconds` for a fresh mark from `build`.
    static func waitForMark(build: String, seconds: TimeInterval = 12) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let m = readMark(), m.build == build, isAlive(m) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    /// launchd stops and starts the agent's job (it keeps the agent's label = its bundle id). Marked as planned, so
    /// the agent doesn't count it as a crash.
    static func restart() {
        UserDefaults(suiteName: bundleID)?.set(Date(), forKey: "plannedRestart")
        // launchctl can wait for ever on a job that couldn't start (after cl_audit was in the Trash, say)
        Installer.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(bundleID)"], timeout: 10)
    }

    /// Asks the agent to renew a profile's sign-in now (object: the profile id).
    static let renewNote = Notification.Name("local.usage-n-uf.renew")
    /// Posted when the agent starts or ends something it shows on the dashboard (its mark's actions).
    static let actionsChangedNote = Notification.Name("local.usage-n-uf.agent-actions")

    /// What the agent is doing, for the window's main display.
    enum Health: Equatable {
        case reading(profiles: Int, minPoll: Int, maxPoll: Int)
        case failing(Int)             // Anthropic didn't answer for this many profiles
        case paused(until: Date)      // crashed several times in a row
        case stopped
    }

    static func health(_ m: AgentMark? = readMark()) -> Health {
        guard let m, isAlive(m) else { return .stopped }
        if let p = m.pausedUntil, p > Date() { return .paused(until: p) }
        if let f = m.failing, !f.isEmpty { return .failing(f.count) }
        let r = m.pollRange ?? []
        return .reading(profiles: m.profiles ?? 0, minPoll: r.first ?? 5, maxPoll: r.last ?? 5)
    }
}

/// The agent role's app delegate: no window, no Dock icon. Reads every profile's usage on a 30 s tick and writes
/// the mark each time.
final class AgentDelegate: NSObject, NSApplicationDelegate {
    let started = Date()
    let myBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    let defaults = UserDefaults.standard
    var timer: Timer?
    var readers: [String: UsageReader] = [:]
    var order: [String] = []
    var pausedUntil: Date?
    var rules: AgentRules?
    private var cleanupWork: DispatchWorkItem?
    private var cleanupTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var askedForAlerts = false
    private let myStamp = Installer.buildStamp(Bundle.main.bundleURL)
    /// Keeps macOS from napping the agent: its 30 s reads and its alive mark must keep time.
    private let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                                 reason: "cl_audit reads Claude usage for every profile")

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        agentLog.log("agent \(self.myBuild, privacy: .public) started, pid \(getpid()), \(Bundle.main.bundlePath, privacy: .public)")
        pausedUntil = Self.crashBackoff(defaults)
        beat()
        if let until = pausedUntil {
            agentLog.error("agent: started \(Self.recentStarts(self.defaults)) times in 10 min, waiting until \(until, privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: .now() + until.timeIntervalSinceNow) { [weak self] in self?.begin() }
            timer = Timer.scheduledTimer(withTimeInterval: Agent.beatSeconds, repeats: true) { [weak self] _ in self?.beat() }
        } else {
            begin()
        }
    }

    private func begin() {
        pausedUntil = nil
        let dn = DistributedNotificationCenter.default()
        observers.append(dn.addObserver(forName: Store.changed, object: nil, queue: .main) { [weak self] _ in self?.reload() })
        observers.append(dn.addObserver(forName: Installer.refreshAllNote, object: nil, queue: .main) { [weak self] note in
            self?.refresh(note.object as? String)
        })
        observers.append(dn.addObserver(forName: Agent.renewNote, object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? String else { return }
            self?.readers[id]?.renewLogin()
        })
        reload()
        // Opening and closing and Usage in the Dock (Rules.swift)
        let r = AgentRules(defaults: defaults)
        r.onChange = { [weak self] in
            self?.beat()
            DistributedNotificationCenter.default().postNotificationName(Agent.actionsChangedNote, object: nil, userInfo: nil, deliverImmediately: true)
        }
        rules = r
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Agent.beatSeconds, repeats: true) { [weak self] _ in self?.tick() }
        // once the readers run: what older versions left behind (per-profile login items), then the clean-up
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            LegacyCleanup.run(Store.load(), defaults: self.defaults)
            Cleanup.runSoon("start")
        }
        // the clean-up again after every saved change (a moment later, once) and every 6 hours
        observers.append(dn.addObserver(forName: Store.changed, object: nil, queue: .main) { [weak self] _ in
            self?.cleanupWork?.cancel()
            let w = DispatchWorkItem { Cleanup.runSoon("after a change") }
            self?.cleanupWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
        })
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in Cleanup.runSoon("every 6 hours") }
    }

    /// The profiles file changed: a reader for each profile, in the file's order; a removed profile's reader,
    /// saved status and alert marks go.
    func reload() {
        guard let list = Store.loadChecked() else { return }
        let ids = Set(list.map(\.id))
        for id in readers.keys where !ids.contains(id) {
            readers[id]?.stop()
            readers[id] = nil
            UsageReader.forget(id, in: defaults)
            Store.removeStatus(id)
            agentLog.log("agent: \(id, privacy: .public) removed")
        }
        var fresh = 0
        for e in list {
            if let r = readers[e.id] { r.update(e) }
            else {
                // new readers start a couple of seconds apart, each read on time (not at the next tick)
                let r = UsageReader(e, defaults: defaults, startIn: Double(fresh) * 2)
                readers[e.id] = r
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(fresh) * 2 + 0.1) { [weak r] in r?.tick() }
                fresh += 1
            }
        }
        order = list.map(\.id)
        askForAlerts(list)
        rules?.update(list)
        beat()
    }

    func tick() {
        // cl_audit was moved to the Trash (the agent runs inside it): offer to remove what belongs to it
        if let p = Uninstall.currentExecutablePath(), Uninstall.inTrash(p) {
            Uninstall.offerTrashCleanup(defaults: defaults, where: p.components(separatedBy: "/Contents/").first ?? p)
        }
        for id in order { readers[id]?.tick() }
        rules?.tick()
        beat()
        // ten minutes without crashing: earlier starts no longer count towards a pause
        if Date().timeIntervalSince(started) > 600 { defaults.removeObject(forKey: "agentStarts") }
    }

    /// Refresh now: one profile (object: its id) or all of them.
    func refresh(_ id: String?) {
        if let id { readers[id]?.refreshNow() } else { order.forEach { readers[$0]?.refreshNow() } }
        beat()
    }

    /// Alerts come from cl_audit, so macOS asks once to allow them (only when some profile has them on).
    private func askForAlerts(_ list: [AccountEntry]) {
        guard !askedForAlerts, list.contains(where: \.notify) else { return }
        askedForAlerts = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, err in
            agentLog.log("agent: alerts \(granted ? "allowed" : "not allowed", privacy: .public)\(err.map { " (\($0.localizedDescription))" } ?? "", privacy: .public)")
        }
    }

    func beat() {
        let info = Bundle.main.infoDictionary
        let polls = order.compactMap { readers[$0]?.entry.pollMinutes }.map { max($0, 1) }
        Agent.writeMark(AgentMark(pid: getpid(), started: started, beat: Date(),
                                  version: info?["CFBundleShortVersionString"] as? String ?? "?", build: myBuild,
                                  path: Bundle.main.bundlePath,
                                  profiles: pausedUntil == nil ? order.count : 0,
                                  failing: order.filter { readers[$0]?.failing == true },
                                  pollRange: polls.isEmpty ? nil : [polls.min()!, polls.max()!],
                                  pausedUntil: pausedUntil,
                                  actions: rules?.actions,
                                  stamp: myStamp))
    }

    // MARK: crashing again and again

    static func recentStarts(_ d: UserDefaults) -> Int { (d.array(forKey: "agentStarts") as? [Date])?.count ?? 0 }

    /// launchd starts the agent again a moment after it crashes. Started four times or more within ten minutes, it
    /// waits before reading again (1 min, doubling up to 30 min) and stays up meanwhile, so it doesn't crash in a
    /// loop. Restarts cl_audit asks for (an update) don't count.
    static func crashBackoff(_ d: UserDefaults) -> Date? {
        let now = Date()
        if let planned = d.object(forKey: "plannedRestart") as? Date, now.timeIntervalSince(planned) < 30 {
            d.removeObject(forKey: "plannedRestart")
            return nil
        }
        var starts = (d.array(forKey: "agentStarts") as? [Date] ?? []).filter { now.timeIntervalSince($0) < 600 }
        starts.append(now)
        d.set(starts, forKey: "agentStarts")
        guard starts.count >= 4 else { return nil }
        return now.addingTimeInterval(min(60 * pow(2, Double(starts.count - 4)), 1800))
    }

    func applicationWillTerminate(_ note: Notification) {
        agentLog.log("agent \(self.myBuild, privacy: .public) quitting, pid \(getpid())")
    }
}
