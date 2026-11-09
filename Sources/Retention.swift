// Retention: which transcripts Claude Code's own clean-up deletes, and after how long. This follows the clean-up of the
// installed Claude Code (2.1.318; the rule came with 2.1.248), read from its program text, not from anyone's data.
//
// A transcript is a candidate once it is older than `cleanupPeriodDays` (30 when not set). A candidate is KEPT anyway when
// it is a session of the Claude window or Cowork, unless:
//   - managed settings set `cleanupPeriodDays`, or a settings file has an error about the two keys (or any real error), or
//     HIPAA or zero data retention applies: then there is no exemption at all and every candidate is deleted. (HIPAA and
//     zero data retention can't be seen from here; the info texts say so.)
//   - `desktopSessionCleanupPeriodDays` (managed settings first, else the user's settings.json; project and local settings
//     are ignored) is more than 0 and the transcript is older than it: a hard cap, so the window's sessions are deleted
//     once older than BOTH numbers (the larger). 0, the default, is no cap.
//   - the session's release marker `<session>.desktop-released.json` (next to the transcript, read up to 4096 bytes, an
//     object with an optional `reason`) says "delete": deleted at once; or "archive": kept for a grace period, deleted once
//     the MARKER is older than `cleanupPeriodDays`. A marker in the grace period keeps the transcript whatever it holds.
// A window session is told by the transcript itself: the `entrypoint` of its first line that has one (within the first
// 64 KB), or of its last such line (within the last 64 KB), is `claude-desktop`, `claude-desktop-3p` or `local-agent`
// (also spelled `local_agent`). So a session started in the window and continued in the terminal, or the other way round,
// is the window's; one whose first and last entrypoint are both the terminal's is not, wherever it was continued in between.
// The Code tab's entries are not looked at. An empty transcript with no folder of that name beside it is kept. An
// `agent-*.jsonl` file (a sub-agent's) is also deleted when the marker of the session it names (its `sessionId`) says so.

import Foundation

struct Retention: Equatable {
    /// `cleanupPeriodDays` as it applies: the managed value, else settings.json's (30 when it says nothing); nil: unknown
    /// (settings.json can't be read or holds something that isn't a whole number of days).
    var days: Int? = CodeCleanup.standard
    /// `desktopSessionCleanupPeriodDays` as it applies (managed first, else settings.json's); nil: no cap (not set, or 0).
    var desktopDays: Int?
    /// Managed settings set `cleanupPeriodDays`: every transcript has that limit, the window's too.
    var managed = false
    /// One of the two keys holds something Claude Code reports as a settings error: it then ends the window exemption.
    var settingsError = false
    /// Where the managed values came from, when there are any.
    var source: ManagedSettings.Source?
    /// Why `days` is unknown, when it is.
    var problem: String?

    enum Verdict: Equatable { case keep, delete, unknown }

    /// The window exemption is on (nothing managed, no settings error).
    var exempts: Bool { !managed && !settingsError }

    /// Whether Claude Code deletes a transcript, now.
    func verdict(_ t: Transcript, now: Date = Date()) -> Verdict {
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
        let desktop = CodeCleanup.userDesktop(codeDir: codeDir)
        var r = Retention()
        r.days = user.days; r.problem = user.problem
        var cap = desktop.days
        r.settingsError = desktop.invalid
        if let a = admin {
            r.source = a.source
            if let d = a.days { r.days = d; r.managed = true; r.problem = nil }
            if a.desktopSet { cap = a.desktop }                                       // a managed 0 wins over the user's number
            if a.invalid { r.settingsError = true }
        }
        r.desktopDays = (cap ?? 0) > 0 ? cap : nil
        return r
    }

    // MARK: the words (one place, for the Sessions card, Restore and Import)

    /// The Keep for row's info text (Settings ▸ a profile ▸ Sessions); the site's Settings page says the same.
    static func keepForInfo(file: String) -> String {
        "How long Claude Code keeps the sessions you ran in the terminal: cleanupPeriodDays in \(file) (default 30), kept with every other setting in that file. "
        + "Sessions started or last continued in the Claude window are kept at any age (Claude Code 2.1.248 and later), unless desktopSessionCleanupPeriodDays gives them a limit "
        + "or the window released the session. Your organisation's managed settings, HIPAA, zero data retention or an error in a settings file make the period apply to them too. "
        + "A longer time keeps the terminal sessions available to claude --resume and for backups; it can't bring back what is already deleted."
    }

