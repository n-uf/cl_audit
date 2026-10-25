// Launcher: what the "cl_audit" app itself shows.
//   Click on its Dock icon  → the launcher palette: every account with its real icon and mini bars.
//   Press and hold          → the main screen: a card per account plus a summary.
//   Click an account's icon → opens Claude for that account (desktop window).
// Both read the status the icon apps save, so they need no login of their own.

import AppKit
import SwiftUI

// MARK: - Opening Claude for an account

enum Launcher {
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// A process's arguments, read from the kernel (KERN_PROCARGS2). No helper process, so it's safe to call
    /// while SwiftUI draws: waiting for `ps` ran the run loop and redrew windows mid-update, which crashed.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }        // the executable path
        while i < size && buf[i] == 0 { i += 1 }        // its padding
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    static func commandLine(of pid: pid_t) -> String { arguments(of: pid).joined(separator: " ") }

    /// The data folder a running Claude desktop app was started with (nil = the standard window), as one
    /// comparable key. Exact, so "Claude-work" never matches "Claude-work-2".
    static func dataDirKey(of pid: pid_t) -> String {
        let dir = arguments(of: pid).first { $0.hasPrefix("--user-data-dir=") }.map { String($0.dropFirst("--user-data-dir=".count)) }
        return FolderKey.canonical(dir ?? FolderKey.standardDataDir)
    }

    /// The key of the window an account opens (its own data folder, or the standard one).
    static func dataDirKey(of account: Account) -> String {
        FolderKey.canonical(account.claudeUserDataDir ?? FolderKey.standardDataDir)
    }

    /// Whether a running Claude desktop app is this account's window (its own data folder, or the standard one).
    static func isWindow(of account: Account, _ app: NSRunningApplication) -> Bool {
        dataDirKey(of: app.processIdentifier) == dataDirKey(of: account)
    }

    /// Brings the account's Claude window to the front, or starts it.
    static func openClaude(_ account: Account) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID)
        if let app = running.first(where: { isWindow(of: account, $0) }) {
            app.unhide()
            if #available(macOS 14, *) {
                NSApp.yieldActivation(to: app)
                app.activate(from: .current, options: [.activateAllWindows])
            } else {
                app.activate(options: [.activateAllWindows])
            }
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = !running.isEmpty || account.claudeUserDataDir != nil
        if let dir = account.claudeUserDataDir { cfg.arguments = ["--user-data-dir=\(dir)"] }
        if !account.isDefaultDir {
            var env = ProcessInfo.processInfo.environment
            env["CLAUDE_CONFIG_DIR"] = account.configDir
            cfg.environment = env
        }
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
    }

    /// Whether the account's Claude desktop window is running (matched by its data folder).
    struct Activity {
        var desktopOpen = false
    }

    static func activity(for accounts: [Account]) -> [String: Activity] {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID)
        let keys = Set(running.map { dataDirKey(of: $0.processIdentifier) })
        var result: [String: Activity] = [:]
        for a in accounts { result[a.configDir] = Activity(desktopOpen: keys.contains(dataDirKey(of: a))) }
        return result
    }

    /// Opens Terminal running Claude Code with the account's settings folder.
    static func openTerminal(_ account: Account) {
        guard let claude = ClaudeCLI.find() else { NSSound.beep(); return }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let lines = ["#!/bin/zsh -l", "cd ~",
                     account.isDefaultDir ? "unset CLAUDE_CONFIG_DIR" : "export CLAUDE_CONFIG_DIR=\(q(account.configDir))",
                     "exec \(q(claude))"]
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-n-uf-claude-\(Account.sha8(account.configDir)).command")
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch { return }
        Installer.run("/usr/bin/open", ["-a", "Terminal", file.path])
    }
}

// MARK: - Accounts as the launcher shows them

/// Where a profile's Dock icon app is: in the Dock, running but not pinned, hidden (running, no tile), not running,
/// or its app missing.
enum UsageIconState {
    case inDock, notPinned, hidden, notRunning, missing
    var text: String {
        switch self {
        case .inDock: return "in the Dock"
        case .notPinned: return "unpinned"
        case .hidden: return "hidden"
        case .notRunning: return "stopped"
        case .missing: return "missing"
        }
    }
    var color: Color {
        switch self {
        case .inDock: return Color(nsColor: Painter.green)
        case .hidden: return .secondary.opacity(0.5)
        case .notPinned, .notRunning, .missing: return .orange
        }
    }

    static func of(_ e: AccountEntry) -> UsageIconState {
        let app = Installer.appURL(e)
        guard FileManager.default.fileExists(atPath: app.path) else { return .missing }
        guard Installer.isRunning(app) else { return .notRunning }
        if e.iconHidden { return .hidden }
        return DockManager.isPinned(app) ? .inDock : .notPinned
    }
}

struct AccountRow: Identifiable {
    let entry: AccountEntry
    let status: IconStatus?
    var activity = Launcher.Activity()
    var usageIcon: UsageIconState = .inDock
    /// A change cl_audit started and is still waiting for (the switch shows it at once, with a spinner).
    var busy: CardChange?
    /// The window opening or quitting because its Dock icon started or quit (Opening and closing).
    var windowFollowing: CardChange?
    var notice: CardNotice?
    /// Seconds until the Dock icon quits with its window (Opening and closing), or nil.
    var followQuitIn: TimeInterval?
    /// The window just opened and the Dock icon is about to start with it.
    var followStarting = false
    var id: String { entry.id }
    var account: Account { Account(entry) }

