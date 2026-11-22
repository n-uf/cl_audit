// SessionsBackup: a quick copy of a profile's sessions, on this Mac. One is made by every switch that moves the sessions
// (SwitchEngine.run, right after the window is known closed and before anything moves; kind beforeSwitch, with its receipt
// in records/receipt.json), by Back up now (Settings ▸ a profile ▸ Sessions) and by the default-profile move. They are
// listed there, kept as General ▸ Backups says, and restorable.
//
// A backup is a folder <backups place>/<profile id>/<backup id>/ with a backup.json that says what is in it:
//   window/<account>/<org>/…     the Claude window's Code-tab list: every claude-code-sessions/<account>/<org> folder
//                                (the entries and scheduled-tasks.json), for every account that has one
//   sidebar/epitaxyPrefs.json    the window's sidebar records: only the `sidebarAllowlist` keys of the epitaxyPrefs part of
//                                claude_desktop_config.json (its sections and groups; never a folder permission mode)
//   config/claude_desktop_config.json   that file's MCP servers (format 3): only its `configAllowlist` keys, nothing else of it
//                                (permission and consent settings, this Mac's paths). It can hold tokens no scan recognises (env values, headers, arguments), so a plain
//                                backup (a switch's, Back up now) NEVER keeps it: only the hidden copy an export is made from does
//                                (the encrypted disk image carries it, a zip leaves it out), and so the backup an import of that image
//                                stages. Import adds it only when asked, only where the profile has none (SessionsRestoreWindow.swift)
//   setup/settings.json          in a plain backup, with every `env` value blanked (names kept), written from the parsed object
//                                (`envBlanked`); one that isn't a JSON object is left out with its scripts. Env values travel only in
//                                the encrypted export. Backups made by 26.11.8 stay as they are. Then the Export page's key scan
//                                (SecretScan) runs over the rest: a hook entry or a permission rule that matches is dropped
//                                (`secretHooksDropped`, `secretRulesDropped`), any other string value that matches is blanked
//                                (`secretBlanked`: dotted paths, never a value; Setup.secretsBlanked says why a hook is never blanked),
//                                and a hook script, a unit that holds one, or plugins/known_marketplaces.json whose bytes match (also
//                                decoded, for a UTF-16 file) is left out (`secretLeftOut`). Scripts are scanned as the copies that
//                                landed in the backup; settings.json as the object that is written.
//   setup/scheduled-tasks/<id>/SKILL.md   a scheduled task's prompt (with the setup's files, but it goes with its task)
//   records/…                    cl_audit's own: the profile's entry, and the receipt of the switch it was made for
//   transcripts/<project>/…      Claude Code's transcripts (<Claude Code folder>/projects), optional
//
// Never in a backup: a sign-in. No .claude.json, nothing named like credentials, no Keychain access at all, and nothing
// outside those paths. Files are copied as APFS clones (fclonefileat, with fcopyfile as the fallback), which share space with the
// originals and take seconds; on another volume that can't be, so the file is copied for real, and the size words say so.
// A source file is never changed, and a backup is a new folder: it is built under a hidden name and renamed into place
// only when whole, never over an existing one.

