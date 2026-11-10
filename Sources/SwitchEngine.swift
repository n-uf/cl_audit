// SwitchEngine: what is left of the switch that moved a profile's Claude window sessions between its accounts (26.11.12
// and earlier). A switch now signs Claude Code in again on the profile's own folder and moves nothing (SwitchRunner.swift);
// what stays here is shared by the writers that still touch the window's files (Restore, Import, the default-profile
// move, re-pointing a moved session, a move's side files):
//
// - the window's folder of sessions for one account and organisation, and how a session entry is placed in another
//   account's folder (its old account's error keys and Remote Control ids off);
// - a write that can't overwrite (a private temp file, then a hard link) and SHA-256;
// - one writer at a time (cl_audit's lock, switches/.lock), and none while claude-transplant runs: its own lock (a flock) is
//   held for the whole run;
// - the window marks (SwitchMarker): while a restore, an import's re-point or the default-profile move holds a Claude window
//   closed, no window opener starts it;
// - the old switches' receipts (switches/<id>/receipt.json), read only: an old backup says which switch it was made before,
//   a switch that stopped half way keeps its backup from pruning, and the Sessions card says so. cl_audit no longer writes,
//   undoes or deletes them. Receipts name accounts by their ids only, never by address.

import CryptoKit
import Foundation

/// An account and organisation by their ids only: what a receipt keeps.
struct SeatID: Codable, Equatable, Hashable {
    var account: String
    var organization: String

    init(_ s: Seat) { account = s.account; organization = s.organization ?? "" }
    init(account: String, organization: String) { self.account = account; self.organization = organization }

    func same(_ s: Seat?) -> Bool { s.map { $0.account == account && ($0.organization ?? "") == organization } ?? false }
}

/// The record of one old switch, in cl_audit's folder (switches/<id>/receipt.json): read only.
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
    /// The receipt of the switch this one switched back ("Undo this switch", 26.11.12 and earlier).
    var undoes: String?

    /// Something was moved, and the switch was neither linked nor undone: it stopped half way.
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
    case busy(String), failed(String)
    var description: String {
        switch self {
        case .busy(let s), .failed(let s): return s
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
        let f = (scopeDir as NSString).appendingPathComponent("scheduled-tasks.json")
        guard let d = FileManager.default.contents(atPath: f), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return j["scheduledTasks"] as? [[String: Any]] ?? []
    }

    // MARK: the old switches' receipts (read only)

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
/// names the run: "restore-…", "repoint-…", "default-…"; a switch of 26.11.12 and earlier put a standby account's id there.)
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
