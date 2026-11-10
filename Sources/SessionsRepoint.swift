// SessionsRepoint: a session that came from another Mac (an import, a restore of an imported backup) pointed at the folder its project
// is in on this Mac. Claude Code files a session's transcript under its folder's name (ProjectName) and records the folder in every line
// (`cwd`); the Claude window's Code-tab entry records it too (cwd, originCwd, and a worktree's path). When the folder is at the same path
// here, nothing is needed. When it isn't (missing, or cloned somewhere else), the Import page and the Sessions page list the session with
// "Pick its folder on this Mac…", and a picked folder re-points it:
//
// - the transcript (projects/<old name>/<id>.jsonl) and its folder (<id>/: subagents, tool results …) are written anew under the picked
//   folder's name, each line's top-level `cwd` that names the old folder (or a folder inside it) rewritten to the picked one, every other
//   byte of the line as it was (a line that isn't a JSON object is copied as it is; a line over 64 MB is copied as it is and counted). The
//   files are new (create-only, a temp name linked into place, never over a file, never through a link), with the old file's dates. Only
//   then is each old file copied into the receipt's folder and taken away;
// - the project's memory files (projects/<old name>/memory/) are copied to the new name where missing (the old ones stay);
// - each Code-tab entry that runs the session gets cwd and originCwd set to the picked folder. A worktree whose folder isn't on this Mac
//   is dropped with the fields the window reads with it (worktreePath, worktreeName, worktreeLazy, branch, sourceBranch,
//   keptDirtyWorktree), and harnessCwd when its folder isn't here, so the window runs the session in the project folder (the window spawns
//   it in `harnessCwd ?? worktreePath ?? worktreeLazy?.path ?? cwd` and refuses to send when that folder is gone: Claude app's program
//   text, not run). Every other byte of the entry stays. The window must be closed while an entry is written;
// - a receipt (repoints/<id>/receipt.json) is saved before each step and after it, with the old files and entries kept beside it, so
//   Undo takes back exactly this: the old files and entries come back, and the new ones go, only when they are unchanged since. A session
//   whose new transcript changed since (it was resumed) stays re-pointed, and that is said.
//
// The folder's name (Claude Code 2.1.318's program text, not run): every UTF-16 unit outside [a-zA-Z0-9] becomes "-"; a name over 200
// characters is cut to 200 and gets "-" and a hash of the whole path: Java's String.hashCode over its UTF-16 units (32 bits), its absolute
// value in base 36 (`Math.abs(Cbe(e)).toString(36)`, `cRe=200`).
//
// Everything read from the transcript and the entry is untrusted: a cwd with control characters, "." or ".." parts or over 4096
// characters is never used (the session isn't offered, or that line is left as it is), an entry is read through a 1 MB cap and must be
// a JSON object, a transcript over 2 GB or a session folder over 20,000 files isn't re-pointed, and a picked folder must be a real folder
// that is none of Claude's or cl_audit's own.

import CryptoKit
import Foundation

/// Claude Code's name for a project folder under <Claude Code folder>/projects.
enum ProjectName {
    static let maxLength = 200

    /// Java's String.hashCode over the UTF-16 units, its absolute value in base 36 (Claude Code: `Math.abs(Cbe(e)).toString(36)`).
    static func hash(_ s: String) -> String {
        var h: Int32 = 0
        for u in s.utf16 { h = (h &<< 5) &- h &+ Int32(u) }
        return String(abs(Int64(h)), radix: 36)
    }

    /// Every UTF-16 unit outside [a-zA-Z0-9] becomes "-"; over 200 characters: the first 200, "-", and the hash of the whole path.
    static func encoded(_ path: String) -> String {
        var out = [UInt8]()
        out.reserveCapacity(path.utf16.count)
        for u in path.utf16 {
            let ok = (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A)
            out.append(ok ? UInt8(u) : 0x2D)
        }
        let s = String(decoding: out, as: UTF8.self)
        guard out.count > maxLength else { return s }
        return String(decoding: out[0..<maxLength], as: UTF8.self) + "-" + hash(path)
    }
}

enum SessionsRepoint {
    static var root: URL { Store.folder.appendingPathComponent("repoints") }
    static let maxTranscript: Int64 = 2 << 30
    static let maxLine = 64 << 20
    static let maxEntry = 1 << 20
    static let maxFiles = 20_000
    static let maxPath = 4096
    /// The fields of a Code-tab entry that belong to its worktree (the window reads them together: its session record keeps
    /// worktreePath, worktreeName, worktreeLazy, sourceBranch, branch side by side, and `startedWithWorktree`/`worktreeRemoved` look at them).
    static let worktreeFields: [String] = ["worktreePath", "worktreeName", "worktreeLazy", "branch", "sourceBranch", "keptDirtyWorktree"]

