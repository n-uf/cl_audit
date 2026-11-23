// What the Dock tile plug-in (DockTile/Plugin.swift) knows of a profile and of cl_audit's files, compiled into the plug-in
// on its own with ProfileCore and the drawing files (build.sh: the plug-in's sources), and into the app with everything else.
// Nothing here may reach the app's other code: the plug-in runs in the Dock's shared process.
//
// - AppPlaces: the agent's folder, the profiles file, the records, and the notices the plug-in listens for or posts. The app
//   names them from here too (Store, Installer, ClQuick, Agent), so there is one spelling of each.
// - PluginProfile: the fields of a profile's entry in accounts.json the tile and its menu use, decoded leniently (an entry
//   the app would refuse still draws, never nothing); the app makes one from its AccountEntry (PluginProfile(e)).
// - The one face: TileModel.face(profile, display, …), from the record through ProfileCore's ProfileDisplay.of.

import AppKit
import ProfileCore

enum AppPlaces {
    /// The agent's folder: the profiles file, the records, the Dock tile's heartbeats.
    static let folder = URL(fileURLWithPath: ("~/Library/Application Support/usage-n-uf" as NSString).expandingTildeInPath)
    static var configURL: URL { folder.appendingPathComponent("accounts.json") }
    static var statusFolder: URL { folder.appendingPathComponent("status") }
    static func statusURL(_ id: String) -> URL { statusFolder.appendingPathComponent("\(id).json") }
    /// The agent's "alive" mark (AgentMark).
    static var agentMarkURL: URL { folder.appendingPathComponent("agent.json") }
    /// The agent writes its mark every this many seconds.
    static let agentBeatSeconds: TimeInterval = 30

    /// The profiles file changed.
    static let configChanged = Notification.Name("local.usage-n-uf.config-changed")
    /// The agent saved a profile's record (object: the profile id).
    static let statusChanged = Notification.Name("local.usage-n-uf.status-changed")
    /// cl_audit installed, renamed or removed Dock icon apps.
    static let appsChanged = Notification.Name("local.usage-n-uf.apps-changed")
    /// Every Dock icon app (or one, its id as the object) fetches its numbers now.
    static let refreshAll = Notification.Name("local.usage-n-uf.refresh-all")
    /// The agent opens cl_quick's chat for a profile (object: its id), or cl_quick's site.
    static let quickChatOpen = Notification.Name("local.usage-n-uf.quick-chat-open")
}

/// A profile as the Dock tile and its menu see it.
struct PluginProfile: Equatable {
    var id: String
    var name: String
    var label: String
    var style: IconStyle = .bars
    var pollMinutes: Int = 5
    var color: TileColor = .orange
    var frame: TileColor? = nil
    var accent: TileColor? = nil
    var windowDot = true
    var claudeWindow = true
    /// Its Claude window quits with its Dock icon (ProfileRuns.windowFollowsDock): only the running app's menu says so
    /// ("Quit and keep"); the plug-in's never does.
    var windowFollowsDock = false

    init(id: String, name: String, label: String) { self.id = id; self.name = name; self.label = label }

    /// The profile's own colour, nil for none (AccountEntry.ownColor's rule).
    var ownColor: TileColor? { accent ?? ([.usage, .graphite].contains(color) ? nil : color) }
    /// What decides the face besides the record, in cl_kit's terms.
    var look: ProfileLook { ProfileLook(name: name, label: label, pollMinutes: pollMinutes, windowDot: windowDot) }
    /// Its label, or the start of its name when it has none (Account.label's rule).
    var shortLabel: String { label.isEmpty ? String(name.uppercased().prefix(6)) : label }

    /// The entry with this id in the profiles file, or nil: a capped read of a regular file (SafeRead), never a wait.
    static func load(_ id: String) -> PluginProfile? {
        guard let data = SafeRead.whole(AppPlaces.configURL.path, max: 4 << 20),
              let file = try? JSONDecoder().decode(Profiles.self, from: data) else { return nil }
        return file.accounts.lazy.compactMap(\.value).first { $0.id == id }
    }

