// Runs · the process table: the processes running on this Mac as the kernel lists them (proc_listallpids, KERN_PROC,
// KERN_PROCARGS2, proc_name, proc_pidpath), with no `ps` or `pgrep`, so nothing waits on a helper. Of a process's
// environment only CLAUDE_CONFIG_DIR is kept: each entry is compared as bytes and the buffer is wiped before it is let go.
// Where the table can't be read, or a process that may be Claude Code can't be (another user's `claude`, as with
// `sudo claude`, included), the answer says so (`nil`, `hidden`), and callers refuse rather than guess. Nothing here signals
// a process.
//
// Moved here from the settings app's own process code (Sources/Processes.swift: the kernel's table, unchanged but for
// `public`, the parent's pid and `isClaudeCode`), so that ClaudeAuth's sign-in finds a `claude auth login` in every app the
// same way. The app's process code keeps its own parts (the Claude app, Claude Code by folder, the session ids) and reads
// the table through this.

import Foundation

public enum ProcessTable {
    /// How a process was started: its executable, its arguments (argv, empty ones included) and its CLAUDE_CONFIG_DIR (nil when
    /// it isn't set, or when the environment couldn't be read).
    public struct Launch: Equatable {
        public var exe: String
        public var args: [String]
        public var configDir: String?
        /// The kernel gave the process's environment. It gives none for Apple's platform binaries (/bin/bash, /bin/sleep: a
        /// shell a stand-in or a script runs in), while it does for Claude Code's own program and other ad-hoc or
        /// developer-signed ones. Without it a nil `configDir` says nothing: the folder can't be told from it.
        public var environmentRead: Bool

        public init(exe: String, args: [String], configDir: String?, environmentRead: Bool = true) {
            self.exe = exe; self.args = args; self.configDir = configDir; self.environmentRead = environmentRead
        }
    }

    /// A process of the table: its id, its parent's, its effective and real user (nil when even they can't be read), its name
    /// (proc_name for the caller's user, else the kernel's short name) and how it was started. That is read for the caller's
    /// user's processes and for any whose name looks like Claude Code's (`looksLikeClaude`); another user's other processes
    /// aren't read (`ps` couldn't read them either). `hidden`: it may be Claude Code, but how it was started couldn't be read
    /// (another user's `claude`, as with `sudo claude`, or anything whose basic facts can't be read): whoever asks then can't
    /// tell, and says so.
    public struct Entry: Equatable {
        public var pid: pid_t
        public var ppid: pid_t?
        public var uid: uid_t?
        public var ruid: uid_t?
        public var name: String
        public var launch: Launch?
        public var hidden = false

        public init(pid: pid_t, ppid: pid_t? = nil, uid: uid_t?, ruid: uid_t?, name: String, launch: Launch?, hidden: Bool = false) {
            self.pid = pid; self.ppid = ppid; self.uid = uid; self.ruid = ruid; self.name = name; self.launch = launch; self.hidden = hidden
        }
    }

    /// `table()`, read once more when something in it was hidden (a process caught mid-start or mid-exit), before the answer
    /// is "can't tell".
    public static func settledTable() -> [Entry]? {
        let t = table()
        return t?.contains(where: \.hidden) == true ? table() : t
    }

