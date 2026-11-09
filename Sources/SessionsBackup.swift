// SessionsBackup: a quick copy of a profile's sessions, on this Mac. One is made by every switch that moves the
// sessions (SwitchEngine.run, right after the window is known closed and before anything moves) and one by Back up now
// (Settings ▸ a profile ▸ Sessions); they are listed there, kept as General ▸ Backups says, and restored in a later build.
//
// A backup is a folder <backups place>/<profile id>/<backup id>/ with a backup.json that says what is in it:
//   window/<account>/<org>/…     the Claude window's Code-tab list: every claude-code-sessions/<account>/<org> folder
//                                (the entries and scheduled-tasks.json), for every account that has one
//   sidebar/epitaxyPrefs.json    the window's sidebar records: only the epitaxyPrefs part of claude_desktop_config.json,
//                                never the whole file (it holds MCP settings, which may carry keys)
//   records/…                    cl_audit's own: the profile's entry, and the receipt of the switch it was made for
//   transcripts/<project>/…      Claude Code's transcripts (<Claude Code folder>/projects), optional
//
// Never in a backup: a sign-in. No .claude.json, nothing named like credentials, no Keychain access at all, and nothing
// outside those paths. Files are copied as APFS clones (fclonefileat, with fcopyfile as the fallback), which share space with the
// originals and take seconds; on another volume that can't be, so the file is copied for real, and the size words say so.
// A source file is never changed, and a backup is a new folder: it is built under a hidden name and renamed into place
// only when whole, never over an existing one.

import Foundation

struct BackupError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

enum SessionsBackup {
    enum Kind: Codable, Equatable {
        case beforeSwitch(String)           // the switch's receipt id
        case manual
        case imported(String)               // unpacked from an export (SessionsImport.swift): the file's name

