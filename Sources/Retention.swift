// Retention: which transcripts Claude Code's own clean-up deletes, and after how long. This follows the clean-up of the
// installed Claude Code (2.1.318; the rule came with 2.1.248), read from its program text, not from anyone's data.
//
// A transcript is a candidate once it is older than `cleanupPeriodDays` (30 when not set). A candidate is KEPT anyway when
// it is a session of the Claude window or Cowork, unless:
//   - ANY managed source (server cache, MDM, managed files) sets `cleanupPeriodDays`, or ANY managed document is present
//     but can't be used (can't be read, not a plain file, too big, not a JSON object, a bad value), or HIPAA or zero data
//     retention applies: then there is no exemption at all and every candidate is deleted. (HIPAA and zero data retention
//     can't be seen from here; the info texts say so.) Errors in the user's OWN settings.json do not end the exemption;
//     they make Claude Code skip its clean-up altogether, see below. A managed source that names a policy helper
//     (`policyHelper` / `policyHelpers`, a program that computes managed settings at start) may set `cleanupPeriodDays`
//     unseen: counted as if it did (no exemption, the period settings.json gives), and never as a skipped clean-up.
//   - `desktopSessionCleanupPeriodDays` (managed settings first, else the user's settings.json; project and local settings
//     are ignored) is more than 0 and the transcript is older than it: a hard cap, so the window's sessions are deleted
//     once older than BOTH numbers (the larger). 0, the default, is no cap. Managed sources: the smallest cap any holds.
//   - the session's release marker `<session>.desktop-released.json` (next to the transcript, read up to 4096 bytes, an
//     object with an optional `reason`) says "delete": deleted at once; or "archive": kept for a grace period, deleted once
//     the MARKER is older than `cleanupPeriodDays`. A marker in the grace period keeps the transcript whatever it holds.
// A window session is told by the transcript itself: the `entrypoint` of its first line that has one (within the first
// 64 KB), or of its last such line (within the last 64 KB), is `claude-desktop`, `claude-desktop-3p` or `local-agent`
// (also spelled `local_agent`). So a session started in the window and continued in the terminal, or the other way round,
// is the window's; one whose first and last entrypoint are both the terminal's is not, wherever it was continued in between.
// The Code tab's entries are not looked at. An empty transcript with no folder of that name beside it is kept. An
// `agent-*.jsonl` file (a sub-agent's) is also deleted when the marker of the session it names (its `sessionId`) says so.
//
// Claude Code SKIPS its clean-up (deletes nothing) when its settings have a validation error, or a settings file can't be
// read or parsed, and `cleanupPeriodDays` or `desktopSessionCleanupPeriodDays` is explicitly set (or can't be told) in any
// settings file (2.1.318 `lQn`: "Skipping cleanup: … Fix settings errors to enable cleanup"), unless managed settings set
// `cleanupPeriodDays` (then it always runs). Modelled here for the user's own settings.json: an invalid key, or a file that
// can't be read, deletes nothing (Retention.Skip says which).
// NOT modelled: the same skip when a MANAGED document is bad and a clean-up key is set somewhere (or managed-settings.json
// itself can't be used): that is said as "an error in the managed settings: deleted, no exemption", which is the safe side.

import Foundation

struct Retention: Equatable {
    /// `cleanupPeriodDays` as it applies: the managed value, else settings.json's (30 when it says nothing); nil: unknown
    /// (settings.json can't be read or holds something that isn't a whole number of days).
    var days: Int? = CodeCleanup.standard
    /// `desktopSessionCleanupPeriodDays` as it applies (managed first, else settings.json's); nil: no cap (not set, or 0).
    var desktopDays: Int?
    /// Managed settings (any source) set `cleanupPeriodDays`: every transcript has that limit, the window's too.
    var managed = false
    /// An organisation's managed document is present but can't be used (or holds a bad value for one of the two keys):
    /// Claude Code then reports a managed settings error, which ends the window exemption.
    var managedError = false
    /// The organisation's managed settings name a policy helper, which may set `cleanupPeriodDays` unseen: counted as if it
    /// did (no exemption, `days` as settings.json says), never as a skipped clean-up.
    var helper = false
    /// Claude Code skips its clean-up (deletes nothing), and why.
    var skipped: Skip?
    /// Where the managed values came from, when there are any.
    var source: ManagedSettings.Source?
    /// Why `days` is unknown, when it is.
    var problem: String?