    var stale: Bool {
        guard let u = status?.updatedAt else { return true }
        return Date().timeIntervalSince(u) > 3600
    }
    var mismatch: Bool {
        guard let a = status?.loginEmail, let b = status?.expectedEmail else { return false }
        return a.lowercased() != b.lowercased()
    }
    var needsLogin: Bool { mismatch || status?.state == "expired" || status?.state == "noLogin" }
    var fiveHour: Double? { status?.fiveHour }
    var weekly: Double? { status?.weekly }
    /// How close the account is to any limit (the higher of the two).
    var worst: Double? { (fiveHour == nil && weekly == nil) ? nil : max(fiveHour ?? 0, weekly ?? 0) }
    var accent: Color { Color(nsColor: entry.accentNSColor) }

    var icon: NSImage {
        Painter.image(TileModel(label: entry.label.isEmpty ? "?" : entry.label, fiveHour: fiveHour, weekly: weekly,
                                stale: stale, style: entry.style, warn: mismatch, tint: entry.color, frame: entry.frame,
                                fiveHourElapsed: windowElapsed(status?.fiveHourResets, 5 * 3600),
                                weeklyElapsed: windowElapsed(status?.weeklyResets, 7 * 86400),
                                windowOpen: activity.desktopOpen && entry.windowDot && entry.desktop != .none), pixels: 128)
    }

    var limits: [Limit] {
        [Limit(id: "5h", title: "5-hour session", name: "5-hour", p: fiveHour, resets: status?.fiveHourResets, window: 5 * 3600),
         Limit(id: "wk", title: "Week", name: "Week", p: weekly, resets: status?.weeklyResets, window: 7 * 86400)]
    }

    var subtitle: String {
        if mismatch { return "login is a different account" }
        if status?.state == "expired" { return "login expired" }
        if status?.state == "noLogin" { return "no Claude Code login" }
        return status?.loginEmail ?? status?.expectedEmail ?? entry.configDir
    }
}

/// What a card switch is waiting for after a click: the Claude window opening or quitting, the Dock icon app
/// starting or stopping.
enum CardChange: Equatable {
    case opening, quitting, starting, stopping
    var text: String {
        switch self {
        case .opening: return "opening…"
        case .quitting, .stopping: return "quitting…"
        case .starting: return "starting…"
        }
    }
    /// Where the switch points while it waits.
    var target: Bool { self == .opening || self == .starting }
    var isWindow: Bool { self == .opening || self == .quitting }
    /// How long to wait before giving up and showing the real state.
    var limit: TimeInterval {
        switch self {
        case .opening: return 30
        case .quitting: return 5
        case .starting, .stopping: return 12
        }
    }
}

/// What a change that ran out of time left behind.
enum CardNotice { case openFailed, claudeAsking }

