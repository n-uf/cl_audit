import Foundation
import ProfileCore

// The Dock tile plug-in's shared parts (DockTile/Plugin.swift is the plug-in): its name in an app, the class name each
// profile's copy registers, and its heartbeat and log in the agent's folder (docktile/<id>.beat, docktile/<id>.log).
// The heartbeat is the file the plug-in writes each time the Dock draws a profile's tile through it.
// The plug-in compiles this file on its own (build.sh: the plug-in's sources): Foundation, ProfileCore and AppPlaces only.

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

    static var folder: URL { AppPlaces.folder.appendingPathComponent("docktile") }
    static func beatURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).beat") }
    static func logURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).log") }

    /// A profile's heartbeat, log and window word go with its Dock icon app (or the profile): an old heartbeat would
    /// otherwise read as the Dock drawing a new copy's tile.
    static func forget(_ id: String) {
        guard plainID(id) != nil else { return }
        for u in [beatURL(id), logURL(id), logURL(id).appendingPathExtension("1"), windowURL(id)] { try? FileManager.default.removeItem(at: u) }
    }

    // (the heartbeat's reading, the agent's rule and the app's bridges: DockTileApps.swift)

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

// (the Dock icon's right-click menu, the app's and the tile's: DockTileMenu, Sources/DockMenu.swift)

extension DockTile {
    /// The Dock tile plug-in's menu asks the agent (DockTileMenu.object).
    static let menuNote = Notification.Name("local.usage-n-uf.docktile-menu")

    /// The agent's mark says it runs and listens: written within three of its beats (a few seconds' clock step allowed),
    /// not paused after crashes (it hears nothing then). A capped read: the plug-in asks it in the Dock's process, where it
    /// can't look at other processes.
    static func agentRuns(now: Date = Date()) -> Bool {
        guard let data = SafeRead.whole(AppPlaces.agentMarkURL.path, max: SafeRead.recordMax) else { return false }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        guard let m = try? dec.decode(MarkBeat.self, from: data) else { return false }
        let age = now.timeIntervalSince(m.beat)
        return age >= -5 && age < AppPlaces.agentBeatSeconds * 3 && (m.pausedUntil.map { $0 <= now } ?? true)
    }

    /// The two fields of the agent's mark (AgentMark, Agent.swift) this asks, by AgentMark's own names: when it last beat, and
    /// until when it waits after crashes. Checks/docktile writes an AgentMark and reads it back through this.
    private struct MarkBeat: Decodable { var beat: Date; var pausedUntil: Date? }
}

// (the heartbeat's reading, TileTracker and the bridges from AccountEntry: DockTileApps.swift)