    enum Verdict: Equatable { case keep, delete, unknown }

    enum Skip: Equatable {
        case key(String)                    // that key in the user's settings.json isn't a valid number
        case unreadable                     // the user's settings.json can't be read or isn't a JSON object
    }

    /// The window exemption is on (nothing managed, no managed error, no policy helper).
    var exempts: Bool { !managed && !managedError && !helper }

    /// Whether Claude Code deletes a transcript, now.
    func verdict(_ t: Transcript, now: Date = Date()) -> Verdict {
        if skipped != nil { return .keep }
        guard let days else { return .unknown }
        let age = now.timeIntervalSince(t.modified)
        guard age > Double(days) * 86400 else { return .keep }                      // not a candidate yet
        guard exempts else { return .delete }
        if let cap = desktopDays, age > Double(cap) * 86400 { return .delete }      // a hard cap, bounds a grace too
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        switch t.marker?.effect(cutoff: cutoff) {
        case .releaseNow?: return .delete
        case .grace?: return .keep
        default: break
        }
        if t.kept { return .keep }
        if !t.window { return .delete }
        if t.sessionMarker?.effect(cutoff: cutoff) == .releaseNow { return .delete }
        return .keep
    }

    /// What the profile's Claude Code folder (settings.json) and the managed settings say.
    static func read(codeDir: String) -> Retention {
        let admin = ManagedSettings.read(codeDir: codeDir)
        let user = CodeCleanup.read(codeDir: codeDir)
        let u = CodeCleanup.userState(codeDir: codeDir)
        var r = Retention()
        r.days = user.days; r.problem = user.problem
        var cap = u.desktop
        if let a = admin {
            r.source = a.source
            if let d = a.days { r.days = d; r.managed = true; r.problem = nil }
            if a.capSet { cap = a.cap }                                               // a managed 0 wins over the user's number
            r.managedError = a.error
            r.helper = a.helper
        }
        r.desktopDays = (cap ?? 0) > 0 ? cap : nil
        // Claude Code runs its clean-up whenever managed settings set cleanupPeriodDays; otherwise it skips it when its
        // settings have an error and one of the two keys is set (or can't be told). Only the user's own settings.json is
        // modelled: a managed error is said as "deleted, no exemption" (the safe side; see the comment at the top). A policy
        // helper may set cleanupPeriodDays, so it is never said as skipped.
        if !r.managed && !r.helper {
            if u.unreadable { r.skipped = .unreadable }
            else if u.daysInvalid { r.skipped = .key(CodeCleanup.key) }
            else if u.desktopInvalid { r.skipped = .key(CodeCleanup.desktopKey) }
        }
        return r
    }

    // MARK: the words (one place, for the Sessions card, Restore and Import)

    /// The Keep for row's info text (Settings ▸ a profile ▸ Sessions); the site's Settings page says the same.
    static func keepForInfo(file: String) -> String {
        "How long Claude Code keeps the sessions you ran in the terminal: cleanupPeriodDays in \(file) (default 30), kept with every other setting in that file. "
        + "Sessions started or last continued in the Claude window are kept at any age (Claude Code 2.1.248 and later), unless desktopSessionCleanupPeriodDays gives them a limit "
        + "or you deleted or archived the session in the Claude window. Your organisation's managed settings (or an error in them), HIPAA and zero data retention make the period apply to them too; "
        + "cl_audit can't tell whether HIPAA or zero data retention applies to your account. "
        + "A longer time keeps the terminal sessions available to claude --resume and for backups; it can't bring back what is already deleted."
    }

    /// The Kept here row's info text.
    static let keptHereInfo = "Claude Code's session transcripts, the entries of the Claude window's Code tab (for every account it has used), and how much room they take. "
        + "The last sentence says when Claude Code deletes them; since Claude Code 2.1.248 that depends on where the session ran (see Keep for)."

