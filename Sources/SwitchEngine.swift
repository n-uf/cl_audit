// SwitchEngine: moving a profile's Claude window sessions from the account in use to another of its accounts, on this
// Mac (Switch.swift is what the page shows; SwitchView.swift the page). The rules are claude-transplant's:
//
// - only with that window closed (the Claude app rewrites its session entries from memory), checked again before each
//   entry and before the tasks and pointer steps; while a switch is under way no window opener starts it (SwitchMarker);
// - one switch at a time (cl_audit's lock), and none while claude-transplant runs: its own lock (a flock) is held for the
//   whole run;
// - every entry keeps its id: kept byte for byte, or re-encoded without the old account's error keys and Remote Control
//   ids when it has them, through a write that can't overwrite (a private temp file, then a hard link), checked, and
//   only then is the original parked in cl_audit's own folder: nothing is deleted;
// - the scheduled tasks move with them: both task files are backed up, the source is emptied first, then the target
//   gets them (a stop in between leaves them in neither, never in both, and Undo puts them back);
// - a session whose transcript points at the old account's Remote Control copy gets Claude Code's own empty pointer
//   line, appended in one O_APPEND write, and only when nothing else is writing that transcript; Undo takes it off
//   again if it's still the transcript's last bytes;
// - the receipt says what each step will do before it's done (paths, hashes, backups) and marks it done after, so Undo
//   puts back whatever got done, also after a stop or a crash (only what is unchanged since). Receipts name accounts by
//   their ids only, never by address.
//
// The sidebar's groups, order and pins are synced to claude.ai per account, so they're not written here: the receipt
// notes them (SwitchSidebar.swift), and the window on the new account rebuilds them with its own sidebar tools.

import CryptoKit
import Foundation

/// What a switch would do, read without changing anything.
struct SwitchPlan: Equatable {
    var profile: String
    var standby: String
    var dataDir: String                 // the window's data folder (expanded)
    var codeDir: String                 // the profile's Claude Code folder (expanded): the Code sessions' transcripts
    var from: Seat
    var to: Seat
    var move: [String] = []             // entries to move ("local_<id>.json")
    var already: [String] = []          // the target has that id already: left where they are
    var deleted: [String] = []          // the target deleted a session with that id: left where they are
    var tasks = 0                       // scheduled tasks to move
    var sessionsFollow = true

    var sourceDir: String { SwitchEngine.scopeDir(dataDir, SeatID(from)) }
    var targetDir: String { SwitchEngine.scopeDir(dataDir, SeatID(to)) }
}

/// An account and organisation by their ids only: what a receipt keeps.
struct SeatID: Codable, Equatable, Hashable {
    var account: String
    var organization: String

    init(_ s: Seat) { account = s.account; organization = s.organization ?? "" }
    init(account: String, organization: String) { self.account = account; self.organization = organization }

    func same(_ s: Seat?) -> Bool { s.map { $0.account == account && ($0.organization ?? "") == organization } ?? false }
}

/// The record of one switch, in cl_audit's folder (switches/<id>/receipt.json), saved before and after every step.
struct SwitchReceipt: Codable, Equatable {
    var id: String
    var profile: String
    var standby: String
    var dataDir: String
    var from: SeatID
    var to: SeatID
    var started: Date
    var finished: Date?                 // every step done
    var linked: Date?                   // the profile works on the new account: from then on, the way back is a switch
    var undone: Date?
    var steps: [Step] = []
    var problems: [String] = []
    /// The moved sessions' groups and pins on the old account, noted before the move (SwitchSidebar.swift).
    var sidebar: SidebarPlan?

    /// Something was moved, and the switch was neither linked nor undone: Undo still applies.
    var unfinished: Bool { undone == nil && linked == nil && !steps.isEmpty }
    var moved: Int { steps.filter { $0.kind == .entry && $0.done }.count }

    struct Step: Codable, Equatable {
        enum Kind: String, Codable { case entry, tasks, pointer }
        var kind: Kind
        var path: String                // entry: where it's placed; tasks: the task file; pointer: the transcript
        var sha: String?                // SHA-256 of what this step leaves there (pointer: of the bytes appended)
        var parked: String?             // entry: where its original goes; tasks: the backup of the file before
        var original: String?           // entry: where the original was
        var existed = true              // tasks: the file was there before
        var offset: UInt64? = nil       // pointer: where the appended bytes start (nil once unknown)
        var bytes: String? = nil        // pointer: the appended bytes, base64
        var dev: UInt64? = nil          // pointer: the transcript's identity
        var ino: UInt64? = nil
        var done = false                // written down before acting, marked done after
    }
}

