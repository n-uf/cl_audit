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
// session): the scope folders, `placed`, `writeNew` and the window marks; the lock is Flows.takeLock, the receipts' store
// and the create-only writes are SafeFiles'.
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
import ProfileCore

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
    var taskStay: String? = nil         // why the scheduled tasks stay (taskProblem): then `tasks` is 0 and neither file is touched
    var taskStayTwin = false            // …because of a differing twin: removing one of the two settles it
    var taskHeld: [String] = []         // the sessions of those tasks, held too (a subset of `held`)
    var unreadable: [String] = []       // held because they can't be read whole, not because Claude Code runs them (a subset of `held`)
    var odd: [SessionTransfer.Odd] = [] // names shaped like an entry that aren't one (a link, an unknown name): left in place, said
    var backupTranscripts = true        // the backup (SessionsBackup.swift) takes Claude Code's transcripts too
    /// Claude Code's folder is on the target already (a switch made elsewhere): `from` is the Claude app's account, the
    /// sessions move from it, and no sign-in is opened (the Claude app's own is what's left).
    var finishLine = false
    var entry: AccountEntry? = nil      // cl_audit's record of the profile, for the backup

    var sourceDir: String { SwitchEngine.scopeDir(dataDir, SeatID(from)) }
    var targetDir: String { SwitchEngine.scopeDir(dataDir, SeatID(to)) }
    /// The two accounts' folders the sessions move between (SessionTransfer).
    var scopes: SessionTransfer.Scopes { SessionTransfer.Scopes(dataDir: dataDir, codeDir: codeDir, from: SeatID(from), to: SeatID(to)) }
    /// Anything to move at all (otherwise the switch only signs in again).
    var moves: Bool { !move.isEmpty || tasks > 0 }
}

// (SeatID, an account and organisation by their ids only, is ProfileCore's: Core/Identity.swift)

/// The record of one switch, in cl_audit's folder (switches/<id>/receipt.json), saved before and after every step.
struct SwitchReceipt: StoredReceipt, Equatable {
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
    /// Undo ran but left these as they were (outside the switch's places, changed since, or couldn't be taken away): only
    /// partly undone, and still open for another Undo.
    var left: [String]?
    var partlyUndone: Date?
    /// How many scheduled tasks the tasks' step moved (written down with the step; nil for older receipts).
    var tasksMoved: Int?
    /// How many names shaped like an entry, but not one, were left in place (SessionTransfer.odd; nil: none, or older).
    var leftInPlace: Int?
    /// The switch closed the profile's Claude window for its move (nil: it was closed already, or an older receipt). It stays
    /// closed while the moved sessions aren't linked, and opens again once the switch is settled (SwitchEngine.settled).
    var closedWindow: Bool?
    /// A finish line (SwitchPlan.finishLine): the folder was on `to` before the move, so the folder being on it says nothing
    /// about the move; linkReached never links one that hasn't finished (a stop keeps Undo), the run's own end links it.
    var finishLine: Bool?

    /// What this switch still has moved now: its placed session entries still where it put them, unchanged, and its
    /// scheduled tasks while the new account's task file is still as it wrote it. (Undo takes them back; after a partial
    /// Undo, only what's left counts.)
    func stillMoved() -> (sessions: Int, tasks: Int) {
        let fm = FileManager.default
        let sessions = steps.filter { $0.kind == .entry && $0.done && fm.fileExists(atPath: $0.path) }.count
        // each task file still as this switch wrote it: the tasks are out of the old account (and, once the second is
        // written, in the new one); a stop between the two leaves them in neither, which Undo puts back too
        let asWritten = steps.contains { $0.kind == .tasks && $0.done && SafeRead.whole($0.path).map(SwitchEngine.sha) == $0.sha }
        return (sessions, asWritten ? (tasksMoved ?? 1) : 0)
    }

    /// Something was moved, and the switch was neither linked nor undone: Undo still applies.
    var unfinished: Bool { undone == nil && linked == nil && leftAsIs == nil && !steps.isEmpty }
    /// Linked within the last day (nil: not linked): how long a switch's finish line lasts (AccountSettings.switchTarget,
    /// the resolver's split). A link dated ahead of `now` (the clock was set back) counts only within five minutes of it,
    /// so it never keeps the finish line until the clock catches up.
    func linkedLately(now: Date) -> Bool? { linked.map { (-300 ... 24 * 3600).contains(now.timeIntervalSince($0)) } }
    /// "Leave it as it is": the person closed it as it stands (Undo no longer applies; nothing is moved).
    var leftAsIs: Date?
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
        var refused: Bool? = nil        // tasks: the write was refused (the file had changed) or put back: nothing to undo
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