    /// What the user's own settings.json holds, when Claude Code skips its clean-up because of it.
    private var skipWords: String? {
        switch skipped {
        case .key(let k)?: return "Claude Code doesn't delete any session while \(k) in settings.json isn't a valid number."
        case .unreadable?: return "Claude Code doesn't delete any session while settings.json can't be read."
        case nil: return nil
        }
    }

    /// The end of the Kept here line.
    var keptHereWords: String {
        if let w = skipWords { return w }
        if managed, let days { return "Your organisation's managed settings make Claude Code delete sessions \(days) days after their last use." }
        guard let days else { return "How long Claude Code keeps sessions isn't known: cleanupPeriodDays in settings.json can't be read." }
        if managedError { return "Claude Code deletes sessions \(days) days after their last use, the Claude window's too: there is an error in your organisation's managed settings." }
        if helper { return "Your organisation's managed settings may set how long Claude Code keeps sessions (a policy helper computes them), so cl_audit counts every session, the Claude window's too, as deleted \(days) days after its last use." }
        if let desktopDays { return "Claude Code deletes terminal sessions \(days) days after their last use and ones from the Claude window \(max(desktopDays, days)) days after." }
        return "Claude Code deletes terminal sessions \(days) days after their last use; ones from the Claude window it keeps (Claude Code 2.1.248 and later)."
    }

    /// A line under the Keep for menu when the Claude window's sessions don't simply stay (nil: they do, or nothing to add).
    var keepForNote: String? {
        if skipped != nil { return nil }                                        // the Kept here line says it
        if managed, let days {
            return "Your organisation's managed settings set \(days) days for every session, the Claude window's too. Changing it here wouldn't change that."
        }
        if managedError, let days {
            return "An error in your organisation's managed settings makes Claude Code delete the Claude window's sessions after \(days) days too, like the others."
        }
        if helper, let days {
            return "Your organisation's managed settings may set this for every session, the Claude window's too (a policy helper computes them); cl_audit counts with \(days) days for all of them."
        }
        if let desktopDays, let days {
            return "Sessions from the Claude window are deleted after \(max(desktopDays, days)) days, the longer of this and desktopSessionCleanupPeriodDays (\(desktopDays))."
        }
        return nil
    }

    /// The info text of the Would be deleted row of Restore (`comes` is "comes back") and Import ("comes in"), and of the
    /// default-profile move (`comes` is "moves", `moving`: the sentence says "once it is moved", not "again").
    func wouldDeleteInfo(file: String, comes: String, moving: Bool = false) -> String {
        let again = "A transcript \(comes) with its real age, so one older than that would be deleted " + (moving ? "once it is moved." : "again.")
        if managed, let days {
            return "Your organisation's managed settings set cleanupPeriodDays to \(days) days for every session, the Claude window's too. \(again)"
        }
        if managedError, let days {
            return "There is an error in your organisation's managed settings, so Claude Code deletes every session after cleanupPeriodDays (\(days) days here), the Claude window's too. \(again)"
        }
        if helper, let days {
            return "Your organisation's managed settings may set cleanupPeriodDays (a policy helper computes them), so every session older than \(days) days is counted, the Claude window's too. \(again)"
        }
        var s = "Claude Code deletes the transcript of a session once it is older than cleanupPeriodDays (\(file), 30 by default). \(again) "
        s += "Sessions started or last continued in the Claude window aren't counted: Claude Code keeps them at any age (2.1.248 and later)"
        let released = "you deleted or archived the session in the Claude window (an archived one goes after a grace period)"
        if let desktopDays, let days { s += ", unless desktopSessionCleanupPeriodDays gives them a limit, as here: they count once they are older than \(max(desktopDays, days)) days, or \(released)" }
        else { s += ", unless \(released)" }
        s += ". Your organisation's managed settings (or an error in them), HIPAA and zero data retention make the period apply to all of them; cl_audit can't see HIPAA or zero data retention."
        return s + " A project's own .claude/settings.json can also set a shorter period, which cl_audit can't see."
    }

