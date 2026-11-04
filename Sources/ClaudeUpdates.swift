// Claude updates: the agent reopens the profile windows a Claude update closed.
//
// Claude 4.x updates itself quietly. Once a window has downloaded the update and sits idle, it quits by itself and logs
// "[stealth-update] Triggering stealth update after idle timeout" (~/Library/Logs/Claude/main.log); the install waits
// until every window has quit, and afterwards Claude opens only its standard window again. Profile windows (their own
// data folder) stay closed, with their Claude Code sessions stopped, until someone opens them.
//
// So the agent looks every 30 s: a profile window that quits within a few minutes after that log line counts as closed
// by the update. When Claude's installed version then changes (the install is done), each of those windows is opened
// again, in the background, and one alert says so. A window you closed yourself never counts (no log line just before
// it), nothing is reopened that you opened again first, and only profiles with their Claude window switch on.

import AppKit
import os

enum ClaudeUpdates {
    struct State: Codable, Equatable {
        var version: String?                        // Claude's installed version at the last look
        var open: Set<String> = []                  // profiles whose window was open at the last look
        var closedByUpdate: [String: Date] = [:]    // profile id → when its window quit for the update
    }

    /// A window that quits this long after the log line (or up to a minute before it) counts as the update's.
    static let window: TimeInterval = 5 * 60
    /// Records older than this are dropped: the update never came.
    static let keep: TimeInterval = 24 * 3600

    /// One look. Returns the profiles whose windows to open again now (in profile order).
    static func step(_ s: inout State, now: Date, order: [String], open: Set<String>, eligible: Set<String>,
                     version: String?, stealthAt: Date?) -> [String] {
        for id in s.open.subtracting(open) {
            if let t = stealthAt, now.timeIntervalSince(t) >= -60, now.timeIntervalSince(t) <= window {
                s.closedByUpdate[id] = now
            }
        }
        for id in open { s.closedByUpdate[id] = nil }          // open again (you, or Claude): nothing to do
        s.closedByUpdate = s.closedByUpdate.filter { now.timeIntervalSince($0.value) < keep && order.contains($0.key) }
        s.open = open
        var reopen: [String] = []
        if let v = version, let old = s.version, v != old {
            reopen = order.filter { s.closedByUpdate[$0] != nil && eligible.contains($0) && !open.contains($0) }
            s.closedByUpdate = [:]
        }
        if let version { s.version = version }
        return reopen
    }

    // MARK: what it reads

    /// Claude's installed version ("1.2.3"), read fresh from its Info.plist.
    static func installedVersion() -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Launcher.claudeBundleID) else { return nil }
        let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return (plist?["CFBundleShortVersionString"] as? String) ?? (plist?["CFBundleVersion"] as? String)
    }

    static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude/main.log")
    }

    /// When Claude last logged that it quits for an update, from the end of its log (the last 256 KB).
    static func lastStealthUpdate(in file: URL = logFile) -> Date? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        guard let line = text.split(separator: "\n").last(where: { $0.contains("[stealth-update] Triggering stealth update") })
        else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: String(line.prefix(19)))
    }
}

/// The agent's side: looks on each tick, keeps its state across restarts, opens the windows and sends the alert.
final class ClaudeUpdateWatch {
    private let defaults: UserDefaults
    private var state: ClaudeUpdates.State
    private static let key = "claudeUpdates"
    private let log = Logger(subsystem: "local.usage-n-uf", category: "agent")

    /// Tests only: the windows that are open, Claude's version and the log line's time, instead of the real ones; and
    /// what opening a window does.
    var testInputs: ((_ entries: [AccountEntry]) -> (open: Set<String>, version: String?, stealthAt: Date?))?
    var testOpener: ((AccountEntry) -> Void)?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        state = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ClaudeUpdates.State.self, from: $0) }
            ?? ClaudeUpdates.State()
    }

    func tick(_ entries: [AccountEntry], now: Date = Date()) {
        let fake = testInputs?(entries)
        let open: Set<String>
        if let fake { open = fake.open } else {
            let activity = Launcher.activity(for: entries.map(Account.init))
            open = Set(entries.filter { activity[Account($0).configDir]?.desktopOpen == true }.map(\.id))
        }
        let eligible = Set(entries.filter(\.claudeWindow).map(\.id))
        // the log is read only when a window has just quit
        let quit = !state.open.subtracting(open).isEmpty
        let stealthAt = fake.map { quit ? $0.stealthAt : nil } ?? (quit ? ClaudeUpdates.lastStealthUpdate() : nil)
        let before = state
        let version = fake.map(\.version) ?? ClaudeUpdates.installedVersion()
        let reopen = ClaudeUpdates.step(&state, now: now, order: entries.map(\.id), open: open, eligible: eligible,
                                        version: version, stealthAt: stealthAt)
        for id in state.closedByUpdate.keys where before.closedByUpdate[id] == nil {
            log.log("claude update: \(id, privacy: .public)'s window quit for the update; reopened when it's installed")
        }
        if state != before, let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.key) }
        guard !reopen.isEmpty else { return }
        let names = reopen.compactMap { id in entries.first { $0.id == id } }.map { e -> String in
            if let testOpener { testOpener(e) } else { Launcher.openClaude(Account(e), activate: false) }
            return e.name
        }
        log.log("claude update: updated to \(version ?? "?", privacy: .public); reopened \(names.joined(separator: ", "), privacy: .public)")
        let body = names.count == 1 ? "Reopened \(names[0])'s window" : "Reopened the windows of \(Self.list(names))"
        let me = version ?? "update"
        DispatchQueue.global(qos: .utility).async {
            _ = UsageReader.post(id: "claude-update.\(me)", title: "Claude updated" + (version.map { " to \($0)" } ?? ""),
                                 body: body, thread: "claude-update")
        }
    }

    /// "Work", "Work and Side", "Work, Side and Lab".
    static func list(_ names: [String]) -> String {
        names.count <= 2 ? names.joined(separator: " and ") : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
