// AppSignIn: which claude.ai account the Claude app is signed in to. The app's settings file names the account; its log
// gives the organisation and whether it signed out (adapted from claude-transplant 4.2.1, transplant.js, signedIn()).
//
// - The account: the data folder's config.json lastKnownAccountUuid. The app can switch accounts in place and back without
//   a new "Initialization succeeded" line (seen in 26.11.14: init for A, then a reevaluate and init for B, then back to A
//   with only "[oauth-v2] lookup" lines, config.json naming A), so the newest init line is not the account.
// - The organisation: the newest line after the app's launch about that same account, any of
//   "[LocalSessionManager] Initialization succeeded … accountId=X, orgId=Y", "[sessions-bridge] identity reevaluate: … → Y:X"
//   or "[oauth-v2] lookup orgId=Y cacheKey=acct:X"; if none, the newest claude-code-sessions/<account>/<org> folder in the
//   data folder (names only, at most `maxListed` entries, no link followed).
// - Signed out: the newest login-state line after the launch and newer than config.json's modification time (less
//   `configSlack`, 2 s: the app writes both at about the same time, some stamps without milliseconds) is
//   "[LocalSessionManager] Account logged out" or a "[account] Login-state transition" whose loggedOut part ends true.
//   Otherwise signed in to config.json's account.
// - No config.json (or no valid id in it): the log's own account line, as before (`judge`): the newest
//   "Initialization succeeded" after the launch names the account; a signed-out line means signed out; another
//   [LocalSessionManager] line about the account, a line before the launch, the file's last (maybe half-written) line or
//   an id that isn't a UUID: unknown.
//
// Only those lines are looked at, only lines up to `maxLine` bytes, with plain string tests (one anchored pattern for the
// time), and only the ids, the time and the signed-out flag are kept: nothing else from the log (it holds paths and
// session titles). The log is shared by every Claude window the app runs, so it is read only while exactly one Claude app
// process runs (claude-transplant's rule); otherwise config.json says the account and the sessions folder the
// organisation. No token is read: config.json's lastKnownAccountUuid is an id.
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
import ProfileCore

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

    /// The Claude app's account for one profile's window: config.json's account, with its organisation and the signed-out
    /// state from the log when this window is the only Claude app running (else the organisation from the sessions folder).
    /// Without config.json, the log's own account line. `launched`: the window's launch (nil: it isn't running).
    static func current(dataDir: String, launched: Date?, onlyApp: Bool, logs: URL = logsDir, now: Date = Date()) -> Login {
        guard let c = config(dataDir: dataDir) else {
            if onlyApp, let launched {
                let l = fromLog(logs: logs, launched: launched, lastKnown: nil, now: now)
                if l.state != .unknown || l.source == "log" { return l }
            }
            return .unknown
        }
        var l = Login(account: c.id, org: nil, state: .known, source: "config", at: nil)
        if onlyApp, let launched {
            let s = scan(logs: logs, launched: launched, account: c.id, configTime: c.modified, now: now)
            if let out = s.loggedOut { return Login(account: nil, org: nil, state: .loggedOut, source: "log", at: out) }
            if let o = s.org { l.org = o.org; l.source = "log"; l.at = o.at }
        }
        if l.org == nil { l.org = sessionsOrg(dataDir: dataDir, account: c.id) }
        return l
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
    static func lastKnown(dataDir: String) -> String? { config(dataDir: dataDir)?.id }

    /// config.json's lastKnownAccountUuid (lower case) and the file's modification time, or nil. Only that key is kept.
    static func config(dataDir: String) -> (id: String, modified: Date)? {
        guard let r = boundedRead((expand(dataDir) as NSString).appendingPathComponent("config.json"), max: configBytes, fromEnd: false),
              let j = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any],
              let id = j["lastKnownAccountUuid"] as? String, AccountDiscovery.isUUID(id) else { return nil }
        return (id.lowercased(), r.modified)
    }

    /// The most entries looked at in one sessions folder listing.
    static let maxListed = 256

    /// The newest claude-code-sessions/<account>/<org> folder in the data folder: its organisation (lower case), or nil.
    /// Names and times only, at most `maxListed` entries; a link (the account's folder or an org's) is never followed.
    static func sessionsOrg(dataDir: String, account: String) -> String? {
        let dir = (expand(dataDir) as NSString).appendingPathComponent("claude-code-sessions/\(account)")
        func isDir(_ p: String) -> Date? {
            var st = stat()
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        }
        guard isDir(dir) != nil, let d = opendir(dir) else { return nil }
        defer { closedir(d) }
        var best: (org: String, at: Date)?
        var seen = 0
        while seen < maxListed, let e = readdir(d) {
            seen += 1
            let name = withUnsafePointer(to: e.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
            guard name.utf8.count == 36, AccountDiscovery.isUUID(name), let t = isDir((dir as NSString).appendingPathComponent(name)) else { continue }
            if best.map({ t > $0.at }) ?? true { best = (name.lowercased(), t) }
        }
        return best?.org
    }

    /// The most log files read: the newest few are where the app's account lines are, and a folder of many files can't
    /// keep a screen busy.
    static let maxLogFiles = 5

    /// The log files newest first: main.log, main1.log, main2.log … (claude-transplant's order), at most `maxLogFiles`.
    static func logFiles(_ logs: URL) -> [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []).filter { n in
            guard n.hasPrefix("main"), n.hasSuffix(".log") else { return false }
            let mid = n.dropFirst(4).dropLast(4)
            return mid.isEmpty || (mid.first != "0" && mid.allSatisfy(\.isNumber))
        }
        return names.sorted { (Int($0.dropFirst(4).dropLast(4)) ?? 0) < (Int($1.dropFirst(4).dropLast(4)) ?? 0) }
            .prefix(maxLogFiles).map { logs.appendingPathComponent($0) }
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
        guard let r = boundedRead(f.path, max: tailBytes, fromEnd: true) else { return nil }
        var lines = String(decoding: r.data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        if r.cut, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// The most read of config.json (it holds one id cl_audit wants; a bigger file isn't one the app wrote).
    static let configBytes = 256 << 10

    /// At most `max` bytes of a regular file, from its start or its end, never blocking: opened without following a link
    /// and non-blocking (a FIFO or a device named like the file returns at once), checked to be a regular file. `cut`: the
    /// file was longer. nil when it isn't there or isn't a regular file.
    static func boundedRead(_ path: String, max: Int, fromEnd: Bool) -> (data: Data, cut: Bool, modified: Date)? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(st.st_size), n = min(size, max)
        var buf = Data(count: n)
        let got = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, n, off_t(fromEnd ? size - n : 0)) }
        guard got == n else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        return (buf, n < size, modified)
    }

    /// An account line is short (under 300 bytes): a longer one isn't looked at, so no line can keep the parsing busy.
    static let maxLine = 2048

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

    /// "Account logged out", or a login-state change whose loggedOut part ends "→ true" / "-> true" (before its next "," or
    /// ")"): signed out. Plain string tests, no pattern that could backtrack.
    static func saysLoggedOut(_ body: String) -> Bool {
        if body.contains("Account logged out") { return true }
        guard let r = body.range(of: "loggedOut: ") else { return false }
        let rest = body[r.upperBound...]
        let value = rest[..<(rest.firstIndex { $0 == "," || $0 == ")" } ?? rest.endIndex)]
        return value.hasSuffix("\u{2192} true") || value.hasSuffix("-> true")
    }

    /// The value after `key` up to the next space, "," or ")" (plain string tests).
    static func token(after key: String, in body: String) -> String? {
        guard let r = body.range(of: key) else { return nil }
        let rest = body[r.upperBound...]
        let v = rest[..<(rest.firstIndex { $0 == " " || $0 == "," || $0 == ")" || $0 == "\t" } ?? rest.endIndex)]
        return v.isEmpty ? nil : String(v)
    }

    /// One log line's (account, organisation), lower case, from any of the account lines: "[LocalSessionManager]
    /// Initialization succeeded … accountId=X, orgId=Y", "[sessions-bridge] identity reevaluate: … → Y:X" or "[oauth-v2]
    /// lookup orgId=Y cacheKey=acct:X". nil: not one, or an id that isn't a UUID.
    static func accountOrg(_ body: String) -> (account: String, org: String)? {
        var pair: (String, String)?
        if body.hasPrefix("[LocalSessionManager] Initialization succeeded") {
            if let a = token(after: "accountId=", in: body), let o = token(after: "orgId=", in: body) { pair = (a, o) }
        } else if body.hasPrefix("[sessions-bridge] identity reevaluate") {
            let arrow = body.range(of: "\u{2192} ", options: .backwards) ?? body.range(of: "-> ", options: .backwards)
            if let r = arrow {
                let rest = body[r.upperBound...]
                let v = rest[..<(rest.firstIndex { $0 == " " || $0 == "," || $0 == ")" || $0 == "\t" } ?? rest.endIndex)]
                let parts = v.split(separator: ":", omittingEmptySubsequences: false)
                if parts.count == 2 { pair = (String(parts[1]), String(parts[0])) }
            }
        } else if body.hasPrefix("[oauth-v2] lookup") {
            if let o = token(after: "orgId=", in: body), let a = token(after: "cacheKey=acct:", in: body) { pair = (a, o) }
        }
        guard let (a, o) = pair, AccountDiscovery.isUUID(a), AccountDiscovery.isUUID(o) else { return nil }
        return (a.lowercased(), o.lowercased())
    }

    /// What the log says beside config.json's account: the organisation of the newest account line for `account` after the
    /// launch, and the time of a signed-out line when the newest login-state line after the launch and after `configTime`
    /// says signed out. Read newest file first, each from its end; it stops at the first such line from before the launch.
    static func scan(logs: URL, launched: Date, account: String, configTime: Date, now: Date = Date()) -> (org: (org: String, at: Date)?, loggedOut: Date?) {
        var s = Scan()
        for f in logFiles(logs) where !s.done {
            guard let lines = tail(f) else { continue }
            scan(lines: lines, into: &s, launched: launched, account: account, configTime: configTime, now: now)
        }
        return (s.org, s.loggedOut)
    }

    /// How much older than config.json a sign-out line may be and still count (the app writes both at about the same time).
    static let configSlack: TimeInterval = 2

    /// What `scan` found so far, carried from one file to the next (older) one.
    struct Scan {
        var org: (org: String, at: Date)?
        var loggedOut: Date?
        var loginDecided = false
        var done = false                // nothing older can change the answer (or a line from before the launch was reached)
    }

    /// One file's part of `scan`, from its end. The file's last element may be half-written: it is never read.
    static func scan(lines: [Substring], into s: inout Scan, launched: Date, account: String, configTime: Date, now: Date = Date()) {
        for i in stride(from: lines.count - 2, through: 0, by: -1) where !s.done {
            guard lines[i].utf8.count <= maxLine else { continue }      // never a long line: account lines are short
            let line = String(lines[i])
            let login = line.contains("[account] Login-state transition") || line.contains("[LocalSessionManager] Account logged out")
            let named = line.contains("[LocalSessionManager] Initialization succeeded") || line.contains("[sessions-bridge] identity reevaluate")
                || line.contains("[oauth-v2] lookup")
            guard login || named else { continue }
            let ns = line as NSString
            guard let m = lineRE.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let stamp = ns.substring(with: m.range(at: 1)), body = ns.substring(with: m.range(at: 2))
            guard let t = (stamp.contains(".") ? timeFormat : timeFormatShort).date(from: stamp), t <= now else { continue }
            if t < launched { s.done = true; break }
            if login, !s.loginDecided, body.contains("Account logged out") || body.contains("loggedOut: ") {
                // the newest login-state line newer than config.json decides; one older than it (or none) leaves it signed in.
                // `configSlack`: a sign-out logged just before config.json is rewritten (or in the same second, a stamp
                // without milliseconds) still counts.
                s.loginDecided = true
                if t > configTime.addingTimeInterval(-configSlack), saysLoggedOut(body) { s.loggedOut = t; s.done = true; break }
            }
            if named, s.org == nil, let p = accountOrg(body), p.account == account { s.org = (p.org, t) }
            if s.org != nil, s.loginDecided { s.done = true }
        }
    }

    /// One file's lines judged from the end: the first account line found decides (nil: none in this file). The file's last
    /// element is what follows its last newline: a line there is still being written, so it says unknown.
    static func judge(lines: [Substring], launched: Date, lastKnown: String?, now: Date = Date()) -> Login? {
        func unknown(_ state: State = .unknown, _ at: Date? = nil) -> Login {
            Login(account: nil, org: nil, state: state, source: at == nil ? "unknown" : "log", at: at)
        }
        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            guard lines[i].utf8.count <= maxLine else { continue }      // never a long line: account lines are short
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
                return unknown(saysLoggedOut(body) ? .loggedOut : .unknown, t)
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
