// SessionsRestore: putting a backup of a profile's sessions (SessionsBackup.swift) back. Input is a backup folder and the
// profile it goes to; output is a plan (what would happen, counted from the backup against what is there now, nothing
// written) and a run with its own receipt. It knows nothing of switches, so an unpacked export (SessionsImport.swift: a
// backup of the target profile, kind "imported", its accounts as fingerprints) restores by the same rules: an import's
// entries are all "another account's" (written as a switch would place them), the sessions a scheduled task ran are left
// out with the task's name, and the receipt names the file (Undo last import is Undo this restore on it).
//
// Restore merges and never overwrites:
//
// - it writes only files that don't exist: a new file is made with an exclusive create (or a clone that fails when the
//   name is taken, or a temp file linked into place), never over a file, never through a link. The backup is read through
//   directory descriptors without following a link, and a file in it that isn't a plain file with one link refuses the
//   whole restore; so does anything named like a sign-in (.claude.json, credentials, Keychain, OAuth) or a path that
//   isn't a plain relative one. No sign-in is ever written, and MCP settings and settings.json are never touched here;
// - by session id, across every account folder of the window's Code-tab list: an entry that is there and unchanged is
//   left (counted "back where it was"), one that is there and differs keeps what is there ("changed since", listed), one
//   made after the backup stays, one that was deleted since (the window's own deleted_ marker) stays deleted, and one
//   that is missing is written back, into the folder of the account the profile works on now, never into the folder of
//   an account it no longer uses. An entry that was on another account in the backup is written as a switch would
//   write it (SwitchEngine.placed: the old account's error keys and Remote Control ids off);
// - transcripts the same way, by their path under the Claude Code folder's projects: missing ones come back (cloned from
//   the backup, with the backup's modification time, so Claude Code's own clean-up sees their real age), those there
//   are left, those a running Claude Code session holds are left alone and listed;
// - the Claude window must be closed while its files are written, asked again before every one; if it opens the run
//   stops with what is back kept, and the receipt says so;
// - one run at a time (SwitchEngine.Lock: cl_audit's own, and claude-transplant's), and none while a switch of the
//   profile is unfinished;
// - a receipt (restores/<id>/receipt.json) and a journal beside it (journal.jsonl, one line appended before a file is
//   written and one after) say what was put back; Undo takes back exactly that, only files unchanged since, and
//   finishing a stopped run starts from the same receipt.

import CryptoKit
import Foundation

struct RestoreError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

enum SessionsRestore {
    /// Where restores keep their receipts.
    static var root: URL { Store.folder.appendingPathComponent("restores") }

    // MARK: what is restored into, and from

    /// The profile a backup goes to: its window's data folder, its Claude Code folder and the account its window works on.
    struct Target: Equatable {
        var profile: String
        var dataDir: String                 // expanded; "" when the profile has no window of its own
        var codeDir: String                 // expanded
        var inUse: SeatID?                  // the account whose folder missing entries go to; nil: none known

        init(profile: String, dataDir: String, codeDir: String, inUse: SeatID?) {
            self.profile = profile
            self.dataDir = dataDir.isEmpty ? "" : expand(dataDir)
            self.codeDir = expand(codeDir)
            self.inUse = inUse.flatMap { AccountDiscovery.isUUID($0.account) && AccountDiscovery.isUUID($0.organization) ? $0 : nil }
        }

        init(_ e: AccountEntry) {
            let s = SessionsBackup.Source(e)
            self.init(profile: e.id, dataDir: s.dataDir, codeDir: s.codeDir, inUse: e.seat.map(SeatID.init))
        }
    }

    /// One backup: a profile's folder under a place (General ▸ Backups, or the place a receipt recorded).
    struct Backup: Equatable {
        var profile: String
        var id: String
        var place: URL
        var dir: URL { SessionsBackup.folder(profile: profile, place: place).appendingPathComponent(id) }
    }

    // MARK: the plan

    /// One file to write: where it is in the backup, where it goes.
    struct Piece: Equatable {
        enum Kind: String, Codable { case entry, tasks, transcript, file }
        enum Base { case window, code }
        var kind: Kind
        var rel: [String]                   // the file's path inside the backup
        var base: Base
        var dirs: [String]                  // folders under the base, then the file
        var leaf: String
        var bytes: Int64
        var from: SeatID? = nil             // entry, tasks: the account folder it was in
        var rewrite = false                 // entry: written as a switch would (another account's)

        var dest: String { dirs.isEmpty ? leaf : dirs.joined(separator: "/") + "/" + leaf }
    }

    struct Plan: Equatable {
        var manifest: SessionsBackup.Manifest?
        var refusal: String?                // the whole restore is refused: nothing would be written
        var notes: [String] = []            // things left out or not possible, one sentence each
        var scope: SeatID?                  // the folder missing entries go to
        var ownScope = false                // the backup has entries from that same folder
        var entries: [Piece] = []
        var tasks: [Piece] = []
        var transcripts: [Piece] = []       // each .jsonl directly in a project's folder
        var files: [Piece] = []             // everything else of Claude Code's: sub-agent files, tool results…
        var backEntries = 0                 // there, unchanged since (also as a switch placed it)
        var backTranscripts = 0             // there, unchanged since
        var grownTranscripts = 0            // there, and longer now (the backup is its first part): left
        var madeAfter = 0                   // entries now that the backup doesn't have
        var madeAfterHere = 0               // of them, in the folder of the account in use
        var changed: [String] = []          // there and different: what is there stays (names for the list)
        var partial: [String] = []          // there, shorter, and the backup's file begins with it: a shorter copy of it, left as it is
        var inUse: [String] = []            // a running Claude Code session holds them: left alone
        var deletedSince: [String] = []     // the window deleted them since: they stay deleted
        var old = 0                         // transcripts to write that Claude Code's own clean-up would delete again (see Retention.swift)
        var oldWindow = 0                   // of them, sessions of the Claude window (only when a limit is set for those)
        var unsure = 0                      // transcripts to write whose keep time can't be told (settings.json doesn't say)
        var retention = Retention()         // what Claude Code's clean-up does here: cleanupPeriodDays, desktopSessionCleanupPeriodDays, managed
        var days: Int? { retention.days }   // cleanupPeriodDays as it applies (30 when not set); nil: unknown
        var otherAccount = 0                // entries to write that were on another account in the backup
        var sidebar: SidebarPlan?
        var checkedRunning = true           // false: whether sessions run couldn't be checked, so none is written
        var isImport = false                // the backup was unpacked from an export (SessionsImport.swift)
        var taskSessions: [String] = []     // an import leaves out the sessions scheduled tasks ran, with the task's name
        var memoryFiles: [String] = []      // <project>/memory/… files in the backup (Claude Code loads them into every session)
        var memoryLeftOut = false           // an import from another Mac or profile leaves them out unless asked ("Add them")

        var count: Int { entries.count + tasks.count + transcripts.count + files.count }
        var windowNeeded: Bool { !entries.isEmpty || !tasks.isEmpty }
        var written: Int { count }
    }

    /// A check's seam: the session ids Claude Code processes were started with (nil: it couldn't be told).
    nonisolated(unsafe) static var runningSessions: () -> Set<String>? = { psSessions() }
    /// A transcript changed in the last two minutes counts as held (a session resumed without its id on the command line).
    static let recent: TimeInterval = 120

    static func plainName(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains("\0") && s.utf8.count <= 255
    }

    /// A path inside a backup as its names, or nil when it is not a plain relative one.
    static func components(_ rel: String) -> [String]? {
        let c = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return !c.isEmpty && c.allSatisfy(plainName) ? c : nil
    }

