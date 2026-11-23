import AppKit
import ProfileCore

// A profile's Dock icon drawn by the Dock itself (an NSDockTilePlugIn, macOS's Dock tile plug-in), from what the cl_audit
// agent saved for the profile. It only draws: it reads the profile list (accounts.json, not tidied or saved) and this
// profile's own record (status/<id>.json), each a capped read of a regular file; never a sign-in, the Keychain, the network,
// a program or a standby account's record. Each time it draws it writes the profile's heartbeat (DockTile.beatURL), so the
// agent can tell the Dock draws the tile.
//
// The Dock runs every third-party plug-in in one shared process (com.apple.dock.external.extra): nothing here may trap or
// block, or the other apps' tiles go down with it. And one class name would stand for every copy there, so each copy
// registers its own subclass when it is loaded (docktile_load.c calls `cl_audit_docktile_loaded`), under the name its
// Info.plist gives (DockTile.className: per profile and build), and keeps its profile and build in its own statics.

@objc(ClAuditDockTileBase)
class DockTilePlugIn: NSObject, NSDockTilePlugIn {
    /// This copy's plug-in bundle (each loaded copy has its own), from the path dyld loaded it from.
    nonisolated(unsafe) static var bundle: URL?
    /// The profile and the build this copy was loaded as (its Info.plist then): the code running is that build's, for that
    /// profile, wherever the copy is moved or whatever replaces it later.
    nonisolated(unsafe) static var profileID: String?
    nonisolated(unsafe) static var loadedBuild: String?

    private var tile: NSDockTile?
    private var view: TileView?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var draws = 0
    /// The menu last given to the Dock (dockMenu): kept, its items too, until the next one. A click comes back later, and
    /// the Dock's process looks its item up in this very menu: an unkept one was freed by then, and the click crashed that
    /// process (seen live in 26.11.82).
    private(set) var shownMenu: NSMenu?
    /// Another build seen in the copy, and when first: it must still be there 10 s later (an install is done by then).
    private var newBuild: (build: String, seen: Date)?

    private var id: String? { Self.profileID }
    private var build: String { Self.loadedBuild ?? "?" }

