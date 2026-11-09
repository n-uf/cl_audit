// Retention: which transcripts Claude Code's own clean-up deletes, and after how long. Claude Code deletes a transcript
// once it is older than `cleanupPeriodDays` (30 when not set), with two exceptions (Claude Code 2.1.248 and later):
//   - a session started or most recently continued in the Claude window (or Cowork) is kept at any age; the user
//     settings' `desktopSessionCleanupPeriodDays` gives such sessions an age limit: each is deleted once it is older
//     than BOTH that and `cleanupPeriodDays` (so the larger of the two);
//   - when managed settings set `cleanupPeriodDays` (or the HIPAA configuration applies), the window's sessions are
//     deleted after `cleanupPeriodDays` like every other, whatever desktopSessionCleanupPeriodDays says.
// A window session is told by the Code tab: an entry (local_<id>.json in the window's claude-code-sessions/<account>/
// <organisation>/) whose `cliSessionId` is the transcript's session id. A session id only in the entry's
// `priorCliSessionIds` was continued somewhere else since, so it counts as a terminal session. (HIPAA can't be seen from
// here; the info texts say so.)

import Foundation

struct Retention: Equatable {
    /// `cleanupPeriodDays` as it applies: the managed value, else settings.json's (30 when it says nothing); nil: unknown
    /// (settings.json can't be read or holds something that isn't a whole number of days).
    var days: Int? = CodeCleanup.standard
    /// `desktopSessionCleanupPeriodDays` as it applies (managed settings first, else settings.json's): nil: none.
    var desktopDays: Int?
    /// Managed settings set `cleanupPeriodDays`: every transcript has that limit, the window's too.
    var managed = false
    /// Why `days` is unknown, when it is.
    var problem: String?

    enum Verdict: Equatable { case keep, delete, unknown }

    /// How long a transcript is kept: `.none` at any age, else days; `.unknown` when it can't be told.
    enum Limit: Equatable { case none, days(Int), unknown }

    func limit(window: Bool) -> Limit {
        if managed { return days.map(Limit.days) ?? .unknown }
        if !window { return days.map(Limit.days) ?? .unknown }
        guard let desktopDays else { return .none }
        guard let days else { return .unknown }
        return .days(max(desktopDays, days))
    }

    /// Whether Claude Code deletes a transcript last changed at `modified`.
    func verdict(window: Bool, modified: Date, now: Date = Date()) -> Verdict {
        switch limit(window: window) {
        case .none: return .keep
        case .unknown: return .unknown
        case .days(let d): return now.timeIntervalSince(modified) > Double(d) * 86400 ? .delete : .keep
        }
    }

    /// What the profile's Claude Code folder (settings.json) and the managed settings say.
    static func read(codeDir: String) -> Retention {
        let user = CodeCleanup.read(codeDir: codeDir)
        let admin = CodeCleanup.managedValues()
        var r = Retention()
        if let d = admin.days { r.days = d; r.managed = true } else { r.days = user.days; r.problem = user.problem }
        r.desktopDays = admin.desktop ?? CodeCleanup.desktopDays(codeDir: codeDir)
        return r
    }

    // MARK: which transcripts belong to the Claude window

    /// The session id (lower case) an entry's `cliSessionId` names; nil: none. `priorCliSessionIds` are not looked at: a
    /// session that was continued elsewhere since is no longer the window's.
    static func cliSession(_ entry: Data) -> String? {
        guard let j = (try? JSONSerialization.jsonObject(with: entry)) as? [String: Any],
              let id = j["cliSessionId"] as? String, !id.isEmpty else { return nil }
        return id.lowercased()
    }

    // MARK: the words (one place, for the Sessions card, Restore and Import)

