// The cl_audit agent: a small helper inside cl_audit.app (Contents/Library/LoginItems/cl_audit Agent.app), the same
// program in a third role, and cl_audit's one login item. It has no window and no Dock icon.
//
// Stage 1 (proving the approach): it only writes an "alive" mark, ~/Library/Application Support/usage-n-uf/agent.json,
// every 30 s. Reading usage and the opening and closing rules move into it later.

import AppKit
import ServiceManagement
import os

let agentLog = Logger(subsystem: "local.usage-n-uf", category: "agent")

/// The agent's "alive" mark. No secrets.
struct AgentMark: Codable, Equatable {
    var pid: Int32
    var started: Date
    var beat: Date
    var version: String
    var build: String
    var path: String
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
        if service.status != .enabled {
            log += register() ? " → registered" : " → couldn't register"
            log += waitForMark(build: want) ? ", build \(want) running" : ", build \(want) didn't start"
            return log
        }
        if let m = readMark(), m.build == want, isAlive(m) { return log + " · build \(want) running" }
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

    private static func register() -> Bool {
        do { try service.register(); return true }
        catch { agentLog.error("agent: couldn't register: \(error.localizedDescription, privacy: .public)"); return false }
    }

    /// Waits up to `seconds` for a fresh mark from `build`.
    static func waitForMark(build: String, seconds: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let m = readMark(), m.build == build, isAlive(m) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    /// launchd stops and starts the agent's job (it keeps the agent's label = its bundle id).
    static func restart() {
        Installer.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(bundleID)"])
    }
}

/// The agent role's app delegate: no window, no Dock icon; writes the mark every beat.
final class AgentDelegate: NSObject, NSApplicationDelegate {
    let started = Date()
    let myBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    var timer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        agentLog.log("agent \(self.myBuild, privacy: .public) started, pid \(getpid()), \(Bundle.main.bundlePath, privacy: .public)")
        beat()
        timer = Timer.scheduledTimer(withTimeInterval: Agent.beatSeconds, repeats: true) { [weak self] _ in self?.beat() }
    }

    func beat() {
        let info = Bundle.main.infoDictionary
        Agent.writeMark(AgentMark(pid: getpid(), started: started, beat: Date(),
                                  version: info?["CFBundleShortVersionString"] as? String ?? "?", build: myBuild,
                                  path: Bundle.main.bundlePath))
    }

    func applicationWillTerminate(_ note: Notification) {
        agentLog.log("agent \(self.myBuild, privacy: .public) quitting, pid \(getpid())")
    }
}
