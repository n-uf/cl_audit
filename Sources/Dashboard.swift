// Dashboard settings (app-wide, in the settings app's preferences): one card style for every account card,
// the history period (the dashboard's 24 h / 7 d / 30 d switch is the same setting), and which history
// charts to show, and the Dock (Dock.swift). Edited on Settings ▸ Dashboard.

import SwiftUI
import UserNotifications

final class DashboardPrefs: ObservableObject {
    static let shared = DashboardPrefs()
    private let d = UserDefaults.standard

    @Published var cardStyle: PanelDesign { didSet { d.set(cardStyle.rawValue, forKey: "dashboardCardStyle") } }
    @Published var range: StatsRange { didSet { d.set(range.rawValue, forKey: "dashboardRange") } }
    @Published var showHeatmap: Bool { didSet { d.set(showHeatmap, forKey: "dashboardShowHeatmap") } }
    @Published var showTokens: Bool { didSet { d.set(showTokens, forKey: "dashboardShowTokens") } }
    @Published var showShares: Bool { didSet { d.set(showShares, forKey: "dashboardShowShares") } }

    private init() {
        cardStyle = PanelDesign(rawValue: d.string(forKey: "dashboardCardStyle") ?? "") ?? .segments
        range = StatsRange(rawValue: d.string(forKey: "dashboardRange") ?? "") ?? .week
        showHeatmap = d.object(forKey: "dashboardShowHeatmap") as? Bool ?? true
        showTokens = d.object(forKey: "dashboardShowTokens") as? Bool ?? true
        showShares = d.object(forKey: "dashboardShowShares") as? Bool ?? true
    }
}

/// Settings ▸ General: Usage in the background · Emails · Dock · Face · Dashboard cards · App icon · About. The history
/// period and which charts to show are set on the dashboard itself, as filters.
struct DashboardSettings: View {
    @ObservedObject private var prefs = DashboardPrefs.shared
    var width: CGFloat = 1280

    /// Most important first, read left to right and top to bottom (two columns and one keep the order): how it runs
    /// (Usage in the background, Emails, Dock), how it looks (Face, Dashboard cards), the rest (App icon, About).
    var body: some View {
        SettingsColumns(width: width, groups: [[AnyView(usageCard), AnyView(emailsCard), AnyView(DockCard())],
                                               [AnyView(faceCard), AnyView(cardsCard)],
                                               [AnyView(appIconCard), AnyView(aboutCard)]])
    }

    @Environment(\.face) private var face
    @ObservedObject private var privacy = Privacy.shared

    // Usage in the background: is usage being read, do alerts reach you (the dashboard display opens this when
    // reading stops). A key only when something needs you.
    @ObservedObject private var starter = AgentStarter.shared
    @ObservedObject private var alerts = AlertsPermission.shared
    @State private var tick = 0
    /// Offscreen renders only: a made-up state for the card (the real agent is never touched).
    struct UsagePreview { var health: Agent.Health; var allowed: Bool; var newest: Date?; var stoppedSince: Date? }
    static var usagePreview: UsagePreview? = nil