final class LauncherModel: ObservableObject {
    @Published var rows: [AccountRow] = []
    @Published var refreshing = false
    @Published var query = ""
    @Published var selected = 0
    /// Accounts left out of the dashboard (cards and history); kept between launches.
    @Published var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "dashboardHidden") ?? []) {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "dashboardHidden"); onHiddenChange?() }
    }
    var onHiddenChange: (() -> Void)?
    var shownRows: [AccountRow] { rows.filter { !hidden.contains($0.id) } }

    func toggle(_ id: String) {
        if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
    }

    func reload() {
        let entries = Store.load()
        let acts = Launcher.activity(for: entries.map(Account.init))
        let now = Date()
        rows = entries.map {
            var r = AccountRow(entry: $0, status: Store.status($0.id), activity: acts[Account($0).configDir] ?? .init(), usageIcon: UsageIconState.of($0))
            settle(&r, now)
            return r
        }
        selected = min(selected, max(filtered.count - 1, 0))
        if pending.isEmpty && windowFollow.isEmpty && followQuit.isEmpty && followStart.isEmpty { fastTimer?.invalidate(); fastTimer = nil }
    }

    // MARK: Changes in progress

    private struct Pending {
        let change: CardChange
        let started = Date()
    }
    private var pending: [String: Pending] = [:]
    private var windowFollow: [String: Pending] = [:]   // the window following a Dock icon that was started or quit
    private var notices: [String: CardNotice] = [:]
    private var followQuit: [String: Date] = [:]     // when the Dock icon quits, following its window
    private var followStart: [String: Date] = [:]    // when the window opened that the Dock icon starts with
    private var lastOpen: [String: Bool] = [:]
    private var fastTimer: Timer?

    /// A card switch was flipped: show the change at once and look every 0.5 s until it is done or out of time.
    func begin(_ id: String, _ change: CardChange) {
        notices[id] = nil
        pending[id] = Pending(change: change)
        // With "open or quit the Claude window too", the window follows the Dock icon: show that on its switch.
        if let r = rows.first(where: { $0.id == id }), r.entry.lifecycle.windowFollowsUsage, r.entry.desktop != .none {
            if change == .starting && !r.activity.desktopOpen { windowFollow[id] = Pending(change: .opening) }
            if change == .stopping && r.activity.desktopOpen { windowFollow[id] = Pending(change: .quitting) }
        }
        reload()
        startFast()
    }

    private func startFast() {
        guard fastTimer == nil else { return }
        fastTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.reload() }
    }

    private func settle(_ r: inout AccountRow, _ now: Date) {
        let id = r.id, e = r.entry
        let open = r.activity.desktopOpen
        let running = r.usageIcon != .notRunning && r.usageIcon != .missing

        // The window opened or quit: with the Dock icon following it, say what comes next.
        if let was = lastOpen[id], was != open, e.lifecycle.usageFollowsWindow, e.desktop != .none {
            if open { followStart[id] = now; followQuit[id] = nil } else { followQuit[id] = now + 10; followStart[id] = nil }
            startFast()
        }
        lastOpen[id] = open

        if let p = pending[id] {
            let done: Bool
            switch p.change {
            case .opening: done = open
            case .quitting: done = !open
            case .starting: done = running
            case .stopping: done = !running
            }
            if !done && now.timeIntervalSince(p.started) > p.change.limit {
                if p.change == .opening { notices[id] = .openFailed }
                if p.change == .quitting { notices[id] = .claudeAsking }
                pending[id] = nil
            } else if done { pending[id] = nil } else { r.busy = p.change }
        }
        if let f = windowFollow[id] {
            // the Dock icon opens its window as it starts, or quits it as it quits; Claude may ask first
            let done = f.change == .opening ? open : !open
            if !done && now.timeIntervalSince(f.started) > (f.change == .opening ? 30 : 8) {
                notices[id] = f.change == .opening ? .openFailed : .claudeAsking
                windowFollow[id] = nil
            } else if done { windowFollow[id] = nil } else { r.windowFollowing = f.change }
        }

        if notices[id] == .openFailed && open { notices[id] = nil }
        if notices[id] == .claudeAsking && !open { notices[id] = nil }
        r.notice = notices[id]

        if let t = followQuit[id] {
            if open || !running || now.timeIntervalSince(t) > 15 { followQuit[id] = nil }
            else { r.followQuitIn = max(0, t.timeIntervalSince(now)) }
        }
        if let t = followStart[id] {
            if !open || running || now.timeIntervalSince(t) > 15 { followStart[id] = nil }
            else { r.followStarting = true }
        }
    }

    var filtered: [AccountRow] {
        query.isEmpty ? rows : rows.filter { $0.entry.name.localizedCaseInsensitiveContains(query) }
    }

    /// Start on the account with the most room left.
    func selectMostRoom() {
        let list = filtered
        if let i = list.indices.min(by: { (list[$0].worst ?? 101) < (list[$1].worst ?? 101) }) { selected = i }
    }
}

struct LauncherActions {
    var open: (AccountRow) -> Void
    var terminal: (AccountRow) -> Void
    var logIn: (AccountRow) -> Void
    var mainScreen: () -> Void
    var settings: () -> Void
    var refresh: () -> Void = {}
    var refreshAll: () -> Void = {}
    var quitWindow: (AccountRow) -> Void = { _ in }
    var showClaude: (AccountRow) -> Void = { _ in }       // bring the running window forward, no change tracked
    var startUsage: (AccountRow) -> Void = { _ in }       // start, or reinstall when the app is missing
    var quitUsage: (AccountRow) -> Void = { _ in }
    var profileSettings: (AccountRow) -> Void = { _ in }
}

/// "Updated 1 min ago": the age of the newest numbers on the dashboard; a click asks every icon to fetch now.
struct UpdatedButton: View {
    @ObservedObject var model: LauncherModel
    let refresh: () -> Void

    var newest: Date? { model.shownRows.compactMap { $0.status?.updatedAt }.max() }
    static let width: CGFloat = 206     // fits "UPDATED · 23 H 59 MIN AGO"

    /// The age in a display window, and a key that refreshes.
    var body: some View {
        HStack(spacing: 6) {
            Group {
                // one width for every text, so nothing next to it moves when it changes
                if model.refreshing { DisplayWindow(text: "Updating…", height: TopStrip.height, width: Self.width) }
                else if let d = newest { DisplayWindow(text: "Updated", dim: "· \(DetailsFormat.ago(d))", height: TopStrip.height, width: Self.width) }
                else { DisplayWindow(text: "Not updated yet", height: TopStrip.height, width: Self.width) }
            }
            Button(action: refresh) {
                KeyLook(height: TopStrip.height, hPad: 0) { Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).frame(width: TopStrip.height) }
            }
                .buttonStyle(PressableKey())
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh now (⌘R)")
        }
    }
}

/// Which accounts the dashboard shows: "Show" followed by a checkbox per account (several can be on).
/// Drawn as a filter, not as account buttons, so it doesn't look like it opens Claude.
struct AccountChips: View {
    @ObservedObject var model: LauncherModel

    @Environment(\.face) private var face

    /// A key per profile; a shown profile's key is latched, its strip lit in the profile's colour.
    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.rows) { row in
                let on = !model.hidden.contains(row.id)
                Button { model.toggle(row.id) } label: {
                    KeyLook(latched: on, lamp: row.accent, height: TopStrip.height, hPad: 11) { Text(row.entry.name) }
                }
                .buttonStyle(PressableKey())
                .help(on ? "Hide \(row.entry.name) from the dashboard" : "Show \(row.entry.name) on the dashboard")
            }
        }
    }
}