    /// The Keep for row's info text (Settings ▸ a profile ▸ Sessions); the site's Settings page says the same.
    static func keepForInfo(file: String) -> String {
        "How long Claude Code keeps sessions you ran in the terminal: cleanupPeriodDays in \(file) (default 30), kept with every other setting in that file. "
        + "Sessions started or last continued in the Claude window are kept at any age (Claude Code 2.1.248 and later), unless desktopSessionCleanupPeriodDays is set, "
        + "or your organisation's managed settings or HIPAA set the period. A longer time keeps the terminal sessions available to claude --resume and for backups; "
        + "it can't bring back what is already deleted."
    }

    /// The end of the Kept here line.
    var keptHereWords: String {
        if managed, let days { return "Your organisation's managed settings make Claude Code delete sessions after \(days) days." }
        guard let days else { return "How long Claude Code keeps sessions from the terminal isn't known (settings.json)." }
        if let desktopDays { return "Claude Code deletes terminal sessions after \(days) days and ones from the Claude window after \(max(desktopDays, days))." }
        return "Claude Code deletes terminal sessions after \(days) days; ones from the Claude window it keeps."
    }

    /// A line under the Keep for menu when the Claude window's sessions don't simply stay (nil: they do, or nothing to add).
    var keepForNote: String? {
        if managed, let days {
            return "Your organisation's managed settings set \(days) days for every session, the Claude window's too. Changing it here wouldn't change that."
        }
        if let desktopDays, let days {
            return "Sessions from the Claude window are deleted after \(max(desktopDays, days)) days (desktopSessionCleanupPeriodDays is \(desktopDays); the longer of it and this applies)."
        }
        return nil
    }

    /// The info text of the Would be deleted row of Restore (`comes` is "comes back") and Import ("comes in").
    func wouldDeleteInfo(file: String, comes: String) -> String {
        if managed, let days {
            return "Your organisation's managed settings set cleanupPeriodDays to \(days) days for every session, the Claude window's too. A transcript \(comes) with its real age, so one older than that would be deleted again."
        }
        var s = "Claude Code deletes the transcript of a session you ran in the terminal once it is older than cleanupPeriodDays (\(file), 30 by default). A transcript \(comes) with its real age, so one older than that would be deleted again. "
        s += "Sessions started or last continued in the Claude window aren't counted: Claude Code keeps them at any age (2.1.248 and later)"
        if let desktopDays, let days { s += ", unless desktopSessionCleanupPeriodDays gives them a limit, as here: they count once they are older than \(max(desktopDays, days)) days" }
        return s + ". Your organisation's managed settings or HIPAA can set the period for all of them (HIPAA can't be seen from here)."
    }

    /// The sessions the window's Code tab names now: every entry in every account folder under `dataDir`.
    static func windowSessions(dataDir: String) -> Set<String> {
        guard !dataDir.isEmpty else { return [] }
        var out = Set<String>()
        for paths in SessionsRestore.WindowNow.read(dataDir).entries.values {
            for p in paths { if let d = FileManager.default.contents(atPath: p), let id = cliSession(d) { out.insert(id) } }
        }
        return out
    }
}

extension SessionsRestore.Plan {
    /// Restore and Import show the Would be deleted row only when something is to say: a transcript Claude Code would
    /// delete again, or a keep time that can't be told.
    var showsWouldDelete: Bool { old > 0 || unsure > 0 }

    /// Keep for 90 days can help: the number is the user's to change (not the organisation's) and is below 90.
    var canKeepLonger: Bool { old > 0 && !retention.managed && (retention.days ?? 90) < 90 }

    var wouldDeleteWords: String {
        var parts: [String] = []
        if old > 0 {
            var s = "\(old): Claude Code would delete them again"
            if oldWindow > 0 { s += " (\(oldWindow) of the Claude window, past the limit set for those)" }
            if canKeepLonger { s += ". Keep for 90 days first" }
            else if retention.managed { s += ". Your organisation's managed settings set that time" }
            parts.append(s)
        }
        if unsure > 0 { parts.append("\(unsure): not known, settings.json doesn't say how long Claude Code keeps them") }
        return parts.joined(separator: " · ")
    }
}
