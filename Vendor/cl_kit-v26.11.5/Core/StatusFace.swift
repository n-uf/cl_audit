// A profile's small status picture as data: what it shows, from the profile's one display value (ProfileDisplay), so every
// app and view that draws it draws the same thing. How it looks (sizes, colours, the countdown's words) is the app's.

import Foundation

/// What decides a profile's picture besides its record. A plain value with its own defaults; an app maps its own profile
/// settings to it.
public struct ProfileLook: Codable, Equatable {
    /// The profile's name.
    public var name: String = ""
    /// Its short label; empty: from the name (`shownLabel`).
    public var label: String = ""
    /// How often its numbers are read, in minutes: the ages they are judged by (StatusAges). 5 by default.
    public var pollMinutes: Int = 5
    /// The picture marks the profile's Claude window while it is open. On by default.
    public var windowDot: Bool = true

    public init(name: String = "", label: String = "", pollMinutes: Int = 5, windowDot: Bool = true) {
        self.name = name; self.label = label; self.pollMinutes = pollMinutes; self.windowDot = windowDot
    }

    /// Keys the value lacks keep their defaults (and keys it doesn't know are skipped).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // (a key of the wrong type keeps the default too)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        pollMinutes = (try? c.decodeIfPresent(Int.self, forKey: .pollMinutes)) ?? 5
        windowDot = (try? c.decodeIfPresent(Bool.self, forKey: .windowDot)) ?? true
    }

    /// The label the picture shows: its own, else the name's first six characters in capitals.
    public var shownLabel: String { label.isEmpty ? String(name.uppercased().prefix(6)) : label }

    /// The thresholds its numbers are judged by.
    public var ages: Headline.Ages { StatusAges.of(pollMinutes: pollMinutes) }
}

/// A profile's small status picture, as data.
public struct StatusFace: Equatable {
    public var label: String
    /// The two limits as the display shows them (nil: not shown).
    public var fiveHour: Double?
    public var weekly: Double?
    /// How much of each limit's window has gone, 0–100 (nil without a reset time): the pace a picture may draw beside it.
    public var fiveHourElapsed: Double?
    public var weeklyElapsed: Double?
    /// Drawn grey: old numbers, or none.
    public var grey: Bool
    /// The sign-in is on another account than the folder names.
    public var otherAccount: Bool
    /// The full limit that holds the profile back now (none once its reset has passed): a picture shows how long until
    /// it's back instead of the numbers.
    public var full: FullLimit?
    /// The profile's Claude window is open, and the look marks it.
    public var windowOpen: Bool

    /// The five-hour and weekly windows, for the elapsed shares.
    public static let fiveHourWindow: TimeInterval = 5 * 3600
    public static let weeklyWindow: TimeInterval = 7 * 86400

    /// The picture for a display value (ProfileDisplay.of) and look at `now`; `windowOpen`: the profile's Claude window runs.
    public static func of(_ d: ProfileDisplay, look: ProfileLook, windowOpen: Bool, now: Date = Date()) -> StatusFace {
        let u = d.usage
        return StatusFace(label: look.shownLabel, fiveHour: u?.fiveHour, weekly: u?.weekly,
                          fiveHourElapsed: elapsed(u?.fiveHourResets, fiveHourWindow, now: now),
                          weeklyElapsed: elapsed(u?.weeklyResets, weeklyWindow, now: now),
                          grey: d.grey, otherAccount: d.otherAccount, full: d.full(now: now),
                          windowOpen: windowOpen && look.windowDot)
    }

    /// The picture straight from a record (nil: none yet), its look and the caller's `source` words (ProfileDisplay.of).
    public static func of(record: StatusRecord?, look: ProfileLook, windowOpen: Bool, source: String, now: Date = Date()) -> StatusFace {
        of(ProfileDisplay.of(record, ages: look.ages, source: source, now: now), look: look, windowOpen: windowOpen, now: now)
    }

    /// How much of a window ending at `resets` has gone at `now`, 0–100.
    public static func elapsed(_ resets: Date?, _ window: TimeInterval, now: Date) -> Double? {
        guard let resets, window > 0 else { return nil }
        return min(max(1 - resets.timeIntervalSince(now) / window, 0), 1) * 100
    }
}
