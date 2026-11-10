// SwitchEngine: moving a profile's Claude window sessions from the account in use to one of its standby accounts, inside
// the profile's one folder (SwitchRunner.swift then signs Claude Code in again on that folder as the new account). The
// rules are claude-transplant's (4.2.1, MIT; its transplant.js: rehomeOne, taskFamilies, workers, the receipts and undo):
//
// - only with the profile's Claude window closed (the Claude app rewrites its session entries from memory), checked again
//   before each entry and before the tasks and pointer steps; while it runs no window opener starts it (SwitchMarker);
// - a session a running Claude Code owns (its id on a `claude` process's command line, or in the folder's
//   sessions/<pid>.json of a live process) is held: left where it is, named in the receipt, moved by a later switch
//   (claude-transplant's "held": never moved while a worker owns it);
// - one writer at a time (cl_audit's lock), and none while claude-transplant runs: its own lock (a flock) is held for the
//   whole run;
// - before anything moves, under the same lock, a backup of the window's Code-tab list, its sidebar records and cl_audit's
//   records (and Claude Code's transcripts) is made (SessionsBackup.swift); if it can't be, nothing moves. The receipt
//   names the backup, and the backup names the receipt;
// - every entry keeps its id: kept byte for byte, or re-encoded without the old account's error keys and Remote Control
//   ids (claude-transplant's `{ ...without(current, ACCOUNT_ERROR_KEYS), bridgeSessionIds: [] }`), through a write that
//   can't overwrite (a private temp file, then a hard link), checked, and only then is the original parked in cl_audit's
//   own folder: nothing is deleted;
// - the scheduled tasks move with them, with their state (recordedSkips, runRetries: claude-transplant's TASK_STATE_KEYS):
//   both task files are backed up, the source is emptied first, then the target gets them (a stop in between leaves them
//   in neither, never in both, and Undo puts them back); a target that already has a task's id with other state stops
//   the tasks' step (claude-transplant's "target scheduled task state collision");
// - a session whose transcript points at the old account's Remote Control copy gets Claude Code's own empty pointer
//   line, appended in one O_APPEND write, and only when nothing else is writing that transcript; Undo takes it off
//   again if it's still the transcript's last bytes;
// - the receipt says what each step will do before it's done (paths, hashes, backups) and marks it done after, so Undo
//   puts back whatever got done, also after a stop or a crash (only what is unchanged since). Receipts name accounts by
//   their ids only, never by address. A switch is linked once Claude Code is on the new account: from then on the way
//   back is a switch the other way.
//
// Shared with the other writers of the window's files (Restore, Import, the default-profile move, re-pointing a moved
// session): the scope folders, `placed`, `writeNew`, the lock and the window marks.
//
// Adapted from claude-transplant, Copyright (c) 2026 Vitaliy Hayda, under the MIT License:
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
//   documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
//   rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
//   permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright
//   notice and this permission notice shall be included in all copies or substantial portions of the Software.
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
//   WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
//   COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
//   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

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
    var held: [String] = []             // a running Claude Code owns it: left where it is, for a later switch
    var tasks = 0                       // scheduled tasks to move
    var backupTranscripts = true        // the backup (SessionsBackup.swift) takes Claude Code's transcripts too
    var entry: AccountEntry? = nil      // cl_audit's record of the profile, for the backup

    var sourceDir: String { SwitchEngine.scopeDir(dataDir, SeatID(from)) }
    var targetDir: String { SwitchEngine.scopeDir(dataDir, SeatID(to)) }
    /// Anything to move at all (otherwise the switch only signs in again).
    var moves: Bool { !move.isEmpty || tasks > 0 }
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
    var linked: Date?                   // the profile worked on the new account: from then on, the way back was a switch
    var undone: Date?
    var steps: [Step] = []
    var problems: [String] = []
    /// The moved sessions' groups and pins on the old account, noted before the move (SwitchSidebar.swift).
    var sidebar: SidebarPlan?
    /// The backup made right before anything moved (SessionsBackup.swift), by its id; the backup names this switch too.
    /// nil: none (the sessions weren't moved, or the receipt is from before backups).
    var backup: String?
    /// The folder that backup is in (General ▸ Backups at the time): a later change of that folder doesn't lose it.
    var backupPlace: String?
    /// The receipt of the switch this one switched back ("Undo this switch", 26.11.13 and earlier).
    var undoes: String?
    /// The entries a running Claude Code owned, left where they were ("local_<id>.json").
    var held: [String]?

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
    /// The backup before the move couldn't be made (or the window opened while it was): nothing moved.
    case backup(String)
    var description: String {
        switch self {
        case .notReady(let s), .busy(let s), .failed(let s), .backup(let s): return s
        case .windowOpen: return "The profile's Claude window opened during the switch; stopped. Undo puts back what moved."
        }
    }
}

