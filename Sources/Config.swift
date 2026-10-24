// Config: the account list every icon reads, the status each icon reports back, and the installer
// that keeps one icon app per account in /Applications.
//
//   ~/Library/Application Support/usage-n-uf/accounts.json   the accounts (edited by the settings window)
//   ~/Library/Application Support/usage-n-uf/status/<id>.json what each icon last saw (no secrets)
//
// The settings app ("cl_audit") has no account of its own. Each icon app is a copy of it whose
// Info.plist carries UsageAccountID, so it knows which entry of accounts.json it shows.

import AppKit
import CryptoKit

/// What a plain click on the Dock icon does. Double-click or ⌥-click always shows the full details.
enum ClickAction: String, Codable, CaseIterable, Identifiable {
    case peekThenOpen, open, details
    var id: String { rawValue }
    var title: String {
        switch self {
        case .peekThenOpen: return "Shows usage briefly and opens Claude"
        case .open: return "Opens Claude"
        case .details: return "Shows the details panel"
        }
    }
}

/// How a profile's cl_usage and its Claude window open and close: on their own, one following the other
/// (one-way), or both following each other (lockstep, two-way).
enum Lifecycle: String, Codable, CaseIterable {
    case independent, usageFollows, windowFollows, lockstep
    /// The Claude window opens or quits → cl_usage starts or quits.
    var usageFollowsWindow: Bool { self == .usageFollows || self == .lockstep }
    /// cl_usage starts or quits → its Claude window opens or quits.
    var windowFollowsUsage: Bool { self == .windowFollows || self == .lockstep }
}

enum DesktopMode: String, Codable, CaseIterable, Identifiable {
    case standard, separate, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "Standard Claude window"
        case .separate: return "Separate Claude window"
        case .none: return "Nothing"
        }
    }
}

struct AccountEntry: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var label: String
    var configDir: String
    var desktop: DesktopMode = .standard
    var desktopDataDir: String = ""
    var style: IconStyle = .bars
    var pollMinutes: Int = 5
    var notify: Bool = true
    var notifyPercent: Int = 90
    var openAtLogin: Bool = true
    var autoRenew: Bool = false
    var color: TileColor = .orange
    var frame: TileColor? = nil      // nil = no frame (the default)
    var accent: TileColor? = nil     // the account's own colour; nil = see accentColor
    var clickAction: ClickAction = .peekThenOpen
    var peekSeconds: Double = 3
    var longPressDetails: Bool = true    // press-and-hold shows the details panel
    var panelDesign: PanelDesign = .glow
    var windowDot: Bool = true           // the icon shows a dot while this account's Claude window is open
    var iconHidden: Bool = false         // cl_usage runs without a Dock tile (still refreshes and alerts)
    var lifecycle: Lifecycle = .independent   // how cl_usage and its Claude window open and close together

    init(id: String, name: String, label: String, configDir: String) {
        self.id = id; self.name = name; self.label = label; self.configDir = configDir
    }

    enum CodingKeys: String, CodingKey {
        case id, name, label, configDir, desktop, desktopDataDir, style, pollMinutes, notify, notifyPercent, openAtLogin, autoRenew, color, frame, accent, clickAction, peekSeconds, longPressDetails, panelDesign, windowDot, iconHidden, lifecycle
    }
    private enum LegacyKeys: String, CodingKey { case clickShowsDetails }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? String(id.uppercased().prefix(6))
        configDir = try c.decodeIfPresent(String.self, forKey: .configDir) ?? "~/.claude"
        desktop = try c.decodeIfPresent(DesktopMode.self, forKey: .desktop) ?? .standard
        desktopDataDir = try c.decodeIfPresent(String.self, forKey: .desktopDataDir) ?? ""
        style = try c.decodeIfPresent(IconStyle.self, forKey: .style) ?? .bars
        pollMinutes = try c.decodeIfPresent(Int.self, forKey: .pollMinutes) ?? 5
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true
        notifyPercent = try c.decodeIfPresent(Int.self, forKey: .notifyPercent) ?? 90
        openAtLogin = try c.decodeIfPresent(Bool.self, forKey: .openAtLogin) ?? true
        autoRenew = try c.decodeIfPresent(Bool.self, forKey: .autoRenew) ?? false
        color = try c.decodeIfPresent(TileColor.self, forKey: .color) ?? .orange
        frame = try c.decodeIfPresent(TileColor.self, forKey: .frame)
        accent = try c.decodeIfPresent(TileColor.self, forKey: .accent)
        peekSeconds = try c.decodeIfPresent(Double.self, forKey: .peekSeconds) ?? 3
        longPressDetails = try c.decodeIfPresent(Bool.self, forKey: .longPressDetails) ?? true
        panelDesign = try c.decodeIfPresent(PanelDesign.self, forKey: .panelDesign) ?? .glow
        windowDot = try c.decodeIfPresent(Bool.self, forKey: .windowDot) ?? true
        iconHidden = try c.decodeIfPresent(Bool.self, forKey: .iconHidden) ?? false
        lifecycle = try c.decodeIfPresent(Lifecycle.self, forKey: .lifecycle) ?? .independent
        if let action = try c.decodeIfPresent(ClickAction.self, forKey: .clickAction) {
            clickAction = action
        } else if let legacy = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Bool.self, forKey: .clickShowsDetails) {
            clickAction = legacy ? .details : .open
        }
    }

    /// What's wrong with this entry, if anything, in words for the settings window.
    /// The account's colour in the launcher, the dashboard (chips, cards, charts) and the panels.
    /// Unset: the icon colour when it's a plain one, else orange.
    var accentColor: TileColor { accent ?? ([.usage, .graphite].contains(color) ? .orange : color) }
    var accentNSColor: NSColor { accentColor.color(fiveHour: nil, stale: false) }

    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the profile a name." }
        if name.contains("/") || name.contains(":") { return "The name can't contain / or :." }
        if label.isEmpty { return "Give the icon a label." }
        if configDir.isEmpty { return "Pick a Claude Code settings folder." }
        if desktop == .separate && desktopDataDir.isEmpty { return "Pick a data folder for the separate Claude window." }
        return nil
    }
}

