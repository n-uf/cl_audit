// SessionsSideApply: an import writing a moved session's side files (SessionsSide.swift), and Undo taking them back.
//
// After the import's restore (and the re-point of any session whose folder was picked), each session the file carries side files for
// gets them, from the imported backup's stash (<backup>/side/), create-only:
//   - its task list, plan and Rewind backups, and the pasted texts its history names (a name that is there already with the same bytes
//     counts as there; with other bytes it is left as it is and said);
//   - its prompt-history lines, each `project` set to the folder the session resolves to on this Mac, appended to history.jsonl under
//     Claude Code's own lock folder, and its folder's trust and allowed tools (and the MCP servers when added) as a new key in
//     .claude.json's `projects`, spliced in under Claude Code's lock. Both only while no Claude Code process runs for this profile's
//     folder and its Claude window is closed, and only for a folder that is on this Mac. A session whose folder isn't here keeps its
//     lines and trust in this receipt and gets them when its folder is picked (Sessions ▸ Folder not here, or the import's Pick).
//
// The receipt (sides/<id>/receipt.json, its copies in saved/) is written before and after each step. Undo takes back exactly this: a
// file only while it is the bytes written, the history lines only those still byte for byte as appended (wherever they are in the file),
// the trust key only while it is still the entry written; what changed since stays and is said.

import Foundation

extension SideFiles {
    struct SideError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

    struct Step: Codable, Equatable {
        enum Kind: String, Codable { case made, dir, lines, trust }
        var kind: Kind
        var session: String
        var path: String                                // made, dir: the file or folder; lines: history.jsonl; trust: .claude.json
        var sha: String? = nil                          // made: what was written
        var saved: String? = nil                        // lines: the lines appended (a file in saved/); trust: the copy of .claude.json as it was
        var key: String? = nil                          // trust: the folder added to projects
        var value: String? = nil                        // trust: the entry as written (JSON text)
        var count = 0                                   // lines: how many
        var done = false
        var settled = false
    }

    /// A session whose folder isn't on this Mac yet: its history lines (a copy in saved/) and trust wait for its folder.
    struct Waiting: Codable, Equatable {
        var session: String
        var title: String?
        var from: String                                // its folder on the old Mac
        var history: String?                            // saved/<name>: its lines as carried
        var historyLines = 0
        var trust: [Trust] = []
        var mcp = false                                 // the MCP servers were added
        var why: String
    }

    struct Written: Codable, Equatable {
        var tasks = 0                                   // task files
        var plans = 0
        var historyLines = 0
        var pastes = 0
        var trust = 0                                   // folders whose trust was written
        var mcp = 0                                     // of them, with their MCP servers
        var rewind = 0                                  // Rewind backups
        var there = 0                                   // there already with the same bytes
        var kept = 0                                    // there with other bytes, or an entry already there: left as it is
    }

    struct Receipt: Codable, Equatable {
        var id: String
        var profile: String
        var codeDir: String
        var dataDir: String
        var restore: String?                            // the import's restore receipt it follows (its Undo takes this back first)
        var started: Date
        var finished: Date?
        var undone: Date?
        var kinds: Kinds
        var written = Written()
        var problems: [String] = []
        var steps: [Step] = []
        var waiting: [Waiting] = []
        var left: [String] = []                         // what Undo left, and why
    }

    // MARK: seams for the checks

    /// Whether a Claude Code process runs for this Claude Code folder (nil: it couldn't be told, so nothing shared is written).
    nonisolated(unsafe) static var codeRunning: (String) -> Bool? = { codeDir in processRuns(codeDir: codeDir) }

