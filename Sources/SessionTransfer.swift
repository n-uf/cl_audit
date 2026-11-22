// SessionTransfer: the engines' piece that moves the Claude window's Code sessions from one account's folder to another's,
// inside one window data folder (claude-code-sessions/<account>/<org>/), with their scheduled tasks and Remote Control
// pointers. Session transfer only: no sign-in, no backup, no window, no receipt of its own. Its caller (a switch) holds the
// flow lock, keeps the window closed, makes the backup and owns the record the steps are written down in; this piece sorts
// the entries, moves them, and puts them back.
//
// The entries are ClaudeFiles' (its one lister: local_<UUID>.json, regular files only, never a link); any other name in
// the source shaped like one (not an id, a link, a pipe) is not listed, so it stays where it is, never moved; `odd` counts
// them, for the caller to say. A running Claude
// Code's sessions are held where they are (Processes, failing closed: when it can't be told, nothing moves). Every write is
// create-only (SwitchEngine.writeNew, SafeFiles' CreateOnly), checked back, and only then is the original parked (never
// deleted); a step is written down before it acts and marked done after. The tasks go through TaskRegistry (compare-and-swap,
// a differing twin refused); a session of tasks that can't move is held with them.
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

import Foundation
import ProfileCore

/// One step a transfer writes down (the switch's receipt keeps them).
typealias TransferStep = SwitchReceipt.Step

/// The record a transfer writes its steps and problems into, saved by its caller before and after every step.
protocol TransferRecord {
    var steps: [TransferStep] { get set }
    var problems: [String] { get set }
    var tasksMoved: Int? { get set }
}

extension SwitchReceipt: TransferRecord {}

enum SessionTransfer {
    /// The two accounts' folders of one window data folder, and the Claude Code folder whose transcripts the sessions have.
    struct Scopes: Equatable {
        var dataDir: String                 // the window's data folder (expanded)
        var codeDir: String                 // the profile's Claude Code folder, as the caller's plan holds it
        var from: SeatID
        var to: SeatID

        var sourceDir: String { SwitchEngine.scopeDir(dataDir, from) }
        var targetDir: String { SwitchEngine.scopeDir(dataDir, to) }
    }

    /// What a transfer would do with the source's entries and tasks.
    struct Sorted: Equatable {
        var move: [String] = []             // entries to move ("local_<id>.json")
        var already: [String] = []          // the target has that id already: left where they are
        var deleted: [String] = []          // the target deleted a session with that id: left where they are
        var held: [String] = []             // a running Claude Code owns it (or it can't be read): left where it is
        var taskHeld: [String] = []         // the sessions of tasks that can't move, held too (a subset of `held`)
        var unreadable: [String] = []       // the ones held because they can't be read whole (a subset of `held`): said apart
        var tasks = 0                       // scheduled tasks to move
        var taskStay: String? = nil         // why the scheduled tasks stay: then `tasks` is 0 and neither file is touched
        var taskStayTwin = false            // …because of a differing twin (removing one of the two settles it)
    }

    /// The source's entries, by ClaudeFiles' one lister.
    static func entries(_ s: Scopes) -> [String] { ClaudeFiles.sessionEntries(in: s.sourceDir).map(\.name) }

    /// What a name in the source that looks like an entry (local_….json) but isn't one is: never moved, only counted, so the
    /// plan and its done line can say what stayed behind.
    enum Odd: String, Codable, Equatable { case link, unknownName, notAFile }