    /// A new file, never over an existing one: written to a private temp file beside it, then linked into place (CreateOnly).
    static func writeNew(_ path: String, _ data: Data) throws {
        let dir = (path as NSString).deletingLastPathComponent, leaf = (path as NSString).lastPathComponent
        let tmp = (dir as NSString).appendingPathComponent(".\(leaf).\(UUID().uuidString).tmp")
        switch CreateOnly.write(data, as: path, temp: tmp, sync: false) {
        case .created: return
        case .exists: throw SwitchError.failed("\(leaf) is already there")
        case .notMade, .notWhole: throw SwitchError.failed("couldn't write in \(tilde(dir))")
        case .failed: throw SwitchError.failed("couldn't place \(leaf)")
        }
    }

    // MARK: scheduled tasks

    // (the task file's one owner is TaskRegistry: reading, the twin rule, the joined files and the compare-and-swap writes)

    static func tasks(in scopeDir: String) -> [[String: Any]] { TaskRegistry.tasks(in: scopeDir) }

    /// Why the source's tasks can't move as they are, or nil (TaskRegistry.twinProblem: a differing twin is refused).
    static func taskProblem(source: String, target: String) -> String? { TaskRegistry.twinProblem(source: source, target: target) }

    // MARK: the plan (read-only)

    /// What a switch to `s` would move, read without changing anything. `owned`: the session ids a running Claude Code
    /// owns (nil: read them now).
    static func plan(_ e: AccountEntry, standby s: StandbyAccount, dataDir: String? = nil, owned: Set<String>? = nil) -> Result<SwitchPlan, SwitchError> {
        guard var from = e.seat, from.organization != nil else { return .failure(.notReady("The account in use isn't known yet.")) }
        guard let to = s.seat, to.organization != nil else {
            return .failure(.notReady("\(s.email) hasn't been signed in on this Mac yet, so its sessions' folder isn't known: nothing to move."))
        }
        // the finish line: Claude Code's folder is on the target already (a switch made elsewhere) while the Claude app is on
        // another account: the sessions move from the Claude app's account
        var finishLine = false
        if from.same(to), let app = e.appSeat(AccountView.of(Store.status(for: e))), !app.same(to) { from = app; finishLine = true }
        // the ids name folders: only real ids (never a path)
        guard [from.account, from.organization!, to.account, to.organization!].allSatisfy(ClaudeFiles.isUUID) else {
            return .failure(.notReady("An account id isn't one Claude would use; nothing is moved."))
        }
        guard !from.same(to) else { return .failure(.notReady("That's the account in use.")) }
        let dir = dataDir ?? (e.desktop == .standard ? expand(FolderKey.standardDataDir) : Account(e).claudeUserDataDir ?? "")
        guard !dir.isEmpty else { return .failure(.notReady("The profile's Claude window has no folder.")) }
        var p = SwitchPlan(profile: e.id, standby: s.id, dataDir: expand(dir), codeDir: Account(e).configDir, from: from, to: to, entry: e)
        p.finishLine = finishLine
        // nothing is written through a link inside the folders: refused, and said why
        if let why = linkProblem(p) { return .failure(.notReady(why)) }
        p.odd = SessionTransfer.odd(p.scopes)
        // the sessions and tasks, sorted by SessionTransfer (its entries are ClaudeFiles' one lister's)
        guard SessionTransfer.hasAnything(p.scopes) else { return .success(p) }
        guard let live = owned ?? Processes.sessionsOwned(codeDir: p.codeDir) else {
            return .failure(.notReady("cl_audit couldn't see which sessions Claude Code is running now; nothing is moved."))
        }
        let sorted = SessionTransfer.sort(p.scopes, owned: live)
        p.move = sorted.move; p.already = sorted.already; p.deleted = sorted.deleted; p.held = sorted.held
        p.taskHeld = sorted.taskHeld; p.tasks = sorted.tasks; p.taskStay = sorted.taskStay; p.taskStayTwin = sorted.taskStayTwin; p.unreadable = sorted.unreadable
        return .success(p)
    }

    /// Why a switch would write through a link, or nil (SessionTransfer.linkProblem).
    static func linkProblem(_ p: SwitchPlan) -> String? { SessionTransfer.linkProblem(p.scopes) }

