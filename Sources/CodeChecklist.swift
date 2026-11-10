// CodeChecklist: what code a move leaves behind, as a list for the new Mac (format 5). A move carries the sessions, never the code they
// ran in. So on a move's export, for each project folder of the sessions in it (the git repo that holds a session's folder), cl_audit
// reads on this Mac, with read-only git, where the code can be cloned from and what wasn't pushed or committed:
//
//   git -C <folder> rev-parse --show-toplevel        the repo's top (fails: not a git repo)
//   git -C <top> symbolic-ref --quiet --short HEAD   the branch (exit 1: a detached HEAD)
//   git -C <top> rev-parse --short HEAD              the latest commit
//   git -C <top> for-each-ref --format=%(upstream:short) refs/heads/<branch>   whether the branch is on a remote (empty: not yet)
//   git -C <top> rev-list --count @{u}..             commits not pushed
//   git -C <top> config --local --get-regexp <…>     whether the repo's own config runs a program (a filter, a diff driver, a monitor,
//                                                    a pager, an ssh command) or includes another file: then `status` is never run
//   git -C <top> status --porcelain                  files not committed (one line each)
//   git -C <top> remote, remote get-url origin       the clone source (else the first remote's), with any user name, password or
//                                                    token, the query and the fragment taken out (https://user:tok@host/… →
//                                                    https://host/…; an ssh address such as git@host:org/repo keeps its user);
//                                                    an address that still holds an "@" or a ":" that isn't a port, starts with
//                                                    "-" or is an ext::/fd:: transport is left out, and the page says so
//
// Each in its own process group, with a plain environment, GIT_OPTIONAL_LOCKS=0 (nothing written into the repo, not even the index's
// stat cache), no system config, no hooks, no file system monitor, no lazy fetch, never a network protocol, and a 10-second limit
// (SIGTERM to the group, SIGKILL a second later, and nothing more waited for); the whole list within 60 seconds and stopped with the
// Export page (the projects left are "not read"). A field git couldn't read is said ("couldn't read the files not committed"), never
// taken for clean. Its output is data: one line, control characters out, at most 300 characters. The git used is the person's own:
// /usr/bin/git when the Command Line Tools are there (`xcode-select -p`, which never asks to install them), else the first git on PATH,
// /opt/homebrew/bin or /usr/local/bin; none: the checklist says so and lists the folders only.
//
// The Export page warns before the export ("garden-app: 3 commits not pushed: push them before you move"). The list travels only in the
// encrypted image (code.json beside export.json); the Import page shows it per project: where to clone it from, where it was, the
// branch, what wasn't pushed or committed there, and the commands as text to copy. cl_audit never runs git on the new Mac.
//
// The file is untrusted on the way in: read under a 256 KB cap, at most 16 levels deep, every field checked for its type and form (a
// path, a branch name, a commit, a count, an address with no credentials and no key shape), anything else dropped and said.

import Foundation

enum CodeChecklist {
    static let fileName = "code.json"
    static let format = "cl_audit-code"
    static let maxBytes = 256 << 10
    static let maxProjects = 100
    static let maxWorktrees = 20
    /// Each git call's limit, and the whole list's (a check's seams): past the budget, the projects left are "not read".
    nonisolated(unsafe) static var timeout: TimeInterval = 10
    nonisolated(unsafe) static var budget: TimeInterval = 60

    /// What git couldn't read for a project or worktree (it failed, timed out, or its settings run programs), by name.
    enum Field: String, Codable, CaseIterable { case branch, head, unpushed, uncommitted, remote }

    struct Worktree: Codable, Equatable {
        var path: String                    // "~/code/garden-app/.claude/worktrees/wt-forms"
        var branch: String?
        var head: String?
        var unpushed: Int?
        var uncommitted: Int?
        var upstream: Bool? = nil           // false: its branch isn't on a remote yet
        var unread: [Field]? = nil
    }