        private enum Keys: String, CodingKey { case type, receipt, file }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "beforeSwitch": self = .beforeSwitch(try c.decode(String.self, forKey: .receipt))
            case "imported": self = .imported((try? c.decode(String.self, forKey: .file)) ?? "an export")
            default: self = .manual
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .beforeSwitch(let r): try c.encode("beforeSwitch", forKey: .type); try c.encode(r, forKey: .receipt)
            case .manual: try c.encode("manual", forKey: .type)
            case .imported(let f): try c.encode("imported", forKey: .type); try c.encode(f, forKey: .file)
            }
        }
        var isImport: Bool { if case .imported = self { return true }; return false }
    }

    /// One thing in a backup: where it was (absolute) and where it is (relative to the backup's folder).
    struct Item: Codable, Equatable {
        enum Role: String, Codable { case window, sidebar, record, transcript }
        var role: Role
        var original: String
        var path: String
        var bytes: Int64
        var part: String? = nil             // sidebar: the part of the original that was taken
    }

    struct Counts: Codable, Equatable {
        var sessions = 0                    // entries in the window's Code-tab list
        var sidebar = 0                     // of them, those in the sidebar (not archived)
        var tasks = 0                       // scheduled tasks
        var transcripts = 0                 // Claude Code's session transcripts
    }

    struct Manifest: Codable, Equatable, Identifiable {
        var version = 1
        var id: String
        var profile: String
        var kind: Kind
        var created: Date
        var seconds: Double
        var accounts: [SeatID]              // by id only, never an address
        var counts: Counts
        var window: Bool                    // the Code-tab list and sidebar records are in
        var transcripts: Bool
        var bytes: Int64                    // logical size of everything in it
        var cloned: Int                     // files that share space with the originals
        var copied: Int                     // files copied for real (the place is on another volume)
        var copiedBytes: Int64
        var leftOut: Int                    // files not taken: sign-in names, or gone while copying
        var dataDir: String                 // where the window's data was, and the Claude Code folder
        var codeDir: String
        var items: [Item]
    }

    /// What a backup is made from.
    struct Source {
        var profile: String
        var dataDir: String                 // the window's data folder (expanded); "" when the profile has none
        var codeDir: String                 // the Claude Code folder (expanded)
        var entry: AccountEntry? = nil      // cl_audit's record of the profile

        init(profile: String, dataDir: String, codeDir: String, entry: AccountEntry? = nil) {
            self.profile = profile; self.dataDir = dataDir.isEmpty ? "" : expand(dataDir); self.codeDir = expand(codeDir); self.entry = entry
        }

        init(_ e: AccountEntry) {
            let dir = e.desktop == .standard ? FolderKey.standardDataDir : (Account(e).claudeUserDataDir ?? "")
            self.init(profile: e.id, dataDir: dir, codeDir: Account(e).configDir, entry: e)
        }
    }

    /// cl_audit's record of the profile as a backup keeps it: ids only. No address, no label, no `was`: it is read back as
    /// this record, never as an AccountEntry.
    struct ProfileRecord: Codable, Equatable {
        struct Standby: Codable, Equatable { var id: String; var seat: SeatID? }
        var id: String
        var name: String
        var seat: SeatID?
        var standby: [Standby]

        init(_ e: AccountEntry) {
            id = e.id; name = e.name
            seat = e.seat.map(SeatID.init)
            standby = e.standby.map { Standby(id: $0.id, seat: $0.seat.map(SeatID.init)) }
        }
    }

    /// Why a folder can't be where backups go: it is, or holds, what is copied from (it would copy itself). nil: fine.
    static func placeProblem(_ place: URL, for sources: [Source]) -> String? {
        for s in sources {
            var from = [(s.codeDir as NSString).appendingPathComponent("projects")]
            if !s.dataDir.isEmpty { from += [s.dataDir, (s.dataDir as NSString).appendingPathComponent("claude-code-sessions")] }
            if from.contains(where: { FolderKey.overlaps(place.path, $0) }) {
                return "the backups folder \(tilde(place.path)) is inside the sessions it copies, or holds them"
            }
        }
        return nil
    }

    // MARK: names

    static func newID(_ d: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: d))-\(UUID().uuidString.prefix(4).lowercased())"
    }

    static func validID(_ s: String) -> Bool {
        s.range(of: #"^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$"#, options: .regularExpression) != nil
    }

    /// A profile id names a folder: any id that is one plain name (Unicode letters are fine).
    static func validProfile(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 255 && !s.contains("/") && !s.contains("\0") && !s.hasPrefix(".")      // also not "." or ".."
    }

    /// A file that could be (or hold) a sign-in is never taken, whatever folder it is in.
    static func isSignIn(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix(".claude.json") || n.contains("credential") || n.contains("keychain") || n.contains("oauth") || n == "auth.json"
    }

    private static func skipped(_ name: String) -> Bool {
        isSignIn(name) || name == ".DS_Store" || (name.hasPrefix(".") && name.hasSuffix(".tmp"))   // SwitchEngine.writeNew's temp files
    }

    static func folder(profile: String, place: URL) -> URL { place.appendingPathComponent(profile) }

    // MARK: what there is to back up (read-only)

    private struct Planned {
        var role: Item.Role
        var src: String
        var rel: String
        var original: String
        var bytes: Int64
    }

    private struct Gathered {
        var files: [Planned] = []
        var counts = Counts()
        var accounts: [SeatID] = []
        var bytes: Int64 = 0
        var leftOut = 0
        var oldest: Date?
    }

    private static func mode(_ path: String) -> (kind: mode_t, size: Int64, mtime: Date, links: Int)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return (st.st_mode & S_IFMT, Int64(st.st_size), Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)), Int(st.st_nlink))
    }

    private static func names(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    }

    /// The window's folders and Claude Code's transcripts as they are now. Symbolic links inside are never followed; the
    /// transcripts folder itself may be one (a folder that shares its history from another).
    private static func gather(_ s: Source, window: Bool, transcripts: Bool) -> Gathered {
        var g = Gathered()
        if window, !s.dataDir.isEmpty {
            let root = (s.dataDir as NSString).appendingPathComponent("claude-code-sessions")
            var seen = Set<SeatID>()
            for account in names(root) where mode((root as NSString).appendingPathComponent(account))?.kind == S_IFDIR {
                let adir = (root as NSString).appendingPathComponent(account)
                for org in names(adir) where mode((adir as NSString).appendingPathComponent(org))?.kind == S_IFDIR {
                    let odir = (adir as NSString).appendingPathComponent(org)
                    seen.insert(SeatID(account: account, organization: org))
                    for name in names(odir) {
                        let path = (odir as NSString).appendingPathComponent(name)
                        guard let m = mode(path), m.kind == S_IFREG else { continue }
                        if skipped(name) || m.links > 1 { g.leftOut += 1; continue }       // (a hard link: never taken, nor counted)
                        g.files.append(Planned(role: .window, src: path, rel: "window/\(account)/\(org)/\(name)", original: path, bytes: m.size))
                        g.bytes += m.size
                        if name.hasPrefix("local_") && name.hasSuffix(".json") {
                            g.counts.sessions += 1
                            let d = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
                            if !SidebarPlan.flag("isArchived", in: d) { g.counts.sidebar += 1 }
                        } else if name == "scheduled-tasks.json",
                                  let d = FileManager.default.contents(atPath: path),
                                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                            g.counts.tasks += (j["scheduledTasks"] as? [Any])?.count ?? 0
                        }
                    }
                }
            }
            g.accounts = seen.sorted { ($0.account, $0.organization) < ($1.account, $1.organization) }
        }
        if transcripts {
            let projects = (s.codeDir as NSString).appendingPathComponent("projects")
            let real = URL(fileURLWithPath: projects).resolvingSymlinksInPath().path       // the folder itself may be a link
            let counted = QuickChatSettings.load().counted
            if mode(real)?.kind == S_IFDIR, let walk = FileManager.default.enumerator(atPath: real) {
                for case let rel as String in walk {
                    // the quick chat's sessions are left out of the counts and backups unless Counting says otherwise
                    if QuickChatData.leftOut(rel, counted: counted) {
                        if !rel.contains("/") { walk.skipDescendants() }
                        continue
                    }
                    let path = (real as NSString).appendingPathComponent(rel)
                    guard let m = mode(path) else { continue }
                    guard m.kind == S_IFREG else { continue }                 // a link inside is never followed (nor does the walk)
                    // a name like a sign-in, or a file with another hard link (the one way a sign-in could be under another name)
                    if skipped((rel as NSString).lastPathComponent) || m.links > 1 { g.leftOut += 1; continue }
                    g.files.append(Planned(role: .transcript, src: path, rel: "transcripts/\(rel)",
                                           original: (projects as NSString).appendingPathComponent(rel), bytes: m.size))
                    g.bytes += m.size
                    // one transcript per session: the .jsonl files directly in a project's folder
                    if rel.hasSuffix(".jsonl"), rel.split(separator: "/").count == 2 {
                        g.counts.transcripts += 1
                        if g.oldest.map({ m.mtime < $0 }) ?? true { g.oldest = m.mtime }
                    }
                }
            }
        }
        return g
    }

    /// What a backup of this source would take, read and counted without taking anything (Export's preview). `src` is where
    /// each file is now.
    static func inventory(_ s: Source, window: Bool, transcripts: Bool)
        -> (files: [(role: Item.Role, rel: String, src: String, bytes: Int64)], counts: Counts, bytes: Int64, leftOut: Int) {
        let g = gather(s, window: window, transcripts: transcripts)
        return (g.files.map { ($0.role, $0.rel, $0.src, $0.bytes) }, g.counts, g.bytes, g.leftOut)
    }

    /// What Settings ▸ a profile ▸ Sessions says is kept here: Claude Code's transcripts and the window's entries.
    struct Kept: Equatable {
        var transcripts = 0
        var entries = 0
        var sidebar = 0
        var bytes: Int64 = 0
        var transcriptBytes: Int64 = 0      // of them, the transcripts'
        var oldest: Date?
    }

    static func kept(_ s: Source) -> Kept {
        let g = gather(s, window: true, transcripts: true)
        return Kept(transcripts: g.counts.transcripts, entries: g.counts.sessions, sidebar: g.counts.sidebar, bytes: g.bytes,
                    transcriptBytes: g.files.filter { $0.role == .transcript }.reduce(0) { $0 + $1.bytes }, oldest: g.oldest)
    }

    /// `kept`, remembered per profile: shown at once, counted again in the background by whoever shows it.
    enum KeptCache {
        private static let lock = NSLock()
        private static var cached: [String: Kept] = [:]
        static func get(_ profile: String) -> Kept? { lock.lock(); defer { lock.unlock() }; return cached[profile] }
        static func set(_ profile: String, _ k: Kept) { lock.lock(); cached[profile] = k; lock.unlock() }
    }

    // MARK: making one

    /// Makes a backup under `place` and returns what it holds. `window` false leaves the Code-tab list and the sidebar
    /// records out (the window is open: it rewrites its entries from memory). Throws, with nothing left behind, when it
    /// can't be made whole. Takes no lock: the switch holds one (SwitchEngine.run), Back up now takes it (`manual`).
    @discardableResult
    static func make(_ s: Source, id: String = newID(), kind: Kind, window: Bool = true, transcripts: Bool = true,
                     receipt: SwitchReceipt? = nil, place: URL, now: Date = Date()) throws -> Manifest {
        guard validProfile(s.profile), validID(id) else { throw BackupError("the profile or backup name isn't a plain one") }
        if let why = placeProblem(place, for: [s]) { throw BackupError(why) }
        let started = Date()
        let fm = FileManager.default
        let profileDir = folder(profile: s.profile, place: place)
        let final = profileDir.appendingPathComponent(id)
        let partial = profileDir.appendingPathComponent(".\(id).partial")
        do {
            try fm.createDirectory(at: profileDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw BackupError("the backups folder \(tilde(place.path)) can't be written") }
        guard !fm.fileExists(atPath: final.path) else { throw BackupError("a backup with that name is there already") }
        guard mkdir(partial.path, 0o700) == 0 else { throw BackupError("couldn't start a backup in \(tilde(place.path))") }
        var done = false
        defer { if !done { try? fm.removeItem(at: partial) } }

        let g = gather(s, window: window, transcripts: transcripts)
        var items: [Item] = []
        var cloned = 0, copied = 0, copiedBytes: Int64 = 0, leftOut = g.leftOut
        var made = Set<String>()
        func dirFor(_ rel: String) throws -> String {
            let dir = ((partial.path as NSString).appendingPathComponent(rel) as NSString).deletingLastPathComponent
            if made.insert(dir).inserted {
                do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
                catch { throw BackupError("couldn't write in \(tilde(place.path))") }
            }
            return (partial.path as NSString).appendingPathComponent(rel)
        }

        // the files, as clones (or real copies on another volume: the room for them is checked first)
        var roomChecked = false
        func needRoom() throws {
            roomChecked = true
            var fs = statfs()
            let free = statfs(place.path, &fs) == 0 ? Int64(fs.f_bavail) * Int64(fs.f_bsize) : Int64.max
            guard free > g.bytes + g.bytes / 10 else {
                throw BackupError("the backups folder is on another volume and doesn't have room for a full copy (\(sizeWords(g.bytes)) needed)")
            }
        }
        if let first = g.files.first, !sameVolume(place, as: first.src) { try needRoom() }
        for f in g.files {
            let dst = try dirFor(f.rel)
            var shared = true                                         // cloned (else copied for real)
            switch copyOne(f.src, dst, single: true) {
            case .cloned: break
            case .copied:
                shared = false
                if !roomChecked { try needRoom() }                        // a volume without clones, on the same device
            case .gone: leftOut += 1; continue                        // deleted meanwhile (Claude Code ages its own out)
            case .failed(let why): throw BackupError("couldn't copy \((f.src as NSString).lastPathComponent) (\(why))")
            }
            // what landed must be a plain file: a link swapped in after it was looked at is not kept
            guard mode(dst)?.kind == S_IFREG else { unlink(dst); leftOut += 1; continue }
            if shared { cloned += 1 } else { copied += 1; copiedBytes += f.bytes }
            items.append(Item(role: f.role, original: f.original, path: f.rel, bytes: f.bytes))
        }

        // the window's sidebar records: only epitaxyPrefs
        if window, let data = sidebarRecords(dataDir: s.dataDir) {
            try put(data, "sidebar/epitaxyPrefs.json", in: partial, dirFor)
            items.append(Item(role: .sidebar, original: (s.dataDir as NSString).appendingPathComponent("claude_desktop_config.json"),
                              path: "sidebar/epitaxyPrefs.json", bytes: Int64(data.count), part: "preferences.epitaxyPrefs"))
        }
        // cl_audit's records: the profile (ids only, no address), and the receipt of the switch this is for
        if let e = s.entry {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? enc.encode(ProfileRecord(e)) {
                try put(data, "records/profile.json", in: partial, dirFor)
                items.append(Item(role: .record, original: Store.configURL.path, path: "records/profile.json", bytes: Int64(data.count), part: "accounts[id=\(e.id)]"))
            }
        }
        if let r = receipt, let data = try? SwitchEngine.encoded(r) {
            try put(data, "records/receipt.json", in: partial, dirFor)
            items.append(Item(role: .record, original: SwitchEngine.root.appendingPathComponent("\(r.id)/receipt.json").path,
                              path: "records/receipt.json", bytes: Int64(data.count)))
        }

        let m = Manifest(id: id, profile: s.profile, kind: kind, created: now, seconds: 0, accounts: g.accounts, counts: g.counts,
                         window: window, transcripts: transcripts,
                         bytes: items.reduce(0) { $0 + $1.bytes }, cloned: cloned, copied: copied, copiedBytes: copiedBytes,
                         leftOut: leftOut, dataDir: s.dataDir, codeDir: s.codeDir, items: items)
        var out = m
        out.seconds = (Date().timeIntervalSince(started) * 10).rounded() / 10
        try put(try encode(out), "backup.json", in: partial, dirFor)
        guard renamex_np(partial.path, final.path, UInt32(RENAME_EXCL)) == 0 else { throw BackupError("couldn't put the backup in place") }
        done = true
        return out
    }

    /// Back up now: under the switch lock (no switch and no claude-transplant run moves sessions meanwhile), then pruned.
    /// `window` true (the window was closed when it started): `windowClosed` is asked again once the backup is made, and
    /// if the window opened meanwhile the backup is taken away.
    static func manual(_ s: Source, window: Bool, transcripts: Bool = true, place: URL = BackupPrefs.placeURL,
                       keepLast: Int = BackupPrefs.keepLast, keepDays: Int = BackupPrefs.keepDays,
                       windowClosed: () -> Bool = { true }) throws -> Manifest {
        let lock: SwitchEngine.Lock
        do { lock = try SwitchEngine.Lock.take() } catch { throw BackupError("\(error)") }
        defer { lock.release() }
        let m = try make(s, kind: .manual, window: window, transcripts: transcripts, place: place)
        if window, !windowClosed() {
            discard(profile: s.profile, id: m.id, place: place)
            throw BackupError("The Claude window opened during the backup; try again.")
        }
        prune(profile: s.profile, place: place, keepLast: keepLast, keepDays: keepDays)
        return m
    }

    enum Copied { case cloned, copied, gone, failed(String) }

    /// One file: cloned, else (another volume, or a file system without clones) copied for real. It is opened without
    /// following links and looked at through that open file (a plain file; with `single`, one with no other hard link),
    /// then cloned or copied from that file itself, so a link swapped in after it was looked at is never followed: the
    /// file is left out (.gone). Never over a file.
    static func copyOne(_ src: String, _ dst: String, single: Bool) -> Copied {
        let fd = open(src, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return .gone }                              // gone, or a link now
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, !(single && st.st_nlink > 1) else { return .gone }
        if fclonefileat(fd, AT_FDCWD, dst, 0) == 0 { return .cloned }
        var e = errno
        if e == ENOTSUP || e == EXDEV || e == EINVAL {
            let out = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard out >= 0 else { return .failed(String(cString: strerror(errno))) }
            defer { close(out) }
            if fcopyfile(fd, out, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 { return .copied }
            e = errno
            unlink(dst)
        }
        return .failed(String(cString: strerror(e)))
    }

    private static func put(_ data: Data, _ rel: String, in partial: URL, _ dirFor: (String) throws -> String) throws {
        let path = try dirFor(rel)
        do { try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting) }
        catch { throw BackupError("couldn't write \((rel as NSString).lastPathComponent)") }
        chmod(path, 0o600)
    }

    private static func encode(_ m: Manifest) throws -> Data {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(m)
    }

    /// The epitaxyPrefs part of the window's claude_desktop_config.json, as its own JSON; nothing else of that file.
    static func sidebarRecords(dataDir: String) -> Data? {
        guard !dataDir.isEmpty,
              let data = FileManager.default.contents(atPath: (dataDir as NSString).appendingPathComponent("claude_desktop_config.json")),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prefs = (j["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: prefs, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: listing, deleting, pruning

    /// A profile's backups under `place`, newest first. A folder without a readable backup.json (one being made, or
    /// not cl_audit's) is not listed.
    static func list(profile: String, place: URL = BackupPrefs.placeURL) -> [Manifest] {
        guard validProfile(profile) else { return [] }
        let dir = folder(profile: profile, place: place)
        return names(dir.path).filter { !$0.hasPrefix(".") && validID($0) }
            .compactMap { load(profile: profile, id: $0, place: place) }
            .sorted { $0.created != $1.created ? $0.created > $1.created : $0.id > $1.id }
    }

    /// Backups that a switch's or a restore's receipt names in another place than `place` (General ▸ Backups was changed
    /// since, or the switch was made with another): listed with their place, so Restore reaches them. Newest first.
    static func elsewhere(profile: String, place: URL = BackupPrefs.placeURL) -> [(manifest: Manifest, place: String)] {
        guard validProfile(profile) else { return [] }
        let here = FolderKey.canonical(place.path)
        var refs: [(id: String, place: String)] = []
        for r in SwitchEngine.receipts(profile: profile) { if let b = r.backup, let p = r.backupPlace { refs.append((b, p)) } }
        for r in SessionsRestore.headers() where r.profile == profile { refs.append((r.backup, r.backupPlace)) }
        var seen = Set<String>(), out: [(manifest: Manifest, place: String)] = []
        for ref in refs where FolderKey.canonical(ref.place) != here {
            guard seen.insert(FolderKey.canonical(ref.place) + "/" + ref.id).inserted,
                  let m = load(profile: profile, id: ref.id, place: URL(fileURLWithPath: ref.place)) else { continue }
            out.append((m, ref.place))
        }
        return out.sorted { $0.manifest.created > $1.manifest.created }
    }

    static func load(profile: String, id: String, place: URL = BackupPrefs.placeURL) -> Manifest? {
        guard validProfile(profile), validID(id) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let file = folder(profile: profile, place: place).appendingPathComponent("\(id)/backup.json")
        guard let m = (try? Data(contentsOf: file)).flatMap({ try? dec.decode(Manifest.self, from: $0) }),
              m.id == id, m.profile == profile else { return nil }
        return m
    }

    /// The backups that must stay: those named by a switch that stopped half way (receipt.backup, in this place), and
    /// every one that names a switch whose receipt is there but can't be read (it may be an unfinished one).
    private static func keeps(profile: String, place: URL) -> (ids: Set<String>, receipts: Set<String>) {
        var ids = Set<String>(), unreadable = Set<String>()
        let here = FolderKey.canonical(place.path)
        for n in names(SwitchEngine.root.path) where !n.hasPrefix(".") && n.hasSuffix("-\(profile)") {
            let file = SwitchEngine.root.appendingPathComponent("\(n)/receipt.json").path
            guard mode(file) != nil else { continue }
            guard let r = SwitchEngine.load(n) else { unreadable.insert(n); continue }
            if r.profile == profile, r.unfinished, let b = r.backup, r.backupPlace.map({ FolderKey.canonical($0) == here }) ?? true { ids.insert(b) }
        }
        // a restore that stopped half way finishes from its backup
        for r in SessionsRestore.unfinished(profile: profile) where FolderKey.canonical(r.backupPlace) == here { ids.insert(r.backup) }
        // and the backup an Undo this switch is about to restore from (until that restore has run)
        for u in SessionsRestore.pendingUndoBackups(profile: profile) where FolderKey.canonical(u.place) == here { ids.insert(u.id) }
        return (ids, unreadable)
    }

    private static func isKept(_ m: Manifest, _ k: (ids: Set<String>, receipts: Set<String>)) -> String? {
        if k.ids.contains(m.id) { return "A switch or a restore that stopped half way names this backup: Undo it or finish it first." }
        if case .beforeSwitch(let rid) = m.kind, k.receipts.contains(rid) {
            return "The receipt of the switch this backup was made for can't be read, so the backup stays."
        }
        return nil
    }

    /// Deletes one backup. Not one an unfinished switch names (its Undo and the backup point at each other).
    static func delete(profile: String, id: String, place: URL = BackupPrefs.placeURL) throws {
        guard let m = load(profile: profile, id: id, place: place) else { throw BackupError("That backup isn't there any more.") }
        if let why = isKept(m, keeps(profile: profile, place: place)) { throw BackupError(why) }
        do { try FileManager.default.removeItem(at: folder(profile: profile, place: place).appendingPathComponent(id)) }
        catch { throw BackupError("The backup couldn't be deleted (\(error.localizedDescription)).") }
        SessionsRestore.prune(profile: profile)             // the receipts of restores from it go too
    }

    /// Takes away a backup this run just made and no receipt names yet (the switch stopped before anything moved).
    static func discard(profile: String, id: String, place: URL) {
        guard validProfile(profile), validID(id) else { return }
        try? FileManager.default.removeItem(at: folder(profile: profile, place: place).appendingPathComponent(id))
    }

    /// Keeps the last `keepLast` backups and any made under `keepDays` days ago; the rest go. Never one an unfinished
    /// switch names, nor one whose switch's receipt can't be read. Returns the ids deleted.
    @discardableResult
    static func prune(profile: String, place: URL = BackupPrefs.placeURL, keepLast: Int = BackupPrefs.keepLast,
                      keepDays: Int = BackupPrefs.keepDays, now: Date = Date()) -> [String] {
        let all = list(profile: profile, place: place)
        let kept = keeps(profile: profile, place: place)
        var gone: [String] = []
        for (i, m) in all.enumerated() {
            if i < max(0, keepLast) { continue }
            if now.timeIntervalSince(m.created) < Double(max(0, keepDays)) * 86400 { continue }
            if isKept(m, kept) != nil { continue }
            if (try? FileManager.default.removeItem(at: folder(profile: profile, place: place).appendingPathComponent(m.id))) != nil { gone.append(m.id) }
        }
        // a backup that was being made when cl_audit stopped: exactly ".<id>.partial", a real folder, a day old
        let dir = folder(profile: profile, place: place)
        for n in names(dir.path) where n.hasPrefix(".") && n.hasSuffix(".partial") {
            let id = String(n.dropFirst().dropLast(".partial".count))
            if validID(id), let m = mode(dir.appendingPathComponent(n).path), m.kind == S_IFDIR, now.timeIntervalSince(m.mtime) > 86400 {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
            }
        }
        SessionsRestore.prune(profile: profile, now: now)   // and the receipts of finished restores whose backup is gone, or 30 days old
        return gone
    }

    // MARK: words

    /// A number and its unit never split over two lines.
    static func tight(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "\u{00A0}") }

    static func sizeWords(_ bytes: Int64) -> String { tight(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }

    /// "3 s", "under 1 s", "1 min 5 s"
    static func secondsWords(_ s: Double) -> String {
        if s < 0.95 { return tight("under 1 s") }
        let n = Int(s.rounded())
        return tight(n < 60 ? "\(n) s" : n % 60 == 0 ? "\(n / 60) min" : "\(n / 60) min \(n % 60) s")
    }

    /// "5 Nov 18:40" (with the year when it isn't this one); day, month and time stay together.
    static func dateWords(_ d: Date, now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: now) ? "d MMM HH:mm" : "d MMM yyyy HH:mm"
        return tight(f.string(from: d))
    }

    /// "Before switch to ultra-2 · 5 Nov 18:40", "Manual · 2 Nov 09:12". The switch's target is named from the receipt's
    /// own record when `target` is given (receipts name accounts by id only).
    static func title(_ m: Manifest, target: String?, now: Date = Date()) -> String {
        let what: String
        switch m.kind {
        case .beforeSwitch: what = target.map { "Before switch to \($0)" } ?? "Before a switch"
        case .manual: what = "Manual"
        case .imported(let file): what = "Imported from \((file as NSString).deletingPathExtension)"
        }
        return "\(what) · \(dateWords(m.created, now: now))"
    }

    /// "84 sessions · 12 tasks · sidebar · transcripts · 5.5 GB, sharing space with the originals"
    static func summary(_ m: Manifest) -> String {
        func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }
        var parts: [String] = []
        if m.window {
            parts.append(n(m.counts.sessions, "session", "sessions"))
            if m.counts.tasks > 0 { parts.append(n(m.counts.tasks, "task", "tasks")) }
            if m.items.contains(where: { $0.role == .sidebar }) { parts.append("sidebar") }
        } else {
            parts.append("window left out")
        }
        if m.transcripts { parts.append(m.counts.transcripts > 0 ? n(m.counts.transcripts, "transcript", "transcripts") : "transcripts") }
        let size = sizeWords(m.bytes)
        let share: String
        if m.copied == 0 { share = m.cloned > 0 ? ", sharing space with the originals" : "" }
        else if m.cloned == 0 { share = ", a full copy (another volume)" }
        else { share = ", \(sizeWords(m.copiedBytes)) of it a full copy" }
        return parts.joined(separator: " · ") + " · " + size + share
    }

    /// Whether a place is on the same volume as the window's data (clones can be made): its nearest existing folder is.
    static func sameVolume(_ place: URL, as path: String) -> Bool {
        func dev(_ p: String) -> dev_t? { var st = stat(); return stat(p, &st) == 0 ? st.st_dev : nil }
        var p = place.path
        while !FileManager.default.fileExists(atPath: p), p != "/" { p = (p as NSString).deletingLastPathComponent }
        var q = path
        while !FileManager.default.fileExists(atPath: q), q != "/" { q = (q as NSString).deletingLastPathComponent }
        guard let a = dev(p), let b = dev(q) else { return true }
        return a == b
    }
}

// MARK: - General ▸ Backups: where they go and how many are kept

/// Where the preferences live: the app's (UserDefaults), or, in a check, a dictionary (UserDefaults writes to the real
/// ~/Library/Preferences whatever the throwaway home is).
protocol PrefStore: AnyObject {
    func string(forKey: String) -> String?
    func int(forKey: String) -> Int?
    func set(_ value: Any?, forKey: String)
}
extension UserDefaults: PrefStore {
    func int(forKey key: String) -> Int? { object(forKey: key) as? Int }
}
final class MemoryPrefs: PrefStore {
    private var d: [String: Any] = [:]
    private let lock = NSLock()
    func string(forKey k: String) -> String? { lock.lock(); defer { lock.unlock() }; return d[k] as? String }
    func int(forKey k: String) -> Int? { lock.lock(); defer { lock.unlock() }; return d[k] as? Int }
    func set(_ v: Any?, forKey k: String) { lock.lock(); d[k] = v; lock.unlock() }
}

/// Kept with the app's other preferences (as DashboardPrefs does). The engine reads the values straight from the
/// store, so a background thread needs no instance.
final class BackupPrefs: ObservableObject {
    static let shared = BackupPrefs()
    nonisolated(unsafe) static var store: PrefStore = UserDefaults.standard
    static let placeKey = "backupsPlace", lastKey = "backupsKeepLast", daysKey = "backupsKeepDays"
    static let defaultLast = 3, defaultDays = 30

    /// "" is cl_audit's folder ▸ backups.
    @Published var place: String { didSet { Self.store.set(place, forKey: Self.placeKey) } }
    @Published var last: Int { didSet { Self.store.set(last, forKey: Self.lastKey) } }
    @Published var days: Int { didSet { Self.store.set(days, forKey: Self.daysKey) } }

    private init() {
        place = Self.store.string(forKey: Self.placeKey) ?? ""
        last = Self.keepLast
        days = Self.keepDays
    }

    /// Re-reads the store (a check swapped it).
    func reload() { place = Self.store.string(forKey: Self.placeKey) ?? ""; last = Self.keepLast; days = Self.keepDays }

    static var defaultPlace: URL { Store.folder.appendingPathComponent("backups") }

    static var placeURL: URL {
        let p = store.string(forKey: placeKey) ?? ""
        return p.isEmpty ? defaultPlace : URL(fileURLWithPath: expand(p))
    }
    static var keepLast: Int { max(1, store.int(forKey: lastKey) ?? defaultLast) }
    static var keepDays: Int { max(0, store.int(forKey: daysKey) ?? defaultDays) }

    /// "cl_audit's folder ▸ backups", or the folder with ~.
    var placeWords: String { place.isEmpty ? "cl_audit's folder ▸ backups" : place }
}

// MARK: - Claude Code's own clean-up: how long it keeps its transcripts

/// `cleanupPeriodDays` in <Claude Code folder>/settings.json (Claude Code deletes the transcripts of sessions from the
/// terminal after that many days; 30 when it isn't set; ones from the Claude window it keeps, see Retention.swift).
/// settings.json is the operator's: it is only ever changed by replacing that one number
/// (or adding the key to a file that has the usual form), and anything else is refused with the file left as it was.
enum CodeCleanup {
    static let key = "cleanupPeriodDays"
    static let standard = 30
    /// A check's seam: runs just before the swap, to change the file at the worst moment.
    nonisolated(unsafe) static var beforeSwap: (() -> Void)?
    static let byHand = "settings.json has a form cl_audit doesn't edit; set cleanupPeriodDays there by hand."

    static func file(_ codeDir: String) -> String { (expand(codeDir) as NSString).appendingPathComponent("settings.json") }

    /// What the file says: the days (30 when there is no file or no key), or why it isn't known (a file that can't be
    /// read or isn't a JSON object, a value that isn't a whole number).
    static func read(codeDir: String) -> (days: Int?, problem: String?) {
        var st = stat()
        guard lstat(file(codeDir), &st) == 0 else { return (standard, nil) }
        guard let d = FileManager.default.contents(atPath: file(codeDir)) else { return (nil, "settings.json can't be read.") }
        if isBlank(d) { return (standard, nil) }
        guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return (nil, "settings.json isn't a JSON object.") }
        guard let v = j[key] else { return (standard, nil) }
        guard let n = whole(v) else { return (nil, "cleanupPeriodDays in settings.json isn't a whole number of days.") }
        return (n, nil)
    }

    static func days(codeDir: String) -> Int? { read(codeDir: codeDir).days }

    /// A JSON value that is a whole number of days, 1 or more (not true, not a string, not a fraction: 30 and 30.0 are the
    /// same to Claude Code, whose zod `int()` takes both); with `zero`, 0 too (desktopSessionCleanupPeriodDays: 0 is no cap).
    /// Any size up to 2^53−1 (zod's safe integers): a huge number is valid to Claude Code, so it must be here too.
    static let maxWhole = 9_007_199_254_740_991.0
    static func whole(_ v: Any?, zero: Bool = false) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), d >= (zero ? 0 : 1), d <= maxWhole else { return nil }
        return Int(d)
    }

    // MARK: sessions from the Claude window (read only; the organisation's managed settings are ManagedSettings in Retention.swift)

    static let desktopKey = "desktopSessionCleanupPeriodDays"

    /// What the user's own settings.json holds about the two keys (Claude Code ignores desktopSessionCleanupPeriodDays in
    /// project and local settings). A key that is there but isn't a whole number is `…Invalid`; a file that can't be read or
    /// isn't a JSON object is `unreadable`. Claude Code skips its clean-up in both cases (Retention.swift).
    struct UserState: Equatable {
        var days: Int?                      // cleanupPeriodDays; nil: not there, or invalid
        var daysPresent = false, daysInvalid = false
        var desktop: Int?                   // desktopSessionCleanupPeriodDays (0: no cap); nil: not there, or invalid
        var desktopPresent = false, desktopInvalid = false
        var unreadable = false
    }

    static func userState(codeDir: String) -> UserState {
        var s = UserState()
        var st = stat()
        guard lstat(file(codeDir), &st) == 0 else { return s }
        guard let d = FileManager.default.contents(atPath: file(codeDir)) else { s.unreadable = true; return s }
        if isBlank(d) { return s }
        guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { s.unreadable = true; return s }
        if let v = j[key] { s.daysPresent = true; if let n = whole(v) { s.days = n } else { s.daysInvalid = true } }
        if let v = j[desktopKey] { s.desktopPresent = true; if let n = whole(v, zero: true) { s.desktop = n } else { s.desktopInvalid = true } }
        return s
    }

    private static func isBlank(_ d: Data) -> Bool { String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Writes the days, keeping everything else byte for byte. A settings.json that is a link is written where it points
    /// (a link to nowhere is refused). The file is replaced atomically and keeps its permissions; if it changed since it
    /// was read, nothing is written. It is made when the folder is there and it isn't (never over a file that appeared
    /// meanwhile); a folder that isn't there is never made. Throws why not, with the file left as it was.
    static func set(_ days: Int, codeDir: String) throws {
        let fm = FileManager.default
        let dir = expand(codeDir)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { throw BackupError("The Claude Code folder isn't there.") }
        let link = file(codeDir)
        var st = stat()
        var target = link
        var before: Data?
        var stamp: (ino: UInt64, sec: Int, nsec: Int, size: Int64)?
        if lstat(link, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFLNK {
                guard let real = realpath(link, nil) else { throw BackupError("settings.json is a link to nowhere; it is left as it is.") }
                target = String(cString: real); free(real)
            }
            var ts = stat()
            guard stat(target, &ts) == 0, (ts.st_mode & S_IFMT) == S_IFREG else { throw BackupError("settings.json isn't a plain file; it is left as it is.") }
            guard let d = fm.contents(atPath: target) else { throw BackupError("settings.json can't be read; it is left as it is.") }
            before = d
            stamp = (UInt64(ts.st_ino), ts.st_mtimespec.tv_sec, ts.st_mtimespec.tv_nsec, Int64(ts.st_size))
            st = ts
        }
        let blank = before.map(isBlank) ?? true
        let new: Data
        if blank {
            new = Data("{\n  \"\(key)\": \(days)\n}\n".utf8)                    // no file, or an empty one: the usual form
        } else {
            new = try edited(before!, days: days)
        }
        // a temp file beside it, with the permissions it had
        let tmp = (target as NSString).deletingLastPathComponent + "/.settings.json.\(UUID().uuidString).tmp"
        let mode = before == nil ? 0o600 : Int(st.st_mode & 0o7777)
        guard fm.createFile(atPath: tmp, contents: new, attributes: [.posixPermissions: NSNumber(value: mode)]) else {
            throw BackupError("settings.json can't be written in \(tilde((target as NSString).deletingLastPathComponent)).")
        }
        beforeSwap?()
        // just before the swap: still the file that was read? (Claude Code writes this file too)
        if let stamp, let before {
            var now = stat()
            let same = stat(target, &now) == 0 && UInt64(now.st_ino) == stamp.ino && now.st_mtimespec.tv_sec == stamp.sec
                && now.st_mtimespec.tv_nsec == stamp.nsec && Int64(now.st_size) == stamp.size && fm.contents(atPath: target) == before
            guard same else { unlink(tmp); throw BackupError("settings.json changed meanwhile; try again.") }
            guard rename(tmp, target) == 0 else { unlink(tmp); throw BackupError("settings.json couldn't be replaced.") }
        } else {
            // a file made meanwhile is never replaced
            guard renamex_np(tmp, target, UInt32(RENAME_EXCL)) == 0 else { unlink(tmp); throw BackupError("settings.json changed meanwhile; try again.") }
        }
    }

    /// The old text with only the number changed, or the key added right after the opening brace: only for a JSON object
    /// with the key once at its top level as a plain whole number (or not at all, and nowhere deeper). Anything else is
    /// refused. Checked: the result reads back as the old object with that one key set.
    static func edited(_ old: Data, days: Int) throws -> Data {
        guard let text = String(data: old, encoding: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: old)) as? [String: Any] else { throw BackupError("settings.json isn't a JSON object; it is left as it is.") }
        var expected = obj
        expected[key] = days
        let scan = scanKeys(text)
        if obj[key] != nil, scan.top.isEmpty { throw BackupError(byHand) }    // there, but not under its plain name
        var out: String?
        switch (scan.top.count, scan.anywhere) {
        case (1, 1):
            let v = scan.top[0]
            let literal = String(text[v])
            guard literal.range(of: #"^-?[0-9]+$"#, options: .regularExpression) != nil else { throw BackupError(byHand) }
            out = text.replacingCharacters(in: v, with: "\(days)")
        case (0, 0):
            guard let open = scan.open else { throw BackupError(byHand) }
            let rest = text[text.index(after: open)...]
            let empty = rest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("}")
            out = String(text[...open]) + "\n  \"\(key)\": \(days)" + (empty ? "\n" : ",") + String(rest)
        default:
            throw BackupError(byHand)                                    // nested too, or twice at the top level
        }
        guard let out, let d = out.data(using: .utf8),
              ((try? JSONSerialization.jsonObject(with: d)) as? NSDictionary)?.isEqual(to: expected) == true else { throw BackupError(byHand) }
        return d
    }

    /// Looks through JSON text: the value ranges of the top-level keys named `key`, how many strings anywhere equal the
    /// key, and where the top-level object opens. Works on the text's bytes (the structure is ASCII).
    private static func scanKeys(_ text: String) -> (top: [Range<String.Index>], anywhere: Int, open: String.Index?) {
        let b = Array(text.utf8)
        func at(_ n: Int) -> String.Index { text.utf8.index(text.utf8.startIndex, offsetBy: n) }
        func space(_ i: inout Int) { while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 } }
        /// A string starting at b[i] == '"': its raw content, and i after the closing quote.
        func string(_ i: inout Int) -> [UInt8] {
            var out: [UInt8] = []
            i += 1
            while i < b.count, b[i] != 0x22 {
                if b[i] == 0x5C { out.append(b[i]); i += 1 }
                if i < b.count { out.append(b[i]); i += 1 }
            }
            i += 1
            return out
        }
        let k = Array(key.utf8)
        var anywhere = 0
        /// Skips one value; counts the strings in it that equal the key.
        func value(_ i: inout Int) {
            space(&i)
            guard i < b.count else { return }
            switch b[i] {
            case 0x22: if string(&i) == k { anywhere += 1 }
            case 0x7B, 0x5B:
                let close: UInt8 = b[i] == 0x7B ? 0x7D : 0x5D
                i += 1
                while i < b.count {
                    space(&i)
                    if i >= b.count { break }
                    if b[i] == close { i += 1; break }
                    if b[i] == 0x2C || b[i] == 0x3A { i += 1; continue }
                    value(&i)
                }
            default:
                while i < b.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
            }
        }
        var top: [Range<String.Index>] = []
        var i = 0
        space(&i)
        if i < b.count, b[i] == 0xEF { i += 3 }                           // a byte order mark
        space(&i)
        guard i < b.count, b[i] == 0x7B else { return ([], 0, nil) }
        let open = at(i)
        i += 1
        while i < b.count {
            space(&i)
            if i >= b.count || b[i] == 0x7D { break }
            if b[i] == 0x2C { i += 1; continue }
            guard b[i] == 0x22 else { break }
            let name = string(&i)
            if name == k { anywhere += 1 }
            space(&i)
            guard i < b.count, b[i] == 0x3A else { break }
            i += 1
            space(&i)
            let start = i
            value(&i)
            var end = i
            while end > start, [0x20, 0x09, 0x0A, 0x0D].contains(b[end - 1]) { end -= 1 }
            if name == k { top.append(at(start)..<at(end)) }
        }
        return (top, anywhere, open)
    }

    /// The choices of Keep for: Claude Code's default, 90 days, a year.
    static let choices: [(days: Int, words: String)] = [(30, "30 days (Claude Code's default)"), (90, "90 days"), (365, "A year")]

    static func words(_ days: Int?) -> String {
        guard let days else { return "unknown" }
        return choices.first { $0.days == days }?.words ?? (days == 1 ? "1 day" : "\(days) days")
    }
}
