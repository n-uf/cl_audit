// Processes: the one place cl_audit finds running Claude processes, and the one way it runs a program of its own.
//
// Finding. The Claude app: its instances as AppKit lists them, and a profile's window among them by its data folder
// (Launcher.isWindow). Claude Code (`claude`): by the folder it runs on (CLAUDE_CONFIG_DIR, or ~/.claude), by the session ids
// on its command line, or as the program of a Code-tab or a terminal. All of it is read from the kernel (proc_listallpids,
// proc_pidinfo, KERN_PROCARGS2, proc_pidpath): no `ps` or `pgrep`, so nothing waits on a helper (waiting for one ran the run loop
// and redrew SwiftUI windows mid-update). Where the table can't be read the answer is nil, and the callers then refuse rather
// than guess. Of a process's environment only CLAUDE_CONFIG_DIR is kept; the rest is compared as bytes and wiped. Only `lsof`
// (which program has a file open) is still a tool, run through `run`.
//
// Running. `run` and `output` start a program in the temporary folder with no input, wait at most its time limit, then ask it to
// end (SIGTERM) and, after a grace, kill it (SIGKILL); a run never blocks much past its limit. `claudeEnvironment` is what a
// `claude` run gets here: ClaudeAuth's rule (AuthFolder.providerVariables: no key, token, other provider, base URL or extra
// headers) and no CLAUDE_CONFIG_DIR. ClaudeAuth's own sign-in, renew and sign-out runs keep its runner (Auth/Runs.swift, which
// takes no output); this file never signals a process it didn't start.

import AppKit
import ClaudeAuth

enum Processes {
    // MARK: the kernel's table

    /// How a process was started: its executable, its arguments (argv, empty ones included) and its CLAUDE_CONFIG_DIR (nil when
    /// it isn't set).
    struct Launch: Equatable {
        var exe: String
        var args: [String]
        var configDir: String?
    }

    /// A process of the table: its id, its effective and real user, its short name (proc_name) and how it was started (nil when
    /// that can't be read: another user's process, or one that has just ended).
    struct Entry {
        var pid: pid_t
        var uid: uid_t
        var ruid: uid_t
        var name: String
        var launch: Launch?
    }

