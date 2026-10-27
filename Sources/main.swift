import AppKit

// Command-line modes, used by build.sh and for checking icon styles:
//   --sync                       install/update one icon app per account in accounts.json, then exit
//   --render-iconset DIR LABEL   write the static icon as an .iconset folder
//   --render-app-iconset DIR [STYLE]   the app's own icon (AppIcon.swift) as an .iconset folder
//   --render-app-icon OUT.png STYLE [PIXELS [PLATE DISPLAY KEYS SLOT]]   one app icon design (the last four: Front panel's look)
//   --render-preview OUT.png STYLE LABEL FIVEHOUR WEEKLY [COLOR [FRAME]]   one sample icon
//   --agent-status | --agent-register | --agent-unregister   the cl_audit agent's background item, for checking

let args = CommandLine.arguments

if args.count >= 2, args[1] == "--sync" {
    guard Store.exists else {
        print("No accounts yet: open “cl_audit” to add them.")
        exit(0)
    }
    DockWriter.inline = true             // the Dock is changed before this run ends
    let log = Installer.sync(Store.load())
    print(log.isEmpty ? "icons are up to date" : log.joined(separator: "\n"))
    print(Agent.ensureRunning())
    exit(0)
}

if args.count >= 3, args[1] == "--pin" {
    // --pin APP [NEIGHBOUR|-] : pin an app in the Dock (used when a hidden cl_usage is shown again)
    DockWriter.inline = true
    DockManager.pinFromHelper(URL(fileURLWithPath: args[2]), after: args.count > 3 && args[3] != "-" ? args[3] : nil)
    exit(0)
}

if args.count >= 3, args[1] == "--render-iconset" {
    Painter.writeIconset(label: args.count >= 4 ? args[3] : "USAGE", to: URL(fileURLWithPath: args[2]))
    exit(0)
}

if args.count >= 3, args[1] == "--render-app-iconset" {
    AppIcon.writeIconset(args.count >= 4 ? AppIconStyle(rawValue: args[3]) ?? .standard : .standard, to: URL(fileURLWithPath: args[2]))
    exit(0)
}

if args.count >= 4, args[1] == "--render-app-icon" {
    let px = args.count >= 5 ? Int(args[4]) ?? 256 : 256
    var look = PanelLook()   // Front panel's choices: PLATE DISPLAY KEYS SLOT
    if args.count >= 6, let v = PanelPlate(rawValue: args[5]) { look.plate = v }
    if args.count >= 7, let v = PanelDisplay(rawValue: args[6]) { look.display = v }
    if args.count >= 8, let v = PanelKeys(rawValue: args[7]) { look.keys = v }
    if args.count >= 9, let v = PanelSlot(rawValue: args[8]) { look.slot = v }
    try? AppIcon.png(AppIconStyle(rawValue: args[3]) ?? .standard, look: look, pixels: px)?.write(to: URL(fileURLWithPath: args[2]))
    exit(0)
}

if args.count >= 7, args[1] == "--render-preview" {
    let m = TileModel(label: args[4], fiveHour: Double(args[5]), weekly: Double(args[6]), stale: false,
                      style: IconStyle(rawValue: args[3]) ?? .bars,
                      tint: args.count >= 8 ? TileColor(rawValue: args[7]) ?? .orange : .orange,
                      frame: args.count >= 9 ? TileColor(rawValue: args[8]) : nil,
                      fiveHourElapsed: 45, weeklyElapsed: 60)
    try? Painter.png(m, pixels: 256)?.write(to: URL(fileURLWithPath: args[2]))
    exit(0)
}

if args.count >= 4, args[1] == "--render-panel" {
    // --render-panel OUT.png DESIGN [large] : a sample panel on a dark background, for checking designs.
    if #available(macOS 14, *) {
        MainActor.assumeIsolated {
            DetailsController.renderSample(to: args[2], design: PanelDesign(rawValue: args[3]) ?? .glow,
                                           large: args.count >= 5 && args[4] == "large")
        }
    }
    exit(0)
}

if args.count >= 3, args[1] == "--render-settings" {
    if #available(macOS 14, *) { MainActor.assumeIsolated { ManagerUI.renderSample(to: args[2], main: true, settingsPage: true) } }
    exit(0)
}

if args.count >= 4, args[1] == "--render-launcher" {
    if #available(macOS 14, *) { MainActor.assumeIsolated { ManagerUI.renderSample(to: args[2], main: args[3] == "main") } }
    exit(0)
}

if args.count >= 2, args[1] == "--agent-status" {
    // the agent's login item and its alive mark, for checking
    let m = Agent.readMark()
    print("background item: \(Agent.statusText(Agent.service.status))")
    if let m {
        print("mark: pid \(m.pid), build \(m.build), started \(Int(-m.started.timeIntervalSinceNow)) s ago, beat \(Int(-m.beat.timeIntervalSinceNow)) s ago, \(Agent.isAlive(m) ? "alive" : "not alive")")
    } else { print("mark: none") }
    exit(0)
}

if args.count >= 2, args[1] == "--agent-register" {
    do { try Agent.service.register(); print("registered: \(Agent.statusText(Agent.service.status))") }
    catch { print("couldn't register: \(error.localizedDescription) (\((error as NSError).code))") }
    exit(0)
}

if args.count >= 2, args[1] == "--agent-unregister" {
    do { try Agent.service.unregister(); print("unregistered") } catch { print("couldn't unregister: \(error.localizedDescription)") }
    exit(0)
}

// Three roles: the agent (the helper inside cl_audit.app), a profile's Dock icon (UsageAccountID in its
// Info.plist) and cl_audit itself.
let app = NSApplication.shared
let delegate: NSApplicationDelegate = Agent.isAgent ? AgentDelegate() : AppDelegate()
app.delegate = delegate
app.run()
