import Foundation
import ProfileCore

// The Dock tile plug-in's shared parts (DockTile/Plugin.swift is the plug-in): its name in an app, the class name each
// profile's copy registers, and its heartbeat and log in the agent's folder (docktile/<id>.beat, docktile/<id>.log).
// The heartbeat is the file the plug-in writes each time the Dock draws a profile's tile through it.

enum DockTile {
    /// The plug-in bundle in cl_audit.app's PlugIns (unused there: cl_audit.app names no Dock tile plug-in) and in each
    /// Dock icon app's, which does (Installer.install).
    static let bundleName = "Dock Tile.docktileplugin"
    /// The plug-in's own class, which every copy carries; macOS creates the subclass the copy registers (className).
    static let baseClass = "ClAuditDockTileBase"

    /// The class a profile's copy registers and its Info.plist names: one per profile and build, so copies loaded into one
    /// Dock process never answer for each other (and a new build's copy is never the old one's class).
    static func className(_ id: String, build: String) -> String {
        "ClAuditDockTile_" + Data(id.utf8).map { String(format: "%02x", $0) }.joined() + "_" + build
    }

    /// A profile id as a file name may carry it, else nil: the plug-in reads it from a copy's Info.plist and names its
    /// heartbeat and log by it. Any letters (Store.newID keeps a name's own, "café" included); never a folder step, a
    /// hidden name, a control character or more than 200 bytes.
    static func plainID(_ id: String) -> String? {
        !id.isEmpty && id.utf8.count <= 200 && !id.hasPrefix(".") && !id.contains("/")
            && !id.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) ? id : nil
    }

    static var folder: URL { Store.folder.appendingPathComponent("docktile") }
    static func beatURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).beat") }
    static func logURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).log") }

    /// When the Dock last drew the profile's tile through the plug-in, or nil.
    static func lastBeat(_ id: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: beatURL(id).path))?[.modificationDate] as? Date
    }

    // MARK: the window dot

    /// Whether the profile's Claude window runs, as the agent last saw it ("1" or "0" in docktile/<id>.window): the
    /// plug-in draws the open dot from it (the agent reads; the plug-in only draws). The agent posts `windowNote` (the
    /// profile's id) when it changes.
    static func windowURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).window") }
    static let windowNote = Notification.Name("local.usage-n-uf.docktile-window")

    /// The agent's word on the window (a capped read: the plug-in reads it in the Dock's process). No word: closed.
    static func windowOpen(_ id: String) -> Bool {
        SafeRead.whole(windowURL(id).path, max: 16).map { String(decoding: $0, as: UTF8.self).hasPrefix("1") } ?? false
    }

    /// The agent's write, only when it changed, with the notice.
    static func setWindowOpen(_ id: String, _ open: Bool) {
        guard windowOpen(id) != open || !FileManager.default.fileExists(atPath: windowURL(id).path) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data((open ? "1" : "0").utf8).write(to: windowURL(id), options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(windowNote, object: id, userInfo: nil, deliverImmediately: true)
    }
}

// MARK: - the agent's rule for a Dock icon app while the Dock draws its tile

/// Whether a profile's Dock icon app should run, now that the Dock draws its tile through the plug-in (the heartbeat says
/// it does): the app no longer runs to show the usage, only when you start it. Without a heartbeat it is opened once
/// (macOS lets the Dock use a copy's plug-in once the copy has run), and if the Dock still draws no tile (Dock Tiles turned
/// off in System Settings ▸ Login Items & Extensions, an older macOS, a plug-in that fails) the profile's Dock icon app
/// runs as before, for the rest of the agent's run. The agent (Rules.swift) asks this every 30 s.
enum TileRule {
    /// A heartbeat this recent: the Dock draws the tile (the plug-in draws at least every 30 s).
    static let fresh: TimeInterval = 90
    /// No heartbeat this long after the copy was ready (the agent started, it was pinned, opened or quit): the Dock doesn't.
    static let patience: TimeInterval = 60

    struct Facts: Equatable {
        var pinned: Bool                // in the Dock
        var running: Bool
        var ours: Bool                  // running because the agent started it (or it ran when the agent started), not a click
        var beatAge: TimeInterval?      // since its last heartbeat; nil: none
        var waited: TimeInterval        // since the copy was last ready to be drawn
        var failed: Bool                // the Dock drew no tile for it in this run of the agent
    }
    enum Act: Equatable {
        case none
        case quit           // the Dock draws the tile: the app the agent started quits (its window left alone)
        case openOnce       // no tile yet: opened once (in the background, its window left alone) so the Dock may use it
        case asBefore       // still no tile: the Dock icon app runs as it did before tiles, for this run of the agent
    }

    static func decide(_ f: Facts) -> Act {
        guard !f.failed, f.pinned else { return .none }
        let drawn = (f.beatAge ?? .infinity) < fresh
        if f.running {
            if drawn { return f.ours ? .quit : .none }
            return f.ours && f.waited >= patience ? .asBefore : .none
        }
        if drawn || f.waited < patience { return .none }
        return .openOnce
    }
}

extension TileModel {
    /// A profile's Dock icon face from its one value (ProfileShow): the Dock icon app and the Dock tile plug-in draw this.
    /// Grey for old numbers or none (ProfileDisplay.grey), the warning for a sign-in on another account, the countdown
    /// for the full limit that holds the profile back (none once its reset has passed).
    static func face(_ e: AccountEntry, _ show: ProfileShow, windowOpen: Bool, now: Date = Date()) -> TileModel {
        let d = show.display, u = show.usage
        return TileModel(label: Account.label(e), fiveHour: u?.fiveHour, weekly: u?.weekly,
                         stale: d.grey, style: e.style, warn: d.otherAccount,
                         tint: e.color, frame: e.frame,
                         fiveHourElapsed: windowElapsed(u?.fiveHourResets, 5 * 3600),
                         weeklyElapsed: windowElapsed(u?.weeklyResets, 7 * 86400), windowOpen: windowOpen && e.windowDot,
                         countdown: AtLimit.tileCountdown(d.full(now: now)))
    }
}
