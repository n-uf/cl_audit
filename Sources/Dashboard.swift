// Dashboard settings (app-wide, in the settings app's preferences): one card style for every account card,
// the history period (the dashboard's 24 h / 7 d / 30 d switch is the same setting), and which history
// charts to show. Edited on Settings ▸ Dashboard.

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

/// Settings ▸ Dashboard.
struct DashboardSettings: View {
    @ObservedObject private var prefs = DashboardPrefs.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SCard(title: "Dashboard cards", info: "One style for every account card on the dashboard. Each account's own panel design (Settings ▸ account ▸ Panels) is for its panels.") {
                SRow(label: "Card style", first: true) {
                    PillPicker(options: PanelDesign.allCases, selection: $prefs.cardStyle, compact: true) { Self.short($0) }
                }
                LimitsView(limits: Self.sampleLimits, design: prefs.cardStyle, large: false)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                    .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity)

            SCard(title: "Usage history") {
                SRow(label: "History period", info: "The period the dashboard opens with; the 24 h / 7 d / 30 d switch there changes it too.", first: true) {
                    PillPicker(options: StatsRange.allCases, selection: $prefs.range, compact: true) { $0.title }
                }
                SRow(label: "When you use Claude") { Toggle("", isOn: $prefs.showHeatmap).smallSwitch() }
                SRow(label: "Tokens per day") { Toggle("", isOn: $prefs.showTokens).smallSwitch() }
                SRow(label: "Where it goes") { Toggle("", isOn: $prefs.showShares).smallSwitch() }
            }
            .frame(maxWidth: .infinity)
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
                Text("Dashboard").font(.system(size: 12.5, weight: .semibold))
                Text("cards · history").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .frame(minHeight: 30)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(selected ? 0.12 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(selected ? 0.3 : 0.07), lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
    }
}
