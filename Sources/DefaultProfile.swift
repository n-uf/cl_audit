// DefaultProfile: "Make the default profile the one Claude opens directly" (cl_audit 26.11.5, issue #15).
//
// The default profile is the one on Claude Code's default folder ~/.claude with the usual Claude app (DesktopMode.standard):
// what Claude shows when it is opened from the Dock or Applications, and what `claude` uses in Terminal. A Mac set up the
// old way has its first profile on its own window instead (a separate data folder, opened only from cl_audit), so opening
// Claude directly shows other sessions. This file is the one-time offer to fix that, never automatic:
//
//   windowOnly    the sole or first profile is already on ~/.claude but has its own window (the folder moved after first
//                 run, the window kind stayed). No sign-in step and no transcript move: the same Claude Code folder.
//                 Its Code-tab entries and sidebar move from the separate data folder to the usual app's, and its
//                 `desktop` becomes .standard.
//   otherFolder   the first profile uses another folder (~/.claude-account) with its own window, next to a ~/.claude
//                 profile without a sign-in, or with none yet. Step one signs Claude Code into ~/.claude (its own login in
//                 Terminal, never a sign-in moved or copied), then the old profile's transcripts and window data move into
//                 the ~/.claude profile (made then, when there is none), and the old profile is offered to stay as a
//                 standby account or be removed.
//
// The move is the restore engine's (SessionsRestore): a backup of the old window's data (and, for otherFolder, its
// transcripts) is restored into the usual app's data and ~/.claude/projects, merging and never overwriting, with a receipt,
// a journal and Undo. A backup of the usual app's own data is made first too. Nothing is deleted from the old window's
// folder: it stays as the backup's source and for Undo. The undo of the receipt also puts the profile's window kind back
// (the record kept here names what to put back).

import Foundation

enum DefaultProfile {
    enum Kind: String, Codable { case windowOnly, otherFolder }

    /// What the offer is about now.
    struct Situation: Equatable {
        var kind: Kind
        /// The profile whose own window's sessions move: the one that is flipped (windowOnly) or the old profile.
        var old: AccountEntry
        /// otherFolder: the ~/.claude profile already in the list (no sign-in yet); nil: the offer makes it in step one.
        var target: AccountEntry?
    }

    // MARK: when the offer shows

    /// The situation for this list of profiles, or nil when the Mac is fine: the usual Claude app belongs to a profile that is
    /// signed in, or no profile has its own window.
    ///
    /// - The sole or first profile has its own window (`.separate`): the offer, whatever its folder is. On ~/.claude it is
    ///   windowOnly; on another folder it is otherFolder, towards the ~/.claude profile in the list (without a sign-in) or a
    ///   new one.
    /// - A ~/.claude profile without a sign-in has the usual app, and a separate-window profile on another folder sits
    ///   next to it: otherFolder towards that profile.
    /// The usual app is a profile's that is signed in (a working default profile): no offer.
    static func situation(_ accounts: [AccountEntry], signedIn: (String) -> Seat? = DefaultProfile.cachedSeat) -> Situation? {
        guard let first = accounts.first else { return nil }
        let usual = accounts.first { $0.desktop == .standard }
        // the usual app belongs to a profile that works (signed in): the default profile exists
        if let u = usual, signedIn(u.configDir) != nil { return nil }
        func onDefault(_ e: AccountEntry) -> Bool { Account.isDefault(configDir: e.configDir) }
        if first.desktop == .separate, first.claudeWindow {
            if onDefault(first) { return usual == nil ? Situation(kind: .windowOnly, old: first, target: nil) : nil }
            // another folder: the ~/.claude profile (without a sign-in) is the target, or none yet
            if let u = usual, !onDefault(u) { return nil }
            return Situation(kind: .otherFolder, old: first, target: usual)
        }
        // the first profile is the unsigned ~/.claude one: a separate-window profile after it is the old one
        if let u = usual, onDefault(u), let old = accounts.first(where: { $0.desktop == .separate && $0.claudeWindow && !onDefault($0) }) {
            return Situation(kind: .otherFolder, old: old, target: u)
        }
        return nil
    }

    /// The account a folder is signed in to, from the folder's record read again only when its date changed: the cards that
    /// ask are drawn every few seconds, and ~/.claude.json can be large.
    static let cachedSeat: (String) -> Seat? = { FolderFactsCache.facts($0)?.seat }

    /// The prefs the offer's "Not now" is kept in (UserDefaults; a check replaces it).
    nonisolated(unsafe) static var prefs: PrefStore = UserDefaults.standard
    static let dismissedKey = "defaultProfileOfferDismissed"
    static var dismissed: Bool {
        get { (prefs.int(forKey: dismissedKey) ?? 0) != 0 }
        set { prefs.set(newValue ? 1 : 0, forKey: dismissedKey) }
    }