    func setDockTile(_ dockTile: NSDockTile?) {
        timer?.invalidate(); timer = nil
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }; observers = []
        guard let dockTile else {
            log("released")
            tile = nil; view = nil
            return
        }
        tile = dockTile
        log("loaded build \(build) in \(ProcessInfo.processInfo.processName) pid \(getpid()), tile \(dockTile.size)")
        let v = TileView(model: face() ?? Self.unknown)
        v.frame = NSRect(origin: .zero, size: dockTile.size)
        view = v
        dockTile.contentView = v
        draw("load")
        // again when the agent saves this profile's record or the profiles or apps change, and every 30 s (the age turns
        // grey, the countdown runs), as the Dock icon app does
        let center = DistributedNotificationCenter.default()
        // (a burst of notices is one redraw, half a second after its first: a storm never reaches the Dock's process)
        observers.append(center.addObserver(forName: AppPlaces.statusChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object == nil || note.object as? String == self.id else { return }
            self.soon("record")
        })
        observers.append(center.addObserver(forName: AppPlaces.configChanged, object: nil, queue: .main) { [weak self] _ in self?.soon("profiles") })
        observers.append(center.addObserver(forName: AppPlaces.appsChanged, object: nil, queue: .main) { [weak self] _ in self?.soon("apps") })
        observers.append(center.addObserver(forName: DockTile.windowNote, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? String == self.id else { return }
            self.soon("window")
        })
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.redraw("timer") }
    }

    /// The right-click menu while the Dock icon app isn't running (DockTileMenu.dockRows): the profile, the Claude window and
    /// the actions, each a notice (the plug-in starts nothing itself). No record is read: the menu shows no account, number
    /// or state. No menu without a profile.
    func dockMenu() -> NSMenu? {
        guard let id, let p = PluginProfile.load(id) else { return nil }
        let rows = DockTileMenu.dockRows(p, windowOpen: DockTile.windowOpen(id), agentRuns: DockTile.agentRuns())
        // plain titles: the Dock draws the menu and leaves out an item's view (and its rows hold no address). Each item its
        // own tag (DockTileMenu.tag): the Dock hands a click back as the item's tag (_sendDockMenuCommand:withTag:)
        let m = DockTileMenu.menu(rows, light: TileColor.lamp(p.ownColor).color, target: self, action: #selector(picked(_:)))
        log("menu asked")
        shownMenu = m           // kept until the next ask (shownMenu)
        return m
    }

    /// A menu action: Quick chat and Refresh now as their notices; the rest to the agent.
    @objc func picked(_ sender: NSMenuItem) {
        // (a switch's target is the Switch page's key, "<profile>~<standby>": only this profile's own)
        guard let id, let (act, target) = DockTileMenu.parse(sender.representedObject),
              DockTileMenu.profile(act, target) == id else { return }
        let center = DistributedNotificationCenter.default()
        switch act {
        case .quickChat: center.postNotificationName(AppPlaces.quickChatOpen, object: id, userInfo: nil, deliverImmediately: true)
        case .refresh: center.postNotificationName(AppPlaces.refreshAll, object: id, userInfo: nil, deliverImmediately: true)
        default: center.postNotificationName(DockTile.menuNote, object: DockTileMenu.object(act, target), userInfo: nil, deliverImmediately: true)
        }
        log("menu: \(act.rawValue)")
    }

    /// An update replaced the copy with another build: the code running here is the old one, and the Dock loads the new one
    /// only in a new process. So this one ends (the Dock starts it again), once the copy and its app both say the new build
    /// and still do 10 s later (an install writes the plug-in's Info.plist before the app's and signs both after). A copy
    /// that's gone or half-written doesn't count.
    private func leaveIfUpdated() {
        // (loaded while an install was writing the copy: no build then; the finished copy's build makes it leave)
        guard let bundle = Self.bundle else { return }
        let loaded = Self.loadedBuild ?? ""
        let app = bundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func build(_ url: URL) -> String? {
            SafeRead.whole(url.appendingPathComponent("Contents/Info.plist").path, max: SafeRead.recordMax)
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }?["UsageBuild"] as? String
        }
        guard let now = build(bundle), now != loaded, build(app) == now else { newBuild = nil; return }
        guard let seen = newBuild, seen.build == now else {
            newBuild = (now, Date())
            DispatchQueue.main.asyncAfter(deadline: .now() + 11) { [weak self] in self?.redraw("update") }
            return
        }
        guard Date().timeIntervalSince(seen.seen) >= 10 else { return }
        log("the copy is now build \(now): leaving so the Dock loads it")
        exit(0)
    }

    /// A redraw for a notice, half a second from the first of a burst: the ones after it within that time join it.
    private var redrawSoon = false
    private func soon(_ why: String) {
        guard !redrawSoon else { return }
        redrawSoon = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.redrawSoon = false
            self?.redraw(why)
        }
    }

    /// A new face from the saved record (the notices and the timer; the docktile checks call it for the timer).
    func redraw(_ why: String) {
        leaveIfUpdated()
        guard let view else { return }
        if let m = face() { view.model = m }
        draw(why)
    }

    /// Shows the view's face and writes the heartbeat.
    private func draw(_ why: String) {
        guard let tile, let id else { return }
        tile.display()
        draws += 1
        let line = "\(ISO8601DateFormatter().string(from: Date())) build \(build) pid \(getpid()) draw \(draws)\n"
        try? FileManager.default.createDirectory(at: DockTile.folder, withIntermediateDirectories: true)
        try? Data(line.utf8).write(to: DockTile.beatURL(id), options: .atomic)
        log("drew (\(why)) #\(draws): \(view.map { ($0.model.fiveHour == nil && $0.model.weekly == nil ? "no numbers" : $0.model.stale ? "grey" : "numbers") + ($0.model.windowOpen ? " · window" : "") } ?? "-")")
    }

    /// The profile's face now, or nil when its entry can't be read (the last face stays). Capped reads of regular files only
    /// (SafeRead: a FIFO, a device or a huge file is no answer), never a wait.
    private func face() -> TileModel? {
        guard let id, let p = PluginProfile.load(id) else { return nil }
        // the record through ProfileCore's display (PluginProfile.swift); the open dot from the agent's word on the window
        // (DockTile.windowOpen)
        return TileModel.face(p, record: PluginProfile.record(id), windowOpen: DockTile.windowOpen(id))
    }

    private static let unknown = TileModel(label: "?", fiveHour: nil, weekly: nil, stale: true, style: .bars)

    /// One line in the profile's plug-in log (DockTile.logURL), kept under 256 KB (the older part goes to <id>.log.1).
    /// Written with plain calls on a regular file opened non-blocking (never a FIFO or a link, never an exception).
    private func log(_ s: String) {
        guard let id else { return }
        let url = DockTile.logURL(id), fm = FileManager.default
        try? fm.createDirectory(at: DockTile.folder, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 256 << 10 {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return }
        let line = Array("\(ISO8601DateFormatter().string(from: Date())) \(s)\n".utf8)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

/// Called once per loaded copy, by its load-time function (docktile_load.c), with the path of its executable: notes the
/// copy's bundle, profile and build, and registers the subclass its Info.plist names, so macOS creates this copy's class and
/// no other's.
@_cdecl("cl_audit_docktile_loaded")
func docktileLoaded(_ image: UnsafePointer<CChar>) {
    // <bundle>/Contents/MacOS/<executable>
    let bundle = URL(fileURLWithPath: String(cString: image)).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    DockTilePlugIn.bundle = bundle
    let info = SafeRead.whole(bundle.appendingPathComponent("Contents/Info.plist").path, max: SafeRead.recordMax)
        .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    DockTilePlugIn.profileID = (info?["UsageAccountID"] as? String).flatMap(DockTile.plainID)
    DockTilePlugIn.loadedBuild = info?["UsageBuild"] as? String
    guard let name = info?["NSPrincipalClass"] as? String, name != DockTile.baseClass, NSClassFromString(name) == nil,
          let cls = objc_allocateClassPair(DockTilePlugIn.self, name, 0) else { return }
    objc_registerClassPair(cls)
}
