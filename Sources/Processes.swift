// Processes: the one place cl_audit finds running Claude processes, and the one way it runs a program of its own.
//
// Finding. The Claude app: its instances as AppKit lists them, and a profile's window among them by its data folder
// (Launcher.isWindow). Claude Code (`claude`): by the folder it runs on (CLAUDE_CONFIG_DIR, or ~/.claude), by the session ids
// on its command line, or as the program of a Code-tab or a terminal. All of it is read from the kernel (proc_listallpids,
// proc_pidinfo, KERN_PROCARGS2, proc_pidpath): no `ps` or `pgrep`, so nothing waits on a helper (waiting for one ran the run loop
// and redrew SwiftUI windows mid-update). Where the table can't be read, or a process that may be Claude Code can't be (another
// user's `claude`, as with `sudo claude`, included), or a Claude Code's environment can't be (then its folder is unknown, never
// taken for ~/.claude), the answer is nil, and the callers then refuse rather than guess. Of a process's environment only CLAUDE_CONFIG_DIR is kept; the rest is compared as bytes and wiped. Only `lsof`
// (which program has a file open) is still a tool, run through `run`.
//
// Running. `run` and `output` go through Runs (Run/), the one runner ClaudeAuth uses too: a program in the temporary folder with
// no input, waited for at most its time limit, then asked to end (SIGTERM) and, after a grace, killed (SIGKILL); a run never
// blocks much past its limit. `claudeEnvironment` is what a `claude` run gets here: Runs' ProviderEnvironment (no key, token,
// other provider, base URL or extra headers) and no CLAUDE_CONFIG_DIR. This file never signals a process it didn't start.

import AppKit
import ClaudeAuth
import Runs

enum Processes {
    // MARK: the kernel's table

    /// How a process was started: its executable, its arguments (argv, empty ones included) and its CLAUDE_CONFIG_DIR (nil when
    /// it isn't set). `environmentRead`: the kernel gave at least one environment entry after the arguments (every real process
    /// has some: PATH, HOME…). When it didn't, a nil `configDir` says nothing: the folder is unknown, never the default one
    /// (`Entry.unknown`). `parse` always sets it; the default is for the checks' hand-made tables.
    struct Launch: Equatable {
        var exe: String
        var args: [String]
        var configDir: String?
        var environmentRead = true
    }

    /// A process of the table: its id, its effective and real user (nil when even they can't be read), its name (proc_name for
    /// cl_audit's user, else the kernel's short name) and how it was started. That is read for cl_audit's user's processes and for
    /// any whose name looks like Claude Code's (`looksLikeClaude`); another user's other processes aren't read (`ps` couldn't read
    /// them either). `hidden`: it may be Claude Code, but how it was started couldn't be read (another user's `claude`, as with
    /// `sudo claude`, or anything whose basic facts can't be read): whoever asks then can't tell, and says so.
    struct Entry {
        var pid: pid_t
        var uid: uid_t?
        var ruid: uid_t?
        var name: String
        var launch: Launch?
        var hidden = false

        /// It may be Claude Code and which folder it runs on can't be told: `hidden`, or a Claude Code program (`codeProgram`)
        /// whose environment wasn't read (its CLAUDE_CONFIG_DIR may be any folder's). Whoever asks then can't tell, and says so.
        var unknown: Bool {
            hidden || launch.map { !$0.environmentRead && Processes.codeProgram(exe: $0.exe, args: $0.args) } == true
        }
    }

    /// `table()`, read once more when something in it was unknown (a process caught mid-start or mid-exit), before the answer
    /// is "can't tell".
    static func settledTable() -> [Entry]? {
        let t = table()
        return t?.contains(where: \.unknown) == true ? table() : t
    }

