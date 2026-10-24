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

    var names: [String: String] { Dictionary(uniqueKeysWithValues: stats.accounts.map { ($0.id, $0.name) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Usage history").font(.title3.weight(.semibold))
                if stats.loading { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(stats.totalReplies) replies · \(StatsFormat.tokens(stats.totalTokens)) tokens")
                    .font(.caption).foregroundStyle(.secondary)
                PillPicker(options: StatsRange.allCases, selection: $stats.range) { $0.title }
            }
            // Which charts to show: filters for this view, kept between launches.
            HStack(spacing: 8) {
                Text("Show").font(.caption).foregroundStyle(.secondary)
                WrapChips(items: [("When you use Claude", prefs.showHeatmap),
                                  (stats.range == .day ? "Tokens per hour" : "Tokens per day", prefs.showTokens),
                                  ("Where it goes", prefs.showShares)]) { i in
                    switch i {
                    case 0: prefs.showHeatmap.toggle()
                    case 1: prefs.showTokens.toggle()
                    default: prefs.showShares.toggle()
                    }
                }
            }
            if !prefs.showHeatmap && !prefs.showTokens && !prefs.showShares {
                Text("All charts are hidden; pick one above.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
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
            ChartCard(title: "Where it goes", note: "share of tokens in the period") {
                HStack(alignment: .top, spacing: 18) {
                    ShareList(title: "By project", rows: stats.breakdown.projects)
                    ShareList(title: "By model", rows: stats.breakdown.models)
                    ShareList(title: "By surface", rows: stats.breakdown.surfaces)
                }
            }
            }
            HStack(spacing: 14) {
                ForEach(stats.accounts) { e in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3).fill(stats.color(e.id)).frame(width: 10, height: 10)
                        Text(e.name)
                    }
                }
                Spacer()
                Text("From the session files on this Mac (terminal, desktop Code tab, VS Code, SDK apps).")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        // the period is remembered between launches
        .onAppear { if stats.range != prefs.range { stats.range = prefs.range } }
        .onChange(of: prefs.range) { r in if stats.range != r { stats.range = r } }
    }
}

struct ChartCard<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
    }
}

/// Days × hours; each cell's colour mixes the accounts by their share of that hour's replies,
/// its strength follows the number of replies.
struct Heatmap: View {
    @ObservedObject var stats: StatsModel

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
                            ctx.fill(path, with: .color(Color.primary.opacity(0.06)))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if rows.isEmpty { Text("–").foregroundStyle(.secondary) }
            ForEach(rows) { r in
                HStack(spacing: 8) {
                    Text(r.name).font(.caption).lineLimit(1).frame(width: 110, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(r.color.opacity(0.9)).frame(width: max(4, g.size.width * r.share))
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
