// CodeChecklist: what code a move leaves behind, as a list for the new Mac (format 5). A move carries the sessions, never the code they
// ran in. So on a move's export, for each project folder of the sessions in it (the git repo that holds a session's folder), cl_audit
// reads on this Mac, with read-only git, where the code can be cloned from and what wasn't pushed or committed:
//
//   git -C <folder> rev-parse --show-toplevel        the repo's top (fails: not a git repo)
//   git -C <top> symbolic-ref --quiet --short HEAD   the branch (fails: a detached HEAD)
//   git -C <top> rev-parse --short HEAD              the last commit
//   git -C <top> status --porcelain                  files not committed (one line each)
//   git -C <top> rev-list --count @{u}..             commits not pushed (fails: no upstream)
//   git -C <top> remote get-url origin               the clone source (else the first remote's), with any user name, password or
//                                                    token taken out (https://user:tok@host/… → https://host/…; an ssh address
//                                                    such as git@host:org/repo keeps its user)
//
// Each with GIT_OPTIONAL_LOCKS=0 (nothing written into the repo, not even the index's stat cache), GIT_TERMINAL_PROMPT=0, the file
// system monitor off, and a 10-second limit; never fetch, never anything that writes. Its output is data: one line, control characters
// out, at most 300 characters. The git used is the person's own: /usr/bin/git when the Command Line Tools are there (`xcode-select -p`,
// which never asks to install them), else the first git on PATH, /opt/homebrew/bin or /usr/local/bin; none: the checklist says so and
// lists the folders only.
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
    static let timeout: TimeInterval = 10

    struct Worktree: Codable, Equatable {
        var path: String                    // "~/code/garden-app/.claude/worktrees/wt-forms"
        var branch: String?
        var head: String?
        var unpushed: Int?
        var uncommitted: Int?
    }

    struct Project: Codable, Equatable {
        var path: String                    // where it was on the old Mac: "~/code/garden-app" (~ for that Mac's home folder)
        var git: Bool                       // a git repo
        var remote: String?                 // where to clone it from, without credentials
        var branch: String?                 // nil: a detached HEAD (or not read)
        var head: String?                   // the last commit, short
        var unpushed: Int?                  // commits not pushed; nil: no upstream (or not read)
        var uncommitted: Int?               // files not committed
        var sessions: Int                   // the move's sessions that ran in it
        var worktrees: [Worktree]? = nil    // Claude Code worktrees the sessions ran in
        var note: String? = nil             // "wasn't there", "git couldn't read it", "no upstream"
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

    /// One line of what git printed: control and bidi characters out, at most 300 characters; nil when it failed or printed nothing.
    static func runGit(_ git: String, _ dir: String, _ args: [String]) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var env = ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "", "SSH_ASKPASS": "", "GIT_PAGER": "cat", "PAGER": "cat"]
        for (k, v) in extraEnv { env[k] = v }
        guard let r = Tool.run(git, ["-C", dir, "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false"] + args, extraEnv: env,
                               poll: { Date() > deadline }), !r.cancelled, r.status == 0 else { return nil }
        return r.out
    }

    static func oneLine(_ s: String, max: Int = 300) -> String {
        let first = s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
        let kept = first.unicodeScalars.filter { u in
            !(u.value < 0x20 || u.value == 0x7F || (0x80...0x9F).contains(u.value) || (0x200B...0x200F).contains(u.value) || (0x202A...0x202E).contains(u.value)
              || (0x2066...0x2069).contains(u.value) || u.value == 0xFEFF)
        }
        return String(String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces).prefix(max))
    }

    /// The clone source without credentials: a URL's user name and password (and its query and fragment) out, except an ssh user with no
    /// password (ssh://git@host/…, git@host:org/repo); nil when nothing is left or a key shape is still in it.
    static func strippedRemote(_ raw: String) -> String? {
        var s = oneLine(raw, max: 2048)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if let r = s.range(of: "://") {
            let scheme = s[..<r.lowerBound].lowercased()
            guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) else { return nil }
            let rest = s[r.upperBound...]
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            var auth = String(rest[..<slash])
            var path = String(rest[slash...])
            if let at = auth.lastIndex(of: "@") {
                let user = auth[..<at]
                let keepUser = (scheme == "ssh" || scheme == "git+ssh") && !user.contains(":") && !user.isEmpty
                auth = (keepUser ? String(user) + "@" : "") + auth[auth.index(after: at)...]
            }
            if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<q]) }
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

    /// What git says about one folder (a project's top or a worktree): branch, head, unpushed, uncommitted.
    private static func state(_ git: String, _ dir: String) -> (branch: String?, head: String?, unpushed: Int?, uncommitted: Int?) {
        let branch = runGit(git, dir, ["symbolic-ref", "--quiet", "--short", "HEAD"]).map { oneLine($0, max: 255) }.flatMap(validBranch)
        let head = runGit(git, dir, ["rev-parse", "--short", "HEAD"]).map { oneLine($0, max: 64) }.flatMap(validHead)
        let status = runGit(git, dir, ["status", "--porcelain", "--untracked-files=normal"])
        let uncommitted = status.map { s in s.split(separator: "\n", omittingEmptySubsequences: true).count }
        let unpushed = runGit(git, dir, ["rev-list", "--count", "@{u}.."]).flatMap { Int(oneLine($0, max: 12)) }
        return (branch, head, unpushed, uncommitted)
    }

    /// The checklist for these session folders (absolute cwds → how many sessions ran there): one project per git repo, or per folder
    /// that isn't one. `git` nil: none on this Mac (the folders are listed, and the file says so).
    static func gather(_ folders: [String: Int], git: String?, home: String = NSHomeDirectory(), now: Date = Date(), cancel: () -> Bool = { false }) -> File {
        var projects: [String: Project] = [:]
        var order: [String] = []
        var worktreesOf: [String: [String]] = [:]
        for (cwd, n) in folders.sorted(by: { $0.key < $1.key }) {
            if cancel() { break }
            guard SessionsRepoint.clean(cwd) else { continue }
            let folder = SessionsRepoint.projectFolder(of: cwd)
            var key = folder
            var p: Project
            if !SessionsRepoint.folderHere(folder) {
                p = Project(path: written(folder, home: home), git: false, sessions: 0, note: "wasn't on that Mac when the move was made")
            } else if let g = git {
                if let top = runGit(g, folder, ["rev-parse", "--show-toplevel"]).map({ oneLine($0, max: SessionsRepoint.maxPath) }), SessionsRepoint.clean(top) {
                    key = top
                    if let have = projects[key] { p = have } else {
                        let st = state(g, top)
                        let remoteName = runGit(g, top, ["remote"]).map { oneLine($0, max: 255) }.flatMap { $0.isEmpty ? nil : $0 }
                        let url = runGit(g, top, ["remote", "get-url", "origin"]) ?? remoteName.flatMap { $0 == "origin" ? nil : runGit(g, top, ["remote", "get-url", $0]) }
                        p = Project(path: written(top, home: home), git: true, remote: url.flatMap(strippedRemote), branch: st.branch, head: st.head,
                                    unpushed: st.unpushed, uncommitted: st.uncommitted, sessions: 0)
                        if st.unpushed == nil, st.branch != nil { p.note = "no upstream" }
                        if url != nil, p.remote == nil { p.note = "its remote's address held a key, so it is left out" }
                    }
                } else {
                    p = projects[key] ?? Project(path: written(folder, home: home), git: false, sessions: 0, note: "not a git repo")
                }
            } else {
                p = projects[key] ?? Project(path: written(folder, home: home), git: false, sessions: 0, note: "not read: git isn't on that Mac")
            }
            p.sessions += n
            if projects[key] == nil { order.append(key) }
            projects[key] = p
            if let wt = SessionsRepoint.worktreeFolder(of: cwd), git != nil, SessionsRepoint.folderHere(wt), !(worktreesOf[key] ?? []).contains(wt) {
                worktreesOf[key, default: []].append(wt)
            }
        }
        var out: [Project] = []
        for key in order.prefix(maxProjects) {
            guard var p = projects[key] else { continue }
            if let g = git, p.git {
                let wts = (worktreesOf[key] ?? []).prefix(maxWorktrees).map { w -> Worktree in
                    let st = state(g, w)
                    return Worktree(path: written(w, home: home), branch: st.branch, head: st.head, unpushed: st.unpushed, uncommitted: st.uncommitted)
                }
                if !wts.isEmpty { p.worktrees = Array(wts) }
            }
            out.append(p)
        }
        return File(created: now, git: git == nil ? "git isn't on that Mac" : nil, projects: out)
    }

    static func encode(_ f: File) -> Data? {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let d = try? enc.encode(f), d.count <= maxBytes else { return nil }
        return d
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
                else { notes.append("\(name(path)): the remote's address can't be shown (credentials, a key shape or an odd form); left out.") }
            }
            if let b = o["branch"] { p.branch = (b as? String).flatMap(validBranch); if p.branch == nil { notes.append("\(name(path)): the branch name isn't one; left out.") } }
            if let h = o["head"] { p.head = (h as? String).flatMap(validHead); if p.head == nil { notes.append("\(name(path)): the last commit isn't one; left out.") } }
            if o["unpushed"] != nil { p.unpushed = count(o["unpushed"]); if p.unpushed == nil { notes.append("\(name(path)): the count of commits not pushed isn't a number; left out.") } }
            if o["uncommitted"] != nil { p.uncommitted = count(o["uncommitted"]); if p.uncommitted == nil { notes.append("\(name(path)): the count of files not committed isn't a number; left out.") } }
            if let n = o["note"] as? String { let c = oneLine(n, max: 120); if !c.isEmpty { p.note = c } }
            if let ws = o["worktrees"] as? [Any] {
                var wts: [Worktree] = []
                for w in ws.prefix(maxWorktrees) {
                    guard let wo = w as? [String: Any], let wp = (wo["path"] as? String).flatMap(validPath) else { continue }
                    wts.append(Worktree(path: wp, branch: (wo["branch"] as? String).flatMap(validBranch), head: (wo["head"] as? String).flatMap(validHead),
                                        unpushed: count(wo["unpushed"]), uncommitted: count(wo["uncommitted"])))
                }
                if !wts.isEmpty { p.worktrees = wts }
            }
            projects.append(p)
        }
        return File(created: created, git: gitWhy, projects: projects, notes: notes.isEmpty ? nil : notes)
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
        else if let r = p.remote { out.append("git clone \(shellWord(r)) \(path)"); out.append("cd \(path)") }
        else { return [] }
        if let b = p.branch { out.append("git checkout \(shellWord(b))") }
        return out
    }

    /// The Export page's warnings: "garden-app: 3 commits not pushed: push them before you move".
    static func warnings(_ f: File) -> [String] {
        var out: [String] = []
        for p in f.projects {
            let n = name(p.path)
            if let k = p.unpushed, k > 0 { out.append("\(n): \(k) \(k == 1 ? "commit" : "commits") not pushed: push \(k == 1 ? "it" : "them") before you move") }
            else if p.git, p.unpushed == nil, p.branch != nil { out.append("\(n): its branch \(p.branch!) has no upstream: push it before you move") }
            if let k = p.uncommitted, k > 0 { out.append("\(n): \(k) \(k == 1 ? "file" : "files") not committed: commit and push before you move, or copy \(k == 1 ? "it" : "them") by hand") }
            if p.git, p.remote == nil { out.append("\(n): no remote to clone it from: copy the folder by hand") }
            if !p.git, p.note == "not a git repo" { out.append("\(n): not a git repo: copy the folder by hand") }
            for w in p.worktrees ?? [] {
                let wn = name(w.path)
                if let k = w.unpushed, k > 0 { out.append("\(n), worktree \(wn): \(k) \(k == 1 ? "commit" : "commits") not pushed: push \(k == 1 ? "it" : "them") before you move") }
                else if w.unpushed == nil, let b = w.branch { out.append("\(n), worktree \(wn): its branch \(b) has no upstream: push it before you move") }
                if let k = w.uncommitted, k > 0 { out.append("\(n), worktree \(wn): \(k) \(k == 1 ? "file" : "files") not committed: commit and push before you move") }
            }
        }
        return out
    }

    /// The Import page's lines for one project: what to fetch, and what the old Mac had that a clone won't.
    static func lines(_ p: Project, here: Bool) -> [String] {
        var out: [String] = []
        if p.git {
            var what = here ? "On this Mac at \(p.path)" : (p.remote.map { "Clone \($0) at \(p.path)" } ?? "Was at \(p.path), with no remote to clone it from: copy it by hand")
            if let b = p.branch { what += ", branch \(b)" + (p.head.map { " (\($0))" } ?? "") } else if let h = p.head { what += ", at \(h)" }
            out.append(what)
            if let k = p.unpushed, k > 0 { out.append("\(k) \(k == 1 ? "commit wasn't" : "commits weren't") pushed on the old Mac: a clone won't have \(k == 1 ? "it" : "them") until \(k == 1 ? "it is" : "they are") pushed there") }
            if p.unpushed == nil, p.branch != nil { out.append("Its branch had no upstream on the old Mac: push it there first, or it won't be in a clone") }
            if let k = p.uncommitted, k > 0 { out.append("\(k) \(k == 1 ? "file wasn't" : "files weren't") committed on the old Mac: copy \(k == 1 ? "it" : "them") by hand, or commit and push there") }
            for w in p.worktrees ?? [] {
                var s = "Worktree \(name(w.path))" + (w.branch.map { " on \($0)" } ?? "")
                var bad: [String] = []
                if let k = w.unpushed, k > 0 { bad.append("\(k) not pushed") } else if w.unpushed == nil, w.branch != nil { bad.append("no upstream") }
                if let k = w.uncommitted, k > 0 { bad.append("\(k) \(k == 1 ? "file" : "files") not committed") }
                s += bad.isEmpty ? ": all pushed" : ": " + bad.joined(separator: ", ")
                out.append(s + ". The session runs in the project folder unless the worktree is made again")
            }
        } else {
            out.append("\(p.path): " + (p.note ?? "not a git repo") + (p.note == "not a git repo" || p.note == nil ? ": copy the folder from the old Mac" : ""))
        }
        return out
    }
}