    /// Every process the kernel lists, the caller itself included, except those that ended meanwhile or are ended and waiting
    /// to be reaped (they run nothing); nil when the list can't be read or may have been cut short.
    public static func table() -> [Entry]? {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        // a full list may have left processes out
        guard got > 0, Int(got) < pids.count else { return nil }
        let me = getuid()
        var out: [Entry] = []
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
            var e = Entry(pid: pid, ppid: info.kp_eproc.e_ppid, uid: uid, ruid: ruid, name: name, launch: nil)
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

    /// The basic facts through KERN_PROC (proc_pidinfo refuses another user's processes): nil when it ended (or is ended and
    /// waiting to be reaped); .unreadable when they can't be read.
    enum Facts { case read(kinfo_proc), unreadable }
    static func facts(_ pid: pid_t) -> Facts? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return errno == ESRCH ? nil : .unreadable }
        return size > 0 && info.kp_proc.p_stat != CChar(SZOMB) ? .read(info) : nil
    }

    /// A name Claude Code's program may have: `claude…` (not a helper), or a version number (the native installer's
    /// …/claude/versions/2.1.318).
    public static func looksLikeClaude(_ name: String) -> Bool {
        let short = name.lowercased()
        if short == "claude" || short == "claude.exe" || short.hasPrefix("claude") && !short.contains("helper") { return true }
        let parts = short.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// Whether a process, as it was started, is Claude Code's program (not the Claude app's own, nor a profile's window copy):
    /// The app's former `Processes.isCode` without the folder, which the caller compares.
    public static func isClaudeCode(_ l: Launch) -> Bool {
        let exe = l.exe, args = l.args
        if exe.hasSuffix("/Claude.app/Contents/MacOS/Claude") || exe.contains("/Claude.app/Contents/Frameworks/") { return false }
        if let r = exe.range(of: ".app/Contents/MacOS/") {
            let bundle = (String(exe[..<r.lowerBound]) as NSString).lastPathComponent + ".app"
            if bundle != "claude.app" { return false }
        }
        let leaf = (exe as NSString).lastPathComponent.lowercased()
        return leaf == "claude" || leaf == "claude.exe" || exe.contains("/claude-code/") || exe.contains("/claude/versions/")
            || ((args.first ?? "") as NSString).lastPathComponent.lowercased() == "claude"
            || args.contains { $0.hasSuffix("/claude") || $0.contains("@anthropic-ai/claude-code") }
    }

    /// How a process was started (KERN_PROCARGS2), or nil when it can't be read. Of its environment only CLAUDE_CONFIG_DIR is
    /// kept: each entry is compared as bytes, and the buffer is wiped before it is let go.
    public static func launch(of pid: pid_t) -> Launch? { read(pid).launch }

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

    /// KERN_PROCARGS2's bytes: argc, the executable path, NULs up to the next 8 bytes counted from the path's start (NUL by NUL
    /// when the layout is another), exactly argc arguments (empty ones included), then the environment up to an empty entry.
    /// nil when cut short, or when the first argument is empty or starts with a space.
    public static func parse(_ buf: [UInt8], size: Int) -> Launch? {
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
        var entries = 0
        let prefix = Array("CLAUDE_CONFIG_DIR=".utf8)
        while i < size {                                            // the environment, up to its end (an empty entry)
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            if i == start { break }
            entries += 1
            if i - start >= prefix.count, Array(buf[start..<(start + prefix.count)]) == prefix {
                configDir = String(decoding: buf[(start + prefix.count)..<i], as: UTF8.self)
            }
            i += 1
        }
        guard args.count == argc else { return nil }                // cut short: not read
        // an empty or space-led program can't be told from a misread layout (an empty argv[0] can't be told from padding): not
        // read, so the process is hidden rather than taken for "not Claude"
        if let first = args.first, first.isEmpty || first.hasPrefix(" ") { return nil }
        return Launch(exe: exe, args: args, configDir: configDir, environmentRead: entries > 0)
    }

    /// The program a running process was started from (proc_pidpath), or nil when it isn't running.
    public static func executable(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    /// When a process started (seconds): with its pid, which process it is (a pid alone can be reused).
    public static func startTime(of pid: pid_t) -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return Int(info.kp_proc.p_un.__p_starttime.tv_sec)
    }

    /// Whether a process with this id runs (another user's counts: it is there, only not ours to signal). A process ended and
    /// waiting to be reaped doesn't run.
    public static func runs(_ pid: pid_t) -> Bool { (kill(pid, 0) == 0 || errno == EPERM) && facts(pid) != nil }
}