    /// Claude Code processes of this user whose Claude Code folder is `codeDir` (CLAUDE_CONFIG_DIR, or ~/.claude when it isn't set):
    /// their arguments and environment, read from the kernel. The Claude app itself isn't one; the Claude Code it starts is.
    static func processRuns(codeDir: String) -> Bool? {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return nil }
        let me = getpid(), uid = getuid()
        let want = FolderKey.canonical(codeDir)
        let std = FolderKey.canonical(NSHomeDirectory() + "/.claude")
        for pid in pids.prefix(Int(got)) where pid > 0 && pid != me {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0, info.pbi_uid == uid else { continue }
            guard let (exe, args, env) = procArgs(pid) else { continue }
            let name = (exe as NSString).lastPathComponent.lowercased()
            let codeLike = (name == "claude" || name == "claude.exe" || exe.contains("/claude-code/") || args.contains { $0.hasSuffix("/claude") || $0.contains("@anthropic-ai/claude-code") })
            guard codeLike, !exe.contains(".app/Contents/MacOS/"), !exe.contains(".app/Contents/Frameworks/") else { continue }
            let dir = env.first { $0.hasPrefix("CLAUDE_CONFIG_DIR=") }.map { String($0.dropFirst("CLAUDE_CONFIG_DIR=".count)) }
            let key = dir.map { FolderKey.canonical(expand($0)) } ?? std
            if key == want { return true }
        }
        return false
    }

    /// A process's executable path, arguments and environment (KERN_PROCARGS2), or nil.
    static func procArgs(_ pid: pid_t) -> (String, [String], [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size, size < 4 << 20 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        let s0 = i
        while i < size && buf[i] != 0 { i += 1 }
        let exe = String(decoding: buf[s0..<i], as: UTF8.self)
        while i < size && buf[i] == 0 { i += 1 }
        var strings: [String] = []
        while i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            if i == start { break }
            strings.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        let args = Array(strings.prefix(argc))
        let env = Array(strings.dropFirst(argc))
        return (exe, args, env)
    }

    // MARK: the receipt

    private static func dir(_ id: String) -> URL { root.appendingPathComponent(id) }
    private static func savedDir(_ id: String) -> URL { dir(id).appendingPathComponent("saved") }

    static func save(_ r: Receipt) throws {
        let d = dir(r.id)
        try FileManager.default.createDirectory(at: d.appendingPathComponent("saved"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(r).write(to: d.appendingPathComponent("receipt.json"), options: .atomic)
    }

    static func load(_ id: String) -> Receipt? {
        guard SessionsRestore.validReceiptID(id) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = readCapped(dir(id).appendingPathComponent("receipt.json").path, limit: 64 << 20), let r = try? dec.decode(Receipt.self, from: d), r.id == id else { return nil }
        return r
    }

    static func receipts() -> [Receipt] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(SessionsRestore.validReceiptID).compactMap(load).sorted { $0.started > $1.started }
    }

    static func linked(restore id: String) -> [Receipt] { receipts().filter { $0.restore == id && $0.undone == nil } }

    /// The sessions of a profile whose history or trust waits for a folder.
    static func waiting(profile: String) -> [Waiting] { receipts().filter { $0.profile == profile && $0.undone == nil }.flatMap(\.waiting) }

    /// A small file in the receipt's folder: never over one, never through a link.
    private static func writeSaved(_ d: Data, id: String, name: String) throws {
        let fd = open(savedDir(id).appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SideError("cl_audit's receipt folder can't be written (\(String(cString: strerror(errno)))); nothing more was written.") }
        defer { close(fd) }
        let ok = d.isEmpty || d.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) == d.count }
        guard ok, fsync(fd) == 0 else { throw SideError("cl_audit's receipt folder can't be written; nothing more was written.") }
    }

    // MARK: writing files (create-only)

    enum Put { case created(String), there, differs, failed(String) }

    /// A new file `name` in `dir` (a descriptor), a copy of `src` checked against `sha` and `bytes` as it is read: a temp name linked into
    /// place, never over a name that is there (one with the same bytes counts as there), with `mode`, and the time now (Claude Code's
    /// clean-up goes by a file's age).
    static func putFile(_ dir: Int32, _ name: String, from src: String, bytes: Int64, sha: String, mode: mode_t) -> Put {
        let fd = open(src, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return .failed("its copy in the backup is gone") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int64(st.st_size) == bytes, SessionsRestore.sha(fd: fd) == sha else { return .failed("its copy in the backup isn't what the file said") }
        var x = stat()
        if fstatat(dir, name, &x, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (x.st_mode & S_IFMT) == S_IFREG else { return .differs }
            let e = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard e >= 0 else { return .differs }
            defer { close(e) }
            return SessionsRestore.sha(fd: e) == sha ? .there : .differs
        }
        let tmp = ".side-\(UUID().uuidString.prefix(8)).tmp"
        let out = openat(dir, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard out >= 0 else { return .failed(String(cString: strerror(errno))) }
        defer { unlinkat(dir, tmp, 0) }
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var off: off_t = 0
        var ok = true
        while off < off_t(bytes) {
            let n = pread(fd, &buf, buf.count, off)
            if n <= 0 { ok = false; break }
            if buf.withUnsafeBytes({ Darwin.write(out, $0.baseAddress, n) }) != n { ok = false; break }
            off += off_t(n)
        }
        if ok { ok = fsync(out) == 0 && fchmod(out, mode) == 0 }
        close(out)
        guard ok, off == off_t(bytes) else { return .failed("it couldn't be written whole (the disk may be full)") }
        guard linkat(dir, tmp, dir, name, 0) == 0 else { return errno == EEXIST ? .differs : .failed(String(cString: strerror(errno))) }
        return .created(sha)
    }

    static func unlinkIfSame(_ path: String, sha: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent, leaf = (path as NSString).lastPathComponent
        let pfd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard pfd >= 0 else { return false }
        defer { close(pfd) }
        let fd = openat(pfd, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return false }
        var a = stat(), b = stat()
        let same = fstat(fd, &a) == 0 && (a.st_mode & S_IFMT) == S_IFREG && a.st_nlink == 1 && SessionsRestore.sha(fd: fd) == sha
        close(fd)
        guard same, fstatat(pfd, leaf, &b, AT_SYMLINK_NOFOLLOW) == 0, a.st_ino == b.st_ino, a.st_dev == b.st_dev else { return false }
        return unlinkat(pfd, leaf, 0) == 0
    }

    // MARK: Claude Code's lock (proper-lockfile: a folder beside the file)

    /// Runs `body` holding Claude Code's lock folder for a file. A lock folder that is there means Claude Code (or another writer) holds
    /// it: nothing is written, and that is said.
    static func withLock<T>(_ lockPath: String, what: String, _ body: () throws -> T) throws -> T {
        guard mkdir(lockPath, 0o700) == 0 else {
            throw SideError(errno == EEXIST ? "\(what) is locked (Claude Code may be writing it); nothing was written to it." : "\(what)'s lock can't be taken; nothing was written to it.")
        }
        defer { rmdir(lockPath) }
        return try body()
    }

    /// The lock folder of history.jsonl as Claude Code names it: its real path and ".lock".
    static func historyLock(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        guard let r = realpath(parent, nil) else { return path + ".lock" }
        defer { free(r) }
        return (String(cString: r) as NSString).appendingPathComponent((path as NSString).lastPathComponent) + ".lock"
    }

    /// A plain file read whole under a cap, never through a link: (bytes, its stat).
    static func readPlain(_ path: String, limit: Int64) -> (Data, stat)? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, Int64(st.st_size) <= limit, let d = SessionsRestore.read(fd, size: st.st_size) else { return nil }
        return (d, st)
    }

    /// A file replaced as Claude Code replaces it: a temp file beside it with its mode, fsync, renamed over it; only while the file is still
    /// the one read (`st`).
    static func replaceFile(_ path: String, with data: Data, was st: stat) throws {
        let parent = (path as NSString).deletingLastPathComponent, leaf = (path as NSString).lastPathComponent
        let pfd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard pfd >= 0 else { throw SideError("\(leaf)'s folder can't be opened; it wasn't changed.") }
        defer { close(pfd) }
        let tmp = "\(leaf).tmp.\(getpid()).\(UUID().uuidString.prefix(12).lowercased())"
        let out = openat(pfd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, st.st_mode & 0o777)
        guard out >= 0 else { throw SideError("\(leaf) couldn't be written; it wasn't changed.") }
        var ok = data.isEmpty || data.withUnsafeBytes { Darwin.write(out, $0.baseAddress, $0.count) == data.count }
        if ok { ok = fchmod(out, st.st_mode & 0o777) == 0 && fsync(out) == 0 }
        close(out)
        var now = stat()
        let same = fstatat(pfd, leaf, &now, AT_SYMLINK_NOFOLLOW) == 0 && now.st_ino == st.st_ino && now.st_dev == st.st_dev && now.st_size == st.st_size
            && now.st_mtimespec.tv_sec == st.st_mtimespec.tv_sec && now.st_mtimespec.tv_nsec == st.st_mtimespec.tv_nsec
        guard ok, same, renameat(pfd, tmp, pfd, leaf) == 0 else {
            unlinkat(pfd, tmp, 0)
            throw SideError(same ? "\(leaf) couldn't be written; it wasn't changed." : "\(leaf) changed while it was being written; it wasn't changed.")
        }
    }

    // MARK: .claude.json: one project key spliced in, every other byte as it was

    /// The project entry as Claude Code makes one (its defaults: allowedTools, mcpContextUris, mcpServers, enabledMcpjsonServers,
    /// disabledMcpjsonServers, hasTrustDialogAccepted, hasClaudeMdExternalIncludesApproved, hasClaudeMdExternalIncludesWarningShown), with
    /// the carried trust, allowed tools and (when added) MCP servers.
    static func entryJSON(_ t: Trust, mcp: Bool) -> String? {
        var e: [String: Any] = ["allowedTools": t.allowedTools, "mcpContextUris": [String](), "mcpServers": [String: Any](), "enabledMcpjsonServers": [String](),
                                "disabledMcpjsonServers": [String](), "hasTrustDialogAccepted": t.trusted, "hasClaudeMdExternalIncludesApproved": false,
                                "hasClaudeMdExternalIncludesWarningShown": false]
        if mcp, let m = t.mcp, let j = (try? JSONSerialization.jsonObject(with: Data(m.utf8))) as? [String: Any] {
            if let s = j["mcpServers"] as? [String: Any] { e["mcpServers"] = s }
            if let s = j["enabledMcpjsonServers"] as? [String] { e["enabledMcpjsonServers"] = s }
            if let s = j["disabledMcpjsonServers"] as? [String] { e["disabledMcpjsonServers"] = s }
        }
        guard let d = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys, .withoutEscapingSlashes]), d.count <= maxEntry + (64 << 10) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    enum Splice: Equatable { case added(Data), there, unreadable(String) }

    /// The config's bytes with `"key": value` added to its `projects` object (made when it has none), every other byte as it was.
    static func spliced(_ b: [UInt8], key: String, value: String) -> Splice {
        guard let members = EntryConnections.top(b) else { return .unreadable("it isn't a JSON object cl_audit can read") }
        guard let k = SessionsRepoint.jsonString(key) else { return .unreadable("the folder's name can't be written") }
        let pair = k + Array(": ".utf8) + Array(value.utf8)
        let proj = members.filter { $0.key == "projects" }
        guard proj.count <= 1 else { return .unreadable("it names projects twice") }
        var out: [UInt8]
        if let p = proj.first {
            let sub = Array(b[p.value..<p.end])
            guard let inner = EntryConnections.top(sub) else { return .unreadable("its projects isn't an object") }
            if inner.contains(where: { $0.key == key }) { return .there }
            if let last = inner.last {
                let sep: [UInt8] = inner.count >= 2 ? Array(sub[inner[0].end..<inner[1].start]) : Array(",\n    ".utf8)
                let at = p.value + last.end
                out = Array(b[0..<at]) + sep + pair + Array(b[at...])
            } else {
                guard let open = sub.firstIndex(of: 0x7B) else { return .unreadable("its projects isn't an object") }
                let at = p.value + open + 1
                out = Array(b[0..<at]) + pair + Array(b[at...])
            }
        } else {
            let add = Array("\"projects\": {".utf8) + pair + [0x7D]
            if let last = members.last {
                let sep: [UInt8] = members.count >= 2 ? Array(b[members[0].end..<members[1].start]) : Array(",\n  ".utf8)
                out = Array(b[0..<last.end]) + sep + add + Array(b[last.end...])
            } else {
                guard let open = b.firstIndex(of: 0x7B) else { return .unreadable("it isn't a JSON object") }
                out = Array(b[0...open]) + add + Array(b[(open + 1)...])
            }
        }
        // what came out: the same document with that one key more
        guard let before = (try? JSONSerialization.jsonObject(with: Data(b))) as? NSDictionary,
              let after = (try? JSONSerialization.jsonObject(with: Data(out))) as? NSDictionary,
              let v = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? NSDictionary,
              let ap = after["projects"] as? NSDictionary, (ap[key] as? NSDictionary) == v else { return .unreadable("the result didn't read back") }
        let m1 = before.mutableCopy() as! NSMutableDictionary, m2 = after.mutableCopy() as! NSMutableDictionary
        let bp = (before["projects"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary ?? NSMutableDictionary()
        let cp = ap.mutableCopy() as! NSMutableDictionary
        cp.removeObject(forKey: key)
        if before["projects"] != nil { m1["projects"] = bp } else { m1.removeObject(forKey: "projects"); if cp.count == 0 { m2.removeObject(forKey: "projects") } }
        if before["projects"] != nil { m2["projects"] = cp }
        guard m1 == m2 else { return .unreadable("the result didn't read back") }
        return .added(Data(out))
    }

    /// The config's bytes without the project `key`, when its entry is still `value` (as JSON); nil: not there or changed since.
    static func unspliced(_ b: [UInt8], key: String, value: String) -> Data? {
        guard let members = EntryConnections.top(b), let p = members.first(where: { $0.key == "projects" }), members.filter({ $0.key == "projects" }).count == 1 else { return nil }
        let sub = Array(b[p.value..<p.end])
        guard let inner = EntryConnections.top(sub), inner.filter({ $0.key == key }).count == 1, let i = inner.firstIndex(where: { $0.key == key }) else { return nil }
        let m = inner[i]
        guard let have = try? JSONSerialization.jsonObject(with: Data(sub[m.value..<m.end])) as? NSDictionary,
              let want = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? NSDictionary, have == want else { return nil }
        let from: Int, to: Int
        if i > 0 { from = inner[i - 1].end; to = m.end }
        else if inner.count > 1 { from = m.start; to = inner[1].start }
        else { from = m.start; to = m.end }
        let out = Array(b[0..<(p.value + from)]) + Array(b[(p.value + to)...])
        guard (try? JSONSerialization.jsonObject(with: Data(out))) is [String: Any] else { return nil }
        return Data(out)
    }

    // MARK: history.jsonl: lines appended, lines taken out

    /// The session's carried lines as they go in here: each a JSON object naming this session, `project` set by `project`. Lines that
    /// aren't are dropped and counted.
    static func historyLines(_ data: Data, session: String, project: (String?) -> String) -> (lines: [Data], dropped: Int) {
        var out: [Data] = []
        var dropped = 0
        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let d = Data(raw)
            guard d.count <= maxHistoryLine, let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  (j["sessionId"] as? String)?.lowercased() == session, j["display"] is String else { dropped += 1; continue }
            let old = j["project"] as? String
            guard let n = SessionsRepoint.edited(d, set: [("project", project(old))], drop: []) else { dropped += 1; continue }
            out.append(n)
        }
        return (out, dropped)
    }

    /// Appends `lines` to history.jsonl the way Claude Code does (made 0600 when missing, its lock folder held, one write). Returns the
    /// lines as written (a newline is put first when the file doesn't end with one).
    static func appendHistory(_ path: String, lines: [Data]) throws {
        var st = stat()
        if lstat(path, &st) != 0 {
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw SideError("history.jsonl couldn't be made; no prompt history was added.") }
            close(fd)
        } else {
            guard (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else { throw SideError("history.jsonl is a link or isn't a plain file; no prompt history was added.") }
        }
        try withLock(historyLock(path), what: "history.jsonl") {
            let fd = open(path, O_RDWR | O_APPEND | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw SideError("history.jsonl can't be opened; no prompt history was added.") }
            defer { close(fd) }
            var s = stat()
            guard fstat(fd, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG, s.st_nlink == 1 else { throw SideError("history.jsonl isn't a plain file; no prompt history was added.") }
            var body = Data()
            if s.st_size > 0 {
                var last: UInt8 = 0
                if pread(fd, &last, 1, s.st_size - 1) == 1, last != 0x0A { body.append(0x0A) }
            }
            for l in lines { body += l; body.append(0x0A) }
            let ok = body.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) == body.count }
            guard ok, fsync(fd) == 0 else { throw SideError("history.jsonl couldn't be written whole; Undo takes back what landed.") }
        }
    }

    /// Takes `lines` out of history.jsonl (each one only where a line is byte for byte the same; the first such one), under Claude Code's
    /// lock, by a temp file renamed over it. Returns how many weren't found.
    static func removeHistory(_ path: String, lines: [Data]) throws -> Int {
        try withLock(historyLock(path), what: "history.jsonl") {
            guard let (d, st) = readPlain(path, limit: maxHistoryFile) else { throw SideError("history.jsonl can't be read (a link, or over \(SessionsBackup.sizeWords(maxHistoryFile))); its lines stay.") }
            var want: [Data: Int] = [:]
            for l in lines { want[l, default: 0] += 1 }
            var out = Data(); out.reserveCapacity(d.count)
            var removed = 0
            var start = d.startIndex
            while start < d.endIndex {
                let nl = d[start...].firstIndex(of: 0x0A)
                let end = nl ?? d.endIndex
                let line = Data(d[start..<end])
                if let n = want[line], n > 0 { want[line] = n - 1; removed += 1 }
                else { out += line; if nl != nil { out.append(0x0A) } }
                start = nl.map { $0 + 1 } ?? d.endIndex
            }
            if removed > 0 { try replaceFile(path, with: out, was: st) }
            return lines.count - removed
        }
    }

    // MARK: applying

    /// What the session's folder is on this Mac: (its folder on the old Mac, its folder here), or nil when it isn't here yet.
    typealias Folder = (from: String, to: String)

    /// Writes the side files the imported backup `b` keeps (nil: it keeps none). `folders`: the sessions re-pointed just now (session →
    /// old folder, picked folder); the others resolve to their recorded folder when it is here, else they wait.
    static func apply(_ t: SessionsRestore.Target, _ b: SessionsRestore.Backup, kinds: Kinds, restore: String?, folders: [String: Folder] = [:],
                      windowClosed: () -> Bool, now: Date = Date()) throws -> Receipt? {
        guard let part = stashed(b), !part.sessions.isEmpty || !part.trust.isEmpty else { return nil }
        guard kinds != .nothing else { return nil }
        let lock: SwitchEngine.Lock
        do { lock = try SwitchEngine.Lock.take() } catch { throw SideError("\(error)") }
        defer { lock.release() }
        var r = Receipt(id: SessionsRestore.receiptID(now, t.profile) + "-side", profile: t.profile, codeDir: t.codeDir, dataDir: t.dataDir, restore: restore, started: now, kinds: kinds)
        try save(r)
        let projects = (t.codeDir as NSString).appendingPathComponent("projects")
        guard let tree = SessionsRestore.Tree(path: t.codeDir) else { throw SideError("\(tilde(t.codeDir)) can't be opened; no side files were written.") }
        let byCli = SessionsRepoint.entries(dataDir: t.dataDir)
        var lines: [(session: String, data: Data)] = []
        var trustAdd: [(session: String, key: String, value: String, mcp: Bool)] = []
        for s in part.sessions {
            let label = s.title.map { "“\($0)”" } ?? "Session \(s.id.prefix(8))"
            guard let found = SessionsRepoint.locate(s.id, projects: projects) else {
                if !(s.tasks.isEmpty && s.plan == nil && s.history == nil && s.rewind.isEmpty) { r.problems.append("\(label): its conversation isn't in this profile, so its side files weren't written.") }
                continue
            }
            // its own files: task list, plan, Rewind backups, pasted texts
            func write(_ comps: [String], _ it: Item, mode: mode_t = 0o600, count: (inout Written) -> Void) {
                let path = (t.codeDir as NSString).appendingPathComponent((comps + [it.name]).joined(separator: "/"))
                tree.willMake = { p in r.steps.append(Step(kind: .dir, session: s.id, path: p)); try? save(r) }
                tree.madeFailed = { p in if let i = r.steps.lastIndex(where: { $0.kind == .dir && $0.path == p && !$0.done }) { r.steps.remove(at: i); try? save(r) } }
                let made = tree.dir(comps, create: true)
                tree.willMake = nil; tree.madeFailed = nil
                for i in r.steps.indices where r.steps[i].kind == .dir && !r.steps[i].done && tree.made.contains(r.steps[i].path) { r.steps[i].done = true }
                guard case .dir(let fd) = made else { r.problems.append("\(label): \(tilde((t.codeDir as NSString).appendingPathComponent(comps.joined(separator: "/")))) is a link or can't be made; \(it.name) wasn't written."); return }
                defer { close(fd) }
                r.steps.append(Step(kind: .made, session: s.id, path: path, sha: it.sha)); try? save(r)
                let i = r.steps.count - 1
                switch putFile(fd, it.name, from: stashPath(b, it), bytes: it.bytes, sha: it.sha, mode: mode) {
                case .created: r.steps[i].done = true; count(&r.written)
                case .there: r.steps.remove(at: i); r.written.there += 1
                case .differs: r.steps.remove(at: i); r.written.kept += 1; r.problems.append("\(label): \(tilde(path)) is there already with other content; it was left as it is.")
                case .failed(let why): r.steps.remove(at: i); r.problems.append("\(label): \(it.name) wasn't written (\(why)).")
                }
                try? save(r)
            }
            if kinds.tasks { for it in s.tasks { write(["tasks", s.id], it) { $0.tasks += 1 } } }
            if kinds.plans, let it = s.plan {
                var p = it; p.name = it.name + ".md"
                write(["plans"], p) { $0.plans += 1 }
            }
            if kinds.rewind { for it in s.rewind { write(["file-history", s.id], it, mode: cleanMode(it.mode)) { $0.rewind += 1 } } }
            if kinds.history, s.history != nil { for it in s.pastes { var p = it; p.name = it.name + ".txt"; write(["paste-cache"], p) { $0.pastes += 1 } } }
            // the shared files: history lines and trust, by the folder the session resolves to here
            let trusts = kinds.trust ? part.trust.filter { $0.session == s.id } : []
            let hasHistory = kinds.history && s.history != nil
            guard hasHistory || !trusts.isEmpty else { continue }
            var folder: Folder?
            if let f = folders[s.id] { folder = f }
            else if let now = SessionsRepoint.session(id: s.id, project: found.project, transcript: found.path, entries: byCli[s.id] ?? []), now.here {
                folder = (SessionsRepoint.projectFolder(of: s.cwd), now.folder)
            }
            guard let f = folder else {
                var w = Waiting(session: s.id, title: s.title, from: SessionsRepoint.projectFolder(of: s.cwd), historyLines: s.historyLines, trust: trusts, mcp: kinds.mcp,
                                why: "its folder isn't on this Mac yet")
                if hasHistory, let h = s.history, let d = readCapped(stashPath(b, h), limit: Int(maxHistoryBytes)), SwitchEngine.sha(d) == h.sha {
                    let name = "waiting-\(s.id).jsonl"
                    try writeSaved(d, id: r.id, name: name)
                    w.history = name
                }
                r.waiting.append(w)
                try save(r)
                continue
            }
            if hasHistory, let h = s.history, let d = readCapped(stashPath(b, h), limit: Int(maxHistoryBytes)), SwitchEngine.sha(d) == h.sha {
                let got = historyLines(d, session: s.id, project: projectMap(f))
                if got.dropped > 0 { r.problems.append("\(label): \(got.dropped) prompt history \(got.dropped == 1 ? "line wasn't one of its own, or couldn't be read, and was" : "lines weren't its own, or couldn't be read, and were") left out.") }
                lines += got.lines.map { (s.id, $0) }
            }
            for tr in trusts {
                guard let key = trustKey(tr.key, f) else { r.problems.append("\(label): the trust kept for \(tilde(tr.key)) is for a folder above its project, so it isn't carried over."); continue }
                guard SessionsRepoint.folderHere(key) else { continue }
                guard let v = entryJSON(tr, mcp: kinds.mcp) else { continue }
                if !trustAdd.contains(where: { $0.key == key }) { trustAdd.append((s.id, key, v, kinds.mcp && tr.mcp != nil)) }
            }
        }
        try writeShared(&r, lines: lines, trust: trustAdd, windowClosed: windowClosed)
        r.finished = Date()
        try save(r)
        return r
    }

    /// How a carried history line's `project` becomes this Mac's: inside the old folder → the same place under the new one (when that is a
    /// folder here), anything else → the session's folder here.
    static func projectMap(_ f: Folder) -> (String?) -> String {
        let map = SessionsRepoint.mapper(folder: f.from, picked: f.to, dropped: [])
        return { old in
            guard let o = old, let m = f.from == f.to ? (SessionsRepoint.inside(o, f.from) ? o : nil) : map(o), SessionsRepoint.folderHere(m) else { return f.to }
            return m
        }
    }

    /// A carried trust key on this Mac: inside the old folder → its place under the new one; a folder above the project → nil.
    static func trustKey(_ key: String, _ f: Folder) -> String? {
        guard SessionsRepoint.inside(key, f.from) else { return nil }
        if f.from == f.to { return key }
        return SessionsRepoint.mapper(folder: f.from, picked: f.to, dropped: [])(key)
    }

    /// history.jsonl and .claude.json, under the shared-file rules: no Claude Code process for this folder, the window closed.
    private static func writeShared(_ r: inout Receipt, lines: [(session: String, data: Data)], trust: [(session: String, key: String, value: String, mcp: Bool)],
                                    windowClosed: () -> Bool) throws {
        guard !lines.isEmpty || !trust.isEmpty else { return }
        let why: String? = {
            guard let running = codeRunning(r.codeDir) else { return "it couldn't be checked whether Claude Code runs for this profile" }
            if running { return "Claude Code runs for this profile" }
            if !windowClosed() { return "the profile's Claude window is open" }
            return nil
        }()
        if let why {
            r.problems.append("Prompt history and trust weren't written: \(why). Pick the session's folder again under Sessions (or import again) once it is quit.")
            return
        }
        // the history lines, one append under Claude Code's lock
        if !lines.isEmpty {
            let path = (r.codeDir as NSString).appendingPathComponent("history.jsonl")
            let name = "lines-\(r.steps.count).jsonl"
            var body = Data()
            for l in lines { body += l.data; body.append(0x0A) }
            try writeSaved(body, id: r.id, name: name)
            r.steps.append(Step(kind: .lines, session: Set(lines.map(\.session)).count == 1 ? lines[0].session : "", path: path, sha: SwitchEngine.sha(body), saved: name, count: lines.count))
            try save(r)
            do {
                try appendHistory(path, lines: lines.map(\.data))
                r.steps[r.steps.count - 1].done = true
                r.written.historyLines += lines.count
            } catch {
                r.problems.append("\(error)")
            }
            try save(r)
        }
        // trust: each key spliced into .claude.json under Claude Code's lock
        if !trust.isEmpty {
            let cfg = configFile(codeDir: r.codeDir)
            var st = stat()
            guard lstat(cfg, &st) == 0 else {
                r.problems.append("Trust wasn't written: this profile has no .claude.json yet (Claude Code makes it the first time it runs). Run Claude Code here once, then import again; nothing else changes.")
                return
            }
            guard (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else { r.problems.append("Trust wasn't written: .claude.json is a link or isn't a plain file."); return }
            do {
                try withLock(cfg + ".lock", what: ".claude.json") {
                    guard let (d, rst) = readPlain(cfg, limit: Int64(maxConfig)) else { throw SideError("Trust wasn't written: .claude.json is over \(SessionsBackup.sizeWords(Int64(maxConfig))) or can't be read.") }
                    var bytes = [UInt8](d)
                    var added: [(session: String, key: String, value: String, mcp: Bool)] = []
                    for tr in trust {
                        switch spliced(bytes, key: tr.key, value: tr.value) {
                        case .added(let n): bytes = [UInt8](n); added.append(tr)
                        case .there: r.written.kept += 1; r.problems.append("\(tilde(tr.key)) already has its own entry in .claude.json; it was kept as it is.")
                        case .unreadable(let why): throw SideError("Trust wasn't written: .claude.json \(why).")
                        }
                    }
                    guard !added.isEmpty else { return }
                    let name = "claude-json-\(r.steps.count).copy"
                    try writeSaved(d, id: r.id, name: name)
                    for a in added { r.steps.append(Step(kind: .trust, session: a.session, path: cfg, saved: name, key: a.key, value: a.value)) }
                    try save(r)
                    try replaceFile(cfg, with: Data(bytes), was: rst)
                    // read back: what landed is what was written
                    guard let back = readPlain(cfg, limit: Int64(maxConfig)), back.0 == Data(bytes) else { throw SideError(".claude.json didn't read back as written; Undo takes the trust back if it is still as written.") }
                    for i in r.steps.indices where r.steps[i].kind == .trust && r.steps[i].saved == name { r.steps[i].done = true }
                    r.written.trust += added.count
                    r.written.mcp += added.filter(\.mcp).count
                }
            } catch {
                r.problems.append("\(error)")
            }
            try save(r)
        }
    }

    /// A session picked later (Sessions ▸ Folder not here, or an import's Pick): its waiting history lines and trust are written now, into
    /// the receipt that kept them (so the import's Undo still takes them back). `picked`: session → (old folder, picked folder).
    @discardableResult
    static func applyPending(_ t: SessionsRestore.Target, picked: [String: Folder], windowClosed: () -> Bool) -> [String] {
        var problems: [String] = []
        for var r in receipts() where r.profile == t.profile && r.undone == nil && r.waiting.contains(where: { picked[$0.session] != nil }) {
            var lines: [(session: String, data: Data)] = []
            var trust: [(session: String, key: String, value: String, mcp: Bool)] = []
            var done: [String] = []
            for w in r.waiting {
                guard let f = picked[w.session] else { continue }
                if let h = w.history, let d = readCapped(savedDir(r.id).appendingPathComponent(h).path, limit: Int(maxHistoryBytes)) {
                    lines += historyLines(d, session: w.session, project: projectMap((w.from, f.to))).lines.map { (w.session, $0) }
                }
                for tr in w.trust {
                    guard let key = trustKey(tr.key, (w.from, f.to)), SessionsRepoint.folderHere(key), let v = entryJSON(tr, mcp: w.mcp) else { continue }
                    if !trust.contains(where: { $0.key == key }) { trust.append((w.session, key, v, w.mcp && tr.mcp != nil)) }
                }
                done.append(w.session)
            }
            let before = r.problems.count
            do {
                try writeShared(&r, lines: lines, trust: trust, windowClosed: windowClosed)
                // (written or said: a session whose history couldn't be written keeps waiting)
                if r.problems.count == before { r.waiting.removeAll { done.contains($0.session) } }
                problems += r.problems.suffix(r.problems.count - before)
                try save(r)
            } catch { problems.append("\(error)") }
        }
        return problems
    }

    // MARK: Undo

    /// Takes back exactly what the receipt wrote, newest first: files only while they are the bytes written, the history lines only those
    /// still the same byte for byte, the trust key only while it is still the entry written. History and trust need Claude Code quit for
    /// this profile and its window closed.
    @discardableResult
    static func undo(_ id: String, locked: Bool = false, windowClosed: () -> Bool) throws -> Receipt {
        var lock: SwitchEngine.Lock?
        if !locked { do { lock = try SwitchEngine.Lock.take() } catch { throw SideError("\(error)") } }
        defer { lock?.release() }
        guard var r = load(id) else { throw SideError("No record of those side files.") }
        guard r.undone == nil else { return r }
        let shared = r.steps.contains { ($0.kind == .lines || $0.kind == .trust) && $0.done && !$0.settled }
        if shared {
            guard let running = codeRunning(r.codeDir), !running else { throw SideError("Quit Claude Code for this profile first (prompt history and trust are shared files), then Undo.") }
            guard windowClosed() else { throw SideError("Quit the profile's Claude window first, then Undo.") }
        }
        for i in r.steps.indices.reversed() where !r.steps[i].settled {
            let s = r.steps[i]
            defer { r.steps[i].settled = true; try? save(r) }
            switch s.kind {
            case .made:
                guard let sha = s.sha else { continue }
                var st = stat()
                if lstat(s.path, &st) != 0 { continue }
                if !unlinkIfSame(s.path, sha: sha) { r.left.append("\(tilde(s.path)) changed since; it stays.") }
            case .dir:
                if s.done { rmdir(s.path) }
            case .lines:
                guard let name = s.saved, let d = readCapped(savedDir(r.id).appendingPathComponent(name).path, limit: Int(maxHistoryBytes) + (1 << 20)) else { continue }
                let lines = d.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
                // (an append that wasn't marked done may still have landed: whatever of it is there goes, and only a done one is missed)
                var st = stat()
                if !s.done, lstat(s.path, &st) != 0 { continue }
                do {
                    let missing = try removeHistory(s.path, lines: lines)
                    if missing > 0, s.done { r.left.append("\(missing) of the prompt history \(missing == 1 ? "line" : "lines") added changed or went since; the rest were taken out.") }
                } catch { if s.done { r.left.append("\(error)") } }
            case .trust:
                guard s.done, let key = s.key, let value = s.value else { continue }
                do {
                    try withLock(s.path + ".lock", what: ".claude.json") {
                        guard let (d, st) = readPlain(s.path, limit: Int64(maxConfig)) else { throw SideError(".claude.json can't be read; the trust for \(tilde(key)) stays.") }
                        guard let out = unspliced([UInt8](d), key: key, value: value) else { r.left.append("The trust for \(tilde(key)) changed since (or went); it stays."); return }
                        try replaceFile(s.path, with: out, was: st)
                    }
                } catch { r.left.append("\(error)") }
            }
        }
        r.waiting = []
        r.undone = Date()
        try save(r)
        return r
    }

    /// Undo of every side-file receipt that follows an import's restore (the import's Undo does this first).
    static func undoLinked(restore id: String, windowClosed: () -> Bool) throws -> [String] {
        var left: [String] = []
        for r in linked(restore: id) { left += try undo(r.id, locked: true, windowClosed: windowClosed).left }
        return left
    }

    /// Whether Undo of the import needs the window (shared files were written).
    static func touchesShared(restore id: String) -> Bool {
        linked(restore: id).contains { $0.steps.contains { ($0.kind == .lines || $0.kind == .trust) && $0.done && !$0.settled } }
    }
}