    static func plan(_ t: Target, _ b: Backup, foreign: Bool = false, addMemory: Bool = false, now: Date = Date()) -> Plan {
        var p = Plan()
        func refuse(_ why: String) -> Plan { p.refusal = why; p.entries = []; p.tasks = []; p.transcripts = []; p.files = []; return p }
        guard SessionsBackup.validProfile(b.profile), SessionsBackup.validID(b.id), SessionsBackup.validProfile(t.profile) else {
            return refuse("The profile or backup name isn't a plain one.")
        }
        guard let m = SessionsBackup.load(profile: b.profile, id: b.id, place: b.place) else {
            return refuse("That backup isn't there any more, or its backup.json can't be read.")
        }
        p.manifest = m
        guard foreign || m.profile == t.profile else { return refuse("That backup is another profile's.") }
        guard m.version == 1 else { return refuse("That backup is from a newer cl_audit; nothing is restored from it.") }
        guard let reader = Reader(path: b.dir.path) else { return refuse("The backup's folder isn't a plain folder (a link, or gone).") }
        let imported = m.kind.isImport
        p.isImport = imported
        // memory files tell every session what to do: from ANY import file they stay out unless the operator adds them. (Whether
        // a file "came from this Mac and this profile" is only what the file says, and a forged file says it too: no trust.)
        let skipMemory = imported && !addMemory
        p.memoryLeftOut = skipMemory

        // 1. the backup's own claims: every path plain, no sign-in, every file a plain file with one link
        var seen = Set<String>()
        var windowItems: [(SessionsBackup.Item, [String])] = []
        var codeItems: [(SessionsBackup.Item, [String])] = []
        var sidebarItem: SessionsBackup.Item?
        for it in m.items {
            guard let c = components(it.path), seen.insert(it.path).inserted else {
                return refuse("backup.json names a path that isn't a plain one (\(it.path.prefix(80))); nothing is restored from it.")
            }
            switch it.role {
            case .window:
                // (an export keeps its accounts as fingerprints, never their ids)
                guard c.count == 4, c[0] == "window", AccountDiscovery.isUUID(c[1]) || (imported && Fingerprint.isValid(c[1])),
                      AccountDiscovery.isUUID(c[2]) || (imported && Fingerprint.isValid(c[2])) else {
                    return refuse("backup.json names a window file in a place it doesn't keep them (\(it.path.prefix(80))).")
                }
                windowItems.append((it, c))
            case .transcript:
                guard c.count >= 3, c[0] == "transcripts" else {
                    return refuse("backup.json names a transcript in a place it doesn't keep them (\(it.path.prefix(80))).")
                }
                codeItems.append((it, c))
            case .sidebar:
                guard c == ["sidebar", "epitaxyPrefs.json"] else { return refuse("backup.json names a sidebar file in a place it doesn't keep it.") }
                sidebarItem = it
            case .record:
                guard c.first == "records" else { return refuse("backup.json names a record in a place it doesn't keep them.") }
            }
            if it.role == .window || it.role == .transcript, c.dropFirst().contains(where: SessionsBackup.isSignIn) {
                return refuse("The backup holds something named like a sign-in (\((c.last ?? "").prefix(40))). A backup never holds one, so nothing is restored from it.")
            }
        }
        // the window's files are small: read once and kept; transcripts can be thousands and big: each checked, then closed at once
        var windowData: [String: Data] = [:]
        for (_, c) in windowItems {
            guard let f = reader.file(c), let d = read(f.fd, size: f.st.st_size) else {
                return refuse("A file in the backup isn't a plain file with one link, or isn't there (\(c.last ?? "")). Nothing is restored from it.")
            }
            close(f.fd)
            windowData[c.joined(separator: "/")] = d
        }
        for (_, c) in codeItems {
            guard let f = reader.file(c) else { return refuse("A file in the backup isn't a plain file with one link, or isn't there (\(c.last ?? "")). Nothing is restored from it.") }
            close(f.fd)
        }

        // 2. the window now
        let nowWindow = t.dataDir.isEmpty ? WindowNow() : WindowNow.read(t.dataDir)
        p.scope = t.inUse
        let scopeID = t.inUse
        var backupNames = Set<String>()
        let win: Tree? = windowItems.isEmpty || t.dataDir.isEmpty ? nil : Tree(path: t.dataDir)
        if !windowItems.isEmpty {
            if t.dataDir.isEmpty {
                p.notes.append("The profile has no Claude window folder, so the window's entries aren't restored.")
            } else if scopeID == nil {
                p.notes.append("The profile isn't linked to an account yet, so there is no folder in the window to restore entries into; they aren't restored.")
            } else if win == nil {
                p.notes.append("The window's data folder isn't there, so its entries aren't restored.")
            }
        }
        var restoredIDs: [(id: String, data: Data, from: SeatID)] = []
        // one session id in two account folders of the backup is one entry: the copy from the account in use comes first
        let ordered = windowItems.sorted { a, b in
            let (x, y) = (a.1[3].lowercased(), b.1[3].lowercased())
            if x != y { return x < y }
            let (ax, ay) = (scopeID.map { SeatID(account: a.1[1], organization: a.1[2]) == $0 } ?? false, scopeID.map { SeatID(account: b.1[1], organization: b.1[2]) == $0 } ?? false)
            if ax != ay { return ax }
            return (a.1[1], a.1[2]) < (b.1[1], b.1[2])
        }
        // an import leaves out the sessions that scheduled tasks ran: the task belongs to its account and isn't imported
        var taskNames: [String: String] = [:]
        if imported {
            for (_, c) in windowItems where c[3] == "scheduled-tasks.json" {
                guard let d = windowData[c.joined(separator: "/")], let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                for t in (j["scheduledTasks"] as? [[String: Any]]) ?? [] {
                    if let id = t["id"] as? String { taskNames[id] = (t["displayName"] as? String) ?? (t["name"] as? String) ?? (t["title"] as? String) ?? id }
                }
            }
        }
        // the Claude Code sessions those entries belong to (their transcript and its folder are left out with them)
        var taskCLI = Set<String>()
        if imported {
            for (_, c) in windowItems where c[3].hasPrefix("local_") {
                guard let d = windowData[c.joined(separator: "/")], taskOrigin(d, names: taskNames) != nil,
                      let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let cli = j["cliSessionId"] as? String, !cli.isEmpty else { continue }
                taskCLI.insert(cli.lowercased())
            }
        }
        var handled = Set<String>()
        for (it, c) in ordered {
            let name = c[3], from = SeatID(account: c[1], organization: c[2])
            if name.hasPrefix("local_"), name.hasSuffix(".json"), AccountDiscovery.isUUID(String(name.dropFirst(6).dropLast(5))) {
                guard handled.insert(name.lowercased()).inserted else { continue }
                backupNames.insert(name.lowercased())
                let sid = String(name.dropFirst(6).dropLast(5))
                let bdata = windowData[c.joined(separator: "/")] ?? Data()
                if let paths = nowWindow.entries[name.lowercased()] {
                    let placedData = (try? SwitchEngine.placed(bdata)) ?? bdata
                    let same = paths.contains { path in
                        guard let cur = FileManager.default.contents(atPath: path) else { return false }
                        return cur == bdata || sameJSON(cur, placedData)
                    }
                    if same { p.backEntries += 1 } else { p.changed.append(name) }
                } else if nowWindow.deleted.contains(sid.lowercased()) {
                    p.deletedSince.append(name)
                } else if let scope = scopeID, win != nil {
                    if imported, let task = taskOrigin(bdata, names: taskNames) {
                        p.taskSessions.append("\(task) · session \(sid.prefix(8))")
                        continue
                    }
                    let rewrite = from != scope
                    p.entries.append(Piece(kind: .entry, rel: c, base: .window,
                                           dirs: ["claude-code-sessions", scope.account, scope.organization], leaf: name,
                                           bytes: Int64(it.bytes), from: from, rewrite: rewrite))
                    if rewrite { p.otherAccount += 1 } else { p.ownScope = true }
                    restoredIDs.append((id: "local_" + sid, data: bdata, from: from))
                }
            } else if name == "scheduled-tasks.json" {
                guard let scope = scopeID, win != nil, from == scope else { continue }       // only the account in use's own file
                if !nowWindow.hasTasks.contains(from) {
                    p.tasks.append(Piece(kind: .tasks, rel: c, base: .window,
                                         dirs: ["claude-code-sessions", scope.account, scope.organization], leaf: name,
                                         bytes: Int64(it.bytes), from: from))
                }
            }
            // deleted_ markers and anything else the window keeps are never written back
        }
        for (name, paths) in nowWindow.entries where !backupNames.contains(name) {
            p.madeAfter += 1
            if let scope = scopeID {
                let dir = SwitchEngine.scopeDir(t.dataDir, scope)
                if paths.contains(where: { ($0 as NSString).deletingLastPathComponent == dir }) { p.madeAfterHere += 1 }
            }
        }
        p.changed.sort(); p.deletedSince.sort()
        p.entries.sort { $0.leaf < $1.leaf }

        // 3. Claude Code's transcripts now
        p.retention = Retention.read(codeDir: t.codeDir)
        if !codeItems.isEmpty {
            // the sessions the window's Code tab will name afterwards: its entries now, and the ones this restore writes
            // (managed settings give every transcript one limit: nothing to tell then)
            var windowCLI = Set<String>()
            if !p.retention.managed {
                if !t.dataDir.isEmpty { windowCLI = Retention.windowSessions(dataDir: t.dataDir) }
                for r in restoredIDs { if let id = Retention.cliSession(r.data) { windowCLI.insert(id) } }
            }
            planTranscripts(&p, t, codeItems.map { $0.1 }, reader: reader, now: now, skipSessions: taskCLI, skipMemory: skipMemory, windowSessions: windowCLI)
        }

        // 4. the sidebar: where the restored entries sat, from the backup's own records
        if !restoredIDs.isEmpty, sidebarItem != nil, let f = reader.file(["sidebar", "epitaxyPrefs.json"]) {
            defer { close(f.fd) }
            if let prefs = (try? JSONSerialization.jsonObject(with: read(f.fd, size: f.st.st_size) ?? Data())) as? [String: Any] {
                p.sidebar = sidebarPlan(prefs: prefs, restored: restoredIDs, imported: imported)
            }
        }
        return p
    }

    /// The name of the scheduled task that ran this session's entry, when the entry says so: a key naming a scheduled task
    /// (its name, else its id looked up in the task files). nil: an ordinary session.
    /// (UNVERIFIED against a real entry: no code of cl_audit knows which key marks a scheduled task's session, and the
    /// operator's real data was not read to find out. Any top-level key with "scheduledtask" in its name is taken to.)
    static func taskOrigin(_ entry: Data, names: [String: String]) -> String? {
        guard let j = (try? JSONSerialization.jsonObject(with: entry)) as? [String: Any] else { return nil }
        let keys = j.keys.filter { $0.lowercased().contains("scheduledtask") }.sorted()
        for k in keys where k.lowercased().contains("name") { if let s = j[k] as? String, !s.isEmpty { return s } }
        for k in keys { if let s = j[k] as? String, !s.isEmpty { return names[s] ?? s } }
        return nil
    }