    /// The profile's record as the agent saved it, or nil (a capped read, StatusCodec's decoding).
    static func record(_ id: String) -> StatusRecord? {
        SafeRead.whole(AppPlaces.statusURL(id).path, max: SafeRead.recordMax).flatMap(StatusCodec.decode)
    }

    private struct Profiles: Decodable { var accounts: [Lenient] }
    /// One entry: nil when even its id can't be read (the others still draw).
    private struct Lenient: Decodable {
        var value: PluginProfile?
        init(from decoder: Decoder) throws { value = try? PluginProfile(from: decoder) }
    }
}

extension PluginProfile: Decodable {
    private enum Keys: String, CodingKey {
        case id, name, label, style, pollMinutes, color, frame, accent, windowDot, claudeWindow, iconHidden, windowFollowsDock
    }

    /// AccountEntry's defaults for these fields, but leniently: a field that can't be read takes its default (the app's
    /// decoder would refuse the whole file; a tile drawn from defaults is better than none in the Dock's process).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        func get<T: Decodable>(_ k: Keys) -> T? { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil }
        name = get(.name) ?? id
        label = get(.label) ?? String(id.uppercased().prefix(6))
        style = get(.style) ?? .bars
        pollMinutes = min(max(get(.pollMinutes) ?? 5, 1), 60)
        color = get(.color) ?? .orange
        frame = get(.frame)
        accent = get(.accent)
        windowDot = get(.windowDot) ?? true
        claudeWindow = get(.claudeWindow) ?? true
        let dock = !(get(.iconHidden) ?? false)
        windowFollowsDock = dock && claudeWindow && (get(.windowFollowsDock) ?? false)
    }
}

extension ResolvedAccount {
    /// The account answer says whose the numbers are and no switch waits: in the split, they show under Terminal's name.
    var namesNumbersOwner: Bool { numbersFor != nil && switchWaits != true }
}

extension TileModel {
    /// A profile's Dock icon face from its one value: the Dock icon app (from ProfileShow's display) and the Dock tile
    /// plug-in (from the record, `face(_:record:)`) draw this. Grey for old numbers or none (ProfileDisplay.grey), the
    /// warning for a sign-in on another account, the countdown for the full limit that holds the profile back (none once
    /// its reset has passed).
    static func face(_ p: PluginProfile, _ display: ProfileDisplay, windowOpen: Bool, now: Date = Date()) -> TileModel {
        // what the face shows is cl_kit's (StatusFace); how it looks (style, colours, frame, countdown) is cl_audit's
        let f = StatusFace.of(display, look: p.look, windowOpen: windowOpen, now: now)
        return TileModel(label: f.label, fiveHour: f.fiveHour, weekly: f.weekly,
                         stale: f.grey, style: p.style, warn: f.otherAccount,
                         tint: p.color, frame: p.frame,
                         fiveHourElapsed: f.fiveHourElapsed, weeklyElapsed: f.weeklyElapsed, windowOpen: f.windowOpen,
                         countdown: AtLimit.tileCountdown(f.full))
    }

    /// The face from the saved record, as the plug-in draws it: ProfileCore's display of it with the profile's ages (in the
    /// split, Terminal's numbers when the record names them: Store.ages' rule).
    static func face(_ p: PluginProfile, record: StatusRecord?, windowOpen: Bool, now: Date = Date()) -> TileModel {
        let resolved = record?.current(now: now).resolved
        let ages = StatusAges.of(pollMinutes: p.pollMinutes, splitShowsNumbersOwner: resolved.map(\.namesNumbersOwner) ?? true)
        return face(p, ProfileDisplay.of(record, ages: ages, source: "Anthropic", now: now), windowOpen: windowOpen, now: now)
    }
}
