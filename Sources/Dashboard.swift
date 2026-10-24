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

/// Settings ▸ Dashboard: Dashboard cards · Usage history · Dock, in columns like the account page.
struct DashboardSettings: View {
    @ObservedObject private var prefs = DashboardPrefs.shared
    var width: CGFloat = 1280

    var body: some View {
        SettingsColumns(width: width,
                        three: [[AnyView(cardsCard)], [AnyView(historyCard)], [AnyView(DockCard())]],
                        two: [[AnyView(cardsCard), AnyView(historyCard)], [AnyView(DockCard())]],
                        one: [AnyView(cardsCard), AnyView(historyCard), AnyView(DockCard())])
    }

    var cardsCard: some View {
        SCard(title: "Dashboard cards", info: "One card style for every account on the dashboard. Each account's panel design is set under its Panels.") {
            SRow(label: "Card style", first: true, stacked: true) {
                PillPicker(options: PanelDesign.allCases, selection: $prefs.cardStyle, compact: true) { Self.short($0) }
                LimitsView(limits: Self.sampleLimits, design: prefs.cardStyle, large: false)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                    .padding(.top, 2)
            }
        }
    }

    var historyCard: some View {
        SCard(title: "Usage history") {
            SRow(label: "History period", info: "The period the dashboard opens with. Its 24 h / 7 d / 30 d switch changes it too.", first: true) {
                PillPicker(options: StatsRange.allCases, selection: $prefs.range, compact: true) { $0.title }
            }
            SRow(label: "Charts", stacked: true) {
                HStack(spacing: 6) {
                    ChartToggle(kind: .heatmap, title: "When you use Claude", on: $prefs.showHeatmap)
                    ChartToggle(kind: .bars, title: "Tokens per day", on: $prefs.showTokens)
                    ChartToggle(kind: .donut, title: "Where it goes", on: $prefs.showShares)
                }
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
                Text("Dashboard").font(.system(size: 12.5, weight: .semibold))
                Text("cards · history · Dock").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .frame(minHeight: 30)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(selected ? 0.12 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(selected ? 0.3 : 0.07), lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
    }
}

/// A dashboard chart as a small thumbnail you click to show or hide it.
struct ChartToggle: View {
    enum Kind { case heatmap, bars, donut }
    let kind: Kind
    let title: String
    @Binding var on: Bool
    @State private var hover = false

    private let accent = Color.accentPill

    var body: some View {
        Button { on.toggle() } label: {
            VStack(alignment: .leading, spacing: 5) {
                thumb.frame(height: 34).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.25)))
                Text(title).font(.system(size: 10.5)).foregroundStyle(on ? Color.primary : Color.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? accent.opacity(0.1) : Color.primary.opacity(hover ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? accent.opacity(0.7) : Color.primary.opacity(0.1), lineWidth: on ? 1.5 : 1))
            .overlay(alignment: .topTrailing) {
                ZStack {
                    if on { Circle().fill(accent); Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(.white) }
                    else { Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.2) }
                }
                .frame(width: 13, height: 13).padding(5)
            }
            .opacity(on ? 1 : 0.6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(on ? "Shown on the dashboard; click to hide" : "Hidden; click to show on the dashboard")
    }

    @ViewBuilder private var thumb: some View {
        switch kind {
        case .heatmap:
            let levels: [Double] = [0.15, 0.5, 0.3, 1, 0.8, 0.15, 0.3, 0.5, 0.8, 0.3, 0.15, 1, 0.5, 0.3, 0.15, 0.8, 0.3, 0.5, 1, 0.15, 0.5, 0.8, 0.3, 0.15]
            VStack(spacing: 1.5) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: 1.5) {
                        ForEach(0..<8, id: \.self) { c in RoundedRectangle(cornerRadius: 1).fill(accent.opacity(levels[r * 8 + c])).frame(height: 6) }
                    }
                }
            }
            .padding(.horizontal, 5)
        case .bars:
            HStack(alignment: .bottom, spacing: 2) {
                ForEach([0.3, 0.55, 0.4, 0.8, 0.65, 0.95, 0.5], id: \.self) { h in
                    RoundedRectangle(cornerRadius: 1).fill(accent).frame(height: 26 * h)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 4).frame(maxHeight: .infinity, alignment: .bottom)
        case .donut:
            ZStack {
                ForEach(Array(zip([0.0, 0.45, 0.7, 0.88], [0.45, 0.7, 0.88, 1.0]).enumerated()), id: \.offset) { i, seg in
                    Circle().trim(from: seg.0, to: seg.1)
                        .stroke([accent, Color.blue, Color.teal, Color.purple][i], lineWidth: 5)
                }
            }
            .rotationEffect(.degrees(-90))
            .frame(width: 22, height: 22)
        }
    }
}
