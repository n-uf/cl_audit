// SessionsSide: a moved session's side files (stage 2 of the move's resume work). Claude Code keeps more per session than the transcript,
// and a move carries these too, in the move's encrypted disk image only (never a zip, never a backup cl_audit makes):
//
//   task list         <Claude Code folder>/tasks/<session id>/<n>.json and .highwatermark (the task panel)
//   plan              plans/<slug>.md, the slug the transcript's lines name (`slug`, ^[a-z0-9]+(-[a-z0-9]+)*$)
//   prompt history    the session's lines of history.jsonl (`display`, `pastedContents`, `timestamp`, `project`, `sessionId`), and the
//                     paste-cache/<hash>.txt files they name (the hash is the first 16 hex characters of the text's SHA-256)
//   trust             the project's entry in the profile's .claude.json (`projects["<folder>"]`): only hasTrustDialogAccepted and
//                     allowedTools, the two fields Claude Code itself names as the trust part (`["allowedTools","hasTrustDialogAccepted"]`);
//                     its MCP servers (mcpServers, enabledMcpjsonServers, disabledMcpjsonServers) ride along apart and are left out on
//                     Import unless added
//   Rewind            file-history/<session id>/<hash>@v<n>: a row of its own, off in the Move preset (it can be hundreds of MB)
//
// Not carried: session-env (hooks write it again; it holds tokens), image-cache, shell-snapshots, debug files, old todos.
//
// What Claude Code does with these (Claude Code 2.1.318's program text, read with strings, never run):
// - history.jsonl is appended, never sorted: the up-arrow reads it from the end, the lines of the project it runs in (at most 100), so the
//   lines added here come out as the newest. Claude Code appends under a lock: it makes the file (0600) if missing, takes a lock folder
//   `<real path of the file>.lock` (proper-lockfile: mkdir, stale after 10 s), appends the lines, and removes the folder. cl_audit does the
//   same, and gives up (says so) when the folder is there. Its own prune (an age limit, only where an organisation sets one) rewrites the
//   file under the same lock with a temp file renamed over it; Undo here does the same.
// - .claude.json is written whole by Claude Code: a lock folder `<file>.lock` (proper-lockfile, stale after 10 s), the file read again
//   under the lock, a temp file `<file>.tmp.<pid>.<hex>` with the file's mode, fsync, renamed over it. cl_audit takes the same lock, reads
//   it again under the lock, and changes it by splicing: one key added to `projects`, every other byte as it was (other projects, key
//   order, the account block untouched); never through a link; a copy of the file as it was kept in the receipt; read back after.
// - Rewind finds a file's backups by the names the transcript's `file-history-snapshot` lines give (`trackedFileBackups`): a tracked
//   file inside the session's folder is recorded relative to it, one outside (or from an older Claude Code) by its absolute path, and each
//   backup records its folder's real path (`realParentDir`), which Rewind compares before it restores. A Pick re-points those absolute
//   paths too (SessionsRepoint.rewriteRewind), the same create-only, journaled, byte-keeping way as the `cwd` values.
//
// Everything read from the image is untrusted: every name is checked (a session id is a UUID, a slug Claude Code's own pattern, a paste
// hash 16 hex characters and the hash of its text, a backup's name <16 hex>@v<n>, a task file <name>.json), every file's size and SHA-256
// must be what side.json says, every read is capped, a history line must be a JSON object naming its own session, and anything else is
// left out and said. Writes are create-only and journaled (a receipt under sides/<id>), and Undo takes back only what is unchanged since.

import CryptoKit
import Foundation

enum SideFiles {
    static let fileName = "side.json"
    static let dirName = "side"
    static var root: URL { Store.folder.appendingPathComponent("sides") }

    // MARK: caps (each one said on the page when it is hit)

    static let maxManifest = 8 << 20                    // side.json
    static let maxSessions = 2000                       // sessions a part carries side files for
    static let maxTaskFiles = 200                       // task files of one session
    static let maxTaskFile = 1 << 20                    // one task file
    static let maxPlan = 4 << 20                        // one plan
    static let maxHistoryFile: Int64 = 512 << 20        // history.jsonl is read this far, no further
    static let maxHistoryLine = 1 << 20                 // a longer line is left out
    static let maxHistoryLines = 5000                   // lines of one session
    static let maxHistoryBytes: Int64 = 32 << 20        // history lines of a part
    static let maxPaste = 8 << 20                       // one pasted text
    static let maxPastes: Int64 = 64 << 20              // pasted texts of a part
    static let maxRewindFile: Int64 = 48 << 20          // one Rewind backup (under the export's 64 MB check of a file)
    static let maxRewindFiles = 5000                    // Rewind backups of one session
    static let maxRewind: Int64 = 1 << 30               // Rewind backups of a part
    static let maxConfig = 32 << 20                     // .claude.json is read only under this
    static let maxEntry = 256 << 10                     // one carried project entry
    static let maxTools = 1000                          // allowedTools entries of one entry
    static let maxKeys = 8                              // project entries of one session (its folder and the folders above it)

    // MARK: what is carried, and what an import writes

