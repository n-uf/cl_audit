import AppKit
import ProfileCore

// A profile's Dock icon drawn by the Dock itself (an NSDockTilePlugIn, macOS's Dock tile plug-in), from what the cl_audit
// agent saved for the profile. It only draws: it reads the profile list (accounts.json, not tidied or saved) and this
// profile's own record (status/<id>.json); never a sign-in, the Keychain, the network or a standby account's record.
// Each time it draws it writes the profile's heartbeat (DockTile.beatURL), so the agent can tell the Dock draws the tile.
//
// Every Dock icon app carries its own copy (Installer.install), and the Dock may load several into one process, where
// one class name would stand for all of them. So each copy registers its own subclass when it is loaded (docktile_load.c
// calls `cl_audit_docktile_loaded`), under the name its Info.plist gives (DockTile.className: per profile and build).

@objc(ClAuditDockTileBase)
class DockTilePlugIn: NSObject, NSDockTilePlugIn {
    /// This copy's plug-in bundle (each loaded copy has its own), from the path dyld loaded it from.
    nonisolated(unsafe) static var bundle: URL?
    /// The build this copy was loaded as (its Info.plist's UsageBuild then): the code running is that build's.
    nonisolated(unsafe) static var loadedBuild: String?

    private var tile: NSDockTile?
    private var view: TileView?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var id: String?
    private var build = "?"
    private var draws = 0

    func setDockTile(_ dockTile: NSDockTile?) {
        timer?.invalidate(); timer = nil
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }; observers = []
        guard let dockTile else {
            log("released")
            tile = nil; view = nil
            return
        }
        tile = dockTile
        let info = Self.bundle.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) }
        id = info?["UsageAccountID"] as? String
        build = Self.loadedBuild ?? "?"
        log("loaded build \(build) in \(ProcessInfo.processInfo.processName) pid \(getpid()), tile \(Int(dockTile.size.width))×\(Int(dockTile.size.height))")
        let v = TileView(model: face() ?? Self.unknown)
        v.frame = NSRect(origin: .zero, size: dockTile.size)
        view = v
        dockTile.contentView = v
        draw("load")
        // again when the agent saves this profile's record or the profiles change, and every 30 s (the age turns grey,
        // the countdown runs), as the Dock icon app does
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Store.statusChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object == nil || note.object as? String == self.id else { return }
            self.redraw("record")
        })
        observers.append(center.addObserver(forName: Store.changed, object: nil, queue: .main) { [weak self] _ in self?.redraw("profiles") })
        observers.append(center.addObserver(forName: Installer.appsChangedNote, object: nil, queue: .main) { [weak self] _ in self?.redraw("apps") })
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.redraw("timer") }
    }

    /// An update replaced the copy with another build: the code running here is the old one, and the Dock loads the new
    /// one only in a new process. So this one ends (the Dock starts it again); a copy that's gone or half-written doesn't.
    private func leaveIfUpdated() {
        guard let loaded = Self.loadedBuild, let bundle = Self.bundle,
              let now = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["UsageBuild"] as? String,
              now != loaded else { return }
        log("the copy is now build \(now): leaving so the Dock loads it")
        exit(0)
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
        log("drew (\(why)) #\(draws): \(view.map { $0.model.fiveHour == nil && $0.model.weekly == nil ? "no numbers" : $0.model.stale ? "grey" : "numbers" } ?? "-")")
    }

    /// The profile's face now, or nil when its entry can't be read (the last face stays).
    private func face() -> TileModel? {
        guard let id, let e = Store.loadRaw()?.first(where: { $0.id == id }) else { return nil }
        return TileModel.face(e, ProfileShow.load(e), windowOpen: false)
    }

    private static let unknown = TileModel(label: "?", fiveHour: nil, weekly: nil, stale: true, style: .bars)

    /// One line in the profile's plug-in log (DockTile.logURL), kept under 256 KB (the older half goes to <id>.log.1).
    private func log(_ s: String) {
        guard let id else { return }
        let url = DockTile.logURL(id), fm = FileManager.default
        try? fm.createDirectory(at: DockTile.folder, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 256 << 10 {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(s)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }
}

/// Called once per loaded copy, by its load-time function (docktile_load.c), with the path of its executable: notes the
/// copy's bundle and registers the subclass its Info.plist names, so macOS creates this copy's class and no other's.
@_cdecl("cl_audit_docktile_loaded")
func docktileLoaded(_ image: UnsafePointer<CChar>) {
    // <bundle>/Contents/MacOS/<executable>
    let bundle = URL(fileURLWithPath: String(cString: image)).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    DockTilePlugIn.bundle = bundle
    let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
    DockTilePlugIn.loadedBuild = info?["UsageBuild"] as? String
    guard let info, let name = info["NSPrincipalClass"] as? String, name != DockTile.baseClass, NSClassFromString(name) == nil,
          let cls = objc_allocateClassPair(DockTilePlugIn.self, name, 0) else { return }
    objc_registerClassPair(cls)
}
