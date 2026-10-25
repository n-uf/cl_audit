// The dashboard's "Usage history": when you use Claude (heatmap), tokens per day, and where they go.

import Charts
import SwiftUI

enum StatsFormat {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        return d >= 1e9 ? String(format: "%.1fB", d / 1e9) : d >= 1e6 ? String(format: "%.1fM", d / 1e6)
            : d >= 1e3 ? String(format: "%.0fK", d / 1e3) : "\(n)"
    }
}

struct StatsSection: View {
    @ObservedObject var stats: StatsModel
    @ObservedObject private var prefs = DashboardPrefs.shared
    @Environment(\.face) private var face

    var names: [String: String] { Dictionary(uniqueKeysWithValues: stats.accounts.map { ($0.id, $0.name) }) }

    private var title: some View {
        HStack(spacing: 8) {
            Text("Usage history").font(.system(size: 17, weight: .semibold)).foregroundStyle(face.text).fixedSize()
            if stats.loading { ProgressView().controlSize(.small) }
        }
    }

    /// Which charts to show (kept between launches): a key each, latched while shown.
    private var chartKeys: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                let (name, on): (String, Bool) = [("When you use Claude", prefs.showHeatmap),
                                                  (stats.range == .day ? "Tokens per hour" : "Tokens per day", prefs.showTokens),
                                                  ("Where it goes", prefs.showShares)][i]
                Button {
                    switch i {
                    case 0: prefs.showHeatmap.toggle()
                    case 1: prefs.showTokens.toggle()
                    default: prefs.showShares.toggle()
                    }
                } label: { KeyLook(latched: on, height: 22, hPad: 10) { Text(name) } }
                .buttonStyle(PressableKey())
            }
        }
        .fixedSize()
    }

    /// Replies and tokens in the period: black glass (on Silver too), like the site.
    private var totals: some View {
        DisplayWindow(text: "\(stats.totalReplies.formatted()) replies", dim: "· \(StatsFormat.tokens(stats.totalTokens)) tokens", black: true)
    }

    private var period: some View {
        KeyPicker(options: StatsRange.allCases, selection: $stats.range) { $0.title }.fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // one line: the title, which charts to show, the totals and the period; two lines when narrow
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { title; chartKeys; Spacer(minLength: 8); totals; period }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) { title; Spacer(minLength: 8); totals; period }
                    chartKeys
                }
            }
            if !prefs.showHeatmap && !prefs.showTokens && !prefs.showShares {
                Text("All charts are hidden; pick one above.").font(.callout).foregroundStyle(face.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                    .faceWindow(radius: 6)
            }
            if prefs.showHeatmap {
            ChartCard(title: "When you use Claude", note: "replies per hour · colour mixes the accounts") {
                Heatmap(stats: stats)
            }
            }
            if prefs.showTokens {
            ChartCard(title: stats.range == .day ? "Tokens per hour" : "Tokens per day",
                      note: "input + cache writes + output · cache reads not counted") {
                TokenChart(stats: stats, names: names)
            }
            }
            if prefs.showShares {
            ChartCard(title: "Where it goes", note: "share of tokens in the period", screen: false) {
                HStack(alignment: .top, spacing: 18) {
                    ShareList(title: "By project", rows: stats.breakdown.projects)
                    ShareList(title: "By model", rows: stats.breakdown.models)
                    ShareList(title: "By surface", rows: stats.breakdown.surfaces)
                }
            }
            }
            HStack(spacing: 14) {
                ForEach(stats.accounts) { e in
                    HStack(spacing: 6) {
                        LED(color: stats.color(e.id))
                        Text(e.name).foregroundStyle(face.soft)
                    }
                }
                Spacer()
                Text("From the session files on this Mac (terminal, desktop Code tab, VS Code, SDK apps).")
            }
            .font(.caption).foregroundStyle(face.muted)
        }
        // the period is remembered between launches
        .onAppear { if stats.range != prefs.range { stats.range = prefs.range } }
        .onChange(of: prefs.range) { r in if stats.range != r { stats.range = r } }
    }
}

/// A chart module: a printed title and note over a recessed screen.
struct ChartCard<Content: View>: View {
    let title: String
    let note: String
    var screen = true
    @ViewBuilder let content: Content
    @Environment(\.face) private var face

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Printed(text: title)
                Spacer()
                Text(note).font(.system(size: 11)).foregroundStyle(face.muted)
            }
            if screen { content.padding(10).faceWindow(radius: 6, chart: true) } else { content }
        }
        .padding(14)
        .background(RaisedShape(finish: face.module, radius: face.moduleRadius))
    }
}

