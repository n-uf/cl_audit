// ClaudeFiles: the one reader of the files Claude Code and the Claude app keep about an account and its sessions.
//
// - Claude Code's record: a folder's .claude.json (or a `.claude.json.backup*` of it), its oauthAccount block, field by field as
//   Claude Code wrote them (ids, the address, the organisation's type and name, the plan's name; never a token). It says which
//   account the folder is signed in to as a guess (AccountIdentity, source `guessed`): Claude Code writes it at another moment
//   than the sign-in itself. Read bounded (`recordMax`, SafeFiles.readPlain), never blocking (a FIFO or a device named like the
//   file returns at once), through a link named by the path itself (~/.claude.json may be one to the real file), and parsed
//   again only when the file changed (its size, date and inode).
// - The Claude app's sessions: claude-code-sessions/<account>/<organisation>/local_<id>.json in a window's data folder, by one
//   rule (`sessionScopes`, `sessionEntries`).
//
// Foundation and ProfileCore only, and app-neutral: folders and files in, answers out, no app type, setting or wording (cl_quick
// can compile it). Nothing here logs or prints an address.

import Foundation
import ProfileCore

enum ClaudeFiles {
    /// A name shaped like a UUID (any case), as Claude names accounts, organisations and sessions.
    static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    // MARK: Claude Code's record (.claude.json)

    /// The file where Claude Code records the account a folder is signed in to: the default folder's in the home folder
    /// (~/.claude.json), any other's inside it. `folder`: the folder's path, ~ expanded.
    static func recordPath(folder: String, isDefault: Bool, home: String = NSHomeDirectory()) -> String {
        isDefault ? (home as NSString).appendingPathComponent(".claude.json") : (folder as NSString).appendingPathComponent(".claude.json")
    }

    /// A .claude.json can be large (Claude Code keeps its projects' history in it): larger than this it isn't read at all,
    /// and the account is "not known" (`tooLarge`), never "signed out".
    static let recordMax = 64 << 20

    /// The oauthAccount block as Claude Code wrote it: each field when it is a string (an empty one included).
    struct Record: Equatable {
        var accountUuid: String?
        var organizationUuid: String?
        var emailAddress: String?
        var organizationType: String?
        var organizationName: String?
        var planDisplayName: String?

        init(_ o: [String: Any]) {
            accountUuid = o["accountUuid"] as? String
            organizationUuid = o["organizationUuid"] as? String
            emailAddress = o["emailAddress"] as? String
            organizationType = o["organizationType"] as? String
            organizationName = o["organizationName"] as? String
            planDisplayName = o["planDisplayName"] as? String
        }

        /// The account the record names (it has an account id): ids and the address, as written.
        var seat: Seat? {
            guard let a = accountUuid, !a.isEmpty else { return nil }
            return Seat(account: a, organization: organizationUuid, email: emailAddress)
        }

        /// The same as an identity, guessed from the file (the process's own word, when there is one, is verified).
        var identity: AccountIdentity? {
            let a = accountUuid.flatMap { $0.isEmpty ? nil : $0 }, e = emailAddress.flatMap { $0.isEmpty ? nil : $0 }
            guard a != nil || e != nil else { return nil }
            return AccountIdentity(account: a, email: e, organization: organizationUuid, source: .guessed)
        }

        /// Claude's own name for the plan ("Ultra"), when it isn't blank.
        var plan: String? { planDisplayName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
    }

    /// The record in one file, or nil (no file, not a regular file, too large, not JSON, no oauthAccount block).
    static func record(at path: String) -> Record? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let key = Stamp(size: Int64(st.st_size), sec: Int(st.st_mtimespec.tv_sec), nsec: Int(st.st_mtimespec.tv_nsec), inode: UInt64(st.st_ino))
        lock.lock()
        if let c = memo[path], c.stamp == key { lock.unlock(); return c.record }
        lock.unlock()
        let block = SafeFiles.readPlain(path, max: recordMax, followsLink: true)
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["oauthAccount"] as? [String: Any]
        let r = block.map(Record.init)
        lock.lock(); memo[path] = (key, r); if memo.count > 256 { memo.removeAll() }; lock.unlock()
        return r
    }