/// The top row's sunken strip: on the dashboard the profile keys and the Updated display with its refresh key;
/// in Settings whether everything is saved. Every control 26 pt high on one centre line.
struct TopStrip: View {
    static let height: CGFloat = 26
    @ObservedObject var model: LauncherModel
    var settings: SettingsModel? = nil      // on the Settings page: whether everything is saved
    let dashboard: Bool
    var fill = false              // narrow window: the strip spans its own row, the display at its right end
    let refresh: () -> Void
    @Environment(\.face) private var face

    var body: some View {
        HStack(spacing: 6) {
            if dashboard && model.rows.count > 1 { AccountChips(model: model); StripDivider() }
            if fill { Spacer(minLength: 6) }
            if dashboard { UpdatedButton(model: model, refresh: refresh) }
            else if let settings { SettingsStatus(model: settings) }
        }
        .padding(4)
        .frame(maxWidth: fill ? .infinity : nil)
        .background(SurfaceShape(surface: face.strip, radius: 6))
        .fixedSize(horizontal: !fill, vertical: true)
    }
}

/// A small "open" marker for an account whose Claude desktop window is running.
struct OpenBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(Color.green).frame(width: 5, height: 5)
            Text("open").font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(Color.green)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color.green.opacity(0.14), in: Capsule())
        .help("Its Claude desktop window is running")
    }
}

struct Kbd: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct MiniLimit: View {
    let tag: String
    let p: Double?
    var body: some View {
        HStack(spacing: 6) {
            Text(tag).font(.caption2.weight(.bold)).foregroundStyle(.secondary).frame(width: 16, alignment: .leading)
            LevelBar(p: p, height: 5)
            Text(Painter.pct(p)).font(.system(size: 11.5, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(p == nil ? Color.secondary : Color(nsColor: Painter.color(p, stale: false)))
                .frame(width: 36, alignment: .trailing)
        }
    }
}

// MARK: - Click: the launcher palette

struct PaletteView: View {
    @ObservedObject var model: LauncherModel
    let week: WeekSummary
    let actions: LauncherActions

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Open Claude for…", text: $model.query).textFieldStyle(.plain)
                    .onChange(of: model.query) { _ in model.selectMostRoom() }
                if model.rows.count > 1 { Kbd(text: "⌘1–\(min(model.rows.count, 9))") }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

            if model.filtered.isEmpty {
                Text(model.rows.isEmpty ? "No accounts yet: add them in Settings." : "No account matches.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 14)
            }
            ForEach(Array(model.filtered.enumerated()), id: \.element.id) { i, row in
                HStack(spacing: 10) {
                    Image(nsImage: row.icon).resizable().frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(row.accent).frame(width: 7, height: 7)
                            Text(row.entry.name).font(.system(size: 13, weight: .semibold))
                            if row.activity.desktopOpen { OpenBadge() }
                            Text(row.subtitle).font(.caption2).lineLimit(1)
                                .foregroundStyle(row.needsLogin ? Color.red : Color.secondary)
                                .hidesEmail(row.subtitle.contains("@"))
                            Spacer(minLength: 0)
                        }
                        MiniLimit(tag: "5h", p: row.fiveHour)
                        MiniLimit(tag: "wk", p: row.weekly)
                    }
                    if i < 9 { Kbd(text: "⌘\(i + 1)") }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(i == model.selected ? Color.primary.opacity(0.09) : Color.clear))
                .contentShape(Rectangle())
                .onHover { if $0 { model.selected = i } }
                .onTapGesture { actions.open(row) }        // one click opens that account's Claude window
                .help("Open Claude \(row.entry.name)")
            }

            DashboardCard(week: week, open: actions.mainScreen).padding(.top, 2)

            HStack(spacing: 10) {
                Text("click or ↩ desktop · ⌘↩ terminal").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(action: actions.settings) { Image(systemName: "gearshape") }.buttonStyle(.plain)
                    .foregroundStyle(.secondary).help("Settings…")
            }
            .padding(.horizontal, 6).padding(.top, 2)
        }
        .padding(10)
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12)))
    }
}

// MARK: - Long press: the main screen

enum MainPage: Hashable { case dashboard, settings }

final class WindowNav: ObservableObject {
    @Published var page: MainPage = .dashboard
    /// Set when code (not the Dashboard/Settings switch) opened Settings and already chose its page.
    var keepSettingsSelection = false
}

/// The one cl_audit window: a top bar to switch between Dashboard and Settings, and the page.
struct MainWindowView: View {
    @ObservedObject var nav: WindowNav
    @ObservedObject var model: LauncherModel
    let stats: StatsModel
    let settings: SettingsModel
    let actions: LauncherActions
    @ObservedObject private var facePrefs = FacePrefs.shared