// MARK: - the pages' words

enum SideWords {
    static func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }
    static func size(_ b: Int64) -> String { SessionsBackup.sizeWords(b) }

    /// Export: "2 task lists · 1 plan · 41 prompt history lines (2 pasted texts) · trust for 2 folders"
    static func carried(_ p: SideFiles.Preview, kinds: SideFiles.Kinds) -> String {
        var parts: [String] = []
        if kinds.tasks, p.taskLists > 0 { parts.append(n(p.taskLists, "task list", "task lists")) }
        if kinds.plans, p.plans > 0 { parts.append(n(p.plans, "plan", "plans")) }
        if kinds.history, p.historyLines > 0 { parts.append(n(p.historyLines, "prompt history line", "prompt history lines") + (p.pastes > 0 ? " (\(n(p.pastes, "pasted text", "pasted texts")))" : "")) }
        if kinds.trust, p.trust > 0 { parts.append("trust for " + n(p.trust, "folder", "folders") + (p.mcpServers > 0 ? " (\(n(p.mcpServers, "MCP server", "MCP servers")))" : "")) }
        return parts.isEmpty ? "none" : parts.joined(separator: " · ")
    }

    static func rewind(_ p: SideFiles.Preview, on: Bool) -> String {
        guard p.rewindFiles > 0 else { return "none on this Mac" }
        return (on ? "included: " : "left out: ") + n(p.rewindFiles, "backup", "backups") + ", " + size(p.rewindBytes)
    }

    /// Import: one row's value.
    static func row(_ count: Int, _ one: String, _ many: String, bytes: Int64, on: Bool) -> String {
        n(count, one, many) + " (" + size(bytes) + "): " + (on ? "added with the sessions" : "left out")
    }

    static func written(_ r: SideFiles.Receipt) -> String {
        let w = r.written
        var parts: [String] = []
        if w.tasks > 0 { parts.append(n(w.tasks, "task file", "task files")) }
        if w.plans > 0 { parts.append(n(w.plans, "plan", "plans")) }
        if w.historyLines > 0 { parts.append(n(w.historyLines, "prompt history line", "prompt history lines")) }
        if w.pastes > 0 { parts.append(n(w.pastes, "pasted text", "pasted texts")) }
        if w.trust > 0 { parts.append("trust for " + n(w.trust, "folder", "folders")) }
        if w.rewind > 0 { parts.append(n(w.rewind, "Rewind backup", "Rewind backups")) }
        var s = parts.isEmpty ? "nothing new" : parts.joined(separator: " · ")
        if !r.waiting.isEmpty { s += " · " + n(r.waiting.count, "session waits", "sessions wait") + " for its folder (history and trust are written when you pick it)" }
        return s
    }

    static let notCarried = "Not carried: session environments (hooks write them again, and they hold tokens), the image cache, shell snapshots, debug files and old to-do lists."
}
