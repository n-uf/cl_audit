// Panel designs: the five ways the compact and the large panel draw the two limits.
// Bars, rings and segments are drawn by the app so they keep their colour while it isn't in front.

import AppKit
import SwiftUI

enum PanelDesign: String, Codable, CaseIterable, Identifiable {
    case glow, rings, numbers, segments, pace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glow: return "Glow bars"
        case .rings: return "Twin rings"
        case .numbers: return "Big numbers"
        case .segments: return "Segmented"
        case .pace: return "Pace bars"
        }
    }
}

/// How much of a limit's window has already passed, in %, from its reset time.
func windowElapsed(_ resets: Date?, _ window: TimeInterval) -> Double? {
    guard let resets else { return nil }
    return min(max(1 - resets.timeIntervalSinceNow / window, 0), 1) * 100
}

/// One limit as the panels show it.
struct Limit: Identifiable {
    let id: String
    let title: String          // "5-hour session"
    let name: String           // "5-hour"
    let p: Double?
    let resets: Date?
    let window: TimeInterval   // length of the limit's window

    /// How much of the window has already passed, in %, from the reset time.
    var elapsed: Double? { windowElapsed(resets, window) }
    var color: Color { Color(nsColor: Painter.color(p, stale: false)) }
    var frac: CGFloat { CGFloat(min(max(p ?? 0, 0), 100)) / 100 }
}

extension DetailsInfo {
    var limits: [Limit] {
        [Limit(id: "5h", title: "5-hour session", name: "5-hour", p: fiveHour, resets: fiveHourResets, window: 5 * 3600),
         Limit(id: "wk", title: "Week", name: "Week", p: weekly, resets: weeklyResets, window: 7 * 86400)]
    }
}

struct LimitsView: View {
    let limits: [Limit]
    let design: PanelDesign
    let large: Bool
    @Environment(\.face) private var face

    var body: some View {
        switch design {
        case .glow:
            VStack(spacing: large ? 12 : 8) { ForEach(limits) { glow($0) } }
        case .rings:
            HStack(spacing: large ? 28 : 16) { ForEach(limits) { ring($0) } }.frame(maxWidth: .infinity)
        case .numbers:
            HStack(alignment: .top, spacing: 16) { ForEach(limits) { number($0) } }
        case .segments:
            VStack(spacing: large ? 12 : 9) { ForEach(limits) { segments($0) } }
        case .pace:
            VStack(spacing: large ? 12 : 9) { ForEach(limits) { pace($0) } }
        }
    }

    func pct(_ l: Limit, _ size: CGFloat) -> some View {
        Text(Painter.pct(l.p)).font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(l.p == nil ? Color.secondary : face.levelColor(l.p))
    }

    func resets(_ l: Limit) -> some View {
        Group {
            if let r = l.resets {
                Text(large ? "Resets \(DetailsFormat.until(r))" : "resets in \(DetailsFormat.short(r))")
            } else {
                Text(" ")
            }
        }
        .font(large ? .caption : .caption2).foregroundStyle(.secondary)
    }

    // Glow bars: bar per limit with the % on the right and the reset time under it.
    func glow(_ l: Limit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(large ? l.title : l.name).font(large ? .body : .callout.weight(.medium))
                Spacer()
                pct(l, large ? 15 : 13)
            }
            LevelBar(p: l.p, height: large ? 9 : 7)
            resets(l)
        }
    }

    // Twin rings: like Activity rings, the % inside, name and reset time under.
    func ring(_ l: Limit) -> some View {
        let d: CGFloat = large ? 96 : 66, w: CGFloat = large ? 10 : 7
        return VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: w)
                Circle().trim(from: 0, to: l.frac)
                    .stroke(l.color, style: StrokeStyle(lineWidth: w, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: l.color.opacity(0.5), radius: 4)
                Text(Painter.pct(l.p)).font(.system(size: large ? 21 : 15, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .frame(width: d, height: d)
            .padding(.bottom, 2)
            Text(l.name).font((large ? Font.callout : .caption).weight(.semibold))
            resets(l)
        }
    }

    // Big numbers: large coloured % with a thin bar and the reset time.
    func number(_ l: Limit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(l.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(l.p.map { "\(Int($0.rounded()))" } ?? "–")
                    .font(.system(size: large ? 42 : 30, weight: .heavy, design: .rounded)).monospacedDigit()
                Text("%").font(.system(size: large ? 20 : 15, weight: .bold, design: .rounded))
            }
            .foregroundStyle(l.p == nil ? Color.secondary : l.color)
            LevelBar(p: l.p, height: 4, glow: false)
            resets(l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Segmented: twelve segments lighting up green → amber → red along the way.
    func segments(_ l: Limit) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(large ? l.title : l.name).font((large ? Font.body : .callout).weight(.semibold))
                if let r = l.resets { Text("· in \(DetailsFormat.short(r))").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                pct(l, large ? 15 : 13)
            }
            SegmentBar(p: l.p, height: large ? 11 : 9)
        }
    }

    // Pace bars: a marker for how much of the window has passed, and whether usage is ahead of it.
    func pace(_ l: Limit) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(large ? l.title : l.name).font((large ? Font.body : .callout).weight(.semibold))
                PaceChip(p: l.p, elapsed: l.elapsed)
                Spacer()
                pct(l, large ? 15 : 13)
            }
            LevelBar(p: l.p, height: large ? 10 : 8, marker: l.elapsed).padding(.vertical, 4)
            if let r = l.resets, let e = l.elapsed {
                Text("resets in \(DetailsFormat.short(r)) · \(Int(e.rounded()))% of the window gone")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct SegmentBar: View {
    let p: Double?
    var height: CGFloat = 9
    let count = 12
    @Environment(\.face) private var face

    var body: some View {
        let lit = Int(((p ?? 0) / 100 * Double(count)).rounded())
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                let zone = Double(i + 1) / Double(count) * 100
                let c = Color(nsColor: zone > 80 ? Painter.red : zone > 50 ? Painter.amber : Painter.green)
                // inside the window an unlit segment is sunk into the plate
                RoundedRectangle(cornerRadius: face.active ? 1.5 : 2)
                    .fill(i < lit ? AnyShapeStyle(c) : face.meterOff)
                    .brightness(i < lit && face.active && face.light ? -0.08 : 0)
                    .shadow(color: i < lit && !(face.active && face.light) ? c.opacity(0.5) : .clear, radius: 2.5)
            }
        }
        .frame(height: height)
    }
}

struct PaceChip: View {
    let p: Double?
    let elapsed: Double?

    var body: some View {
        if let p, let e = elapsed {
            let d = p - e
            let (text, tint): (String, Color) = d > 10 ? ("ahead of pace", .red) : d < -10 ? ("room to spare", .green) : ("on pace", .gray)
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(tint == .gray ? Color.primary.opacity(0.8) : tint)
        }
    }
}