    /// The source's names shaped like an entry that ClaudeFiles doesn't list (a link, a name that isn't an id, a folder or a
    /// pipe), sorted by name: they stay where they are, and are said. One read of the folder, each name sorted by the
    /// lister's own rule (isEntryName and a regular file: an entry, not counted).
    static func odd(_ s: Scopes) -> [Odd] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: s.sourceDir)) ?? []).sorted()
        return names.compactMap { n in
            guard n.hasPrefix("local_"), n.hasSuffix(".json") else { return nil }
            var st = stat()
            guard lstat((s.sourceDir as NSString).appendingPathComponent(n), &st) == 0 else { return nil }   // gone meanwhile
            switch st.st_mode & S_IFMT {
            case S_IFLNK: return .link
            case S_IFREG: return ClaudeFiles.isEntryName(n) ? nil : .unknownName
            default: return .notAFile
            }
        }
    }

    /// The source has anything to move at all (an entry, or a task file).
    static func hasAnything(_ s: Scopes) -> Bool { !entries(s).isEmpty || TaskRegistry.exists(s.sourceDir) }

    // MARK: who owns a session now (claude-transplant's workers: Processes.sessionsOwned)

    /// Whether a running Claude Code owns this entry: its own id (without "local_") or its Claude Code session's.
    static func ownedBy(_ owned: Set<String>, entry data: Data, name: String) -> Bool {
        let id = String(name.dropFirst("local_".count).dropLast(".json".count)).lowercased()
        if owned.contains(id) { return true }
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (j?["cliSessionId"] as? String).map { owned.contains($0.lowercased()) } ?? false
    }

    // MARK: sorting (read-only)

    /// Sorts the source's entries (`owned`: the session ids a running Claude Code owns), and says whether its tasks move.
    static func sort(_ s: Scopes, owned: Set<String>) -> Sorted {
        var out = Sorted()
        let fm = FileManager.default
        let taskBlock = TaskRegistry.twinCheck(source: s.sourceDir, target: s.targetDir)
        let taskIDs = Set(TaskRegistry.tasks(in: s.sourceDir).compactMap { $0["id"] as? String })
        for n in entries(s) {
            let id = String(n.dropFirst("local_".count).dropLast(".json".count))
            // bounded, never blocking: one that can't be read whole is held, never moved
            guard let data = SafeRead.whole((s.sourceDir as NSString).appendingPathComponent(n), max: SafeRead.entryMax) else { out.held.append(n); out.unreadable.append(n); continue }
            if fm.fileExists(atPath: (s.targetDir as NSString).appendingPathComponent(n)) { out.already.append(n); continue }
            if fm.fileExists(atPath: (s.targetDir as NSString).appendingPathComponent("deleted_\(id)")) { out.deleted.append(n); continue }
            // a session a running Claude Code owns, or one of tasks that can't move: held where it is
            let task = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["scheduledTaskId"] as? String
            let taskHeld = taskBlock != nil && task.map(taskIDs.contains) == true
            if ownedBy(owned, entry: data, name: n) || taskHeld { out.held.append(n); if taskHeld { out.taskHeld.append(n) }; continue }
            out.move.append(n)
        }
        out.tasks = taskBlock == nil ? taskIDs.count : 0
        // nothing to say about the new account's file when the source has no task; the old account's own file that can't
        // be read as one (its tasks then count as none) is said all the same
        if let b = taskBlock, b.side == .source || !taskIDs.isEmpty {
            out.taskStay = b.words
            out.taskStayTwin = b.twin
        }
        return out
    }

    /// Why a transfer would write through a link, or nil: below the window's data folder, `claude-code-sessions` and both
    /// accounts' two levels (created, moved into, written); below the Claude Code folder, `projects` and each project folder
    /// (a transcript's pointer line is appended there). A part that isn't there yet is fine (it's made as a folder).
    static func linkProblem(_ s: Scopes) -> String? {
        let projects = (expand(s.codeDir) as NSString).appendingPathComponent("projects")
        func isLink(_ path: String) -> Bool {
            var st = stat()
            guard lstat(path, &st) == 0 else { return false }
            let kind = st.st_mode & S_IFMT
            // a project folder's neighbours may be plain files (.DS_Store); only a link there is refused
            return path.hasPrefix(projects + "/") ? kind == S_IFLNK : kind != S_IFDIR
        }
        let sessions = (s.dataDir as NSString).appendingPathComponent("claude-code-sessions")
        var parts = [sessions]
        for seat in [s.from, s.to] {
            let a = (sessions as NSString).appendingPathComponent(seat.account)
            parts += [a, (a as NSString).appendingPathComponent(seat.organization)]
        }
        parts.append(projects)
        if !isLink(projects) {
            for n in (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? [] { parts.append((projects as NSString).appendingPathComponent(n)) }
        }
        guard let bad = parts.first(where: isLink) else { return nil }
        return "\(tildeNoIds(bad)) isn't a plain folder (a link or a file): cl_audit never writes through one, so nothing is moved."
    }

    // MARK: moving

    /// Moves the tasks (when `tasks` > 0) first, then `entries`, then clears the moved sessions' Remote Control pointers.
    /// The tasks are decided before any session moves: when they stay where they are (a twin the new account got since the
    /// plan, a file that changed, a backup that couldn't be made: nothing of them written), the sessions of those tasks stay
    /// with them and the rest move, as when the plan held them. (A task's session that fails on its own after its task moved
    /// stays behind, said in the problems, as any session that fails.) `work`: the caller's own folder for this transfer
    /// (parked originals in work/parked, the task files' backups).
    /// `windowClosed` is asked before every step: the window must stay closed. `save` writes the record down.
    static func move<R: TransferRecord>(_ s: Scopes, entries: [String], tasks: Int, record r: inout R, work: URL,
                                        windowClosed: () -> Bool, save: (R) throws -> Void) throws {
        // (the system's own words for a folder that can't be made name its path, which holds the account's ids)
        do { try FileManager.default.createDirectory(atPath: s.targetDir, withIntermediateDirectories: true) }
        catch { throw SwitchError.failed("Couldn't make the new account's folder in the sessions (\(PlainWords.why(error))). Nothing moved.") }
        // the scheduled tasks, also when there's no session to move
        guard windowClosed() else { throw SwitchError.windowOpen }
        var stayed: Set<String> = []                 // the ids of tasks that stayed: their sessions stay with them
        var holdAllTasks = false                     // the plan's tasks can't be read now: every task's session stays
        if tasks > 0 {
            if TaskRegistry.tasks(in: s.sourceDir).isEmpty {
                holdAllTasks = true
                r.problems.append("The scheduled tasks stay where they were, and so do their sessions: the old account's scheduled tasks file changed since the switch was planned.")
                try save(r)
            } else {
                do { try moveTasks(s, backups: work, &r, save: save) }
                catch let stay as TasksStayed {
                    stayed = stay.ids
                    r.problems.append("The scheduled tasks stay where they were, and so do their sessions: \(stay.why). "
                                      + (stay.twin ? "Remove one of the two, then switch again." : "Fix that, then switch again."))
                    try save(r)
                }
            }
        }
        for name in entries {
            guard windowClosed() else { throw SwitchError.windowOpen }
            if holdAllTasks || !stayed.isEmpty, let task = taskID(of: name, s), holdAllTasks || stayed.contains(task) { continue }    // held with its task
            do { try moveEntry(name, s, parked: work.appendingPathComponent("parked"), &r, save: save) }
            catch { r.problems.append("\(name) didn't move: \(PlainWords.why(error))."); try save(r) }
        }
        let placedPaths = r.steps.filter { $0.kind == .entry && $0.done }.map(\.path)
        for path in placedPaths {
            guard windowClosed() else { throw SwitchError.windowOpen }
            clearPointer(entryPath: path, s, &r, save: save)
        }
    }

    /// The scheduled task a session entry belongs to (its scheduledTaskId), or nil; read as sort() reads it.
    private static func taskID(of name: String, _ s: Scopes) -> String? {
        guard let data = SafeRead.whole((s.sourceDir as NSString).appendingPathComponent(name), max: SafeRead.entryMax) else { return nil }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["scheduledTaskId"] as? String
    }

    /// The tasks stayed where they were, nothing of them written and none of their steps left in the record: `why` says
    /// why, `ids` are the source's task ids (their sessions stay with them).
    // Two checks' seams. Only a test build (compiled with -D CL_AUDIT_TESTING) has them as variables; in the shipped app they
    // are constants (no hook). `beforeTaskBackup`: called with each task file's backup path just before it is written, so a
    // check can make that backup fail. `afterTaskWrite`: called after task file k (0 the source, 1 the target) is written,
    // so a check can make the next write and the put-back fail.
    #if CL_AUDIT_TESTING
    nonisolated(unsafe) static var beforeTaskBackup: ((String) -> Void)? = nil
    nonisolated(unsafe) static var afterTaskWrite: ((Int) -> Void)? = nil
    #else
    static let beforeTaskBackup: ((String) -> Void)? = nil
    static let afterTaskWrite: ((Int) -> Void)? = nil
    #endif

    struct TasksStayed: Error {
        let why: String
        let ids: Set<String>
        var twin = false                    // the reason is a task both accounts have (the way out: remove one of the two)
    }

    /// One entry: written down, placed, checked, then its original parked. A check that fails after placing takes the
    /// placed copy away again, so the session is never in both accounts.
    private static func moveEntry<R: TransferRecord>(_ name: String, _ s: Scopes, parked: URL, _ r: inout R, save: (R) throws -> Void) throws {
        let fm = FileManager.default
        let src = (s.sourceDir as NSString).appendingPathComponent(name)
        let dst = (s.targetDir as NSString).appendingPathComponent(name)
        // bounded and never blocking, like every read of the window's files (SafeRead)
        func readEntry(_ path: String) -> Data? { SafeRead.whole(path, max: SafeRead.entryMax) }
        guard let original = readEntry(src) else { throw SwitchError.failed("\(name) can't be read as a session entry") }
        let data = try SwitchEngine.placed(original)
        let park = parked.appendingPathComponent(name).path
        r.steps.append(TransferStep(kind: .entry, path: dst, sha: SwitchEngine.sha(data), parked: park, original: src))
        let i = r.steps.count - 1
        try save(r)                                                  // what it will do, before anything is written
        do {
            try SwitchEngine.writeNew(dst, data)
        } catch {
            r.steps.remove(at: i); try save(r); throw error         // nothing placed
        }
        do {
            guard readEntry(dst) == data else { throw SwitchError.failed("the placed entry didn't read back the same") }
            // the source checked unchanged, then parked (never deleted)
            guard readEntry(src) == original else { throw SwitchError.failed("the original changed during the switch") }
            try fm.moveItem(atPath: src, toPath: park)
        } catch {
            if readEntry(dst).map(SwitchEngine.sha) == SwitchEngine.sha(data), (try? fm.removeItem(atPath: dst)) != nil {
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

    /// The source's tasks join the target's (a task the target already has by its id, identical to it by the twin rule,
    /// stays the target's: a different one never gets here, the tasks stay), with their state (recordedSkips, runRetries);
    /// the source keeps none. Both files are backed up and both steps written down first; the source is emptied before the
    /// target gets them, so a stop in between never leaves a task in both accounts (it would run twice). Each file is
    /// written through TaskRegistry's compare-and-swap: only while it is still as it was read here; a target that changed
    /// meanwhile or can't be written puts the source back as it was: the tasks stay where they were, and their steps leave
    /// the record (nothing of them to undo). Every way the tasks stay with nothing of them written throws TasksStayed (the
    /// caller then holds their sessions too); a source that can't be put back throws SwitchError (the switch stops, for Undo).
    private static func moveTasks<R: TransferRecord>(_ s: Scopes, backups: URL, _ r: inout R, save: (R) throws -> Void) throws {
        let fm = FileManager.default
        let srcFile = TaskRegistry.path(s.sourceDir), dstFile = TaskRegistry.path(s.targetDir)
        TaskRegistry.sweep(s.sourceDir); TaskRegistry.sweep(s.targetDir)          // a temp an earlier stop left
        // the two files as they are now: what each write must still find
        // the source's task ids as decided below: when the tasks stay, their sessions stay with them
        let ids = Set(TaskRegistry.tasks(in: s.sourceDir).compactMap { $0["id"] as? String })
        guard case .success(let srcBytes) = TaskRegistry.current(srcFile), case .success(let dstBytes) = TaskRegistry.current(dstFile) else {
            throw TasksStayed(why: "a scheduled-tasks.json isn't a plain file", ids: ids)
        }
        func object(_ d: Data?) -> [String: Any]? { d.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } }
        let moving = Set(((object(srcBytes)?["scheduledTasks"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }).union(ids)
        // the twin rule again, on the very bytes joined below: a twin the target got since the plan (made before the window
        // closed) would otherwise drop the source's task for the target's; nothing of the tasks is written then
        if let b = TaskRegistry.twinCheck(source: object(srcBytes), sourceThere: srcBytes != nil,
                                          target: object(dstBytes), targetThere: dstBytes != nil) {
            throw TasksStayed(why: b.words, ids: moving, twin: b.twin)
        }
        let joined = TaskRegistry.joined(source: object(srcBytes) ?? [:], target: object(dstBytes) ?? ["scheduledTasks": [[String: Any]]()])
        var writes: [(file: String, data: Data, expected: Data?, step: Int)] = []
        let first = r.steps.count
        do {
            for (file, json, was, tag) in [(srcFile, joined.source, srcBytes, "source"), (dstFile, joined.target, dstBytes, "target")] {
                let existed = was != nil
                let backup = backups.appendingPathComponent("scheduled-tasks.\(tag).json").path
                // the backup is the very bytes read (never a copy made later, which a link swapped in meanwhile could redirect)
                if let was {
                    try? fm.removeItem(atPath: backup)
                    beforeTaskBackup?(backup)
                    guard CreateOnly.write(was, as: backup, temp: backup + ".tmp", sync: true) == .created else {
                        throw SwitchError.failed("couldn't back up scheduled-tasks.json")
                    }
                }
                let data = try TaskRegistry.encode(json)
                r.steps.append(TransferStep(kind: .tasks, path: file, sha: SwitchEngine.sha(data), parked: existed ? backup : nil, existed: existed))
                writes.append((file, data, was, r.steps.count - 1))
            }
        } catch {
            // nothing of the tasks written: their steps and backups go (also one made before its step was written down, and
            // a temp a failed backup left), and they stay where they were
            for tag in ["source", "target"] {
                let backup = backups.appendingPathComponent("scheduled-tasks.\(tag).json").path
                try? fm.removeItem(atPath: backup); try? fm.removeItem(atPath: backup + ".tmp")
            }
            r.steps.removeSubrange(first...)
            let why = (error as? SwitchError).map { "\($0)" } ?? "scheduled-tasks.json couldn't be written out (\(PlainWords.why(error)))"
            throw TasksStayed(why: why, ids: moving)
        }
        r.tasksMoved = joined.moved.count
        try save(r)                                                  // both written down before either file changes
        for (k, w) in writes.enumerated() {
            let wrote = TaskRegistry.swap(w.data, at: w.file, expected: w.expected)
            guard wrote == .written else {
                // the target couldn't take them: the source back as it was read (only while it is as written here), so the
                // tasks are never in neither account
                let putBack = k == 0 || (writes.first.flatMap { first in
                    first.expected.map { TaskRegistry.swap($0, at: first.file, expected: first.data) == .written } } ?? false)
                if putBack {
                    // nothing of the tasks changed: written down as refused first (a later save that fails still leaves
                    // Undo nothing to do with them), then their steps and backups go (a switch that moved nothing else then
                    // has nothing to undo, and doesn't hold back the next switch)
                    for w in writes { r.steps[w.step].refused = true }
                    try? save(r)
                    for w in writes { if let b = r.steps[w.step].parked { try? FileManager.default.removeItem(atPath: b) } }
                    r.steps.removeSubrange(writes[0].step...)
                    r.tasksMoved = nil
                } else {
                    r.steps[w.step].refused = true                     // this file's write was refused: nothing of it to undo
                }
                try? save(r)
                let why: String
                if case .failed(let w) = wrote { why = w } else { why = "scheduled-tasks.json changed during the switch" }
                // put back: nothing of the tasks changed, they stay with their sessions; not put back: the source was
                // emptied and the target didn't take them (they're in the backup): the switch stops, for Undo
                if putBack { throw TasksStayed(why: why, ids: moving) }
                throw SwitchError.failed("\(why); the tasks are in this switch's backup: Undo puts them back")
            }
            r.steps[w.step].done = true
            try save(r)
            afterTaskWrite?(k)
        }
    }

    // MARK: the Remote Control pointer

    /// Claude Code's own empty pointer line, appended when a moved session's transcript last points at a Remote Control
    /// copy of another account, so the old pointer can't hide the session on the new one. Only when nothing else is
    /// writing that transcript (see `busy`); one O_APPEND write; written down with where it went, for Undo.
    static func clearPointer<R: TransferRecord>(entryPath: String, _ s: Scopes, _ r: inout R, now: Date = Date(), save: (R) throws -> Void) {
        guard let j = SafeRead.jsonObject(entryPath, max: SafeRead.recordMax),
              let cli = j["cliSessionId"] as? String, !cli.isEmpty,
              let transcript = transcriptPath(cli, codeDir: s.codeDir),
              let last = lastPointer(transcript),
              let bridge = last["bridgeSessionId"] as? String, !bridge.isEmpty,
              (last["ownerAccountUuid"] as? String) != s.to.account else { return }
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
        r.steps.append(TransferStep(kind: .pointer, path: transcript, sha: SwitchEngine.sha(bytes), parked: nil, original: nil,
                                    offset: size, bytes: bytes.base64EncodedString(), dev: UInt64(st.st_dev), ino: UInt64(st.st_ino)))
        let i = r.steps.count - 1
        do { try save(r) } catch {                                   // not written down: not written
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
    /// process runs that session. A check that can't finish counts as busy. `table`: the process table (the checks pass their
    /// own; nil reads it now).
    static func busy(_ transcript: String, cli: String, now: Date = Date(), table: [Processes.Entry]?? = nil) -> String? {
        if let m = (try? FileManager.default.attributesOfItem(atPath: transcript))?[.modificationDate] as? Date,
           now.timeIntervalSince(m) < 10 { return "its transcript changed seconds ago" }
        switch Processes.fileOpen(transcript) {
        case .found: return "its transcript is open in another program"
        case .unknown: return "it couldn't be checked whether its transcript is open"
        case .none: break
        }
        // (`cli` is a file name of letters, digits and "-" only: transcriptPath)
        switch Processes.commandLineNames(cli, table: table) {
        case true?: return "Claude Code runs it"
        case nil: return "it couldn't be checked whether Claude Code runs it"
        case false?: break
        }
        return nil
    }

    private static func endsWithNewline(_ path: String, size: UInt64) -> Bool {
        guard size > 0, let last = SafeRead.read(path, max: 1, fromEnd: true)?.data else { return true }
        return last == Data("\n".utf8)
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
        // the last 4 MB of a regular file, never blocking: a FIFO or a device named like a transcript returns at once
        guard let tail = SafeRead.read(path, max: 4 << 20, fromEnd: true)?.data else { return nil }
        for line in String(decoding: tail, as: UTF8.self).split(separator: "\n").reversed()
        where line.contains("\"bridge-session\"") {
            if let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], j["type"] as? String == "bridge-session" { return j }
        }
        return nil
    }

    // MARK: putting back

    /// One step put back (the caller checked it is one of its own places and holds the window closed): a placed entry
    /// that is unchanged goes and its original comes back (an original whose copy can't be taken away stays parked, so the
    /// session is never in both accounts); a task file comes back from its backup if unchanged since; a pointer line comes
    /// off if it's still the transcript's last bytes. Its name when it is left as it was (then the record is only partly
    /// undone), else nil; problems go into the record.
    static func undo<R: TransferRecord>(_ step: TransferStep, record r: inout R) throws -> String? {
        let fm = FileManager.default
        let name = (step.path as NSString).lastPathComponent
        switch step.kind {
        case .entry:
            let now = (try? Data(contentsOf: URL(fileURLWithPath: step.path))).map(SwitchEngine.sha)
            if now == step.sha {                                       // only what this transfer placed, unchanged
                do { try fm.removeItem(atPath: step.path) }
                catch { r.problems.append("\(name) couldn't be taken away; its original stays parked"); return name }
            } else if now != nil {
                r.problems.append("\(name) changed since; left as it is"); return name
            }
            guard let parked = step.parked, let original = step.original, fm.fileExists(atPath: parked) else { return nil }
            if !fm.fileExists(atPath: original) {
                do { try fm.moveItem(atPath: parked, toPath: original) }
                catch { throw SwitchError.failed("\(name) couldn't be put back in the old account's sessions folder (\(PlainWords.why(error))); it stays parked. Undo again once that is fixed.") }
            }
            else { r.problems.append("\(name) is back already") }
        case .tasks:
            // (through TaskRegistry: put back, or taken away, only while the file is still exactly as this transfer wrote it)
            guard case .success(let nowBytes) = TaskRegistry.current(step.path) else {
                r.problems.append("\(name) changed since; left as it is"); return name
            }
            let now = nowBytes.map(SwitchEngine.sha)
            // (the backup read as a plain file: never through a link)
            let backupBytes = step.parked.flatMap { SafeFiles.readPlain($0, max: TaskRegistry.max) }
            let before = backupBytes.map(SwitchEngine.sha)
            if now == before || (now == nil && !step.existed) { return nil }    // never written (a stop before it)
            // a write that was refused (the file had changed) or put back has nothing to undo, whatever the file holds
            // now; any other step not marked done (a crash) is undone only while it still holds this transfer's bytes
            if step.refused == true, !step.done, now != step.sha { return nil }
            guard now == step.sha, let nowBytes else { r.problems.append("\(name) changed since; left as it is"); return name }
            let done: TaskRegistry.Swap
            if let backup = step.parked {
                guard let backupBytes else { throw SwitchError.failed("the backup of \(name) is gone") }
                done = TaskRegistry.swap(backupBytes, at: step.path, expected: nowBytes)
                if done == .written { try? fm.removeItem(atPath: backup) }   // put back (as a move of the backup did)
            } else if !step.existed {
                done = TaskRegistry.remove(at: step.path, expected: nowBytes) // a task file this transfer made, unchanged
            } else { return nil }
            switch done {
            case .written: break
            case .changed: r.problems.append("\(name) changed since; left as it is"); return name
            case .failed(let why): throw SwitchError.failed(why)
            }
        case .pointer:
            if let why = takeBack(step) { r.problems.append("\(name): \(why)") }
        }
        return nil
    }

    /// A pointer line off again: only if the transcript is the same file and still ends with exactly those bytes where
    /// they were written. Why not, or nil.
    private static func takeBack(_ step: TransferStep) -> String? {
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

    /// Anything parked that the steps don't name (a stop between parking and saving): back to `source` where it came from.
    /// `windowClosed` asked before each; a name already back is said so.
    static func returnParked<R: TransferRecord>(parkedDir: String, source: String, record r: inout R, windowClosed: () -> Bool,
                                               save: (R) throws -> Void) throws {
        let fm = FileManager.default
        let named = Set(r.steps.compactMap(\.parked))
        for f in (try? fm.contentsOfDirectory(atPath: parkedDir)) ?? [] {
            let p = (parkedDir as NSString).appendingPathComponent(f)
            guard !named.contains(p), f.hasPrefix("local_"), f.hasSuffix(".json") else { continue }
            guard windowClosed() else { try? save(r); throw SwitchError.windowOpen }
            let back = (source as NSString).appendingPathComponent(f)
            if fm.fileExists(atPath: back) { r.problems.append("\(f) is back already") }
            else {
                do { try fm.moveItem(atPath: p, toPath: back) }
                catch { throw SwitchError.failed("\(f) couldn't be put back in the old account's sessions folder (\(PlainWords.why(error))); it stays parked. Undo again once that is fixed.") }
            }
        }
    }
}