enum SwitchEngine {
    /// The window's folder of sessions for one account and organisation.
    static func scopeDir(_ dataDir: String, _ s: SeatID) -> String {
        (expand(dataDir) as NSString).appendingPathComponent("claude-code-sessions/\(s.account)/\(s.organization)")
    }

    /// Where the old switches' receipts are, and the window marks and the lock.
    static var root: URL { Store.folder.appendingPathComponent("switches") }

    // MARK: a session entry in another account's folder

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

    /// A task's state kept beside the list, by task id (claude-transplant's TASK_STATE_KEYS): it goes with the task.
    static let taskStateKeys = ["recordedSkips", "runRetries"]

    /// The scope's scheduled-tasks.json, or nil when it isn't there or can't be read as one.
    static func registry(_ scopeDir: String) -> [String: Any]? {
        let f = (scopeDir as NSString).appendingPathComponent("scheduled-tasks.json")
        guard let d = FileManager.default.contents(atPath: f) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// Why the source's tasks can't move as they are, or nil (claude-transplant's taskSessions and taskFamilies checks): a
    /// registry that can't be read, a task without an id or an id twice, or a target that has one of their ids already with
    /// other state.
    static func taskProblem(source: String, target: String) -> String? {
        let fm = FileManager.default
        let file = (source as NSString).appendingPathComponent("scheduled-tasks.json")
        guard fm.fileExists(atPath: file) else { return nil }
        guard let src = registry(source) else { return "its scheduled-tasks.json can't be read" }
        if let raw = src["scheduledTasks"], !(raw is [[String: Any]]) { return "its scheduled-tasks.json isn't a task list" }
        let list = tasks(in: source)
        let ids = list.compactMap { $0["id"] as? String }
        guard ids.count == list.count, !ids.contains(where: \.isEmpty) else { return "a scheduled task has no id" }
        guard Set(ids).count == ids.count else { return "two scheduled tasks share an id" }
        if fm.fileExists(atPath: (target as NSString).appendingPathComponent("scheduled-tasks.json")) {
            guard let dst = registry(target) else { return "the new account's scheduled-tasks.json can't be read" }
            for key in taskStateKeys {
                let s = src[key] as? [String: Any] ?? [:], t = dst[key] as? [String: Any] ?? [:]
                for id in ids where t[id] != nil {
                    guard let a = s[id], NSDictionary(dictionary: ["v": a]).isEqual(to: ["v": t[id]!]) else {
                        return "the new account has a task with the same id and other state"
                    }
                }
            }
        }
        return nil
    }

    // MARK: who owns a session now (claude-transplant's workers)

    /// The session ids a running Claude Code owns: every id on the command line of a process whose program is `claude`,
    /// and the sessionId of `<codeDir>/sessions/<pid>.json` for a process that runs. nil when the processes can't be read
    /// (then nothing moves: claude-transplant's "cannot inspect running workers").
    static func workers(codeDir: String) -> Set<String>? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,command="]
        var env = ProcessInfo.processInfo.environment; env["LC_ALL"] = "C"; p.environment = env
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return owned(ps: String(decoding: data, as: UTF8.self), codeDir: codeDir, alive: { kill($0, 0) == 0 || errno == EPERM })
    }