    struct Kinds: Codable, Equatable, Hashable {
        var tasks = true
        var plans = true
        var history = true
        var trust = true
        var mcp = false                                 // a project's MCP servers (an import leaves them out unless added)
        var rewind = false
        static let nothing = Kinds(tasks: false, plans: false, history: false, trust: false, mcp: false, rewind: false)
        /// Export's Move preset: tasks, plan, history, trust (with the MCP servers, in the image) on; Rewind off.
        static let movePreset = Kinds(tasks: true, plans: true, history: true, trust: true, mcp: true, rewind: false)
    }

    // MARK: the format (side.json beside export.json, the files under side/<part>/)

    struct Item: Codable, Equatable {
        var name: String                                // its name in Claude Code's folder (a task file, a slug, a paste hash, a backup's name)
        var file: String                                // where it is in the image: "side/p1/7"
        var bytes: Int64
        var sha: String                                 // SHA-256, hex
        var mode: Int? = nil                            // Rewind: the backup's mode (Rewind restores a file with it)
    }

    struct Session: Codable, Equatable {
        var id: String
        var cwd: String                                 // the folder its transcript names first
        var title: String? = nil
        var tasks: [Item] = []
        var plan: Item? = nil
        var history: Item? = nil                        // its history lines, as they were, one per line
        var historyLines = 0
        var pastes: [Item] = []
        var rewind: [Item] = []
        var rewindFiles = 0                             // on the old Mac (carried or not)
        var rewindBytes: Int64 = 0
    }

    struct Trust: Codable, Equatable {
        var session: String
        var key: String                                 // the folder it was kept for on the old Mac
        var trusted = false                             // hasTrustDialogAccepted
        var allowedTools: [String] = []
        var mcp: String? = nil                          // {"mcpServers":…,"enabledMcpjsonServers":…,"disabledMcpjsonServers":…} as JSON text
        var mcpServers: [String] = []                   // their names
    }

    struct Hit: Codable, Equatable {
        var what: String                                // "the prompt history of “Fix the sign-up form”"
        var kinds: [Secret]
        var kept: Bool
    }

    struct Part: Codable, Equatable {
        var dir: String
        var sessions: [Session] = []
        var trust: [Trust] = []
        var leftOut: [String] = []                      // a cap hit, a file that couldn't be read …: one sentence each
        var hits: [Hit] = []
    }

    struct File: Codable, Equatable {
        var version = 1
        var parts: [Part] = []
    }

    // MARK: names