    private var brand: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("cl_audit").font(.system(size: 17, weight: .bold)).foregroundStyle(facePrefs.face.theme.text)
            Printed(text: "Usage audit for Claude profiles", size: 8)
        }
        .fixedSize()
    }

    private var pageKeys: some View {
        PageKeys(options: [MainPage.dashboard, .settings], selection: $nav.page, height: TopStrip.height) { $0 == .dashboard ? "Dashboard" : "Settings" }
            .fixedSize()
    }

    /// On the dashboard: profile keys and Updated. In Settings: whether everything is saved.
    private var strip: some View {
        TopStrip(model: model, settings: settings, dashboard: nav.page == .dashboard, refresh: actions.refreshAll)
    }

    var body: some View {
        VStack(spacing: 0) {
            // the front panel's top strip: the name, the page's own controls, the page keys
            // one row: the name, one sunken strip (profile keys | Updated and refresh), the page keys;
            // when the window is narrow the strip takes its own row under them
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    brand
                    strip                       // the same place on every page
                    Spacer(minLength: 8)
                    pageKeys
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) { brand; Spacer(minLength: 8); pageKeys }
                    TopStrip(model: model, settings: settings, dashboard: nav.page == .dashboard, fill: true, refresh: actions.refreshAll)
                }
            }
            .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 11)
            EngravedRule(dark: .black(facePrefs.face.isLight ? 0.3 : 0.6))
            Group {
                if nav.page == .dashboard {
                    MainScreenView(model: model, stats: stats, actions: actions)
                } else {
                    SettingsPage(model: settings)
                }
            }
            .overlay(alignment: .bottom) { SettingNoteOverlay(model: settings) }
        }
        .background(ChassisBackground())
        .face(facePrefs.face)
        .frame(minWidth: 940, minHeight: 600)
        .onChange(of: nav.page) { p in
            if p == .dashboard { actions.refresh() }
            else if nav.keepSettingsSelection { nav.keepSettingsSelection = false }
            else { settings.openDefault() }
        }
    }
}

struct MainScreenView: View {
    @ObservedObject var model: LauncherModel
    var stats: StatsModel? = nil
    let actions: LauncherActions
    @Environment(\.face) private var face

    var body: some View {
        ScrollView { content }
        .frame(minWidth: 600, minHeight: 360)
    }

    var content: some View {
            VStack(alignment: .leading, spacing: 14) {
                CardGrid(minWidth: 352, spacing: 12) {
                    ForEach(model.shownRows) { AccountCard(row: $0, actions: actions) }
                }
                if model.rows.isEmpty {
                    Text("No profiles yet. Open Settings to add one.").foregroundStyle(face.muted)
                }
                if !model.rows.isEmpty && model.shownRows.isEmpty {
                    Text("No profile selected: pick one or more above.").foregroundStyle(face.muted)
                } else if let stats { StatsSection(stats: stats).padding(.top, 6) }
            }
            .padding(16)
    }
}

/// Cards in columns of at least `minWidth`; every card in a row gets the row's tallest height, so the
/// cards line up whatever panel design each account uses.
struct CardGrid: Layout {
    var minWidth: CGFloat = 270
    var spacing: CGFloat = 12

    /// A usable width: SwiftUI also asks with no width or an infinite one (e.g. inside a scroll view while it
    /// measures), which can't be turned into a number of columns; then it's the width of up to three cards.
    private func usable(_ width: CGFloat?, count: Int) -> CGFloat {
        guard let width, width.isFinite, width > 0 else {
            let n = CGFloat(max(1, min(count, 3)))
            return n * minWidth + (n - 1) * spacing
        }
        return width
    }