    /// What a set of transcripts comes to: how many Claude Code would delete, and what Keep for 90 days could change.
    struct Tally: Equatable {
        var old = 0                         // Claude Code would delete them
        var oldWindow = 0                   // of them, sessions of the Claude window (released, or past the limit set for those)
        var oldSaved = 0                    // of them, a 90-day cleanupPeriodDays would keep
        var unsure = 0                      // how long Claude Code keeps them can't be told (settings.json doesn't say)

        mutating func add(_ t: Transcript, _ r: Retention, now: Date) {
            switch r.verdict(t, now: now) {
            case .delete:
                old += 1
                if t.fromWindow { oldWindow += 1 }
                if !r.managed, (r.days ?? 90) < 90 {
                    var longer = r; longer.days = 90
                    if longer.verdict(t, now: now) == .keep { oldSaved += 1 }
                }
            case .unknown: unsure += 1
            case .keep: break
            }
        }

        /// The Would be deleted row is there only when something is to say.
        var shows: Bool { old > 0 || unsure > 0 }
        /// Keep for 90 days helps only when it would save some of them.
        var canKeepLonger: Bool { oldSaved > 0 }

        /// `keepHint`: the page has the Keep for 90 days key (Restore and Import), so the words point at it.
        /// `moving`: the default-profile move, whose rows above say "N transcripts go into ~/.claude/projects".
        func words(_ r: Retention, keepHint: Bool = true, moving: Bool = false) -> String {
            var parts: [String] = []
            if old > 0 {
                var s = moving ? "\(old == 1 ? "1 of them Claude Code would" : "\(old) of them Claude Code would") delete once they are in ~/.claude" : "\(old): Claude Code would delete them again"
                if oldWindow > 0, !r.managed {
                    let why = r.exempts ? "deleted or archived there, or past its limit"
                        : r.managedError ? "an error in your organisation's managed settings" : "your organisation's managed settings may set their period"
                    s += ", \(oldWindow) of them from the Claude window (\(why))"
                }
                if keepHint, oldSaved == old { s += ". Keep for 90 days would save \(old == 1 ? "it" : "all of them")" }
                else if keepHint, oldSaved > 0 { s += ". Keep for 90 days would save \(oldSaved)" }
                else if r.managed { s += ". Your organisation's managed settings set that time" }
                parts.append(s)
            }
            if unsure > 0 { parts.append("\(unsure): can't tell, cleanupPeriodDays in settings.json can't be read") }
            return parts.joined(separator: " · ")
        }
    }
}

// MARK: what Claude Code reads from a transcript's folder

