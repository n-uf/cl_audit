// MenuRows · the model: what one account row of a menu says, apart from how it is drawn. Plain values, built by the app
// from what it already has (the account's address, whether it is the one in use, its ProfileCore display value); this
// module decides nothing about an account, it only turns the display value into a compact usage line.

import Foundation
import ProfileCore

/// One account in a menu: its address (always whole, hidden or shown by AddressPrivacy when drawn), whether it is the
/// account in use (the menu's tick), and a compact usage line or a line of the app's own words under it.
public struct MenuAccountRow: Equatable {
    /// How the row's leading column marks it, beside the tick of the account in use.
    public enum Marker: Equatable {
        /// Nothing (the tick alone marks the account in use).
        case none
        /// A hollow lamp: an account standing by (cl_quick's standby look).
        case hollowLamp
        /// A "+": a row that adds an account rather than naming one (`MenuAccountRow.add`).
        case plus
    }

    /// The app's words before the address, in the same line ("Sign Terminal in to "), or "".
    public var prefix: String
    /// The account's whole address. The row draws it through AddressPrivacy; it is never in a title or a spoken label
    /// while hidden.
    public var address: String
    /// The account in use: the tick in the margin, and "selected" to VoiceOver.
    public var inUse: Bool
    /// The compact usage line under the address, or nil (a standby account isn't read).
    public var usage: MenuUsageLine?
    /// A line of the app's own words under the address when there is no usage line ("Signed out", "Last used yesterday");
    /// nil: none. The app's words, never an address: one that names an address anyway is drawn and spoken as "hidden
    /// address" while addresses are hidden (so are the prefix, the tag and the hint).
    public var note: String?
    /// The app's words right after the address, in the same line (" · standby"), or "".
    public var tag: String
    /// The app's word at the right of the address line while the row is lit ("Switch…"), or nil; VoiceOver's help too.
    public var hint: String?
    /// false: never lit, does nothing, drawn disabled.
    public var enabled: Bool
    /// A quieter look for an account that isn't the one in use (cl_quick's standby rows: tertiary text). It still lights
    /// and acts.
    public var dimmed: Bool
    /// The leading column's mark.
    public var marker: Marker
    /// Waiting for something (cl_quick's row while a switch or a sign-in is under way): extra-faint text, fainter than a
    /// disabled row's. It acts as `enabled` says; a waiting row is usually not enabled too.
    public var waiting: Bool

    public init(prefix: String = "", address: String, inUse: Bool, usage: MenuUsageLine? = nil, note: String? = nil,
                tag: String = "", hint: String? = nil, enabled: Bool = true, dimmed: Bool = false, marker: Marker = .none,
                waiting: Bool = false) {
        self.prefix = prefix; self.address = address; self.inUse = inUse; self.usage = usage; self.note = note; self.tag = tag
        self.hint = hint; self.enabled = enabled; self.dimmed = dimmed; self.marker = marker; self.waiting = waiting
    }

    /// A row that names no account: a "+" in the leading column and the app's words where the address would stand
    /// ("Add an account…"), with the same metrics as the account rows and a pick like theirs; `note` is a second line of
    /// the app's words under it ("Signing in…").
    public static func add(_ words: String, note: String? = nil, hint: String? = nil, enabled: Bool = true,
                           waiting: Bool = false) -> MenuAccountRow {
        var r = MenuAccountRow(prefix: words, address: "", inUse: false, note: note, hint: hint, enabled: enabled, marker: .plus,
                               waiting: waiting)
        r.isAdd = true
        return r
    }
    /// The row names no account: made by `add` and only there (never from an empty address, so an account row whose
    /// address is missing still draws and speaks the stand-in). No address to draw, hide or speak.
    public private(set) var isAdd = false
}

