// ClaudeAuth · finding accounts on this Mac: each source a plain function, files in, accounts out, all in one shape
// (FoundAccount: one sighting of an account, its named fields only, never a token). Each app picks its sources and does its
// own listing with what comes back (which profile an account goes to, what is forgotten, the words).
//
// The sources:
// - a Claude Code folder's own record (.claude.json) and the backups Claude Code keeps of it (`folderRecordFiles`);
// - the Claude Code folders in a home folder (`claudeFolders`: ~/.claude and ~/.claude-*);
// - every record in a home folder and claude-transplant's switch folder (`homeRecordFiles`: ~/.claude*,
//   ~/.claude-switch/accounts/*/.claude.json), read for the profile on the default folder;
// - and, in Auth/DiscoveryApp.swift (an incognito app's build leaves that file out, with Keychain.swift), the desktop app's
//   session folders and the account ids transcripts name: they open session records and read chats.
//
// Every path is the caller's (the home folder, the folders, the desktop app's data folder): nothing here names a place of
// its own but Claude Code's and the desktop app's own file names. Reads are bounded and never block on a FIFO or a device.

import Foundation
import ProfileCore

/// One sighting of an account: where it was seen and what that place says of it, its named fields only.
public struct FoundAccount: Equatable {
    /// Where it was seen.
    public enum Source: String, Equatable, Codable {
        /// A Claude Code folder's own record (.claude.json).
        case record
        /// A backup Claude Code keeps of a record (.claude.json.backup*).
        case backup
        /// The desktop app's Code sessions (claude-code-sessions/<account>/<organisation>/): names and dates only.
        case appSessions
        /// The desktop app's agent sessions (local-agent-mode-sessions/…): names, dates and the address a record names.
        case appAgentSessions
        /// A Claude Code transcript (the account id alone): read from chats.
        case transcript
    }

    /// The account id, in its normal form (AccountID.normal), never empty (set by `init` only).
    public internal(set) var accountID: String
    /// The organisation's id in its normal form; nil when the place names none (a transcript).
    public internal(set) var organizationID: String?
    public var email: String?
    /// The organisation's name and type as Claude wrote them (an app says them in its own words).
    public var organizationName: String?
    public var organizationType: String?
    /// The plan's name as recorded ("Ultra").
    public var plan: String?
    /// When the account was last used there (a session written under it); nil: not known.
    public var lastUsed: Date?
    public var source: Source
    /// The file or folder it was seen in.
    public var path: String

    /// nil when `accountID` is empty (a place that names no account). Ids are kept in their normal form; an empty
    /// organisation id is none.
    public init?(accountID: String, organizationID: String? = nil, email: String? = nil, organizationName: String? = nil,
                 organizationType: String? = nil, plan: String? = nil, lastUsed: Date? = nil, source: Source, path: String) {
        guard !accountID.isEmpty else { return nil }
        self.accountID = AccountID.normal(accountID)
        self.organizationID = organizationID.flatMap { $0.isEmpty ? nil : AccountID.normal($0) }
        self.email = email; self.organizationName = organizationName; self.organizationType = organizationType
        self.plan = plan; self.lastUsed = lastUsed; self.source = source; self.path = path
    }

    /// The seat it names: both ids UUID-shaped (as cl_audit kept its pairs); nil otherwise.
    public var seat: SeatID? {
        guard AccountSources.isUUID(accountID), let o = organizationID, AccountSources.isUUID(o) else { return nil }
        return SeatID(account: accountID, organization: o)
    }

    /// As ClaudeAuth names an account (guessed: a file).
    public var account: SignedInAccount {
        SignedInAccount(accountID: accountID, email: email, organizationID: organizationID, organizationName: organizationName,
                        plan: plan, origin: .record)
    }
}

/// The sightings put together, first seen first (the order the caller read its sources in), as cl_audit's account list
/// put its records together: each account's address and plan (as written, a record whose account id isn't UUID-shaped
/// included), each organisation's name and type (both from the first record that names either), every seat in order (both
/// ids UUID-shaped), when each seat was last used, and the ids a transcript names alone.
public struct FoundAccounts: Equatable {
    public var emails: [String: String] = [:]                 // account id → address
    public var plans: [String: String] = [:]                  // account id → plan, as written
    public var organizationNames: [String: String] = [:]      // organisation id → name
    public var organizationTypes: [String: String] = [:]      // organisation id → type
    public var seats: [SeatID] = []                           // every account/organisation pair, in the order seen
    public var lastUsed: [SeatID: Date] = [:]
    /// Accounts a transcript names by their id alone and no seat names.
    public var idsAlone: [String] = []
    /// Every account seen, in the order first seen (any source).
    public private(set) var accounts: [String] = []

    public init() {}

    public init(_ found: [FoundAccount]) { self.init(); add(found) }