    static func validID(_ s: String) -> Bool { AccountDiscovery.isUUID(s) && s == s.lowercased() }
    static func validSlug(_ s: String) -> Bool { s.utf8.count <= 128 && s.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil }
    static func validHash(_ s: String) -> Bool { s.range(of: #"^[0-9a-f]{16}$"#, options: .regularExpression) != nil }
    static func validBackupName(_ s: String) -> Bool { s.utf8.count <= 40 && s.range(of: #"^[0-9a-f]{16}@v[1-9][0-9]{0,8}$"#, options: .regularExpression) != nil }
    static func validTaskName(_ s: String) -> Bool {
        s == ".highwatermark" || (s.utf8.count <= 70 && s.range(of: #"^[A-Za-z0-9_-]{1,64}\.json$"#, options: .regularExpression) != nil)
    }
    static func validSha(_ s: String) -> Bool { s.count == 64 && s.allSatisfy { "0123456789abcdef".contains($0) } }
    static func validFile(_ s: String, dir: String) -> Bool { s.range(of: #"^side/\#(dir)/[0-9]{1,6}$"#, options: .regularExpression) != nil }
    /// The paste-cache name Claude Code gives a text: the first 16 hex characters of its SHA-256.
    static func pasteHash(_ d: Data) -> String { String(SwitchEngine.sha(d).prefix(16)) }

    /// A Rewind backup's mode, as cl_audit writes it: the owner's bits and read for others, never setuid, setgid or sticky.
    static func cleanMode(_ m: Int?) -> mode_t {
        guard let m, m >= 0 else { return 0o600 }
        let v = mode_t(m) & 0o755
        return v & 0o600 == 0o600 ? v : 0o600
    }

    // MARK: Claude Code's files of a profile

    /// The profile's .claude.json: in its Claude Code folder (CLAUDE_CONFIG_DIR), or beside it in the home folder for ~/.claude.
    static func configFile(codeDir: String) -> String {
        let inside = (codeDir as NSString).appendingPathComponent(".claude.json")
        var st = stat()
        if lstat(inside, &st) == 0 { return inside }
        let std = FolderKey.canonical(NSHomeDirectory() + "/.claude")
        return FolderKey.canonical(codeDir) == std ? NSHomeDirectory() + "/.claude.json" : inside
    }

    static func readCapped(_ path: String, limit: Int) -> Data? { SessionsRepoint.readCapped(path, limit: limit) }

    /// The plain files directly in a folder (never through a link), with their sizes.
    static func plainFiles(_ dir: String) -> [(name: String, bytes: Int64)]? {
        let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0, let d = fdopendir(fd) else { if fd >= 0 { close(fd) }; return nil }
        defer { closedir(d) }
        var out: [(name: String, bytes: Int64)] = []
        while let ent = readdir(d) {
            let n = withUnsafeBytes(of: ent.pointee.d_name) { String(decoding: $0.prefix(Int(ent.pointee.d_namlen)), as: UTF8.self) }
            if n == "." || n == ".." { continue }
            var st = stat()
            guard fstatat(dirfd(d), n, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else { continue }
            out.append((n, Int64(st.st_size)))
            if out.count > 100_000 { break }
        }
        return out.sorted { $0.name < $1.name }
    }

    /// The last plan slug a transcript names (Claude Code takes the last valid one), read in 1 MB steps up to 2 GB.
    static func slug(inTranscript path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let needle = Array("\"slug\":\"".utf8)
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var carry: [UInt8] = []
        var off: off_t = 0
        var found: String?
        while off < off_t(SessionsRepoint.maxTranscript) {
            let n = pread(fd, &buf, buf.count, off)
            if n <= 0 { break }
            off += off_t(n)
            let chunk = carry + buf[0..<n]
            var i = 0
            while i + needle.count <= chunk.count {
                guard let at = chunk[i...].firstRange(of: needle) else { break }
                var j = at.upperBound
                var s: [UInt8] = []
                while j < chunk.count, chunk[j] != 0x22, s.count <= 128 { s.append(chunk[j]); j += 1 }
                if j < chunk.count, chunk[j] == 0x22 {
                    let v = String(decoding: s, as: UTF8.self)
                    if validSlug(v) { found = v }
                }
                i = at.upperBound
            }
            carry = Array(chunk.suffix(160))
        }
        return found
    }

    // MARK: export: gathering (also the preview, which writes nothing)

    struct Preview: Equatable {
        var sessions = 0                                // sessions with any side file
        var taskLists = 0
        var taskBytes: Int64 = 0
        var plans = 0
        var planBytes: Int64 = 0
        var historyLines = 0
        var historyBytes: Int64 = 0
        var pastes = 0
        var pasteBytes: Int64 = 0
        var trust = 0                                   // project entries (folders)
        var mcpServers = 0
        var rewindFiles = 0                             // on this Mac
        var rewindBytes: Int64 = 0
        var rewindCarried = false
        var hits: [Hit] = []
        var leftOut: [String] = []
        var configNote: String?                          // why trust isn't read (no .claude.json, too big, a link …)
        var isEmpty: Bool { sessions == 0 && trust == 0 }
        mutating func add(_ o: Preview) {
            sessions += o.sessions; taskLists += o.taskLists; taskBytes += o.taskBytes; plans += o.plans; planBytes += o.planBytes
            historyLines += o.historyLines; historyBytes += o.historyBytes; pastes += o.pastes; pasteBytes += o.pasteBytes
            trust += o.trust; mcpServers += o.mcpServers; rewindFiles += o.rewindFiles; rewindBytes += o.rewindBytes
            rewindCarried = rewindCarried || o.rewindCarried; hits += o.hits; leftOut += o.leftOut; if configNote == nil { configNote = o.configNote }
        }
    }

    struct SessionRef: Equatable {
        var id: String
        var cwd: String
        var transcript: String
        var title: String? = nil
    }

    /// The sessions of a profile's Claude Code folder (projects/*/<id>.jsonl), with the folder each names: what a preview counts.
    static func sessions(codeDir: String) -> [SessionRef] {
        let projects = (codeDir as NSString).appendingPathComponent("projects")
        return sessions(projectsDir: projects)
    }

    /// The sessions under a folder laid out like projects/ (a profile's, or an export part's transcripts/).
    static func sessions(projectsDir: String) -> [SessionRef] {
        let fm = FileManager.default
        var out: [SessionRef] = []
        for p in ((try? fm.contentsOfDirectory(atPath: projectsDir)) ?? []).sorted() where SessionsRestore.plainName(p) && !p.hasPrefix(".") {
            let dir = (projectsDir as NSString).appendingPathComponent(p)
            var st = stat()
            guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            for leaf in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where leaf.hasSuffix(".jsonl") {
                let id = String(leaf.dropLast(6)).lowercased()
                guard validID(id), !out.contains(where: { $0.id == id }) else { continue }
                let path = (dir as NSString).appendingPathComponent(leaf)
                guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, let cwd = SessionsRepoint.recordedCwd(path) else { continue }
                out.append(SessionRef(id: id, cwd: cwd, transcript: path))
                if out.count >= maxSessions { return out }
            }
        }
        return out
    }

    /// Reads the side files of `sessions` from the Claude Code folder `codeDir`; with `out`, writes the carried ones under out/side/<dir>/
    /// and returns the part for side.json. `keys`: a file (or history line) with a key in it is left out, unless kept. Nothing in the
    /// Claude Code folder is ever written.
    static func gather(codeDir: String, sessions refs: [SessionRef], kinds: Kinds, keys: SessionsExport.Keys, dir: String, out: URL?,
                       cancel: () -> Bool = { false }) -> (part: Part, preview: Preview)? {
        var part = Part(dir: dir)
        var pv = Preview()
        pv.rewindCarried = kinds.rewind
        var seq = 0
        var historyTotal: Int64 = 0, pasteTotal: Int64 = 0, rewindTotal: Int64 = 0
        let sideDir = out?.appendingPathComponent("\(dirName)/\(dir)")
        if let sideDir { try? FileManager.default.createDirectory(at: sideDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        func hit(_ what: String, _ kinds: Set<Secret>) -> Bool {
            guard !kinds.isEmpty else { return false }
            let k = keys == .keep
            if let i = part.hits.firstIndex(where: { $0.what == what }) { part.hits[i].kinds = Array(Set(part.hits[i].kinds).union(kinds)).sorted { $0.rawValue < $1.rawValue } }
            else { part.hits.append(Hit(what: what, kinds: kinds.sorted { $0.rawValue < $1.rawValue }, kept: k)) }
            return !k
        }
        func leftOut(_ s: String) { if !part.leftOut.contains(s) { part.leftOut.append(s) } }
        /// A small file carried: written to the image (when making it) with its size and hash.
        func put(_ name: String, _ data: Data) -> Item? {
            seq += 1
            let file = "\(dirName)/\(dir)/\(seq)"
            if let sideDir {
                let url = sideDir.appendingPathComponent("\(seq)")
                guard (try? data.write(to: url, options: .withoutOverwriting)) != nil else { leftOut("A side file couldn't be written into the file; it was left out."); return nil }
                chmod(url.path, 0o600)
            }
            return Item(name: name, file: file, bytes: Int64(data.count), sha: SwitchEngine.sha(data))
        }
        /// A big file carried (a Rewind backup): cloned or copied into the image, checked after.
        func putFile(_ name: String, _ src: String, bytes: Int64, mode: Int) -> Item? {
            seq += 1
            let file = "\(dirName)/\(dir)/\(seq)"
            guard let sideDir else { return Item(name: name, file: file, bytes: bytes, sha: "", mode: mode) }
            let dst = sideDir.appendingPathComponent("\(seq)").path
            switch SessionsBackup.copyOne(src, dst, single: true) {
            case .cloned, .copied: break
            default: leftOut("A Rewind backup couldn't be copied; it was left out."); return nil
            }
            chmod(dst, 0o600)
            var st = stat()
            guard lstat(dst, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int64(st.st_size) == bytes, let h = Setup.sha(path: dst) else {
                unlink(dst); leftOut("A Rewind backup changed while it was copied; it was left out."); return nil
            }
            return Item(name: name, file: file, bytes: bytes, sha: h, mode: mode)
        }

        let ids = Set(refs.map(\.id))
        // the history lines of the sessions, by session, in the file's order (one pass, capped)
        var lines: [String: [Data]] = [:]
        if kinds.history {
            let path = (codeDir as NSString).appendingPathComponent("history.jsonl")
            if let r = historyLines(path, sessions: ids, cancel: cancel) {
                lines = r.lines
                if r.capped { leftOut("history.jsonl is over \(SessionsBackup.sizeWords(maxHistoryFile)); only its first \(SessionsBackup.sizeWords(maxHistoryFile)) were read.") }
                if r.long > 0 { leftOut("\(r.long) prompt history \(r.long == 1 ? "line is" : "lines are") over 1 MB and \(r.long == 1 ? "was" : "were") left out.") }
            }
        }
        for ref in refs.prefix(maxSessions) {
            if cancel() { return nil }
            var s = Session(id: ref.id, cwd: ref.cwd, title: ref.title)
            let label = ref.title.map { "“\($0)”" } ?? "session \(ref.id.prefix(8))"
            // the task list
            if kinds.tasks {
                let tdir = (codeDir as NSString).appendingPathComponent("tasks/\(ref.id)")
                if let list = plainFiles(tdir) {
                    let names = list.filter { validTaskName($0.name) }
                    if names.count > maxTaskFiles { leftOut("The task list of \(label) has over \(maxTaskFiles) files; only the first \(maxTaskFiles) were taken.") }
                    for f in names.prefix(maxTaskFiles) {
                        guard f.bytes <= Int64(maxTaskFile), let d = readCapped(tdir + "/" + f.name, limit: maxTaskFile) else { leftOut("A task file of \(label) is over 1 MB; it was left out."); continue }
                        if hit("the task list of \(label)", SecretScan.scan(d)) { continue }
                        if let it = put(f.name, d) { s.tasks.append(it); pv.taskBytes += it.bytes }
                    }
                    if !s.tasks.isEmpty { pv.taskLists += 1 }
                }
            }
            // the plan
            if kinds.plans, let slug = slug(inTranscript: ref.transcript) {
                let p = (codeDir as NSString).appendingPathComponent("plans/\(slug).md")
                var st = stat()
                if lstat(p, &st) == 0 {
                    if (st.st_mode & S_IFMT) != S_IFREG || st.st_size > maxPlan { leftOut("The plan of \(label) is over 4 MB or isn't a plain file; it was left out.") }
                    else if let d = readCapped(p, limit: maxPlan), !hit("the plan of \(label)", SecretScan.scan(d)), let it = put(slug, d) {
                        // (two sessions of one plan: counted once)
                        s.plan = it
                        if !part.sessions.contains(where: { $0.plan?.name == slug }) { pv.plans += 1; pv.planBytes += it.bytes }
                    }
                }
            }
            // the prompt history and its pasted texts
            if kinds.history, let ls = lines[ref.id], !ls.isEmpty {
                var kept: [Data] = []
                for l in ls {
                    if hit("the prompt history of \(label)", SecretScan.scan(l)) { continue }
                    if historyTotal + Int64(l.count + 1) > maxHistoryBytes { leftOut("Prompt history over \(SessionsBackup.sizeWords(maxHistoryBytes)) was left out."); break }
                    historyTotal += Int64(l.count + 1)
                    kept.append(l)
                }
                if kept.count > maxHistoryLines { leftOut("\(label) has over \(maxHistoryLines) prompt history lines; the newest \(maxHistoryLines) were taken."); kept = Array(kept.suffix(maxHistoryLines)) }
                if !kept.isEmpty {
                    var body = Data()
                    for l in kept { body += l; body.append(0x0A) }
                    if let it = put("history", body) { s.history = it; s.historyLines = kept.count; pv.historyLines += kept.count; pv.historyBytes += it.bytes }
                    // the pasted texts those lines name
                    var hashes: [String] = []
                    for l in kept { for h in pasteHashes(l) where !hashes.contains(h) { hashes.append(h) } }
                    for h in hashes {
                        let p = (codeDir as NSString).appendingPathComponent("paste-cache/\(h).txt")
                        var st = stat()
                        guard lstat(p, &st) == 0 else { continue }
                        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= maxPaste, let d = readCapped(p, limit: maxPaste) else { leftOut("A pasted text over 8 MB was left out."); continue }
                        guard pasteHash(d) == h else { leftOut("A pasted text whose name isn't the hash of its text was left out."); continue }
                        if hit("a pasted text in the prompt history of \(label)", SecretScan.scan(d)) { continue }
                        guard pasteTotal + Int64(d.count) <= maxPastes else { leftOut("Pasted texts over \(SessionsBackup.sizeWords(maxPastes)) were left out."); break }
                        pasteTotal += Int64(d.count)
                        if let it = put(h, d) { s.pastes.append(it); pv.pastes += 1; pv.pasteBytes += it.bytes }
                    }
                }
            }
            // Rewind's backups: counted always (the page shows the size), carried only when asked
            let fdir = (codeDir as NSString).appendingPathComponent("file-history/\(ref.id)")
            if let list = plainFiles(fdir) {
                let names = list.filter { validBackupName($0.name) }
                s.rewindFiles = names.count
                s.rewindBytes = names.reduce(0) { $0 + $1.bytes }
                pv.rewindFiles += s.rewindFiles; pv.rewindBytes += s.rewindBytes
                if kinds.rewind {
                    if names.count > maxRewindFiles { leftOut("Rewind for \(label) has over \(maxRewindFiles) backups; only the first \(maxRewindFiles) were taken.") }
                    for f in names.prefix(maxRewindFiles) {
                        if cancel() { return nil }
                        guard f.bytes <= maxRewindFile else { leftOut("A Rewind backup over \(SessionsBackup.sizeWords(maxRewindFile)) was left out."); continue }
                        guard rewindTotal + f.bytes <= maxRewind else { leftOut("Rewind backups over \(SessionsBackup.sizeWords(maxRewind)) in all were left out."); break }
                        let path = fdir + "/" + f.name
                        guard let kinds = SecretScan.scan(path: path, cancel: cancel) else { if cancel() { return nil }; continue }
                        if hit("Rewind's copies of the files \(label) edited", kinds) { continue }
                        var st = stat()
                        let mode = lstat(path, &st) == 0 ? Int(st.st_mode & 0o777) : 0o600
                        rewindTotal += f.bytes
                        if let it = putFile(f.name, path, bytes: f.bytes, mode: mode) { s.rewind.append(it) }
                    }
                }
            }
            let any = !s.tasks.isEmpty || s.plan != nil || s.history != nil || !s.rewind.isEmpty || s.rewindFiles > 0
            if any { part.sessions.append(s); pv.sessions += 1 }
        }
        // trust: the project entries in .claude.json for each session's folder (its cwd, and its project folder when that differs). A
        // folder above it (Claude Code also looks up the tree to the repository's top) isn't carried: it would trust more on the new Mac
        if kinds.trust {
            let cfg = configFile(codeDir: codeDir)
            switch projectsOf(cfg) {
            case .failure(let why): pv.configNote = why.description
            case .success(let projects):
                for ref in refs.prefix(maxSessions) {
                    var keysFor: [String] = []
                    for k in [ref.cwd, SessionsRepoint.projectFolder(of: ref.cwd)] where !keysFor.contains(k) && projects[k] != nil && keysFor.count < maxKeys { keysFor.append(k) }
                    for k in keysFor {
                        guard !part.trust.contains(where: { $0.session == ref.id && $0.key == k }), let v = projects[k] as? [String: Any] else { continue }
                        guard let t = trust(of: v, session: ref.id, key: k) else { continue }
                        if let tools = try? JSONSerialization.data(withJSONObject: t.allowedTools), hit("the allowed tools of \(tilde(k))", SecretScan.scan(tools)) { continue }
                        var tt = t
                        if let m = t.mcp, hit("the MCP servers of \(tilde(k))", SecretScan.scan(Data(m.utf8))) { tt.mcp = nil; tt.mcpServers = [] }
                        if !kinds.mcp { tt.mcp = nil; tt.mcpServers = [] }
                        guard tt.trusted || !tt.allowedTools.isEmpty || tt.mcp != nil else { continue }
                        part.trust.append(tt)
                    }
                }
                let folders = Set(part.trust.map(\.key))
                pv.trust = folders.count
                pv.mcpServers = part.trust.reduce(0) { $0 + $1.mcpServers.count }
            }
        }
        pv.hits = part.hits
        pv.leftOut = part.leftOut
        return (part, pv)
    }

    /// The fields of a project entry that are carried: trust and allowed tools, and the MCP servers apart (capped; nil: nothing to carry).
    static func trust(of v: [String: Any], session: String, key: String) -> Trust? {
        var t = Trust(session: session, key: key)
        t.trusted = (v["hasTrustDialogAccepted"] as? Bool) == true
        if let tools = v["allowedTools"] as? [Any] {
            t.allowedTools = Array(tools.compactMap { $0 as? String }.filter { $0.utf8.count <= 4096 && !$0.unicodeScalars.contains { $0.value < 0x20 } }.prefix(maxTools))
        }
        var mcp: [String: Any] = [:]
        if let servers = v["mcpServers"] as? [String: Any], !servers.isEmpty { mcp["mcpServers"] = servers; t.mcpServers = servers.keys.sorted().map { SessionsBackup.oneLine($0, max: 80) } }
        for k in ["enabledMcpjsonServers", "disabledMcpjsonServers"] {
            if let a = v[k] as? [Any] { let s = a.compactMap { $0 as? String }.filter { $0.utf8.count <= 256 }; if !s.isEmpty { mcp[k] = Array(s.prefix(200)) } }
        }
        if !mcp.isEmpty, let d = try? JSONSerialization.data(withJSONObject: mcp, options: [.sortedKeys, .withoutEscapingSlashes]), d.count <= maxEntry {
            t.mcp = String(decoding: d, as: UTF8.self)
        } else { t.mcpServers = [] }
        if let d = try? JSONSerialization.data(withJSONObject: t.allowedTools), d.count > maxEntry { t.allowedTools = [] }
        return t
    }

    /// The `projects` object of a .claude.json, read once under its cap, never through a link.
    static func projectsOf(_ path: String) -> Result<[String: Any], ConfigProblem> {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .failure(ConfigProblem("Claude Code's .claude.json isn't there, so no folder's trust is carried.")) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(ConfigProblem("Claude Code's .claude.json is a link or isn't a plain file, so it isn't read.")) }
        guard st.st_size <= maxConfig, let d = readCapped(path, limit: maxConfig) else { return .failure(ConfigProblem("Claude Code's .claude.json is over \(SessionsBackup.sizeWords(Int64(maxConfig))), so it isn't read.")) }
        guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return .failure(ConfigProblem("Claude Code's .claude.json can't be read as JSON, so no trust is carried.")) }
        return .success((j["projects"] as? [String: Any]) ?? [:])
    }

    struct ConfigProblem: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

    /// The lines of history.jsonl that name one of `sessions` (`"sessionId":"<id>"`, the line a JSON object), each as it is, in the file's
    /// order; the file is read at most 512 MB far, a line over 1 MB is counted and left out.
    static func historyLines(_ path: String, sessions: Set<String>, cancel: () -> Bool = { false }) -> (lines: [String: [Data]], capped: Bool, long: Int)? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        var out: [String: [Data]] = [:]
        var long = 0
        var line: [UInt8] = []
        var skipping = false
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var off: off_t = 0
        let limit = off_t(min(Int64(st.st_size), maxHistoryFile))
        func end() {
            defer { line.removeAll(keepingCapacity: true) }
            if skipping { skipping = false; return }
            guard line.count > 30, let id = sessionID(ofHistoryLine: line), sessions.contains(id) else { return }
            out[id, default: []].append(Data(line))
        }
        while off < limit {
            if cancel() { return nil }
            let n = pread(fd, &buf, min(buf.count, Int(limit - off)), off)
            if n <= 0 { break }
            off += off_t(n)
            var start = 0
            /// (checked before a line ends too: one that grows past the cap across reads is never taken)
            func cap() { if !skipping, line.count > maxHistoryLine { long += 1; skipping = true; line.removeAll(keepingCapacity: true) } }
            while start < n {
                if let nl = buf[start..<n].firstIndex(of: 0x0A) {
                    if !skipping { line.append(contentsOf: buf[start..<nl]); cap() }
                    end()
                    start = nl + 1
                } else {
                    if !skipping { line.append(contentsOf: buf[start..<n]); cap() }
                    start = n
                }
            }
        }
        // a last line without its newline, when the whole file was read
        if off >= off_t(st.st_size), !line.isEmpty || skipping { end() }
        return (out, Int64(st.st_size) > maxHistoryFile, long)
    }

    /// The session a history line names, when the line is a JSON object with a `sessionId` that is a session id.
    static func sessionID(ofHistoryLine b: [UInt8]) -> String? {
        guard let j = (try? JSONSerialization.jsonObject(with: Data(b))) as? [String: Any], let s = j["sessionId"] as? String, validID(s.lowercased()) else { return nil }
        return s.lowercased()
    }

    /// The paste hashes a history line names (pastedContents.*.contentHash).
    static func pasteHashes(_ d: Data) -> [String] {
        guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let pc = j["pastedContents"] as? [String: Any] else { return [] }
        return pc.values.compactMap { ($0 as? [String: Any])?["contentHash"] as? String }.filter(validHash).sorted()
    }

    static func encode(_ f: File) -> Data? {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let d = try? enc.encode(f), d.count <= maxManifest else { return nil }
        return d
    }

    // MARK: import: reading side.json back (untrusted)

    /// side.json read and cleaned: every name checked, every number in range; what doesn't pass is dropped (and said on the page). nil: it
    /// isn't a side.json at all.
    static func read(_ data: Data, parts known: Set<String>) -> File? {
        guard data.count <= maxManifest, var f = try? JSONDecoder().decode(File.self, from: data), f.version == 1, f.parts.count <= 64 else { return nil }
        var seenDirs = Set<String>()
        var files = Set<String>()
        f.parts = f.parts.compactMap { p0 in
            var p = p0
            guard known.contains(p.dir), seenDirs.insert(p.dir).inserted else { return nil }
            func ok(_ it: Item, _ nameOK: (String) -> Bool, cap: Int64) -> Bool {
                it.bytes >= 0 && it.bytes <= cap && validSha(it.sha) && nameOK(it.name) && validFile(it.file, dir: p.dir) && files.insert(it.file).inserted
            }
            var dropped = 0
            var ids = Set<String>()
            p.sessions = Array(p.sessions.prefix(maxSessions)).compactMap { s0 in
                var s = s0
                guard validID(s.id), ids.insert(s.id).inserted, SessionsRepoint.clean(s.cwd) else { dropped += 1; return nil }
                s.title = s.title.map { SessionsBackup.oneLine($0, max: 80) }
                let t0 = s.tasks.count, r0 = s.rewind.count, p0 = s.pastes.count
                s.tasks = Array(s.tasks.prefix(maxTaskFiles)).filter { ok($0, validTaskName, cap: Int64(maxTaskFile)) }
                if let pl = s.plan, !ok(pl, validSlug, cap: Int64(maxPlan)) { s.plan = nil; dropped += 1 }
                if let h = s.history, !ok(h, { $0 == "history" }, cap: maxHistoryBytes) { s.history = nil; dropped += 1 }
                s.historyLines = max(0, min(s.historyLines, maxHistoryLines))
                s.pastes = s.pastes.filter { ok($0, validHash, cap: Int64(maxPaste)) }
                s.rewind = Array(s.rewind.prefix(maxRewindFiles)).filter { ok($0, validBackupName, cap: maxRewindFile) }
                s.rewindFiles = max(0, min(s.rewindFiles, 1_000_000)); s.rewindBytes = max(0, min(s.rewindBytes, 1 << 50))
                dropped += (t0 - s.tasks.count) + (r0 - s.rewind.count) + (p0 - s.pastes.count)
                return s
            }
            p.trust = Array(p.trust.prefix(maxSessions * maxKeys)).compactMap { t0 in
                var t = t0
                guard ids.contains(t.session), SessionsRepoint.clean(t.key), t.key != "/" else { dropped += 1; return nil }
                t.allowedTools = Array(t.allowedTools.prefix(maxTools)).filter { $0.utf8.count <= 4096 && !$0.unicodeScalars.contains { $0.value < 0x20 } }
                if let m = t.mcp {
                    guard m.utf8.count <= maxEntry, let j = (try? JSONSerialization.jsonObject(with: Data(m.utf8))) as? [String: Any],
                          Set(j.keys).isSubset(of: ["mcpServers", "enabledMcpjsonServers", "disabledMcpjsonServers"]) else { t.mcp = nil; t.mcpServers = []; dropped += 1; return t }
                    t.mcpServers = ((j["mcpServers"] as? [String: Any])?.keys.sorted() ?? []).map { SessionsBackup.oneLine($0, max: 80) }
                } else { t.mcpServers = [] }
                return t
            }
            p.leftOut = Array(p.leftOut.prefix(50)).map { SessionsBackup.oneLine($0, max: 240) }
            p.hits = Array(p.hits.prefix(200)).map { Hit(what: SessionsBackup.oneLine($0.what, max: 160), kinds: Array($0.kinds.prefix(20)), kept: $0.kept) }
            if dropped > 0 { p.leftOut.append("\(dropped) side \(dropped == 1 ? "file or entry" : "files or entries") in the file didn't look like Claude Code's and \(dropped == 1 ? "was" : "were") left out.") }
            return p
        }
        return f
    }

    /// Every file side.json names, for the import's tree check (path → size).
    static func expected(_ f: File) -> [String: (bytes: Int64, sha: String)] {
        var out: [String: (bytes: Int64, sha: String)] = [:]
        for p in f.parts {
            for s in p.sessions {
                for it in s.tasks + s.pastes + s.rewind + [s.plan, s.history].compactMap({ $0 }) { out[it.file] = (it.bytes, it.sha) }
            }
        }
        return out
    }

    /// A part's side files kept with the imported backup it belongs to (<backup>/side/: side.json and the files), outside the backup's
    /// manifest, so a Restore of that backup brings them as the import does, and an export of the backup never carries them.
    static func stash(_ tree: URL, part: Part, into backupDir: String) throws {
        let dst = (backupDir as NSString).appendingPathComponent(dirName)
        guard mkdir(dst, 0o700) == 0 else { throw ArchiveError("The backups folder can't be written.") }
        var p = part
        let prefix = "\(dirName)/\(part.dir)/"
        func moved(_ it: Item) throws -> Item {
            var n = it
            let leaf = String(it.file.dropFirst(prefix.count))
            n.file = "\(dirName)/\(leaf)"
            let to = (dst as NSString).appendingPathComponent(leaf)
            switch SessionsBackup.copyOne(tree.appendingPathComponent(it.file).path, to, single: true) {
            case .cloned, .copied: break
            default: throw ArchiveError("A side file of the export couldn't be kept with the backup.")
            }
            chmod(to, 0o600)
            return n
        }
        p.sessions = try p.sessions.map { s in
            var s = s
            s.tasks = try s.tasks.map(moved); s.pastes = try s.pastes.map(moved); s.rewind = try s.rewind.map(moved)
            s.plan = try s.plan.map(moved); s.history = try s.history.map(moved)
            return s
        }
        p.dir = "stash"
        guard let d = encode(File(parts: [p])) else { throw ArchiveError("The side files' list came out too big.") }
        do { try d.write(to: URL(fileURLWithPath: (dst as NSString).appendingPathComponent(fileName)), options: .withoutOverwriting) }
        catch { throw ArchiveError("The backups folder can't be written.") }
        chmod((dst as NSString).appendingPathComponent(fileName), 0o600)
    }

    /// The titles of the sessions a part's window entries run (session id → title).
    static func titles(windowDir: String) -> [String: String] {
        var out: [String: String] = [:]
        guard let walk = FileManager.default.enumerator(atPath: windowDir) else { return out }
        for case let rel as String in walk where (rel as NSString).lastPathComponent.hasPrefix("local_") && rel.hasSuffix(".json") {
            guard let d = readCapped((windowDir as NSString).appendingPathComponent(rel), limit: SessionsRepoint.maxEntry), let f = SessionsRepoint.entryFacts(d), let t = f.title else { continue }
            out[f.cli] = t
        }
        return out
    }

    /// The side files kept with an imported backup, read back (untrusted, like the image): nil when it has none.
    static func stashed(_ b: SessionsRestore.Backup) -> Part? {
        let dir = b.dir.appendingPathComponent(dirName).path
        guard let d = readCapped((dir as NSString).appendingPathComponent(fileName), limit: maxManifest),
              let raw = try? JSONDecoder().decode(File.self, from: d), raw.parts.count == 1 else { return nil }
        // (the stash names its files "side/<n>"; read with the image's rules under the name "stash")
        var f = raw
        f.parts[0].sessions = f.parts[0].sessions.map { s in
            var s = s
            func re(_ it: Item) -> Item { var n = it; n.file = it.file.replacingOccurrences(of: "\(dirName)/", with: "\(dirName)/stash/"); return n }
            s.tasks = s.tasks.map(re); s.pastes = s.pastes.map(re); s.rewind = s.rewind.map(re); s.plan = s.plan.map(re); s.history = s.history.map(re)
            return s
        }
        guard let data = encode(f), let clean = read(data, parts: ["stash"]), let p = clean.parts.first else { return nil }
        return p
    }

    /// The path of a stashed item's file.
    static func stashPath(_ b: SessionsRestore.Backup, _ it: Item) -> String {
        let leaf = (it.file as NSString).lastPathComponent
        return b.dir.appendingPathComponent("\(dirName)/\(leaf)").path
    }

    // MARK: the import's preview (what each row says)

    struct Plan: Equatable {
        var sessions = 0
        var taskLists = 0, taskFiles = 0
        var taskBytes: Int64 = 0
        var plans = 0
        var planBytes: Int64 = 0
        var historyLines = 0
        var historyBytes: Int64 = 0
        var pastes = 0
        var pasteBytes: Int64 = 0
        var trust = 0
        var mcpServers = 0
        var rewindFiles = 0
        var rewindBytes: Int64 = 0
        var rewindOnOldMac: Int64 = 0                   // what the old Mac had (shown when Rewind wasn't carried)
        var leftOut: [String] = []
        var hits: [Hit] = []
        var isEmpty: Bool { sessions == 0 }
    }

    static func plan(_ p: Part) -> Plan {
        var pl = Plan()
        for s in p.sessions {
            pl.sessions += 1
            if !s.tasks.isEmpty { pl.taskLists += 1; pl.taskFiles += s.tasks.count; pl.taskBytes += s.tasks.reduce(0) { $0 + $1.bytes } }
            if let x = s.plan, !p.sessions.prefix(while: { $0.id != s.id }).contains(where: { $0.plan?.name == x.name }) { pl.plans += 1; pl.planBytes += x.bytes }
            if let h = s.history { pl.historyLines += s.historyLines; pl.historyBytes += h.bytes }
            pl.pastes += s.pastes.count; pl.pasteBytes += s.pastes.reduce(0) { $0 + $1.bytes }
            pl.rewindFiles += s.rewind.count; pl.rewindBytes += s.rewind.reduce(0) { $0 + $1.bytes }
            pl.rewindOnOldMac += s.rewindBytes
        }
        pl.trust = Set(p.trust.filter { $0.trusted || !$0.allowedTools.isEmpty }.map(\.key)).count
        pl.mcpServers = p.trust.reduce(0) { $0 + $1.mcpServers.count }
        pl.leftOut = p.leftOut; pl.hits = p.hits
        return pl
    }

    /// The kinds an import of a move starts with: every kind the file carries, on (like a move's memory), the MCP servers off.
    static func importKinds(_ p: Plan) -> Kinds {
        Kinds(tasks: p.taskLists > 0, plans: p.plans > 0, history: p.historyLines > 0, trust: p.trust > 0, mcp: false, rewind: p.rewindFiles > 0)
    }
}
