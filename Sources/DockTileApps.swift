import Foundation
import ProfileCore

// The app's side of the Dock tile (DockTile.swift is the part the plug-in compiles too): reading the plug-in's heartbeat,
// the agent's rule for a Dock icon app while the Dock draws its tile, and the bridges from AccountEntry and ProfileShow to
// the plug-in's PluginProfile and face.

extension DockTile {
    /// The Dock draws the profile's tile now: its heartbeat is fresh (Settings' Runs line asks this).
    static func drawn(_ id: String, now: Date = Date()) -> Bool { fresh(lastBeat(id), now: now) }

    /// A heartbeat within TileTracker.fresh and not in the future (a clock moved back): the one test, for the agent's
    /// tracker and Settings alike.
    static func fresh(_ beat: Date?, now: Date = Date()) -> Bool {
        beat.map { now.timeIntervalSince($0) }.map { $0 >= 0 && $0 < TileTracker.fresh } ?? false
    }

    /// When the Dock last drew the profile's tile through the plug-in, or nil.
    static func lastBeat(_ id: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: beatURL(id).path))?[.modificationDate] as? Date
    }

    /// The argument of a Dock icon app an update restarted for you (Installer.sync): it starts quietly (--no-follow) but
    /// stays yours, so the agent doesn't quit it once the Dock draws the tile.
    static let startedByYou = "--started-by-you"

    /// The agent's own start of a Dock icon app: quiet (--no-follow) and not restarted for you.
    static func agentStarted(_ args: [String]) -> Bool { args.contains("--no-follow") && !args.contains(startedByYou) }

    /// A Dock icon app you started (a click) quits by itself once it's been left for a minute while the Dock draws its
    /// icon: no window shown, not the app in front. One the agent started is the agent's to quit (TileTracker).
    static let idleQuitAfter: TimeInterval = 60
    static func quitsWhenIdle(agentStarted: Bool, drawn: Bool, inFront: Bool, windowShown: Bool, idleFor: TimeInterval) -> Bool {
        !agentStarted && drawn && !inFront && !windowShown && idleFor >= idleQuitAfter
    }
}

// MARK: - the agent's rule for a Dock icon app while the Dock draws its tile

/// Whether a profile's Dock icon app should run, now that the Dock draws its tile through the plug-in (its heartbeat says
/// it does), across the agent's 30 s ticks (Rules.swift). The app no longer runs to show the usage, only when you start it:
/// one the agent started quits once the tile is drawn (never while it's the app in front). Without a heartbeat for a
/// minute (and two ticks in a row) the copy is opened once in the agent's run (macOS lets the Dock use a copy's plug-in once
/// the copy has run); still none (Dock Tiles turned off in System Settings ▸ Login Items & Extensions, an older macOS, a
/// plug-in that fails), its Dock icon app runs as before, until a heartbeat comes back. After sleep, or a tick that came
/// late, every heartbeat is old: everyone gets a minute's patience again rather than being opened at once.
struct TileTracker {
    /// A heartbeat this recent (and not in the future): the Dock draws the tile (the plug-in draws at least every 30 s).
    static let fresh: TimeInterval = 90
    /// No heartbeat this long after the copy was ready (the agent started or woke, it was pinned, opened or quit).
    static let patience: TimeInterval = 60
    /// A tick this long after the one before: the Mac slept or the agent stalled (ticks come every 30 s).
    static let gap: TimeInterval = 45

    struct Facts: Equatable {
        var pinned: Bool                // in the Dock
        var running: Bool
        var ours: Bool                  // running because the agent started it (its --no-follow), not a click
        var inFront: Bool               // it's the app in front: you're using it
        var lastBeat: Date?
    }
    enum Act: Equatable {
        case none
        case quit           // the Dock draws the tile: the app the agent started quits (its window left alone)
        case openOnce       // no tile yet: opened once (in the background, its window left alone) so the Dock may use it
        case asBefore       // still no tile: the Dock icon app runs as it did before tiles, until a heartbeat comes back
    }