    private func grid(_ subviews: Subviews, width rawWidth: CGFloat) -> (cols: Int, colWidth: CGFloat, heights: [CGFloat]) {
        let width = usable(rawWidth, count: subviews.count)
        let fit = ((width + spacing) / (minWidth + spacing)).rounded(.down)
        // empty columns stay empty, so a single card keeps a column's width instead of filling the window
        let cols = max(1, fit.isFinite ? Int(min(fit, 1000)) : 1)
        let colWidth = (width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
        let heights = stride(from: 0, to: subviews.count, by: cols).map { start in
            subviews[start..<min(start + cols, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: colWidth, height: nil)).height }.max() ?? 0
        }
        return (cols, colWidth, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = usable(proposal.width, count: subviews.count)
        let g = grid(subviews, width: width)
        return CGSize(width: width, height: g.heights.reduce(0, +) + CGFloat(max(0, g.heights.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let g = grid(subviews, width: bounds.width)
        var y = bounds.minY
        for (r, h) in g.heights.enumerated() {
            for c in 0..<g.cols {
                let i = r * g.cols + c
                guard i < subviews.count else { break }
                subviews[i].place(at: CGPoint(x: bounds.minX + CGFloat(c) * (g.colWidth + spacing), y: y),
                                  proposal: ProposedViewSize(width: g.colWidth, height: h))
            }
            y += h + spacing
        }
    }
}

struct AccountCard: View {
    let row: AccountRow
    let actions: LauncherActions
    @ObservedObject private var prefs = DashboardPrefs.shared
    @Environment(\.face) private var face

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { actions.open(row) } label: {
                    Image(nsImage: row.icon).resizable().frame(width: 48, height: 48)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .help("Open Claude \(row.entry.name)")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(row.accent).frame(width: 8, height: 8)
                        Text("Claude \(row.entry.name)").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(face.text)
                    }
                    Text(row.subtitle).font(.system(size: 12)).lineLimit(1)
                        .foregroundStyle(row.needsLogin ? face.danger : face.muted)
                        .hidesEmail(row.subtitle.contains("@"))
                }
                Spacer(minLength: 0)
                if let plan = row.status?.plan {
                    DisplayWindow(text: plan).frame(maxHeight: .infinity, alignment: .top)
                }
            }
            // Its Claude window and its Dock icon, as switches (or the button that fixes a problem).
            ProfileControls(row: row, actions: actions)
            // one style for every card on the dashboard (Settings ▸ General); each profile's panel design is for its panels
            LimitsView(limits: row.limits, design: prefs.cardStyle, large: false)
          }
            Spacer(minLength: 12)         // cards in a row share one height; the buttons stay at the bottom
            HStack(spacing: 7) {
                // One main button: sign in when needed, otherwise bring the Claude window forward.
                if row.needsLogin {
                    Button("Sign in…") { actions.logIn(row) }.buttonStyle(.pill(.red))
                } else if row.entry.desktop != .none {
                    Button(row.activity.desktopOpen ? "Show window" : "Open window") { actions.open(row) }.buttonStyle(.pill(row.accent))
                }
                Button("Terminal") { actions.terminal(row) }.buttonStyle(.pill)
                moreMenu
                Spacer()
                if let u = row.status?.updatedAt {
                    Text(DetailsFormat.ago(u)).font(.system(size: 11.5)).foregroundStyle(face.muted).lineLimit(1).fixedSize()
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 15).padding(.top, 14).padding(.bottom, 12)
        .background(RaisedShape(finish: face.module, radius: face.moduleRadius))
    }

    /// The rest for this profile.
    private var moreMenu: some View {
        Menu {
            Button("Refresh now") { actions.refreshAll() }
            Divider()
            Button("Profile settings…") { actions.profileSettings(row) }
        } label: {
            KeyLook(height: 26, radius: 4, hPad: 0) { Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).frame(width: 26) }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("More for \(row.entry.name)")
    }
}

extension ManagerUI {
    /// The palette or main screen with the real accounts, as a PNG (`--render-launcher OUT palette|main`).
    @MainActor static func renderSample(to path: String, main: Bool, settingsPage: Bool = false) {
        let ui = ManagerUI()
        ui.model.reload(); ui.model.selectMostRoom()
        if main && !settingsPage {   // wait for the history scan
            ui.stats.reload()
            let deadline = Date().addingTimeInterval(60)
            while ui.stats.loading && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        }
        let view = Group {
            if settingsPage { SettingsPage(model: ui.settings).snapshot.frame(width: 980) }
            else if main { MainScreenView(model: ui.model, stats: ui.stats, actions: ui.actions).content.frame(width: 880) }
            else { let _ = ui.week.reload(hidden: ui.model.hidden, wait: true); PaletteView(model: ui.model, week: ui.week, actions: ui.actions) }
        }
        .padding(16).background(Color(white: 0.13)).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let tiff = r.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - The settings app's windows: palette, main screen

final class ManagerUI {
    let model = LauncherModel()
    let stats = StatsModel()
    let week = WeekSummary()
    let nav = WindowNav()
    lazy var settings = SettingsModel()
    private var ticks = 0

    private func wireFilter() {
        stats.hidden = model.hidden
        model.onHiddenChange = { [weak self] in
            guard let self else { return }
            self.stats.hidden = self.model.hidden
            self.stats.reload()
        }
    }
    private var palette: DetailsPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var closedAt = Date.distantPast
    private var mainWindow: NSWindow?
    private var timer: Timer?

    lazy var actions = LauncherActions(
        open: { [weak self] r in
            self?.closePalette()
            if !r.activity.desktopOpen && r.entry.desktop != .none { self?.model.begin(r.id, .opening) }
            Launcher.openClaude(r.account)
        },
        terminal: { [weak self] r in self?.closePalette(); Launcher.openTerminal(r.account) },
        logIn: { [weak self] r in
            self?.closePalette()
            if let claude = ClaudeCLI.find() { ClaudeCLI.openLogin(claude, account: r.account, email: r.status?.expectedEmail) }
        },
        mainScreen: { [weak self] in self?.closePalette(); self?.showMain() },
        settings: { [weak self] in self?.showMain(page: .settings) },
        refresh: { [weak self] in self?.model.reload(); self?.stats.reload() },
        refreshAll: { [weak self] in
            guard let self else { return }
            self.model.refreshing = true
            DistributedNotificationCenter.default().postNotificationName(Installer.refreshAllNote, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            // The icons fetch and save within a few seconds; read their results then.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                self.model.reload(); self.stats.reload(); self.model.refreshing = false
            }
        },
        quitWindow: { [weak self] r in
            self?.model.begin(r.id, .quitting)
            NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
                .filter { Launcher.isWindow(of: r.account, $0) }.forEach { $0.terminate() }
        },
        showClaude: { r in Launcher.openClaude(r.account) },
        startUsage: { [weak self] r in
            let app = Installer.appURL(r.entry)
            if FileManager.default.fileExists(atPath: app.path) {
                self?.model.begin(r.id, .starting)
                Installer.run("/usr/bin/open", ["-g", app.path])      // a normal start: a following window opens too
            } else {
                Installer.sync(Store.load())
                self?.model.begin(r.id, .starting)
            }
        },
        quitUsage: { [weak self] r in
            self?.model.begin(r.id, .stopping)
            // a normal quit, so a window that follows its Dock icon quits too; pins and the Dock are not touched
            Installer.running(Installer.appURL(r.entry)).forEach { $0.terminate() }
        },
        profileSettings: { [weak self] r in self?.showMain(page: .settings, account: r.id) })

    var paletteShown: Bool { palette?.isVisible == true }
    var dashboardShown: Bool { mainWindow?.isVisible == true && mainWindow?.isMiniaturized == false }
    private var othersObserver: NSObjectProtocol?
    private var appObservers: [NSObjectProtocol] = []

    init() {
        // An account icon opening its panel closes the palette (and the palette closes theirs).
        othersObserver = DistributedNotificationCenter.default().addObserver(
            forName: DetailsController.panelOpened, object: nil, queue: .main) { [weak self] note in
            guard (note.object as? String) != Bundle.main.bundleIdentifier else { return }
            self?.closePalette()
        }
        // A Claude window or Dock icon starting or quitting shows on the cards right away, not at the next check.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            appObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, self.dashboardShown || self.paletteShown,
                      let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier,
                      id == Launcher.claudeBundleID || id.hasPrefix(Installer.managerID + ".") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.model.reload() }
            })
        }
    }

    /// Click on the cl_audit icon. The palette and the dashboard show the same accounts, so they never
    /// appear together: with the dashboard open, the click brings the dashboard forward instead.
    func togglePalette() {
        if paletteShown { closePalette(); return }
        if dashboardShown { showMain(); return }
        if Date().timeIntervalSince(closedAt) < 0.4 { return }   // the click that just closed it
        model.reload()
        model.query = ""
        model.selectMostRoom()
        week.reload(hidden: model.hidden)
        let host = PanelHostingView(rootView: PaletteView(model: model, week: week, actions: actions))
        let size = host.fittingSize
        let p = palette ?? DetailsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = host
        p.setFrame(DetailsController.frame(for: size), display: true)
        palette = p
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p,
                                                                    queue: .main) { [weak self] _ in self?.closePalette() }
        }
        DistributedNotificationCenter.default().postNotificationName(DetailsController.panelOpened,
                                                                     object: Bundle.main.bundleIdentifier ?? "usage",
                                                                     userInfo: nil, deliverImmediately: true)
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        startKeys()
    }

    func closePalette() {
        guard paletteShown else { return }
        palette?.orderOut(nil)
        closedAt = Date()
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
    }

    /// ↑ ↓ choose, ↩ desktop, ⌘↩ terminal, ⌘1–9 open that account, Esc closes.
    private func startKeys() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.paletteShown, e.window === self.palette else { return e }
            let list = self.model.filtered
            switch e.keyCode {
            case 125: self.model.selected = min(self.model.selected + 1, max(list.count - 1, 0)); return nil
            case 126: self.model.selected = max(self.model.selected - 1, 0); return nil
            case 53: self.closePalette(); return nil
            case 2 where e.modifierFlags.contains(.command): self.actions.mainScreen(); return nil   // ⌘D
            case 36, 76:
                guard list.indices.contains(self.model.selected) else { return nil }
                let row = list[self.model.selected]
                if e.modifierFlags.contains(.command) { self.actions.terminal(row) } else { self.actions.open(row) }
                return nil
            default:
                if e.modifierFlags.contains(.command), let c = e.charactersIgnoringModifiers, let n = Int(c), n >= 1,
                   list.indices.contains(n - 1) {
                    self.actions.open(list[n - 1]); return nil
                }
                return e
            }
        }
    }

    func showMain(page: MainPage = .dashboard, account: String? = nil) {
        closePalette()
        model.reload()
        wireFilter()
        // The switch's own handler would pick the Dashboard tile; skip it once (only an open window runs it).
        if page == .settings && nav.page != .settings && mainWindow != nil { nav.keepSettingsSelection = true }
        nav.page = page
        if page == .settings {
            // From an icon: that account's page. From inside the app: the Dashboard tile.
            if let account, settings.accounts.contains(where: { $0.id == account }) { settings.reloadIfClean(); settings.selection = account }
            else { settings.openDefault() }
        }
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "cl_audit"
            w.styleMask.insert(.fullSizeContentView)      // the chassis runs under the title bar
            w.titlebarAppearsTransparent = true
            w.tabbingMode = .disallowed
            w.contentViewController = NSHostingController(rootView: MainWindowView(
                nav: nav, model: model, stats: stats, settings: settings, actions: actions))
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("ClaudeUsageMain")
            if !w.setFrameUsingName("ClaudeUsageMain") { w.center() }
            mainWindow = w
            FacePrefs.shared.window = w                  // Silver: the light appearance; the others dark
        }
        stats.reload()
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self, self.mainWindow?.isVisible == true || self.paletteShown else { return }
                self.model.reload()
                self.ticks += 1
                if self.ticks % 6 == 0, self.mainWindow?.isVisible == true { self.stats.reload() }   // every minute
            }
        }
    }
}

