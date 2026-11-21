// TaskRegistry: the one owner of a Claude window scope's scheduled-tasks.json (claude-code-sessions/<account>/<org>/), the
// task list the Claude window runs. Every write over a task file that is there goes through it: the switch (the tasks move
// with the account, and Undo puts the files back). Restore and import make a file only where there's none (create-only,
// through their own piece writer), with `paused` from here; they, the default move and the switch read tasks here too
// (backup, export and import still count a file's tasks from its bytes themselves). Built on SafeFiles: a write is a
// compare-and-swap (the file must still be exactly as it was read, or nothing is written), placed through a private temp
// file, never through a link, keeping the file's own mode.
//
// The rule lifted out of the switch (Fix A): a task the target already has under the same id must be the same task, whole
// (its entry and its state): a differing twin is refused, so a move never drops one task for another.
//
// Bytes stay as they were: the switch writes `encode` (JSONSerialization, slashes unescaped), restore writes `paused` (pretty,
// sorted keys). A file written over keeps its mode; a new one gets 0666 under the umask, as Foundation's write made it.

import Foundation

enum TaskRegistry {
    static let fileName = "scheduled-tasks.json"
    /// A task's state kept beside the list, by task id (claude-transplant's TASK_STATE_KEYS): it goes with the task.
    static let stateKeys = ["recordedSkips", "runRetries"]
    /// The largest task file read or swapped.
    static let max = 64 << 20

    /// The scope's task file.
    static func path(_ scopeDir: String) -> String { (scopeDir as NSString).appendingPathComponent(fileName) }

    /// There is a task file (whatever it is).
    static func exists(_ scopeDir: String) -> Bool { FileManager.default.fileExists(atPath: path(scopeDir)) }

    // MARK: reading

    /// The scope's scheduled-tasks.json, or nil when it isn't there or can't be read as one (bounded, never blocking).
    static func registry(_ scopeDir: String) -> [String: Any]? { SafeRead.jsonObject(path(scopeDir)) }

    /// The scope's tasks: the objects of its `scheduledTasks` ([] when there's no file or no list).
    static func tasks(in scopeDir: String) -> [[String: Any]] {
        registry(scopeDir)?["scheduledTasks"] as? [[String: Any]] ?? []
    }

    /// The tasks of a task file's bytes: the objects of its `scheduledTasks` array (anything else in it is skipped). [] when it
    /// isn't one.
    static func taskList(_ d: Data) -> [[String: Any]] {
        guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let list = j["scheduledTasks"] as? [Any] else { return [] }
        return list.compactMap { $0 as? [String: Any] }
    }

    /// The ids of the tasks a scope's file has, read as a plain file (never through a link): empty when none.
    static func ids(in scopeDir: String) -> Set<String> {
        Set(SafeFiles.readPlain(path(scopeDir), max: max).map { taskList($0).compactMap { $0["id"] as? String } } ?? [])
    }

    // MARK: the twin rule