    struct Project: Codable, Equatable {
        var path: String                    // where it was on the old Mac: "~/code/garden-app" (~ for that Mac's home folder)
        var git: Bool                       // a git repo
        var remote: String?                 // where to clone it from, without credentials
        var branch: String?                 // nil: a detached HEAD (or not read)
        var head: String?                   // the latest commit, short
        var unpushed: Int?                  // commits not pushed; nil: no upstream, or not read (`unread`)
        var uncommitted: Int?               // files not committed; nil: not read
        var sessions: Int                   // the move's sessions that ran in it
        var worktrees: [Worktree]? = nil    // Claude Code worktrees the sessions ran in
        var note: String? = nil             // "wasn't on the old Mac", "not a git repo", why the remote is left out …
        var upstream: Bool? = nil           // false: its branch isn't on a remote yet
        var unread: [Field]? = nil          // what git couldn't read
        /// Every field git could have read was read (a git repo, nothing unread, its worktrees too).
        var fullyRead: Bool { git && (unread ?? []).isEmpty && (worktrees ?? []).allSatisfy { ($0.unread ?? []).isEmpty } }
    }

    struct File: Codable, Equatable {
        var format = CodeChecklist.format
        var version = 1
        var created: Date
        var git: String?                    // nil: read with git; else why not ("git isn't on this Mac")
        var projects: [Project]
        var notes: [String]? = nil          // (on the way in) what was dropped or cleaned
    }

    // MARK: git

    /// A check's seam: the git to use (nil: none on this Mac).
    nonisolated(unsafe) static var gitPath: () -> String? = { locateGit() }
    /// A check's seam: more environment for git (a suite's GIT_CEILING_DIRECTORIES, so its fake repos never find the tree they sit in).
    nonisolated(unsafe) static var extraEnv: [String: String] = [:]

