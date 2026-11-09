// SessionsRestoreWindow: the Claude window's own settings and scheduled tasks in a backup (format 3), planned against what the profile
// has now. The same rules for an import and a restore, except where said:
//
// - claude_desktop_config.json (its MCP servers and the window's other settings; the sidebar part travels on its own): MCP servers run
//   commands on their own, so it is left out unless asked ("Add them", which lists each server's name and what it runs, never an env
//   value, a header or an argument). Create-only for the whole file: added only where the profile has no claude_desktop_config.json;
//   one that is here stays byte for byte, and the preview lists the servers it lacks. Never merged into an existing file.
// - scheduled-tasks.json (the window's tasks, in each account folder) and each task's prompt (<Claude Code folder>/scheduled-tasks/<id>/
//   SKILL.md, where the window looks for it: it works the path out from the id, whatever `filePath` the task records):
//     · a restore from this Mac's own backup puts the account in use's task file back when none is here, as it was (its own tasks), with
//       the prompts that are missing;
//     · an import adds the file's tasks only when asked ("Add them, paused"), into the account in use's folder, and only when that folder
//       has no task file (one that is here stays; the preview lists the tasks it lacks). Every task is written with `enabled: false` and
//       nothing else changed, so nothing runs twice: the person turns each on in the window. A task is written only with its prompt: one
//       whose prompt isn't in the file, whose id the window wouldn't keep, whose recorded `filePath` points anywhere but its own prompt,
//       or whose prompt here is a different one, is listed and not written. The sessions an added task ran come in with it.
// - every write is the restore engine's: create-only, never through a link, journaled, so Undo takes back exactly what was added.

import Foundation

extension SessionsRestore {
    struct ConfigPlan: Equatable {
        enum Status: Equatable { case new, here, blocked(String) }
        struct Server: Equatable { var name: String; var runs: String }
        var present = false                     // the backup holds one
        var leftOut = true                      // the choice: left out unless asked
        var status: Status = .new
        var servers: [Server] = []              // what adding brings: each server's name and what it runs
        var otherKeys: [String] = []            // the file's other top-level settings, by name
        var lacking: [String] = []              // a file is here: the servers it doesn't have (by name; nothing is merged)
        var moreServers = 0                     // servers past the first 200 (the page lists those)
        var moreLacking = 0
        var unreadable = false                  // the backup's file isn't a JSON object under 8 MB: never added
        var leftOutAtSource: String?            // why the source left it out (a zip, a link, over 8 MB …)
        var added: Bool { !leftOut && status == .new && present && !unreadable }
    }

    struct TaskPlan: Equatable {
        enum Status: Equatable { case new, here, blocked(String) }
        struct Task: Equatable {
            var id: String
            var name: String
            var why: String?                    // why it isn't added (nil: it comes in, paused on an import)
            var schedule: String? = nil         // its cronExpression, as written
            var mode: String? = nil             // its permissionMode when it isn't the default one
            var folder: String? = nil           // the folder it runs in (cwd), ~ for the home folder
            /// It runs with permission checks off (bypassPermissions) or with permissions approved on the other Mac: worth a look
            /// before it is turned on.
            var risky = false
            var browserSkips = false            // its browser use skips all permission checks
            var carried = false                 // its permission mode was carried over
            var approved = false                // it holds permissions approved on the other Mac
            /// "Nightly digest · every day at 3:00 · in ~/projects/app · permissions: acceptEdits"
            var line: String {
                var parts = [name]
                if let s = schedule { parts.append(s) }
                if let f = folder { parts.append("in " + f) }
                if let m = mode { parts.append("permissions: " + m) }
                if approved { parts.append("approved permissions") }
                if browserSkips { parts.append("browser: no permission checks") }
                if carried { parts.append("permission mode carried over") }
                return parts.joined(separator: " · ")
            }
        }
        var moreTasks = 0                       // tasks past the first 200: written as the others, not listed one by one
        var risky: Int { riskyCount }
        var present = false                     // the backup holds a task file the plan could use
        var imported = false
        var leftOut = true                      // an import's choice: left out unless asked ("Add them, paused")
        var status: Status = .new
        var tasks: [Task] = []                  // every task of the file(s), with whether it comes
        var lacking: [String] = []              // a task file is here: the tasks it doesn't have (by name; it stays as it is)
        var prompts = 0                         // prompts the plan writes (each with its task)
        var promptsHere = 0                     // prompts already here, the same
        var writes = false                      // the plan writes a task file
        // (the lists keep the first 200 for the page; the counts are of all of them)
        var comingCount = 0                     // tasks that come (or would, if added)
        var riskyCount = 0                      // of them, with permission checks off or approved permissions
        var moreLacking = 0                     // tasks the file here lacks past those listed
        var coming: [Task] { tasks.filter { $0.why == nil } }
        var addedNames: [String] { writes ? coming.map(\.name) : [] }        // (the first of them: the list's)
        var addedCount: Int { writes ? comingCount : 0 }                       // all of them
        var addedRisky: Int { writes ? riskyCount : 0 }
    }