/// The compact panel's duration: quarter seconds up to 3 s, whole seconds above.
enum PeekDuration {
    static let range: ClosedRange<Double> = 0.25...15
    static func up(_ v: Double) -> Double { min(range.upperBound, v < 3 ? v + 0.25 : v.rounded(.down) + 1) }
    static func down(_ v: Double) -> Double { max(range.lowerBound, v > 3 ? v.rounded(.up) - 1 : v - 0.25) }
    /// "0.75 s", "2 s", "1.5 s".
    static func text(_ v: Double) -> String {
        let s = v == v.rounded() ? "\(Int(v))" : String(format: "%g", v)
        return s + " s"
    }
}

struct ConfigFile: Codable {
    var accounts: [AccountEntry]
}

/// What an icon last saw, for the settings window. No secrets.
struct IconStatus: Codable {
    var loginEmail: String?
    var expectedEmail: String?
    var state: String
    var fiveHour: Double?
    var weekly: Double?
    var updatedAt: Date?
    var renewNote: String?
    var fiveHourResets: Date?
    var weeklyResets: Date?
    var plan: String?
}

// MARK: - Renewing an expired login through Claude Code

/// The icon never refreshes a login itself. When asked to, it runs Claude Code once with a one-line
/// prompt; Claude Code renews its own login as part of that call and stores it as usual.
enum ClaudeCLI {
    static func find() -> String? {
        let fm = FileManager.default
        let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.local/bin/claude",
                          "~/.claude/local/claude", "~/.npm-global/bin/claude", "~/.bun/bin/claude"].map(expand)
        if let p = candidates.first(where: fm.isExecutableFile(atPath:)) { return p }
        // Fall back to the login shell's PATH.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitQuietly()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    /// Opens Terminal on `claude auth login` for the account's settings folder, with the e-mail the folder
    /// is set up for filled in. The person signs in in the browser; nothing here sees the password.
    @discardableResult
    static func openLogin(_ claude: String, account: Account, email: String?) -> Bool {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var lines = ["#!/bin/zsh -l", "clear"]
        lines.append(account.isDefaultDir ? "unset CLAUDE_CONFIG_DIR" : "export CLAUDE_CONFIG_DIR=\(q(account.configDir))")
        lines.append("echo \(q("Signing in to Claude Code for \(tilde(account.configDir))…"))")
        var cmd = "\(q(claude)) auth login --claudeai"
        if let email { cmd += " --email \(q(email))" }
        lines += [cmd, "echo", "echo 'Done. The usage icon picks up the new login on its next refresh (or right-click ▸ Refresh now).'"]
        let file = loginScript(account.configDir)
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch { return false }
        return Installer.run("/usr/bin/open", ["-a", "Terminal", file.path]) == 0
    }