/// Days × hours; each cell's colour mixes the accounts by their share of that hour's replies,
/// its strength follows the number of replies.
struct Heatmap: View {
    @ObservedObject var stats: StatsModel
    @Environment(\.face) private var face

    var body: some View {
        let rows = stats.heat.count
        let cellH: CGFloat = rows > 10 ? 9 : 20
        let maxCount = max(stats.heat.flatMap { $0 }.map { $0.values.reduce(0, +) }.max() ?? 1, 1)
        let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = rows > 10 ? "d MMM" : "EEE d"; return f }()
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text("").frame(width: 54)
                GeometryReader { g in
                    ForEach([0, 3, 6, 9, 12, 15, 18, 21], id: \.self) { h in
                        Text(String(format: "%02d", h)).font(.system(size: 9.5)).foregroundStyle(.secondary)
                            .position(x: g.size.width * (CGFloat(h) + 0.5) / 24, y: 6)
                    }
                }
                .frame(height: 12)
            }
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 0) {
                    Text(r < stats.heatDays.count ? df.string(from: stats.heatDays[r]) : "")
                        .font(.system(size: rows > 10 ? 8.5 : 10.5)).foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .leading)
                    Canvas { ctx, size in
                        let w = size.width / 24
                        for h in 0..<24 {
                            let counts = stats.heat[r][h]
                            let total = counts.values.reduce(0, +)
                            let rect = CGRect(x: CGFloat(h) * w + 1.5, y: 1, width: w - 3, height: size.height - 2)
                            let path = Path(roundedRect: rect, cornerRadius: min(4, rect.height / 3))
                            ctx.fill(path, with: .color(face.light ? Color.black(0.06) : Color.white(0.05)))
                            guard total > 0 else { continue }
                            ctx.fill(path, with: .color(mix(counts).opacity(0.18 + 0.82 * min(1, Double(total) / Double(maxCount)))))
                        }
                    }
                    .frame(height: cellH)
                }
            }
        }
    }

    /// The accounts' colours averaged by their reply counts.
    func mix(_ counts: [String: Int]) -> Color {
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for (acc, c) in counts {
            guard let ns = NSColor(stats.color(acc)).usingColorSpace(.sRGB) else { continue }
            r += ns.redComponent * Double(c); g += ns.greenComponent * Double(c); b += ns.blueComponent * Double(c); n += Double(c)
        }
        return n > 0 ? Color(.sRGB, red: r / n, green: g / n, blue: b / n) : .gray
    }
}

struct TokenChart: View {
    @ObservedObject var stats: StatsModel
    let names: [String: String]

    var body: some View {
        let ids = stats.accounts.map(\.id)
        let known = Set(ids)
        let bars = stats.bars.filter { known.contains($0.account) }
        if ids.isEmpty {
            Text("No profile selected").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 190)
        } else {
            chart(bars, ids: ids)
        }
    }

    func chart(_ bars: [TokenBar], ids: [String]) -> some View {
        Chart(bars) { b in
            BarMark(x: .value("Time", b.bucket, unit: stats.range == .day ? .hour : .day),
                    y: .value("Tokens", b.tokens))
                .foregroundStyle(by: .value("Account", names[b.account] ?? b.account))
                .cornerRadius(3)
        }
        .chartForegroundStyleScale(domain: ids.map { names[$0] ?? $0 }, range: ids.map { stats.color($0) })
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let n = v.as(Int.self) { Text(StatsFormat.tokens(n)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: stats.range == .month ? 10 : 8)) { _ in
                AxisGridLine()
                AxisValueLabel(format: stats.range == .day ? .dateTime.hour() : .dateTime.weekday(.abbreviated).day())
            }
        }
        .frame(height: 190)
        .overlay {
            if bars.isEmpty && !stats.loading {
                Text("No Claude Code activity in this period").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct ShareList: View {
    let title: String
    let rows: [ShareRow]
    @Environment(\.face) private var face

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Printed(text: title, size: 9)
            if rows.isEmpty { Text("–").foregroundStyle(.secondary) }
            ForEach(rows) { r in
                HStack(spacing: 8) {
                    Text(r.name).font(.caption).lineLimit(1).frame(width: 110, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            // a meter sunk into the plate
                            RoundedRectangle(cornerRadius: 2).fill(face.meterOff)
                            RoundedRectangle(cornerRadius: 1.5).fill(r.color.opacity(0.9)).frame(width: max(4, g.size.width * r.share))
                                .padding(1)
                        }
                    }
                    .frame(height: 8)
                    Text("\(Int((r.share * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