    /// The most entries a plan keeps for the page (tasks, servers and the names a file here lacks): the rest are counted.
    static let listCap = 200

    /// The tasks of a scheduled-tasks.json: the objects of its `scheduledTasks` array (anything else in it is skipped). [] when it isn't one.
    static func taskList(_ d: Data) -> [[String: Any]] {
        guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let list = j["scheduledTasks"] as? [Any] else { return [] }
        return list.compactMap { $0 as? [String: Any] }
    }

    /// The task that ran a Code-tab entry: its `scheduledTaskId`, exactly (nil: an ordinary session).
    static func taskID(_ entry: Data) -> String? {
        guard let j = (try? JSONSerialization.jsonObject(with: entry)) as? [String: Any], let id = j["scheduledTaskId"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// A task's name as the window shows it (its displayName), cut to plain printable text.
    static func taskName(_ t: [String: Any], id: String) -> String {
        let raw = (t["displayName"] as? String) ?? id
        let clean = SessionsBackup.oneLine(raw, max: 100)
        return clean.isEmpty ? SessionsBackup.oneLine(id, max: 100) : clean
    }

    /// The task file an import writes: the first file's object with its `scheduledTasks` replaced by `tasks`, each with `enabled: false`
    /// and nothing else changed. nil: it can't be made.
    static func pausedTasks(base: Data, tasks: [[String: Any]]) -> Data? {
        guard var j = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any] else { return nil }
        j["scheduledTasks"] = tasks.map { t -> [String: Any] in var t = t; t["enabled"] = false; return t }
        return try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: claude_desktop_config.json

    static func planConfig(_ p: inout Plan, _ t: Target, item: SessionsBackup.Item?, leftOutAtSource: String?, reader: Reader, add: Bool) {
        var cp = ConfigPlan()
        cp.leftOut = !add
        cp.leftOutAtSource = leftOutAtSource
        defer { p.config = cp }
        guard let item, let c = components(item.path) else { return }
        cp.present = true
        // the backup's file, read only under the cap, and only a JSON object
        var data: Data?
        if let f = reader.file(c) {
            if f.st.st_size <= SessionsBackup.maxConfigBytes { data = read(f.fd, size: f.st.st_size) }
            close(f.fd)
        }
        guard let d = data, let j = SessionsBackup.withoutSidebar(d) else { cp.unreadable = true; return }
        let servers = SessionsBackup.mcpServers(d)
        cp.servers = servers.prefix(listCap).map { ConfigPlan.Server(name: $0.name, runs: $0.runs) }
        cp.moreServers = max(0, servers.count - listCap)
        cp.otherKeys = j.keys.filter { $0 != "mcpServers" }.sorted().prefix(200).map { SessionsBackup.oneLine($0, max: 60) }
        // where it would go: the window's data folder, which must be there; a file of that name (or a link, or a folder) means "here"
        if t.dataDir.isEmpty { cp.status = .blocked("the profile has no Claude window folder"); return }
        guard Tree(path: t.dataDir) != nil else { cp.status = .blocked("the window's data folder isn't there"); return }
        let here = (t.dataDir as NSString).appendingPathComponent("claude_desktop_config.json")
        var st = stat()
        if lstat(here, &st) == 0 {
            cp.status = .here
            let mine = Set(Setup.readCapped(here, limit: SessionsBackup.maxConfigBytes).map { SessionsBackup.mcpServers($0).map(\.name) } ?? [])
            let lacking = servers.map(\.name).filter { !mine.contains($0) }
            cp.lacking = Array(lacking.prefix(listCap)); cp.moreLacking = max(0, lacking.count - listCap)
            return
        }
        cp.status = .new
        if add {
            // written without its sidebar part, whatever the file holds: the sidebar (and the folder permission modes it keeps) is
            // arranged only by the sidebar step, never brought in by a file's "Add them"
            guard let stripped = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { cp.unreadable = true; return }
            p.configPieces = [Piece(kind: .config, rel: c, base: .window, dirs: [], leaf: "claude_desktop_config.json", bytes: Int64(stripped.count), data: stripped)]
        }
    }

    // MARK: scheduled tasks

    /// Plans the task file (and its prompts); returns the ids of the tasks an import adds (their sessions then come in too).
    static func planTasks(_ p: inout Plan, _ t: Target, windowItems: [[String]], windowData: [String: Data], setupItems: [SessionsBackup.Item], reader: Reader,
                          imported: Bool, add: Bool, now nowWindow: WindowNow, scope: SeatID?, windowThere: Bool) -> Set<String> {
        var tp = TaskPlan()
        tp.imported = imported
        tp.leftOut = imported && !add
        defer { p.taskPlan = tp }
        let files = windowItems.filter { $0.count == 4 && $0[3] == "scheduled-tasks.json" }.sorted { ($0[1], $0[2]) < ($1[1], $1[2]) }
        guard !files.isEmpty else { return [] }
        var prompts: [String: SessionsBackup.Item] = [:]
        for it in setupItems {
            let u = Setup.unit(of: String(it.path.dropFirst(6)))
            if u.kind == .task { prompts[u.name] = it }
        }
        // a restore: only the account in use's own file, as it was
        let source: [[String]] = imported ? files : files.filter { c in scope.map { SeatID(account: c[1], organization: c[2]) == $0 } ?? false }
        guard !source.isEmpty else { return [] }
        tp.present = true

        // what is there to take: every task of the file(s), once each
        var seen = Set<String>(), list: [(task: [String: Any], id: String)] = []
        for c in source {
            for task in taskList(windowData[c.joined(separator: "/")] ?? Data()) {
                let id = task["id"] as? String ?? ""
                guard !id.isEmpty, seen.insert(id).inserted else { continue }
                list.append((task, id))
            }
        }
        let code: Tree? = {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: t.codeDir, isDirectory: &isDir) && isDir.boolValue ? Tree(path: t.codeDir) : nil
        }()
        /// The prompt here: nil (none), "same", "different", or "blocked" (a link or a file on the way).
        func promptHere(_ id: String, sha: String?) -> String? {
            guard let code else { return "blocked" }
            switch code.dir([Setup.taskFolder, id], create: false) {
            case .blocked: return "blocked"
            case .absent: return nil
            case .dir(let dfd):
                defer { close(dfd) }
                var st = stat()
                guard fstatat(dfd, "SKILL.md", &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
                guard (st.st_mode & S_IFMT) == S_IFREG else { return "different" }
                let fd = openat(dfd, "SKILL.md", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { return "different" }
                defer { close(fd) }
                return SessionsRestore.sha(fd: fd) == sha ? "same" : "different"
            }
        }
        var promptPieces: [Piece] = []
        var keep: [[String: Any]] = []
        var all: [(id: String, name: String)] = []              // every task, for what a file here lacks (the page lists the first 200)
        for (task, id) in list {
            var entry = TaskPlan.Task(id: SessionsBackup.oneLine(id, max: 200), name: taskName(task, id: id), why: nil)
            // what the person turns on when they flip its switch: its schedule, its folder, its permission mode and approvals
            entry.schedule = (task["cronExpression"] as? String).map { SessionsBackup.oneLine($0, max: 60) } ?? (task["fireAt"] != nil ? "once" : nil)
            entry.folder = (task["cwd"] as? String).map { SessionsBackup.oneLine(tilde($0), max: 120) }
            if let m = task["permissionMode"] as? String, m != "default" { entry.mode = SessionsBackup.oneLine(m, max: 40) }
            // (the window's own schema: chromePermissionMode is ask, skip_all_permission_checks or follow_a_plan; permissionModeCarried, true
            // or absent, marks a mode carried over from elsewhere, so it is flagged too)
            entry.browserSkips = (task["chromePermissionMode"] as? String) == "skip_all_permission_checks"
            entry.carried = (task["permissionModeCarried"] as? Bool) == true
            entry.approved = !((task["approvedPermissions"] as? [Any]) ?? []).isEmpty
            entry.risky = (task["permissionMode"] as? String) == "bypassPermissions" || !((task["approvedPermissions"] as? [Any]) ?? []).isEmpty
                || entry.browserSkips || entry.carried
            let item = prompts[id]
            if !Setup.validTaskID(id) {
                entry.why = "its id isn't one the Claude window keeps"
            } else if !((task["filePath"] as? String).map { $0 == Setup.taskRel(id) || $0.hasSuffix("/" + Setup.taskRel(id)) } ?? false) {
                // (the window reads a task's prompt from its id's own folder; a task without that `filePath`, as a string, isn't one as the window makes them)
                entry.why = task["filePath"] is String ? "it names a prompt file somewhere else" : "it doesn't record its prompt file the way the window does"
            } else if item == nil {
                // (a restore puts its own file back whole: such a task comes back too, and the row says what it lacks)
                entry.why = imported ? "its prompt isn't in the file" : "back without its prompt (none in the backup)"
            } else {
                switch promptHere(id, sha: item?.sha) {
                case "same": tp.promptsHere += 1
                case "different": entry.why = imported ? "a different prompt for it is here" : "back, with the prompt that is here (a different one)"
                case "blocked": entry.why = imported ? (code == nil ? "the Claude Code folder isn't there" : "a folder on the way to its prompt is a link or a file")
                                                     : "back without its prompt (a folder on the way is a link or a file)"
                default:
                    if let item, let c = components(item.path) {
                        promptPieces.append(Piece(kind: .setup, rel: c, base: .code, dirs: [Setup.taskFolder, id], leaf: "SKILL.md", bytes: item.bytes))
                    }
                }
            }
            if entry.why == nil { keep.append(task); tp.comingCount += 1; if entry.risky { tp.riskyCount += 1 } }
            all.append((entry.id, entry.name))
            if tp.tasks.count < listCap { tp.tasks.append(entry) } else { tp.moreTasks += 1 }
        }

        // where the file goes: the account in use's folder, only when it has no task file
        if t.dataDir.isEmpty { tp.status = .blocked("the profile has no Claude window folder"); return [] }
        guard let scope else { tp.status = .blocked("the profile isn't linked to an account yet"); return [] }
        guard windowThere else { tp.status = .blocked("the window's data folder isn't there"); return [] }
        if nowWindow.hasTasks.contains(where: { $0.account.lowercased() == scope.account.lowercased() && $0.organization.lowercased() == scope.organization.lowercased() }) {
            tp.status = .here
            let path = (SwitchEngine.scopeDir(t.dataDir, scope) as NSString).appendingPathComponent("scheduled-tasks.json")
            let mine = Set(Setup.readCapped(path, limit: 64 << 20).map { taskList($0).compactMap { $0["id"] as? String } } ?? [])
            let lacking = all.filter { !mine.contains($0.id) }.map(\.name)
            tp.lacking = Array(lacking.prefix(listCap)); tp.moreLacking = max(0, lacking.count - listCap)
            return []
        }
        tp.status = .new
        // (a restore puts its own file back whole, as it was, also a task whose prompt can't come with it: listed)
        guard !tp.leftOut, !keep.isEmpty || !imported else { return [] }
        let first = source[0]
        let rel = first, bytes: Int64
        var data: Data? = nil
        if imported {
            // the file's tasks, paused, and only those that come
            data = pausedTasks(base: windowData[first.joined(separator: "/")] ?? Data(), tasks: keep)
            guard let d = data else { return [] }
            bytes = Int64(d.count)
        } else {
            bytes = Int64(windowData[first.joined(separator: "/")]?.count ?? 0)
        }
        p.tasks = [Piece(kind: .tasks, rel: rel, base: .window, dirs: ["claude-code-sessions", scope.account, scope.organization], leaf: "scheduled-tasks.json",
                         bytes: bytes, from: SeatID(account: first[1], organization: first[2]), data: data)]
        p.taskPrompts = promptPieces
        tp.writes = true
        tp.prompts = promptPieces.count
        return imported ? Set(keep.compactMap { $0["id"] as? String }) : []
    }
}