    /// Signs out the Claude Code login of a settings folder (`claude auth logout`), which also removes its
    /// Keychain item. Blocks; call off the main thread.
    @discardableResult
    static func logout(_ claude: String, configDir: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = ["auth", "logout"]
        var env = ProcessInfo.processInfo.environment
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"] { env[k] = nil }
        env["CLAUDE_CONFIG_DIR"] = expand(configDir)
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitQuietly()
        return p.terminationStatus == 0
    }

    /// The Terminal script `openLogin` writes for a folder.
    static func loginScript(_ configDir: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("usage-n-uf-login-\(Account.sha8(configDir)).command")
    }

    /// Runs `claude -p` for the account's settings folder (Haiku, nothing saved). Blocks; call off the main thread.
    static func renew(_ claude: String, account: Account) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = ["-p", "Reply with OK.", "--model", "haiku", "--no-session-persistence"]
        var env = ProcessInfo.processInfo.environment
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR"] { env[k] = nil }
        if !account.isDefaultDir { env["CLAUDE_CONFIG_DIR"] = account.configDir }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let deadline = Date().addingTimeInterval(120)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        if p.isRunning { p.terminate(); return false }
        return p.terminationStatus == 0
    }
}

enum Store {
    static let folder = URL(fileURLWithPath: expand("~/Library/Application Support/usage-n-uf"))
    static var configURL: URL { folder.appendingPathComponent("accounts.json") }
    static var statusFolder: URL { folder.appendingPathComponent("status") }
    static let changed = Notification.Name("local.usage-n-uf.config-changed")

    static var exists: Bool { FileManager.default.fileExists(atPath: configURL.path) }

    static func load() -> [AccountEntry] {
        guard let data = try? Data(contentsOf: configURL) else { return [] }
        return (try? JSONDecoder().decode(ConfigFile.self, from: data))?.accounts ?? []
    }

    static func save(_ accounts: [AccountEntry]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(ConfigFile(accounts: accounts)).write(to: configURL, options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(changed, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Change one entry and save, keeping the others as they are on disk.
    static func update(_ entry: AccountEntry) {
        var all = load()
        guard let i = all.firstIndex(where: { $0.id == entry.id }) else { return }
        all[i] = entry
        try? save(all)
    }

    static func status(_ id: String) -> IconStatus? {
        guard let data = try? Data(contentsOf: statusFolder.appendingPathComponent("\(id).json")) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(IconStatus.self, from: data)
    }

    static func writeStatus(_ id: String, _ s: IconStatus) -> Data? {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(s) else { return nil }
        try? FileManager.default.createDirectory(at: statusFolder, withIntermediateDirectories: true)
        try? data.write(to: statusFolder.appendingPathComponent("\(id).json"), options: .atomic)
        return data
    }

    static func removeStatus(_ id: String) {
        try? FileManager.default.removeItem(at: statusFolder.appendingPathComponent("\(id).json"))
    }

    /// A short id for a new account, unique among `taken`.
    static func newID(from name: String, taken: [String]) -> String {
        let base = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
        let root = base.isEmpty ? "account" : base
        var id = root, n = 2
        while taken.contains(id) { id = "\(root)-\(n)"; n += 1 }
        return id
    }
}

// MARK: - Finding folders for the settings window

struct FolderChoice: Hashable {
    var path: String       // as stored, with ~
    var detail: String?    // e.g. the account e-mail
    var title: String { detail.map { "\(path)  ·  \(Privacy.masked($0))" } ?? path }
}

enum Detect {
    /// Claude Code settings folders: ~/.claude plus any ~/.claude* folder, with the account each is set up for.
    static func configFolders() -> [FolderChoice] {
        let home = NSHomeDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        var dirs = ["~/.claude"]
        for n in names.sorted() where n.hasPrefix(".claude") && n != ".claude" {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: "\(home)/\(n)", isDirectory: &isDir), isDir.boolValue {
                dirs.append("~/\(n)")
            }
        }
        return dirs.map { FolderChoice(path: $0, detail: Account.expectedEmail(configDir: $0)) }
    }

    /// Claude desktop data folders other than the standard one ("Claude-…" in Application Support).
    static func desktopDataFolders() -> [FolderChoice] {
        let support = expand("~/Library/Application Support")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: support)) ?? []
        return names.sorted()
            .filter { $0.hasPrefix("Claude-") && $0 != "Claude-3p" }
            .map { FolderChoice(path: "~/Library/Application Support/\($0)", detail: nil) }
    }
}