    private static func isMemory(_ rel: [String]) -> Bool { rel.count >= 3 && rel[1] == "memory" }

    private static func planTranscripts(_ p: inout Plan, _ t: Target, _ items: [[String]], reader: Reader, now: Date,
                                        skipSessions: Set<String> = [], skipMemory: Bool = false, windowSessions: Set<String> = []) {
        p.memoryFiles = items.map { Array($0.dropFirst()) }.filter(isMemory).map { $0.joined(separator: "/") }.sorted()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: t.codeDir, isDirectory: &isDir), isDir.boolValue, let code = Tree(path: t.codeDir) else {
            p.notes.append("The Claude Code folder isn't there, so the transcripts aren't restored.")
            return
        }
        var st = stat()
        if lstat((t.codeDir as NSString).appendingPathComponent("projects"), &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR {
            p.notes.append("projects in the Claude Code folder is a link, not a folder (it may share its history from another): nothing is written through a link, so the transcripts aren't restored.")
            return
        }
        let running = runningSessions()
        if running == nil { p.checkedRunning = false; p.notes.append("It couldn't be checked which Claude Code sessions run, so no missing transcript is written back.") }
        let held = running ?? []
        var blocked = 0
        var markers: [[String]] = []
        for c in items {
            let rel = Array(c.dropFirst())                                  // <project>/…
            let leaf = rel.last!
            let top = rel.count == 2 && leaf.hasSuffix(".jsonl")
            let session = top ? String(leaf.dropLast(".jsonl".count)).lowercased() : rel.count >= 3 ? rel[1].lowercased() : ""
            let name = rel.joined(separator: "/")
            if skipMemory, isMemory(rel) { continue }                       // left out: listed (memoryFiles), never written
            if !skipSessions.isEmpty, skipSessions.contains(session) { continue }     // a scheduled task's session: transcript and folder stay out
            // Claude Code's retention marker (<session>.desktop-released.json): written only with its transcript, below
            if rel.count == 2, SessionsExport.markerID(leaf) != nil { markers.append(c); continue }
            guard let src = reader.file(c) else { continue }
            defer { close(src.fd) }
            let piece = Piece(kind: top ? .transcript : .file, rel: c, base: .code, dirs: ["projects"] + rel.dropLast(), leaf: leaf, bytes: Int64(src.st.st_size))
            let holds = held.contains(session) || !p.checkedRunning
            func leave() { if top { p.inUse.append(name) } }                // a session's other files go with it, unlisted
            switch code.dir(piece.dirs, create: false) {
            case .blocked:
                if top { blocked += 1 }
            case .absent:
                if holds { leave() } else { add(&p, piece, mtime: src.st.st_mtimespec.tv_sec, now: now, windowSessions: windowSessions) }
            case .dir(let dfd):
                defer { close(dfd) }
                var cur = stat()
                if fstatat(dfd, leaf, &cur, AT_SYMLINK_NOFOLLOW) != 0 {
                    if holds { leave() } else { add(&p, piece, mtime: src.st.st_mtimespec.tv_sec, now: now, windowSessions: windowSessions) }
                    continue
                }
                guard (cur.st_mode & S_IFMT) == S_IFREG else { p.changed.append(name); continue }      // a link or folder where a file goes
                let age = now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(cur.st_mtimespec.tv_sec)))
                if held.contains(session) || (top && age < recent) { leave(); continue }
                let fd = openat(dfd, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { p.changed.append(name); continue }
                defer { close(fd) }
                var cst = stat()
                guard fstat(fd, &cst) == 0, (cst.st_mode & S_IFMT) == S_IFREG else { p.changed.append(name); continue }
                // same size and the same modification time (a clone keeps the original's): unchanged, without reading GBs again
                let sameStamp = cst.st_size == src.st.st_size && cst.st_mtimespec.tv_sec == src.st.st_mtimespec.tv_sec
                    && cst.st_mtimespec.tv_nsec == src.st.st_mtimespec.tv_nsec
                switch sameStamp ? .same : compare(backup: src.fd, off_t(src.st.st_size), current: fd, off_t(cst.st_size)) {
                case .same: if top { p.backTranscripts += 1 }
                case .grown: if top { p.grownTranscripts += 1; p.backTranscripts += 1 }
                case .different:
                    // the backup's file begins with it: a shorter copy of it (what a crash during a copy from another volume
                    // leaves, among other things; it can't be told which), not something that changed. Left as it is, and said so.
                    if cst.st_size < src.st.st_size, compare(backup: fd, off_t(cst.st_size), current: src.fd, off_t(src.st.st_size)) == .grown {
                        p.partial.append(name)
                    } else { p.changed.append(name) }
                }
            }
        }
        // a marker comes back only when its transcript is written by this run, and never over a marker that is there; Undo then
        // takes both back, as pieces of the same run
        for c in markers {
            let rel = Array(c.dropFirst()), leaf = rel.last!
            guard let id = SessionsExport.markerID(leaf), rel.count == 2,
                  p.transcripts.contains(where: { $0.dirs == ["projects", rel[0]] && $0.leaf.lowercased() == id + ".jsonl" }),
                  let src = reader.file(c) else { continue }
            defer { close(src.fd) }
            let piece = Piece(kind: .file, rel: c, base: .code, dirs: ["projects", rel[0]], leaf: leaf, bytes: Int64(src.st.st_size))
            switch code.dir(piece.dirs, create: false) {
            case .blocked: continue
            case .absent: add(&p, piece, mtime: src.st.st_mtimespec.tv_sec, now: now)
            case .dir(let dfd):
                defer { close(dfd) }
                var cur = stat()
                if fstatat(dfd, leaf, &cur, AT_SYMLINK_NOFOLLOW) != 0 { add(&p, piece, mtime: src.st.st_mtimespec.tv_sec, now: now) }
            }
        }
        p.partial.sort()
        if blocked > 0 {
            p.notes.append("\(blocked) transcript\(blocked == 1 ? "" : "s") would go through a link in a project's folder, so they aren't written back.")
        }
        p.changed = p.changed.sorted()
        p.inUse.sort()
        p.transcripts.sort { $0.leaf < $1.leaf }
    }

    private static func add(_ p: inout Plan, _ piece: Piece, mtime: Int, now: Date, windowSessions: Set<String> = []) {
        if piece.kind == .transcript {
            p.transcripts.append(piece)
            // Claude Code's clean-up: sessions of the window are kept (unless a limit is set for them), the rest after cleanupPeriodDays
            let window = windowSessions.contains(String(piece.leaf.dropLast(".jsonl".count)).lowercased())
            switch p.retention.verdict(window: window, modified: Date(timeIntervalSince1970: TimeInterval(mtime)), now: now) {
            case .delete: p.old += 1; if window { p.oldWindow += 1 }
            case .unknown: p.unsure += 1
            case .keep: break
            }
        } else {
            p.files.append(piece)
        }
    }

    /// The sidebar arrangement of the entries that come back, from the backup's records, scope by scope (an entry keeps
    /// the groups it had on the account it was on).
    /// A group name from an export as the helper session's prompt may carry it: letters, digits, spaces and - _ . , ( ) & ' only,
    /// at most 40 characters; the rest is taken out. "": the group is dropped (its sessions stay ungrouped).
    static func importGroupName(_ s: String) -> String {
        let extra: Set<Character> = ["-", "_", ".", ",", "(", ")", "&", "'"]
        let kept = String(s.filter { $0.isLetter || $0.isNumber || $0 == " " || extra.contains($0) })
        let words = kept.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(words.prefix(40)).trimmingCharacters(in: .whitespaces)
    }

    static func sidebarPlan(prefs: [String: Any], restored: [(id: String, data: Data, from: SeatID)], imported: Bool = false) -> SidebarPlan? {
        var merged = SidebarPlan()
        var bySource: [SeatID: [(id: String, data: Data)]] = [:]
        for r in restored { bySource[r.from, default: []].append((r.id, r.data)) }
        for source in bySource.keys.sorted(by: { ($0.account, $0.organization) < ($1.account, $1.organization) }) {
            let list = bySource[source] ?? []
            let moving = list.filter { !SidebarPlan.flag("isArchived", in: $0.data) }.map(\.id)
            let pinned = list.filter { !SidebarPlan.flag("isArchived", in: $0.data) && SidebarPlan.flag("isStarred", in: $0.data) }.map(\.id)
            let one = SidebarPlan.read(prefs: prefs, scope: "\(source.account)/\(source.organization)", moving: moving, pinned: pinned)
            for g in one.groups {
                if let i = merged.groups.firstIndex(where: { $0.id == g.id }) {
                    merged.groups[i].sessions += g.sessions.filter { !merged.groups[i].sessions.contains($0) }
                } else { merged.groups.append(g) }
            }
            merged.pinned += one.pinned.filter { !merged.pinned.contains($0) }
            if let l = one.left { merged.left = (merged.left ?? 0) + l }
        }
        if imported {
            // names from a file that came from elsewhere reach the helper session's prompt: only plain ones do
            merged.groups = merged.groups.compactMap { g in
                var g = g
                g.name = importGroupName(g.name)
                if g.sort != nil, g.sort != "alpha", g.sort != "created" { g.sort = nil }
                return g.name.isEmpty ? nil : g
            }
        }
        merged.restored = true
        return merged.isEmpty ? nil : merged
    }

    // MARK: reading the backup, and what is there now

    /// An open backup folder: files are opened one name at a time without following a link.
    final class Reader {
        private let root: Int32
        init?(path: String) {
            let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            root = fd
        }
        deinit { close(root) }

        /// The file at that path, opened for reading: only when every part is a real folder and the file a plain one with
        /// one hard link. The caller closes it.
        func file(_ rel: [String]) -> (fd: Int32, st: stat)? {
            guard let leaf = rel.last else { return nil }
            var dir = root
            var held: [Int32] = []
            defer { for f in held { close(f) } }
            for c in rel.dropLast() {
                let n = openat(dir, c, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard n >= 0 else { return nil }
                held.append(n); dir = n
            }
            let fd = openat(dir, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { return nil }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else { close(fd); return nil }
            return (fd, st)
        }
    }

    /// A folder tree's directories, opened one name at a time without following a link (made when asked to).
    final class Tree {
        /// `.dir`: the folder's descriptor, which the caller closes.
        enum Dir { case dir(Int32), absent, blocked }
        let path: String
        private let base: Int32
        private(set) var made: [String] = []        // folders this run made, absolute, in order
        /// Told the folder's path just before it is made (so a crash leaves it written down) and again if it then wasn't.
        var willMake: ((String) -> Void)?
        var madeFailed: ((String) -> Void)?

        /// The top folder itself is opened as given (it is where the user keeps it); nothing below it may be a link.
        init?(path: String) {
            let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY)
            guard fd >= 0 else { return nil }
            self.path = path; base = fd
        }
        deinit { close(base) }

        /// Opened afresh each time (a few openat calls): a long list of projects never holds descriptors open.
        func dir(_ comps: [String], create: Bool) -> Dir {
            var cur = dup(base)
            guard cur >= 0 else { return .blocked }
            for (i, c) in comps.enumerated() {
                var f = openat(cur, c, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if f < 0 {
                    let why = errno
                    guard why == ENOENT else { close(cur); return .blocked }              // a link, a file, or no access
                    guard create else { close(cur); return .absent }
                    let abs = (path as NSString).appendingPathComponent(comps[0...i].joined(separator: "/"))
                    willMake?(abs)
                    if mkdirat(cur, c, 0o700) == 0 { made.append(abs) }
                    else {
                        let e = errno                                                                   // before the callback can change it
                        madeFailed?(abs)
                        if e != EEXIST { close(cur); return .blocked }                                  // made meanwhile by someone else: not ours
                    }
                    f = openat(cur, c, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    guard f >= 0 else { close(cur); return .blocked }
                }
                close(cur); cur = f
            }
            return .dir(cur)
        }
    }

    /// The window's Code-tab list as it is now: entries by name across every account folder, deleted markers by session
    /// id, which accounts have a task file. Links are never followed.
    struct WindowNow {
        var entries: [String: [String]] = [:]       // "local_<id>.json" → the paths (one per account folder that has it)
        var deleted = Set<String>()                 // session ids (lower case) with a deleted_ marker in any folder
        var hasTasks = Set<SeatID>()

        static func read(_ dataDir: String) -> WindowNow {
            var w = WindowNow()
            let fm = FileManager.default
            let root = (dataDir as NSString).appendingPathComponent("claude-code-sessions")
            func isDir(_ p: String) -> Bool { var st = stat(); return lstat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR }
            for account in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() where isDir((root as NSString).appendingPathComponent(account)) {
                let adir = (root as NSString).appendingPathComponent(account)
                for org in ((try? fm.contentsOfDirectory(atPath: adir)) ?? []).sorted() where isDir((adir as NSString).appendingPathComponent(org)) {
                    let odir = (adir as NSString).appendingPathComponent(org)
                    for name in ((try? fm.contentsOfDirectory(atPath: odir)) ?? []).sorted() {
                        let path = (odir as NSString).appendingPathComponent(name)
                        var st = stat()
                        guard lstat(path, &st) == 0 else { continue }
                        if name.hasPrefix("deleted_") { w.deleted.insert(String(name.dropFirst("deleted_".count)).lowercased()); continue }
                        guard (st.st_mode & S_IFMT) == S_IFREG else { continue }
                        // names are compared case-insensitively (the Mac's disks ignore case)
                        if name.hasPrefix("local_"), name.hasSuffix(".json") { w.entries[name.lowercased(), default: []].append(path) }
                        else if name == "scheduled-tasks.json" { w.hasTasks.insert(SeatID(account: account, organization: org)) }
                    }
                }
            }
            return w
        }
    }

    /// Whether two JSON objects hold the same keys and values (the bytes may differ: a dictionary writes its keys in any order).
    static func sameJSON(_ a: Data, _ b: Data) -> Bool {
        guard let x = try? JSONSerialization.jsonObject(with: a) as? NSDictionary, let y = try? JSONSerialization.jsonObject(with: b) as? NSDictionary else { return false }
        return x.isEqual(to: y)
    }

    static func read(_ fd: Int32, size: off_t) -> Data? {
        guard size >= 0, size <= 64 << 20 else { return nil }            // an entry or a records file: never huge
        var data = Data(count: Int(size))
        let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(size), 0) }
        return n == Int(size) ? data : nil
    }

    enum Cmp { case same, grown, different }

    /// Whether the file now is the backup's file (`same`), the backup's file with more after it (`grown`: a transcript
    /// that went on), or something else. Streams both; stops at the first difference.
    static func compare(backup a: Int32, _ asize: off_t, current b: Int32, _ bsize: off_t) -> Cmp {
        guard bsize >= asize else { return .different }
        let chunk = 1 << 20
        var x = [UInt8](repeating: 0, count: chunk), y = [UInt8](repeating: 0, count: chunk)
        var off: off_t = 0
        while off < asize {
            let want = Int(min(off_t(chunk), asize - off))
            let n = pread(a, &x, want, off), m = pread(b, &y, want, off)
            guard n == want, m == want else { return .different }
            if memcmp(x, y, want) != 0 { return .different }
            off += off_t(want)
        }
        return bsize == asize ? .same : .grown
    }

    static func sha(fd: Int32) -> String? {
        var h = SHA256()
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var off: off_t = 0
        while true {
            let n = pread(fd, &buf, buf.count, off)
            if n < 0 { return nil }
            if n == 0 { break }
            h.update(data: buf[0..<n])
            off += off_t(n)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The session ids on the command lines of Claude Code processes (`--resume <id>`, `--session-id <id>`): one `ps`.
    /// Limits: a session resumed from its own picker, or with --continue, isn't named there; the transcript's age covers it.
    static func psSessions() -> Set<String>? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box(), done = DispatchGroup()
        done.enter()
        DispatchQueue.global(qos: .utility).async { box.data = pipe.fileHandleForReading.readDataToEndOfFile(); done.leave() }
        if done.wait(timeout: .now() + 5) == .timedOut { p.terminate(); return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0, let re = try? NSRegularExpression(pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}") else { return nil }
        var out = Set<String>()
        for line in String(decoding: box.data, as: UTF8.self).split(separator: "\n") where line.localizedCaseInsensitiveContains("claude") {
            let s = String(line)
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) { out.insert((s as NSString).substring(with: m.range).lowercased()) }
        }
        return out
    }

    // MARK: the receipt

    /// What a run put back, for Undo and for finishing it. The header is receipt.json; the steps are journal.jsonl.
    struct Receipt: Codable, Equatable {
        struct Step: Equatable {
            enum Kind: String, Codable { case entry, tasks, transcript, file, dir }
            var kind: Kind
            var path: String
            var sha: String?
            var bytes: Int64
            var done = false
            /// An Undo has dealt with it for good: taken back, already gone, or left because it changed since. Only a
            /// restored transcript a running session held stays unsettled, for the next Undo.
            var settled = false
        }
        var id: String
        var profile: String
        var dataDir: String
        var codeDir: String
        var backup: String
        var backupPlace: String
        var target: SeatID?
        var started: Date
        var planned = 0                     // files to write when it started (more when it was finished later)
        var finished: Date?
        var undone: Date?
        var stopped: String?                // why it stopped, when it did
        var problems: [String] = []
        var sidebar: SidebarPlan?
        var changed: [String] = []          // there and different: left as they were (capped)
        var changedCount = 0
        var inUse: [String] = []
        var inUseCount = 0
        var deletedCount = 0
        var afterSwitch: String?            // Undo this switch: the receipt of the switch that was switched back
        var partialCount = 0                // shorter copies of a backup file that were there: left as they were
        var undoLeft = 0                    // an Undo left this many restored transcripts in place (a session holds them): it is still open
        var importedFrom: String?           // an import: the export file's name (the receipt is then "Undo last import")
        var sessionsAdded = 0               // an import: the sessions (transcripts) it added, for the Sessions card
        var entriesAdded = 0                // an import: the Code-tab entries it added (never counted as sessions)
        var steps: [Step] = []              // from the journal

        private enum CodingKeys: String, CodingKey {
            case id, profile, dataDir, codeDir, backup, backupPlace, target, started, planned, finished, undone, stopped, problems,
                 sidebar, changed, changedCount, inUse, inUseCount, deletedCount, afterSwitch, partialCount, undoLeft, importedFrom, sessionsAdded, entriesAdded
        }

        /// Wrote something and neither finished nor was undone: Undo applies, and so does finishing it.
        var unfinished: Bool { undone == nil && finished == nil && !steps.isEmpty }
        var back: Int { steps.filter { $0.done && $0.kind != .dir }.count }
        /// Written down but not marked done and not checked (a window file while the window was open): probably there, and
        /// Undo takes it back if it is exactly what the step says; not counted in `back`.
        var unchecked: Int { steps.filter { !$0.done && $0.kind != .dir }.count }
        /// Window files this receipt still has to answer for: entry and task steps an Undo hasn't settled yet. A second Undo
        /// with only transcripts left never needs the window.
        var windowTouched: Bool { steps.contains { ($0.kind == .entry || $0.kind == .tasks) && !$0.settled } }
    }

    private struct Event: Codable {
        var op: String                      // intent, done, gone
        var kind: Receipt.Step.Kind?
        var path: String
        var sha: String?
        var bytes: Int64?
    }

    static func receiptID(_ d: Date, _ profile: String) -> String { SwitchEngine.receiptID(d, profile) }

    private static func dir(_ id: String) -> URL { root.appendingPathComponent(id) }

    static func save(_ r: Receipt) throws {
        let d = dir(r.id)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(r).write(to: d.appendingPathComponent("receipt.json"), options: .atomic)
    }

    /// The receipt's header alone (no journal): enough to tell whether a restore is unfinished.
    static func header(_ id: String) -> Receipt? {
        guard validReceiptID(id) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let r = (try? Data(contentsOf: dir(id).appendingPathComponent("receipt.json"))).flatMap({ try? dec.decode(Receipt.self, from: $0) }),
              r.id == id else { return nil }
        return r
    }

    static func load(_ id: String) -> Receipt? {
        guard var r = header(id) else { return nil }
        r.steps = steps(id)
        return r
    }

    static func validReceiptID(_ s: String) -> Bool { plainName(s) && !s.hasPrefix(".") && s.range(of: #"^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}-.+$"#, options: .regularExpression) != nil }

    private static func steps(_ id: String) -> [Receipt.Step] {
        guard let text = try? String(contentsOf: dir(id).appendingPathComponent("journal.jsonl"), encoding: .utf8) else { return [] }
        var out: [Receipt.Step] = []
        let dec = JSONDecoder()
        for line in text.split(separator: "\n") {
            guard let e = try? dec.decode(Event.self, from: Data(line.utf8)) else { continue }       // a line cut short by a crash
            switch e.op {
            case "intent": out.append(Receipt.Step(kind: e.kind ?? .file, path: e.path, sha: e.sha, bytes: e.bytes ?? 0))
            case "done": if let i = out.lastIndex(where: { $0.path == e.path }) { out[i].done = true; if let h = e.sha { out[i].sha = h } }
            case "gone": out.removeAll { $0.path == e.path && !$0.done }
            case "settled": if let i = out.lastIndex(where: { $0.path == e.path }) { out[i].settled = true }
            default: break
            }
        }
        return out
    }

    private final class Journal {
        let fd: Int32
        init?(id: String) {
            try? FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let f = Darwin.open(dir(id).appendingPathComponent("journal.jsonl").path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
            guard f >= 0 else { return nil }
            fd = f
        }
        deinit { close(fd) }
        func add(_ e: Event, sync: Bool) {
            guard var line = try? JSONEncoder().encode(e) else { return }
            line.append(0x0A)
            _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if sync { fsync(fd) }
        }
    }

    /// Every restore, newest first.
    static func receipts() -> [Receipt] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(validReceiptID).compactMap(load).sorted { $0.started > $1.started }
    }

    /// Restores that wrote something and neither finished nor were undone, newest first (every profile's, or one's). Only
    /// the headers of the others are read: the journal of a long finished restore is never folded for this.
    static func unfinished(profile: String? = nil) -> [Receipt] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(validReceiptID).compactMap(header)
            .filter { $0.finished == nil && $0.undone == nil && (profile == nil || $0.profile == profile) }
            .compactMap { load($0.id) }.filter(\.unfinished).sorted { $0.started > $1.started }
    }

    // MARK: whether one may start

    /// Why a restore of this profile may not start, or nil: a switch of it that stopped half way (its receipt puts back
    /// exactly what it moved; then restore if anything is still missing) or another restore that stopped.
    static func blocker(profile: String, except id: String? = nil) -> (words: String, switchKey: String?)? {
        if let s = SwitchEngine.unfinished(profile: profile).first {
            return ("A switch of this profile stopped half way on \(SessionsBackup.dateWords(s.started)). Undo it first: its receipt puts back exactly what it moved; then restore if anything is still missing.",
                    AccountEntry.standbyStatusID(s.profile, s.standby))
        }
        if let r = unfinished(profile: profile).first(where: { $0.id != id }) {
            return ("A restore of this profile stopped half way on \(SessionsBackup.dateWords(r.started)). Finish it or undo it first.", nil)
        }
        return nil
    }

    /// A switch (or another restore) that holds this Claude window closed right now (SwitchMarker), or nil. The restore
    /// that asks is not one: its own mark is `restore-<id>` (its runner's name, passed as `own`) by this process for this profile.
    static func markerBlocker(profile: String, dataDir: String, own: String? = nil) -> String? {
        guard !dataDir.isEmpty, let m = SwitchMarker.current(FolderKey.canonical(dataDir)) else { return nil }
        // exempt: only the mark of the caller itself (each restore runner has its own name, "restore-<id>")
        if let own, m.pid == getpid(), m.profile == profile, m.standby == own { return nil }
        return "A switch or a restore of this Claude window is under way (since \(SessionsBackup.dateWords(m.started))). Wait for it, or undo it."
    }

    /// Whether one switch, restore or import is under way elsewhere (cl_audit's own lock) or claude-transplant is moving
    /// sessions (its lock): the words, or nil. Takes the locks and lets go at once. Taking claude-transplant's flock for
    /// that instant can make a `lockf -t 0` caller that starts in that very moment fail once; it is only a look.
    static func busy() -> String? {
        do { try SwitchEngine.Lock.take().release(); return nil } catch { return "\(error)" }
    }

    // MARK: paths of a receipt

    /// The folder a step's path is under: the window's data folder or the Claude Code folder.
    static func base(of path: String, _ r: Receipt) -> String? {
        if !r.dataDir.isEmpty, path.hasPrefix(r.dataDir + "/") { return r.dataDir }
        if !r.codeDir.isEmpty, path.hasPrefix(r.codeDir + "/") { return r.codeDir }
        return nil
    }

    /// The names of `path` under `base`, each a plain one (no ".", "..", empty).
    static func relative(_ path: String, under base: String) -> [String]? {
        guard path.hasPrefix(base + "/") else { return nil }
        let c = path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return !c.isEmpty && c.allSatisfy(plainName) ? c : nil
    }

    /// The first 20 characters of a receipt id (when and a random part): what names its temp files.
    static func tag(_ id: String) -> String { String(id.prefix(20)) }

    /// Takes away the temp files this restore made beside the entries it wrote (".restore-<tag>-….tmp"): a crash between
    /// the temp file and its removal leaves one, and the entry then has two links. Only names with that prefix, only
    /// plain files, through the folder's own descriptor.
    static func sweepTemps(_ r: Receipt) {
        let prefix = ".restore-\(tag(r.id))-"
        var seen = Set<String>()
        for s in r.steps where s.kind == .entry || s.kind == .tasks {
            let parent = (s.path as NSString).deletingLastPathComponent
            guard seen.insert(parent).inserted, let b = base(of: s.path, r), let rel = relative(s.path, under: b),
                  let tree = Tree(path: b), case .dir(let pfd) = tree.dir(Array(rel.dropLast()), create: false) else { continue }
            defer { close(pfd) }
            for n in ((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []) where n.hasPrefix(prefix) && n.hasSuffix(".tmp") {
                var st = stat()
                if fstatat(pfd, n, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFREG { unlinkat(pfd, n, 0) }
            }
        }
    }

    /// A stopped run's steps that were written down but not marked done (a crash between the write and its line): done if
    /// the file there is exactly what the step says (its hash), otherwise not ours, so dropped. What can't be checked
    /// safely stays as it is, not done (Undo takes a not-done step back if the file matches it): a window file while the
    /// window is open (`windowOK` false), and a file with a second link (a temp name that wasn't swept).
    private static func reconcile(_ r: Receipt, journal: Journal, windowOK: Bool) {
        for s in r.steps where !s.done && s.kind != .dir {
            if !windowOK, s.kind == .entry || s.kind == .tasks { continue }
            func drop() { journal.add(Event(op: "gone", kind: nil, path: s.path, sha: nil, bytes: nil), sync: false) }
            guard let b = base(of: s.path, r), let rel = relative(s.path, under: b), let tree = Tree(path: b),
                  case .dir(let pfd) = tree.dir(Array(rel.dropLast()), create: false) else { drop(); continue }
            defer { close(pfd) }
            let fd = openat(pfd, rel.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { drop(); continue }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { drop(); continue }
            if st.st_nlink != 1 { continue }                                    // a second link: can't be told safely, stays not done
            if let want = s.sha, sha(fd: fd) == want {
                journal.add(Event(op: "done", kind: nil, path: s.path, sha: want, bytes: nil), sync: true)
            } else { drop() }
        }
    }

    // MARK: running it

    /// Writes what the plan says, under the switch lock. `windowClosed` is asked before the first window file and before
    /// every one after; `stop` is asked between files. A run that stops (the window opened, the operator stopped it, a
    /// write failed) keeps what is back; its receipt is unfinished until it is finished or undone. `continuing` finishes
    /// an earlier run of the same backup under its receipt (also when nothing is left to write: it is then only closed).
    @discardableResult
    static func run(_ t: Target, _ b: Backup, continuing: String? = nil, foreign: Bool = false, addMemory: Bool = false, afterSwitch: String? = nil,
                    mark: String? = nil, windowClosed: () -> Bool, stop: () -> Bool = { false },
                    progress: ((_ done: Int, _ total: Int) -> Void)? = nil,
                    receiptWritten: ((_ id: String) -> Void)? = nil, now: Date = Date()) throws -> Receipt {
        let lock: SwitchEngine.Lock
        do { lock = try SwitchEngine.Lock.take() } catch { throw RestoreError("\(error)") }
        defer { lock.release() }
        if let why = blocker(profile: t.profile, except: continuing) { throw RestoreError(why.words) }
        var old: Receipt?
        if let cid = continuing {
            guard let o = load(cid), o.profile == t.profile, o.backup == b.id, o.undone == nil else {
                throw RestoreError("The stopped restore's receipt isn't there, or isn't for this backup.")
            }
            // what the stop left: temp files of ours (only names with this receipt's prefix: always safe to take away, also
            // while the window is open), then the steps without their line (window files only while the window is closed)
            sweepTemps(o)
            if let j = Journal(id: cid) { reconcile(o, journal: j, windowOK: !o.windowTouched || windowClosed()) }
            old = load(cid)
        }
        let p = plan(t, b, foreign: foreign, addMemory: addMemory, now: now)
        if let why = p.refusal { throw RestoreError(why) }
        guard p.manifest != nil else { throw RestoreError("That backup isn't there any more.") }
        if p.count == 0 {
            // a restore stopped after its last write but before it was marked finished: only closed now
            guard var o = old else { throw RestoreError("Nothing to restore: everything in the backup is here already.") }
            o.finished = now; o.stopped = nil; o.planned = o.back
            o.partialCount = p.partial.count
            if o.unchecked > 0 {
                let words = "\(o.unchecked) window \(o.unchecked == 1 ? "file" : "files") couldn't be checked while the window was open: still in the receipt as not done (probably back); Undo takes each back if it is exactly what was written."
                if !o.problems.contains(words) { o.problems.append(words) }
            }
            try save(o)
            return load(o.id) ?? o
        }
        if p.windowNeeded {
            if let why = markerBlocker(profile: t.profile, dataDir: t.dataDir, own: mark) { throw RestoreError(why) }
            guard windowClosed() else { throw RestoreError("The profile's Claude window is open; nothing written.") }
        }

        var r: Receipt
        let fresh = old == nil
        if var o = old {
            o.finished = nil; o.stopped = nil
            o.planned = o.back + p.count
            r = o
        } else {
            r = Receipt(id: receiptID(now, t.profile), profile: t.profile, dataDir: t.dataDir, codeDir: t.codeDir, backup: b.id,
                        backupPlace: b.place.path, target: t.inUse, started: now, planned: p.count)
            r.sidebar = p.sidebar
            r.afterSwitch = afterSwitch
            r.problems += p.notes
            if case .imported(let file)? = p.manifest?.kind { r.importedFrom = file; r.sessionsAdded = p.transcripts.count; r.entriesAdded = p.entries.count }
        }
        r.changedCount = p.changed.count; r.changed = Array(p.changed.prefix(200)); r.partialCount = p.partial.count
        r.inUseCount = p.inUse.count; r.inUse = Array(p.inUse.prefix(200)); r.deletedCount = p.deletedSince.count
        do { try save(r) } catch { throw RestoreError("The restore's receipt couldn't be saved; nothing written.") }
        receiptWritten?(r.id)               // the caller learns the receipt before the first file is written
        guard let journal = Journal(id: r.id), let reader = Reader(path: b.dir.path) else {
            if fresh { try? FileManager.default.removeItem(at: dir(r.id)) }
            throw RestoreError("The restore's receipt couldn't be written; nothing written.")
        }
        func stopped(_ why: String) -> RestoreError {
            r.stopped = why
            if load(r.id)?.steps.isEmpty ?? true, fresh { try? FileManager.default.removeItem(at: dir(r.id)) } else { try? save(r) }
            return RestoreError(why)
        }
        func gone(_ path: String) { journal.add(Event(op: "gone", kind: nil, path: path, sha: nil, bytes: nil), sync: false) }
        /// Folders the tree made are marked done; each was written down (intent) just before it was made, so a crash between
        /// the two leaves a folder the receipt knows, never an unjournalled one.
        func madeDirs(_ tree: Tree, since n: Int) {
            for d in tree.made[n...] { journal.add(Event(op: "done", kind: nil, path: d, sha: nil, bytes: nil), sync: false) }
        }
        func wire(_ tree: Tree) {
            tree.willMake = { d in journal.add(Event(op: "intent", kind: .dir, path: d, sha: nil, bytes: 0), sync: true) }
            tree.madeFailed = { d in gone(d) }
        }
        let tmpTag = tag(r.id)

        var win: Tree?, code: Tree?
        if p.windowNeeded { win = Tree(path: t.dataDir); if win == nil { throw stopped("The window's data folder isn't there; nothing written.") }; wire(win!) }
        if !p.transcripts.isEmpty || !p.files.isEmpty { code = Tree(path: t.codeDir); if code == nil { throw stopped("The Claude Code folder isn't there; nothing written.") }; wire(code!) }
        var done = r.back
        let total = r.planned
        progress?(done, total)

        // the window's files first (the window must stay closed), then Claude Code's
        for piece in p.entries + p.tasks {
            if stop() { throw stopped("Stopped by you. What is back is kept.") }
            guard windowClosed() else { throw stopped("The profile's Claude window opened during the restore; stopped. What is back is kept.") }
            guard let tree = win, let f = reader.file(piece.rel) else { throw stopped("A file in the backup changed while restoring; stopped. What is back is kept.") }
            defer { close(f.fd) }
            guard var data = read(f.fd, size: f.st.st_size) else { throw stopped("A file in the backup couldn't be read; stopped. What is back is kept.") }
            if piece.rewrite { data = (try? SwitchEngine.placed(data)) ?? data }
            let before = tree.made.count
            let opened = tree.dir(piece.dirs, create: true)
            madeDirs(tree, since: before)
            guard case .dir(let dfd) = opened else { throw stopped("A folder in the window's data is a link or can't be made; stopped. What is back is kept.") }
            defer { close(dfd) }
            let path = (t.dataDir as NSString).appendingPathComponent(piece.dest)
            let hash = SwitchEngine.sha(data)
            journal.add(Event(op: "intent", kind: piece.kind == .tasks ? .tasks : .entry, path: path, sha: hash, bytes: Int64(data.count)), sync: true)
            switch createNew(dfd, piece.leaf, data, tag: tmpTag) {
            case .created: journal.add(Event(op: "done", kind: nil, path: path, sha: nil, bytes: nil), sync: false)
            case .exists: gone(path); r.problems.append("\(piece.leaf) appeared meanwhile; left as it is."); continue
            case .failed(let why): gone(path); throw stopped("\(piece.leaf) couldn't be written (\(why)); stopped. What is back is kept.")
            }
            done += 1; progress?(done, total)
        }
        var written = Set<String>()                                 // the transcripts this run made (a marker needs its own among them)
        for piece in p.transcripts + p.files {
            if stop() { throw stopped("Stopped by you. What is back is kept.") }
            // a retention marker only with its transcript made by this run (the plan saw it planned; it may have appeared since)
            if piece.kind == .file, let id = SessionsExport.markerID(piece.leaf), !written.contains((piece.dirs + [id + ".jsonl"]).joined(separator: "/")) {
                done += 1; progress?(done, total); continue
            }
            guard let tree = code, let f = reader.file(piece.rel) else { throw stopped("A file in the backup changed while restoring; stopped. What is back is kept.") }
            defer { close(f.fd) }
            // the backup file's hash is known before anything is made: the step says what the file must be, so a crash
            // between the clone and its line is still undone (and finished) exactly
            guard let want = sha(fd: f.fd) else { throw stopped("A file in the backup couldn't be read; stopped. What is back is kept.") }
            let before = tree.made.count
            let opened = tree.dir(piece.dirs, create: true)
            madeDirs(tree, since: before)
            guard case .dir(let dfd) = opened else { throw stopped("A folder under projects is a link or can't be made; stopped. What is back is kept.") }
            defer { close(dfd) }
            let path = (t.codeDir as NSString).appendingPathComponent(piece.dest)
            journal.add(Event(op: "intent", kind: piece.kind == .transcript ? .transcript : .file, path: path, sha: want, bytes: Int64(f.st.st_size)), sync: true)
            switch cloneNew(from: f.fd, st: f.st, expected: want, dfd, piece.leaf) {
            case .created(let hash):
                journal.add(Event(op: "done", kind: nil, path: path, sha: hash, bytes: nil), sync: false)
                if piece.kind == .transcript { written.insert((piece.dirs + [piece.leaf.lowercased()]).joined(separator: "/")) }
            case .exists: gone(path); r.problems.append("\(piece.leaf) appeared meanwhile; left as it is."); continue
            case .differs:
                // never taken away by name: a running session may have written to it since it was made
                gone(path); r.problems.append("\(piece.leaf): what landed isn't the backup's file; left as it is."); continue
            case .failed(let why): gone(path); throw stopped("\(piece.leaf) couldn't be written (\(why)); stopped. What is back is kept.")
            }
            done += 1; progress?(done, total)
        }
        r.finished = Date()
        try save(r)
        guard var out = load(r.id) else { return r }
        sweepTemps(out)
        out.problems = r.problems
        return out
    }

    enum Created { case created, exists, failed(String) }
    /// `.differs`: something is there under the name that isn't the backup's file (or isn't plainly ours): left as it is.
    enum Cloned { case created(String), exists, differs, failed(String) }

    /// A new small file, never over a name that exists: a private temp file beside it (named for the restore that makes
    /// it, so a leftover is found and taken away), then linked into place and the temp name removed.
    static func createNew(_ dir: Int32, _ name: String, _ data: Data, tag: String = "x") -> Created {
        let tmp = ".restore-\(tag)-\(UUID().uuidString).tmp"
        let fd = openat(dir, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return .failed(String(cString: strerror(errno))) }
        var ok = data.isEmpty
        if !data.isEmpty { ok = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == data.count } }
        if ok { fsync(fd) }
        close(fd)
        defer { unlinkat(dir, tmp, 0) }
        guard ok else { return .failed("couldn't write it whole") }
        if linkat(dir, tmp, dir, name, 0) == 0 { return .created }
        return errno == EEXIST ? .exists : .failed(String(cString: strerror(errno)))
    }

    /// A transcript (or other file of Claude Code's) brought back as a clone of the backup's file, or a real copy when the
    /// backup is on another volume; the name must be free. What landed is looked at through its own descriptor (a plain
    /// file, one link, the backup's size, the hash the caller expects); only then does it get the backup's modification
    /// time, through that descriptor. If it isn't what it should be, it is NEVER deleted by name: a running Claude Code
    /// session may have appended to it since the clone was made. `.differs` says so.
    static func cloneNew(from src: Int32, st: stat, expected: String?, _ dir: Int32, _ name: String) -> Cloned {
        var landed: Int32
        // CLONE_NOFOLLOW matters: without it a link standing at the name (even one to nowhere) is followed and the clone is
        // made where it points (found by a check with a dangling link); with it the name counts as taken (EEXIST)
        if fclonefileat(src, dir, name, UInt32(CLONE_NOFOLLOW)) == 0 {
            landed = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard landed >= 0 else { return .differs }
        } else {
            let e = errno
            if e == EEXIST { return .exists }
            guard e == ENOTSUP || e == EXDEV || e == EINVAL else { return .failed(String(cString: strerror(e))) }
            landed = openat(dir, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard landed >= 0 else { return errno == EEXIST ? .exists : .failed(String(cString: strerror(errno))) }
            if fcopyfile(src, landed, nil, copyfile_flags_t(COPYFILE_ALL)) != 0 {
                // our own, made a moment ago by this descriptor and nothing else: taken away only if the name is still that file
                var a = stat(), b = stat()
                if fstat(landed, &a) == 0, fstatat(dir, name, &b, AT_SYMLINK_NOFOLLOW) == 0, a.st_ino == b.st_ino, a.st_dev == b.st_dev { unlinkat(dir, name, 0) }
                close(landed)
                return .failed("couldn't copy it")
            }
        }
        defer { close(landed) }
        var now = stat()
        guard fstat(landed, &now) == 0, (now.st_mode & S_IFMT) == S_IFREG, now.st_nlink == 1, now.st_size == st.st_size,
              let hash = sha(fd: landed), expected == nil || hash == expected else { return .differs }
        var times = [st.st_atimespec, st.st_mtimespec]
        futimens(landed, &times)
        return .created(hash)
    }

    // MARK: Undo

    /// Takes back exactly what a run put back: each file it made, if it is still the file it made (same bytes; also a file
    /// it had written down but not yet marked, a crash's leftover), and the folders it made, if empty. Anything changed
    /// since stays and is said. Every folder above a file is opened without following a link and the file is taken away
    /// through its folder's descriptor after its inode was checked again. The window must be closed when window files are
    /// among them, and is asked before each: if it opens, the undo stops with what is taken back kept (Undo again).
    @discardableResult
    static func undo(_ id: String, mark: String? = nil, windowClosed: () -> Bool, now: Date = Date()) throws -> Receipt {
        let lock: SwitchEngine.Lock
        do { lock = try SwitchEngine.Lock.take() } catch { throw RestoreError("\(error)") }
        defer { lock.release() }
        guard var r = load(id) else { throw RestoreError("No receipt for that restore.") }
        guard r.undone == nil else { return r }
        // a default-profile move whose old profile was kept as a standby account or removed: not undone any more
        if let why = DefaultProfile.undoRefusal(receipt: id) { throw RestoreError(why) }
        if let why = blocker(profile: r.profile, except: r.id) { throw RestoreError(why.words) }
        if r.windowTouched {
            if let why = markerBlocker(profile: r.profile, dataDir: r.dataDir, own: mark) { throw RestoreError(why) }
            guard windowClosed() else { throw RestoreError("Quit the profile's Claude window first, then Undo.") }
            sweepTemps(r)
        }
        // which Claude Code sessions run: one `ps`, only when transcripts are among what is taken back. If it can't be read,
        // nothing is taken back (a failed look must not turn the undo into a no-op recorded as done).
        // (only for a transcript step that isn't settled and whose file is still there: a fully taken-back restore needs no look)
        var running = Set<String>()
        let needsLook = r.steps.contains { s in
            guard (s.kind == .transcript || s.kind == .file), !s.settled else { return false }
            var st = stat()
            return lstat(s.path, &st) == 0
        }
        if needsLook {
            guard let live = runningSessions() else {
                throw RestoreError("It couldn't be checked which Claude Code sessions run; nothing was taken back. Try again.")
            }
            running = live
        }
        var left = 0                                   // restored transcripts left in place because a session holds them
        var gone: [String: Int] = [:]                  // a folder the receipt wrote into that can't be opened: how many steps it holds
        let journal = Journal(id: r.id)                // each step an Undo is done with is written down, so a second Undo skips it
        for step in r.steps.reversed() {
            if step.settled { continue }
            let name = (step.path as NSString).lastPathComponent
            var leaveOpen = false                      // a restored transcript a session holds, or a stop: not settled
            defer { if !leaveOpen { journal?.add(Event(op: "settled", kind: nil, path: step.path, sha: nil, bytes: nil), sync: false) } }
            if step.kind == .entry || step.kind == .tasks, !windowClosed() {
                leaveOpen = true
                r.problems.append("The Claude window opened during the undo; stopped. What is taken back stays so: Undo again once it is closed.")
                try? save(r)
                throw RestoreError("The profile's Claude window opened during the undo; stopped. Undo again once it is closed.")
            }
            guard let b = base(of: step.path, r), let rel = relative(step.path, under: b) else {
                r.problems.append("\(name) isn't under the folder this restore wrote into; left as it is."); continue
            }
            // The folder the receipt wrote into is gone (moved, renamed, unplugged): none of its files can be checked, so each
            // is left as it is, and that is said once for the folder, not once per file.
            guard let tree = Tree(path: b) else { gone[b, default: 0] += 1; continue }
            switch tree.dir(Array(rel.dropLast()), create: false) {
            case .absent: continue                                                       // its folder is gone, so it is
            case .blocked: r.problems.append("\(name): a folder above it is a link or can't be opened; left as it is."); continue
            case .dir(let pfd):
                defer { close(pfd) }
                let leaf = rel.last!
                var st = stat()
                guard fstatat(pfd, leaf, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }       // already gone
                if step.kind == .dir {
                    if (st.st_mode & S_IFMT) == S_IFDIR { unlinkat(pfd, leaf, AT_REMOVEDIR) }   // only a folder, and only when empty
                    continue
                }
                guard (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else { r.problems.append("\(name) isn't the file this restore made; left as it is."); continue }
                let fd = openat(pfd, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { r.problems.append("\(name) couldn't be opened; left as it is."); continue }
                var opened = stat()
                let have = sha(fd: fd)
                let sameFile = fstat(fd, &opened) == 0 && opened.st_ino == st.st_ino && opened.st_dev == st.st_dev
                close(fd)
                guard let expected = step.sha, have == expected, sameFile else { r.problems.append("\(name) changed since; left as it is."); continue }
                // the restore's own in-use rule: a restored transcript a running Claude Code session holds but hasn't written to
                // yet still matches its hash; taking it away would pull the file from under that session. Left, and listed.
                if step.kind == .transcript || step.kind == .file {
                    let top = rel.count == 3 && leaf.hasSuffix(".jsonl")
                    let session = top ? String(leaf.dropLast(".jsonl".count)).lowercased() : rel.count >= 4 ? rel[2].lowercased() : ""
                    let age = now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
                    if running.contains(session) || (top && age < recent) {
                        left += 1; leaveOpen = true
                        r.problems.append("\(name): a running Claude Code session holds it (or it was written to a moment ago); left in place.")
                        continue
                    }
                }
                var again = stat()
                guard fstatat(pfd, leaf, &again, AT_SYMLINK_NOFOLLOW) == 0, again.st_ino == st.st_ino, again.st_dev == st.st_dev else {
                    r.problems.append("\(name) changed while it was being taken away; left as it is."); continue
                }
                if unlinkat(pfd, leaf, 0) != 0 { leaveOpen = true; r.problems.append("\(name) couldn't be taken away.") }
            }
        }
        for (folder, n) in gone.sorted(by: { $0.key < $1.key }) {
            r.problems.append(goneWords(folder, files: n))
        }
        // the same line from an earlier try is said once
        var seen = Set<String>()
        r.problems = r.problems.filter { seen.insert($0).inserted }
        r.undoLeft = left
        if left == 0 { r.undone = now }                // otherwise it stays open: Undo again, once the session has ended, takes the rest
        else {
            let words = "\(left) restored \(left == 1 ? "transcript is" : "transcripts are") held by a running Claude Code session: left in place. The receipt stays open; Undo again once it has ended takes the rest."
            if !r.problems.contains(words) { r.problems.append(words) }
        }
        try save(r)
        let out = load(id) ?? r
        sweepTemps(out)
        return out
    }

    /// What Undo says, once per folder, when the folder a restore wrote into isn't there any more: usually the profile's
    /// Claude Code folder was moved or renamed after the restore (the receipt names the path it had then).
    static func goneWords(_ folder: String, files n: Int) -> String {
        "\(tilde(folder)) isn't there any more (moved, renamed or not plugged in), so the \(n) \(n == 1 ? "file" : "files") this restore put in it couldn't be checked and \(n == 1 ? "was" : "were") left as \(n == 1 ? "it is" : "they are"). If the folder was moved, they are in its new place: delete them there by hand, or move the folder back and Undo again."
    }

    /// Every restore's header, newest first (no journals read).
    static func headers() -> [Receipt] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(validReceiptID).compactMap(header).sorted { $0.started > $1.started }
    }

    /// The last import of this profile that is finished and not undone (Undo last import, in Settings ▸ the profile ▸
    /// Sessions, opens its page): newest first. One an Undo only half did (a session held some transcripts) still counts.
    static func lastImport(of profile: String) -> Receipt? {
        headers().first { $0.profile == profile && $0.importedFrom != nil && $0.finished != nil && $0.undone == nil && !carriedOver($0) }
    }

    /// An import made into a window's data folder that a default-profile move has since carried over to the usual app (and
    /// that move isn't undone): its own Undo would change only the old folder, so it isn't offered; Undo this move takes the
    /// sessions out of the usual app (SessionsCard says so).
    static func carriedOver(_ r: Receipt) -> Bool {
        guard !r.dataDir.isEmpty else { return false }
        return DefaultProfile.all().contains {
            $0.profile == r.profile && $0.receipt != nil && $0.undone == nil && !$0.oldDataDir.isEmpty && $0.started > r.started
                && FolderKey.canonical($0.oldDataDir) == FolderKey.canonical(r.dataDir)
        }
    }

    /// How many finished restores of a profile read from this backup and weren't undone: their receipts go with the backup.
    static func finishedRestores(of backup: String, profile: String, place: String) -> Int {
        let here = FolderKey.canonical(place)
        return headers().filter { $0.backup == backup && $0.profile == profile && $0.finished != nil && $0.undone == nil && $0.undoLeft == 0
            && FolderKey.canonical($0.backupPlace) == here }.count
    }

    /// How many restores from this backup an Undo only half did (a session held some of its transcripts): they keep their
    /// receipts, and Undo again can finish them; they don't need the backup.
    static func halfUndoneRestores(of backup: String, profile: String, place: String) -> Int {
        let here = FolderKey.canonical(place)
        return headers().filter { $0.backup == backup && $0.profile == profile && $0.undone == nil && $0.undoLeft > 0
            && FolderKey.canonical($0.backupPlace) == here }.count
    }

    // MARK: old receipts

    /// Finished and undone restores' receipts go when their backup is gone or after 30 days, whichever first. One that
    /// wrote something and neither finished nor was undone is never taken away; nor one started in the last hour (it may
    /// be running).
    static func prune(profile: String? = nil, now: Date = Date()) {
        let fm = FileManager.default
        for n in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter(validReceiptID) {
            guard let h = header(n), profile == nil || h.profile == profile else { continue }
            if h.finished == nil && h.undone == nil {
                if !(load(n)?.steps.isEmpty ?? true) || now.timeIntervalSince(h.started) < 3600 { continue }
            }
            if h.undone == nil, h.undoLeft > 0 { continue }          // half undone: Undo again still has files to take back (it needs no backup)
            let end = h.finished ?? h.undone ?? h.started
            // gone only when the place can be looked at (its folder for this profile is there) and the backup's own isn't: a
            // place on a disk that isn't plugged in says nothing
            let profileDir = SessionsBackup.folder(profile: h.profile, place: URL(fileURLWithPath: h.backupPlace)).path
            var isDir: ObjCBool = false
            let reachable = fm.fileExists(atPath: profileDir, isDirectory: &isDir) && isDir.boolValue
            let backupGone = reachable && !fm.fileExists(atPath: (profileDir as NSString).appendingPathComponent(h.backup))
            if backupGone || now.timeIntervalSince(end) > 30 * 86400 { try? fm.removeItem(at: dir(n)) }
        }
    }

    /// Backups an Undo this switch flow still needs: a switch back (its receipt says `undoes`) names the switch it undoes,
    /// and that switch's backup is what the restore after it reads, until a restore of it has finished (or 30 days pass).
    static func pendingUndoBackups(profile: String, now: Date = Date()) -> [(id: String, place: String)] {
        var out: [(String, String)] = []
        let restores = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(validReceiptID).compactMap(header)
        for back in SwitchEngine.receipts(profile: profile) {
            guard let u = back.undoes, now.timeIntervalSince(back.started) < 30 * 86400,
                  let first = SwitchEngine.load(u), let b = first.backup else { continue }
            if restores.contains(where: { $0.afterSwitch == u && $0.finished != nil }) { continue }
            out.append((b, first.backupPlace ?? BackupPrefs.placeURL.path))
        }
        return out
    }
}

/// A receipt written by an earlier build has fewer keys: every one that has a default is read if present, else defaulted
/// (the synthesized decoding would fail on the first missing one, and an unreadable header drops the receipt).
extension SessionsRestore.Receipt {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), profile: try c.decode(String.self, forKey: .profile),
                  dataDir: try c.decode(String.self, forKey: .dataDir), codeDir: try c.decode(String.self, forKey: .codeDir),
                  backup: try c.decode(String.self, forKey: .backup), backupPlace: try c.decode(String.self, forKey: .backupPlace),
                  target: try c.decodeIfPresent(SeatID.self, forKey: .target), started: try c.decode(Date.self, forKey: .started))
        planned = try c.decodeIfPresent(Int.self, forKey: .planned) ?? 0
        finished = try c.decodeIfPresent(Date.self, forKey: .finished)
        undone = try c.decodeIfPresent(Date.self, forKey: .undone)
        stopped = try c.decodeIfPresent(String.self, forKey: .stopped)
        problems = try c.decodeIfPresent([String].self, forKey: .problems) ?? []
        sidebar = try c.decodeIfPresent(SidebarPlan.self, forKey: .sidebar)
        changed = try c.decodeIfPresent([String].self, forKey: .changed) ?? []
        changedCount = try c.decodeIfPresent(Int.self, forKey: .changedCount) ?? 0
        inUse = try c.decodeIfPresent([String].self, forKey: .inUse) ?? []
        inUseCount = try c.decodeIfPresent(Int.self, forKey: .inUseCount) ?? 0
        deletedCount = try c.decodeIfPresent(Int.self, forKey: .deletedCount) ?? 0
        afterSwitch = try c.decodeIfPresent(String.self, forKey: .afterSwitch)
        partialCount = try c.decodeIfPresent(Int.self, forKey: .partialCount) ?? 0
        undoLeft = try c.decodeIfPresent(Int.self, forKey: .undoLeft) ?? 0
        importedFrom = try c.decodeIfPresent(String.self, forKey: .importedFrom)
        sessionsAdded = try c.decodeIfPresent(Int.self, forKey: .sessionsAdded) ?? 0
        entriesAdded = try c.decodeIfPresent(Int.self, forKey: .entriesAdded) ?? 0
    }
}