    static func locateGit() -> String? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: "/usr/bin/git"), fm.isExecutableFile(atPath: "/usr/bin/xcode-select"),
           let r = Tool.run("/usr/bin/xcode-select", ["-p"]), r.status == 0, !r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "/usr/bin/git"
        }
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for d in path + ["/opt/homebrew/bin", "/usr/local/bin"] where d.hasPrefix("/") && d != "/usr/bin" {
            let g = (d as NSString).appendingPathComponent("git")
            var st = stat()
            if stat(g, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, fm.isExecutableFile(atPath: g) { return g }
        }
        return nil
    }

    /// What one git call gave: its exit status and what it printed (at most 1 MB). nil from `git`: it couldn't start, ran out of time or
    /// was stopped.
    struct Run {
        var status: Int32
        var out: String
        /// Its first line, cleaned (control and bidi characters out, at most 300 characters); nil when it failed or printed nothing.
        var line: String? { status == 0 ? Optional(oneLine(out)).flatMap { $0.isEmpty ? nil : $0 } : nil }
    }

    /// The flags every call gets: no hooks, no file system monitor, no untracked cache, no replace refs, never a network fetch.
    static let safeFlags = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "protocol.allow=never",
                            "--no-replace-objects"]

    /// git in `dir`, read-only: its own process group, a plain environment, `timeout` seconds at most (then SIGTERM to the group, SIGKILL
    /// a second later, and nothing more is waited for), `cancel` asked every 50 ms.
    static func git(_ git: String, _ dir: String, _ args: [String], until deadline: Date, cancel: () -> Bool = { false }) -> Run? {
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "HOME": NSHomeDirectory(), "GIT_OPTIONAL_LOCKS": "0",
                   "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false", "GIT_PAGER": "cat", "PAGER": "cat",
                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1"]
        if let t = ProcessInfo.processInfo.environment["TMPDIR"] { env["TMPDIR"] = t }
        for (k, v) in extraEnv { env[k] = v }
        let end = min(deadline, Date().addingTimeInterval(timeout))
        guard Date() < end, !cancel() else { return nil }
        return spawn(git, ["-C", dir] + safeFlags + args, env: env, until: end, cancel: cancel)
    }

    /// Runs `exe` in a process group of its own and reads its standard output until it ends or `end` passes; stderr goes nowhere.
    static func spawn(_ exe: String, _ args: [String], env: [String: String], until end: Date, cancel: () -> Bool) -> Run? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let (r, w) = (fds[0], fds[1])
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, w, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, r)
        posix_spawn_file_actions_addclose(&actions, w)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &actions, &attr, argv, envp)
        close(w)
        guard rc == 0 else { close(r); return nil }
        defer { close(r) }
        _ = fcntl(r, F_SETFL, fcntl(r, F_GETFL) | O_NONBLOCK)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 << 10)
        var eof = false, late = false
        while !eof {
            if Date() >= end || cancel() { late = true; break }
            var p = pollfd(fd: r, events: Int16(POLLIN), revents: 0)
            let n = poll(&p, 1, 50)
            if n > 0 {
                let k = Darwin.read(r, &buf, buf.count)
                if k > 0 { if out.count < 1 << 20 { out.append(contentsOf: buf[0..<k]) } } else if k == 0 { eof = true } else if errno != EAGAIN && errno != EINTR { eof = true }
            }
        }
        var status: Int32 = 0
        if late {
            // the whole group: git and anything it started (a filter, a pager) that may hold the pipe
            kill(-pid, SIGTERM)
            let grace = Date().addingTimeInterval(1)
            while waitpid(pid, &status, WNOHANG) == 0 && Date() < grace { usleep(20_000) }
            kill(-pid, SIGKILL)
            if waitpid(pid, &status, WNOHANG) == 0 { _ = waitpid(pid, &status, 0) }
            return nil
        }
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        kill(-pid, SIGKILL)                                     // nothing of its group outlives it
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Run(status: code, out: String(decoding: out, as: UTF8.self))
    }

    /// The settings a repo's own config can hold that run a program (a filter, a diff driver, a monitor, a pager, an ssh command) or pull in
    /// another file. When its local config names one, `status` (which can run a filter) is never called for it.
    static let runsPrograms = #"^(filter\..*\.(clean|smudge|process)|core\.(fsmonitor|pager|sshcommand|gitproxy)|diff\..*\.(textconv|command)|include\.path|includeif\..*\.path)$"#

    static func oneLine(_ s: String, max: Int = 300) -> String {
        let first = s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
        let kept = first.unicodeScalars.filter { u in
            !(u.value < 0x20 || u.value == 0x7F || (0x80...0x9F).contains(u.value) || (0x200B...0x200F).contains(u.value) || (0x202A...0x202E).contains(u.value)
              || (0x2066...0x2069).contains(u.value) || u.value == 0xFEFF)
        }
        return String(String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces).prefix(max))
    }

    /// Why a remote is left out, as the pages say it.
    static let remoteLeftOut = "its address held something like a key, so it is left out"

    /// The clone source without credentials: a URL's user name and password, its query and its fragment out, except an ssh user with no
    /// password (ssh://git@host/…, git@host:org/repo). nil (left out) when nothing is left, an "@" or a ":" that isn't a port is still in
    /// a URL's address, it starts with "-" (an option to git when pasted), it is an `ext::` or `fd::` transport, or a key shape is in it.
    static func strippedRemote(_ raw: String) -> String? {
        var s = oneLine(raw, max: 2048)
        guard !s.isEmpty, !s.contains(" "), !s.hasPrefix("-") else { return nil }
        let low = s.lowercased()
        guard !low.hasPrefix("ext::"), !low.hasPrefix("fd::") else { return nil }
        if let q = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<q]) }
        if let r = s.range(of: "://") {
            let scheme = s[..<r.lowerBound].lowercased()
            guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) else { return nil }
            let ssh = scheme == "ssh" || scheme == "git+ssh" || scheme == "ssh+git"
            let rest = s[r.upperBound...]
            // the user part ends at the last "@" before the path (a password may hold a "/")
            var auth: String, path: String
            if let at = rest.lastIndex(of: "@") {
                let user = rest[..<at]
                // (a "/" before the "@": a password holding one, or an "@" in the path; either way it can't be told apart safely)
                if user.contains("/") { return nil }
                let after = rest[rest.index(after: at)...]
                let slash = after.firstIndex(of: "/") ?? after.endIndex
                let keepUser = ssh && !user.contains(":") && !user.isEmpty
                auth = (keepUser ? String(user) + "@" : "") + after[..<slash]
                path = String(after[slash...])
            } else {
                let slash = rest.firstIndex(of: "/") ?? rest.endIndex
                auth = String(rest[..<slash]); path = String(rest[slash...])
            }
            // what is left of the address: a host, a plain user for ssh, a port of digits; nothing else
            let hostPart = auth.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            if let c = hostPart.firstIndex(of: ":"), !(hostPart[hostPart.index(after: c)...].allSatisfy(\.isNumber)) { return nil }
            if !ssh, auth.contains("@") || path.contains("@") { return nil }
            guard !auth.isEmpty || scheme == "file" else { return nil }
            s = scheme + "://" + auth + path
        } else if !s.hasPrefix("/"), let at = s.firstIndex(of: "@"), !s[..<at].contains("/"), s[s.index(after: at)...].contains(":") {
            // scp-like: user@host:path. A user part holding a ":" (a password) goes; a plain user (git@) stays
            let user = s[..<at]
            if user.contains(":") || user.isEmpty { s = String(s[s.index(after: at)...]) }
        }
        guard !s.isEmpty, SecretScan.scan(Data(s.utf8)).isEmpty else { return nil }
        return s
    }

    /// Where a folder is, as the checklist writes it: "~/…" under this Mac's home folder.
    static func written(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// What git says about one folder (a project's top or a worktree). A field git couldn't read is in `unread`. `status` (which can run
    /// a filter) is skipped when the repo's own config names a program to run (`runsPrograms`).
    struct State {
        var branch: String?, head: String?, unpushed: Int?, uncommitted: Int?
        var upstream: Bool?
        var unread: [Field] = []
        var runsPrograms = false
    }

    static func state(_ g: String, _ dir: String, until end: Date, cancel: () -> Bool) -> State {
        var s = State()
        // the branch: --quiet exits 1 for a detached HEAD (no branch, nothing unread); anything else is a failure
        if let r = git(g, dir, ["symbolic-ref", "--quiet", "--short", "HEAD"], until: end, cancel: cancel) {
            if r.status == 0 { s.branch = r.line.flatMap { validBranch(oneLine($0, max: 255)) }; if s.branch == nil { s.unread.append(.branch) } }
            else if r.status != 1 { s.unread.append(.branch) }
        } else { s.unread.append(.branch) }
        if let h = git(g, dir, ["rev-parse", "--short", "HEAD"], until: end, cancel: cancel)?.line.flatMap(validHead) { s.head = h } else { s.unread.append(.head) }
        // the upstream: whether the branch has one (empty: none), then how many commits it lacks
        if let b = s.branch {
            if let r = git(g, dir, ["for-each-ref", "--format=%(upstream:short)", "refs/heads/" + b], until: end, cancel: cancel), r.status == 0 {
                if (r.line ?? "").isEmpty { s.upstream = false }
                else {
                    s.upstream = true
                    if let n = git(g, dir, ["rev-list", "--count", "@{u}.."], until: end, cancel: cancel)?.line.flatMap({ Int($0) }) { s.unpushed = n } else { s.unread.append(.unpushed) }
                }
            } else { s.unread.append(.unpushed) }
        }
        // a repo whose own config runs a program: never `status`
        let cfg = git(g, dir, ["config", "--local", "--get-regexp", runsPrograms], until: end, cancel: cancel)
        if cfg == nil || cfg!.status == 0 || (cfg!.status != 1) { s.runsPrograms = cfg?.status == 0; s.unread.append(.uncommitted) }
        else if let r = git(g, dir, ["status", "--porcelain", "--untracked-files=normal", "--ignore-submodules=all"], until: end, cancel: cancel), r.status == 0 {
            s.uncommitted = r.out.split(separator: "\n", omittingEmptySubsequences: true).count
        } else { s.unread.append(.uncommitted) }
        return s
    }

    /// The checklist for these session folders (absolute cwds → how many sessions ran there): one project per git repo, or per folder
    /// that isn't one. `git` nil: none on this Mac (the folders are listed, and the file says so). Within `budget` seconds in all; the
    /// projects past it, or past `cancel`, are listed as not read.
    static func gather(_ folders: [String: Int], git gitExe: String?, home: String = NSHomeDirectory(), now: Date = Date(), cancel: () -> Bool = { false }) -> File {
        let end = Date().addingTimeInterval(budget)
        func out() -> Bool { Date() >= end || cancel() }
        var projects: [String: Project] = [:]
        var order: [String] = []
        var worktreesOf: [String: [String]] = [:]
        for (cwd, n) in folders.sorted(by: { $0.key < $1.key }) {
            guard SessionsRepoint.clean(cwd) else { continue }
            let folder = SessionsRepoint.projectFolder(of: cwd)
            var key = folder
            var p: Project
            if !SessionsRepoint.folderHere(folder) {
                p = projects[key] ?? Project(path: written(folder, home: home), git: false, sessions: 0, note: "wasn't on the old Mac")
            } else if gitExe != nil, out() {
                p = projects[key] ?? Project(path: written(folder, home: home), git: false, sessions: 0, note: cancel() ? "not read: stopped" : "not read: out of time")
            } else if let g = gitExe {
                let found = git(g, folder, ["rev-parse", "--show-toplevel"], until: end, cancel: cancel)
                if found == nil {
                    // git didn't answer in time (or was stopped): never taken for "not a git repo"
                    p = projects[key] ?? Project(path: written(folder, home: home), git: false, sessions: 0,
                                                 note: cancel() ? "not read: stopped" : out() ? "not read: out of time" : "not read: git didn't answer in time")
                } else if let top = found?.line.map({ oneLine($0, max: SessionsRepoint.maxPath) }), SessionsRepoint.clean(top) {
                    key = top
                    if let have = projects[key] { p = have } else {
                        let st = state(g, top, until: end, cancel: cancel)
                        let names = git(g, top, ["remote"], until: end, cancel: cancel)
                        let remoteName = names?.line
                        let url = git(g, top, ["remote", "get-url", "origin"], until: end, cancel: cancel)?.line
                            ?? remoteName.flatMap { $0 == "origin" ? nil : git(g, top, ["remote", "get-url", $0], until: end, cancel: cancel)?.line }
                        p = Project(path: written(top, home: home), git: true, remote: url.flatMap(strippedRemote), branch: st.branch, head: st.head,
                                    unpushed: st.unpushed, uncommitted: st.uncommitted, sessions: 0)
                        p.upstream = st.upstream
                        var unread = st.unread
                        if names == nil || (names!.status != 0) { unread.append(.remote) }
                        p.unread = unread.isEmpty ? nil : unread
                        if st.runsPrograms { p.note = "not read: its git settings run programs" }
                        if url != nil, p.remote == nil { p.note = remoteLeftOut }
                    }
                } else {
                    p = projects[key] ?? Project(path: written(folder, home: home), git: false, sessions: 0, note: out() ? "not read: out of time" : "not a git repo")
                }
            } else {
                p = projects[key] ?? Project(path: written(folder, home: home), git: false, sessions: 0, note: "not read: git isn't on the old Mac")
            }
            p.sessions += n
            if projects[key] == nil { order.append(key) }
            projects[key] = p
            if let wt = SessionsRepoint.worktreeFolder(of: cwd), gitExe != nil, SessionsRepoint.folderHere(wt), !(worktreesOf[key] ?? []).contains(wt) {
                worktreesOf[key, default: []].append(wt)
            }
        }
        var list: [Project] = []
        for key in order.prefix(maxProjects) {
            guard var p = projects[key] else { continue }
            if let g = gitExe, p.git {
                let wts = (worktreesOf[key] ?? []).prefix(maxWorktrees).map { w -> Worktree in
                    let st = state(g, w, until: end, cancel: cancel)
                    return Worktree(path: written(w, home: home), branch: st.branch, head: st.head, unpushed: st.unpushed, uncommitted: st.uncommitted,
                                    upstream: st.upstream, unread: st.unread.isEmpty ? nil : st.unread)
                }
                if !wts.isEmpty { p.worktrees = Array(wts) }
            }
            list.append(p)
        }
        return File(created: now, git: gitExe == nil ? "git isn't on the old Mac" : nil, projects: list)
    }

    /// code.json for the image. A list over 256 KB is cut to the projects that fit, and says so (never left out without a word).
    static func encode(_ f: File) -> Data? {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var g = f
        while true {
            guard let d = try? enc.encode(g) else { return nil }
            if d.count <= maxBytes { return d }
            guard g.projects.count > 1 else { return nil }
            g.projects = Array(g.projects.prefix(g.projects.count / 2))
            g.notes = ["The list came to over \(maxBytes >> 10) KB, so only the first \(g.projects.count) of \(f.projects.count) projects are in it."]
        }
    }

    // MARK: reading it back (untrusted)

    static func validBranch(_ s: String) -> String? {
        guard !s.isEmpty, s.utf8.count <= 255, !s.hasPrefix("-"), !s.hasPrefix("/"), !s.hasSuffix("/"), !s.hasSuffix(".lock"), !s.contains(".."), !s.contains("//"), !s.contains("@{"),
              s.unicodeScalars.allSatisfy({ ($0.value >= 0x21 && $0.value < 0x7F) && !"~^:?*[\\\"'`$;&|<>()".unicodeScalars.contains($0) }) else { return nil }
        return s
    }

    static func validHead(_ s: String) -> String? {
        guard (4...64).contains(s.count), s.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return s
    }

    /// A path as the file names it: "~", "~/…" or absolute, clean (no control characters, no "." or ".." parts), at most 1024 characters.
    static func validPath(_ s: String) -> String? {
        guard s.utf8.count <= 1024 else { return nil }
        if s == "~" { return s }
        let abs = s.hasPrefix("~/") ? "/h" + s.dropFirst(1) : s
        return SessionsRepoint.clean(abs) && abs != "/" ? s : nil
    }

    static func count(_ v: Any?) -> Int? {
        guard let v, !SessionsMove.isBool(v), let n = SessionsMove.int(v), (0...10_000_000).contains(n) else { return nil }
        return n
    }

    /// code.json read and checked. nil: it isn't one (not a JSON object, over 256 KB, nested too deep, another format).
    static func read(_ d: Data) -> File? {
        guard d.count <= maxBytes, SessionsMove.depth(d) <= 16, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              j["format"] as? String == format else { return nil }
        var notes: [String] = []
        let created = (j["created"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date(timeIntervalSince1970: 0)
        let gitWhy = (j["git"] as? String).map { oneLine($0, max: 120) }.flatMap { $0.isEmpty ? nil : $0 }
        var projects: [Project] = []
        let list = j["projects"] as? [Any] ?? []
        if list.count > maxProjects { notes.append("The checklist names more than \(maxProjects) projects; the first \(maxProjects) are shown.") }
        for (i, item) in list.prefix(maxProjects).enumerated() {
            guard let o = item as? [String: Any], let rawPath = o["path"] as? String, let path = validPath(rawPath) else {
                notes.append("Project \(i + 1) of the checklist has no path that can be shown; left out."); continue
            }
            var p = Project(path: path, git: SessionsMove.bool(o["git"]) ?? false, sessions: count(o["sessions"]) ?? 0)
            if let r = o["remote"] {
                if let s = r as? String, let clean = strippedRemote(s) { p.remote = clean; if clean != oneLine(s, max: 2048) { notes.append("\(name(path)): the remote's address held credentials; they are left out.") } }
                else { notes.append("\(name(path)): the remote's address can't be shown (credentials, something that looks like a key, or an odd form); left out.") }
            }
            if let b = o["branch"] { p.branch = (b as? String).flatMap(validBranch); if p.branch == nil { notes.append("\(name(path)): the branch name isn't one; left out.") } }
            if let h = o["head"] { p.head = (h as? String).flatMap(validHead); if p.head == nil { notes.append("\(name(path)): the last commit isn't one; left out.") } }
            if o["unpushed"] != nil { p.unpushed = count(o["unpushed"]); if p.unpushed == nil { notes.append("\(name(path)): the count of commits not pushed isn't a number; left out.") } }
            if o["uncommitted"] != nil { p.uncommitted = count(o["uncommitted"]); if p.uncommitted == nil { notes.append("\(name(path)): the count of files not committed isn't a number; left out.") } }
            if let n = o["note"] as? String { let c = oneLine(n, max: 120); if !c.isEmpty { p.note = c } }
            p.upstream = SessionsMove.bool(o["upstream"])
            p.unread = fields(o["unread"])
            if let ws = o["worktrees"] as? [Any] {
                var wts: [Worktree] = []
                for w in ws.prefix(maxWorktrees) {
                    guard let wo = w as? [String: Any], let wp = (wo["path"] as? String).flatMap(validPath) else { continue }
                    wts.append(Worktree(path: wp, branch: (wo["branch"] as? String).flatMap(validBranch), head: (wo["head"] as? String).flatMap(validHead),
                                        unpushed: count(wo["unpushed"]), uncommitted: count(wo["uncommitted"]), upstream: SessionsMove.bool(wo["upstream"]),
                                        unread: fields(wo["unread"])))
                }
                if !wts.isEmpty { p.worktrees = wts }
            }
            projects.append(p)
        }
        // the file's own notes (a list cut to fit): plain lines, a few
        for n in ((j["notes"] as? [Any]) ?? []).prefix(4) { if let s = n as? String { let c = oneLine(s, max: 200); if !c.isEmpty { notes.append(c) } } }
        return File(created: created, git: gitWhy, projects: projects, notes: notes.isEmpty ? nil : notes)
    }

    /// The fields a file says git couldn't read: known names only.
    static func fields(_ v: Any?) -> [Field]? {
        let list = ((v as? [Any]) ?? []).prefix(8).compactMap { ($0 as? String).flatMap(Field.init(rawValue:)) }
        return list.isEmpty ? nil : list
    }

    static func name(_ path: String) -> String { (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent }

    // MARK: words

    /// A word for the shell: as it is when it is plain, else in single quotes. A leading "~/" stays outside them, so the shell expands it.
    static func shellWord(_ s: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if s.hasPrefix("~/") { let rest = String(s.dropFirst(2)); return "~/" + (rest.isEmpty ? "" : shellWord(rest)) }
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ plain.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The commands to get it on the new Mac, as text (cl_audit never runs them). `here`: the folder is already on this Mac.
    static func commands(_ p: Project, here: Bool) -> [String] {
        guard p.git else { return [] }
        let path = shellWord(p.path)
        var out: [String] = []
        if here { out.append("cd \(path) && git fetch") }
        // ("--": nothing in the address can be taken for an option when it is pasted)
        else if let r = p.remote { out.append("git clone -- \(shellWord(r)) \(path)"); out.append("cd \(path)") }
        else { return [] }
        if let b = p.branch { out.append("git checkout \(shellWord(b))") }
        return out
    }

    /// The words for fields git couldn't read: "the files not committed", "the branch".
    static func unreadWords(_ f: [Field]) -> String {
        let w: [Field: String] = [.branch: "the branch", .head: "the latest commit", .unpushed: "the commits not pushed", .uncommitted: "the files not committed",
                                  .remote: "the remote"]
        return f.compactMap { w[$0] }.joined(separator: ", ")
    }

    /// The Export page's warnings: "garden-app: 3 commits not pushed: push them before you move".
    static func warnings(_ f: File) -> [String] {
        var out: [String] = []
        for p in f.projects {
            let n = name(p.path)
            if let k = p.unpushed, k > 0 { out.append("\(n): \(k) \(k == 1 ? "commit" : "commits") not pushed: push \(k == 1 ? "it" : "them") before you move") }
            else if p.git, p.upstream == false, let b = p.branch { out.append("\(n): its branch \(b) isn't on a remote yet: push it before you move") }
            if let k = p.uncommitted, k > 0 { out.append("\(n): \(k) \(k == 1 ? "file" : "files") not committed: commit and push before you move, or copy \(k == 1 ? "it" : "them") by hand") }
            if let u = p.unread, !u.isEmpty {
                out.append("\(n): couldn't read \(unreadWords(u))" + (p.note == "not read: its git settings run programs" ? " (its git settings run programs)" : "") + ": check it before you move")
            }
            if p.git, p.remote == nil { out.append("\(n): " + (p.note == remoteLeftOut ? "\(remoteLeftOut): copy the folder by hand" : "no remote to clone it from: copy the folder by hand")) }
            if !p.git, p.note == "not a git repo" { out.append("\(n): not a git repo: copy the folder by hand") }
            if !p.git, let note = p.note, note.hasPrefix("not read: out of time") || note.hasPrefix("not read: stopped") || note.hasPrefix("not read: git didn't") {
                out.append("\(n): \(note): check it before you move")
            }
            if !p.git, p.note == "wasn't on the old Mac" { out.append("\(n): its folder isn't on this Mac, so nothing was read") }
            for w in p.worktrees ?? [] {
                let wn = name(w.path)
                if let k = w.unpushed, k > 0 { out.append("\(n), worktree \(wn): \(k) \(k == 1 ? "commit" : "commits") not pushed: push \(k == 1 ? "it" : "them") before you move") }
                else if w.upstream == false, let b = w.branch { out.append("\(n), worktree \(wn): its branch \(b) isn't on a remote yet: push it before you move") }
                if let k = w.uncommitted, k > 0 { out.append("\(n), worktree \(wn): \(k) \(k == 1 ? "file" : "files") not committed: commit and push before you move") }
                if let u = w.unread, !u.isEmpty { out.append("\(n), worktree \(wn): couldn't read \(unreadWords(u)): check it before you move") }
            }
        }
        return out
    }

    /// The Export page's Code row: what was read, and that the list goes in the image (always, on a move). "All pushed and committed" only
    /// when git read every field of every project.
    static func summary(_ f: File) -> String {
        let n = f.projects.count, g = f.projects.filter(\.git).count
        let projects = "\(n) \(n == 1 ? "project" : "projects")"
        if n == 0 { return "none: the sessions name no folder" }
        if f.git != nil { return "\(projects): not read, git isn't on this Mac (the list of folders goes in the image)" }
        let warn = warnings(f).count
        let head = projects + (g > 0 ? ", \(g) in git" : "")
        if warn > 0 { return "\(head): \(warn) \(warn == 1 ? "thing" : "things") to fix first (the list goes in the image)" }
        if f.projects.allSatisfy(\.fullyRead) { return "\(head): all pushed and committed (the list goes in the image)" }
        return "\(head): nothing to warn about (the list goes in the image)"
    }

    /// The Import page's lines for one project: what to fetch, and what the old Mac had that a clone won't.
    static func lines(_ p: Project, here: Bool) -> [String] {
        var out: [String] = []
        if p.git {
            let noRemote = p.note == remoteLeftOut ? "Was at \(p.path); \(remoteLeftOut): copy it by hand" : "Was at \(p.path), with no remote to clone it from: copy it by hand"
            var what = here ? "On this Mac at \(p.path)" : (p.remote.map { "Clone \($0) at \(p.path)" } ?? noRemote)
            if let b = p.branch { what += ", branch \(b)" + (p.head.map { " (latest commit \($0))" } ?? "") } else if let h = p.head { what += ", at commit \(h)" }
            out.append(what)
            if let k = p.unpushed, k > 0 { out.append("\(k) \(k == 1 ? "commit wasn't" : "commits weren't") pushed on the old Mac: a clone won't have \(k == 1 ? "it" : "them") until \(k == 1 ? "it is" : "they are") pushed there") }
            if p.upstream == false, p.branch != nil { out.append("Its branch wasn't on a remote on the old Mac: push it there first, or it won't be in a clone") }
            if let k = p.uncommitted, k > 0 { out.append("\(k) \(k == 1 ? "file wasn't" : "files weren't") committed on the old Mac: copy \(k == 1 ? "it" : "them") by hand, or commit and push there") }
            if let u = p.unread, !u.isEmpty { out.append("Couldn't be read on the old Mac: \(unreadWords(u))" + (p.note == "not read: its git settings run programs" ? " (its git settings run programs)" : "") + ". Check it there") }
            for w in p.worktrees ?? [] {
                var s = "Worktree \(name(w.path))" + (w.branch.map { " on \($0)" } ?? "")
                var bad: [String] = []
                if let k = w.unpushed, k > 0 { bad.append("\(k) not pushed") } else if w.upstream == false, w.branch != nil { bad.append("not on a remote yet") }
                if let k = w.uncommitted, k > 0 { bad.append("\(k) \(k == 1 ? "file" : "files") not committed") }
                if let u = w.unread, !u.isEmpty { bad.append("couldn't read \(unreadWords(u))") }
                s += bad.isEmpty ? ": all pushed" : ": " + bad.joined(separator: ", ")
                out.append(s + ". The session runs in the project folder unless the worktree is made again")
            }
        } else {
            out.append("\(p.path): " + (p.note ?? "not a git repo") + (p.note == "not a git repo" || p.note == nil ? ": copy the folder from the old Mac" : ""))
        }
        return out
    }
}