import Foundation
import ProfileCore

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
        enum Role: String, Codable { case window, sidebar, record, transcript, setup, config }
        var role: Role
        var original: String
        var path: String
        var bytes: Int64
        var part: String? = nil             // sidebar: the part of the original that was taken
        var sha: String? = nil              // setup: the file's SHA-256 (hex)
        var exec: Bool? = nil               // setup: the owner-execute bit it had
    }

    /// The format of backup.json (and of an export's export.json). 2 added `setup` items (Claude Code's CLAUDE.md, skills, agents …);
    /// 3 added the `config` item (the Claude window's claude_desktop_config.json, its `configAllowlist` keys only) and scheduled tasks' prompts
    /// (setup/scheduled-tasks/<id>/SKILL.md). 4 added cl_audit's own profiles and settings (an export's cl_audit.json, SessionsMove.swift)
    /// and the move: a part whose window folders are the real account and organisation ids (`move`), only ever in an encrypted image.
    /// 5 added a move's code checklist (an export's code.json, CodeChecklist.swift): only an export.json says 5, and only when it holds
    /// one; a backup.json stays at 4 at most.
    /// 6 added a move's side files (an export's side.json and side/, SessionsSide.swift: task lists, plans, prompt history, trust, Rewind):
    /// only an export.json says 6, and only when it holds them.
    /// Files of version 1 to 5 are read as before (they have none); a newer one is refused.
    /// (26.11.7 reads only version 1, 26.11.8 up to 2, 26.11.9 up to 3, 26.11.10 and 26.11.11 up to 4, 26.11.12 up to 5: each refuses a
    /// newer file with its "newer cl_audit" words.)
    static let formatVersion = 6
    /// The highest a backup.json is written in and read up to (a backup, an export's part): 4. Only an export.json goes to 5 or 6.
    static let backupVersion = 4

    /// The window's own folders inside an account folder that a backup takes the plain files of (one level, never a link): the
    /// Code-tab backlog (backlog/tasks.json) and the waiting input. A restore puts each file back only where none is.
    /// They are kept apart, under window-extra/<account>/<org>/<folder>/<file> and listed in the manifest's `windowExtra`, not in
    /// `items`: a reader that doesn't know them (26.11.43 and earlier) ignores the key and the folder and restores the rest, so
    /// the format stays as it was. Only this Mac's backups hold them; an export never does.
    static let windowFolders = ["backlog", "waiting-input"]
    static let extraRoot = "window-extra"

    /// Whether a backup path is a file of one of the window's own folders: window-extra/<account>/<org>/<folder>/<file>.
    static func isFolderFile(_ c: [String]) -> Bool { c.count == 5 && c[0] == extraRoot && windowFolders.contains(c[3]) }

    /// The lowest format that holds these items, which is what a backup and an export write: 4 for a move's part, 3 only when a format-3
    /// part is in it (the window's config, a scheduled task's prompt), else 2, so 26.11.8 still imports a plain zip from this build.
    /// (formatVersion stays the highest written: what this build reads up to.)
    static func neededVersion(_ items: [Item], move: Bool = false) -> Int {
        if move { return 4 }
        return items.contains { $0.role == .config || ($0.role == .setup && $0.path.hasPrefix("setup/\(Setup.taskFolder)/")) } ? 3 : 2
    }

    struct Counts: Codable, Equatable {
        var sessions = 0                    // entries in the window's Code-tab list
        var sidebar = 0                     // of them, those in the sidebar (not archived)
        var tasks = 0                       // scheduled tasks
        var transcripts = 0                 // Claude Code's session transcripts
    }

    struct Manifest: Codable, Equatable, Identifiable {
        var version = SessionsBackup.backupVersion
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
        /// The window's own folders' files (`windowFolders`: the Code-tab backlog, the waiting input), at window-extra/…: apart from
        /// `items`, so an older reader ignores them and restores the rest. nil: none (or a backup from before they were taken).
        var windowExtra: [Item]? = nil
        /// Setup (CLAUDE.md, skills …) left out because it is a link: names only, never where it pointed.
        var setupLeftOut: [String]? = nil
        /// The setup units ("skill:guard") that hold a file settings.json's hooks or status line run, learned from the live settings.json
        /// when the backup was made (also a linked one, which isn't carried): names only. An export from this backup leaves them out
        /// of a zip. nil: not known (settings.json couldn't be read, or an older backup): a zip then leaves out every unit that holds a
        /// file with the execute bit.
        var setupHookUnits: [String]? = nil
        /// Why the window's claude_desktop_config.json isn't in it although the window was ("over 8 MB", "a link", "not a JSON object",
        /// "needs the encrypted disk image" in a zip): words for the pages. nil: it is in, or there was none.
        var configLeftOut: String? = nil
        /// settings.json in it has every `env` value blanked (keys kept): a plain backup's (this version on). nil: as it was (an
        /// export's copy, an import's staged backup, a backup made by 26.11.8).
        var envBlanked: Bool? = nil
        /// Where a plain backup's settings.json had a value the Export page's key scan matches (dotted paths such as
        /// "permissions.allow[2]": names only, never a value): each is blank in the backup, its key kept. nil: none (or not a plain backup).
        var secretBlanked: [String]? = nil
        /// Setup a plain backup left out because it held a key (a script a hook runs, the plugin marketplaces, a skill that holds such a
        /// script), by name as the pages call it ("script hooks/x.sh"). Like `secretBlanked`, those travel only in an encrypted export.
        var secretLeftOut: [String]? = nil
        /// Hook entries of settings.json a plain backup dropped whole because one of their values held a key ("PreToolUse (Bash)": the
        /// event and the matcher, names only). A hook is never blanked: an empty http url makes Claude Code ignore the whole file.
        var secretHooksDropped: [String]? = nil
        /// Permission rules ("permissions.deny[1]") a plain backup dropped because they held a key.
        var secretRulesDropped: [String]? = nil
        /// A move's part (format 4): its window folders are named by the real account and organisation ids, not fingerprints, so an
        /// import puts each entry and task file back into its own account's folder. Only ever from an encrypted image. nil: not a move.
        var move: Bool? = nil
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

    /// A backup's name: the second it is for and 4 random hex characters. Never one this run of cl_audit gave before (`Issued`),
    /// so two backups of one profile in one second never share a name, also when the caller writes the name down before the
    /// backup is made (a switch's receipt). The form stays the one `validID` reads: older backups list, sort and age out as before.
    static func newID(_ d: Date = Date()) -> String {
        #if CL_AUDIT_TESTING
        if !nextIDs.isEmpty { return nextIDs.removeFirst() }
        #endif
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: d)
        while true {
            let id = "\(stamp)-\(randomHex())"
            if Issued.take(id) { return id }
        }
    }

    private static func randomHex() -> String {
        #if CL_AUDIT_TESTING
        if let n = hexPool { return String(format: "%04x", Int.random(in: 0..<max(1, n))) }
        #endif
        return UUID().uuidString.prefix(4).lowercased()
    }

    /// The names newID gave in this run: the last `cap` of them (a clash needs the same second, so older ones don't matter).
    private enum Issued {
        private static let lock = NSLock()
        private static var taken = Set<String>()
        private static var order: [String] = []
        private static let cap = 4096
        /// True when `id` wasn't given before; it counts as given from now on.
        static func take(_ id: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard taken.insert(id).inserted else { return false }
            order.append(id)
            if order.count > cap { taken.remove(order.removeFirst()) }
            return true
        }
    }

    #if CL_AUDIT_TESTING
    /// A check's seam: newID returns these first, whatever it gave before (as another process, or an earlier run, would). Only a
    /// test build (compiled with -D CL_AUDIT_TESTING) has it.
    nonisolated(unsafe) static var nextIDs: [String] = []
    /// A check's seam: newID's random part is drawn from this many values (0000, 0001 …), so its draws repeat often, as 4 hex
    /// characters do over many backups (0 or less counts as 1). Keep it above the number of names a check asks for in one
    /// second: once every value of that second is taken, newID looks for a free one for ever.
    nonisolated(unsafe) static var hexPool: Int? = nil
    #endif

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
        var exec = false                    // setup: the owner-execute bit
    }

    private struct Gathered {
        var files: [Planned] = []
        var setupLeftOut: [String] = []
        var setupHookUnits: [String]? = nil
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
    private static func gather(_ s: Source, window: Bool, transcripts: Bool, setup: Bool = false) -> Gathered {
        var g = Gathered()
        if setup {
            // Claude Code's setup (CLAUDE.md, skills, agents, commands …): links never followed, left out by name. The scheduled tasks'
            // prompts go with the window's task files: only when those are taken too
            let f = Setup.scan(codeDir: s.codeDir)
            for r in f.files where window || r.unit.kind != .task {
                g.files.append(Planned(role: .setup, src: r.src, rel: "setup/" + r.rel, original: r.src, bytes: r.bytes, exec: r.exec))
                g.bytes += r.bytes
            }
            // by name and the reason, never where a link pointed: "agent linked.md (a link)", "skills/big (too many files, or folders nested too deep: left out whole)"
            g.setupLeftOut = (f.linked.map { $0.label.contains("(") ? $0.label : $0.label + " (a link)" } + f.leftOutNames.filter { $0.hasSuffix("left out whole)") || $0 == Setup.settingsTooBig }).sorted()
            g.setupHookUnits = f.hookUnits.map { $0.map(Setup.key).sorted() }
        } else if window {
            // setup left out (an export without it): the scheduled tasks' prompts still go with their tasks
            for r in Setup.scan(codeDir: s.codeDir).files where r.unit.kind == .task {
                g.files.append(Planned(role: .setup, src: r.src, rel: "setup/" + r.rel, original: r.src, bytes: r.bytes, exec: false))
                g.bytes += r.bytes
            }
        }
        if window, !s.dataDir.isEmpty {
            var seen = Set<SeatID>()
            // the account/organisation folders by ClaudeFiles' one lister (real folders named like ids, never a link); every
            // plain file in each is taken, the sessions counted by its entry rule
            for scope in ClaudeFiles.sessionScopes(dataDir: s.dataDir) {
                let (account, org, odir) = (scope.account, scope.organization, scope.path)
                seen.insert(SeatID(account: account, organization: org))
                for name in names(odir) {
                    let path = (odir as NSString).appendingPathComponent(name)
                    guard let m = mode(path), m.kind == S_IFREG else { continue }
                    if skipped(name) || m.links > 1 { g.leftOut += 1; continue }       // (a hard link: never taken, nor counted)
                    g.files.append(Planned(role: .window, src: path, rel: "window/\(account)/\(org)/\(name)", original: path, bytes: m.size))
                    g.bytes += m.size
                    if ClaudeFiles.isEntryName(name) {
                        g.counts.sessions += 1
                        let d = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
                        if !SidebarPlan.flag("isArchived", in: d) { g.counts.sidebar += 1 }
                    } else if name == "scheduled-tasks.json",
                              let d = FileManager.default.contents(atPath: path),
                              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        g.counts.tasks += (j["scheduledTasks"] as? [Any])?.count ?? 0
                    }
                }
                // the window's own folders (the Code-tab backlog, the waiting input): a real folder only, its plain files, one level
                for sub in windowFolders {
                    let sdir = (odir as NSString).appendingPathComponent(sub)
                    guard mode(sdir)?.kind == S_IFDIR else { continue }
                    for name in names(sdir) {
                        let path = (sdir as NSString).appendingPathComponent(name)
                        guard let m = mode(path), m.kind == S_IFREG else { continue }
                        // (over a window file's own cap, 64 MB, it isn't one of the window's: never taken, counted)
                        if skipped(name) || m.links > 1 || m.size > 64 << 20 { g.leftOut += 1; continue }
                        g.files.append(Planned(role: .window, src: path, rel: "\(extraRoot)/\(account)/\(org)/\(sub)/\(name)", original: path, bytes: m.size))
                        g.bytes += m.size
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
                    // (every file of the tree is taken: a session's own folder with its archive record archived.json, and a
                    // project's connector-downloads/, go with it; a restore writes each one back only where it is missing)
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
    /// can't be made whole. Takes no lock: Back up now takes it (`manual`), as does the default-profile move.
    /// A plain backup (Back up now, the default-profile move's; a switch's from 26.11.13 and earlier) keeps no claude_desktop_config.json and keeps settings.json
    /// with every `env` value blanked (`envBlanked`), a hook entry or permission rule the key scan matches dropped, every other value it
    /// matches blanked too (`secretBlanked`; Setup.secretsBlanked), and leaves
    /// out a hook script, a unit holding one, or the plugin marketplaces that hold a key (`secretLeftOut`): those travel only in the
    /// encrypted export. `forExport`: the hidden copy an export
    /// is made from (and taken away again), which keeps both whole for the image (a zip leaves them out).
    /// `id`: the name a caller wrote down first (a switch's receipt names it): refused when a backup, or one being made, has it.
    /// nil: make picks it for `now` (the name's time is the manifest's `created`), and picks another while the name is taken (by
    /// another process, or an earlier run, in the same second); the name used is the returned manifest's `id`.
    @discardableResult
    static func make(_ s: Source, id given: String? = nil, kind: Kind, window: Bool = true, transcripts: Bool = true, setup: Bool = true,
                     receipt: SwitchReceipt? = nil, place: URL, now: Date = Date(), forExport: Bool = false) throws -> Manifest {
        guard validProfile(s.profile), given.map(validID) ?? true else { throw BackupError("the profile or backup name isn't a plain one") }
        if let why = placeProblem(place, for: [s]) { throw BackupError(why) }
        let started = Date()
        let fm = FileManager.default
        let profileDir = folder(profile: s.profile, place: place)
        do {
            try fm.createDirectory(at: profileDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw BackupError("the backups folder \(tilde(place.path)) can't be written") }
        let tries = given == nil ? 8 : 1
        var id = "", final = profileDir, partial = profileDir
        for attempt in 1...tries {
            id = given ?? newID(now)
            final = profileDir.appendingPathComponent(id)
            partial = profileDir.appendingPathComponent(".\(id).partial")
            if fm.fileExists(atPath: final.path) {
                if given != nil { throw BackupError("a backup with that name is there already") }
            } else if mkdir(partial.path, 0o700) == 0 {
                break
            } else if errno != EEXIST {
                throw BackupError("couldn't start a backup in \(tilde(place.path))")
            }
            if attempt == tries { throw BackupError("couldn't start a backup in \(tilde(place.path))") }
        }
        var done = false
        defer { if !done { try? fm.removeItem(at: partial) } }

        let g = gather(s, window: window, transcripts: transcripts, setup: setup)
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
        // settings.json in a plain backup: its env values blanked (keys kept), written from the parsed object; one that can't be
        // parsed is left out with the scripts its hooks run (an export of the backup must not carry scripts without it)
        var setupLeftOut = g.setupLeftOut
        var envBlanked: Bool? = nil
        var secretBlanked: [String]? = nil
        var secretHooksDropped: [String]? = nil, secretRulesDropped: [String]? = nil
        var dropScripts = false
        if !forExport, let sf = g.files.first(where: { $0.role == .setup && $0.rel == "setup/settings.json" }) {
            // (env values blanked, then every other string value the Export page's key scan matches)
            if let d = SafeFiles.readPlain(sf.src, max: Setup.maxSettingsBytes), let blank = Setup.secretsBlanked(d) {
                try put(blank.data, "setup/settings.json", in: partial, dirFor)
                items.append(Item(role: .setup, original: sf.original, path: sf.rel, bytes: Int64(blank.data.count), sha: SwitchEngine.sha(blank.data), exec: false))
                envBlanked = true
                secretBlanked = blank.keys.isEmpty ? nil : blank.keys
                secretHooksDropped = blank.hooks.isEmpty ? nil : blank.hooks
                secretRulesDropped = blank.rules.isEmpty ? nil : blank.rules
            } else {
                setupLeftOut.append(Setup.settingsUnreadable); dropScripts = true; leftOut += 1
            }
        }
        var landedShared: [String: (shared: Bool, bytes: Int64)] = [:]       // setup files: cloned or copied (for taking one back out)
        for f in g.files {
            if !forExport, f.role == .setup, f.rel == "setup/settings.json" { continue }        // (written above, blanked, or left out)
            if dropScripts, f.role == .setup, Setup.unit(of: String(f.rel.dropFirst(6))).kind == .script { leftOut += 1; continue }
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
            if f.role == .setup {
                landedShared[f.rel] = (shared, f.bytes)
                // the hash of what landed (what a restore checks it against), and the execute bit the original had
                var landedStat = stat()
                guard let h = Setup.sha(path: dst), lstat(dst, &landedStat) == 0 else { unlink(dst); leftOut += 1; continue }
                items.append(Item(role: .setup, original: f.original, path: f.rel, bytes: Int64(landedStat.st_size), sha: h, exec: f.exec))
            } else {
                items.append(Item(role: f.role, original: f.original, path: f.rel, bytes: f.bytes))
            }
        }

        // a plain backup: what held a key stays out. The key scan of the Export page runs over the copies that landed (never the originals:
        // what is scanned is what would be kept) of the scripts settings.json's hooks and status line run, of plugins/known_marketplaces.json,
        // and of every file of a skill, agent, command or output style that holds such a script (that unit is one: it goes whole or not at
        // all). A file that can't be read back counts as a match.
        var secretLeftOut: [String] = []
        if !forExport {
            let holders = Set((g.setupHookUnits ?? []).compactMap(Setup.unit(key:)))
            var held: [Setup.Unit: [String]] = [:]
            for it in items where it.role == .setup && it.path.hasPrefix("setup/") {
                let u = Setup.unit(of: String(it.path.dropFirst(6)))
                if u.kind == .script || u.kind == .marketplaces || holders.contains(u) { held[u, default: []].append(it.path) }
            }
            for (u, rels) in held.sorted(by: { $0.key < $1.key }) {
                let hit = rels.contains { rel in
                    guard let k = Setup.keysIn(path: (partial.path as NSString).appendingPathComponent(rel)) else { return true }
                    return !k.isEmpty
                }
                guard hit else { continue }
                for rel in rels {
                    let path = (partial.path as NSString).appendingPathComponent(rel)
                    unlink(path)
                    // (and the folders made for it, while they are empty: rmdir refuses a folder that holds anything)
                    var dir = (path as NSString).deletingLastPathComponent
                    while dir.count > partial.path.count, rmdir(dir) == 0 { made.remove(dir); dir = (dir as NSString).deletingLastPathComponent }
                    if let l = landedShared[rel] {
                        if l.shared { cloned -= 1 } else { copied -= 1; copiedBytes -= l.bytes }
                    }
                }
                let gone = Set(rels)
                items.removeAll { gone.contains($0.path) }
                leftOut += rels.count
                secretLeftOut.append(oneLine(SetupRow.title(u), max: 100))
            }
        }

        // the window's sidebar records: only epitaxyPrefs, by the sidebar allowlist
        if window, let data = sidebarRecords(dataDir: s.dataDir) {
            try put(data, "sidebar/epitaxyPrefs.json", in: partial, dirFor)
            items.append(Item(role: .sidebar, original: (s.dataDir as NSString).appendingPathComponent("claude_desktop_config.json"),
                              path: "sidebar/epitaxyPrefs.json", bytes: Int64(data.count), part: "preferences.epitaxyPrefs"))
        }
        // claude_desktop_config.json's MCP servers (its allowlisted keys, nothing else of it): only in the copy an export is made from
        // (the encrypted image carries it); a plain backup never keeps it
        var configLeftOut: String?
        if window, forExport {
            switch windowConfig(dataDir: s.dataDir) {
            case .none: break
            case .leftOut(let why): configLeftOut = why
            case .data(let data):
                try put(data, configPath, in: partial, dirFor)
                items.append(Item(role: .config, original: (s.dataDir as NSString).appendingPathComponent("claude_desktop_config.json"),
                                  path: configPath, bytes: Int64(data.count), part: configPart))
            }
        }
        // cl_audit's records: the profile (ids only, no address), and the receipt of the switch this is for
        if let e = s.entry {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? enc.encode(ProfileRecord(e)) {
                try put(data, "records/profile.json", in: partial, dirFor)
                items.append(Item(role: .record, original: Store.configURL.path, path: "records/profile.json", bytes: Int64(data.count), part: "accounts[id=\(e.id)]"))
            }
        }
        if let r = receipt, let data = try? SwitchEngine.store.encoded(r) {
            try put(data, "records/receipt.json", in: partial, dirFor)
            items.append(Item(role: .record, original: SwitchEngine.store.url(r.id).path,
                              path: "records/receipt.json", bytes: Int64(data.count)))
        }

        // the window's own folders' files go apart (windowExtra), where an older reader doesn't look
        let extra = items.filter { isFolderFile($0.path.split(separator: "/").map(String.init)) }
        let named = items.filter { !isFolderFile($0.path.split(separator: "/").map(String.init)) }
        let m = Manifest(id: id, profile: s.profile, kind: kind, created: now, seconds: 0, accounts: g.accounts, counts: g.counts,
                         window: window, transcripts: transcripts,
                         bytes: items.reduce(0) { $0 + $1.bytes }, cloned: cloned, copied: copied, copiedBytes: copiedBytes,
                         leftOut: leftOut, dataDir: s.dataDir, codeDir: s.codeDir, items: named, windowExtra: extra.isEmpty ? nil : extra,
                         setupLeftOut: setupLeftOut.isEmpty ? nil : setupLeftOut.sorted(), setupHookUnits: g.setupHookUnits, configLeftOut: configLeftOut,
                         envBlanked: envBlanked, secretBlanked: secretBlanked, secretLeftOut: secretLeftOut.isEmpty ? nil : secretLeftOut.sorted(),
                         secretHooksDropped: secretHooksDropped, secretRulesDropped: secretRulesDropped)
        var out = m
        out.version = neededVersion(named)
        out.seconds = (Date().timeIntervalSince(started) * 10).rounded() / 10
        try put(try encode(out), "backup.json", in: partial, dirFor)
        guard CreateOnly.rename(partial.path, to: final.path) else { throw BackupError("couldn't put the backup in place") }
        done = true
        return out
    }

    /// Back up now: under the switch lock (no switch and no claude-transplant run moves sessions meanwhile), then pruned.
    /// `window` true (the window was closed when it started): `windowClosed` is asked again once the backup is made, and
    /// if the window opened meanwhile the backup is taken away.
    static func manual(_ s: Source, window: Bool, transcripts: Bool = true, place: URL = BackupPrefs.placeURL,
                       keepLast: Int = BackupPrefs.keepLast, keepDays: Int = BackupPrefs.keepDays,
                       windowClosed: () -> Bool = { true }) throws -> Manifest {
        let lock: FlowLock.Held
        do { lock = try Flows.takeLock() } catch { throw BackupError("\(error)") }
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
            let out = CreateOnly.open(dst)
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

    /// The sidebar records of the window's claude_desktop_config.json (its `preferences.epitaxyPrefs`), as their own JSON: only the
    /// `sidebarAllowlist` keys of them, nothing else of that file.
    static func sidebarRecords(dataDir: String) -> Data? {
        guard !dataDir.isEmpty,
              let data = FileManager.default.contents(atPath: (dataDir as NSString).appendingPathComponent("claude_desktop_config.json")),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prefs = (j["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: sidebarAllowed(prefs), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// The ONLY keys of the window's sidebar records (`preferences.epitaxyPrefs`) that sidebar/epitaxyPrefs.json ever carries or a
    /// restore ever reads: the two the sidebar step uses (SidebarPlan.read: a scope's groups, their sessions and order, and its
    /// sections with their order and sort). DEFAULT DENY, as for `configAllowlist`: the rest of epitaxyPrefs (the folder permission
    /// modes, `epitaxy-folder-permission-mode-v2.<account>`, auto or bypassPermissions per folder; and any key a later Claude app adds)
    /// never goes into a backup or an export, and an older backup's or image's file that holds them is filtered again before any use
    /// (SessionsRestore.plan; SessionsExport for an image made from a backup).
    ///   dframe-group-scopes    per "<account>/<organisation>": the sidebar's groups (id, name, mode), which sessions sit in each
    ///                          and in what order. Ids and names only; the helper session's prompt carries them as data.
    ///   dframe-code-sections   per scope: the sidebar's sections (id, kind, order, sortBy, shown). Layout only.
    /// Neither grants a permission or holds a path of this Mac. (This Mac's own live file is read for its permission mode only by
    /// SidebarPlan.asksBeforeMoves, never from a backup.)
    static let sidebarAllowlist: Set<String> = ["dframe-code-sections", "dframe-group-scopes"]

    /// The sidebar records' `sidebarAllowlist` keys and nothing else.
    static func sidebarAllowed(_ prefs: [String: Any]) -> [String: Any] {
        prefs.filter { sidebarAllowlist.contains($0.key) }
    }

    /// A sidebar/epitaxyPrefs.json file's bytes with its allowlisted keys only (sorted, pretty); nil: not a JSON object.
    static func sidebarData(_ d: Data) -> Data? {
        guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: sidebarAllowed(j), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Where a backup keeps the window's claude_desktop_config.json (its allowlisted keys only), and the most the file may hold: a real
    /// one is a few KB, and an import refuses one bigger, so a backup (and an export) never takes one bigger either.
    static let configPath = "config/claude_desktop_config.json"
    static let maxConfigBytes = 8 << 20

    /// The ONLY top-level keys of the window's claude_desktop_config.json that ever travel. Decided here, and nowhere else: an export
    /// writes nothing else of the file (windowConfig, and SessionsExport for an image made from a backup), and a restore or an import
    /// writes nothing else of a backup's or an image's (SessionsRestoreWindow.planConfig: one made by 26.11.61 or earlier carried the
    /// whole file but its sidebar part, and is filtered again before anything is written). DEFAULT DENY: every key not named here, at
    /// the top level or under `preferences`, including any key a later Claude app adds, never moves.
    ///   mcpServers   what the person is offered as "the window's MCP settings": each server's command, arguments, env and headers.
    ///                Safe to carry because it is gated, not because it is harmless: it runs commands, so a restore or import adds
    ///                it only on "Add them" (which lists each server and the program it runs), only where the profile has no
    ///                claude_desktop_config.json, read under the 8 MB cap without following a link, and only from the encrypted
    ///                image. It holds no permission grant, consent, trusted folder or path of the window's own.
    /// Left out on purpose: `preferences` (permission opt-ins such as bypassPermissionsGateByAccount, trusted folders, device and
    /// network consents, this Mac's workspaces; its sidebar part, epitaxyPrefs, travels on its own as sidebar/epitaxyPrefs.json),
    /// `coworkUserFilesPath` and every other key (this Mac's paths and device state).
    static let configAllowlist: Set<String> = ["mcpServers"]
    /// The config item's `part` in a backup.json: what of the file it holds.
    static let configPart = configAllowlist.sorted().joined(separator: ", ")

    enum ConfigRead: Equatable { case none, leftOut(String), data(Data) }

    /// The window's claude_desktop_config.json as a backup takes it: its allowlisted keys only (`allowlisted`). Read without following
    /// a link and under the cap; `.none`: there is none, or it holds nothing on the allowlist; `.leftOut`: why it isn't taken.
    static func windowConfig(dataDir: String) -> ConfigRead {
        guard !dataDir.isEmpty else { return .none }
        let path = (dataDir as NSString).appendingPathComponent("claude_desktop_config.json")
        var st = stat()
        guard lstat(path, &st) == 0 else { return .none }
        if (st.st_mode & S_IFMT) == S_IFLNK { return .leftOut("it is a link") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .leftOut("it isn't a plain file") }
        guard st.st_size <= maxConfigBytes else { return .leftOut("it is over 8 MB") }
        guard let d = SafeFiles.readPlain(path, max: maxConfigBytes) else { return .leftOut("it can't be read") }
        guard let j = allowlisted(d) else { return .leftOut("it isn't a JSON object") }
        if j.isEmpty { return .none }
        guard let out = configData(j) else { return .leftOut("it can't be read") }
        return .data(out)
    }

    /// The config's `configAllowlist` keys and nothing else, each only as a non-empty JSON object (an empty or malformed one
    /// carries nothing); nil: not a JSON object. Every write of the window's config, export side and restore side, goes through it.
    static func allowlisted(_ d: Data) -> [String: Any]? {
        guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        for k in configAllowlist { if let v = j[k] as? [String: Any], !v.isEmpty { out[k] = v } }
        return out
    }

    /// The allowlisted object as the file is written (sorted keys, pretty).
    static func configData(_ j: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// One MCP server as the Import and Restore pages list it: what "Add them" is asking the person to trust.
    struct MCPServer: Equatable {
        var name: String
        var runs: String                    // its command line, one line, cut to `runsWidth` (… at the end); or "a remote server (…)"
        var full: String = ""               // the whole command line, one line (the line's tooltip), cut at 4000 characters with …
        var env: [String] = []              // the names of the environment variables it sets, sorted: never a value
        var flags: [String] = []            // why it needs a look first: a shell, interpreter or launcher, a loader variable, a hidden key
    }
    static let runsWidth = 120

    /// Programs that run whatever their arguments say (a shell, an interpreter, a launcher that runs another program or package): a
    /// server that is one is flagged. Lowercase: the disk is case-insensitive, so /bin/SH and Python3 are the same programs.
    static let interpreters: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "csh", "tcsh", "env", "xargs", "nohup", "sudo",
                                            "exec", "eval", "open", "osascript", "node", "nodejs", "deno", "bun", "bunx", "ruby", "irb", "perl", "php",
                                            "lua", "tclsh", "wish", "pwsh", "powershell", "rscript", "java", "swift", "python", "pythonw",
                                            "npx", "npm", "pnpm", "yarn", "uv", "uvx", "pipx", "docker", "arch", "caffeinate", "nice", "time",
                                            "timeout", "command", "xcrun", "script", "stdbuf", "setsid"]
    /// The options `env` has (2026-11): this Mac's (BSD: -0 -i -v, -C -P -S -u with a value) and GNU coreutils' (-0 -i -v, -a -C
    /// -S -u with a value; the long names below). An option outside these ends what can be read of an `env` command line.
    enum EnvValue { case none, required, optional }
    static let envLongOptions: [(name: String, value: EnvValue)] = [
        ("--ignore-environment", .none), ("--null", .none), ("--unset", .required), ("--chdir", .required), ("--split-string", .required),
        ("--debug", .none), ("--argv0", .required), ("--block-signal", .optional), ("--default-signal", .optional),
        ("--ignore-signal", .optional), ("--list-signal-handling", .none), ("--help", .none), ("--version", .none)]
    static let envOperandOptions: Set<Character> = ["S", "u", "C", "P", "a"]
    static let envShortOptions: Set<Character> = envOperandOptions.union(["0", "i", "v"])
    static let envUnreadFlag = "env has an option cl_audit doesn't know: the rest of its command line is hidden (\"…\"), so it couldn't be read in full"
    /// A command word as a program's name: surrounding quotes off, its last path part, lowercased.
    static func programName(_ word: String) -> String {
        var w = Substring(word)
        while let f = w.first, let l = w.last, w.count >= 2, f == l, f == "\"" || f == "'" { w = w.dropFirst().dropLast() }
        return (String(w) as NSString).lastPathComponent.lowercased()
    }
    static func isInterpreter(_ program: String) -> Bool {
        let base = programName(program)
        return interpreters.contains(base) || ["python", "ruby", "perl", "node"].contains { base.hasPrefix($0) }
    }
    /// Environment variables that change what a program loads or runs before its own code: a server that sets one is flagged.
    static func isLoaderVariable(_ name: String) -> Bool {
        name.hasPrefix("DYLD_") || name.hasPrefix("LD_") || ["NODE_OPTIONS", "NODE_PATH", "ELECTRON_RUN_AS_NODE", "PYTHONPATH", "PYTHONSTARTUP",
            "PYTHONHOME", "PYTHONINSPECT", "PYTHONUSERBASE", "PERL5LIB", "PERL5OPT", "PERLLIB", "RUBYOPT", "RUBYLIB", "BASH_ENV", "ENV", "ZDOTDIR",
            "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "CLASSPATH", "GEM_PATH", "GEM_HOME", "PROMPT_COMMAND", "GIT_SSH_COMMAND",
            "NODE_EXTRA_CA_CERTS"].contains(name) || name.hasPrefix("BASH_FUNC_")
    }

    /// An argument with each key the scan recognises in it as ‹a key›, the rest as it is (a key sits in a run of letters, digits,
    /// "_", "-" and "."; a key the runs can't isolate hides the whole argument). `hit`: something was hidden.
    static func maskKeys(_ w: String) -> (text: String, hit: Bool) {
        guard !SecretScan.scan(Data(w.utf8)).isEmpty else { return (w, false) }
        var out = "", run = "", hit = false
        func flush() {
            guard !run.isEmpty else { return }
            if SecretScan.scan(Data(run.utf8)).isEmpty { out += run } else { out += "‹a key›"; hit = true }
            run = ""
        }
        for c in w {
            if c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-" || c == ".") { run.append(c) } else { flush(); out.append(c) }
        }
        flush()
        // a key the runs split (one with "+" or "/" in it) can leave part of it showing: if the result still holds one, hide it all
        guard hit, SecretScan.scan(Data(out.utf8)).isEmpty else { return ("‹a key›", true) }
        return (out, true)
    }

    /// The MCP servers a config names, by name, with what each runs: its whole command line (the command and its arguments, each in
    /// full, but for the NAME=value words before the program, or after an `env` program up to the program it runs, which set the
    /// environment and show as NAME=…, and a key the scan recognises inside an argument, ‹a key›), the names of the environment variables it sets (never a value), and a flag for a shell, interpreter
    /// or launcher, a loader variable or a hidden key; or "a remote server" for one reached by URL (the URL and headers can hold a token).
    static func mcpServers(_ d: Data) -> [MCPServer] {
        guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let s = j["mcpServers"] as? [String: Any] else { return [] }
        /// NAME=value: an environment assignment (its value never shown).
        func assignment(_ w: String) -> String? {
            guard let eq = w.firstIndex(of: "="), eq != w.startIndex else { return nil }
            let n = w[..<eq]
            guard n.first.map({ !$0.isNumber }) == true, n.allSatisfy({ $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }) else { return nil }
            return String(n)
        }
        /// Any word with "=" after its first character, as `env` reads one (any name, quoted or odd): NAME=… (never its value).
        func assignmentMasked(_ w: String) -> String? {
            guard let eq = w.firstIndex(of: "="), eq != w.startIndex else { return nil }
            return String(w[..<eq]) + "=…"
        }
        return s.keys.sorted().map { name in
            let o = s[name] as? [String: Any]
            var env = Set(((o?["env"] as? [String: Any]) ?? [:]).keys.map { oneLine($0, max: 60) })
            // the command string's words (it may hold its own arguments), then `args`; control characters read as spaces
            let flat: (String) -> String = { String($0.map { $0.isNewline || $0 == "\t" ? " " : $0 }) }
            // split on spaces outside quotes, so A="x y" stays one word (its quotes kept) and is masked whole; a backslash keeps the
            // next character in the word (an escaped quote or space), as a shell reads it, but inside '…'
            let commandWords: [String] = {
                var out: [String] = [], cur = "", quote: Character? = nil, escaped = false
                for c in flat((o?["command"] as? String) ?? "") {
                    if escaped { cur.append(c); escaped = false }
                    else if c == "\\", quote != "'" { cur.append(c); escaped = true }
                    else if let q = quote { cur.append(c); if c == q { quote = nil } }
                    else if c == "\"" || c == "'" { quote = c; cur.append(c) }
                    else if c == " " { if !cur.isEmpty { out.append(cur); cur = "" } }
                    else { cur.append(c) }
                }
                if !cur.isEmpty { out.append(cur) }
                return out
            }()
            let argWords = ((o?["args"] as? [Any]) ?? []).map { a -> String in
                if let s = a as? String { return flat(s) }
                if let n = a as? NSNumber { return n.stringValue }
                return "…"
            }
            let words = commandWords + argWords
            var shown: [String] = []
            // only the command string's leading NAME=value words set the environment ("API_KEY=… npx …"): name shown, value never
            var i = 0
            while i < commandWords.count, let n = assignment(words[i]) { env.insert(oneLine(n, max: 60)); shown.append(n + "=…"); i += 1 }
            let program: String? = commandWords.isEmpty || i >= words.count ? nil : words[i]
            // every other word in full (an `env` program's own NAME=value arguments too, counted by name), but a key the scan recognises
            var keyHidden = false, envArgs = program.map { programName($0) == "env" } ?? false, splitNext = false, operandNext = false
            var unread = false                  // an `env` option it doesn't know: everything after it shows as one "…"
            for (k, w) in words.enumerated().dropFirst(i) {
                // the operand of an `env` option that takes one (-u NAME, -C dir, -P path): as it is, not the program
                if operandNext {
                    operandNext = false
                    let (m, hit) = maskKeys(w)
                    if hit { keyHidden = true }
                    shown.append(m); continue
                }
                // an `env` program's own words up to the program it runs: its options as they are, and every word with "=" (an
                // assignment, whatever its name) as NAME=…. A -S/--split-string string is a command line of its own (assignments,
                // options, quotes): it is never shown, only `-S "…"` (the env flag already says to look at what it runs)
                if k > i, envArgs {
                    if splitNext { splitNext = false; shown.append("\"…\""); continue }
                    // "--" ends env's options: as it is (masking goes on)
                    if w == "--" { shown.append(w); continue }
                    if w.hasPrefix("--") {
                        // a long option, or any prefix of one that getopt would take (--unse, --split): by its name before "="
                        let name = w.split(separator: "=", maxSplits: 1).first.map(String.init) ?? w
                        let hits = name.count >= 3 ? envLongOptions.filter { $0.name.hasPrefix(name) } : []
                        // the one it names (an exact name wins); none, or a prefix of two (getopt refuses it), is unknown
                        guard let opt = hits.first(where: { $0.name == name }) ?? (hits.count == 1 ? hits[0] : nil),
                              name == w || opt.value != .none else {
                            unread = true; shown.append(maskKeys(name).0 + (name == w ? "" : "=…"))
                            if k < words.count - 1 { shown.append("…") }
                            break
                        }
                        if opt.name == "--split-string" {
                            if name == w { splitNext = true; shown.append(w) } else { shown.append(name + "=…") }
                            continue
                        }
                        if name == w, opt.value == .required { operandNext = true }
                        shown.append(assignmentMasked(w) ?? w); continue
                    }
                    // a bare "-" is env's old spelling of -i: an option like the rest (masking goes on)
                    if w == "-" { shown.append(w); continue }
                    if w.hasPrefix("-"), w.count > 1 {
                        // a cluster of short options, read left to right: the first that takes a value (S its string; u, C, P, a
                        // a name or path) takes the rest of the word, or the next word when nothing is left. A letter env
                        // doesn't have, before that, is unknown
                        let opts = w.dropFirst()
                        if let bad = opts.firstIndex(where: { !envShortOptions.contains($0) }),
                           opts[..<bad].allSatisfy({ !envOperandOptions.contains($0) }) {
                            unread = true; shown.append("-" + opts[...bad] + (opts.index(after: bad) == opts.endIndex ? "" : "…"))
                            if k < words.count - 1 { shown.append("…") }
                            break
                        }
                        if let o = opts.firstIndex(where: { envOperandOptions.contains($0) }) {
                            let rest = opts[opts.index(after: o)...]
                            if opts[o] == "S" {
                                if rest.isEmpty { splitNext = true; shown.append(w) } else { shown.append("-" + opts[..<o] + "S…") }
                            } else if rest.isEmpty { operandNext = true; shown.append(w) }
                            else {
                                let (m, hit) = maskKeys(w)
                                if hit { keyHidden = true }
                                shown.append(m)
                            }
                            continue
                        }
                        shown.append(w); continue
                    }
                    if let m = assignmentMasked(w) {
                        if let n = assignment(w) { env.insert(oneLine(n, max: 60)) }
                        shown.append(m); continue
                    }
                    envArgs = false
                }
                let (masked, hit) = maskKeys(w)
                if hit { keyHidden = true }
                // quoted when the argument itself holds a space (not for the space in ‹a key›)
                shown.append(w.contains(" ") || w.isEmpty ? "\"" + masked + "\"" : masked)
            }
            var flags: [String] = []
            if let p = program, isInterpreter(p) { flags.append("runs \(oneLine(programName(p), max: 40)), a shell, interpreter or launcher: its arguments are what it runs") }
            let loaders = env.filter(isLoaderVariable).sorted()
            if !loaders.isEmpty { flags.append("sets \(loaders.prefix(3).joined(separator: ", "))\(loaders.count > 3 ? ", …" : ""), which \(loaders.count == 1 ? "changes" : "change") what a program loads") }
            if keyHidden { flags.append("an argument looks like a key (shown as ‹a key›): check where it came from") }
            if unread { flags.append(envUnreadFlag) }
            let whole = oneLine(shown.joined(separator: " "), max: 4001)
            let full = whole.count > 4000 ? String(whole.prefix(3999)) + "…" : whole
            let runs: String
            if program != nil { runs = full.count > runsWidth ? String(full.prefix(runsWidth - 1)) + "…" : full }
            else { runs = o?["url"] != nil ? "a remote server (its address isn't shown)" : "nothing it names" }
            return MCPServer(name: oneLine(name, max: 100), runs: runs, full: program != nil ? full : runs, env: env.sorted(), flags: flags)
        }
    }

    /// Text from a file shown on a page as one plain line: no control characters (a newline would fake another line), no bidi or
    /// direction marks (they would turn a line around), no line or paragraph separators; cut to `max` characters.
    static func oneLine(_ s: String, max: Int) -> String {
        // (also zero-width characters and tag characters: they show nothing and only pad or disguise a name)
        let bidi: Set<UInt32> = [0x061C, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2060, 0x2066, 0x2067, 0x2068, 0x2069, 0x2028, 0x2029, 0xFEFF]
        let kept = s.unicodeScalars.filter { u in !(u.value < 32 || (0x7F...0x9F).contains(u.value) || bidi.contains(u.value) || (0xE0000...0xE007F).contains(u.value)) }
        return String(String.UnicodeScalarView(kept.prefix(max)))
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
            let file = SwitchEngine.store.url(n).path
            guard mode(file) != nil else { continue }
            guard let r = SwitchEngine.store.load(n) else { unreadable.insert(n); continue }
            if r.profile == profile, r.unfinished, let b = r.backup, r.backupPlace.map({ FolderKey.canonical($0) == here }) ?? true { ids.insert(b) }
        }
        // a restore that stopped half way finishes from its backup
        for r in SessionsRestore.unfinished(profile: profile) where FolderKey.canonical(r.backupPlace) == here { ids.insert(r.backup) }
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
        catch { throw BackupError("The backup couldn't be deleted (\(PlainWords.why(error))).") }
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

    /// A window file the backup keeps beside the entries that is the window's own (its task list, its archive index, a
    /// deleted_ marker): not an "other file".
    static func windowOwn(_ name: String) -> Bool {
        ClaudeFiles.isEntryName(name) || name == "scheduled-tasks.json" || name == "archived-sessions.idx" || name.hasPrefix("deleted_")
    }

    /// The window files a backup holds that are neither entries nor the window's own: copied with the rest (the backup
    /// is the safety copy), never counted as sessions, and said ("· 2 other files").
    static func otherFiles(_ m: Manifest) -> Int {
        m.items.filter { $0.role == .window && !windowOwn(($0.path as NSString).lastPathComponent) }.count
    }

    /// "84 sessions · 2 other files · 12 tasks · sidebar · transcripts · 5.5 GB, sharing space with the originals" (the
    /// sessions: the entries by ClaudeFiles' one rule; other files only when there are any)
    static func summary(_ m: Manifest) -> String {
        func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }
        var parts: [String] = []
        if m.window {
            // counted from the items by the one rule (a backup or import of 26.11.42 and earlier counted any local_….json
            // as a session); a manifest without window items keeps its own count
            let names = m.items.filter { $0.role == .window }.map { ($0.path as NSString).lastPathComponent }
            parts.append(n(names.isEmpty ? m.counts.sessions : names.filter(ClaudeFiles.isEntryName).count, "session", "sessions"))
            let other = otherFiles(m)
            if other > 0 { parts.append(n(other, "other file", "other files")) }
            if m.counts.tasks > 0 { parts.append(n(m.counts.tasks, "task", "tasks")) }
            // the window's own folders (windowExtra): named, so a backup that holds a backlog says so
            let extra = (m.windowExtra ?? []).map { $0.path.split(separator: "/").map(String.init) }
            if extra.contains(where: { $0.count == 5 && $0[3] == "backlog" }) { parts.append("backlog") }
            if extra.contains(where: { $0.count == 5 && $0[3] == "waiting-input" }) { parts.append("waiting input") }
            if m.items.contains(where: { $0.role == .sidebar }) { parts.append("sidebar") }
            if m.items.contains(where: { $0.role == .config }) { parts.append("MCP settings") }
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
    /// The value as stored (a Bool, a number, a string), nil when none is.
    func object(forKey: String) -> Any?
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
    func object(forKey k: String) -> Any? { lock.lock(); defer { lock.unlock() }; return d[k] }
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
    func reload() { place = Self.store.string(forKey: Self.placeKey) ?? ""; last = Self.keepLast; days = Self.keepDays; seen = Self.store.string(forKey: Self.noteKey) ?? "" }

    // MARK: the one-time line for a place the person picked

    /// General ▸ Backups says once, per place, when the backups go to a folder the person picked (not cl_audit's own): backups hold copies
    /// of Claude Code's settings and scripts, and the keys found in them are left out. Per place, not once overall: what that folder is
    /// (a synced or shared one, an external drive) is what the line is about, so a second picked folder gets it again; dismissing it for
    /// one folder says nothing about another. Remembered as the folders' canonical paths (a JSON array, the last 20), in the same store
    /// as the place; the default place never shows it.
    static let noteKey = "backupsNoteSeen"
    /// (What is scanned, exactly: settings.json, the scripts its hooks run and the skills that hold them, and the plugin marketplaces;
    /// not CLAUDE.md or other skills. And only the key shapes the Export page's scan knows.)
    static let pickedNote = "Backups in this folder hold copies of Claude Code's settings and scripts (CLAUDE.md, settings.json, the scripts its hooks run). A key found in settings.json or a script its hooks run is left out. Shown once for each folder you pick."
    @Published var seen: String = BackupPrefs.store.string(forKey: BackupPrefs.noteKey) ?? ""

    /// The canonical paths dismissed, as a JSON array of strings (a folder name may hold a newline, so not a line list).
    static func noteSeen() -> [String] {
        (store.string(forKey: noteKey)).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? []
    }

    /// `FolderKey.canonical` resolves links on disk: said once per place, not on every draw of General (an unmounted network folder
    /// would stall the page).
    private static let canonLock = NSLock()
    nonisolated(unsafe) private static var canonCache: [String: String] = [:]
    private static func canon(_ place: String) -> String {
        canonLock.lock(); defer { canonLock.unlock() }
        if let c = canonCache[place] { return c }
        let c = FolderKey.canonical(place)
        if canonCache.count > 200 { canonCache = [:] }
        canonCache[place] = c
        return c
    }

    /// Whether the line shows for this `place` (the stored setting: "" is cl_audit's own folder, which never shows it).
    static func noteDue(place: String) -> Bool {
        !place.isEmpty && !noteSeen().contains(canon(place))
    }

    /// Dismisses it for this place.
    func dismissNote(place: String) {
        guard !place.isEmpty else { return }
        let c = Self.canon(place)
        var list = Self.noteSeen().filter { $0 != c }
        list.append(c)
        seen = (try? JSONSerialization.data(withJSONObject: Array(list.suffix(20)))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        Self.store.set(seen, forKey: Self.noteKey)
    }

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
        let s = userState(codeDir: codeDir)
        return (s.problem == nil ? (s.days ?? standard) : nil, s.problem)
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
    /// The file is read bounded (2 MiB), without blocking, and only when it is a plain file. One that isn't there (a link to
    /// nowhere included: Claude Code takes ENOENT as no file) and one that isn't a plain file (a folder, a FIFO) say nothing:
    /// the defaults apply.
    struct UserState: Equatable {
        var days: Int?                      // cleanupPeriodDays; nil: not there, or invalid
        var daysPresent = false, daysInvalid = false
        var desktop: Int?                   // desktopSessionCleanupPeriodDays (0: no cap); nil: not there, or invalid
        var desktopPresent = false, desktopInvalid = false
        var unreadable = false
        /// Why cleanupPeriodDays can't be told from the file (unreadable, not an object, an invalid value); nil: it can.
        var problem: String?
    }

    static let maxSettingsBytes = 2 * 1024 * 1024

    static func userState(codeDir: String) -> UserState {
        var s = UserState()
        let d: Data
        switch ManagedSettings.raw(file(codeDir), max: maxSettingsBytes) {
        case .absent, .irregular: return s
        case .bad: s.unreadable = true; s.problem = "settings.json can't be read."; return s
        case .data(let x): d = x
        }
        let j: [String: Any]
        switch parse(d) {
        case .blank: return s
        case .invalid, .notObject: s.unreadable = true; s.problem = "settings.json isn't a JSON object."; return s
        case .object(let o): j = o
        }
        if let v = j[key] {
            s.daysPresent = true
            if let n = whole(v) { s.days = n } else { s.daysInvalid = true; s.problem = "cleanupPeriodDays in settings.json isn't a valid number." }
        }
        if let v = j[desktopKey] { s.desktopPresent = true; if let n = whole(v, zero: true) { s.desktop = n } else { s.desktopInvalid = true } }
        return s
    }

    // MARK: reading a settings file the way Claude Code does

    /// The text Claude Code reads from a settings file's bytes (2.1.326, the same for settings.json, managed-settings.json,
    /// managed-settings.d/*.json and remote-settings.json): UTF-16LE when the file starts with FF FE, else UTF-8, nothing
    /// else detected (`Buffer.toString`). Decoded as Bun does, never refused: a bad UTF-8 sequence is U+FFFD, a trailing odd
    /// byte of UTF-16LE is dropped, a byte order mark is kept (U+FEFF; `parse` drops one). A bad UTF-16 pair is U+FFFD here
    /// where JavaScript keeps the lone half: the same to JSON.parse (valid in a string, invalid outside one).
    static func text(_ data: Data) -> String {
        let b = [UInt8](data)
        guard b.count >= 2, b[0] == 0xFF, b[1] == 0xFE else { return String(decoding: b, as: UTF8.self) }
        let units = stride(from: 0, to: b.count / 2 * 2, by: 2).map { UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8 }
        return String(decoding: units, as: UTF16.self)
    }

    /// JavaScript's `trim()` whitespace: blank text is an empty settings document to Claude Code (`e.trim()===""`).
    /// U+FEFF is in it, U+0085 isn't.
    private static func jsSpace(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }

    static func isBlank(_ d: Data) -> Bool { text(d).unicodeScalars.allSatisfy(jsSpace) }

    /// A settings document as Claude Code reads it: blank, not JSON to JSON.parse, JSON but not an object, or the object.
    enum Parsed { case blank, invalid, notObject, object([String: Any]) }

    /// `text`, blank as above, then one leading U+FEFF dropped and `JSON.parse` (Claude Code's `JSON.parse(Ss(e))`).
    /// Foundation's parser isn't asked whether the text is JSON: it differs from JSON.parse (it takes a trailing comma and
    /// guesses UTF-16 and UTF-32; it refuses a \ud800 escape, a number too big for a double, more than 512 levels). `valid`
    /// decides, and the object is its top-level members as JSON.parse keeps them: a name written twice holds its LAST value,
    /// names compared with their escapes decoded. A value Foundation can't read (a lone surrogate, 1e400, deep nesting)
    /// stands as a string, which is invalid for the day counts and, for a policy helper, names one (the safe side).
    static func parse(_ data: Data) -> Parsed {
        let t = text(data)
        if t.unicodeScalars.allSatisfy(jsSpace) { return .blank }
        var scalars = t.unicodeScalars[...]
        if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }
        let body = String(String.UnicodeScalarView(scalars))
        let b = Array(body.utf8)
        guard valid(b) else { return .invalid }
        guard b.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) == 0x7B else { return .notObject }
        var out: [String: Any] = [:]
        for m in scanKeys(body).members {
            out[m.name] = (try? JSONSerialization.jsonObject(with: Data(body[m.value].utf8), options: .fragmentsAllowed)) ?? "unreadable"
        }
        return .object(out)
    }

    /// Whether JSON.parse takes these bytes (UTF-8 text) as one JSON value: ECMA-404's grammar, whitespace only space, tab,
    /// LF and CR, no trailing comma, no comment, no depth limit. Outside strings JSON is ASCII, so any other byte there is
    /// refused; in a string any character from U+0020 on is taken except " and \ (an escape: \" \\ \/ \b \f \n \r \t or
    /// \u and four hex digits, a lone surrogate included).
    /// No depth limit, as JavaScriptCore's JSON.parse: macOS 27.3's JSC (22626.1.12.11.4, its jsc) takes arrays and objects
    /// nested 2^26 levels deep, far past the deepest file the size caps let through (8 MiB: about 4 million levels).
    /// Claude Code 2.1.326 runs Bun 1.4.4 on oven-sh's fork of the same engine; that build itself wasn't asked. A bound here
    /// would be the unsafe side: a settings.json called unreadable is counted with 30 days while Claude Code uses its own.
    static func valid(_ b: [UInt8]) -> Bool {
        var i = 0
        var open: [UInt8] = []                                   // the containers around i: { or [
        func space() { while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 } }
        func hex(_ c: UInt8) -> Bool { (0x30...0x39).contains(c) || (0x41...0x46).contains(c) || (0x61...0x66).contains(c) }
        func digits() -> Bool {
            let s = i
            while i < b.count, (0x30...0x39).contains(b[i]) { i += 1 }
            return i > s
        }
        func string() -> Bool {                                  // at "
            i += 1
            while i < b.count {
                let c = b[i]
                if c == 0x22 { i += 1; return true }
                if c < 0x20 { return false }
                if c == 0x5C {
                    guard i + 1 < b.count else { return false }
                    let e = b[i + 1]
                    if e == 0x75 {
                        guard i + 5 < b.count, (i + 2...i + 5).allSatisfy({ hex(b[$0]) }) else { return false }
                        i += 6
                    } else if [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(e) {
                        i += 2
                    } else { return false }
                } else { i += 1 }
            }
            return false
        }
        func number() -> Bool {
            if b[i] == 0x2D { i += 1 }
            guard i < b.count else { return false }
            if b[i] == 0x30 { i += 1 } else if (0x31...0x39).contains(b[i]) { _ = digits() } else { return false }
            if i < b.count, b[i] == 0x2E { i += 1; guard digits() else { return false } }
            if i < b.count, b[i] == 0x65 || b[i] == 0x45 {
                i += 1
                if i < b.count, b[i] == 0x2B || b[i] == 0x2D { i += 1 }
                guard digits() else { return false }
            }
            return true
        }
        func word(_ w: String) -> Bool {
            let u = Array(w.utf8)
            guard i + u.count <= b.count, Array(b[i..<i + u.count]) == u else { return false }
            i += u.count
            return true
        }
        func member() -> Bool {                                  // "name" : , ready for the value
            space()
            guard i < b.count, b[i] == 0x22, string() else { return false }
            space()
            guard i < b.count, b[i] == 0x3A else { return false }
            i += 1
            return true
        }
        var wantValue = true
        while true {
            space()
            if wantValue {
                guard i < b.count else { return false }
                switch b[i] {
                case 0x7B:
                    i += 1; space()
                    if i < b.count, b[i] == 0x7D { i += 1; wantValue = false; continue }
                    open.append(0x7B)
                    guard member() else { return false }
                case 0x5B:
                    i += 1; space()
                    if i < b.count, b[i] == 0x5D { i += 1; wantValue = false; continue }
                    open.append(0x5B)
                case 0x22: guard string() else { return false }; wantValue = false
                case 0x2D, 0x30...0x39: guard number() else { return false }; wantValue = false
                case 0x74: guard word("true") else { return false }; wantValue = false
                case 0x66: guard word("false") else { return false }; wantValue = false
                case 0x6E: guard word("null") else { return false }; wantValue = false
                default: return false
                }
            } else {
                guard let top = open.last else { return i == b.count }
                guard i < b.count else { return false }
                if b[i] == 0x2C {
                    i += 1
                    if top == 0x7B { guard member() else { return false } }
                    wantValue = true
                } else if b[i] == (top == 0x7B ? 0x7D : 0x5D) {
                    i += 1
                    open.removeLast()
                } else { return false }
            }
        }
    }

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
            guard CreateOnly.rename(tmp, to: target) else { unlink(tmp); throw BackupError("settings.json changed meanwhile; try again.") }
        }
    }

    /// The old text with only the number changed, or the key added right after the opening brace: only for a JSON object
    /// with the key once at its top level as a plain whole number (or not at all, and nowhere deeper). Anything else is
    /// refused, and so is a file Claude Code can't read (`parse`: a trailing comma, UTF-16BE…) and one that isn't valid UTF-8
    /// byte for byte (UTF-16LE, a stray byte): only UTF-8 bytes are spliced. The edit is made on the bytes: everything before
    /// and after the number (or the insertion point) is the old file's, a byte order mark and CRLF line ends included;
    /// checked, with the result read back as the old object with that one key set.
    static func edited(_ old: Data, days: Int) throws -> Data {
        guard case .object(let obj) = parse(old) else { throw BackupError("settings.json isn't a JSON object; it is left as it is.") }
        let bytes = [UInt8](old)
        let text = String(decoding: bytes, as: UTF8.self)
        guard Array(text.utf8) == bytes, !(bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) else { throw BackupError(byHand) }
        func offset(_ i: String.Index) -> Int { text.utf8.distance(from: text.utf8.startIndex, to: i) }
        var expected = obj
        expected[key] = days
        let scan = scanKeys(text)
        if obj[key] != nil, scan.top.isEmpty { throw BackupError(byHand) }    // there, but not under its plain name
        if scan.members.filter({ $0.name == key }).count != scan.top.count { throw BackupError(byHand) }   // also under an escaped name
        let span: Range<Int>, fresh: [UInt8]                                // the old bytes replaced, and what replaces them
        switch (scan.top.count, scan.anywhere) {
        case (1, 1):
            let v = scan.top[0]
            guard String(text[v]).range(of: #"^-?[0-9]+$"#, options: .regularExpression) != nil else { throw BackupError(byHand) }
            span = offset(v.lowerBound)..<offset(v.upperBound)
            fresh = Array("\(days)".utf8)
        case (0, 0):
            guard let open = scan.open else { throw BackupError(byHand) }
            let at = offset(open) + 1
            let empty = text[text.index(after: open)...].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("}")
            let nl = text.contains("\r\n") ? "\r\n" : "\n"
            span = at..<at
            fresh = Array((nl + "  \"\(key)\": \(days)" + (empty ? nl : ",")).utf8)
        default:
            throw BackupError(byHand)                                    // nested too, or twice at the top level
        }
        let out = Array(bytes[..<span.lowerBound]) + fresh + Array(bytes[span.upperBound...])
        // the bytes around the edit are the old file's, exactly
        guard out.count == bytes.count - span.count + fresh.count,
              Array(out[..<span.lowerBound]) == Array(bytes[..<span.lowerBound]),
              Array(out[(span.lowerBound + fresh.count)...]) == Array(bytes[span.upperBound...]) else { throw BackupError(byHand) }
        let d = Data(out)
        guard case .object(let back) = parse(d), (back as NSDictionary).isEqual(to: expected) else { throw BackupError(byHand) }
        return d
    }

    /// Looks through JSON text: the value ranges of the top-level keys named `key`, how many strings anywhere equal the
    /// key, and where the top-level object opens. Works on the text's bytes (the structure is ASCII).
    /// `members` is every member of the top-level object, in order: its name as JSON.parse reads it (escapes decoded) and
    /// the range of its value. `top` is the value ranges of the members written with the plain name.
    private static func scanKeys(_ text: String) -> (top: [Range<String.Index>], anywhere: Int, open: String.Index?, members: [(name: String, value: Range<String.Index>)]) {
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
        /// Skips one value; counts the strings in it that equal the key. Not recursive: JSON.parse (and `parse`) take any
        /// depth, so a nested value is skipped by counting its brackets.
        func value(_ i: inout Int) {
            var depth = 0
            repeat {
                space(&i)
                guard i < b.count else { return }
                switch b[i] {
                case 0x22: if string(&i) == k { anywhere += 1 }
                case 0x7B, 0x5B: depth += 1; i += 1
                case 0x7D, 0x5D:
                    if depth == 0 { return }                         // the end of the object around it: not this value's
                    depth -= 1; i += 1
                case 0x2C where depth > 0, 0x3A where depth > 0: i += 1
                default:
                    let s = i
                    while i < b.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
                    if i == s { return }                             // a stray , or : at the top: nothing to skip
                }
            } while depth > 0
        }
        /// A member name as JSON.parse reads it: the raw bytes between the quotes, escapes decoded.
        func decoded(_ raw: [UInt8]) -> String {
            guard raw.contains(0x5C) else { return String(decoding: raw, as: UTF8.self) }
            let quoted = Data([0x22] + raw + [0x22])
            return ((try? JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed)) as? String) ?? "\u{0}"
        }
        var top: [Range<String.Index>] = []
        var members: [(name: String, value: Range<String.Index>)] = []
        var i = 0
        space(&i)
        if i < b.count, b[i] == 0xEF { i += 3 }                           // a byte order mark
        space(&i)
        guard i < b.count, b[i] == 0x7B else { return ([], 0, nil, []) }
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
            members.append((decoded(name), at(start)..<at(end)))
        }
        return (top, anywhere, open, members)
    }

    /// The choices of Keep for: Claude Code's default, 90 days, a year.
    static let choices: [(days: Int, words: String)] = [(30, "30 days (Claude Code's default)"), (90, "90 days"), (365, "A year")]

    static func words(_ days: Int?) -> String {
        guard let days else { return "unknown" }
        return choices.first { $0.days == days }?.words ?? (days == 1 ? "1 day" : "\(days) days")
    }
}