    /// `workers` on what `ps -axo pid=,command=` printed (the checks pass their own).
    static func owned(ps: String, codeDir: String, alive: (pid_t) -> Bool) -> Set<String> {
        var ids: Set<String> = []
        let uuid = try! NSRegularExpression(pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", options: [.caseInsensitive])
        for line in ps.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let program = parts[1].split(separator: " ").first,
                  (String(program) as NSString).lastPathComponent.lowercased() == "claude" else { continue }
            let cmd = parts[1]
            for m in uuid.matches(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)) {
                if let r = Range(m.range, in: cmd) { ids.insert(cmd[r].lowercased()) }
            }
        }
        let dir = (expand(codeDir) as NSString).appendingPathComponent("sessions")
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".json") {
            guard let pid = pid_t(n.dropLast(5)), pid > 0, alive(pid),
                  let d = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent(n)),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (j["pid"] as? NSNumber)?.int32Value == pid, let s = j["sessionId"] as? String else { continue }
            ids.insert(s.lowercased())
        }
        return ids
    }

    /// Whether a running Claude Code owns this entry: its own id (without "local_") or its Claude Code session's.
    static func ownedBy(_ owned: Set<String>, entry data: Data, name: String) -> Bool {
        let id = String(name.dropFirst("local_".count).dropLast(".json".count)).lowercased()
        if owned.contains(id) { return true }
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (j?["cliSessionId"] as? String).map { owned.contains($0.lowercased()) } ?? false
    }

    // MARK: the plan (read-only)

    /// What a switch to `s` would move, read without changing anything. `owned`: the session ids a running Claude Code
    /// owns (nil: read them now).
    static func plan(_ e: AccountEntry, standby s: StandbyAccount, dataDir: String? = nil, owned: Set<String>? = nil) -> Result<SwitchPlan, SwitchError> {
        guard let from = e.seat, from.organization != nil else { return .failure(.notReady("The account in use isn't known yet.")) }
        guard let to = s.seat, to.organization != nil else {
            return .failure(.notReady("\(s.email) hasn't been signed in on this Mac yet, so its sessions' folder isn't known: nothing to move."))
        }
        // the ids name folders: only real ids (never a path)
        guard [from.account, from.organization!, to.account, to.organization!].allSatisfy(AccountDiscovery.isUUID) else {
            return .failure(.notReady("An account id isn't one Claude would use; nothing is moved."))
        }
        guard !from.same(to) else { return .failure(.notReady("That's the account in use.")) }
        let dir = dataDir ?? (e.desktop == .standard ? expand(FolderKey.standardDataDir) : Account(e).claudeUserDataDir ?? "")
        guard !dir.isEmpty else { return .failure(.notReady("The profile's Claude window has no folder.")) }
        var p = SwitchPlan(profile: e.id, standby: s.id, dataDir: expand(dir), codeDir: Account(e).configDir, from: from, to: to, entry: e)
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: p.sourceDir)) ?? []).filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }.sorted()
        guard !names.isEmpty || fm.fileExists(atPath: (p.sourceDir as NSString).appendingPathComponent("scheduled-tasks.json")) else { return .success(p) }
        guard let live = owned ?? workers(codeDir: p.codeDir) else {
            return .failure(.notReady("cl_audit couldn't see which sessions Claude Code is running now; nothing is moved."))
        }
        let taskBlock = taskProblem(source: p.sourceDir, target: p.targetDir)
        let taskIDs = Set(tasks(in: p.sourceDir).compactMap { $0["id"] as? String })
        for n in names {
            let id = String(n.dropFirst("local_".count).dropLast(".json".count))
            let data = fm.contents(atPath: (p.sourceDir as NSString).appendingPathComponent(n)) ?? Data()
            if fm.fileExists(atPath: (p.targetDir as NSString).appendingPathComponent(n)) { p.already.append(n); continue }
            if fm.fileExists(atPath: (p.targetDir as NSString).appendingPathComponent("deleted_\(id)")) { p.deleted.append(n); continue }
            // a session a running Claude Code owns, or one of tasks that can't move: held where it is
            let task = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["scheduledTaskId"] as? String
            if ownedBy(live, entry: data, name: n) || (taskBlock != nil && task.map(taskIDs.contains) == true) { p.held.append(n); continue }
            p.move.append(n)
        }
        p.tasks = taskBlock == nil ? taskIDs.count : 0
        return .success(p)
    }

    // MARK: running it

    /// Moves what the plan says. `windowClosed` is asked first and before every step: the window must stay closed. If
    /// it stops (the window opened, a write failed), the receipt stays as it is, unfinished, for Undo.
    ///
    /// A backup of the sessions is made first, right here under the lock: the window is known closed and nothing has
    /// moved. The receipt names it (saved before the first move) and it names the receipt. If it can't be made, the switch
    /// stops with nothing moved. `backups`: where it goes (General ▸ Backups unless given).
    @discardableResult
    static func run(_ p: SwitchPlan, windowClosed: () -> Bool, now: Date = Date(), backups: URL? = nil,
                    backupMade: ((_ id: String, _ place: String) -> Void)? = nil) throws -> SwitchReceipt {
        let lock = try Lock.take()
        defer { lock.release() }
        guard windowClosed() else { throw SwitchError.notReady("The profile's Claude window is open; nothing moved.") }
        var r = SwitchReceipt(id: receiptID(now, p.profile), profile: p.profile, standby: p.standby, dataDir: p.dataDir,
                              from: SeatID(p.from), to: SeatID(p.to), started: now)
        r.held = p.held.isEmpty ? nil : p.held
        let place = backups ?? BackupPrefs.placeURL
        if p.moves {
            let id = SessionsBackup.newID(now)
            r.backup = id; r.backupPlace = place.path
            do {
                try SessionsBackup.make(SessionsBackup.Source(profile: p.profile, dataDir: p.dataDir, codeDir: p.codeDir, entry: p.entry),
                                        id: id, kind: .beforeSwitch(r.id), window: true, transcripts: p.backupTranscripts,
                                        receipt: r, place: place, now: now)
            } catch {
                throw SwitchError.backup("The backup of the sessions couldn't be made (\(error)). Nothing moved. Backups go to \(tilde(place.path)); General ▸ Backups changes that.")
            }
            // still closed? a window that opened meanwhile may have changed what was copied: the backup is taken away
            guard windowClosed() else {
                SessionsBackup.discard(profile: p.profile, id: id, place: place)
                throw SwitchError.backup("The Claude window opened during the backup; nothing moved. Close it and try again.")
            }
        }
        // old backups age out once this one is made, also when the switch stops
        defer { if p.moves { SessionsBackup.prune(profile: p.profile, place: place) } }
        let dir = root.appendingPathComponent(r.id)
        do {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("parked"), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try save(r)
        } catch {
            // no receipt: nothing names the backup, and nothing moved
            if let id = r.backup { SessionsBackup.discard(profile: p.profile, id: id, place: place) }
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        if let id = r.backup { backupMade?(id, place.path) }           // known to the page before the first move
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
        guard p.moves else { return }
        try FileManager.default.createDirectory(atPath: p.targetDir, withIntermediateDirectories: true)
        for name in p.move {
            guard windowClosed() else { throw SwitchError.windowOpen }
            do { try moveEntry(name, p, parked: dir.appendingPathComponent("parked"), &r) }
            catch { r.problems.append("\(name) didn't move: \(error)."); try save(r) }
        }
        // the scheduled tasks, also when there's no session to move
        guard windowClosed() else { throw SwitchError.windowOpen }
        if p.tasks > 0, !tasks(in: p.sourceDir).isEmpty { try moveTasks(p, backups: dir, &r) }
        let placedPaths = r.steps.filter { $0.kind == .entry && $0.done }.map(\.path)
        for path in placedPaths {
            guard windowClosed() else { throw SwitchError.windowOpen }
            clearPointer(entryPath: path, p, &r)
        }
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

    /// The source's tasks join the target's (a task the target already has by its id stays the target's), with their state
    /// (recordedSkips, runRetries); the source keeps none. Both files are backed up and both steps written down first; the
    /// source is emptied before the target gets them, so a stop in between never leaves a task in both accounts (it would
    /// run twice).
    private static func moveTasks(_ p: SwitchPlan, backups: URL, _ r: inout SwitchReceipt) throws {
        let fm = FileManager.default
        let srcFile = (p.sourceDir as NSString).appendingPathComponent("scheduled-tasks.json")
        let dstFile = (p.targetDir as NSString).appendingPathComponent("scheduled-tasks.json")
        var source = registry(p.sourceDir) ?? [:]
        var target = registry(p.targetDir) ?? ["scheduledTasks": [[String: Any]]()]
        let moving = source["scheduledTasks"] as? [[String: Any]] ?? []
        let movingIDs = moving.compactMap { $0["id"] as? String }
        var have = target["scheduledTasks"] as? [[String: Any]] ?? []
        let ids = Set(have.compactMap { $0["id"] as? String })
        have += moving.filter { ($0["id"] as? String).map { !ids.contains($0) } ?? true }
        target["scheduledTasks"] = have
        source["scheduledTasks"] = [[String: Any]]()
        for key in taskStateKeys {
            guard var s = source[key] as? [String: Any] else { continue }
            var t = target[key] as? [String: Any] ?? [:]
            for id in movingIDs { if let v = s.removeValue(forKey: id) { t[id] = v } }
            source[key] = s; target[key] = t
        }
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
    /// must be closed. A linked switch isn't undone: the way back is a switch the other way.
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

    /// "20261105-153012-a3f9-main": when, a short random part (two runs in one second never share a folder), whose. Restore
    /// receipts are named the same way.
    static func receiptID(_ d: Date, _ profile: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: d))-\(UUID().uuidString.prefix(4).lowercased())-\(profile)"
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

    /// A receipt as it is saved (receipt.json).
    static func encoded(_ r: SwitchReceipt) throws -> Data {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(r)
    }

    static func save(_ r: SwitchReceipt) throws {
        let dir = root.appendingPathComponent(r.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoded(r).write(to: dir.appendingPathComponent("receipt.json"), options: .atomic)
    }

    /// Claude Code signed in as the new account: the profile works on it, and the way back is a switch.
    static func markLinked(_ id: String, now: Date = Date()) {
        guard var r = load(id), r.linked == nil, r.undone == nil else { return }
        r.linked = now
        try? save(r)
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    // MARK: one writer at a time

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
            guard !held else { throw SwitchError.busy("Another restore, import or move is under way.") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else { throw SwitchError.busy("Couldn't take cl_audit's lock.") }
            guard lockf(fd, F_TLOCK, 0) == 0 else { close(fd); throw SwitchError.busy("Another restore, import or move is under way.") }
            // claude-transplant 4.2.1 runs `/usr/bin/lockf -k -s -w -t 0 <its folder>/lock …` (a flock; -k keeps the file
            // between runs), or perl's flock on the same file, and makes the folder and the file when they're missing. cl_audit
            // makes them too, so a claude-transplant that starts meanwhile finds the lock held, even on its first run.
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

/// A run that holds one Claude window (by its data folder) closed while it writes the window's files: a restore, an
/// import's re-point, the default-profile move. Meanwhile no window opener starts that window (Launcher.openClaude: the
/// Dock icon, the menu bar, the agent's rules and reopening after a Claude update), and a second run on it is refused. It
/// holds only while the cl_audit that wrote it runs: the same process id, still running cl_audit's program (a crashed
/// cl_audit whose id another program got holds nothing). Stale marks go at cl_audit's start and on reading. (`standby`
/// names the run: "restore-…", "repoint-…", "default-…"; a switch of 26.11.13 and earlier put a standby account's id there.)
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

    /// Marks the window for this run; false when another run on it (another profile or run, or another cl_audit) holds it.
    static func claim(_ window: String, profile: String, standby: String) -> Bool {
        if let m = current(window), m.pid != getpid() || m.profile != profile || m.standby != standby { return false }
        guard let exe = executable(of: getpid()) else { return false }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: SwitchEngine.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let d = try? enc.encode(Mark(pid: getpid(), exe: exe, profile: profile, standby: standby, started: Date())) else { return false }
        return (try? d.write(to: url(window), options: .atomic)) != nil
    }

    /// Takes this cl_audit's mark off the window.
    /// With `profile` and `standby`, only a mark that is exactly that one: one run finishing never takes away another's
    /// mark, though both are this process's.
    static func release(_ window: String, profile: String? = nil, standby: String? = nil) {
        if let m = read(url(window)) {
            if m.pid != getpid(), live(m) { return }
            if let profile, let standby, m.profile != profile || m.standby != standby { return }
        }
        try? FileManager.default.removeItem(at: url(window))
    }

    /// The run that keeps this account's window closed now, if any.
    static func blocking(_ account: Account) -> Mark? { current(Launcher.dataDirKey(of: account)) }
    static func blocks(_ account: Account) -> Bool { blocking(account) != nil }
}
