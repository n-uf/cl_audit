// AppSignIn: which claude.ai account the Claude app is signed in to, read the way claude-transplant 4.2.1 reads it
// (transplant.js, signedIn()): the app's main*.log, newest file first and each from its end, after the app's launch.
//
// - "[LocalSessionManager] Initialization succeeded … accountId=<uuid>, orgId=<uuid>" names the account;
// - "[account] Login-state transition … loggedOut: … → true" or "[LocalSessionManager] Account logged out" means signed out;
// - another [LocalSessionManager] line about the account (Org changed, Cannot initialize sessions, loadSessions failed),
//   a line before the launch, the file's last (maybe half-written) line or an id that isn't a UUID: unknown;
// - the account named is cross-checked with the data folder's config.json lastKnownAccountUuid: another id there means
//   unknown.
//
// Only those lines are looked at, and only the ids, the time and the signed-out flag are kept: nothing else from the log
// (it holds paths and session titles). The log is shared by every Claude window the app runs, so it is read only while
// exactly one Claude app process runs (claude-transplant's rule); otherwise the data folder's config.json alone says the
// account (no organisation then). No token is read: config.json's lastKnownAccountUuid is an id.
//
// Adapted from claude-transplant, Copyright (c) 2026 Vitaliy Hayda, under the MIT License:
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
//   documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
//   rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
//   permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright
//   notice and this permission notice shall be included in all copies or substantial portions of the Software.
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
//   WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
//   COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
//   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import AppKit

enum AppSignIn {
    enum State: String, Equatable { case known, loggedOut, unknown }

    struct Login: Equatable {
        var account: String?
        var org: String?
        var state: State
        var source: String          // "log", "config" or "unknown"
        var at: Date?

        static let unknown = Login(account: nil, org: nil, state: .unknown, source: "unknown", at: nil)
    }

    static var logsDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude") }

    /// The most read from the end of one log file.
    static let tailBytes = 4 << 20

    /// The Claude app's account for one profile's window: from the log when this window is the only Claude app running,
    /// else from its data folder's config.json. `launched`: the window's launch (nil: it isn't running).
    static func current(dataDir: String, launched: Date?, onlyApp: Bool, logs: URL = logsDir, now: Date = Date()) -> Login {
        let config = lastKnown(dataDir: dataDir)
        if onlyApp, let launched {
            let l = fromLog(logs: logs, launched: launched, lastKnown: config, now: now)
            if l.state != .unknown || l.source == "log" { return l }
        }
        if let c = config { return Login(account: c, org: nil, state: .known, source: "config", at: nil) }
        return .unknown
    }

    /// `current(for:)` kept a few seconds per profile (the log grows all the time; a screen asks on every tick), and read
    /// again at once when the data folder's config.json changes or the window starts or quits.
    private static var memo: [String: (key: String, at: Date, login: Login)] = [:]
    private static let memoLock = NSLock()