/// A profile card's two controls: its Claude window (open or quit) and its Dock icon (start or quit), each a
/// switch. A missing Dock icon app shows Reinstall instead.
struct ProfileControls: View {
    let row: AccountRow
    let actions: LauncherActions
    @Environment(\.face) private var face

    var body: some View {
        // side by side, sharing the card's width; one above the other when the card is narrow
        HStack(spacing: 6) { chips }
    }

    @ViewBuilder private var chips: some View {
        if row.entry.desktop != .none { windowChip }
        dockChip
    }

    // no glyphs: the printed title says which one it is
    private var windowGlyph: AnyView { AnyView(EmptyView()) }
    private var dockGlyph: AnyView { AnyView(EmptyView()) }

    @ViewBuilder private var windowChip: some View {
        let open = row.activity.desktopOpen
        if let c = row.busy?.isWindow == true ? row.busy : row.windowFollowing {
            chip(glyph: windowGlyph, title: "Claude window", sub: c.text, on: c.target, warn: false) {
                BusySwitch(on: c.target).help(row.windowFollowing != nil ? "Following its Dock icon (profile settings ▸ Opening and closing)" : "Working on it…")
            }
        } else if row.notice == .openFailed {
            chip(glyph: windowGlyph, title: "Claude window", sub: "didn't open", on: false, warn: true) { fix("Retry") { actions.open(row) } }
        } else if row.notice == .claudeAsking {
            chip(glyph: windowGlyph, title: "Claude window", sub: "Claude is asking", on: true, warn: true) {
                fix("Show") { actions.showClaude(row) }.help("Claude asks before quitting, for example about unsent work; answer it there")
            }
        } else {
            chip(glyph: windowGlyph, title: "Claude window", sub: open ? "open" : "closed", on: open, warn: false) {
                Toggle("", isOn: Binding(get: { open }, set: { $0 ? actions.open(row) : actions.quitWindow(row) })).smallSwitch()
                    .help(open ? "Quit this profile's Claude window" : "Open this profile's Claude window")
            }
        }
    }

