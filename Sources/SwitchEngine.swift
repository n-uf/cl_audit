// SwitchEngine: moving a profile's Claude window sessions from the account in use to another of its accounts, on this
// Mac (Switch.swift is what the page shows; SwitchView.swift the page). The rules are claude-transplant's:
//
// - only with that window closed (the Claude app rewrites its session entries from memory);
// - one switch at a time (a lock), and none while claude-transplant holds its own lock;
// - every entry keeps its id and is copied unchanged, but for the old account's error keys and its Remote Control ids,
//   through a write that can't overwrite (a private temp file, then a hard link), checked, and only then is the original
//   parked in cl_audit's own folder: nothing is deleted;
// - the scheduled tasks move with them (both task files are backed up first);
// - a session whose transcript points at the old account's Remote Control copy gets Claude Code's own empty pointer line;
// - a receipt, saved after every step, says exactly what was done, so Undo puts it back (only what is unchanged since).
//
// The sidebar's groups, order and pins are synced to claude.ai per account, so they're not written here: the receipt
// notes them (SwitchSidebar.swift), and the window on the new account rebuilds them with its own sidebar tools.

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

    var sourceDir: String { SwitchEngine.scopeDir(dataDir, from) }
    var targetDir: String { SwitchEngine.scopeDir(dataDir, to) }
}

/// The record of one switch, in cl_audit's folder (switches/<id>/receipt.json), saved after every step.
struct SwitchReceipt: Codable, Equatable {
    var id: String
    var profile: String
    var standby: String
    var dataDir: String
    var from: Seat
    var to: Seat
    var started: Date
    var finished: Date?
    var undone: Date?
    var steps: [Step] = []
    var problems: [String] = []
    /// The moved sessions' groups and pins on the old account, noted before the move (SwitchSidebar.swift).
    var sidebar: SidebarPlan?

    struct Step: Codable, Equatable {
        enum Kind: String, Codable { case entry, tasks, pointer }
        var kind: Kind
        var path: String                // the entry placed, the task file changed, the transcript appended to
        var sha: String?                // what it holds after the step
        var parked: String?             // entry: where its original went; tasks: the backup of the file before
        var original: String?           // entry: where the original was
        var existed = true              // tasks: the file was there before
    }
}

enum SwitchError: Error, Equatable, CustomStringConvertible {
    case notReady(String), busy(String), windowOpen, failed(String)
    var description: String {
        switch self {
        case .notReady(let s), .busy(let s), .failed(let s): return s
        case .windowOpen: return "The profile's Claude window is still open."
        }
    }
}

enum SwitchEngine {
    /// The window's folder of sessions for one account and organisation.
    static func scopeDir(_ dataDir: String, _ s: Seat) -> String {
        (expand(dataDir) as NSString).appendingPathComponent("claude-code-sessions/\(s.account)/\(s.organization ?? "")")
    }

    /// Where switches keep their receipts, parked originals and backups.
    static var root: URL { Store.folder.appendingPathComponent("switches") }

    // MARK: the plan (read-only)