    static func cached(for e: AccountEntry, now: Date = Date()) -> Login {
        let dir = e.desktop == .standard ? expand(FolderKey.standardDataDir) : (Account(e).claudeUserDataDir ?? "")
        let cfg = (try? FileManager.default.attributesOfItem(atPath: (dir as NSString).appendingPathComponent("config.json")))?[.modificationDate] as? Date
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID).filter { !$0.isTerminated }
            .map { "\($0.processIdentifier)" }.sorted().joined(separator: ",")
        let key = "\(e.claudeWindow)|\(dir)|\(cfg?.timeIntervalSince1970 ?? 0)|\(running)"
        memoLock.lock()
        let hit = memo[e.id]
        memoLock.unlock()
        if let h = hit, h.key == key, now.timeIntervalSince(h.at) < 10 { return h.login }
        let l = current(for: e)
        memoLock.lock(); memo[e.id] = (key, now, l); memoLock.unlock()
        return l
    }

    /// The profile's own window: its data folder, launch and whether it is the only Claude app running.
    static func current(for e: AccountEntry) -> Login {
        guard e.claudeWindow else { return .unknown }
        let dir = e.desktop == .standard ? expand(FolderKey.standardDataDir) : (Account(e).claudeUserDataDir ?? "")
        guard !dir.isEmpty else { return .unknown }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID).filter { !$0.isTerminated }
        let mine = apps.first { Launcher.isWindow(of: Account(e), $0) }
        return current(dataDir: dir, launched: mine?.launchDate, onlyApp: apps.count == 1 && mine != nil)
    }

    /// config.json's lastKnownAccountUuid (lower case), or nil. Only that key is kept.
    static func lastKnown(dataDir: String) -> String? {
        guard let d = FileManager.default.contents(atPath: (expand(dataDir) as NSString).appendingPathComponent("config.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let id = j["lastKnownAccountUuid"] as? String, AccountDiscovery.isUUID(id) else { return nil }
        return id.lowercased()
    }

    /// The log files newest first: main.log, main1.log, main2.log … (claude-transplant's order).
    static func logFiles(_ logs: URL) -> [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []).filter { n in
            guard n.hasPrefix("main"), n.hasSuffix(".log") else { return false }
            let mid = n.dropFirst(4).dropLast(4)
            return mid.isEmpty || (mid.first != "0" && mid.allSatisfy(\.isNumber))
        }
        return names.sorted { (Int($0.dropFirst(4).dropLast(4)) ?? 0) < (Int($1.dropFirst(4).dropLast(4)) ?? 0) }
            .map { logs.appendingPathComponent($0) }
    }

    /// The last account line after the launch, read from the end of each file (newest first).
    static func fromLog(logs: URL, launched: Date, lastKnown: String?, now: Date = Date()) -> Login {
        for f in logFiles(logs) {
            guard let lines = tail(f) else { continue }
            if let l = judge(lines: lines, launched: launched, lastKnown: lastKnown, now: now) { return l }
        }
        return .unknown
    }

    /// The end of one file as lines (at most `tailBytes`; a cut first line is dropped), or nil when it can't be read.
    private static func tail(_ f: URL) -> [Substring]? {
        let fd = open(f.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(st.st_size), n = min(size, tailBytes)
        var buf = Data(count: n)
        let got = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, n, off_t(size - n)) }
        guard got == n else { return nil }
        var lines = String(decoding: buf, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        if n < size, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    static let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    static let timeFormatShort: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let lineRE = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,3})?) \[\w+\] (.*)$"#)
    private static let initRE = try! NSRegularExpression(pattern: #"^\[LocalSessionManager\] Initialization succeeded\b.*?accountId=([^,\s]+), orgId=([^,\s]+)"#)
    private static let loggedOutRE = try! NSRegularExpression(pattern: #"loggedOut: .*?(?:\x{2192}|->) true(?:,|\))|Account logged out"#)

    /// One file's lines judged from the end: the first account line found decides (nil: none in this file). The file's last
    /// element is what follows its last newline: a line there is still being written, so it says unknown.
    static func judge(lines: [Substring], launched: Date, lastKnown: String?, now: Date = Date()) -> Login? {
        func unknown(_ state: State = .unknown, _ at: Date? = nil) -> Login {
            Login(account: nil, org: nil, state: state, source: at == nil ? "unknown" : "log", at: at)
        }
        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            let line = String(lines[i])
            let local = line.contains("[LocalSessionManager]")
            let login = line.contains("[account] Login-state transition")
            guard login || (local && ["Initialization succeeded", "Org changed", "Account logged out", "Cannot initialize sessions", "loadSessions failed"]
                .contains(where: line.contains)) else { continue }
            let ns = line as NSString
            guard let m = lineRE.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return unknown() }
            let stamp = ns.substring(with: m.range(at: 1)), body = ns.substring(with: m.range(at: 2))
            let time = (stamp.contains(".") ? timeFormat : timeFormatShort).date(from: stamp)
            guard i != lines.count - 1, let t = time, t >= launched, t <= now else { return unknown() }
            if login || body.contains("Account logged out") {
                let out = loggedOutRE.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) != nil
                return unknown(out ? .loggedOut : .unknown, t)
            }
            let b = body as NSString
            guard let im = initRE.firstMatch(in: body, range: NSRange(location: 0, length: b.length)) else { return unknown(.unknown, t) }
            let account = b.substring(with: im.range(at: 1)).lowercased(), org = b.substring(with: im.range(at: 2)).lowercased()
            guard AccountDiscovery.isUUID(account), AccountDiscovery.isUUID(org) else { return unknown(.unknown, t) }
            if let k = lastKnown, k != account { return unknown(.unknown, t) }
            return Login(account: account, org: org, state: .known, source: "log", at: t)
        }
        return nil
    }
}