    /// `quitOnce`: the agent quit its app once for a tile in this run; `sticky`: and then the Dock drew none again, so its
    /// tile beats only while the app runs: the app keeps running (no quit and restart every few minutes).
    private struct State { var readyAt: Date; var stale = 0; var tried = false; var failed = false; var quitOnce = false; var sticky = false }
    private var states: [String: State] = [:]
    private var baseline: Date
    private var lastTick: Date?

    init(now: Date = Date()) { baseline = now }

    /// The Dock drew no tile for it lately: its Dock icon app runs by the rules, as before.
    func asBefore(_ id: String) -> Bool { (states[id]?.failed ?? false) || (states[id]?.sticky ?? false) }

    /// A new copy (another build, removed, or turned off and on): it starts over, its one open included.
    mutating func forget(_ id: String) { states[id] = nil }

    /// The copy is ready to be drawn from `now` (pinned, quit): a minute's patience again.
    mutating func ready(_ id: String, now: Date = Date()) {
        var s = states[id] ?? State(readyAt: now); s.readyAt = now; s.stale = 0; states[id] = s
    }

    /// The Mac woke (or ticks stalled): every heartbeat is old, so everyone's patience starts again.
    mutating func woke(now: Date = Date()) {
        baseline = now
        for id in states.keys { states[id]?.readyAt = now; states[id]?.stale = 0 }
    }

    /// Call once per tick, before `step`: a late tick counts as a wake.
    mutating func tick(now: Date = Date()) {
        if let last = lastTick, now.timeIntervalSince(last) > Self.gap { woke(now: now) }
        lastTick = now
    }

    /// A profile's Dock icon app at this tick.
    mutating func step(_ id: String, _ f: Facts, now: Date = Date()) -> Act {
        var s = states[id] ?? State(readyAt: baseline)
        defer { states[id] = s }
        guard f.pinned else { s.stale = 0; return .none }
        if DockTile.fresh(f.lastBeat, now: now) {
            s.stale = 0
            guard !s.sticky else { return .none }       // drawn only while it runs: it keeps running, as before
            s.failed = false
            guard f.running && f.ours && !f.inFront else { return .none }
            s.quitOnce = true
            return .quit
        }
        guard !s.failed else { return .none }
        s.stale += 1
        guard now.timeIntervalSince(s.readyAt) >= Self.patience, s.stale >= 2 else { return .none }
        if f.running {
            guard f.ours else { return .none }          // one you started: left alone
            s.failed = true; if s.quitOnce { s.sticky = true }
            return .asBefore
        }
        if s.tried { s.failed = true; if s.quitOnce { s.sticky = true }; return .asBefore }
        s.tried = true; s.readyAt = now; s.stale = 0
        return .openOnce
    }
}

// MARK: - from the app's profile to the plug-in's

extension PluginProfile {
    /// The fields of a profile the Dock tile and its menu use, from the app's entry (the plug-in decodes the same ones from
    /// accounts.json: PluginProfile.init(from:)).
    init(_ e: AccountEntry) {
        self.init(id: e.id, name: e.name, label: e.label)
        style = e.style; pollMinutes = e.pollMinutes; color = e.color; frame = e.frame; accent = e.accent
        windowDot = e.windowDot; claudeWindow = e.claudeWindow; windowFollowsDock = e.runs.windowFollowsDock
    }
}

extension AccountEntry {
    /// What decides the profile's face besides its record, in cl_kit's terms (ProfileLook).
    var look: ProfileLook { PluginProfile(self).look }
}

extension TileModel {
    /// A profile's Dock icon face from its one value (ProfileShow): the Dock icon app draws this (the plug-in draws the same
    /// face from the record: TileModel.face(_:record:windowOpen:)).
    static func face(_ e: AccountEntry, _ show: ProfileShow, windowOpen: Bool, now: Date = Date()) -> TileModel {
        face(PluginProfile(e), show.display, windowOpen: windowOpen, now: now)
    }
}