    /// Why the source's tasks can't join the target's as they are, or nil (claude-transplant's taskSessions and taskFamilies
    /// checks): a file that can't be read, a task without an id or an id twice, or a target that has one of their ids already
    /// with other settings (the task's own entry) or other state: a differing twin, refused. The words follow an old account's
    /// name ("The scheduled tasks stay with ann: …"), so each file is named by whose it is, never "its", and never by its file name.
    static func twinProblem(source: String, target: String) -> String? {
        guard exists(source) else { return nil }
        guard let src = registry(source) else { return "the old account's scheduled tasks file can't be read" }
        if let raw = src["scheduledTasks"], !(raw is [[String: Any]]) { return "the old account's scheduled tasks file isn't a list of tasks" }
        let list = tasks(in: source)
        let ids = list.compactMap { $0["id"] as? String }
        guard ids.count == list.count, !ids.contains(where: \.isEmpty) else { return "a scheduled task has no id" }
        guard Set(ids).count == ids.count else { return "two scheduled tasks share an id" }
        if exists(target) {
            guard let dst = registry(target) else { return "the new account's scheduled tasks file can't be read" }
            // a list with an element that isn't a task would read as no tasks at all, and be overwritten by the move
            if let raw = dst["scheduledTasks"], !(raw is [[String: Any]]) { return "the new account's scheduled tasks file isn't a list of tasks" }
            // a task the target has under the same id must be the same task, whole: otherwise the move would drop the
            // source's (the target's copy stays), and it would survive only in the backup
            let have = tasks(in: target)
            for task in list {
                guard let id = task["id"] as? String, let mine = have.first(where: { $0["id"] as? String == id }) else { continue }
                guard NSDictionary(dictionary: task).isEqual(to: mine) else { return "the new account has a task with the same id and other settings" }
            }
            for key in stateKeys {
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

    // MARK: making the files

    /// The source's tasks joined to the target's: a task the target already has by its id (the same by `twinProblem`'s rule)
    /// stays the target's; their state (`stateKeys`) goes with them; the source keeps none. `moved`: the ids that moved.
    static func joined(source: [String: Any], target: [String: Any]) -> (source: [String: Any], target: [String: Any], moved: [String]) {
        var source = source, target = target
        let moving = source["scheduledTasks"] as? [[String: Any]] ?? []
        let movingIDs = moving.compactMap { $0["id"] as? String }
        var have = target["scheduledTasks"] as? [[String: Any]] ?? []
        let ids = Set(have.compactMap { $0["id"] as? String })
        have += moving.filter { ($0["id"] as? String).map { !ids.contains($0) } ?? true }
        target["scheduledTasks"] = have
        source["scheduledTasks"] = [[String: Any]]()
        for key in stateKeys {
            guard var s = source[key] as? [String: Any] else { continue }
            var t = target[key] as? [String: Any] ?? [:]
            for id in movingIDs { if let v = s.removeValue(forKey: id) { t[id] = v } }
            source[key] = s; target[key] = t
        }
        return (source, target, movingIDs)
    }

    /// A task file's bytes as the switch writes them.
    static func encode(_ json: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
    }

    /// The task file restore and import write: the first file's object with its `scheduledTasks` replaced by `tasks`, each with
    /// `enabled: false` and nothing else changed. nil: it can't be made.
    static func paused(base: Data, tasks: [[String: Any]]) -> Data? {
        guard var j = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any] else { return nil }
        j["scheduledTasks"] = tasks.map { t -> [String: Any] in var t = t; t["enabled"] = false; return t }
        return try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: compare-and-swap

    /// What a swap did.
    enum Swap: Equatable {
        case written
        /// The file isn't as it was read (changed, made or taken away since): nothing was written.
        case changed
        /// It couldn't be written (a link or something other than a plain file at its name, a temp that couldn't be made, …):
        /// nothing was written.
        case failed(String)
    }

    /// The file's bytes now: nil when nothing is there; `.failure` when something is there that isn't a plain file under
    /// the cap (a link, a folder, a FIFO, too large).
    static func current(_ file: String) -> Result<Data?, SwapRefused> {
        var st = stat()
        guard lstat(file, &st) == 0 else { return errno == ENOENT ? .success(nil) : .failure(SwapRefused()) }
        guard (st.st_mode & S_IFMT) == S_IFREG, let d = SafeFiles.readPlain(file, max: max) else { return .failure(SwapRefused()) }
        return .success(d)
    }
    struct SwapRefused: Error {}

    /// `data` at `file` (a scope's task file, or a path the caller checked is one) only while the file is exactly `expected`
    /// (nil: no file there): written whole under a private temp name in the same folder, checked again, then renamed over it.
    /// Never through a link; `.changed` and `.failed` write nothing.
    static func swap(_ data: Data, at file: String, expected: Data?) -> Swap {
        switch current(file) {
        case .failure: return .failed("\(fileName) isn't a plain file")
        case .success(let now): guard now == expected else { return .changed }
        }
        // the file's own mode when it is there (so a 0600 task file stays 0600); a new one 0666 under the umask
        var st = stat()
        let keep: mode_t? = lstat(file, &st) == 0 ? st.st_mode & 0o777 : nil          // the permissions, no special bits
        let dir = (file as NSString).deletingLastPathComponent
        let temp = (dir as NSString).appendingPathComponent(tempPrefix + UUID().uuidString + ".tmp")
        let t: CreateOnly.Temp
        do { t = try CreateOnly.Temp(temp, mode: 0o666) } catch { return .failed("couldn't write in \(tilde(dir))") }
        defer { t.discard() }
        if let keep { guard fchmod(t.fd, keep) == 0 else { return .failed("couldn't write \(fileName)") } }
        guard CreateOnly.writeAll(t.fd, data) else { return .failed("couldn't write \(fileName)") }
        t.close()
        // the last look before it goes in: still as it was read
        switch current(file) {
        case .failure: return .failed("\(fileName) isn't a plain file")
        case .success(let now): guard now == expected else { return .changed }
        }
        return Darwin.rename(temp, file) == 0 ? .written : .failed("couldn't place \(fileName)")
    }

    /// The temp files `swap` writes beside a task file start so (and end with ".tmp").
    static let tempPrefix = ".\(fileName)."

    /// Takes away the temp files a swap left in a scope folder (a stop between writing and placing): plain files only.
    static func sweep(_ scopeDir: String) {
        let fd = open(scopeDir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: scopeDir)) ?? []
        CreateOnly.sweep(fd, names: names, prefix: tempPrefix)
    }

    /// The file at `file` taken away only while it is exactly `expected`.
    static func remove(at file: String, expected: Data) -> Swap {
        switch current(file) {
        case .failure: return .failed("\(fileName) isn't a plain file")
        case .success(let now): guard now == expected else { return .changed }
        }
        return unlink(file) == 0 ? .written : .failed("couldn't take \(fileName) away")
    }
}
