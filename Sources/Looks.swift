// A profile's looks kept in its entry (AccountEntry), apart from the code that draws them: how its usage panel draws the two
// limits (PanelDesign, drawn by PanelDesigns.swift) and how its menu bar icon looks (MenuBarLook, drawn by MenuBar.swift).
// The Dock icon's own look (IconStyle, TileColor) is Painter.swift's, which the Dock tile plug-in compiles too.

import Foundation

enum PanelDesign: String, Codable, CaseIterable, Identifiable {
    case glow, rings, numbers, segments, pace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glow: return "Glow bars"
        case .rings: return "Twin rings"
        case .numbers: return "Big numbers"
        case .segments: return "Segmented"
        case .pace: return "Pace bars"
        }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable, Codable {
    case bars, barsNumber, ring, ringNumber, number, twoNumbers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bars: return "Two bars"
        case .barsNumber: return "Bars + number"
        case .ring: return "Ring"
        case .ringNumber: return "Ring + number"
        case .number: return "Number"
        case .twoNumbers: return "Two numbers"
        }
    }
    var blurb: String {
        switch self {
        case .bars: return "the 5-hour limit over the week, as thin bars"
        case .barsNumber: return "the bars, then the fuller limit as a number"
        case .ring: return "the week outside, the 5-hour limit inside"
        case .ringNumber: return "the ring, then the fuller limit as a number"
        case .number: return "the fuller of the two limits as a number"
        case .twoNumbers: return "the 5-hour and the weekly limit as numbers"
        }
    }
    static let families: [(title: String, styles: [MenuBarStyle])] =
        [("Bars", [.bars, .barsNumber]), ("Rings", [.ring, .ringNumber]), ("Numbers", [.number, .twoNumbers])]
}

enum MenuBarColours: String, CaseIterable, Identifiable, Codable {
    case levels, system, accent, profile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .levels: return "Levels"
        case .system: return "System"
        case .accent: return "Accent"
        case .profile: return "Profile colour"
        }
    }
    var blurb: String {
        switch self {
        case .levels: return "green, amber, red, crimson as the limits fill up"
        case .system: return "the menu bar's own colour, like Apple's icons: white or black, dimmed on an inactive screen. A full limit shows by its countdown, as macOS doesn't colour these icons"
        case .accent: return "your Mac's accent colour (System Settings ▸ Appearance), following it when it changes"
        case .profile: return "this profile's colour (orange for a profile with none of its own)"
        }
    }
}

enum MenuBarWhenFull: String, CaseIterable, Identifiable, Codable {
    case countdown, red
    var id: String { rawValue }
    var title: String { self == .countdown ? "Countdown" : "Crimson only" }
}

/// How a profile's menu bar icon looks; kept in the profile.
struct MenuBarLook: Codable, Hashable {
    var style: MenuBarStyle = .bars
    var colours: MenuBarColours = .levels
    var label = false                   // the profile's label before its icon ("MAIN")
    var whenFull: MenuBarWhenFull = .countdown

    init() {}

    private enum Keys: String, CodingKey { case style, colours, label, whenFull }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        style = (try? c.decodeIfPresent(MenuBarStyle.self, forKey: .style)) ?? .bars
        let raw = (try? c.decodeIfPresent(String.self, forKey: .colours)) ?? "levels"
        colours = MenuBarColours(rawValue: raw == "plain" ? "system" : raw) ?? .levels
        label = (try? c.decodeIfPresent(Bool.self, forKey: .label)) ?? false
        whenFull = (try? c.decodeIfPresent(MenuBarWhenFull.self, forKey: .whenFull)) ?? .countdown
    }
}