    /// Every process the kernel lists whose basic facts can be read, cl_audit itself included; nil when the list can't be read.
    static func table() -> [Entry]? {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return nil }
        var out: [Entry] = []
        for pid in pids.prefix(Int(got)) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            var nameBuf = [CChar](repeating: 0, count: 256)
            let name = proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 ? String(cString: nameBuf) : ""
            out.append(Entry(pid: pid, uid: info.pbi_uid, ruid: info.pbi_ruid, name: name, launch: launch(of: pid)))
        }
        return out
    }

    /// How a process was started (KERN_PROCARGS2), or nil when it can't be read. Of its environment only CLAUDE_CONFIG_DIR is
    /// kept: each entry is compared as bytes, and the buffer is wiped before it is let go.
    static func launch(of pid: pid_t) -> Launch? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size, size < 4 << 20 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        defer { for k in buf.indices { buf[k] = 0 } }               // (the rest of the environment isn't kept)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        let s0 = i
        while i < size && buf[i] != 0 { i += 1 }                    // the executable path
        let exe = String(decoding: buf[s0..<i], as: UTF8.self)
        while i < size && buf[i] == 0 { i += 1 }                    // its padding
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        var configDir: String?
        let prefix = Array("CLAUDE_CONFIG_DIR=".utf8)
        while i < size {                                            // the environment, up to its end (an empty entry)
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            if i == start { break }
            if i - start >= prefix.count, Array(buf[start..<(start + prefix.count)]) == prefix {
                configDir = String(decoding: buf[(start + prefix.count)..<i], as: UTF8.self)
            }
            i += 1
        }
        return Launch(exe: exe, args: args, configDir: configDir)
    }

    /// A process's arguments ([] when they can't be read).
    static func arguments(of pid: pid_t) -> [String] { launch(of: pid)?.args ?? [] }

    /// The program a running process was started from (proc_pidpath), or nil when it isn't running.
    static func executable(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    /// When a process started (seconds): with its pid, which process it is (a pid alone can be reused).
    static func startTime(of pid: pid_t) -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return Int(info.kp_proc.p_un.__p_starttime.tv_sec)
    }

    /// Whether a process with this id runs (another user's counts: it is there, only not ours to signal).
    static func runs(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    // MARK: the Claude app

    /// The Claude app's instances, as AppKit lists them (one that is ending may still be among them).
    static func claudeApps() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
    }

    /// The instances that are this profile's window (by its data folder, or the standard one).
    static func claudeWindows(of account: Account) -> [NSRunningApplication] {
        claudeApps().filter { Launcher.isWindow(of: account, $0) }
    }

    // MARK: Claude Code

    /// Every Claude app and Claude Code session of this user, for the new-account page: the app by its data folder, Claude Code
    /// (a process named `claude`) as a Code-tab's or a terminal's, by its folder. Call off the main thread.
    static func claudeRuns() -> [ClaudeRun] {
        var runs: [ClaudeRun] = []
        for app in claudeApps() {
            let dir = arguments(of: app.processIdentifier).first { $0.hasPrefix("--user-data-dir=") }
            let folder = dir.map { tilde(String($0.dropFirst("--user-data-dir=".count))) } ?? FolderKey.standardDataDir
            runs.append(ClaudeRun(id: app.processIdentifier, kind: .desktop, folder: folder))
        }
        let uid = getuid()
        for e in table() ?? [] where e.name == "claude" && e.ruid == uid {
            let program = e.launch?.args.first ?? e.name
            let kind: ClaudeRun.Kind = program.contains("/Library/Application Support/Claude") ? .codeTab : .terminal
            runs.append(ClaudeRun(id: e.pid, kind: kind, folder: e.launch?.configDir.map(tilde) ?? "~/.claude"))
        }
        return runs
    }

    /// Whether Claude Code runs for this Claude Code folder (CLAUDE_CONFIG_DIR, or ~/.claude when it isn't set), among this
    /// user's processes: nil when that can't be told (the table can't be read, or a process that may be Claude Code can't be).
    /// The Claude app itself isn't Claude Code; the Claude Code it starts is.
    static func codeRuns(codeDir: String) -> Bool? {
        guard let all = table() else { return nil }
        let me = getpid(), uid = getuid()
        let want = FolderKey.canonical(codeDir)
        let std = FolderKey.canonical(NSHomeDirectory() + "/.claude")
        var unknown = false
        for e in all where e.pid != me && e.uid == uid {
            switch isCode(name: e.name, exe: e.launch?.exe, args: e.launch?.args ?? [], configDir: e.launch?.configDir, want: want, std: std) {
            case true?: return true
            case nil: unknown = true
            case false?: break
            }
        }
        return unknown ? nil : false
    }

    /// One process: true when it is Claude Code for the folder `want`; nil when it may be Claude Code but couldn't be read (counted as
    /// running by the caller: nothing shared is written); false otherwise. The Claude app's own main program isn't Claude Code (its window
    /// is checked apart); the Claude Code it carries, run from a terminal, is.
    static func isCode(name: String, exe: String?, args: [String], configDir: String?, want: String, std: String) -> Bool? {
        let short = name.lowercased()
        let looks = short == "claude" || short == "claude.exe" || short.hasPrefix("claude") && !short.contains("helper")
        guard let exe else { return looks ? nil : false }
        if exe.hasSuffix("/Claude.app/Contents/MacOS/Claude") || exe.contains("/Claude.app/Contents/Frameworks/") { return false }
        // a profile's own window copy (…/Claude-Work.app/Contents/MacOS/Claude): any app bundle's program that isn't Claude Code's own
        // claude.app is a window, not Claude Code
        if let r = exe.range(of: ".app/Contents/MacOS/") {
            let bundle = (String(exe[..<r.lowerBound]) as NSString).lastPathComponent + ".app"
            if bundle != "claude.app" { return false }
        }
        let leaf = (exe as NSString).lastPathComponent.lowercased()
        let codeLike = leaf == "claude" || leaf == "claude.exe" || exe.contains("/claude-code/") || exe.contains("/claude/versions/")
            || ((args.first ?? "") as NSString).lastPathComponent.lowercased() == "claude"
            || args.contains { $0.hasSuffix("/claude") || $0.contains("@anthropic-ai/claude-code") }
        guard codeLike else { return false }
        let key = configDir.map { FolderKey.canonical(expand($0)) } ?? std
        return key == want
    }

    /// The command lines the kernel can read (each process's arguments joined by spaces, as `ps -o command` prints them), every
    /// user's; nil when the table can't be read.
    static func commandLines() -> [String]? {
        table().map { $0.compactMap { $0.launch.map { $0.args.joined(separator: " ") } } }
    }

    /// The session ids a running Claude Code owns (claude-transplant's workers): every id on the command line of a process whose
    /// program is `claude`, and the sessionId of `<codeDir>/sessions/<pid>.json` for a process that runs. nil when the processes
    /// can't be read (then nothing moves: claude-transplant's "cannot inspect running workers").
    static func sessionsOwned(codeDir: String) -> Set<String>? {
        commandLines().map { owned(commands: $0, codeDir: codeDir, alive: runs) }
    }

    /// `sessionsOwned` on given command lines (the checks pass their own).
    static func owned(commands: [String], codeDir: String, alive: (pid_t) -> Bool) -> Set<String> {
        var ids: Set<String> = []
        for cmd in commands where isClaude(cmd) {
            for m in uuidPattern.matches(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)) {
                if let r = Range(m.range, in: cmd) { ids.insert(cmd[r].lowercased()) }
            }
        }
        let dir = (expand(codeDir) as NSString).appendingPathComponent("sessions")
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".json") {
            guard let pid = pid_t(n.dropLast(5)), pid > 0, alive(pid),
                  let j = SafeRead.jsonObject((dir as NSString).appendingPathComponent(n), max: SafeRead.recordMax),
                  (j["pid"] as? NSNumber)?.int32Value == pid, let s = j["sessionId"] as? String else { continue }
            ids.insert(s.lowercased())
        }
        return ids
    }

    /// Whether a command line's program is `claude`: its executable's last path component, the path taken whole even with
    /// spaces in it (".../Application Support/Claude/claude-code/2.1.318/claude --resume …"), up to the first argument
    /// that starts with "-". `/bin/zsh -c claude …` is zsh's, not claude's.
    static func isClaude(_ command: String) -> Bool {
        let words = command.split(separator: " ", omittingEmptySubsequences: false)
        var path = ""
        for (i, w) in words.enumerated() {
            if i > 0 && w.hasPrefix("-") { break }
            path = i == 0 ? String(w) : path + " " + w
            if (path as NSString).lastPathComponent.lowercased() == "claude" { return i == 0 || path.hasPrefix("/") }
            if i == 0 && !path.hasPrefix("/") { break }            // a bare program name has no spaces
        }
        return false
    }

    /// The session ids on the command lines that name Claude (`--resume <id>`, `--session-id <id>`), lower case; nil when the
    /// processes can't be read. Limits: a session resumed from its own picker, or with --continue, isn't named there.
    static func sessionsOnCommandLines() -> Set<String>? {
        guard let lines = commandLines() else { return nil }
        var out = Set<String>()
        for s in lines where s.localizedCaseInsensitiveContains("claude") {
            for m in uuidPattern.matches(in: s, range: NSRange(s.startIndex..., in: s)) { out.insert((s as NSString).substring(with: m.range).lowercased()) }
        }
        return out
    }

    /// Whether any process's command line has this text in it (what `pgrep -f` finds); nil when the processes can't be read.
    static func commandLineNames(_ text: String) -> Bool? {
        commandLines().map { $0.contains { $0.contains(text) } }
    }

    enum Probe { case found, none, unknown }

    /// Whether a program has this file open (`lsof`, with its own 2-second limit for kernel calls), within 5 seconds: past it,
    /// only that `lsof` (cl_audit's own child) is stopped, and the answer is unknown.
    static func fileOpen(_ path: String) -> Probe {
        // -b isn't used: it can't then find a file named by path
        switch run("/usr/sbin/lsof", ["-S", "2", "-t", "--", path], timeout: 5, grace: 1) {
        case nil: return .unknown
        case 0?: return .found
        default: return .none
        }
    }

    private static let uuidPattern = try! NSRegularExpression(pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", options: [.caseInsensitive])

    // MARK: running a program

    /// The environment a `claude` run gets here: `base` without ClaudeAuth's provider variables (a key, a token, another
    /// provider, a base URL, extra headers) and without CLAUDE_CONFIG_DIR.
    static func claudeEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        for k in AuthFolder.providerVariables + ["CLAUDE_CONFIG_DIR"] { env[k] = nil }
        return env
    }

    /// Runs a program and returns its exit status; nil when it couldn't start or ran out of time. Blocks: call off the main thread.
    @discardableResult
    static func run(_ exe: String, _ args: [String], environment: [String: String]? = nil, timeout: TimeInterval, grace: TimeInterval) -> Int32? {
        start(exe, args, environment: environment, timeout: timeout, grace: grace, output: false)?.status
    }

    /// What a program printed (trimmed), or nil when it couldn't start, failed or ran out of time. Blocks: call off the main thread.
    static func output(_ exe: String, _ args: [String], environment: [String: String]? = nil, timeout: TimeInterval, grace: TimeInterval) -> String? {
        guard let r = start(exe, args, environment: environment, timeout: timeout, grace: grace, output: true), r.status == 0 else { return nil }
        return String(data: r.out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The one runner: in the temporary folder, no input, errors dropped, what it prints kept (up to 1 MB) when `output`. Past
    /// `timeout` it is asked to end (SIGTERM), then killed (SIGKILL) if it hasn't within `grace`, and nil is returned. What it
    /// printed is waited for only until the time limit, or a second after it ended (a program it started may hold the output open).
    private static func start(_ exe: String, _ args: [String], environment: [String: String]?, timeout: TimeInterval, grace: TimeInterval,
                              output: Bool) -> (status: Int32, out: Data)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let environment { p.environment = environment }
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let pipe = output ? Pipe() : nil
        p.standardOutput = pipe ?? FileHandle.nullDevice
        final class Box: @unchecked Sendable { var data = Data(); let lock = NSLock() }
        let box = Box(), read = DispatchGroup()
        guard (try? p.run()) != nil else { return nil }
        if let pipe {
            read.enter()
            DispatchQueue.global(qos: .utility).async {
                let h = pipe.fileHandleForReading
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    box.lock.lock(); if box.data.count < 1 << 20 { box.data.append(d) }; box.lock.unlock()
                }
                read.leave()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning {
            p.terminate()
            let until = Date().addingTimeInterval(grace)
            while p.isRunning && Date() < until { usleep(20_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            let reaped = Date().addingTimeInterval(1)
            while p.isRunning && Date() < reaped { usleep(5_000) }
            return nil
        }
        if pipe != nil, read.wait(timeout: .now() + max(1, deadline.timeIntervalSinceNow)) == .timedOut { return nil }
        box.lock.lock(); let out = box.data; box.lock.unlock()
        return (p.terminationStatus, out)
    }
}