    static func plan(_ e: AccountEntry, standby s: StandbyAccount, dataDir: String? = nil) -> Result<SwitchPlan, SwitchError> {
        guard let from = e.seat, from.organization != nil else { return .failure(.notReady("The account in use isn't linked yet.")) }
        guard let to = s.seat, to.organization != nil else { return .failure(.notReady("\(s.email) isn't linked yet: sign in to it first.")) }
        guard !from.same(to) else { return .failure(.notReady("That's the account in use.")) }
        let dir = dataDir ?? (e.desktop == .standard ? expand(FolderKey.standardDataDir) : Account(e).claudeUserDataDir ?? "")
        guard !dir.isEmpty else { return .failure(.notReady("The profile's Claude window has no folder.")) }
        var p = SwitchPlan(profile: e.id, standby: s.id, dataDir: expand(dir), codeDir: Account(e).configDir, from: from, to: to,
                           sessionsFollow: e.sessionsFollow)
        guard e.sessionsFollow else { return .success(p) }
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

    /// Moves what the plan says. `windowClosed` is asked first and before every step: the window must stay closed.
    @discardableResult
    static func run(_ p: SwitchPlan, windowClosed: () -> Bool, now: Date = Date()) throws -> SwitchReceipt {
        let lock = try Lock.take()
        defer { lock.release() }
        guard windowClosed() else { throw SwitchError.windowOpen }
        var r = SwitchReceipt(id: receiptID(now, p.profile), profile: p.profile, standby: p.standby, dataDir: p.dataDir,
                              from: p.from, to: p.to, started: now)
        let dir = root.appendingPathComponent(r.id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("parked"), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try save(r)
        if p.sessionsFollow && !p.move.isEmpty {
            // their groups and pins, from the window's mirror (the window is closed, so it's current), before anything moves
            r.sidebar = p.sidebar()
            try save(r)
            try FileManager.default.createDirectory(atPath: p.targetDir, withIntermediateDirectories: true)
            for name in p.move {
                guard windowClosed() else { r.problems.append("The window opened during the switch; stopped."); try save(r); throw SwitchError.windowOpen }
                do { r.steps.append(try moveEntry(name, p, parkedIn: dir.appendingPathComponent("parked"))) }
                catch { r.problems.append("\(name): \(error)") }
                try save(r)
            }
            if !tasks(in: p.sourceDir).isEmpty {
                r.steps += try moveTasks(p, backups: dir)
                try save(r)
            }
            for step in r.steps where step.kind == .entry {
                if let s = try? clearPointer(entryPath: step.path, p) { r.steps.append(s); try save(r) }
            }
        }
        r.finished = Date()
        try save(r)
        return r
    }

    /// The old account's error keys go; its Remote Control ids are cleared. Everything else stays as it was.
    static let accountErrorKeys = ["error", "errorAt", "priorErrorMark"]

    static func placed(_ original: Data) throws -> Data {
        guard var j = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw SwitchError.failed("not a session entry") }
        for k in accountErrorKeys { j.removeValue(forKey: k) }
        j["bridgeSessionIds"] = [String]()
        return try JSONSerialization.data(withJSONObject: j, options: [.withoutEscapingSlashes])
    }

    private static func moveEntry(_ name: String, _ p: SwitchPlan, parkedIn parked: URL) throws -> SwitchReceipt.Step {
        let src = (p.sourceDir as NSString).appendingPathComponent(name)
        let dst = (p.targetDir as NSString).appendingPathComponent(name)
        let original = try Data(contentsOf: URL(fileURLWithPath: src))
        let data = try placed(original)
        try writeNew(dst, data)
        guard (try? Data(contentsOf: URL(fileURLWithPath: dst))) == data else { throw SwitchError.failed("the placed entry didn't read back the same") }
        // the source checked unchanged, then parked (never deleted)
        guard (try? Data(contentsOf: URL(fileURLWithPath: src))) == original else { throw SwitchError.failed("the original changed during the switch") }
        let park = parked.appendingPathComponent(name).path
        try FileManager.default.moveItem(atPath: src, toPath: park)
        return SwitchReceipt.Step(kind: .entry, path: dst, sha: sha(data), parked: park, original: src)
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
    /// keeps none. Both files are backed up first.
    private static func moveTasks(_ p: SwitchPlan, backups: URL) throws -> [SwitchReceipt.Step] {
        let fm = FileManager.default
        let srcFile = (p.sourceDir as NSString).appendingPathComponent("scheduled-tasks.json")
        let dstFile = (p.targetDir as NSString).appendingPathComponent("scheduled-tasks.json")
        var steps: [SwitchReceipt.Step] = []
        var source = registry(p.sourceDir) ?? [:]
        var target = registry(p.targetDir) ?? ["scheduledTasks": [[String: Any]]()]
        let moving = source["scheduledTasks"] as? [[String: Any]] ?? []
        var have = target["scheduledTasks"] as? [[String: Any]] ?? []
        let ids = Set(have.compactMap { $0["id"] as? String })
        have += moving.filter { ($0["id"] as? String).map { !ids.contains($0) } ?? true }
        target["scheduledTasks"] = have
        source["scheduledTasks"] = [[String: Any]]()
        for (file, json, tag) in [(dstFile, target, "target"), (srcFile, source, "source")] {
            let existed = fm.fileExists(atPath: file)
            let backup = backups.appendingPathComponent("scheduled-tasks.\(tag).json").path
            if existed { try fm.copyItem(atPath: file, toPath: backup) }
            let data = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: file), options: .atomic)
            steps.append(SwitchReceipt.Step(kind: .tasks, path: file, sha: sha(data), parked: existed ? backup : nil, existed: existed))
        }
        return steps
    }

    // MARK: the Remote Control pointer