    /// Adds sightings: a value already known is kept (first seen wins), a later date of use replaces an earlier one.
    public mutating func add(_ found: [FoundAccount]) {
        for f in found {
            let a = f.accountID
            if !accounts.contains(a) { accounts.append(a) }
            if emails[a] == nil, let e = f.email, !e.isEmpty { emails[a] = e }
            if plans[a] == nil, let p = f.plan, !p.isEmpty { plans[a] = p }
            // the organisation's name and type, both from one record: the first that names either
            if let g = f.organizationID, organizationNames[g] == nil, organizationTypes[g] == nil,
               f.organizationName?.isEmpty == false || f.organizationType?.isEmpty == false {
                if let n = f.organizationName, !n.isEmpty { organizationNames[g] = n }
                if let t = f.organizationType, !t.isEmpty { organizationTypes[g] = t }
            }
            if let s = f.seat {
                if !seats.contains(s) { seats.append(s) }
                if let d = f.lastUsed, d > (lastUsed[s] ?? .distantPast) { lastUsed[s] = d }
                idsAlone.removeAll { $0 == a }                    // now known by a seat
            } else if f.source == .transcript, !idsAlone.contains(a), !seats.contains(where: { $0.account == a }) {
                idsAlone.append(a)
            }
        }
    }

    /// The organisation the account's own record named first (its first seat seen), nil when none was.
    public func organization(of account: String) -> String? {
        let a = AccountID.normal(account)
        return seats.first { $0.account == a }?.organization
    }
}

public enum AccountSources {
    /// A name shaped like a UUID (any case), as Claude names accounts, organisations and sessions.
    public static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    // MARK: Claude Code's records

    /// A backup's name as Claude Code writes it: ".claude.json.backup", or that, "." and digits (a time).
    public static func isBackupName(_ n: String) -> Bool {
        let base = ".claude.json.backup"
        if n == base { return true }
        guard n.hasPrefix(base + ".") else { return false }
        let tail = n.dropFirst(base.count + 1)
        return !tail.isEmpty && tail.allSatisfy(\.isASCII) && tail.allSatisfy(\.isNumber)
    }

    /// A folder's record and the backups Claude Code keeps of it, the record first: <folder>/backups/<backup name>, and
    /// for the default folder also <home>/<backup name> (`isBackupName`). Names only (nothing is read).
    public static func folderRecordFiles(_ folder: AuthFolder) -> [String] {
        var out = [folder.recordPath]
        func backups(_ d: String) {
            for n in list(d) where isBackupName(n) { out.append((d as NSString).appendingPathComponent(n)) }
        }
        backups((folder.path as NSString).appendingPathComponent("backups"))
        if folder.isDefault { backups(folder.home) }
        return out
    }

    /// The Claude Code folders in a home folder: ~/.claude first, then every ~/.claude-* folder by name, a link to a folder
    /// included (a dotfiles set-up links them), never claude-transplant's ~/.claude-switch (its accounts' store, not a
    /// folder Claude Code runs on). As paths with ~ (the way a person names them).
    public static func claudeFolders(home: String) -> [String] {
        list(home).filter { n in
            guard n == ".claude" || (n.hasPrefix(".claude-") && n != ".claude-switch") else { return false }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: (home as NSString).appendingPathComponent(n), isDirectory: &isDir) && isDir.boolValue
        }
        .sorted { a, b in a == ".claude" ? true : b == ".claude" ? false : a < b }
        .map { "~/" + $0 }
    }

    /// Every record in a home folder: each ~/.claude* (a folder's .claude.json, or the file itself) and each
    /// ~/.claude-switch/accounts/<name>/.claude.json (claude-transplant's). Names only. Read for the profile on the default
    /// folder (it collects every folder's account: an app adds none of them to another profile by itself).
    public static func homeRecordFiles(home: String) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for n in list(home) where n.hasPrefix(".claude") {
            let p = (home as NSString).appendingPathComponent(n)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            out.append(isDir.boolValue ? (p as NSString).appendingPathComponent(".claude.json") : p)
        }
        let sw = (home as NSString).appendingPathComponent(".claude-switch/accounts")
        for n in list(sw) { out.append((sw as NSString).appendingPathComponent("\(n)/.claude.json")) }
        return out
    }

    /// The accounts the records at `paths` name (their oauthAccount blocks, named fields only, bounded reads): one sighting
    /// per record that names an account id, in order, its fields as written (an id that isn't UUID-shaped too: its address
    /// and plan count, it just names no seat, as cl_audit kept them); a backup's name (`isBackupName`) is a backup. `read`:
    /// the record reader (RecordFile's, bounded, by default; an app passes its own cached one).
    public static func records(_ paths: [String], read: (String) -> [String: Any]? = { RecordFile.oauthAccount($0) }) -> [FoundAccount] {
        paths.compactMap { p in
            guard let o = read(p), let a = o["accountUuid"] as? String else { return nil }
            func text(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            return FoundAccount(accountID: a, organizationID: text("organizationUuid"), email: text("emailAddress"),
                                organizationName: text("organizationName"), organizationType: text("organizationType"),
                                plan: text("planDisplayName"), source: isBackupName((p as NSString).lastPathComponent) ? .backup : .record,
                                path: p)
        }
    }

    // MARK: folders

    static func list(_ dir: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() }

    /// A folder's names, sorted (at most `limit` looked at, in the order the disk gives them).
    static func names(_ dir: String, limit: Int?) -> [String] {
        guard let limit else { return list(dir) }
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

    static func isRealFolder(_ p: String) -> Bool { var st = stat(); return lstat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR }
    static func isRealFile(_ p: String) -> Bool { var st = stat(); return lstat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG }

    /// When a real file (not a link) last changed, by one lstat; nil when it isn't one.
    static func modified(_ p: String) -> Date? {
        var st = stat()
        guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
    }
}