/// Where a row's leading mark and its address stand, so the rows line up with what's above them in the app's menu (cl_quick's
/// usage block, a profile menu's name column).
public struct MenuRowColumns: Equatable {
    /// The mark's left edge (the tick's right edge sits just before `addressX` instead).
    public var markerX: CGFloat
    /// The address's (and the prefix's, the second line's) left edge.
    public var addressX: CGFloat
    public init(markerX: CGFloat, addressX: CGFloat) { self.markerX = markerX; self.addressX = addressX }
    /// The address's column alone: the mark stands `markerGap` before it (a 7 pt lamp and 6 pt of room), never closer to
    /// the edge than the standard 4 pt. `MenuRowColumns(addressX: 14)` is `standard`; 27 puts the mark at 14 (cl_quick).
    public init(addressX: CGFloat) { self.init(markerX: max(4, addressX - Self.markerGap), addressX: addressX) }
    /// How far the mark stands before the address when only the address's column is given.
    static let markerGap: CGFloat = 13
    /// A native menu's: the tick in the margin, the text at 14 pt.
    public static let standard = MenuRowColumns(markerX: 4, addressX: 14)
}

/// The words a usage line is made of: the app's (or the kit's plain ones, `standard`).
public struct MenuRowWords: Equatable {
    /// The 5-hour limit's short name ("5h").
    public var fiveHour: String
    /// The week's short name ("Week").
    public var week: String
    /// What a full limit says after its name ("full"); the countdown to its reset follows (TimeWords.countdown).
    public var full: String
    /// The mark of the account in use, in the margin ("✓").
    public var tick: String
    /// What VoiceOver says of the account in use ("selected").
    public var selected: String
    /// What VoiceOver says of a waiting row ("waiting").
    public var waiting: String

    public init(fiveHour: String, week: String, full: String, tick: String = "✓", selected: String = "selected",
                waiting: String = "waiting") {
        self.fiveHour = fiveHour; self.week = week; self.full = full; self.tick = tick; self.selected = selected
        self.waiting = waiting
    }

    /// Plain short words: "5h 34% · Week 12%", "Week full · 2d 19h", the tick "✓", "selected", "waiting".
    public static let standard = MenuRowWords(fiveHour: "5h", week: "Week", full: "full")
}

/// A compact usage line: each limit that shows with its percent and colour level, or the full limit and how long until
/// it's back, greyed for old numbers. Everything in it comes from ProfileCore's display value; it holds no rule of its own.
public struct MenuUsageLine: Equatable {
    /// One limit: its short name, its percent as a person reads it (rounded), its colour level (ProfileDisplay.level).
    public struct Part: Equatable {
        public var label: String
        public var percent: Int
        public var level: Level
        public init(label: String, percent: Int, level: Level) { self.label = label; self.percent = percent; self.level = level }
    }

    /// The limits that show, 5-hour first.
    public var parts: [Part]
    /// While a limit is full: its words instead of the parts ("Week full · 2d 19h"), drawn in the full colour.
    public var full: String?
    /// Old numbers: drawn grey (ProfileDisplay.grey).
    public var grey: Bool

    public init(parts: [Part], full: String? = nil, grey: Bool = false) { self.parts = parts; self.full = full; self.grey = grey }

    /// The line for a display value at `now`, or nil when it shows no numbers (`display.usage` is nil: the app says why in
    /// its own words, MenuAccountRow.note). The 5-hour part shows only where the week-only rule lets it
    /// (`display.hasFiveHour`); a limit with no number is left out; a full limit holding the profile back now
    /// (`display.full(now:)`) replaces the parts.
    public static func of(_ display: ProfileDisplay, words: MenuRowWords = .standard, now: Date = Date()) -> MenuUsageLine? {
        guard let u = display.usage else { return nil }
        if let f = display.full(now: now) {
            let name = f.kind == .fiveHour ? words.fiveHour : words.week
            let left = f.resets.map { " · " + TimeWords.countdown($0, now: now) } ?? ""
            return MenuUsageLine(parts: [], full: "\(name) \(words.full)\(left)", grey: display.grey)
        }
        var parts: [Part] = []
        // (a number that isn't finite is no number: Int(_:) would trap on it)
        if display.hasFiveHour, let p = u.fiveHour, p.isFinite {
            parts.append(Part(label: words.fiveHour, percent: Int(p.rounded()), level: display.level(p)))
        }
        if let p = u.weekly, p.isFinite { parts.append(Part(label: words.week, percent: Int(p.rounded()), level: display.level(p))) }
        return parts.isEmpty ? nil : MenuUsageLine(parts: parts, grey: display.grey)
    }

    /// The line as plain words ("5h 34% · Week 12%", "Week full · 2d 19h"): the row's spoken words and its title.
    public var words: String {
        full ?? parts.map { "\($0.label) \($0.percent)%" }.joined(separator: " · ")
    }
}