extension Retention {
    /// A file's modification time with its fraction (Claude Code compares milliseconds).
    static func mtime(_ st: stat) -> Date { Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9) }

    /// `<session>.desktop-released.json`: the window let the session go.
    struct Marker: Equatable {
        var reason: String?                 // "delete", "archive", or something else (no effect)
        var modified: Date
        enum Effect { case none, releaseNow, grace }
        /// "delete": at once. "archive": once the marker is older than the cutoff (`cleanupPeriodDays` ago); before that a grace.
        func effect(cutoff: Date) -> Effect {
            switch reason {
            case "delete": return .releaseNow
            case "archive": return modified < cutoff ? .releaseNow : .grace
            default: return .none
            }
        }
        static let maxBytes = 4096
        static let suffix = ".desktop-released.json"

        /// From an open file: nil when it isn't a plain file, is longer than 4096 bytes, or isn't a JSON object whose
        /// `reason`, when there is one, is a string (Claude Code then treats the session as not released).
        static func read(fd: Int32, st: stat) -> Marker? {
            guard (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= Int64(maxBytes) else { return nil }
            var buf = [UInt8](repeating: 0, count: maxBytes)
            let n = pread(fd, &buf, maxBytes, 0)
            guard n >= 0 else { return nil }
            let modified = Retention.mtime(st)
            guard let j = (try? JSONSerialization.jsonObject(with: Data(buf[0..<n]))) as? [String: Any] else { return Marker(reason: nil, modified: modified) }
            if let r = j["reason"], !(r is String) { return Marker(reason: nil, modified: modified) }
            return Marker(reason: j["reason"] as? String, modified: modified)
        }

        /// From a path, never through a link; nil when there is no such file.
        static func read(path: String) -> Marker? {
            let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0 else { return nil }
            return read(fd: fd, st: st) ?? Marker(reason: nil, modified: Retention.mtime(st))
        }
    }

    /// A transcript as Claude Code's clean-up sees it.
    struct Transcript: Equatable {
        var modified: Date
        /// The first line's entrypoint, or the last line's, is the Claude window's or Cowork's.
        var window = false
        /// Kept whatever the entrypoint says: an empty file with no folder beside it, or one that couldn't be read.
        var kept = false
        var marker: Marker?                 // its own release marker
        var sessionMarker: Marker?          // an agent-*.jsonl file: the marker of the session it names
        /// A session of the Claude window as far as words go: told by the entrypoint, or released by the window.
        var fromWindow: Bool { window || ["delete", "archive"].contains(marker?.reason ?? "") }

        static let tail = 65536
        static let entrypoints: Set<String> = ["claude-desktop", "claude-desktop-3p", "local-agent"]

        static func isWindow(entrypoint e: String) -> Bool { entrypoints.contains(e == "local_agent" ? "local-agent" : e) }

        /// The first line that has the key as a string (forwards), like Claude Code's own scan of the head.
        static func first(_ text: String, key: String) -> String? {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) { if let v = value(line, key) { return v } }
            return nil
        }
        /// The last such line (backwards), like its scan of the tail.
        static func last(_ text: String, key: String) -> String? {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() { if let v = value(line, key) { return v } }
            return nil
        }
        private static func value(_ line: Substring, _ key: String) -> String? {
            guard line.contains("\"\(key)\":"),
                  let j = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let s = j[key] as? String else { return nil }
            return s
        }

        /// From an open transcript. `marker(id)`: the release marker of that session id in the same folder; `hasFolder`: a
        /// folder named like the session is beside it.
        static func read(fd: Int32, st: stat, name: String, hasFolder: Bool, marker: (String) -> Marker?) -> Transcript {
            var t = Transcript(modified: Retention.mtime(st))
            let stem = name.hasSuffix(".jsonl") ? String(name.dropLast(".jsonl".count)) : name
            t.marker = marker(stem)
            let size = Int64(st.st_size)
            if size == 0 { t.kept = !hasFolder; return t }
            var buf = [UInt8](repeating: 0, count: tail)
            let n = pread(fd, &buf, tail, 0)
            guard n > 0 else { t.kept = true; return t }                        // couldn't be read: Claude Code leaves it this round
            let head = String(decoding: buf[0..<n], as: UTF8.self)
            var end = head
            if size > Int64(tail) {
                let m = pread(fd, &buf, tail, off_t(size - Int64(tail)))
                let raw = String(decoding: buf[0..<max(m, 0)], as: UTF8.self)
                end = raw.firstIndex(of: "\n").map { String(raw[raw.index(after: $0)...]) } ?? ""     // the cut first line goes
            }
            let a = first(head, key: "entrypoint"), b = last(end, key: "entrypoint")
            t.window = (a.map(isWindow) ?? false) || (b.map(isWindow) ?? false)
            if t.window, name.hasPrefix("agent-"), let sid = first(head, key: "sessionId") ?? last(end, key: "sessionId"),
               sid.range(of: "^[0-9A-Za-z_-]{1,64}$", options: .regularExpression) != nil, sid != stem {
                t.sessionMarker = marker(sid)
            }
            return t
        }

        /// From a path, with the markers looked up beside it. nil when it isn't a plain file. `destination`: the folder the
        /// transcript is going to (the default-profile move): a marker already there wins, as it does for Claude Code.
        static func read(path: String, destination: String? = nil) -> Transcript? {
            let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
            let dir = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
            let stem = String(name.dropLast(".jsonl".count))
            var isDir: ObjCBool = false
            let folder = FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(stem), isDirectory: &isDir) && isDir.boolValue
            return read(fd: fd, st: st, name: name, hasFolder: folder) { id in
                if let dest = destination {
                    let there = (dest as NSString).appendingPathComponent(id + Marker.suffix)
                    var ms = stat()
                    if lstat(there, &ms) == 0 { return Marker.read(path: there) }
                }
                return Marker.read(path: (dir as NSString).appendingPathComponent(id + Marker.suffix))
            }
        }
    }
}