    /// A folder's record: `record(at: recordPath(...))`.
    static func record(folder: String, isDefault: Bool, home: String = NSHomeDirectory()) -> Record? {
        record(at: recordPath(folder: folder, isDefault: isDefault, home: home))
    }

    /// The account a folder's record names, guessed from the file (cl_quick's "guessed from file"); nil when it names none.
    static func identity(folder: String, isDefault: Bool, home: String = NSHomeDirectory()) -> AccountIdentity? {
        record(folder: folder, isDefault: isDefault, home: home)?.identity
    }

    /// The file is a regular file larger than `recordMax` (by its size alone; nothing is read).
    static func tooLarge(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && Int(st.st_size) > recordMax
    }

    private struct Stamp: Equatable { var size: Int64; var sec: Int; var nsec: Int; var inode: UInt64 }
    nonisolated(unsafe) private static var memo: [String: (stamp: Stamp, record: Record?)] = [:]
    private static let lock = NSLock()

    // MARK: the Claude app's sessions (claude-code-sessions/<account>/<organisation>/local_<id>.json)

    /// One account/organisation folder: its names as they are on disk (compare them lower-cased), its path and when it last
    /// changed.
    struct SessionScope: Equatable {
        var account: String
        var organization: String
        var path: String
        var modified: Date
    }

    /// One session entry: its file name as it is on disk and when it last changed.
    struct SessionEntry: Equatable {
        var name: String
        var modified: Date
    }

    /// The account/organisation folders under `<dataDir>/<kind>` (claude-code-sessions, or local-agent-mode-sessions), sorted by
    /// account, then organisation. The one rule: both named like a UUID (any case, kept as on disk), each a real folder (a link
    /// is never followed: it isn't listed). `account`: only that account's folder. `limit`: at most that many names looked at in
    /// each folder (a folder of very many can't keep a caller busy).
    static func sessionScopes(dataDir: String, kind: String = "claude-code-sessions", account: String? = nil, limit: Int? = nil) -> [SessionScope] {
        let root = (dataDir as NSString).appendingPathComponent(kind)
        let accounts = account.map { [$0] } ?? names(root, limit: limit)
        var out: [SessionScope] = []
        for a in accounts where isUUID(a) {
            let adir = (root as NSString).appendingPathComponent(a)
            guard folderTime(adir) != nil else { continue }
            for o in names(adir, limit: limit) where isUUID(o) {
                let odir = (adir as NSString).appendingPathComponent(o)
                guard let t = folderTime(odir) else { continue }
                out.append(SessionScope(account: a, organization: o, path: odir, modified: t))
            }
        }
        return out
    }

    /// A session entry's name: local_<UUID>.json (any case).
    static func isEntryName(_ n: String) -> Bool {
        n.hasPrefix("local_") && n.hasSuffix(".json") && isUUID(String(n.dropFirst("local_".count).dropLast(".json".count)))
    }

    /// The session entries in one account/organisation folder, sorted by name: `isEntryName`, each a regular file (a link isn't
    /// one). Only names and times are read; no entry is opened.
    static func sessionEntries(in dir: String, limit: Int? = nil) -> [SessionEntry] {
        names(dir, limit: limit).compactMap { n in
            guard isEntryName(n) else { return nil }
            var st = stat()
            guard lstat((dir as NSString).appendingPathComponent(n), &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
            return SessionEntry(name: n, modified: date(st.st_mtimespec))
        }
    }

    /// A folder's names, sorted (at most `limit` looked at, in the order the disk gives them).
    private static func names(_ dir: String, limit: Int?) -> [String] {
        guard let limit else { return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() }
        guard let d = opendir(dir) else { return [] }
        defer { closedir(d) }
        var out: [String] = []
        var seen = 0
        while seen < limit, let e = readdir(d) {
            seen += 1
            let n = withUnsafePointer(to: e.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
            if n != "." && n != ".." { out.append(n) }
        }
        return out.sorted()
    }

    /// When a real folder (not a link) last changed; nil when it isn't one.
    private static func folderTime(_ p: String) -> Date? {
        var st = stat()
        guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return date(st.st_mtimespec)
    }

    private static func date(_ t: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9)
    }
}