    /// Every process the kernel lists, cl_audit itself included, except those that ended meanwhile or are ended and waiting to
    /// be reaped (they run nothing); nil when the list can't be read or may have been cut short.
    static func table() -> [Entry]? {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        // a full list may have left processes out
        guard got > 0, Int(got) < pids.count else { return nil }
        let me = getuid()
        var out: [Entry] = []
        // the basic facts through KERN_PROC (proc_pidinfo refuses another user's processes): nil when it ended (or is ended and
        // waiting to be reaped); .unreadable when they can't be read
        enum Facts { case read(kinfo_proc), unreadable }
        func facts(_ pid: pid_t) -> Facts? {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return errno == ESRCH ? nil : .unreadable }
            return size > 0 && info.kp_proc.p_stat != CChar(SZOMB) ? .read(info) : nil
        }
        for pid in pids.prefix(Int(got)) where pid > 0 {
            guard let f = facts(pid) else { continue }                                  // ended
            guard case .read(let info) = f else {
                out.append(Entry(pid: pid, uid: nil, ruid: nil, name: "", launch: nil, hidden: true))
                continue
            }
            let uid = info.kp_eproc.e_ucred.cr_uid, ruid = info.kp_eproc.e_pcred.p_ruid
            var name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if uid == me {
                var nameBuf = [CChar](repeating: 0, count: 256)
                if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 { name = String(cString: nameBuf) }
            }
            var e = Entry(pid: pid, uid: uid, ruid: ruid, name: name, launch: nil)
            if uid == me || looksLikeClaude(name) {
                let r = read(pid)
                e.launch = r.launch
                // not read: hidden, unless it ended meanwhile
                e.hidden = r.launch == nil && !r.gone && facts(pid) != nil
            }
            out.append(e)
        }
        return out
    }

    /// A name Claude Code's program may have: `claude…` (not a helper), or a version number (the native installer's
    /// …/claude/versions/2.1.318).
    static func looksLikeClaude(_ name: String) -> Bool {
        let short = name.lowercased()
        if short == "claude" || short == "claude.exe" || short.hasPrefix("claude") && !short.contains("helper") { return true }
        let parts = short.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// How a process was started (KERN_PROCARGS2), or nil when it can't be read. Of its environment only CLAUDE_CONFIG_DIR is
    /// kept: each entry is compared as bytes, and the buffer is wiped before it is let go.
    static func launch(of pid: pid_t) -> Launch? { read(pid).launch }

    /// `launch(of:)`, and whether the process had ended (then nothing is hidden by it).
    private static func read(_ pid: pid_t) -> (launch: Launch?, gone: Bool) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return (nil, errno == ESRCH) }
        guard size > MemoryLayout<Int32>.size, size < 4 << 20 else { return (nil, false) }
        var buf = [UInt8](repeating: 0, count: size)
        defer { for k in buf.indices { buf[k] = 0 } }               // (the rest of the environment isn't kept)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return (nil, errno == ESRCH) }
        return (parse(buf, size: size), false)
    }

    /// KERN_PROCARGS2's bytes: argc, the executable path, NULs up to the next 8 bytes counted from the path's start (the accounts
    /// suite proves it on started stand-ins; NUL by NUL when the layout is another), exactly argc arguments (empty ones included),
    /// then the environment up to an empty entry (the kernel's own strings, ptr_munge= and the like, follow it). nil when cut
    /// short, or when the first argument is empty or starts with a space. `environmentRead` only when an entry came after the
    /// arguments that isn't one of the kernel's own strings: a buffer that ends after them, or goes on with NULs, wasn't read.
    static func parse(_ buf: [UInt8], size: Int) -> Launch? {
        guard size > MemoryLayout<Int32>.size, size <= buf.count else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        let s0 = i
        while i < size && buf[i] != 0 { i += 1 }                    // the executable path
        let exe = String(decoding: buf[s0..<i], as: UTF8.self)
        // its padding: its NUL rounded up to 8 bytes (so an empty first argument isn't taken for padding); a layout that
        // isn't that is skipped NUL by NUL as before
        let aligned = s0 + (i - s0 + 1 + 7) / 8 * 8
        if aligned <= size && buf[i..<aligned].allSatisfy({ $0 == 0 }) { i = aligned } else { while i < size && buf[i] == 0 { i += 1 } }
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        var configDir: String?
        var environmentRead = false
        let prefix = Array("CLAUDE_CONFIG_DIR=".utf8)
        while i < size {                                            // the environment, up to its end (an empty entry)
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            if i == start { break }
            if i - start >= prefix.count, Array(buf[start..<(start + prefix.count)]) == prefix {
                configDir = String(decoding: buf[(start + prefix.count)..<i], as: UTF8.self)
            }
            if !kernelStrings.contains(where: { k in i - start >= k.count && buf[start..<(start + k.count)].elementsEqual(k) }) {
                environmentRead = true
            }
            i += 1
        }
        guard args.count == argc else { return nil }                // cut short: not read
        // an empty or space-led program can't be told from a misread layout (an empty argv[0] can't be told from padding): not
        // read, so the process is hidden rather than taken for "not Claude"
        if let first = args.first, first.isEmpty || first.hasPrefix(" ") { return nil }
        return Launch(exe: exe, args: args, configDir: configDir, environmentRead: environmentRead)
    }

    /// The kernel's own strings that follow the environment in KERN_PROCARGS2 (its "apple" strings): should one come right
    /// after the arguments, it isn't taken for an environment that was read.
    private static let kernelStrings: [[UInt8]] = ["ptr_munge=", "main_stack=", "executable_path=", "executable_file=", "dyld_file=",
        "executable_cdhash=", "executable_boothash=", "th_port=", "security_config=", "stack_guard=", "malloc_entropy=",
        "arm64e_abi=", "has_sec_transition=", "pfz=", "dyld_flags=", "executable_TeamID=", "apple_fd="].map { Array($0.utf8) }

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
        for e in table() ?? [] where e.name == "claude" && e.ruid == uid { runs.append(codeRun(e)) }
        return runs
    }

    /// One `claude` process as the new-account page shows it: a Code-tab's when its program, as it was started (argv[0], what
    /// `ps -o comm` printed), is in the Claude app's folder, else a terminal's; its folder, or ~/.claude when its environment was
    /// read without CLAUDE_CONFIG_DIR. When how it was started, or its environment, couldn't be read: ClaudeRun.unknownFolder
    /// (which every folder's check counts as using it), never ~/.claude.
    static func codeRun(_ e: Entry) -> ClaudeRun {
        let program = e.launch?.args.first ?? e.name
        let kind: ClaudeRun.Kind = program.contains("/Library/Application Support/Claude") ? .codeTab : .terminal
        guard let l = e.launch, l.environmentRead else { return ClaudeRun(id: e.pid, kind: kind, folder: ClaudeRun.unknownFolder) }
        return ClaudeRun(id: e.pid, kind: kind, folder: l.configDir.map(tilde) ?? "~/.claude")
    }

    /// Whether Claude Code runs for this Claude Code folder (CLAUDE_CONFIG_DIR, or ~/.claude when it isn't set), among this
    /// user's processes: nil when that can't be told (the table can't be read, a process that may be Claude Code can't be, or
    /// another user's that looks like Claude Code, which may be on this folder, as `sudo claude` is, or a Claude Code whose
    /// environment couldn't be read: `Entry.unknown`, for every folder, the default one included). The Claude app itself isn't
    /// Claude Code; the Claude Code it starts is.
    static func codeRuns(codeDir: String, table given: [Entry]?? = nil) -> Bool? {
        guard let all = given ?? settledTable() else { return nil }
        let me = getpid(), uid = getuid()
        let want = FolderKey.canonical(codeDir)
        let std = FolderKey.canonical(NSHomeDirectory() + "/.claude")
        var unknown = false
        for e in all where e.pid != me {
            if e.unknown { unknown = true; continue }
            guard e.uid == uid else { continue }
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
    /// is checked apart); the Claude Code it carries, run from a terminal, is. `configDir` nil is the default folder's, so a process whose
    /// environment wasn't read never comes here (codeRuns counts it as unknown first: `Entry.unknown`).
    static func isCode(name: String, exe: String?, args: [String], configDir: String?, want: String, std: String) -> Bool? {
        guard let exe else { return looksLikeClaude(name) ? nil : false }
        guard codeProgram(exe: exe, args: args) else { return false }
        let key = configDir.map { FolderKey.canonical(expand($0)) } ?? std
        return key == want
    }

    /// Whether a program, as it was started, is Claude Code's: not the Claude app's own (its main program, its frameworks, a profile's
    /// window copy), but `claude` by its executable or its first argument, the native installer's versions/, or the npm package.
    static func codeProgram(exe: String, args: [String]) -> Bool {
        if exe.hasSuffix("/Claude.app/Contents/MacOS/Claude") || exe.contains("/Claude.app/Contents/Frameworks/") { return false }
        // a profile's own window copy (…/Claude-Work.app/Contents/MacOS/Claude): any app bundle's program that isn't Claude Code's own
        // claude.app is a window, not Claude Code
        if let r = exe.range(of: ".app/Contents/MacOS/") {
            let bundle = (String(exe[..<r.lowerBound]) as NSString).lastPathComponent + ".app"
            if bundle != "claude.app" { return false }
        }
        let leaf = (exe as NSString).lastPathComponent.lowercased()
        return leaf == "claude" || leaf == "claude.exe" || exe.contains("/claude-code/") || exe.contains("/claude/versions/")
            || ((args.first ?? "") as NSString).lastPathComponent.lowercased() == "claude"
            || args.contains { $0.hasSuffix("/claude") || $0.contains("@anthropic-ai/claude-code") }
    }

    /// The command lines the kernel reads (each process's arguments joined by spaces, as `ps -o command` prints them): this user's
    /// and those of any user's process that looks like Claude Code. nil when the table can't be read or a process that may be
    /// Claude Code can't be, or its environment can't be (`Entry.unknown`): a session it holds would look free. `given`: a table
    /// the caller read (the checks pass their own); nil reads one now.
    static func commandLines(_ given: [Entry]?? = nil) -> [String]? {
        guard let all = given ?? settledTable(), !all.contains(where: \.unknown) else { return nil }
        return all.compactMap { $0.launch.map { $0.args.joined(separator: " ") } }
    }

    /// The session ids a running Claude Code owns (claude-transplant's workers): every id on the command line of a process whose
    /// program is `claude`, and the sessionId of `<codeDir>/sessions/<pid>.json` for a process that runs. nil when the processes
    /// can't be read (then nothing moves: claude-transplant's "cannot inspect running workers").
    static func sessionsOwned(codeDir: String, table given: [Entry]?? = nil) -> Set<String>? {
        commandLines(given).map { owned(commands: $0, codeDir: codeDir, alive: runs) }
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
    static func sessionsOnCommandLines(table given: [Entry]?? = nil) -> Set<String>? {
        guard let lines = commandLines(given) else { return nil }
        var out = Set<String>()
        for s in lines where s.localizedCaseInsensitiveContains("claude") {
            for m in uuidPattern.matches(in: s, range: NSRange(s.startIndex..., in: s)) { out.insert((s as NSString).substring(with: m.range).lowercased()) }
        }
        return out
    }

    /// Whether any process's command line has this text in it (what `pgrep -f` finds); nil when the processes can't be read.
    static func commandLineNames(_ text: String, table given: [Entry]?? = nil) -> Bool? {
        commandLines(given).map { $0.contains { $0.contains(text) } }
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

    /// The environment a `claude` run gets here: `base` without the provider variables (a key, a token, another provider, a
    /// base URL, extra headers) and without CLAUDE_CONFIG_DIR (Runs' ProviderEnvironment, ClaudeAuth's too).
    static func claudeEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        Runs.ProviderEnvironment.cleaned(base)
    }

    /// Runs a program and returns its exit status; nil when it couldn't start or ran out of time. Blocks: call off the main thread.
    @discardableResult
    static func run(_ exe: String, _ args: [String], environment: [String: String]? = nil, timeout: TimeInterval, grace: TimeInterval) -> Int32? {
        Runs.Runner.run(Runs.Program(exe, args, environment: environment, timeout: timeout, grace: grace))?.status
    }

    /// What a program printed (trimmed), or nil when it couldn't start, failed or ran out of time. Blocks: call off the main thread.
    /// (Runs' Runner: in the temporary folder, no input, errors dropped, up to 1 MB of output read while it runs and for a second
    /// after it ended at most, a program it started may hold the output open; past `timeout` SIGTERM, then SIGKILL after `grace`.)
    static func output(_ exe: String, _ args: [String], environment: [String: String]? = nil, timeout: TimeInterval, grace: TimeInterval) -> String? {
        guard let r = Runs.Runner.run(Runs.Program(exe, args, environment: environment, timeout: timeout, grace: grace, keepOutput: true)),
              r.status == 0 else { return nil }
        return String(data: r.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