enum SwitchError: Error, Equatable, CustomStringConvertible {
    case notReady(String), busy(String), windowOpen, failed(String)
    var description: String {
        switch self {
        case .notReady(let s), .busy(let s), .failed(let s): return s
        case .windowOpen: return "The profile's Claude window opened during the switch; stopped. Undo puts back what moved."
        }
    }
}

enum SwitchEngine {
    /// The window's folder of sessions for one account and organisation.
    static func scopeDir(_ dataDir: String, _ s: SeatID) -> String {
        (expand(dataDir) as NSString).appendingPathComponent("claude-code-sessions/\(s.account)/\(s.organization)")
    }

    /// Where switches keep their receipts, parked originals and backups.
    static var root: URL { Store.folder.appendingPathComponent("switches") }

    // MARK: the plan (read-only)

    /// `follow`: the Switch page's answer to "Move them?" (asked every time); nil only for older callers (the profile's
    /// old Sessions follow setting).
    static func plan(_ e: AccountEntry, standby s: StandbyAccount, dataDir: String? = nil, follow: Bool? = nil) -> Result<SwitchPlan, SwitchError> {
        let follow = follow ?? e.sessionsFollow
        guard let from = e.seat, from.organization != nil else { return .failure(.notReady("The account in use isn't linked yet.")) }
        guard let to = s.seat, to.organization != nil else { return .failure(.notReady("\(s.email) isn't linked yet: sign in to it first.")) }
        // the ids name folders: only real ids (never a path)
        guard [from.account, from.organization!, to.account, to.organization!].allSatisfy(AccountDiscovery.isUUID) else {
            return .failure(.notReady("An account id isn't one Claude would use; nothing is moved."))
        }
        guard !from.same(to) else { return .failure(.notReady("That's the account in use.")) }
        let dir = dataDir ?? (e.desktop == .standard ? expand(FolderKey.standardDataDir) : Account(e).claudeUserDataDir ?? "")
        guard !dir.isEmpty else { return .failure(.notReady("The profile's Claude window has no folder.")) }
        var p = SwitchPlan(profile: e.id, standby: s.id, dataDir: expand(dir), codeDir: Account(e).configDir, from: from, to: to,
                           sessionsFollow: follow)
        guard follow else { return .success(p) }
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: p.sourceDir)) ?? []).filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }.sorted()
        for n in names {
            let id = String(n.dropFirst("local_".count).dropLast(".json".count))
            if fm.fileExists(atPath: (p.targetDir as NSString).appendingPathComponent(n)) { p.already.append(n) }
            else if fm.fileExists(atPath: (p.targetDir as NSString).appendingPathComponent("deleted_\(id)")) { p.deleted.append(n) }
            else { p.move.append(n) }
        }
        p.tasks = tasks(in: p.sourceDir).count
        return .success(p)
    }

    // MARK: running it

    /// Moves what the plan says. `windowClosed` is asked first and before every step: the window must stay closed. If
    /// it stops (the window opened, a write failed), the receipt stays as it is, unfinished, for Undo.
    @discardableResult
    static func run(_ p: SwitchPlan, windowClosed: () -> Bool, now: Date = Date()) throws -> SwitchReceipt {
        let lock = try Lock.take()
        defer { lock.release() }
        guard windowClosed() else { throw SwitchError.notReady("The profile's Claude window is open; nothing moved.") }
        var r = SwitchReceipt(id: receiptID(now, p.profile), profile: p.profile, standby: p.standby, dataDir: p.dataDir,
                              from: SeatID(p.from), to: SeatID(p.to), started: now)
        let dir = root.appendingPathComponent(r.id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("parked"), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try save(r)
        do {
            try moveAll(p, &r, dir: dir, windowClosed: windowClosed)
        } catch {
            r.problems.append("\(error)")
            try? save(r)
            throw error
        }
        r.finished = Date()
        try save(r)
        return r
    }

    private static func moveAll(_ p: SwitchPlan, _ r: inout SwitchReceipt, dir: URL, windowClosed: () -> Bool) throws {
        guard p.sessionsFollow else { return }
        let hasTasks = !tasks(in: p.sourceDir).isEmpty
        if !p.move.isEmpty || hasTasks { try FileManager.default.createDirectory(atPath: p.targetDir, withIntermediateDirectories: true) }
        if !p.move.isEmpty {
            // their groups and pins, from the window's mirror (the window is closed, so it's current), before anything moves
            r.sidebar = p.sidebar()
            try save(r)
        }
        for name in p.move {
            guard windowClosed() else { throw SwitchError.windowOpen }
            do { try moveEntry(name, p, parked: dir.appendingPathComponent("parked"), &r) }
            catch { r.problems.append("\(name) didn't move: \(error)."); try save(r) }
        }
        // the scheduled tasks, also when there's no session to move
        guard windowClosed() else { throw SwitchError.windowOpen }
        if !tasks(in: p.sourceDir).isEmpty { try moveTasks(p, backups: dir, &r) }
        let placed = r.steps.filter { $0.kind == .entry && $0.done }.map(\.path)
        for path in placed {
            guard windowClosed() else { throw SwitchError.windowOpen }
            clearPointer(entryPath: path, p, &r)
        }
    }

    /// The old account's error keys go; its Remote Control ids are cleared. An entry with neither is kept byte for byte.
    static let accountErrorKeys = ["error", "errorAt", "priorErrorMark"]

    static func placed(_ original: Data) throws -> Data {
        guard var j = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw SwitchError.failed("not a session entry") }
        let errors = accountErrorKeys.filter { j[$0] != nil }
        let bridges = (j["bridgeSessionIds"] as? [Any]).map { !$0.isEmpty } ?? false
        guard !errors.isEmpty || bridges else { return original }
        for k in errors { j.removeValue(forKey: k) }
        if bridges { j["bridgeSessionIds"] = [String]() }
        return try JSONSerialization.data(withJSONObject: j, options: [.withoutEscapingSlashes])
    }

    /// One entry: written down, placed, checked, then its original parked. A check that fails after placing takes the
    /// placed copy away again, so the session is never in both accounts.
    private static func moveEntry(_ name: String, _ p: SwitchPlan, parked: URL, _ r: inout SwitchReceipt) throws {
        let fm = FileManager.default
        let src = (p.sourceDir as NSString).appendingPathComponent(name)
        let dst = (p.targetDir as NSString).appendingPathComponent(name)
        let original = try Data(contentsOf: URL(fileURLWithPath: src))
        let data = try placed(original)
        let park = parked.appendingPathComponent(name).path
        r.steps.append(SwitchReceipt.Step(kind: .entry, path: dst, sha: sha(data), parked: park, original: src))
        let i = r.steps.count - 1
        try save(r)                                            // what it will do, before anything is written
        do {
            try writeNew(dst, data)
        } catch {
            r.steps.remove(at: i); try save(r); throw error   // nothing placed
        }
        do {
            guard (try? Data(contentsOf: URL(fileURLWithPath: dst))) == data else { throw SwitchError.failed("the placed entry didn't read back the same") }
            // the source checked unchanged, then parked (never deleted)
            guard (try? Data(contentsOf: URL(fileURLWithPath: src))) == original else { throw SwitchError.failed("the original changed during the switch") }
            try fm.moveItem(atPath: src, toPath: park)
        } catch {
            if (try? Data(contentsOf: URL(fileURLWithPath: dst))).map(sha) == sha(data), (try? fm.removeItem(atPath: dst)) != nil {
                r.steps.remove(at: i)                          // the copy taken away: as if never placed
            } else if fm.fileExists(atPath: dst) && fm.fileExists(atPath: src) {
                r.problems.append("\(name) is in both accounts: its copy couldn't be taken away. Undo takes it away.")
            }
            try save(r)
            throw error
        }
        r.steps[i].done = true
        try save(r)
    }

    /// A new file, never over an existing one: written to a private temp file beside it, then linked into place.
    static func writeNew(_ path: String, _ data: Data) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = (dir as NSString).appendingPathComponent(".\((path as NSString).lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SwitchError.failed("couldn't write in \(tilde(dir))")
        }
        defer { unlink(tmp) }
        guard link(tmp, path) == 0 else { throw SwitchError.failed(errno == EEXIST ? "\((path as NSString).lastPathComponent) is already there" : "couldn't place \((path as NSString).lastPathComponent)") }
    }

    // MARK: scheduled tasks

    static func tasks(in scopeDir: String) -> [[String: Any]] {
        registry(scopeDir)?["scheduledTasks"] as? [[String: Any]] ?? []
    }

    private static func registry(_ scopeDir: String) -> [String: Any]? {
        let f = (scopeDir as NSString).appendingPathComponent("scheduled-tasks.json")
        guard let d = FileManager.default.contents(atPath: f) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// The source's tasks join the target's (a task the target already has by its id stays the target's); the source
    /// keeps none. Both files are backed up and both steps written down first; the source is emptied before the target
    /// gets them, so a stop in between never leaves a task in both accounts (it would run twice).
    private static func moveTasks(_ p: SwitchPlan, backups: URL, _ r: inout SwitchReceipt) throws {
        let fm = FileManager.default
        let srcFile = (p.sourceDir as NSString).appendingPathComponent("scheduled-tasks.json")
        let dstFile = (p.targetDir as NSString).appendingPathComponent("scheduled-tasks.json")
        var source = registry(p.sourceDir) ?? [:]
        var target = registry(p.targetDir) ?? ["scheduledTasks": [[String: Any]]()]
        let moving = source["scheduledTasks"] as? [[String: Any]] ?? []
        var have = target["scheduledTasks"] as? [[String: Any]] ?? []
        let ids = Set(have.compactMap { $0["id"] as? String })
        have += moving.filter { ($0["id"] as? String).map { !ids.contains($0) } ?? true }
        target["scheduledTasks"] = have
        source["scheduledTasks"] = [[String: Any]]()
        var writes: [(file: String, data: Data, step: Int)] = []
        for (file, json, tag) in [(srcFile, source, "source"), (dstFile, target, "target")] {
            let existed = fm.fileExists(atPath: file)
            let backup = backups.appendingPathComponent("scheduled-tasks.\(tag).json").path
            if existed { try? fm.removeItem(atPath: backup); try fm.copyItem(atPath: file, toPath: backup) }
            let data = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
            r.steps.append(SwitchReceipt.Step(kind: .tasks, path: file, sha: sha(data), parked: existed ? backup : nil, existed: existed))
            writes.append((file, data, r.steps.count - 1))
        }
        try save(r)                                            // both written down before either file changes
        for w in writes {
            try w.data.write(to: URL(fileURLWithPath: w.file), options: .atomic)
            r.steps[w.step].done = true
            try save(r)
        }
    }

    // MARK: the Remote Control pointer

    /// Claude Code's own empty pointer line, appended when a moved session's transcript last points at a Remote Control
    /// copy of another account, so the old pointer can't hide the session on the new one. Only when nothing else is
    /// writing that transcript (see `busy`); one O_APPEND write; written down with where it went, for Undo.
    static func clearPointer(entryPath: String, _ p: SwitchPlan, _ r: inout SwitchReceipt, now: Date = Date()) {
        guard let d = FileManager.default.contents(atPath: entryPath),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let cli = j["cliSessionId"] as? String, !cli.isEmpty,
              let transcript = transcriptPath(cli, codeDir: p.codeDir),
              let last = lastPointer(transcript),
              let bridge = last["bridgeSessionId"] as? String, !bridge.isEmpty,
              (last["ownerAccountUuid"] as? String) != p.to.account else { return }
        if let why = busy(transcript, cli: cli, now: now) {
            r.problems.append("Session \(cli): \(why), so its Remote Control pointer is left as it is.")
            try? save(r)
            return
        }
        let fd = open(transcript, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return }
        let size = UInt64(st.st_size)
        let pointer: [String: Any] = ["type": "bridge-session", "sessionId": cli, "bridgeSessionId": "", "lastSequenceNum": 0]
        guard let line = try? JSONSerialization.data(withJSONObject: pointer, options: [.sortedKeys]) else { return }
        // a transcript that doesn't end its last line gets one first, in the same write
        let bytes = (endsWithNewline(transcript, size: size) ? Data() : Data("\n".utf8)) + line + Data("\n".utf8)
        r.steps.append(SwitchReceipt.Step(kind: .pointer, path: transcript, sha: sha(bytes), parked: nil, original: nil,
                                          offset: size, bytes: bytes.base64EncodedString(), dev: UInt64(st.st_dev), ino: UInt64(st.st_ino)))
        let i = r.steps.count - 1
        do { try save(r) } catch {                             // not written down: not written
            r.steps.remove(at: i)
            r.problems.append("Session \(cli): its Remote Control pointer is left as it is (the receipt couldn't be saved).")
            return
        }
        let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var after = stat()
        guard n == bytes.count else {
            r.problems.append("Session \(cli): its pointer line wasn't written whole.")
            r.steps[i].offset = nil; try? save(r); return
        }
        // where it landed: right after what was there, unless someone else wrote meanwhile (Undo then leaves it)
        if fstat(fd, &after) != 0 || UInt64(after.st_size) != size + UInt64(bytes.count) { r.steps[i].offset = nil }
        r.steps[i].done = true
        try? save(r)
    }

    /// Why a transcript may be being written, or nil: changed in the last 10 seconds, open in a process, or a Claude Code
    /// process runs that session. A check that can't finish counts as busy.
    ///
    /// pgrep sees a Claude Code process only when the session id is on its command line (`--resume <id>`,
    /// `--session-id <id>`); one resumed from its own picker, or with `--continue`, isn't seen. The transcript's age and
    /// its open files are checked for those, and the line is one O_APPEND write either way.
    static func busy(_ transcript: String, cli: String, now: Date = Date()) -> String? {
        if let m = (try? FileManager.default.attributesOfItem(atPath: transcript))?[.modificationDate] as? Date,
           now.timeIntervalSince(m) < 10 { return "its transcript changed seconds ago" }
        // lsof -S 2: its own time limit for kernel calls (-b isn't used: it can't then find a file named by path)
        switch probe("/usr/sbin/lsof", ["-S", "2", "-t", "--", transcript]) {
        case .found: return "its transcript is open in another program"
        case .unknown: return "it couldn't be checked whether its transcript is open"
        case .none: break
        }
        switch probe("/usr/bin/pgrep", ["-f", "--", cli]) {
        case .found: return "Claude Code runs it"
        case .unknown: return "it couldn't be checked whether Claude Code runs it"
        case .none: break
        }
        return nil
    }

    enum Probe { case found, none, unknown }

    /// Whether a command finds something (exit 0), within `limit` seconds: past it, only that command (cl_audit's own
    /// child) is stopped, and the answer is unknown.
    static func probe(_ tool: String, _ args: [String], limit: TimeInterval = 5) -> Probe {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return .unknown }
        let deadline = Date().addingTimeInterval(limit)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning {
            p.terminate()
            let grace = Date().addingTimeInterval(1)
            while p.isRunning && Date() < grace { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
            return .unknown
        }
        return p.terminationStatus == 0 ? .found : .none
    }

    private static func endsWithNewline(_ path: String, size: UInt64) -> Bool {
        guard size > 0, let h = FileHandle(forReadingAtPath: path) else { return true }
        defer { try? h.close() }
        try? h.seek(toOffset: size - 1)
        return h.readData(ofLength: 1) == Data("\n".utf8)
    }

    /// <Claude Code folder>/projects/<project>/<cli id>.jsonl
    static func transcriptPath(_ cli: String, codeDir: String) -> String? {
        guard cli.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }   // a file name, never a path
        let projects = (expand(codeDir) as NSString).appendingPathComponent("projects")
        for p in (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? [] {
            let f = (projects as NSString).appendingPathComponent("\(p)/\(cli).jsonl")
            if FileManager.default.fileExists(atPath: f) { return f }
        }
        return nil
    }

    /// The last Remote Control pointer line in a transcript (read from its end), or nil.
    static func lastPointer(_ path: String) -> [String: Any]? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let span: UInt64 = min(size, 4 << 20)
        try? h.seek(toOffset: size - span)
        let tail = h.readData(ofLength: Int(span))
        for line in String(decoding: tail, as: UTF8.self).split(separator: "\n").reversed()
        where line.contains("\"bridge-session\"") {
            if let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], j["type"] as? String == "bridge-session" { return j }
        }
        return nil
    }

    // MARK: Undo

    /// Puts back what a switch did, from its receipt, also when it stopped half way: placed entries that are unchanged
    /// go and their originals come back (an original whose copy can't be taken away stays parked, so the session is
    /// never in both accounts); task files come back from their backups if unchanged since; a pointer line comes off if
    /// it's still the transcript's last bytes. Then anything in parked/ the steps don't name goes back too. The window
    /// must be closed.
    @discardableResult
    static func undo(_ id: String, windowClosed: () -> Bool) throws -> SwitchReceipt {
        let lock = try Lock.take()
        defer { lock.release() }
        guard windowClosed() else { throw SwitchError.notReady("Quit the profile's Claude window first, then Undo.") }
        guard var r = load(id) else { throw SwitchError.failed("No receipt for that switch.") }
        guard r.undone == nil else { return r }
        guard r.linked == nil else { throw SwitchError.notReady("That switch finished; the way back is a switch the other way.") }
        let fm = FileManager.default
        for step in r.steps.reversed() {
            let name = (step.path as NSString).lastPathComponent
            switch step.kind {
            case .entry:
                let now = (try? Data(contentsOf: URL(fileURLWithPath: step.path))).map(sha)
                if now == step.sha {                                       // only what this switch placed, unchanged
                    do { try fm.removeItem(atPath: step.path) }
                    catch { r.problems.append("\(name) couldn't be taken away; its original stays parked"); continue }
                } else if now != nil {
                    r.problems.append("\(name) changed since; left as it is"); continue
                }
                guard let parked = step.parked, let original = step.original, fm.fileExists(atPath: parked) else { continue }
                if !fm.fileExists(atPath: original) { try fm.moveItem(atPath: parked, toPath: original) }
                else { r.problems.append("\(name) is back already") }
            case .tasks:
                let now = (try? Data(contentsOf: URL(fileURLWithPath: step.path))).map(sha)
                let before = step.parked.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }.map(sha)
                if now == before || (now == nil && !step.existed) { continue }    // never written (a stop before it)
                guard now == step.sha else { r.problems.append("\(name) changed since; left as it is"); continue }
                if let backup = step.parked {
                    _ = try fm.replaceItemAt(URL(fileURLWithPath: step.path), withItemAt: URL(fileURLWithPath: backup),
                                             backupItemName: nil, options: [.usingNewMetadataOnly])
                } else if !step.existed {
                    try fm.removeItem(atPath: step.path)                   // a task file this switch made, unchanged
                }
            case .pointer:
                if let why = takeBack(step) { r.problems.append("\(name): \(why)") }
            }
        }
        // anything parked that the steps don't name (a stop between parking and saving): back where it came from
        let parkedDir = root.appendingPathComponent("\(r.id)/parked").path
        let named = Set(r.steps.compactMap(\.parked))
        let source = scopeDir(r.dataDir, r.from)
        for f in (try? fm.contentsOfDirectory(atPath: parkedDir)) ?? [] {
            let p = (parkedDir as NSString).appendingPathComponent(f)
            guard !named.contains(p), f.hasPrefix("local_"), f.hasSuffix(".json") else { continue }
            let back = (source as NSString).appendingPathComponent(f)
            if fm.fileExists(atPath: back) { r.problems.append("\(f) is back already") } else { try fm.moveItem(atPath: p, toPath: back) }
        }
        r.undone = Date()
        try save(r)
        return r
    }

    /// A pointer line off again: only if the transcript is the same file and still ends with exactly those bytes where
    /// they were written. Why not, or nil.
    private static func takeBack(_ step: SwitchReceipt.Step) -> String? {
        guard step.done else { return nil }                                // never written
        guard let off = step.offset, let b = step.bytes.flatMap({ Data(base64Encoded: $0) }) else { return "its pointer line stays (where it went is unknown)" }
        let fd = open(step.path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { return "its pointer line stays (the transcript can't be opened)" }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, UInt64(st.st_dev) == step.dev, UInt64(st.st_ino) == step.ino,
              UInt64(st.st_size) == off + UInt64(b.count) else { return "written to since; its pointer line stays" }
        var tail = Data(count: b.count)
        let n = tail.withUnsafeMutableBytes { pread(fd, $0.baseAddress, b.count, off_t(off)) }
        guard n == b.count, tail == b else { return "written to since; its pointer line stays" }
        return ftruncate(fd, off_t(off)) == 0 ? nil : "its pointer line couldn't be taken off"
    }

    // MARK: receipts

    /// "20261105-153012-a3f9-main": when, a short random part (two switches in one second never share a folder), whose.
    static func receiptID(_ d: Date, _ profile: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: d))-\(UUID().uuidString.prefix(4).lowercased())-\(profile)"
    }

    static func save(_ r: SwitchReceipt) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dir = root.appendingPathComponent(r.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try enc.encode(r).write(to: dir.appendingPathComponent("receipt.json"), options: .atomic)
    }

    static func load(_ id: String) -> SwitchReceipt? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: root.appendingPathComponent("\(id)/receipt.json"))).flatMap { try? dec.decode(SwitchReceipt.self, from: $0) }
    }

    /// A profile's switches, newest first.
    static func receipts(profile: String) -> [SwitchReceipt] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasSuffix("-\(profile)") }
            .compactMap(load).filter { $0.profile == profile }.sorted { $0.started > $1.started }
    }

    /// Every profile's switches, newest first.
    static func receipts() -> [SwitchReceipt] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") && !$0.hasSuffix(".json") }
            .compactMap(load).sorted { $0.started > $1.started }
    }

    /// A profile's switches that moved something and were neither linked nor undone, newest first.
    static func unfinished(profile: String) -> [SwitchReceipt] { receipts(profile: profile).filter(\.unfinished) }

    /// Claude Code signed in as the new account: the profile works on it, and the way back is a switch.
    static func markLinked(_ id: String) {
        guard var r = load(id) else { return }
        r.linked = Date()
        try? save(r)
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    // MARK: one switch at a time

    struct Lock {
        let fd: Int32
        let transplant: Int32                // claude-transplant's lock, held too
        /// A file lock holds against other processes only; this holds within cl_audit.
        private static let inProcess = NSLock()
        private static var held = false

        /// cl_audit's own lock (switches/.lock), and claude-transplant's: it takes its lock with flock (/usr/bin/lockf),
        /// which fcntl locks don't see, so it's taken the same way and held until release.
        static func take() throws -> Lock {
            inProcess.lock()
            defer { inProcess.unlock() }
            guard !held else { throw SwitchError.busy("Another switch is under way.") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else { throw SwitchError.busy("Couldn't take the switch lock.") }
            guard lockf(fd, F_TLOCK, 0) == 0 else { close(fd); throw SwitchError.busy("Another switch is under way.") }
            // claude-transplant 4.2.1 runs `/usr/bin/lockf -k -s -w -t 0 <its folder>/lock …` (a flock; -k keeps the file
            // between runs), or perl's flock on the same file, and makes the folder and the file when they're missing. cl_audit
            // makes them too, so a claude-transplant that starts mid-switch finds the lock held, even on its first run.
            let ctDir = expand("~/Library/Application Support/claude-transplant")
            try? FileManager.default.createDirectory(atPath: ctDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let t = open((ctDir as NSString).appendingPathComponent("lock"), O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard t >= 0 else { lockf(fd, F_ULOCK, 0); close(fd); throw SwitchError.busy("Couldn't check claude-transplant's lock.") }
            guard flock(t, LOCK_EX | LOCK_NB) == 0 else {
                close(t); lockf(fd, F_ULOCK, 0); close(fd)
                throw SwitchError.busy("claude-transplant is moving sessions; wait for it to finish.")
            }
            held = true
            return Lock(fd: fd, transplant: t)
        }

        func release() {
            flock(transplant, LOCK_UN); close(transplant)
            lockf(fd, F_ULOCK, 0); close(fd)
            Self.inProcess.lock(); Self.held = false; Self.inProcess.unlock()
        }
    }
}

/// A switch under way for one Claude window (by its data folder): from closing it until the profile is linked, the
/// switch is undone, or it stops with nothing moved. Meanwhile no window opener starts that window (Launcher.openClaude:
/// the Dock icon, the menu bar, the agent's rules and reopening after a Claude update), and a second switch of it is
/// refused. It holds only while the cl_audit that wrote it runs: the same process id, still running cl_audit's program
/// (a crashed cl_audit whose id another program got holds nothing). Stale marks go at cl_audit's start and on reading.
enum SwitchMarker {
    struct Mark: Codable, Equatable { var pid: Int32; var exe: String; var profile: String; var standby: String; var started: Date }

    static func url(_ window: String) -> URL { SwitchEngine.root.appendingPathComponent("active-\(Account.sha8(window)).json") }

    /// The program a running process was started from, or nil when it isn't running.
    static func executable(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    private static func read(_ file: URL) -> Mark? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: file)).flatMap { try? dec.decode(Mark.self, from: $0) }
    }

    /// Whether the cl_audit that wrote a mark still runs.
    static func live(_ m: Mark) -> Bool { executable(of: m.pid) == m.exe }

    /// The mark on a window, if the cl_audit that wrote it still runs; a stale one is taken away.
    static func current(_ window: String) -> Mark? {
        guard FileManager.default.fileExists(atPath: url(window).path) else { return nil }
        guard let m = read(url(window)), live(m) else { try? FileManager.default.removeItem(at: url(window)); return nil }
        return m
    }

    /// Takes away every mark whose cl_audit is gone (at cl_audit's start).
    static func sweep() {
        let files = (try? FileManager.default.contentsOfDirectory(at: SwitchEngine.root, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix("active-") && f.pathExtension == "json" {
            if read(f).map(live) != true { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// Marks the window for this switch; false when another switch of it (another profile or account, or another
    /// cl_audit) holds it.
    static func claim(_ window: String, profile: String, standby: String) -> Bool {
        if let m = current(window), m.pid != getpid() || m.profile != profile || m.standby != standby { return false }
        guard let exe = executable(of: getpid()) else { return false }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: SwitchEngine.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let d = try? enc.encode(Mark(pid: getpid(), exe: exe, profile: profile, standby: standby, started: Date())) else { return false }
        return (try? d.write(to: url(window), options: .atomic)) != nil
    }

    /// Takes this cl_audit's mark off the window.
    static func release(_ window: String) {
        if let m = read(url(window)), m.pid != getpid(), live(m) { return }
        try? FileManager.default.removeItem(at: url(window))
    }

    /// The switch that keeps this account's window closed now, if any.
    static func blocking(_ account: Account) -> Mark? { current(Launcher.dataDirKey(of: account)) }
    static func blocks(_ account: Account) -> Bool { blocking(account) != nil }
}

extension FolderRules {
    /// After a switch: the profile works on the standby account (its seat), which leaves standby; the account it was on
    /// joins standby, with the folder that kept its own sign-in before (if any). Everything else stays.
    static func completeSwitch(_ id: String, to standbyID: String, in accounts: [AccountEntry], now: Date = Date()) -> [AccountEntry]? {
        guard let i = accounts.firstIndex(where: { $0.id == id }),
              let j = accounts[i].standby.firstIndex(where: { $0.id == standbyID }),
              var to = accounts[i].standby[j].seat else { return nil }
        var out = accounts
        let old = out[i].seat
        let target = out[i].standby.remove(at: j)
        to.linkedAt = now
        to.was = old?.email
        out[i].seat = to
        if let old {
            var back = old
            back.linkedAt = now
            out[i].standby.append(StandbyAccount(email: old.email ?? "", seat: back, configDir: out[i].keptFolder))
        }
        out[i].keptFolder = target.configDir
        return out
    }

    /// After a switch, each account's saved numbers go with it: the profile's (read for the account it was on) become
    /// that account's on standby, and the standby account's become the profile's. The agent's next read replaces them.
    static func moveNumbers(_ before: AccountEntry, _ after: AccountEntry, folder: URL = Store.statusFolder) {
        guard let from = before.seat, let to = after.seat,
              let was = before.standby.first(where: { $0.seat?.same(to) == true }),
              let now = after.standby.first(where: { $0.seat?.same(from) == true }) else { return }
        let fm = FileManager.default
        func url(_ id: String) -> URL { folder.appendingPathComponent("\(id).json") }
        let profile = url(after.id)
        let standbyNow = url(AccountEntry.standbyStatusID(after.id, now.id))
        let standbyWas = url(AccountEntry.standbyStatusID(before.id, was.id))
        try? fm.removeItem(at: standbyNow)
        if fm.fileExists(atPath: profile.path) { try? fm.moveItem(at: profile, to: standbyNow) }
        if fm.fileExists(atPath: standbyWas.path) { try? fm.moveItem(at: standbyWas, to: profile) }
        for id in [after.id, AccountEntry.standbyStatusID(after.id, now.id)] {
            DistributedNotificationCenter.default().postNotificationName(Store.statusChanged, object: id, userInfo: nil, deliverImmediately: true)
        }
    }
}