    /// The card shows by itself only until it is dismissed (once, it doesn't come back by itself); it is always there to
    /// be found in Settings ▸ General and on the profile's Claude window card while a situation exists.
    static func card(_ accounts: [AccountEntry], signedIn: (String) -> Seat? = DefaultProfile.cachedSeat) -> Situation? {
        dismissed ? nil : situation(accounts, signedIn: signedIn)
    }

    // MARK: what changes in the profile (pure)

    /// The profile after the move: the usual Claude app, no data folder of its own; linked to the account ~/.claude is
    /// signed in to when it wasn't linked yet. Everything else (name, look, Dock icon, window switches) stays.
    static func moved(_ e: AccountEntry, seat: Seat?, now: Date = Date()) -> AccountEntry {
        var x = linked(e, seat: seat, now: now)
        x.desktop = .standard
        x.desktopDataDir = ""
        return x
    }

    /// The profile linked to the account ~/.claude is signed in to, when it wasn't linked yet; nothing else changes.
    static func linked(_ e: AccountEntry, seat: Seat?, now: Date = Date()) -> AccountEntry {
        var x = e
        if x.seat == nil, var s = seat { s.linkedAt = now; x.seat = s }
        return x
    }

    /// The profile as it was before the move (Undo): the window it had, and unlinked again when the move linked it.
    static func reverted(_ e: AccountEntry, _ r: Record) -> AccountEntry {
        var x = e
        if r.flipped { x.desktop = r.oldDesktop; x.desktopDataDir = r.oldDesktopDataDir }
        if r.linkedSeat { x.seat = nil }
        return x
    }

    // MARK: the record (what Undo puts back besides the files)

    struct Record: Codable, Equatable, Identifiable {
        var id: String
        var kind: Kind
        var profile: String                 // the profile that is (or becomes) the default one
        var oldProfile: String?             // otherFolder: the profile whose window and sessions moved
        var flipped = false                 // `profile`'s window kind was changed from oldDesktop
        var oldDesktop: DesktopMode = .separate
        var oldDesktopDataDir = ""
        var linkedSeat = false              // the move linked `profile` to the account ~/.claude is signed in to
        var created = false                 // the move made `profile` (a ~/.claude profile there was none of)
        var oldDataDir = ""                 // the window data folder that was moved from (expanded)
        var backup: String                  // the backup of the old window's data, under `profile`'s backups
        var backupPlace: String
        var defaultBackup: String?          // the backup of the usual app's own data made first
        var started: Date
        var receipt: String?                // the restore's receipt
        var finished: Date?
        var undone: Date?

        /// The move changed something (the window kind, a link, a new profile) or wrote a receipt, and is neither finished
        /// nor undone: the card must say so.
        var open: Bool { undone == nil && finished == nil && (flipped || linkedSeat || created || receipt != nil) }
    }

        /// otherFolder: what became of the old profile after the move ("standby" or "removed"). From then on the move can't
        /// be undone: Undo would take a profile or a folder away that now holds the only copy of something.
        var oldHandled: String?
    static var folder: URL { Store.folder.appendingPathComponent("default-moves") }