// MARK: - Installing one icon app per account

enum Installer {
    static let managerID = "local.usage-n-uf"
    /// /Applications, so Spotlight finds the apps (it skips ~/Applications on some Macs).
    static var appsFolder: URL { URL(fileURLWithPath: "/Applications") }
    /// Where earlier versions installed; copies found there are removed on the next sync.
    static var oldAppsFolders: [URL] { [URL(fileURLWithPath: expand("~/Applications"))] }

    static func appURL(_ e: AccountEntry) -> URL {
        appsFolder.appendingPathComponent("cl_audit \(e.name.trimmingCharacters(in: .whitespaces)).app")
    }

    static func bundleID(_ e: AccountEntry) -> String { "\(managerID).\(e.id)" }

    static func info(_ app: URL) -> NSDictionary? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    }

    /// Icon apps already installed (here or in an old location), by the account id in their Info.plist.
    static func installed() -> [(url: URL, id: String)] {
        let urls = ([appsFolder] + oldAppsFolders).flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }
        return urls.compactMap { u in
            guard u.pathExtension == "app", let id = info(u)?["UsageAccountID"] as? String else { return nil }
            return (u, id)
        }
    }

    /// Make /Applications match the account list: add, update, rename and remove icon apps,
    /// then start the ones that aren't running. `source` is the app to copy (this one).
    @discardableResult
    static func sync(_ accounts: [AccountEntry], source: URL = Bundle.main.bundleURL) -> [String] {
        var log: [String] = []
        let wanted = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, appURL($0).standardizedFileURL) })
        for (url, id) in installed() where wanted[id] != url.standardizedFileURL {
            stop(url)
            try? FileManager.default.removeItem(at: url)
            if wanted[id] == nil {
                // The account is gone: everything macOS and the app kept for it goes too.
                AccountRemoval.purgeApp(id: id, app: url)
            } else {
                // Renamed: the old name's Dock pin and Launch Services record would point at nothing.
                AccountRemoval.unpinFromDock(url)
                run(AccountRemoval.lsregister, ["-u", url.path])
            }
            log.append("removed \(url.deletingPathExtension().lastPathComponent)")
        }
        // Leftovers of accounts removed by earlier versions.
        let live = Set(accounts.map(\.id)).union(installed().map(\.id))
        for id in AccountRemoval.orphanIDs(keeping: live) {
            AccountRemoval.purgeApp(id: id, app: appsFolder.appendingPathComponent("cl_audit \(id).app"))
            log.append("cleaned up \(id)")
        }
        for e in accounts {
            let dst = appURL(e)
            if needsInstall(e, at: dst, source: source) {
                stop(dst)
                do { try install(e, at: dst, source: source); log.append("installed \(dst.deletingPathExtension().lastPathComponent)") }
                catch { log.append("couldn't install \(e.name): \(error.localizedDescription)"); continue }
            }
            // Started in the background and without opening its Claude window ("Window follows" is for you starting
            // it). One that follows its window isn't started while that window is closed.
            if !isRunning(dst), !waitsForWindow(e) { run("/usr/bin/open", ["-g", dst.path, "--args", "--no-follow"]) }
        }
        return log
    }

    /// cl_usage set to follow its Claude window, while that window is closed: it isn't started.
    static func waitsForWindow(_ e: AccountEntry) -> Bool {
        let a = Account(e)
        return e.lifecycle.usageFollowsWindow && a.opensDesktop && !(Launcher.activity(for: [a])[a.configDir]?.desktopOpen ?? false)
    }

    /// A Claude window just started: start the cl_usage of profiles that follow it (cl_audit does this, since a
    /// cl_usage that isn't running can't notice).
    static func startFollowers() {
        for e in Store.load() where e.lifecycle.usageFollowsWindow && !waitsForWindow(e) {
            let dst = appURL(e)
            if FileManager.default.fileExists(atPath: dst.path), !isRunning(dst) { run("/usr/bin/open", ["-g", dst.path, "--args", "--no-follow"]) }
        }
    }

    static func needsInstall(_ e: AccountEntry, at dst: URL, source: URL) -> Bool {
        guard let i = info(dst),
              i["UsageAccountID"] as? String == e.id,
              i["UsageLabel"] as? String == e.label,
              i["UsageColor"] as? String == e.color.rawValue,
              i["UsageFrame"] as? String == (e.frame?.rawValue ?? "none"),
              i["CFBundleIdentifier"] as? String == bundleID(e) else { return true }
        // Signing a copy changes its executable, so copies are matched by the build they were made from.
        return i["UsageBuild"] as? String != buildStamp(source)
    }

    /// A short fingerprint of the app being copied (its executable), stored in each copy's Info.plist.
    static func buildStamp(_ source: URL) -> String {
        guard let data = try? Data(contentsOf: source.appendingPathComponent("Contents/MacOS/UsageDock"),
                                   options: .alwaysMapped) else { return "unknown" }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func install(_ e: AccountEntry, at dst: URL, source: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: appsFolder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: source, to: dst)
        // A downloaded cl_audit carries macOS's download mark, and the copy would too: every Dock icon app
        // would then ask to be allowed in Privacy & Security. The copy is made here, so it isn't a download.
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dst.path])

        let plistURL = dst.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSMutableDictionary(contentsOf: plistURL) else { throw CocoaError(.fileReadCorruptFile) }
        let name = dst.deletingPathExtension().lastPathComponent
        plist["CFBundleIdentifier"] = bundleID(e)
        plist["CFBundleName"] = name
        plist["CFBundleDisplayName"] = name
        plist["UsageAccountID"] = e.id
        plist["UsageLabel"] = e.label
        plist["UsageColor"] = e.color.rawValue
        plist["UsageFrame"] = e.frame?.rawValue ?? "none"
        plist["UsageBuild"] = buildStamp(source)
        try plist.write(to: plistURL)

        let tmp = fm.temporaryDirectory.appendingPathComponent("usage-n-uf-\(e.id).iconset")
        try? fm.removeItem(at: tmp)
        Painter.writeIconset(label: e.label, tint: e.color, frame: e.frame, to: tmp)
        run("/usr/bin/iconutil", ["-c", "icns", "-o", dst.appendingPathComponent("Contents/Resources/AppIcon.icns").path, tmp.path])
        try? fm.removeItem(at: tmp)

        // The copy's Info.plist changed, so its signature must be redone (ad hoc, like the build).
        if run("/usr/bin/codesign", ["--force", "--sign", "-", dst.path]) != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    static func running(_ url: URL) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
    }

    static func isRunning(_ url: URL) -> Bool { !running(url).isEmpty }

    static func stop(_ url: URL) {
        let apps = running(url)
        guard !apps.isEmpty else { return }
        if let id = info(url)?["UsageAccountID"] as? String {
            DistributedNotificationCenter.default().postNotificationName(quietQuitNote, object: id, userInfo: nil, deliverImmediately: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        apps.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    static let openSettingsNote = Notification.Name("local.usage-n-uf.open-settings")
    /// Sent to a cl_usage app (object: its profile id) before cl_audit quits it to reinstall: quit without
    /// taking the Claude window along.
    static let quietQuitNote = Notification.Name("local.usage-n-uf.quiet-quit")
    static let openDashboardNote = Notification.Name("local.usage-n-uf.open-dashboard")
    /// Asks every icon app to fetch its numbers now.
    static let refreshAllNote = Notification.Name("local.usage-n-uf.refresh-all")

    /// Open the dashboard of the "cl_audit" app (it opens on the dashboard when it starts).
    static func openDashboard() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: managerID).first {
            DistributedNotificationCenter.default().postNotificationName(openDashboardNote, object: nil, userInfo: nil,
                                                                         deliverImmediately: true)
            app.activate(options: [])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: managerID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            NSSound.beep()
        }
    }

    /// Open the settings window of the "cl_audit" app (it lives next to the icon apps), on `account`'s page.
    static func openSettings(account: String? = nil) {
        // macOS 14+ lets an app come forward only when the active one hands over.
        if #available(macOS 14, *) { NSApp.yieldActivation(toApplicationWithBundleIdentifier: managerID) }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: managerID).isEmpty {
            DistributedNotificationCenter.default().postNotificationName(openSettingsNote, object: account, userInfo: nil,
                                                                         deliverImmediately: true)
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == managerID }?.activate(options: [])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: managerID) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = ["--settings"] + (account.map { ["--account=\($0)"] } ?? [])
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        } else {
            NSSound.beep()
        }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitQuietly()
        return p.terminationStatus
    }
}
