// Dashboard settings (app-wide, in the settings app's preferences): one card style for every account card,
// the history period (the dashboard's 24 h / 7 d / 30 d switch is the same setting), and which history
// charts to show, and the Dock (Dock.swift). Edited on Settings ▸ Dashboard.

import SwiftUI

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

/// Settings ▸ General: Emails · Face · App icon · Dashboard cards · About · Dock. The history period and which charts to show are set on the
/// dashboard itself, as filters.
struct DashboardSettings: View {
    @ObservedObject private var prefs = DashboardPrefs.shared
    var width: CGFloat = 1280

    var body: some View {
        SettingsColumns(width: width, groups: [[AnyView(emailsCard), AnyView(faceCard), AnyView(appIconCard), AnyView(cardsCard), AnyView(aboutCard)], [AnyView(agentCard), AnyView(DockCard()), AnyView(cleanupCard)]])
    }

    @Environment(\.face) private var face
    @ObservedObject private var privacy = Privacy.shared

    // The agent: what it's doing, and when it won't start, why and what to do
    @ObservedObject private var starter = AgentStarter.shared
    var agentCard: some View {
        let _ = cleanupTick
        let health = Agent.health()
        let line: String = {
            switch health {
            case let .reading(n, lo, hi): return "Reading usage · \(n) profile\(n == 1 ? "" : "s") · every \(lo == hi ? "\(lo)" : "\(lo)–\(hi)") min"
            case .failing(let n): return "Reading usage · Anthropic didn't answer for \(n) profile\(n == 1 ? "" : "s")"
            case .paused(let until): return "Not updating · paused until \(StripState.time(until)) after crashes"
            case .stopped: return starter.failures >= 3 ? "Not updating · agent won't start" : "Starting the agent…"
            }
        }()
        return SCard(title: "Agent", info: "cl_audit's background agent reads every profile's usage, renews sign-ins, sends the alerts and runs Opening and closing. macOS starts it at login and after a crash; cl_audit starts it too when its window opens and whenever it has been silent for 90 s.") {
            SRow(label: "Now", first: true) {
                Text(line).font(.system(size: 12)).foregroundStyle(starter.failures >= 3 && health == .stopped ? face.danger : face.soft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .stopped = health, starter.failures >= 3 {
                SRow(label: "Why", stacked: true) {
                    Text(Self.reason()).font(.system(size: 11.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { cleanupTick += 1 }
    }

    /// Why the agent won't start, and the fix, in words.
    static func reason() -> String {
        switch Agent.service.status {
        case .requiresApproval:
            return "macOS needs you to allow cl_audit to run in the background: System Settings ▸ General ▸ Login Items & Extensions ▸ Allow in the Background ▸ cl_audit. Then press the refresh key."
        case .notRegistered, .notFound:
            return "cl_audit's background item isn't registered. Quit and reopen cl_audit, or reinstall it; then press the refresh key."
        default:
            return "macOS didn't start it. Make sure cl_audit is in /Applications (not in the Trash or a download folder), then press the refresh key. If it still won't start, restart the Mac or reinstall cl_audit."
        }
    }

    // Clean-up and Uninstall: what the agent tidies on its own, and taking cl_audit off this Mac
    @State private var cleanupTick = 0
    var cleanupCard: some View {
        let _ = cleanupTick
        let r = Cleanup.lastRecord()
        let items = (r?.removed ?? []).prefix(6).joined(separator: "\n")
        return SCard(title: "Clean-up", info: "The cl_audit agent tidies up on its own: at login, after every change and every 6 hours. It removes only what is provably cl_audit's: Dock icon apps no profile wants, second copies, what macOS keeps for them, saved usage of removed profiles, Dock pins of apps that are gone and old Terminal scripts. Never a Claude Code folder, a Claude window's data, a Keychain sign-in or anything else.") {
            SRow(label: "Last run", info: items.isEmpty ? "Nothing removed in the last week." : "Removed:\n" + items, first: true) {
                Text(Cleanup.summary(r)).font(.system(size: 12)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
            }
            SRow(label: "Uninstall", info: "Removes every Dock icon app and its pin, the agent, saved usage, settings and caches, then moves cl_audit to the Trash. You choose per profile whether its Claude Code folder (signed out first) and its own Claude window's data go too; ~/.claude and the standard window are never deleted.") {
                Button("Uninstall cl_audit…") { UninstallUI.shared.show = true }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(face.danger)
            }
        }
        .onAppear { cleanupTick += 1 }
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
        TileKey(selected: selected) { TileText(title: "General", sub: "emails · face · dashboard · Dock") }
    }
}
