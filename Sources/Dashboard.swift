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

/// Settings ▸ General: Face · Dashboard cards · About · Dock. Show emails is the Emails key in the window's top strip. The history period and which charts to show are set on the
/// dashboard itself, as filters.
struct DashboardSettings: View {
    @ObservedObject private var prefs = DashboardPrefs.shared
    var width: CGFloat = 1280

    var body: some View {
        SettingsColumns(width: width, groups: [[AnyView(faceCard), AnyView(cardsCard), AnyView(aboutCard)], [AnyView(DockCard())]])
    }

    @Environment(\.face) private var face

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
        TileKey(selected: selected) { TileText(title: "General", sub: "face · dashboard · Dock") }
    }
}