// MARK: the organisation's managed settings (read only, never written)

/// The settings an organisation sets for Claude Code, from the sources Claude Code reads, in its order: the server-managed
/// cache (`<Claude Code folder>/remote-settings.json`), then MDM's managed preferences for `com.anthropic.claudecode`
/// (the plists macOS keeps under /Library/Managed Preferences, which is what Claude Code reads too), then the managed
/// settings files (`/Library/Application Support/ClaudeCode/managed-settings.json`, then `managed-settings.d/*.json` in
/// alphabetical order, a later value replacing an earlier one). Plain files only (a link is followed to its file), at
/// most 2 MiB (8 MiB for the server cache), each parsed as a JSON object (a property list for MDM).
///
/// What Claude Code makes of them (2.1.318): `cleanupPeriodDays` set in ANY of the three sources ends the window exemption,
/// whichever source's other settings win; its value is the winning (first non-empty) source's, else the smallest any holds.
/// The cap `desktopSessionCleanupPeriodDays` is likewise taken from every source: the smallest positive one, a 0 (no cap)
/// only when no source caps. A document that is there but can't be used (not readable, not a plain file, too big, not an
/// object, a drop-in folder that can't be listed, a bad value for one of the two keys) is a managed settings ERROR, which
/// ends the exemption too; only a missing file (ENOENT) is "not there". A source that names a policy helper
/// (`policyHelper` / `policyHelpers`, a program that computes managed settings at start) may set `cleanupPeriodDays`
/// unseen: then the exemption is taken as off (the safe side) and the clean-up as running.
enum ManagedSettings {
    enum Source: String, Equatable { case server, mdm, file }

    struct Values: Equatable {
        var source: Source?                 // the first source that holds any setting (nil: only errors)
        var days: Int?                      // cleanupPeriodDays as above
        var cap: Int?                       // desktopSessionCleanupPeriodDays as above (0: no cap)
        var capSet = false                  // some source holds a valid cap (a 0 is one too)
        var error = false                   // a managed document can't be used, or holds a bad value for one of the two keys
        /// Some source names a policy helper (`policyHelper` / `policyHelpers`): a program that computes managed settings
        /// when Claude Code starts. What it sets can't be seen, so it may set cleanupPeriodDays.
        var helper = false
    }

    static let helperKeys = ["policyHelper", "policyHelpers"]

    /// One document: missing, there but unusable, or its content (an empty object holds no setting).
    enum Doc { case absent, bad, content([String: Any]) }

    // The seams of the checks: where the sources are. The program never writes to any of them.
    nonisolated(unsafe) static var fileDir = "/Library/Application Support/ClaudeCode"
    nonisolated(unsafe) static var mdmDir = "/Library/Managed Preferences"
    nonisolated(unsafe) static var mdmUser = NSUserName()
    nonisolated(unsafe) static var useServerCache = true

    static let domain = "com.anthropic.claudecode"
    static let maxBytes = 2 * 1024 * 1024, maxServerBytes = 8 * 1024 * 1024

    /// A file's bytes: missing (ENOENT, a missing parent, a link to nowhere), not a plain file (a folder, a FIFO, a device:
    /// never read, so it can't block), bad (can't be opened or read, or larger than `max`), or its data.
    enum Raw { case absent, irregular, bad, data(Data) }