    /// Claude Code's own empty pointer, appended when a moved session's transcript last points at a Remote Control copy
    /// of another account, so the old pointer can't hide the session on the new one. nil when nothing was needed.
    static func clearPointer(entryPath: String, _ p: SwitchPlan) throws -> SwitchReceipt.Step? {
        guard let d = FileManager.default.contents(atPath: entryPath),
              let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let cli = j["cliSessionId"] as? String, !cli.isEmpty,
              let transcript = transcriptPath(cli, codeDir: p.codeDir),
              let last = lastPointer(transcript),
              let bridge = last["bridgeSessionId"] as? String, !bridge.isEmpty,
              (last["ownerAccountUuid"] as? String) != p.to.account else { return nil }
        let pointer: [String: Any] = ["type": "bridge-session", "sessionId": cli, "bridgeSessionId": "", "lastSequenceNum": 0]
        let line = try JSONSerialization.data(withJSONObject: pointer, options: [.sortedKeys]) + Data("\n".utf8)
        guard let h = FileHandle(forWritingAtPath: transcript) else { return nil }
        defer { try? h.close() }
        try h.seekToEnd()
        // a transcript that doesn't end its last line gets one first, so the pointer is a line of its own
        if let size = try? FileManager.default.attributesOfItem(atPath: transcript)[.size] as? Int, size > 0,
           let r = FileHandle(forReadingAtPath: transcript) {
            try r.seek(toOffset: UInt64(size - 1))
            let end = r.readData(ofLength: 1); try? r.close()
            if end != Data("\n".utf8) { try h.write(contentsOf: Data("\n".utf8)) }
        }
        try h.write(contentsOf: line)
        return SwitchReceipt.Step(kind: .pointer, path: transcript, sha: nil)
    }

    /// <Claude Code folder>/projects/<project>/<cli id>.jsonl
    static func transcriptPath(_ cli: String, codeDir: String) -> String? {
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

    /// Puts back what a switch did, from its receipt: placed entries that are unchanged go, their originals come back;
    /// the task files come back from their backups if unchanged since. Pointer lines stay (harmless). The window must be
    /// closed.
    @discardableResult
    static func undo(_ id: String, windowClosed: () -> Bool) throws -> SwitchReceipt {
        let lock = try Lock.take()
        defer { lock.release() }
        guard windowClosed() else { throw SwitchError.windowOpen }
        guard var r = load(id) else { throw SwitchError.failed("No receipt for that switch.") }
        guard r.undone == nil else { return r }
        let fm = FileManager.default
        for step in r.steps.reversed() {
            switch step.kind {
            case .entry:
                guard let parked = step.parked, let original = step.original else { continue }
                let now = (try? Data(contentsOf: URL(fileURLWithPath: step.path))).map(sha)
                if now == step.sha { try? fm.removeItem(atPath: step.path) }        // only what this switch placed, unchanged
                else if now != nil { r.problems.append("\((step.path as NSString).lastPathComponent) changed since; left as it is"); continue }
                if !fm.fileExists(atPath: original) { try fm.moveItem(atPath: parked, toPath: original) }
                else { r.problems.append("\((original as NSString).lastPathComponent) is back already") }
            case .tasks:
                let now = (try? Data(contentsOf: URL(fileURLWithPath: step.path))).map(sha)
                guard now == step.sha else { r.problems.append("\((step.path as NSString).lastPathComponent) changed since; left as it is"); continue }
                if let backup = step.parked {
                    _ = try fm.replaceItemAt(URL(fileURLWithPath: step.path), withItemAt: URL(fileURLWithPath: backup),
                                             backupItemName: nil, options: [.usingNewMetadataOnly])
                } else if !step.existed {
                    try fm.removeItem(atPath: step.path)          // a task file this switch made, unchanged
                }
            case .pointer:
                continue
            }
        }
        r.undone = Date()
        try save(r)
        return r
    }

    // MARK: receipts

    static func receiptID(_ d: Date, _ profile: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: d))-\(profile)"
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
            .compactMap(load).sorted { $0.started > $1.started }
    }

    static func sha(_ d: Data) -> String { Account.sha8(String(decoding: d, as: UTF8.self)) + "-\(d.count)" }

    // MARK: one switch at a time

    struct Lock {
        let fd: Int32
        /// A file lock holds against other processes only; this holds within cl_audit.
        private static let inProcess = NSLock()
        private static var held = false

        /// cl_audit's own lock (switches/.lock), and claude-transplant's not held (its folder's "lock").
        static func take() throws -> Lock {
            inProcess.lock()
            defer { inProcess.unlock() }
            guard !held else { throw SwitchError.busy("Another switch is under way.") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else { throw SwitchError.busy("Couldn't take the switch lock.") }
            guard lockf(fd, F_TLOCK, 0) == 0 else { close(fd); throw SwitchError.busy("Another switch is under way.") }
            let ct = expand("~/Library/Application Support/claude-transplant/lock")
            if FileManager.default.fileExists(atPath: ct) {
                let t = open(ct, O_RDWR)
                if t >= 0 {
                    let free = lockf(t, F_TEST, 0) == 0
                    close(t)
                    if !free { lockf(fd, F_ULOCK, 0); close(fd); throw SwitchError.busy("claude-transplant is moving sessions; wait for it to finish.") }
                }
            }
            held = true
            return Lock(fd: fd)
        }

        func release() {
            lockf(fd, F_ULOCK, 0); close(fd)
            Self.inProcess.lock(); Self.held = false; Self.inProcess.unlock()
        }
    }
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
}
