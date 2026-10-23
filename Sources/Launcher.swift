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

struct AccountRow: Identifiable {
    let entry: AccountEntry
    let status: IconStatus?
    var activity = Launcher.Activity()
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
                                weeklyElapsed: windowElapsed(status?.weeklyResets, 7 * 86400)), pixels: 128)
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
        rows = entries.map {
            AccountRow(entry: $0, status: Store.status($0.id), activity: acts[Account($0).configDir] ?? .init())
        }
        selected = min(selected, max(filtered.count - 1, 0))
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
}

/// "Updated 1 min ago": the age of the newest numbers on the dashboard; a click asks every icon to fetch now.
struct UpdatedButton: View {
    @ObservedObject var model: LauncherModel
    let refresh: () -> Void
    @State private var hover = false

    var newest: Date? { model.shownRows.compactMap { $0.status?.updatedAt }.max() }

    var body: some View {
        Button(action: refresh) {
            Group {
                if model.refreshing { Text("Updating…") }
                else if let d = newest { Text("Updated \(DetailsFormat.ago(d))") }
                else { Text("Not updated yet") }
            }
            .font(.system(size: 12)).foregroundStyle(hover ? Color.primary : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(hover ? 0.07 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .keyboardShortcut("r", modifiers: .command)
        .help("Refresh now (⌘R)")
    }
}

/// Which accounts the dashboard shows: "Show" followed by a checkbox per account (several can be on).
/// Drawn as a filter, not as account buttons, so it doesn't look like it opens Claude.
struct AccountChips: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        HStack(spacing: 4) {
            Text("Show").font(.callout).foregroundStyle(.secondary).padding(.trailing, 4)
            ForEach(model.rows) { row in
                let on = !model.hidden.contains(row.id)
                Button { model.toggle(row.id) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(on ? row.accent : Color.secondary)
                        Text(row.entry.name).font(.callout)
                            .foregroundStyle(on ? Color.primary : Color.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(on ? "Hide \(row.entry.name) from the dashboard" : "Show \(row.entry.name) on the dashboard")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("cl_audit").font(.system(size: 17, weight: .bold))
                if nav.page == .dashboard {
                    if model.rows.count > 1 { AccountChips(model: model) }
                    UpdatedButton(model: model, refresh: actions.refreshAll)
                }
                Spacer()
                PillPicker(options: [MainPage.dashboard, .settings], selection: $nav.page) { $0 == .dashboard ? "Dashboard" : "Settings" }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            Divider().opacity(0.5)
            if nav.page == .dashboard {
                MainScreenView(model: model, stats: stats, actions: actions)
            } else {
                SettingsPage(model: settings)
            }
        }
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

    var body: some View {
        ScrollView { content }
        .frame(minWidth: 600, minHeight: 360)
    }

    var content: some View {
            VStack(alignment: .leading, spacing: 14) {
                CardGrid(minWidth: 270, spacing: 12) {
                    ForEach(model.shownRows) { AccountCard(row: $0, actions: actions) }
                }
                if model.rows.isEmpty {
                    Text("No accounts yet. Open Settings to add them.").foregroundStyle(.secondary)
                }
                if !model.rows.isEmpty && model.shownRows.isEmpty {
                    Text("No account selected: pick one or more above.").foregroundStyle(.secondary)
                } else if let stats { StatsSection(stats: stats).padding(.top, 6) }
            }
            .padding(18)
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
        let cols = max(1, min(subviews.count, fit.isFinite ? Int(min(fit, 1000)) : 1))
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
                        Text("Claude \(row.entry.name)").font(.headline)
                    }
                    Text(row.subtitle).font(.caption).lineLimit(1)
                        .foregroundStyle(row.needsLogin ? Color.red : Color.secondary)
                        .hidesEmail(row.subtitle.contains("@"))
                    HStack(spacing: 5) {
                        Circle().fill(row.activity.desktopOpen ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        Text(row.activity.desktopOpen ? "Desktop open" : "Desktop closed")
                    }
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let plan = row.status?.plan {
                    Text(plan.capitalized).font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
            // one style for every card on the dashboard (Settings ▸ Dashboard); each account's panel design is for its panels
            LimitsView(limits: row.limits, design: prefs.cardStyle, large: false)
          }
            Spacer(minLength: 12)         // cards in a row share one height; the buttons stay at the bottom
            HStack(spacing: 6) {
                if row.needsLogin { Button("Log in…") { actions.logIn(row) }.buttonStyle(.pill(.red)) }
                Button(row.activity.desktopOpen ? "Show Desktop" : "Open Desktop") { actions.open(row) }
                    .buttonStyle(.pill(row.accent))
                Button("Terminal") { actions.terminal(row) }.buttonStyle(.pill)
                Spacer()
                if let u = row.status?.updatedAt {
                    Text(DetailsFormat.ago(u)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
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
        open: { [weak self] r in self?.closePalette(); Launcher.openClaude(r.account) },
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
        })

    var paletteShown: Bool { palette?.isVisible == true }
    var dashboardShown: Bool { mainWindow?.isVisible == true && mainWindow?.isMiniaturized == false }
    private var othersObserver: NSObjectProtocol?

    init() {
        // An account icon opening its panel closes the palette (and the palette closes theirs).
        othersObserver = DistributedNotificationCenter.default().addObserver(
            forName: DetailsController.panelOpened, object: nil, queue: .main) { [weak self] note in
            guard (note.object as? String) != Bundle.main.bundleIdentifier else { return }
            self?.closePalette()
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
            w.tabbingMode = .disallowed
            w.contentViewController = NSHostingController(rootView: MainWindowView(
                nav: nav, model: model, stats: stats, settings: settings, actions: actions))
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("ClaudeUsageMain")
            if !w.setFrameUsingName("ClaudeUsageMain") { w.center() }
            mainWindow = w
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