    /// Reads a file whole, bounded, without blocking: a link is followed, O_NONBLOCK, plain files only, at most `max` bytes.
    static func raw(_ path: String, max: Int) -> Raw {
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT || errno == ENOTDIR ? .absent : .bad }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .bad }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .irregular }
        guard st.st_size <= Int64(max) else { return .bad }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 { return .bad }
            if n == 0 { break }
            data.append(buf, count: n)
            if data.count > max { return .bad }
        }
        return .data(data)
    }

    /// One document. Only a file that isn't there (ENOENT, or a missing parent) and a blank one are `absent`: anything else
    /// that goes wrong (a folder or a FIFO where the file should be included) is `bad`.
    static func load(_ path: String, max: Int = maxBytes, plist: Bool = false) -> Doc {
        let data: Data
        switch raw(path, max: max) {
        case .absent: return .absent
        case .irregular, .bad: return .bad
        case .data(let d): data = d
        }
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .absent }
        let any: Any? = plist ? (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) : (try? JSONSerialization.jsonObject(with: data))
        guard let o = any as? [String: Any] else { return .bad }
        return .content(o)
    }

    /// The managed settings as they apply, or nil when there are none and nothing is wrong.
    static func read(codeDir: String) -> Values? {
        var docs: [(Source, [String: Any])] = []
        var error = false
        func take(_ s: Source, _ d: Doc) {
            switch d {
            case .absent: break
            case .bad: error = true
            case .content(let o): if !o.isEmpty { docs.append((s, o)) }
            }
        }
        // 1. the server-managed cache
        if useServerCache, !codeDir.isEmpty { take(.server, load((codeDir as NSString).appendingPathComponent("remote-settings.json"), max: maxServerBytes)) }
        // 2. MDM: the per-user managed preferences first, then the device-level ones (the first that holds anything)
        var mdmDoc: [String: Any]?
        for p in [(mdmDir as NSString).appendingPathComponent("\(mdmUser)/\(domain).plist"), (mdmDir as NSString).appendingPathComponent("\(domain).plist")] {
            switch load(p, plist: true) {
            case .bad: error = true
            case .content(let o): if mdmDoc == nil, !o.isEmpty { mdmDoc = o }
            case .absent: break
            }
        }
        if let m = mdmDoc { docs.append((.mdm, m)) }
        // 3. managed-settings.json, then managed-settings.d/*.json (not hidden ones) in alphabetical order, merged key by key
        var merged: [String: Any] = [:]
        func merge(_ d: Doc) { if case .content(let o) = d { for (k, v) in o { merged[k] = v } } }
        let main = load((fileDir as NSString).appendingPathComponent("managed-settings.json"))
        if case .bad = main { error = true }
        merge(main)
        let dropIns = (fileDir as NSString).appendingPathComponent("managed-settings.d")
        var dst = stat()
        if stat(dropIns, &dst) == 0 {
            if (dst.st_mode & S_IFMT) == S_IFDIR {
                if let names = try? FileManager.default.contentsOfDirectory(atPath: dropIns) {
                    for n in names.filter({ !$0.hasPrefix(".") && $0.hasSuffix(".json") }).sorted() {
                        let d = load((dropIns as NSString).appendingPathComponent(n))
                        if case .bad = d { error = true }
                        merge(d)
                    }
                } else { error = true }                                          // there, but it can't be listed
            }
        } else if errno != ENOENT && errno != ENOTDIR { error = true }           // can't even be looked at
        if !merged.isEmpty { docs.append((.file, merged)) }

        guard !docs.isEmpty || error else { return nil }
        var v = Values(source: docs.first?.0)
        var all: [Int] = [], caps: [Int] = [], winner: Int?
        for (src, d) in docs {
            if helperKeys.contains(where: { d[$0] != nil }) { v.helper = true }
            if let x = d[CodeCleanup.key] {
                if let n = CodeCleanup.whole(x) { all.append(n); if src == v.source { winner = n } } else { error = true }
            }
            if let x = d[CodeCleanup.desktopKey] {
                if let n = CodeCleanup.whole(x, zero: true) { caps.append(n) } else { error = true }
            }
        }
        v.days = winner ?? all.min()
        v.capSet = !caps.isEmpty
        v.cap = caps.filter { $0 > 0 }.min() ?? (caps.isEmpty ? nil : 0)
        v.error = error
        return v
    }
}

extension SessionsRestore.Plan {
    /// Restore and Import show the Would be deleted row only when something is to say.
    var showsWouldDelete: Bool { tally.shows }
    /// Keep for 90 days can help: some of the transcripts would be kept by it.
    var canKeepLonger: Bool { tally.canKeepLonger }
    var wouldDeleteWords: String { tally.words(retention) }
}