    /// A check's seam: whether a folder is on this Mac (a real folder).
    nonisolated(unsafe) static var folderHere: (String) -> Bool = { path in
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: paths

    /// A path that can be used as a folder: absolute, no control characters, no ".", ".." or empty parts, at most 4096 characters.
    static func clean(_ p: String) -> Bool {
        guard p.hasPrefix("/"), p.utf8.count <= maxPath, !p.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) }) else { return false }
        if p == "/" { return true }
        let parts = p.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    static func inside(_ p: String, _ folder: String) -> Bool { p == folder || p.hasPrefix(folder == "/" ? "/" : folder + "/") }

    /// The project folder a recorded cwd belongs to: a Claude Code worktree (<project>/.claude/worktrees/<name>) is cut to its project.
    static func projectFolder(of cwd: String) -> String {
        if let r = cwd.range(of: "/.claude/worktrees/") {
            let base = String(cwd[..<r.lowerBound])
            if !base.isEmpty { return base }
        }
        return cwd
    }

    /// The worktree folder a recorded cwd is in (<project>/.claude/worktrees/<name>), or nil.
    static func worktreeFolder(of cwd: String) -> String? {
        guard let r = cwd.range(of: "/.claude/worktrees/") else { return nil }
        let rest = cwd[r.upperBound...]
        guard let name = rest.split(separator: "/").first, !name.isEmpty else { return nil }
        return String(cwd[..<r.upperBound]) + name
    }

    // MARK: what a session is

    struct Session: Equatable, Identifiable {
        var id: String                      // Claude Code's session id, lower case
        var title: String?                  // the Code-tab entry's title, one plain line
        var project: String                 // the transcript's folder name under projects
        var transcript: String              // where the transcript is (absolute)
        var recorded: String                // the cwd its transcript names first
        var folder: String                  // its project folder: the entry's originCwd, else the recorded cwd without a worktree's tail
        var worktree: String?               // the entry's worktreePath, or the recorded cwd's worktree
        var entries: [String] = []          // the Code-tab entries that run it (absolute paths)
        var here: Bool                      // the folder is on this Mac
    }

    /// One Code-tab entry, read and checked (1 MB cap, a JSON object).
    struct EntryFacts {
        var cli: String
        var title: String?
        var cwd: String?
        var originCwd: String?
        var worktreePath: String?
    }

    static func readCapped(_ path: String, limit: Int) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0, st.st_size <= off_t(limit) else { return nil }
        var d = Data(count: Int(st.st_size))
        let n = d.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(st.st_size), 0) }
        return n == Int(st.st_size) ? d : nil
    }

    static func entryFacts(_ d: Data) -> EntryFacts? {
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let cli = j["cliSessionId"] as? String, AccountDiscovery.isUUID(cli) else { return nil }
        func path(_ k: String) -> String? { (j[k] as? String).flatMap { clean($0) ? $0 : nil } }
        let title = (j["title"] as? String).map { SessionsBackup.oneLine($0, max: 80) }.flatMap { $0.isEmpty ? nil : $0 }
        return EntryFacts(cli: cli.lowercased(), title: title, cwd: path("cwd"), originCwd: path("originCwd"), worktreePath: path("worktreePath"))
    }

    /// The first cwd a transcript names (its first 64 KB), when it is a clean path.
    static func recordedCwd(_ transcript: String) -> String? {
        guard let c = SessionsExport.cwd(inTranscript: transcript), clean(c) else { return nil }
        return c
    }

    static func session(id: String, project: String, transcript: String, entries: [(path: String, facts: EntryFacts)]) -> Session? {
        guard let rec = recordedCwd(transcript) else { return nil }
        let origin = entries.compactMap(\.facts.originCwd).first
        let folder = origin ?? projectFolder(of: rec)
        let wt = entries.compactMap(\.facts.worktreePath).first ?? worktreeFolder(of: rec)
        return Session(id: id, title: entries.compactMap(\.facts.title).first, project: project, transcript: transcript, recorded: rec, folder: folder,
                       worktree: wt, entries: entries.map(\.path), here: folderHere(folder))
    }

    /// The Code-tab entries of a window's data folder, by the session they run (links never followed).
    static func entries(dataDir: String) -> [String: [(path: String, facts: EntryFacts)]] {
        guard !dataDir.isEmpty else { return [:] }
        var out: [String: [(path: String, facts: EntryFacts)]] = [:]
        let w = SessionsRestore.WindowNow.read(dataDir)
        for (_, paths) in w.entries {
            for p in paths {
                guard let d = readCapped(p, limit: maxEntry), let f = entryFacts(d) else { continue }
                out[f.cli, default: []].append((p, f))
            }
        }
        return out
    }

    /// The sessions a staged backup would add (an import's preview): the transcripts the plan writes, with the entries it writes.
    static func staged(_ p: SessionsRestore.Plan, backup: SessionsRestore.Backup) -> [Session] {
        var byCli: [String: [(path: String, facts: EntryFacts)]] = [:]
        for e in p.entries {
            let path = backup.dir.appendingPathComponent(e.rel.joined(separator: "/")).path
            guard let d = readCapped(path, limit: maxEntry), let f = entryFacts(d) else { continue }
            byCli[f.cli, default: []].append((path, f))
        }
        var out: [Session] = []
        for t in p.transcripts where t.rel.count == 3 && t.rel[2].hasSuffix(".jsonl") {
            let id = String(t.rel[2].dropLast(6)).lowercased()
            guard AccountDiscovery.isUUID(id) else { continue }
            let path = backup.dir.appendingPathComponent(t.rel.joined(separator: "/")).path
            if let s = session(id: id, project: t.rel[1], transcript: path, entries: byCli[id] ?? []) { out.append(s) }
        }
        return out.sorted { ($0.folder, $0.id) < ($1.folder, $1.id) }
    }

    /// The sessions this profile has from imports (finished, not undone) whose folder isn't on this Mac: for the Sessions page.
    static func missing(_ t: SessionsRestore.Target) -> [Session] {
        var ids = Set<String>()
        for h in SessionsRestore.headers() where h.profile == t.profile && h.importedFrom != nil && h.undone == nil {
            guard let r = SessionsRestore.load(h.id) else { continue }
            for s in r.steps where s.kind == .transcript && s.path.hasSuffix(".jsonl") {
                let leaf = (s.path as NSString).lastPathComponent
                let id = String(leaf.dropLast(6)).lowercased()
                if AccountDiscovery.isUUID(id) { ids.insert(id) }
            }
        }
        guard !ids.isEmpty else { return [] }
        let projects = (t.codeDir as NSString).appendingPathComponent("projects")
        let fm = FileManager.default
        let byCli = entries(dataDir: t.dataDir)
        var out: [Session] = []
        for p in ((try? fm.contentsOfDirectory(atPath: projects)) ?? []).sorted() where SessionsRestore.plainName(p) && !p.hasPrefix(".") {
            let dir = (projects as NSString).appendingPathComponent(p)
            var st = stat()
            guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            for leaf in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []) where leaf.hasSuffix(".jsonl") {
                let id = String(leaf.dropLast(6)).lowercased()
                guard ids.contains(id) else { continue }
                let path = (dir as NSString).appendingPathComponent(leaf)
                guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                if let s = session(id: id, project: p, transcript: path, entries: byCli[id] ?? []), !s.here { out.append(s) }
            }
        }
        return out.sorted { ($0.folder, $0.id) < ($1.folder, $1.id) }
    }

    // MARK: rewriting a line

    /// A JSON string as it is written (slashes as they are).
    static func jsonString(_ s: String) -> [UInt8]? {
        guard let d = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]), d.count >= 2 else { return nil }
        return Array(d.dropFirst().dropLast())
    }

    /// The line with each top-level "cwd" that `map` changes rewritten, every other byte as it was; nil: unchanged (not a JSON object,
    /// no such cwd, or nothing to change). `line` is without its newline.
    static func rewrite(line b: [UInt8], map: (String) -> String?) -> [UInt8]? {
        // only a line that names "cwd" is parsed
        let needle: [UInt8] = Array("\"cwd\"".utf8)
        guard b.count >= needle.count, contains(b, needle), let members = EntryConnections.top(b) else { return nil }
        var out: [UInt8] = []
        var at = 0
        var changed = false
        for m in members where m.key == "cwd" {
            guard m.value < b.count, b[m.value] == 0x22,
                  let old = (try? JSONSerialization.jsonObject(with: Data([UInt8(0x5B)] + Array(b[m.value..<m.end]) + [UInt8(0x5D)]))) as? [String], let v = old.first,
                  let new = map(v), new != v, let enc = jsonString(new) else { continue }
            out += b[at..<m.value]; out += enc; at = m.end
            changed = true
        }
        guard changed else { return nil }
        out += b[at...]
        return out
    }

    private static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard hay.count >= needle.count else { return false }
        return hay.withUnsafeBufferPointer { h in
            needle.withUnsafeBufferPointer { n in memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil }
        }
    }

    /// How a session's recorded paths are mapped to the picked folder: a path in a dropped worktree becomes the picked folder; a path in
    /// the old project folder keeps its place under the picked one; anything else stays (nil). A path that isn't clean is never used.
    static func mapper(folder: String, picked: String, dropped: [String]) -> (String) -> String? {
        return { v in
            guard clean(v) else { return nil }
            if dropped.contains(where: { inside(v, $0) }) { return picked }
            guard inside(v, folder) else { return nil }
            let rest = v.dropFirst(folder == "/" ? 0 : folder.count)
            return rest.isEmpty ? picked : (picked == "/" ? String(rest) : picked + rest)
        }
    }

    // MARK: an entry

    /// The entry with its members set or dropped, every other byte as it was; nil: it isn't a UTF-8 JSON object, or the result isn't one.
    /// `set` keys that aren't there are added at the end.
    static func edited(_ d: Data, set: [(String, String)], drop: Set<String>) -> Data? {
        let b = [UInt8](d)
        guard let members = top(b) else { return nil }
        var values: [String: [UInt8]] = [:]
        for (k, v) in set { guard let e = jsonString(v) else { return nil }; values[k] = e }
        var pieces: [[UInt8]] = []
        var seen = Set<String>()
        for m in members {
            if drop.contains(m.key) { continue }
            if let v = values[m.key] { pieces.append(Array(b[m.start..<m.value]) + v); seen.insert(m.key) }
            else { pieces.append(Array(b[m.start..<m.end])) }
        }
        for (k, _) in set where !seen.contains(k) {
            guard let key = jsonString(k), let v = values[k] else { return nil }
            pieces.append(key + Array(":".utf8) + v)
        }
        let sep: [UInt8] = members.count >= 2 ? Array(b[members[0].end..<members[1].start]) : [0x2C]
        var out: [UInt8]
        if members.isEmpty {
            guard let close = b.lastIndex(of: 0x7D) else { return nil }
            out = Array(b[0..<close])
            for (n, p) in pieces.enumerated() { if n > 0 { out += [0x2C] }; out += p }
            out += b[close...]
        } else {
            out = Array(b[0..<members[0].start])
            for (n, p) in pieces.enumerated() { if n > 0 { out += sep }; out += p }
            out += b[members[members.count - 1].end...]
        }
        let r = Data(out)
        guard (try? JSONSerialization.jsonObject(with: r)) is [String: Any] else { return nil }
        return r
    }

    private static func top(_ b: [UInt8]) -> [(key: String, start: Int, value: Int, end: Int)]? { EntryConnections.top(b) }

    /// What a re-point does to an entry: (the new bytes, the fields it dropped). nil: it can't be read as an entry.
    static func entryRepointed(_ d: Data, folder: String, picked: String, map: (String) -> String?, here: (String) -> Bool) -> (data: Data, dropped: [String])? {
        guard d.count <= maxEntry, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var set: [(String, String)] = []
        var drop = Set<String>()
        let cwd = (j["cwd"] as? String).flatMap(map).flatMap { here($0) ? $0 : nil } ?? picked
        set.append(("cwd", cwd))
        if j["originCwd"] != nil { set.append(("originCwd", picked)) }
        var dropWorktree = j["worktreeLazy"] != nil
        if let wp = j["worktreePath"] {
            if let s = wp as? String, let m = map(s), here(m), m != picked { set.append(("worktreePath", m)) }
            else { dropWorktree = true }
        }
        if dropWorktree { for k in worktreeFields where j[k] != nil { drop.insert(k) } }
        if let hc = j["harnessCwd"] {
            if let s = hc as? String, let m = map(s) ?? (clean(s) ? s : nil), here(m) { if m != s { set.append(("harnessCwd", m)) } }
            else { drop.insert("harnessCwd") }
        }
        set.removeAll { drop.contains($0.0) }
        guard let out = edited(d, set: set, drop: drop) else { return nil }
        return (out, drop.sorted())
    }

    // MARK: the receipt

    struct Step: Codable, Equatable {
        enum Kind: String, Codable { case made, dir, entry, parked }
        var kind: Kind
        var session: String
        var path: String                    // made: a new file; dir: a folder made; entry: the entry; parked: an old file taken away
        var sha: String?                    // made, entry: what was written; parked: the old file's
        var saved: String?                  // entry, parked: the copy kept in the receipt's folder (its name there)
        var done = false
        var settled = false                 // Undo is done with it
    }

    struct Done: Codable, Equatable {
        var session: String
        var title: String?
        var from: String                    // the old project folder
        var to: String                      // the picked one
        var lines = 0                       // lines whose cwd was rewritten
        var keptLines = 0                   // lines left as they were although they may name the folder (over 64 MB, or not a clean path)
        var files = 0                       // files written under the new name
        var memory = 0                      // memory files copied
        var entries = 0                     // Code-tab entries changed
        var dropped: [String] = []          // entry fields dropped (a worktree that isn't here)
        var undone = false
        var left: String? = nil             // why Undo left it re-pointed
    }

    struct Receipt: Codable, Equatable {
        var id: String
        var profile: String
        var codeDir: String
        var dataDir: String
        var restore: String?                // the import's restore receipt it follows (its Undo takes this back first)
        var started: Date
        var finished: Date?
        var undone: Date?
        var sessions: [Done] = []
        var problems: [String] = []
        var steps: [Step] = []
        var touchesWindow: Bool { steps.contains { $0.kind == .entry && $0.done && !$0.settled } }
    }

    struct Pick: Equatable, Codable, Hashable {
        var session: String
        var folder: String
    }

    private static func dir(_ id: String) -> URL { root.appendingPathComponent(id) }
    static func validID(_ s: String) -> Bool { SessionsRestore.validReceiptID(s) }

    static func save(_ r: Receipt) throws {
        let d = dir(r.id)
        try FileManager.default.createDirectory(at: d.appendingPathComponent("saved"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(r).write(to: d.appendingPathComponent("receipt.json"), options: .atomic)
    }

    static func load(_ id: String) -> Receipt? {
        guard validID(id) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = readCapped(dir(id).appendingPathComponent("receipt.json").path, limit: 64 << 20), let r = try? dec.decode(Receipt.self, from: d), r.id == id else { return nil }
        return r
    }

    static func receipts() -> [Receipt] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(validID).compactMap(load).sorted { $0.started > $1.started }
    }

    /// The re-points that follow an import's restore and aren't undone.
    static func linked(restore id: String) -> [Receipt] { receipts().filter { $0.restore == id && $0.undone == nil } }
    static func touchesWindow(restore id: String) -> Bool { linked(restore: id).contains(where: \.touchesWindow) }
    /// The last re-point of a profile that isn't undone (the Sessions page's Undo).
    static func last(profile: String) -> Receipt? { receipts().first { $0.profile == profile && $0.undone == nil && $0.finished != nil } }

    // MARK: re-pointing

    struct RepointError: Error, CustomStringConvertible {
        let description: String
        init(_ s: String) { description = s }
    }

    /// Re-points each picked session of the profile. Takes cl_audit's switch lock (`locked`: the caller holds it). `windowClosed` is asked
    /// before each entry is written. A session that can't be re-pointed is said in the receipt's problems; the others go on.
    static func apply(_ t: SessionsRestore.Target, picks: [Pick], restore: String? = nil, mark: String? = nil, locked: Bool = false,
                      windowClosed: () -> Bool, now: Date = Date()) throws -> Receipt {
        var lock: SwitchEngine.Lock?
        if !locked {
            do { lock = try SwitchEngine.Lock.take() } catch { throw RepointError("\(error)") }
        }
        defer { lock?.release() }
        guard !picks.isEmpty else { throw RepointError("No folder was picked.") }
        var r = Receipt(id: SessionsRestore.receiptID(now, t.profile), profile: t.profile, codeDir: t.codeDir, dataDir: t.dataDir, restore: restore, started: now)
        try save(r)
        let byCli = entries(dataDir: t.dataDir)
        let projects = (t.codeDir as NSString).appendingPathComponent("projects")
        let running = SessionsRestore.runningSessions()
        var memoryDone = Set<String>()
        for pick in picks {
            let id = pick.session.lowercased()
            do {
                guard AccountDiscovery.isUUID(id) else { throw RepointError("A session id that isn't one; left as it is.") }
                // where its transcript is now
                guard let found = locate(id, projects: projects) else { throw RepointError("Session \(id.prefix(8)): its transcript isn't in \(tilde(projects)); left as it is.") }
                guard let s = session(id: id, project: found.project, transcript: found.path, entries: byCli[id] ?? []) else {
                    throw RepointError("Session \(id.prefix(8)): its transcript doesn't name a folder that can be read safely; left as it is.")
                }
                let label = s.title.map { "“\($0)”" } ?? "Session \(id.prefix(8))"
                guard let running else { throw RepointError("\(label): it couldn't be checked whether a Claude Code session runs it; left as it is.") }
                try repointOne(s, label: label, picked: pick.folder, t: t, projects: projects, running: running, memoryDone: &memoryDone, mark: mark,
                               windowClosed: windowClosed, now: now, r: &r)
            } catch {
                r.problems.append("\(error)")
                try? save(r)
            }
        }
        r.finished = Date()
        try save(r)
        return r
    }

    static func locate(_ id: String, projects: String) -> (project: String, path: String)? {
        let fm = FileManager.default
        for p in ((try? fm.contentsOfDirectory(atPath: projects)) ?? []).sorted() where SessionsRestore.plainName(p) && !p.hasPrefix(".") {
            let path = (projects as NSString).appendingPathComponent(p) + "/" + id + ".jsonl"
            var st = stat()
            if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { return (p, path) }
        }
        return nil
    }

    /// One session: checks, then the new files, the entries, and last the old files parked and taken away.
    private static func repointOne(_ s: Session, label: String, picked raw: String, t: SessionsRestore.Target, projects: String, running: Set<String>,
                                   memoryDone: inout Set<String>, mark: String?, windowClosed: () -> Bool, now: Date, r: inout Receipt) throws {
        // the picked folder: a real folder (its real path, as Claude Code records it), clean, none of Claude's or cl_audit's own
        guard let real = realpath(raw, nil) else { throw RepointError("\(label): the picked folder \(tilde(raw)) isn't there; left as it is.") }
        let picked = String(cString: real); free(real)
        guard folderHere(picked) else { throw RepointError("\(label): \(tilde(picked)) isn't a folder; left as it is.") }
        guard clean(picked), picked != "/" else { throw RepointError("\(label): the picked folder's path can't be used (control characters, or the top of the disk); left as it is.") }
        let home = (realpath(NSHomeDirectory(), nil)).map { p -> String in defer { free(p) }; return String(cString: p) } ?? NSHomeDirectory()
        let own = [t.codeDir, t.dataDir, Store.folder.path].filter { !$0.isEmpty }
        if picked == home || picked == NSHomeDirectory() || own.contains(where: { inside(picked, $0) }) {
            throw RepointError("\(label): \(tilde(picked)) is Claude's or cl_audit's own folder (or the home folder); pick the project's folder.")
        }
        guard picked != s.folder else { throw RepointError("\(label): it already points at \(tilde(picked)).") }
        let newName = ProjectName.encoded(picked)
        guard newName != s.project else {
            throw RepointError("\(label): Claude Code's name for \(tilde(picked)) is the same as for its old folder (\(newName.prefix(60))), so it can't be moved there; left as it is.")
        }
        // a running Claude Code session holds it (or it was written to a moment ago)
        var tst = stat()
        guard lstat(s.transcript, &tst) == 0, (tst.st_mode & S_IFMT) == S_IFREG, tst.st_nlink == 1 else { throw RepointError("\(label): its transcript isn't a plain file; left as it is.") }
        let age = now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(tst.st_mtimespec.tv_sec)))
        if running.contains(s.id) || age < SessionsRestore.recent { throw RepointError("\(label): a running Claude Code session holds it (or it was written to a moment ago); left as it is.") }
        guard tst.st_size <= maxTranscript else { throw RepointError("\(label): its transcript is over 2 GB; left as it is.") }
        // the session's folder (<id>/): plain files and folders only, at most 20,000 files
        guard let tree = Tree(path: projects) else { throw RepointError("\(label): \(tilde(projects)) can't be opened; left as it is.") }
        guard case .dir(let oldDir) = tree.dir([s.project], create: false) else { throw RepointError("\(label): its project folder can't be opened; left as it is.") }
        defer { close(oldDir) }
        var sub: [(rel: [String], isDir: Bool)] = []
        var sst = stat()
        let hasSub = fstatat(oldDir, s.id, &sst, AT_SYMLINK_NOFOLLOW) == 0
        if hasSub {
            guard (sst.st_mode & S_IFMT) == S_IFDIR else { throw RepointError("\(label): its folder (\(s.id.prefix(8))…/) isn't a plain folder; left as it is.") }
            guard let list = walk(oldDir, [s.id]) else { throw RepointError("\(label): its folder holds a link, something that isn't a plain file, or over 20,000 files; left as it is.") }
            sub = list
        }
        // the new name must be free for it
        let created = tree.dir([newName], create: false)
        if case .dir(let nd) = created {
            defer { close(nd) }
            var x = stat()
            if fstatat(nd, s.id + ".jsonl", &x, AT_SYMLINK_NOFOLLOW) == 0 || fstatat(nd, s.id, &x, AT_SYMLINK_NOFOLLOW) == 0 {
                throw RepointError("\(label): \(tilde(projects))/\(newName.prefix(60))… already has a session of that id; left as it is.")
            }
        } else if case .blocked = created { throw RepointError("\(label): the folder for its new name is a link or can't be opened; left as it is.") }
        // the entries: read now, and every one must be an entry (the window closed before any is written)
        var entryPlans: [(path: String, old: Data, new: Data, dropped: [String])] = []
        let entryDropped = s.entries.isEmpty ? [] : droppedWorktrees(s, picked: picked)
        let map = mapper(folder: s.folder, picked: picked, dropped: entryDropped)
        for p in s.entries {
            guard let d = readCapped(p, limit: maxEntry), let e = entryRepointed(d, folder: s.folder, picked: picked, map: map, here: folderHere) else {
                throw RepointError("\(label): its Code-tab entry can't be read as one; left as it is.")
            }
            entryPlans.append((p, d, e.data, e.dropped))
        }
        if !entryPlans.isEmpty {
            if let m = SwitchMarker.current(FolderKey.canonical(t.dataDir)), !(m.pid == getpid() && m.standby == mark) {
                throw RepointError("\(label): a switch or a restore of the Claude window is under way; left as it is.")
            }
            guard windowClosed() else { throw RepointError("\(label): its Code-tab entry needs the Claude window closed; left as it is.") }
        }
        var done = Done(session: s.id, title: s.title, from: s.folder, to: picked)
        // 1. the new files: the transcript, then its folder
        let tag = String(r.id.prefix(20))
        let newBase = (projects as NSString).appendingPathComponent(newName)
        if case .absent = created { r.steps.append(Step(kind: .dir, session: s.id, path: newBase)); try save(r) }
        guard case .dir(let newDir) = tree.dir([newName], create: true) else {
            if case .absent = created { r.steps.removeLast(); try? save(r) }
            throw RepointError("\(label): the folder for its new name can't be made; nothing was written for it.")
        }
        defer { close(newDir) }
        if case .absent = created { r.steps[r.steps.count - 1].done = true; try save(r) }
        func made(_ path: String, _ write: () throws -> (sha: String, lines: Int, kept: Int)) throws {
            r.steps.append(Step(kind: .made, session: s.id, path: path)); try save(r)
            let i = r.steps.count - 1
            do {
                let w = try write()
                r.steps[i].sha = w.sha; r.steps[i].done = true
                done.lines += w.lines; done.keptLines += w.kept; done.files += 1
                try save(r)
            } catch {
                r.steps.remove(at: i); try? save(r); throw error
            }
        }
        try made(newBase + "/" + s.id + ".jsonl") {
            try copyFile(from: oldDir, [s.id + ".jsonl"], to: newDir, [s.id + ".jsonl"], rewrite: true, tag: tag, map: map)
        }
        if hasSub {
            r.steps.append(Step(kind: .dir, session: s.id, path: newBase + "/" + s.id)); try save(r)
            guard mkdirat(newDir, s.id, 0o700) == 0 else {
                r.steps.removeLast(); try? save(r)
                throw RepointError("\(label): its folder couldn't be made under the new name; what was written for it stays until Undo.")
            }
            r.steps[r.steps.count - 1].done = true; try save(r)
        }
        for item in sub {
            let rel = item.rel
            if item.isDir {
                r.steps.append(Step(kind: .dir, session: s.id, path: newBase + "/" + rel.joined(separator: "/"))); try save(r)
                let i = r.steps.count - 1
                guard mkdirat(newDir, rel.joined(separator: "/"), 0o700) == 0 || errno == EEXIST else {
                    r.steps.remove(at: i); try? save(r)
                    throw RepointError("\(label): a folder for it couldn't be made; what was written for it stays until Undo.")
                }
                r.steps[i].done = true; try save(r)
                continue
            }
            try made(newBase + "/" + rel.joined(separator: "/")) {
                try copyFile(from: oldDir, rel, to: newDir, rel, rewrite: rel.last!.hasSuffix(".jsonl"), tag: tag, map: map)
            }
        }
        // 2. the project's memory files, once per old project folder: copied where missing
        if !memoryDone.contains(s.project + "→" + newName) {
            memoryDone.insert(s.project + "→" + newName)
            var mst = stat()
            if fstatat(oldDir, "memory", &mst, AT_SYMLINK_NOFOLLOW) == 0, (mst.st_mode & S_IFMT) == S_IFDIR, let list = walk(oldDir, ["memory"]) {
                var x = stat()
                if fstatat(newDir, "memory", &x, AT_SYMLINK_NOFOLLOW) != 0 {
                    r.steps.append(Step(kind: .dir, session: s.id, path: newBase + "/memory")); try save(r)
                    if mkdirat(newDir, "memory", 0o700) == 0 { r.steps[r.steps.count - 1].done = true } else { r.steps.removeLast() }
                    try save(r)
                }
                for item in list {
                    let rel = item.rel
                    var e = stat()
                    if fstatat(newDir, rel.joined(separator: "/"), &e, AT_SYMLINK_NOFOLLOW) == 0 { continue }       // there: never replaced
                    if item.isDir {
                        r.steps.append(Step(kind: .dir, session: s.id, path: newBase + "/" + rel.joined(separator: "/"))); try save(r)
                        if mkdirat(newDir, rel.joined(separator: "/"), 0o700) == 0 { r.steps[r.steps.count - 1].done = true } else { r.steps.removeLast() }
                        try save(r)
                        continue
                    }
                    let before = done.files
                    try? made(newBase + "/" + rel.joined(separator: "/")) {
                        try copyFile(from: oldDir, rel, to: newDir, rel, rewrite: false, tag: tag, map: map)
                    }
                    if done.files > before { done.files -= 1; done.memory += 1 }
                }
            }
        }
        // 3. the entries (the window closed, asked again before each)
        for e in entryPlans {
            guard windowClosed() else { throw RepointError("\(label): the Claude window opened; its entry wasn't changed. Undo takes back what was written for it.") }
            let name = SwitchEngine.sha(e.old).prefix(16) + "-entry.json"
            let savedPath = dir(r.id).appendingPathComponent("saved").appendingPathComponent(String(name))
            try writeSaved(e.old, to: savedPath)
            r.steps.append(Step(kind: .entry, session: s.id, path: e.path, sha: SwitchEngine.sha(e.new), saved: String(name))); try save(r)
            let i = r.steps.count - 1
            try replace(e.path, expected: SwitchEngine.sha(e.old), with: e.new, tag: tag)
            r.steps[i].done = true
            done.entries += 1
            for k in e.dropped where !done.dropped.contains(k) { done.dropped.append(k) }
            try save(r)
        }
        // 4. the old files: each copied into the receipt's folder, then taken away (only while it is the file that was read)
        var old: [[String]] = [[s.id + ".jsonl"]]
        old += sub.filter { !$0.isDir }.map(\.rel)
        for rel in old {
            let path = (projects as NSString).appendingPathComponent(s.project) + "/" + rel.joined(separator: "/")
            let name = "\(r.steps.count)-" + (rel.last ?? "file")
            r.steps.append(Step(kind: .parked, session: s.id, path: path, saved: name)); try save(r)
            let i = r.steps.count - 1
            let h = try park(oldDir, rel, to: dir(r.id).appendingPathComponent("saved").path, name: name)
            r.steps[i].sha = h; r.steps[i].done = true
            try save(r)
        }
        for item in sub.filter(\.isDir).reversed() { unlinkat(oldDir, item.rel.joined(separator: "/"), AT_REMOVEDIR) }
        if hasSub { unlinkat(oldDir, s.id, AT_REMOVEDIR) }                 // only when empty
        r.sessions.append(done)
        try save(r)
    }

    /// The worktrees a re-point drops: the entry's worktreePath, or the recorded cwd's worktree, when its place under the picked folder
    /// isn't on this Mac.
    static func droppedWorktrees(_ s: Session, picked: String) -> [String] {
        var out: [String] = []
        for w in [s.worktree, worktreeFolder(of: s.recorded)].compactMap({ $0 }) where !out.contains(w) {
            let m = mapper(folder: s.folder, picked: picked, dropped: [])(w)
            if m == nil || !folderHere(m!) { out.append(w) }
        }
        return out
    }

    /// A folder's tree under `rel` of `base`: folders first, then their files, plain ones only (one link); nil when it holds anything
    /// else (a link, a device …) or more than 20,000 files.
    static func walk(_ base: Int32, _ rel: [String]) -> [(rel: [String], isDir: Bool)]? {
        var out: [(rel: [String], isDir: Bool)] = []
        func visit(_ path: [String], depth: Int) -> Bool {
            guard depth < 24 else { return false }
            let fd = openat(base, path.joined(separator: "/"), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0, let d = fdopendir(fd) else { return false }
            defer { closedir(d) }
            var names: [String] = []
            while let ent = readdir(d) {
                let n = withUnsafeBytes(of: ent.pointee.d_name) { String(decoding: $0.prefix(Int(ent.pointee.d_namlen)), as: UTF8.self) }
                if n == "." || n == ".." { continue }
                names.append(n)
            }
            for n in names.sorted() {
                guard SessionsRestore.plainName(n) else { return false }
                var st = stat()
                guard fstatat(dirfd(d), n, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    out.append((path + [n], true))
                    guard visit(path + [n], depth: depth + 1) else { return false }
                case S_IFREG:
                    guard st.st_nlink == 1 else { return false }
                    out.append((path + [n], false))
                    if out.count > maxFiles { return false }
                default: return false
                }
            }
            return true
        }
        guard visit(rel, depth: 0) else { return nil }
        return out                                              // each path from `base`, `rel` included
    }

    // MARK: writing

    /// A copy of a file (`rel` under `src`) as a new file (`dst` under `dir`): a .jsonl's lines rewritten when `rewrite`, every other
    /// byte as it was; written under a temp name, given the old file's dates, then linked into place (never over a name that exists).
    static func copyFile(from src: Int32, _ rel: [String], to dir: Int32, _ dst: [String], rewrite: Bool, tag: String, map: (String) -> String?) throws -> (sha: String, lines: Int, kept: Int) {
        let fd = openat(src, rel.joined(separator: "/"), O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RepointError("\(rel.last ?? "a file") couldn't be opened; what was written stays until Undo.") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_size <= maxTranscript else {
            throw RepointError("\(rel.last ?? "a file") isn't a plain file; what was written stays until Undo.")
        }
        // the folder the new file goes in
        let parentRel = dst.dropLast().joined(separator: "/")
        let pfd = parentRel.isEmpty ? dup(dir) : openat(dir, parentRel, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard pfd >= 0 else { throw RepointError("A folder for \(dst.last ?? "a file") isn't a plain folder; what was written stays until Undo.") }
        defer { close(pfd) }
        let leaf = dst.last!
        let tmp = ".repoint-\(tag)-\(UUID().uuidString.prefix(8)).tmp"
        let out = openat(pfd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard out >= 0 else { throw RepointError("\(leaf) couldn't be written (\(String(cString: strerror(errno)))); what was written stays until Undo.") }
        var closed = false
        defer { if !closed { close(out) }; unlinkat(pfd, tmp, 0) }
        var hash = SHA256()
        var pending = [UInt8]()
        pending.reserveCapacity(1 << 20)
        var failed = false
        func flush() {
            guard !pending.isEmpty, !failed else { pending.removeAll(keepingCapacity: true); return }
            let n = pending.withUnsafeBytes { Darwin.write(out, $0.baseAddress, $0.count) }
            if n != pending.count { failed = true }
            hash.update(data: pending)
            pending.removeAll(keepingCapacity: true)
        }
        func emit<C: Collection>(_ bytes: C) where C.Element == UInt8 {
            pending.append(contentsOf: bytes)
            if pending.count >= 1 << 20 { flush() }
        }
        var lines = 0, kept = 0
        var line = [UInt8]()
        var passing = false                                     // a line over 64 MB: copied as it streams
        func endLine(_ newline: Bool) {
            if passing { if newline { emit([0x0A]) }; passing = false; return }
            if let r = SessionsRepoint.rewrite(line: line, map: map) { emit(r); lines += 1 } else { emit(line) }
            if newline { emit([0x0A]) }
            line.removeAll(keepingCapacity: true)
        }
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var off: off_t = 0
        while true {
            let n = pread(fd, &buf, buf.count, off)
            if n < 0 { throw RepointError("\(rel.last ?? "a file") couldn't be read; what was written stays until Undo.") }
            if n == 0 { break }
            off += off_t(n)
            if !rewrite { emit(buf[0..<n]); continue }
            var start = 0
            while start < n {
                let chunk = buf[start..<n]
                if let nl = chunk.firstIndex(of: 0x0A) {
                    if passing { emit(buf[start..<nl]) } else { line.append(contentsOf: buf[start..<nl]) }
                    endLine(true)
                    start = nl + 1
                } else {
                    if passing { emit(chunk) } else { line.append(contentsOf: chunk) }
                    start = n
                }
                if !passing, line.count > maxLine { kept += 1; emit(line); line.removeAll(keepingCapacity: true); passing = true }
            }
        }
        if rewrite, passing || !line.isEmpty { endLine(false) }
        flush()
        guard !failed, off == st.st_size else { throw RepointError("\(leaf) couldn't be written whole (the disk may be full); what was written stays until Undo.") }
        fsync(out)
        var times = [st.st_atimespec, st.st_mtimespec]
        futimens(out, &times)
        close(out); closed = true
        guard linkat(pfd, tmp, pfd, leaf, 0) == 0 else {
            throw RepointError(errno == EEXIST ? "\(leaf) appeared meanwhile; what was written stays until Undo." : "\(leaf) couldn't be put in place; what was written stays until Undo.")
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), lines, kept)
    }

    /// A small file in the receipt's folder (an entry as it was): never over one, never through a link.
    private static func writeSaved(_ d: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RepointError("cl_audit's receipt folder can't be written (\(String(cString: strerror(errno)))); nothing more was changed.") }
        defer { close(fd) }
        let ok = d.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) == d.count }
        guard ok, fsync(fd) == 0 else { throw RepointError("cl_audit's receipt folder can't be written; nothing more was changed.") }
    }

    /// An entry replaced: a temp file beside it, renamed over it, only while it is still what was read (`expected`).
    static func replace(_ path: String, expected: String, with data: Data, tag: String) throws {
        let parent = (path as NSString).deletingLastPathComponent, leaf = (path as NSString).lastPathComponent
        let pfd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard pfd >= 0 else { throw RepointError("The entry's folder can't be opened; it wasn't changed.") }
        defer { close(pfd) }
        let fd = openat(pfd, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RepointError("\(leaf) can't be opened; it wasn't changed.") }
        var st = stat()
        let ok = fstat(fd, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && st.st_nlink == 1 && SessionsRestore.sha(fd: fd) == expected
        close(fd)
        guard ok else { throw RepointError("\(leaf) changed meanwhile; it wasn't changed.") }
        let tmp = ".repoint-\(tag)-\(UUID().uuidString.prefix(8)).tmp"
        let out = openat(pfd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard out >= 0 else { throw RepointError("\(leaf) couldn't be written; it wasn't changed.") }
        let wrote = data.withUnsafeBytes { Darwin.write(out, $0.baseAddress, $0.count) == data.count }
        fsync(out); close(out)
        guard wrote, renameat(pfd, tmp, pfd, leaf) == 0 else { unlinkat(pfd, tmp, 0); throw RepointError("\(leaf) couldn't be written; it wasn't changed.") }
    }

    /// An old file copied into the receipt's folder (a clone where it can be), then taken away while it is still that file. Its hash.
    private static func park(_ dir: Int32, _ rel: [String], to savedDir: String, name: String) throws -> String {
        let fd = openat(dir, rel.joined(separator: "/"), O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RepointError("\(rel.last ?? "an old file") couldn't be opened; it stays where it was (Undo takes back the new copy).") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else { throw RepointError("\(rel.last ?? "an old file") isn't a plain file; it stays where it was.") }
        let sfd = open(savedDir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard sfd >= 0 else { throw RepointError("cl_audit's receipt folder can't be opened; the old files stay where they were.") }
        defer { close(sfd) }
        guard case .created(let h) = SessionsRestore.cloneNew(from: fd, st: st, expected: nil, sfd, name) else {
            throw RepointError("\(rel.last ?? "an old file") couldn't be kept in cl_audit's receipt folder; it stays where it was.")
        }
        // taken away only while the name is still the file that was copied, unchanged
        let parentRel = rel.dropLast().joined(separator: "/")
        let pfd = parentRel.isEmpty ? dup(dir) : openat(dir, parentRel, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard pfd >= 0 else { return h }
        defer { close(pfd) }
        var again = stat()
        guard fstatat(pfd, rel.last!, &again, AT_SYMLINK_NOFOLLOW) == 0, again.st_ino == st.st_ino, again.st_dev == st.st_dev,
              again.st_size == st.st_size, again.st_mtimespec.tv_sec == st.st_mtimespec.tv_sec, again.st_mtimespec.tv_nsec == st.st_mtimespec.tv_nsec,
              SessionsRestore.sha(fd: fd) == h else {
            throw RepointError("\(rel.last ?? "an old file") changed meanwhile; it stays where it was.")
        }
        unlinkat(pfd, rel.last!, 0)
        return h
    }

    // MARK: Undo

    /// Takes back exactly what the receipt did, session by session: only a session whose new files and entries are unchanged since (a
    /// resumed one stays re-pointed, said). The old files and entries come back first, then the new ones go. `windowClosed` is asked
    /// before each entry.
    @discardableResult
    static func undo(_ id: String, locked: Bool = false, windowClosed: () -> Bool) throws -> Receipt {
        var lock: SwitchEngine.Lock?
        if !locked {
            do { lock = try SwitchEngine.Lock.take() } catch { throw RepointError("\(error)") }
        }
        defer { lock?.release() }
        guard var r = load(id) else { throw RepointError("No receipt for that re-point.") }
        guard r.undone == nil else { return r }
        let sessions = r.steps.map(\.session).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let running = SessionsRestore.runningSessions() ?? []
        for sid in sessions.reversed() {
            let idx = r.steps.indices.filter { r.steps[$0].session == sid && !r.steps[$0].settled }
            if idx.isEmpty { continue }
            // every new file and entry still as written?
            var why: String?
            if running.contains(sid) { why = "a running Claude Code session holds it" }
            for i in idx where why == nil {
                let s = r.steps[i]
                switch s.kind {
                case .made where s.done:
                    if let have = fileSHA(s.path), have != s.sha { why = "\((s.path as NSString).lastPathComponent) changed since (it was resumed)" }
                case .entry where s.done:
                    if fileSHA(s.path) != s.sha { why = "its Code-tab entry changed since" }
                default: break
                }
            }
            if idx.contains(where: { r.steps[$0].kind == .entry && r.steps[$0].done }), why == nil, !windowClosed() {
                try? save(r)
                throw RepointError("Quit the profile's Claude window first, then Undo.")
            }
            if let why {
                if let k = r.sessions.firstIndex(where: { $0.session == sid }) { r.sessions[k].left = why }
                r.problems.append("\(r.sessions.first { $0.session == sid }?.title.map { "“\($0)”" } ?? "Session \(sid.prefix(8))") stays re-pointed: \(why).")
                for i in idx { r.steps[i].settled = true }
                try save(r)
                continue
            }
            // 1. the old files back (create-only, from the copies kept)
            for i in idx where r.steps[i].kind == .parked {
                let s = r.steps[i]
                guard let saved = s.saved, SessionsRestore.plainName(saved) else { r.steps[i].settled = true; continue }
                var x = stat()
                if lstat(s.path, &x) != 0 {                                      // (there: never taken away, or back already)
                    let kept = dir(r.id).appendingPathComponent("saved").appendingPathComponent(saved).path
                    if lstat(kept, &x) == 0 {
                        do { try restoreParked(kept, to: s.path, codeDir: r.codeDir, expected: s.sha) }
                        catch { try? save(r); throw error }
                    }
                }
                r.steps[i].settled = true
            }
            try save(r)
            // 2. the entries back
            for i in idx.reversed() where r.steps[i].kind == .entry {
                let s = r.steps[i]
                guard let saved = s.saved, let sha = s.sha, let old = readCapped(dir(r.id).appendingPathComponent("saved").appendingPathComponent(saved).path, limit: maxEntry) else { r.steps[i].settled = true; continue }
                guard windowClosed() else { try? save(r); throw RepointError("The profile's Claude window opened during the undo; stopped. Undo again once it is closed.") }
                if fileSHA(s.path) == sha { try replace(s.path, expected: sha, with: old, tag: String(r.id.prefix(20))) }
                r.steps[i].settled = true
                try save(r)
            }
            // 3. the new files go, then the folders it made (only when empty)
            for i in idx.reversed() where r.steps[i].kind == .made {
                let s = r.steps[i]
                if let sha = s.sha, fileSHA(s.path) == sha { unlinkIfSame(s.path, sha: sha) }
                r.steps[i].settled = true
            }
            for i in idx.reversed() where r.steps[i].kind == .dir {
                rmdir(r.steps[i].path)
                r.steps[i].settled = true
            }
            if let k = r.sessions.firstIndex(where: { $0.session == sid }) { r.sessions[k].undone = true }
            try save(r)
        }
        r.undone = Date()
        try save(r)
        return r
    }

    /// Undo of every re-point that follows an import's restore (the import's Undo does this first).
    static func undoLinked(restore id: String, windowClosed: () -> Bool) throws -> [String] {
        var problems: [String] = []
        for r in linked(restore: id) { problems += try undo(r.id, locked: true, windowClosed: windowClosed).problems }
        return problems
    }

    static func fileSHA(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return SessionsRestore.sha(fd: fd)
    }

    private static func unlinkIfSame(_ path: String, sha: String) {
        let parent = (path as NSString).deletingLastPathComponent, leaf = (path as NSString).lastPathComponent
        let pfd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard pfd >= 0 else { return }
        defer { close(pfd) }
        let fd = openat(pfd, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return }
        var a = stat(), b = stat()
        let same = fstat(fd, &a) == 0 && (a.st_mode & S_IFMT) == S_IFREG && a.st_nlink == 1 && SessionsRestore.sha(fd: fd) == sha
        close(fd)
        guard same, fstatat(pfd, leaf, &b, AT_SYMLINK_NOFOLLOW) == 0, a.st_ino == b.st_ino, a.st_dev == b.st_dev else { return }
        unlinkat(pfd, leaf, 0)
    }

    /// A parked file put back where it was: its folders made again when they are gone (under the Claude Code folder only, never through a
    /// link), the file a clone of the kept copy (create-only, its dates as they were).
    private static func restoreParked(_ saved: String, to path: String, codeDir: String, expected: String?) throws {
        guard let rel = SessionsRestore.relative(path, under: codeDir), let tree = Tree(path: codeDir) else { throw RepointError("\((path as NSString).lastPathComponent) isn't under the Claude Code folder; left in cl_audit's receipt folder.") }
        guard case .dir(let pfd) = tree.dir(Array(rel.dropLast()), create: true) else { throw RepointError("A folder for \((path as NSString).lastPathComponent) is a link or can't be made; left in cl_audit's receipt folder.") }
        defer { close(pfd) }
        let fd = open(saved, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RepointError("The kept copy of \((path as NSString).lastPathComponent) is gone; it couldn't be put back.") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw RepointError("The kept copy of \((path as NSString).lastPathComponent) isn't a plain file.") }
        switch SessionsRestore.cloneNew(from: fd, st: st, expected: expected, pfd, rel.last!) {
        case .created, .exists: return
        case .differs: throw RepointError("\((path as NSString).lastPathComponent) didn't come back as it was; look at it.")
        case .failed(let why): throw RepointError("\((path as NSString).lastPathComponent) couldn't be put back (\(why)).")
        }
    }

    typealias Tree = SessionsRestore.Tree
}

// MARK: - the pages' words

enum RepointWords {
    static func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }

    /// "Fix the sign-up form · ~/code/garden-app"
    static func title(_ s: SessionsRepoint.Session) -> String { s.title ?? "Session \(s.id.prefix(8))" }

    static func done(_ d: SessionsRepoint.Done) -> String {
        var parts = ["now in \(tilde(d.to))"]
        if d.lines > 0 { parts.append(n(d.lines, "line", "lines") + " re-pointed") }
        if d.entries > 0 { parts.append(n(d.entries, "Code-tab entry", "Code-tab entries") + " changed") }
        if d.dropped.contains("worktreePath") { parts.append("its worktree isn't on this Mac, so it runs in the project folder") }
        if d.memory > 0 { parts.append(n(d.memory, "memory file", "memory files") + " copied") }
        return parts.joined(separator: " · ")
    }
}