    /// The Dock icon switch starts and quits the Dock icon app. It never touches pins, so the Dock is never
    /// restarted; hiding is in profile settings ▸ Dock icon. Only a missing app gets an orange button.
    @ViewBuilder private var dockChip: some View {
        let s = row.usageIcon
        let running = s != .notRunning && s != .missing
        let follows = row.entry.lifecycle.usageFollowsWindow && row.entry.desktop != .none
        if let c = row.busy, !c.isWindow {
            chip(glyph: dockGlyph, title: "Dock icon", sub: c.text, on: c.target, warn: false) { BusySwitch(on: c.target) }
        } else if row.followStarting && s == .notRunning {
            chip(glyph: dockGlyph, title: "Dock icon", sub: "starting…", on: true, warn: false) { BusySwitch(on: true).help("Starting with its Claude window") }
        } else if s == .missing {
            chip(glyph: dockGlyph, title: "Dock icon", sub: "missing", on: false, warn: true) { fix("Reinstall") { actions.startUsage(row) } }
        } else {
            let sub: String = {
                if running, let t = row.followQuitIn { return t < 0.5 ? "quitting…" : "quits in \(Int(t.rounded(.up))) s" }
                if running { return s == .hidden ? "running, hidden" : "running" }
                return follows && !row.activity.desktopOpen ? "waits for the window" : "stopped · no alerts"
            }()
            chip(glyph: dockGlyph, title: "Dock icon", sub: sub, on: running, warn: false) {
                Toggle("", isOn: Binding(get: { running }, set: { $0 ? actions.startUsage(row) : actions.quitUsage(row) })).smallSwitch()
                    .help(row.followQuitIn != nil ? "It quits with its Claude window (profile settings ▸ Opening and closing)"
                          : running ? "Quit it: no refreshes or alerts for this profile until it starts again; its Dock pin stays"
                          : follows ? "It starts when the Claude window opens; or start it now" : "Start it")
            }
        }
    }

    private func fix(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.pill(FaceTheme.led, compact: true)).fixedSize()
    }

    /// A recess in the card: a printed title, the state glowing like a display, and the switch (or a fix key).
    private func chip<C: View>(glyph: AnyView, title: String, sub: String, on: Bool, warn: Bool, @ViewBuilder trailing: () -> C) -> some View {
        let subColor: Color = warn ? (face.light ? .hex(0xa85f00) : .hex(0xffb24a)) : face.displayText
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Printed(text: title, size: 8.5)
                Text(sub).font(.system(size: 9.5, weight: .semibold, design: .monospaced)).tracking(0.6).textCase(.uppercase)
                    .foregroundStyle(subColor.opacity(on || warn ? 1 : 0.5))
                    .shadow(color: face.displayGlow && (on || warn) ? subColor.opacity(0.6) : .clear, radius: 1.5)
                    .lineLimit(1).truncationMode(.tail)
                    .help(sub)
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.leading, 10).padding(.trailing, 7)
        .frame(maxWidth: .infinity, minHeight: 40)
        .fixedSize(horizontal: false, vertical: true)
        .faceWindow(radius: 6)
    }
}

/// A small switch already pointing where it is going, its knob a spinner, while cl_audit waits for the change.
/// It takes no clicks.
/// Drawn as the switch key already where it goes, its LED blinking.
struct BusySwitch: View {
    let on: Bool
    var body: some View {
        LEDSwitchKey(on: on, blinking: true) {}
            .allowsHitTesting(false)
            .help("Working on it…")
        .accessibilityLabel("Working")
    }
}
