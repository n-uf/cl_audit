// cl_audit's words for a full limit (ProfileCore's FullLimit is data only) and the Dock icon's countdown face while one is
// full: compiled by the app, the widget and the Dock tile plug-in alike (build.sh), so Foundation and ProfileCore only.
// TimeWords, FullLimit and AtLimit's rules are ProfileCore's (Core/TimeWords.swift, Core/Limits.swift); the card's layout
// while a limit is full stays in AtLimit.swift.

import Foundation
import ProfileCore

extension FullLimit {
    /// A limit's name: "5-hour", "Week".
    static func name(_ k: Kind) -> String { k == .fiveHour ? "5-hour" : "Week" }
    /// The id of its row in the panels (Limit.id): "5h", "wk".
    var id: String { kind == .fiveHour ? "5h" : "wk" }
    /// "5-hour" or "Week".
    var name: String { Self.name(kind) }
    /// The other full limit's name, when both are full.
    var other: String? { alsoFull.map(Self.name) }
    /// "in 1h 42m", or nil when the reset time isn't known.
    func countdown(_ now: Date = Date()) -> String? { resets.map { "in " + TimeWords.countdown($0, now: now) } }
    /// "back at 15:28", or "reset time unknown".
    func back(_ now: Date = Date()) -> String { resets.map { TimeWords.back($0, now: now) } ?? "reset time unknown" }
    /// Both times in one line: "back at 15:28, in 1h 42m", or "reset time unknown".
    func both(_ now: Date = Date()) -> String { resets.map { "\(TimeWords.back($0, now: now)), in \(TimeWords.countdown($0, now: now))" } ?? "reset time unknown" }

    /// "5-hour full", or "Week full · 5-hour too".
    var title: String { "\(name) full" + (other.map { " · \($0) too" } ?? "") }
    /// The Dock icon's line under the time: "5H FULL", "WK FULL".
    var tileFooter: String { id == "5h" ? "5H FULL" : "WK FULL" }
    /// The alert's and Dock menu's name for it: "5-hour limit", "weekly limit".
    var limitName: String { id == "5h" ? "5-hour limit" : "weekly limit" }
}

extension TimeWords {
    /// The countdown on the Dock icon, where one short value fits: ("19", "m"), ("1", "h42"), ("19", "h"), ("Thu", ""),
    /// ("16", "d"), ("Jan", "") — the first part large, the second small after it.
    static func tile(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> (String, String) {
        let m = minutesLeft(d, now: now)
        let cal = calendar
        let f = TimeWords.formatter(timeZone: cal.timeZone)
        if m < 60 { return ("\(m)", "m") }
        if m < 10 * 60 { return ("\(m / 60)", String(format: "h%02d", m % 60)) }
        if m < 24 * 60 { return ("\(m / 60)", "h") }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
        if days <= 6 { f.dateFormat = "EEE"; return (f.string(from: d), "") }
        if cal.component(.year, from: d) == cal.component(.year, from: now) { return ("\(m / 1440)", "d") }
        f.dateFormat = "MMM"; return (f.string(from: d), "")
    }
}

/// What the Dock icon shows while a limit is full: the time large ("1" + "h42"), which limit under it.
struct TileCountdown: Equatable {
    var big: String
    var small: String
    var footer: String
}

extension AtLimit {
    /// The Dock icon's countdown face for a full limit (D1), or nil when nothing is full.
    static func tileCountdown(fiveHour: Double?, fiveHourResets: Date?, weekly: Double?, weeklyResets: Date?,
                              now: Date = Date()) -> TileCountdown? {
        tileCountdown(blocker(fiveHour: fiveHour, fiveHourResets: fiveHourResets, weekly: weekly, weeklyResets: weeklyResets, now: now), now: now)
    }

    /// The countdown face for the full limit that holds the profile back (ProfileDisplay.full), or nil.
    static func tileCountdown(_ full: FullLimit?, now: Date = Date()) -> TileCountdown? {
        guard let b = full else { return nil }
        let (big, small) = b.resets.map { TimeWords.tile($0, now: now) } ?? ("—", "")
        return TileCountdown(big: big, small: small, footer: b.tileFooter)
    }
}