    var usageCard: some View {
        let _ = tick
        let p = Self.usagePreview
        let mark = p == nil ? Agent.readMark() : nil
        let health = p?.health ?? Agent.health(mark)
        let newest = p.map { $0.newest } ?? Store.load().compactMap { Store.status($0.id)?.updatedAt }.max()
        let stoppedSince = p.map { $0.stoppedSince } ?? mark?.beat
        let allowed = p.map { Optional($0.allowed) } ?? alerts.allowed
        let stopped: Bool = { if case .stopped = health { return !starter.starting }; return false }()
        return SCard(title: "Usage in the background", info: "cl_audit's background agent reads every profile's usage on each profile's own schedule, renews sign-ins, sends the alerts and runs Opening and closing. macOS starts it when you log in and again after a crash; cl_audit starts it too when this window opens and whenever it has been silent for 90 s.") {
            Group {
                switch health {
                case let .reading(n, lo, hi):
                    DisplayWindow(text: "Reading usage", dim: "· \(n) profile\(n == 1 ? "" : "s") · every \(lo == hi ? "\(lo)" : "\(lo)–\(hi)") min", tone: .ok, height: 24)
                case .failing(let n):
                    DisplayWindow(text: "Reading usage", dim: "· Anthropic didn't answer for \(n) profile\(n == 1 ? "" : "s")", tone: .amber, height: 24)
                case .paused(let until):
                    DisplayWindow(text: "Not reading", dim: "· paused until \(StripState.time(until))", tone: .amber, height: 24)
                case .stopped:
                    if starter.starting { DisplayWindow(text: "Starting the agent…", tone: .amber, height: 24) }
                    else { DisplayWindow(text: "Not reading", dim: stoppedSince.map { "· stopped \(DetailsFormat.ago($0))" } ?? "· not started yet", tone: .warn, height: 24) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("cl_audit reads every profile's usage and sends the alerts on its own, even with this window and the Dock icons closed. It starts when you log in.")
                .font(.system(size: 11.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 7).padding(.bottom, 4)
            SRow(label: "Alerts", info: "Alerts come from cl_audit when a limit reaches the level set for each profile. macOS asks once; you can change it in System Settings ▸ Notifications ▸ cl_audit.", first: true) {
                if allowed == false {
                    // side by side when there's room, the key under the display when not
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { notAllowed; openNotifications }
                        VStack(alignment: .leading, spacing: 6) { notAllowed; openNotifications }
                    }
                } else if allowed == true {
                    DisplayWindow(text: "Allowed", tone: .ok)
                } else {
                    Text("checking…").font(.system(size: 12)).foregroundStyle(face.muted)
                }
            }
            SRow(label: "Last read") {
                VStack(alignment: .leading, spacing: 1) {
                    Text(newest.map { DetailsFormat.ago($0) } ?? "not yet").font(.system(size: 12)).foregroundStyle(face.soft)
                    if stopped { Text("the cards show older numbers").font(.system(size: 11)).foregroundStyle(face.muted) }
                }
            }
            if stopped {
                SRow(label: "Start it") {
                    VStack(alignment: .leading, spacing: 3) {
                        Button("Start reading") { starter.start(reason: "Settings") }.buttonStyle(PillButtonStyle(compact: true))
                        Text("cl_audit tries by itself every minute").font(.system(size: 11)).foregroundStyle(face.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
                if starter.failures >= 3 {
                    Text(Self.reason()).font(.system(size: 11)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
            }
        }
        .onAppear { tick += 1; alerts.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in alerts.refresh(); tick += 1 }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in tick += 1 }
    }

    private var notAllowed: some View { DisplayWindow(text: "Not allowed", tone: .amber) }
    private var openNotifications: some View {
        Button("Open Notifications…") { AlertsPermission.openSettings() }.buttonStyle(PillButtonStyle(compact: true))
            .help("System Settings ▸ Notifications ▸ cl_audit")
    }

    /// Why the agent won't start, and the fix, in words.
    static func reason() -> String {
        switch Agent.service.status {
        case .requiresApproval:
            return "macOS needs you to allow cl_audit to run in the background: System Settings ▸ General ▸ Login Items & Extensions ▸ Allow in the Background ▸ cl_audit."
        case .notRegistered, .notFound:
            return "cl_audit's background item isn't registered. Quit and reopen cl_audit, or reinstall it."
        default:
            return "macOS didn't start it. Make sure cl_audit is in /Applications (not in the Trash or a download folder). If it still won't start, restart the Mac or reinstall cl_audit."
        }
    }

    // Show emails: for screen sharing and screenshots
    var emailsCard: some View {
        SCard(title: "Emails") {
            SRow(label: "Show emails", info: "Off: email addresses are left out of the dashboard, the launcher, the usage panels and the Dock icon menus, and blurred in Settings (hover one to see it). For screen sharing and screenshots.", first: true) {
                Toggle("", isOn: Binding(get: { privacy.show }, set: { privacy.set(show: $0) })).smallSwitch()
            }
        }
    }

    // Face: the look of this window (Faces.swift)
    var faceCard: some View {
        SCard(title: "Face") {
            VStack(alignment: .leading, spacing: 8) {
                FacePicker()
                Text("The look of this window, its settings and the dashboard. Silver is a light face: the window takes the Mac's light appearance. The Dock icons keep their own designs.")
                    .font(.system(size: 11.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2).padding(.bottom, 4)
        }
    }
    // App icon: the cl_audit app's own icon (AppIcon.swift), unlike the profiles' Dock icons
    var appIconCard: some View {
        SCard(title: "App icon") {
            VStack(alignment: .leading, spacing: 8) {
                AppIconPicker()
                Text("The cl_audit icon in the Dock and the app switcher, so it stands apart from the profile Dock icons. While cl_audit isn't running, the Dock shows the plain Front panel.")
                    .font(.system(size: 11.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2).padding(.bottom, 4)
        }
    }
    // About: which build this is, and where its changes are listed
    var aboutCard: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return SCard(title: "About") {
            SRow(label: "Version", info: "Calendar version: the year and month of the release, then a counter within that month (26.10.1 = the second release in October 2026). The build counts every change.", first: true) {
                DisplayWindow(text: version, dim: "· build \(build)").textSelection(.enabled)
            }
            SRow(label: "Changes") {
                Button("What's new") { NSWorkspace.shared.open(URL(string: "https://github.com/n-uf/cl_audit/blob/main/CHANGELOG.md")!) }
                    .buttonStyle(PillButtonStyle(compact: true))
            }
            let r = Cleanup.lastRecord()
            let items = (r?.removed ?? []).prefix(6).joined(separator: "\n")
            SRow(label: "Clean-up", info: "The agent tidies up on its own: at login, after every change and every 6 hours. It removes only what is provably cl_audit's: Dock icon apps no profile wants, second copies, what macOS keeps for them, saved usage of removed profiles, Dock pins of apps that are gone and old Terminal scripts. Never a Claude Code folder, a Claude window's data or a sign-in." + (items.isEmpty ? "" : "\nLast removed:\n" + items)) {
                Text(Cleanup.summary(r)).font(.system(size: 12)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
            }
            SRow(label: "Uninstall", info: "Removes every Dock icon app and its pin, the agent, saved usage, settings and caches, then moves cl_audit to the Trash. You choose per profile whether its Claude Code folder (signed out first) and its own Claude window's data go too; ~/.claude and the standard window are never deleted.") {
                Button("Uninstall cl_audit…") { UninstallUI.shared.show = true }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(face.danger)
            }
        }
    }

    var cardsCard: some View {
        SCard(title: "Dashboard cards", info: "How the 5-hour and weekly limits look on every profile's dashboard card. Each profile's own usage panel has its design in that profile's settings.") {
            SRow(label: "Card style", first: true, stacked: true) {
                // the keys and, under them, their preview, together in one pane
                VStack(spacing: 7) {
                    PillPicker(options: PanelDesign.allCases, selection: $prefs.cardStyle, compact: true, fill: true) { Self.short($0) }
                    LimitsView(limits: Self.sampleLimits, design: prefs.cardStyle, large: false)
                        .padding(12)
                        .faceWindow(radius: 5)
                }
                .padding(7)
                .background(SurfaceShape(surface: face.strip, radius: 7))
            }
        }
    }

    static func short(_ d: PanelDesign) -> String {
        switch d { case .glow: return "Glow"; case .rings: return "Rings"; case .numbers: return "Numbers"; case .segments: return "Segments"; case .pace: return "Pace" }
    }

    /// Sample figures for the preview: 34 % of the 5-hour limit, 61 % of the week.
    static var sampleLimits: [Limit] {
        [Limit(id: "5h", title: "5-hour session", name: "5-hour", p: 34, resets: Date().addingTimeInterval(3 * 3600 + 12 * 60), window: 5 * 3600),
         Limit(id: "wk", title: "Week", name: "Week", p: 61, resets: Date().addingTimeInterval(3 * 86400), window: 7 * 86400)]
    }
}

/// The strip's tile for the dashboard settings.
struct DashboardTile: View {
    let selected: Bool
    var body: some View {
        TileKey(selected: selected) { TileText(title: "General", sub: "reading · emails · Dock · face · cards") }
    }
}

/// Whether macOS lets cl_audit send alerts (asked by the cl_audit window; see IconApp), for Usage in the background.
final class AlertsPermission: ObservableObject {
    static let shared = AlertsPermission()
    @Published private(set) var allowed: Bool?

    func refresh() {
        guard Bundle.main.bundleIdentifier != nil else { return }      // offscreen renders run outside an app bundle
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            DispatchQueue.main.async { if self.allowed != ok { self.allowed = ok } }
        }
    }

    /// System Settings ▸ Notifications, at cl_audit.
    static func openSettings() {
        let deep = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Installer.managerID)")!
        if !NSWorkspace.shared.open(deep) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
        }
    }
}