    /// The Kept here row's info text.
    static let keptHereInfo = "Claude Code's session transcripts, the entries of the Claude window's Code tab (for every account it has used), and how much room they take. "
        + "The last sentence says when Claude Code deletes them: sessions from the Claude window are kept at any age since Claude Code 2.1.248."

    /// The end of the Kept here line.
    var keptHereWords: String {
        if managed, let days { return "Your organisation's managed settings make Claude Code delete sessions after \(days) days." }
        guard let days else { return "How long Claude Code keeps sessions from the terminal isn't known (settings.json)." }
        if settingsError { return "Claude Code deletes sessions after \(days) days, the Claude window's too, while a settings file has an error." }
        if let desktopDays { return "Claude Code deletes terminal sessions after \(days) days and ones from the Claude window after \(max(desktopDays, days))." }
        return "Claude Code deletes terminal sessions after \(days) days; ones from the Claude window it keeps (Claude Code 2.1.248 and later)."
    }

    /// A line under the Keep for menu when the Claude window's sessions don't simply stay (nil: they do, or nothing to add).
    var keepForNote: String? {
        if managed, let days {
            return "Your organisation's managed settings set \(days) days for every session, the Claude window's too. Changing it here wouldn't change that."
        }
        if settingsError, let days {
            return "A settings file has an error, so Claude Code deletes the Claude window's sessions after \(days) days too, like the others."
        }
        if let desktopDays, let days {
            return "Sessions from the Claude window are deleted after \(max(desktopDays, days)) days (desktopSessionCleanupPeriodDays is \(desktopDays); the longer of it and this applies)."
        }
        return nil
    }

    /// The info text of the Would be deleted row of Restore (`comes` is "comes back") and Import ("comes in").
    func wouldDeleteInfo(file: String, comes: String) -> String {
        let again = "A transcript \(comes) with its real age, so one older than that would be deleted again."
        if managed, let days {
            return "Your organisation's managed settings set cleanupPeriodDays to \(days) days for every session, the Claude window's too. \(again)"
        }
        if settingsError, let days {
            return "A settings file has an error, so Claude Code deletes every session after cleanupPeriodDays (\(days) days here), the Claude window's too. \(again)"
        }
        var s = "Claude Code deletes the transcript of a session once it is older than cleanupPeriodDays (\(file), 30 by default). \(again) "
        s += "Sessions started or last continued in the Claude window aren't counted: Claude Code keeps them at any age (2.1.248 and later)"
        if let desktopDays, let days { s += ", unless desktopSessionCleanupPeriodDays gives them a limit, as here: they count once they are older than \(max(desktopDays, days)) days" }
        s += ", or the window released the session (a .desktop-released.json next to the transcript)"
        return s + ". Your organisation's managed settings, HIPAA, zero data retention or a settings error make the period apply to all of them (HIPAA and zero data retention can't be seen from here)."
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
        func words(_ r: Retention, keepHint: Bool = true) -> String {
            var parts: [String] = []
            if old > 0 {
                var s = "\(old): Claude Code would delete them again"
                if oldWindow > 0, !r.managed { s += " (\(oldWindow) of the Claude window, released by it or past the limit set for those)" }
                if keepHint, oldSaved == old { s += ". Keep for 90 days first" }
                else if keepHint, oldSaved > 0 { s += ". Keep for 90 days would keep \(oldSaved) of them" }
                else if r.managed { s += ". Your organisation's managed settings set that time" }
                parts.append(s)
            }
            if unsure > 0 { parts.append("\(unsure): not known, settings.json doesn't say how long Claude Code keeps them") }
            return parts.joined(separator: " · ")
        }
    }
}

// MARK: what Claude Code reads from a transcript's folder

extension Retention {
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
            let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
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
            return read(fd: fd, st: st) ?? Marker(reason: nil, modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
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
            var t = Transcript(modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
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

        /// From a path, with the markers looked up beside it. nil when it isn't a plain file.
        static func read(path: String) -> Transcript? {
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
                Marker.read(path: (dir as NSString).appendingPathComponent(id + Marker.suffix))
            }
        }
    }
}

// MARK: the organisation's managed settings (read only, never written)

