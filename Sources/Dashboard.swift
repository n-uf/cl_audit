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

/// Settings ▸ General: Dashboard cards · Emails · Dock. The history period and which charts to show are set on the
/// dashboard itself, as filters.
struct DashboardSettings: View {
    @ObservedObject private var prefs = DashboardPrefs.shared
    var width: CGFloat = 1280

    var body: some View {
        SettingsColumns(width: width,
                        three: [[AnyView(cardsCard), AnyView(emailsCard), AnyView(aboutCard)], [AnyView(DockCard())]],
                        two: [[AnyView(cardsCard), AnyView(emailsCard), AnyView(aboutCard)], [AnyView(DockCard())]],
                        one: [AnyView(cardsCard), AnyView(emailsCard), AnyView(DockCard()), AnyView(aboutCard)])
    }

    @ObservedObject private var privacy = Privacy.shared
    var emailsCard: some View {
        SCard(title: "Emails") {
            SRow(label: "Show emails", info: "Off: email addresses are left out of the launcher, dashboard, panels and Dock menus, and blurred in Settings (hover to see one).", first: true) {
                Toggle("", isOn: Binding(get: { privacy.show }, set: { privacy.set(show: $0) })).smallSwitch()
            }
        }
    }

    // About: which build this is, and where its changes are listed
    var aboutCard: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return SCard(title: "About") {
            SRow(label: "Version", info: "Calendar versions: year, month of the release, then a counter within the month.", first: true) {
                Text("\(version) (build \(build))").font(.system(size: 12)).textSelection(.enabled)
            }
            SRow(label: "Changes") {
                Link("What's new", destination: URL(string: "https://github.com/n-uf/cl_audit/blob/main/CHANGELOG.md")!)
                    .font(.system(size: 12))
            }
        }
    }

    var cardsCard: some View {
        SCard(title: "Dashboard cards", info: "One card style for every profile on the dashboard. Each profile's panel design is set in its profile settings.") {
            SRow(label: "Card style", first: true, stacked: true) {
                PillPicker(options: PanelDesign.allCases, selection: $prefs.cardStyle, compact: true) { Self.short($0) }
                LimitsView(limits: Self.sampleLimits, design: prefs.cardStyle, large: false)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                    .padding(.top, 2)
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
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("General").font(.system(size: 12.5, weight: .semibold))
                Text("dashboard · Dock · emails").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .frame(minHeight: 30)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(selected ? 0.12 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(selected ? 0.3 : 0.07), lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
    }
}