    static func save(_ r: Record) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(r) { try? d.write(to: folder.appendingPathComponent("\(r.id).json"), options: .atomic) }
        cache = nil
    }

    /// The records, kept until the folder changes: the cards that ask are drawn every few seconds.
    private static var cache: (stamp: Date?, list: [Record])?
    private static let cacheLock = NSLock()

    static func all() -> [Record] {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = cache, c.stamp == stamp { return c.list }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let list: [Record] = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
            .compactMap { (try? Data(contentsOf: folder.appendingPathComponent($0))).flatMap { try? dec.decode(Record.self, from: $0) } }
        cache = (stamp, list)
        return list
    }

    /// Forgets the kept records (a check that changes the folder under it).
    static func forgetCache() { cacheLock.lock(); cache = nil; cacheLock.unlock() }

    static func record(forReceipt id: String) -> Record? { all().first { $0.receipt == id } }

    /// Writes the restore's receipt id into the move's record, the moment the engine first writes the receipt (a crash or
    /// quit after that still finds the restore, to Finish or Undo). Called from the restore's thread: disk only.
    static func attachReceipt(record id: String, receipt: String) {
        forgetCache()
        guard var r = all().first(where: { $0.id == id }), r.receipt != receipt else { return }
        r.receipt = receipt
        save(r)
    }

    /// The restore that belongs to a move: the one its record names, else, for a crash between the engine's first write and
    /// the record's, the restore of this profile that read the move's backup.
    static func restoreFor(_ r: Record) -> SessionsRestore.Receipt? {
        if let id = r.receipt, let h = SessionsRestore.header(id) { return h }
        return SessionsRestore.headers().first { $0.profile == r.profile && $0.backup == r.backup }
    }

    /// A move that is open: it changed the profile (or wrote files) and wasn't finished or undone, e.g. cl_audit quit part
    /// way. The card sends the user to that restore's Finish or Undo when files were written, and offers "Put it back" only
    /// when none were.
    static func unfinished() -> Record? {
        for var r in all().reversed() where r.open {
            // its restore was finished from the Restore page (after a restart, say): the move is done, the record catches up
            if let rc = restoreFor(r), rc.finished != nil, rc.undone == nil {
                r.receipt = rc.id; r.finished = rc.finished; save(r)
                continue
            }
            return r
        }
        return nil
    }

    /// Why this move can't be undone any more, or nil: its old profile was kept as a standby account or removed.
    static func undoRefusal(_ r: Record) -> String? {
        r.oldHandled.map { undoRefusalWords(removed: $0 == "removed") }
    }

    static func undoRefusalWords(removed: Bool) -> String {
        "The old profile was \(removed ? "removed" : "kept as a standby account"), so this move can't be undone from here. Its backup is listed under Sessions in the default profile's settings."
    }

    /// The same, for a restore receipt (the engine's refusal of Undo).
    static func undoRefusal(receipt id: String) -> String? { record(forReceipt: id).flatMap(undoRefusal) }

    /// The old profile was removed (the remove flow): a standing move that carried it over can't be undone any more.
    static func noteOldRemoved(profile id: String) {
        for var r in all() where r.oldProfile == id && r.undone == nil && r.oldHandled == nil { r.oldHandled = "removed"; save(r) }
    }

    /// The move this profile's window data came with, still standing (not undone): the import made into the old window
    /// before it has been carried over; its own Undo would only change the old window's folder.
    static func standing(profile: String) -> Record? { all().last { $0.profile == profile && $0.receipt != nil && $0.undone == nil } }

    // MARK: the preview (read-only)

    /// What would move, counted from the old window's folder against the usual app's now. Nothing is written.
    struct Preview: Equatable {
        var entries = 0                     // Code-tab entries in the old window's folder (every account folder)
        var tasks = 0                       // scheduled tasks
        var groups = 0                      // sidebar groups of the profile's account there
        var transcripts = 0                 // otherFolder: Claude Code transcripts in the old folder not in ~/.claude yet
        var inUsual = 0                     // entries the usual app has already
        var same = 0                        // of the old ones: there unchanged
        var clash = 0                       // of the old ones: there but different (what is there stays, listed)
        var hasWindowData: Bool { entries > 0 || tasks > 0 }
    }

    static func entryNames(_ dataDir: String) -> [String: [String]] {
        // lower-case file name -> every path of it under claude-code-sessions/<account>/<org>/
        let fm = FileManager.default
        let root = (expand(dataDir) as NSString).appendingPathComponent("claude-code-sessions")
        var out: [String: [String]] = [:]
        for a in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() where AccountDiscovery.isUUID(a) {
            let adir = (root as NSString).appendingPathComponent(a)
            for o in ((try? fm.contentsOfDirectory(atPath: adir)) ?? []).sorted() where AccountDiscovery.isUUID(o) {
                let odir = (adir as NSString).appendingPathComponent(o)
                for n in ((try? fm.contentsOfDirectory(atPath: odir)) ?? []).sorted() where n.hasPrefix("local_") && n.hasSuffix(".json") {
                    out[n.lowercased(), default: []].append((odir as NSString).appendingPathComponent(n))
                }
            }
        }
        return out
    }

    static func preview(oldDataDir: String, usualDataDir: String = expand(FolderKey.standardDataDir), seat: Seat? = nil,
                        oldCodeDir: String? = nil, codeDir: String = expand("~/.claude")) -> Preview {
        var p = Preview()
        let old = entryNames(oldDataDir), usual = entryNames(usualDataDir)
        p.entries = old.count
        p.inUsual = usual.count
        for (name, paths) in old {
            guard let there = usual[name]?.first, let mine = paths.first else { continue }
            let a = FileManager.default.contents(atPath: mine), b = FileManager.default.contents(atPath: there)
            if let a, let b, SessionsRestore.sameJSON(a, b) || SwitchEngine.sha(a) == SwitchEngine.sha(b) { p.same += 1 } else { p.clash += 1 }
        }
        let fm = FileManager.default
        let root = (expand(oldDataDir) as NSString).appendingPathComponent("claude-code-sessions")
        for a in ((try? fm.contentsOfDirectory(atPath: root)) ?? []) where AccountDiscovery.isUUID(a) {
            let adir = (root as NSString).appendingPathComponent(a)
            for o in ((try? fm.contentsOfDirectory(atPath: adir)) ?? []) where AccountDiscovery.isUUID(o) {
                p.tasks += SwitchEngine.tasks(in: (adir as NSString).appendingPathComponent(o)).count
            }
        }
        if let s = seat, let c = SidebarCounts.read(dataDir: oldDataDir, account: s.account) { p.groups = c.groups }
        if let src = oldCodeDir {
            let projects = (expand(src) as NSString).appendingPathComponent("projects")
            let have = (codeDir as NSString).appendingPathComponent("projects")
            for proj in ((try? fm.contentsOfDirectory(atPath: projects)) ?? []) {
                for f in ((try? fm.contentsOfDirectory(atPath: (projects as NSString).appendingPathComponent(proj))) ?? []) where f.hasSuffix(".jsonl") {
                    if !fm.fileExists(atPath: ((have as NSString).appendingPathComponent(proj) as NSString).appendingPathComponent(f)) { p.transcripts += 1 }
                }
            }
        }
        return p
    }

    // MARK: words

    static let title = "Make the default profile what Claude opens"

    /// The offer's explanation, one short paragraph per kind.
    static func why(_ s: Situation) -> String {
        let name = s.old.name.isEmpty ? "Your profile" : s.old.name
        switch s.kind {
        case .windowOnly:
            return "\(name) opens its own Claude window, with its own sessions. Opening Claude from the Dock or Applications starts the usual Claude app instead, which shows other sessions. The default profile is the one the usual Claude app shows and the claude command in Terminal uses."
        case .otherFolder:
            return "\(name) uses its own folder and its own Claude window, so opening Claude from the Dock or Applications shows other sessions. The default profile uses ~/.claude, which the usual Claude app and claude in Terminal use."
        }
    }

    /// What happens, in order (each is a step on the page).
    static func steps(_ s: Situation) -> [String] {
        let name = s.old.name.isEmpty ? "the profile" : s.old.name
        switch s.kind {
        case .windowOnly:
            return ["Back up \(name)'s window data and the usual app's own, with both windows closed.",
                    "Switch \(name) to the usual Claude app, saved before anything moves.",
                    "Move \(name)'s sessions list and sidebar into the usual app's data. Nothing is overwritten."]
        case .otherFolder:
            return ["Sign Claude Code into ~/.claude (its own login in Terminal).",
                    "Back up \(name) and the ~/.claude profile, with both windows closed.",
                    "Move \(name)'s sessions (transcripts, sessions list, sidebar) into the default profile. Nothing is overwritten.",
                    "Choose what \(name) becomes: a standby account of the default profile, or removed."]
        }
    }

    /// What each setting that depends on the window kind becomes. Said on the page, and true after the move.
    static func settingsAfter(_ e: AccountEntry) -> [String] {
        let name = e.name.isEmpty ? "The profile" : e.name
        var out = ["Claude window: stays \(e.claudeWindow ? "on" : "off"); it is now the usual Claude app.",
                   "Dock icon, Open Claude and the menu bar icon open the usual Claude app.",
                   e.opensFromDock ? "Opens from: Dock click too, as before; a Dock click opens the usual app."
                                   : "Opens from: only when asked, as before.",
                   e.windowFollowsDock ? "With Dock icon: stays on; the usual Claude app opens and quits with the Dock icon."
                                       : "With Dock icon: stays off; quitting the Dock icon leaves the usual Claude app open.",
                   "Sessions follow a switch: stays; a switch then moves the usual app's sessions."]
        if !e.desktopDataDir.isEmpty {
            out.append("\(name)'s old window folder is left as it is (the backup's source, and what Undo needs). Nothing is deleted from it.")
        }
        return out
    }

    /// The first of the two sentences the Import and Restore pages say about the move's effect on an earlier import.
    static let importNote = "This import was made into the old window's data and has been carried over to the usual app by the default-profile move. Undo this move takes it out of the usual app again; the import's own Undo would only change the old window's folder, so it isn't offered."
}

extension AccountEntry {
    /// The window this profile opens, in words, for the pages that write into it (Import, Restore, Switch, the default-profile
    /// move): "the usual Claude app", or "Main's own window, opened from its Dock icon".
    var windowWords: String { desktop == .standard ? DesktopMode.usualWords : DesktopMode.ownWords(name.isEmpty ? "this profile" : name) }
    /// The same at the start of a sentence.
    var windowWordsCap: String { let w = windowWords; return w.prefix(1).uppercased() + w.dropFirst() }
    /// "Writes into the usual Claude app's data" / "Main's own window's data (…/Claude-main)": what Import and Restore name.
    var windowDataWords: String {
        desktop == .standard ? "the usual Claude app's data" : "\(name.isEmpty ? "this profile" : name)'s own window's data"
    }
}