/// The settings an organisation sets for Claude Code, from the sources Claude Code reads, in its order: the server-managed
/// cache (`<Claude Code folder>/remote-settings.json`), then MDM's managed preferences for `com.anthropic.claudecode`
/// (the plists macOS keeps under /Library/Managed Preferences, which is what Claude Code reads too), then the managed
/// settings files (`/Library/Application Support/ClaudeCode/managed-settings.json`, then `managed-settings.d/*.json` in
/// alphabetical order, a later value replacing an earlier one). The first source that holds any setting supplies all of
/// them; the others are ignored. Plain files only (never through a link), at most 2 MiB (8 MiB for the server cache), each
/// parsed as a JSON object (or a property list for MDM). A source that can't be read counts as not there.
enum ManagedSettings {
    enum Source: String, Equatable { case server, mdm, file }

    struct Values: Equatable {
        var source: Source
        var days: Int?                      // cleanupPeriodDays, when it is a whole number of days (1 or more)
        var desktop: Int?                   // desktopSessionCleanupPeriodDays, when it is a whole number (0 or more)
        var desktopSet = false              // the key is there and valid (a 0 is a value too)
        var invalid = false                 // one of the two keys is there with something else: Claude Code reports an error
    }

    // The seams of the checks: where the sources are. The program never writes to any of them.
    nonisolated(unsafe) static var fileDir = "/Library/Application Support/ClaudeCode"
    nonisolated(unsafe) static var mdmDir = "/Library/Managed Preferences"
    nonisolated(unsafe) static var mdmUser = NSUserName()
    nonisolated(unsafe) static var useServerCache = true

    static let domain = "com.anthropic.claudecode"
    static let maxBytes = 2 * 1024 * 1024, maxServerBytes = 8 * 1024 * 1024

    /// A plain file's bytes, or nil (missing, a link, not a regular file, too big, unreadable).
    static func bytes(_ path: String, max: Int = maxBytes) -> Data? {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= Int64(max) else { return nil }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 { return nil }
            if n == 0 { break }
            out.append(buf, count: n)
            if out.count > max { return nil }
        }
        return out
    }

    private static func json(_ path: String, max: Int = maxBytes) -> [String: Any]? {
        guard let d = bytes(path, max: max) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// The server-managed settings Claude Code last stored for this profile.
    static func server(codeDir: String) -> [String: Any]? {
        guard useServerCache, !codeDir.isEmpty else { return nil }
        return json((codeDir as NSString).appendingPathComponent("remote-settings.json"), max: maxServerBytes)
    }

    /// MDM: the per-user managed preferences first, then the device-level ones.
    static func mdm() -> [String: Any]? {
        for p in [(mdmDir as NSString).appendingPathComponent("\(mdmUser)/\(domain).plist"), (mdmDir as NSString).appendingPathComponent("\(domain).plist")] {
            guard let d = bytes(p), let o = (try? PropertyListSerialization.propertyList(from: d, options: [], format: nil)) as? [String: Any], !o.isEmpty else { continue }
            return o
        }
        return nil
    }

    /// managed-settings.json, then managed-settings.d/*.json (not hidden ones) in alphabetical order, merged key by key.
    static func files() -> [String: Any]? {
        let fm = FileManager.default
        let dropIns = (fileDir as NSString).appendingPathComponent("managed-settings.d")
        var paths = [(fileDir as NSString).appendingPathComponent("managed-settings.json")]
        paths += ((try? fm.contentsOfDirectory(atPath: dropIns)) ?? []).filter { !$0.hasPrefix(".") && $0.hasSuffix(".json") }.sorted()
            .map { (dropIns as NSString).appendingPathComponent($0) }
        var merged: [String: Any] = [:]
        for p in paths { if let j = json(p) { for (k, v) in j { merged[k] = v } } }
        return merged.isEmpty ? nil : merged
    }

    /// The two values from the first source that holds any setting; nil: no source does.
    static func read(codeDir: String) -> Values? {
        let found: (Source, [String: Any])
        if let s = server(codeDir: codeDir), !s.isEmpty { found = (.server, s) }
        else if let m = mdm() { found = (.mdm, m) }
        else if let f = files() { found = (.file, f) }
        else { return nil }
        var v = Values(source: found.0)
        let doc = found.1
        if let x = doc[CodeCleanup.key] {
            if let n = CodeCleanup.whole(x) { v.days = n } else { v.invalid = true }
        }
        if let x = doc[CodeCleanup.desktopKey] {
            if let n = CodeCleanup.whole(x, zero: true) { v.desktop = n; v.desktopSet = true } else { v.invalid = true }
        }
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
