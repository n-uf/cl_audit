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

    /// A profile id as a file name may carry it (letters, digits, - and _ only), else nil: the plug-in reads it from a copy's
    /// Info.plist, and names its heartbeat and log by it.
    static func plainID(_ id: String) -> String? {
        !id.isEmpty && id.count <= 128 && id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) ? id : nil
    }

    static var folder: URL { Store.folder.appendingPathComponent("docktile") }
    static func beatURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).beat") }
    static func logURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).log") }

    /// When the Dock last drew the profile's tile through the plug-in, or nil.
    static func lastBeat(_ id: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: beatURL(id).path))?[.modificationDate] as? Date
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