    // MARK: running it

    /// Moves what the plan says. `windowClosed` is asked first and before every step: the window must stay closed. If
    /// it stops (the window opened, a write failed), the receipt stays as it is, unfinished, for Undo.
    ///
    /// A backup of the sessions is made first, right here under the lock: the window is known closed and nothing has
    /// moved. The receipt names it (saved before the first move) and it names the receipt. If it can't be made, the switch
    /// stops with nothing moved. `backups`: where it goes (General ▸ Backups unless given). `closedWindow`: the switch closed the
    /// profile's Claude window for it (written down: the window opens again once the switch is settled, `settled`).
    @discardableResult
    static func run(_ p: SwitchPlan, windowClosed: () -> Bool, now: Date = Date(), backups: URL? = nil, closedWindow: Bool = false,
                    backupMade: ((_ id: String, _ place: String) -> Void)? = nil) throws -> SwitchReceipt {
        let lock = try Flows.takeLock()
        defer { lock.release() }
        guard windowClosed() else { throw SwitchError.notReady("The profile's Claude window is open; nothing moved.") }
        // looked at again under the lock, like a restore does: one that stopped half way since the page asked still holds it back
        if let why = Flows.blocker(profile: p.profile, for: .switching) { throw SwitchError.notReady(why) }
        // a link put in since the plan is refused all the same
        if let why = linkProblem(p) { throw SwitchError.notReady(why) }
        var r = SwitchReceipt(id: receiptID(now, p.profile), profile: p.profile, standby: p.standby, dataDir: p.dataDir,
                              from: SeatID(p.from), to: SeatID(p.to), started: now)
        r.held = p.held.isEmpty ? nil : p.held
        r.leftInPlace = p.odd.isEmpty ? nil : p.odd.count
        r.closedWindow = closedWindow ? true : nil
        r.finishLine = p.finishLine ? true : nil
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
            try store.save(r)
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
            try? store.save(r)
            throw error
        }
        r.finished = Date()
        try store.save(r)
        return r
    }

    /// The sessions, their tasks and pointers moved by SessionTransfer, written down in this switch's receipt.
    private static func moveAll(_ p: SwitchPlan, _ r: inout SwitchReceipt, dir: URL, windowClosed: () -> Bool) throws {
        guard p.moves else { return }
        try SessionTransfer.move(p.scopes, entries: p.move, tasks: p.tasks, record: &r, work: dir, windowClosed: windowClosed,
                                 save: { try store.save($0) })
    }

    /// Why a transcript may be being written, or nil (SessionTransfer.busy).
    static func busy(_ transcript: String, cli: String, now: Date = Date(), table: [Processes.Entry]?? = nil) -> String? {
        SessionTransfer.busy(transcript, cli: cli, now: now, table: table)
    }

    /// The last Remote Control pointer line in a transcript, or nil (SessionTransfer.lastPointer).
    static func lastPointer(_ path: String) -> [String: Any]? { SessionTransfer.lastPointer(path) }

    // MARK: Undo

    /// Puts back what a switch did, from its receipt, also when it stopped half way: placed entries that are unchanged
    /// go and their originals come back (an original whose copy can't be taken away stays parked, so the session is
    /// never in both accounts); task files come back from their backups if unchanged since; a pointer line comes off if
    /// it's still the transcript's last bytes. Then anything in parked/ the steps don't name goes back too. The window
    /// must be closed. A linked switch isn't undone: the way back is a switch the other way.
    @discardableResult
    static func undo(_ id: String, windowClosed: () -> Bool) throws -> SwitchReceipt {
        let lock = try Flows.takeLock()
        defer { lock.release() }
        guard windowClosed() else { throw SwitchError.notReady("Quit the profile's Claude window first, then Undo.") }
        guard var r = store.load(id) else { throw SwitchError.failed("No receipt for that switch.") }
        guard r.undone == nil else { return r }
        guard r.linked == nil else { throw SwitchError.notReady("That switch finished; the way back is a switch the other way.") }
        // receipt.json is a file on disk: every path it names must be one of this switch's own places, or it's left alone
        let places = undoPlaces(r)
        // what is left as it was (outside the switch's places, changed since, or couldn't be taken away): then the
        // receipt is only partly undone and stays open, so Undo can be tried again
        var left: [String] = []
        for step in r.steps.reversed() {
            let name = (step.path as NSString).lastPathComponent
            // the window must stay closed for every step, as for the switch itself
            guard windowClosed() else {
                r.problems.append("The profile's Claude window opened during Undo; stopped. Undo again once it's closed.")
                try? store.save(r)
                throw SwitchError.windowOpen
            }
            if let why = places.outside(step) { r.problems.append("\(name): \(why); left as it is"); left.append(name); continue }
            // each step put back by SessionTransfer (its name when it is left as it was)
            if let stays = try SessionTransfer.undo(step, record: &r) { left.append(stays) }
        }
        // anything parked that the steps don't name (a stop between parking and saving): back where it came from
        if places.scopesOK {
            try SessionTransfer.returnParked(parkedDir: root.appendingPathComponent("\(r.id)/parked").path, source: scopeDir(r.dataDir, r.from),
                                             record: &r, windowClosed: windowClosed, save: { try store.save($0) })
        }
        if left.isEmpty {
            r.undone = Date(); r.left = nil; r.partlyUndone = nil
        } else {
            r.left = left; r.partlyUndone = Date()           // not undone: it stays open (unfinished) for another Undo
        }
        try store.save(r)
        return r
    }

    /// Called once a switch is settled (linked, undone, or left as it is), with its receipt: the app and the agent open the
    /// profile's Claude window again here when the switch closed it (ClaudeWindow.afterSwitch). Nothing by default (the checks).
    nonisolated(unsafe) static var settled: (SwitchReceipt) -> Void = { _ in }

    /// The first process to open a settled switch's window again (the app or the agent, both told): true once per switch, by
    /// a file made create-only in the switch's own folder (taken away with it).
    static func claimReopen(_ id: String) -> Bool {
        guard !id.isEmpty, !id.contains("/"), id != "..", id != "." else { return false }
        let path = root.appendingPathComponent(id).appendingPathComponent("reopened").path
        let fd = Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// The unsettled switch that closed this window, if any: it moved sessions that aren't linked yet, so the Claude app must
    /// not run on them; the window stays closed until the switch is settled (Launcher.openClaude asks this).
    static func keepsClosed(_ account: Account) -> SwitchReceipt? {
        let key = Launcher.dataDirKey(of: account)
        return receipts().first { $0.unfinished && $0.closedWindow == true && FolderKey.canonical($0.dataDir) == key }
    }

    /// The places a switch's Undo may touch, from what cl_audit knows rather than from receipt.json alone: the two
    /// accounts' scope folders in the profile's own window data folder (real ids, plain folders), this receipt's own folder
    /// (parked/ and the task files' backups) and the profile's Claude Code `projects` (pointer lines).
    struct UndoPlaces {
        var from: String?, to: String?            // the scope folders, nil when they can't be trusted
        var own: String                           // switches/<id>
        var projects: String?
        var scopesOK: Bool { from != nil && to != nil }

        private static func child(_ path: String?, of dir: String?, depth: Int = 1) -> Bool {
            guard let path, let dir else { return false }
            let p = (path as NSString).standardizingPath, d = (dir as NSString).standardizingPath
            guard p == path, p.hasPrefix(d + "/") else { return false }       // no "..", no "./", inside
            let rest = p.dropFirst(d.count + 1).split(separator: "/", omittingEmptySubsequences: false)
            guard rest.count == depth, !rest.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else { return false }
            // nothing on the way is a link
            var walk = d
            for part in rest.dropLast() {
                walk = (walk as NSString).appendingPathComponent(String(part))
                var st = stat()
                if lstat(walk, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR { return false }
            }
            return true
        }

        /// Why a step's paths aren't this switch's own, or nil.
        func outside(_ s: SwitchReceipt.Step) -> String? {
            let why = "the receipt names a place outside this switch's folders"
            switch s.kind {
            case .entry:
                guard Self.child(s.path, of: to), s.original == nil || Self.child(s.original, of: from),
                      s.parked == nil || Self.child(s.parked, of: (own as NSString).appendingPathComponent("parked")) else { return why }
            case .tasks:
                let file = (s.path as NSString).lastPathComponent
                guard file == "scheduled-tasks.json", Self.child(s.path, of: to) || Self.child(s.path, of: from),
                      s.parked == nil || Self.child(s.parked, of: own) else { return why }
            case .pointer:
                guard s.path.hasSuffix(".jsonl"), Self.child(s.path, of: projects, depth: 2) else { return why }
            }
            return nil
        }
    }

    static func undoPlaces(_ r: SwitchReceipt) -> UndoPlaces {
        let own = root.appendingPathComponent(r.id).path
        let e = (Store.loadChecked() ?? Store.load()).first { $0.id == r.profile }
        let projects = e.map { (expand($0.configDir) as NSString).appendingPathComponent("projects") }
        // the receipt's data folder must be one the profile's window uses (its own, or the usual app's)
        let dirs = [expand(FolderKey.standardDataDir), e.flatMap { Account($0).claudeUserDataDir }.map(expand)].compactMap { $0 }
            .map { ($0 as NSString).standardizingPath }
        let ids = [r.from.account, r.from.organization, r.to.account, r.to.organization].allSatisfy(ClaudeFiles.isUUID)
        guard ids, dirs.contains((expand(r.dataDir) as NSString).standardizingPath) else {
            return UndoPlaces(from: nil, to: nil, own: own, projects: projects)
        }
        var places = UndoPlaces(from: scopeDir(r.dataDir, r.from), to: scopeDir(r.dataDir, r.to), own: own, projects: projects)
        // a scope folder (or a part above it) that is a link: none of it is touched
        let sessions = (expand(r.dataDir) as NSString).appendingPathComponent("claude-code-sessions")
        for s in [r.from, r.to] {
            let a = (sessions as NSString).appendingPathComponent(s.account)
            for p in [sessions, a, (a as NSString).appendingPathComponent(s.organization)] {
                var st = stat()
                if lstat(p, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR { places.from = nil; places.to = nil }
            }
        }
        return places
    }

    /// Undo with the profile's window held closed meanwhile (SwitchMarker), as a switch holds it: no opener starts the
    /// window during Undo, and another run on it is refused.
    @discardableResult
    static func undoHolding(_ id: String, account: Account, windowClosed: () -> Bool) throws -> SwitchReceipt {
        let window = Launcher.dataDirKey(of: account), profile = store.load(id)?.profile ?? "", name = "undo-\(id)"
        guard SwitchMarker.claim(window, profile: profile, standby: name) else {
            throw SwitchError.busy("Another run on the profile's Claude window is under way (a restore, an import or a switch).")
        }
        let r: SwitchReceipt
        do { r = try undo(id, windowClosed: windowClosed) } catch { SwitchMarker.release(window, profile: profile, standby: name); throw error }
        SwitchMarker.release(window, profile: profile, standby: name)
        if r.undone != nil { settled(r) }                       // (after its mark is gone: the window it closed may open)
        return r
    }

    // MARK: receipts

    /// "20261105-153012-a3f9-main": when, a short random part (two runs in one second never share a folder), whose. Restore
    /// receipts are named the same way.
    static func receiptID(_ d: Date, _ profile: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: d))-\(UUID().uuidString.prefix(4).lowercased())-\(profile)"
    }

    /// The switches' receipts: switches/<id>/receipt.json (the folder also holds the window marks and the lock).
    static var store: ReceiptStore<SwitchReceipt> { ReceiptStore(root: root, layout: .folders(file: "receipt.json")) }

    /// A profile's switches, newest first.
    static func receipts(profile: String) -> [SwitchReceipt] {
        cachedList { $0.hasSuffix("-\(profile)") }.filter { $0.profile == profile }
    }

    /// Every profile's switches, newest first.
    static func receipts() -> [SwitchReceipt] {
        cachedList { !$0.hasPrefix(".") && !$0.hasSuffix(".json") }
    }

    /// A receipt file as last read: its inode, size and modification time (a save replaces the file whole, so any change
    /// shows here), and what it decoded to.
    private struct Cached { let ino: UInt64; let size: Int64; let mtime: timespec; let receipt: ReceiptStore<SwitchReceipt>.Ordered? }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Cached] = [:]
    #if CL_AUDIT_TESTING
    /// A check's seam: the receipt ids the cache holds now. Only a test build (compiled with -D CL_AUDIT_TESTING) has it.
    static var cachedIDs: Set<String> { cacheLock.lock(); defer { cacheLock.unlock() }; return Set(cache.keys) }
    #endif

    /// The store's receipts `include` takes, newest first, each decoded again only when its file changed: the agent's and
    /// the pages' ticks ask every few seconds, and most of the time nothing has. An id `include` takes that is no longer
    /// there leaves the cache, on a profile's read as on the whole list's.
    private static func cachedList(_ include: @escaping (String) -> Bool) -> [SwitchReceipt] {
        let s = store
        let ids = s.ids(include)
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache = cache.filter { ids.contains($0.key) || !include($0.key) }
        var out: [ReceiptStore<SwitchReceipt>.Ordered] = []
        for id in ids {
            var st = stat()
            guard lstat(s.url(id).path, &st) == 0 else { cache[id] = nil; continue }
            if let c = cache[id], c.ino == st.st_ino, c.size == st.st_size,
               c.mtime.tv_sec == st.st_mtimespec.tv_sec, c.mtime.tv_nsec == st.st_mtimespec.tv_nsec {
                if let r = c.receipt { out.append(r) }
                continue
            }
            let r = s.loadOrdered(id)
            cache[id] = Cached(ino: st.st_ino, size: st.st_size, mtime: st.st_mtimespec, receipt: r)
            if let r { out.append(r) }
        }
        // (the store's own order: two switches started in one second in the order they were made)
        return out.sorted(by: ReceiptStore<SwitchReceipt>.newestFirst).map(\.receipt)
    }

    /// A profile's switches that moved something and were neither linked nor undone, newest first.
    static func unfinished(profile: String) -> [SwitchReceipt] { receipts(profile: profile).filter(\.unfinished) }

    /// Claude Code signed in as the new account: the profile works on it, and the way back is a switch.
    /// Every unfinished switch whose profile reached the account it went for, by the profile's record or by what its
    /// folder's .claude.json names, is linked, also when the Switch page didn't see it (cl_audit quit during the sign-in,
    /// or the person signed in by hand): its sessions are where they belong, Undo no longer applies, and it no longer
    /// holds up the next switch. Called with the profiles' noting (FolderRules.noteAccounts). The ids linked.
    @discardableResult
    static func linkReached(_ accounts: [AccountEntry], signedIn: (String) -> Seat? = Account.signedInSeat, now: Date = Date()) -> [String] {
        let open = receipts().filter(\.unfinished)
        guard !open.isEmpty else { return [] }
        func reached(_ want: SeatID, _ s: Seat?) -> Bool { want.sameIgnoringCase(s) }      // (case doesn't count here, as before)
        var linked: [String] = []
        for r in open {
            // a finish line's folder was on `to` from the start: linked only once its move finished (a stop keeps Undo)
            if r.finishLine == true, r.finished == nil { continue }
            guard let e = accounts.first(where: { $0.id == r.profile }),
                  reached(r.to, e.seat) || reached(r.to, signedIn(e.configDir)) else { continue }
            markLinked(r.id, now: now)
            linked.append(r.id)
        }
        return linked
    }

    /// "Leave it as it is" on a switch that stopped half way (or was only partly undone): nothing moves; the receipt is
    /// closed, so it no longer holds up the next switch. What stays where, in words. The backup made before it is kept.
    @discardableResult
    static func leaveAsIs(_ id: String, now: Date = Date()) throws -> String {
        let lock = try Flows.takeLock()
        defer { lock.release() }
        guard var r = store.load(id), r.unfinished else { return "" }
        r.leftAsIs = now
        try store.save(r)
        settled(r)
        // after a partial Undo only what it left where the switch put it counts (the rest is back already); the backup is
        // not named: it may age out (the backups' keep rules), so nothing is promised about it
        let moved = r.partlyUndone != nil ? (r.left ?? []).filter(ClaudeFiles.isEntryName).count
                                          : r.steps.filter { $0.kind == .entry && $0.done }.count
        // (none left there: no "0 Code-tab sessions")
        if moved == 0 { return "Left as it is: no Code-tab session stays under the account the switch went to; they're under the one it came from." }
        return "Left as it is: \(moved) Code-tab \(moved == 1 ? "session stays" : "sessions stay") under the account the switch went to, the rest under the one it came from."
    }

    static func markLinked(_ id: String, now: Date = Date()) {
        guard var r = store.load(id), r.linked == nil, r.undone == nil, r.leftAsIs == nil else { return }
        r.linked = now
        guard (try? store.save(r)) != nil else { return }
        settled(r)
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    // (one writer at a time: cl_audit's lock and claude-transplant's, Flows.takeLock)
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

    private static func read(_ file: URL) -> Mark? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: file)).flatMap { try? dec.decode(Mark.self, from: $0) }
    }

    /// Whether the cl_audit that wrote a mark still runs.
    static func live(_ m: Mark) -> Bool { Processes.executable(of: m.pid) == m.exe }

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
        guard let exe = Processes.executable(of: getpid()) else { return false }
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
