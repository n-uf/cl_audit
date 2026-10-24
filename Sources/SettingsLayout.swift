// Settings layout pieces: columns that follow the window width (cards never stretch into long forms), a
// colour row that wraps, and the small pictures some (i) explanations carry.

import SwiftUI

/// Cards in three columns from 1180 pt, two from 800, one below. A column is at most 460 pt wide, so a very
/// wide window gets empty space on the right, not long rows.
struct SettingsColumns: View {
    let width: CGFloat
    let three: [[AnyView]]
    let two: [[AnyView]]
    let one: [AnyView]

    static let maxColumn: CGFloat = 460

    var body: some View {
        let cols = width >= 1180 ? three : width >= 800 ? two : [one]
        HStack(alignment: .top, spacing: 10) {
            ForEach(cols.indices, id: \.self) { i in
                VStack(spacing: 10) {
                    ForEach(cols[i].indices, id: \.self) { j in cols[i][j] }
                }
                .fixedSize(horizontal: false, vertical: true)    // a short column never stretches to a tall one's height
                .frame(maxWidth: Self.maxColumn, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Colour swatches that wrap onto a second line when the column is narrow; optionally a "none" choice first.
struct SwatchRow: View {
    let colors: [TileColor]
    let selected: TileColor?
    var none = false
    let pick: (TileColor?) -> Void

    var body: some View {
        FlowLayout(spacing: 2) {
            if none { NoneSwatch(selected: selected == nil, size: 14).onTapGesture { pick(nil) }.help("No frame") }
            ForEach(colors, id: \.self) { c in
                Swatch(color: c, selected: selected == c, size: 14).onTapGesture { pick(c) }.help(c.title)
            }
        }
    }
}

// MARK: - Pictures inside (i)

private struct MiniIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.2)))
            .frame(width: 22, height: 22)
    }
}

private struct MiniPanel: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
            .overlay(VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(Color(nsColor: Painter.green)).frame(width: 30, height: 3)
                Capsule().fill(Color.orange).frame(width: 40, height: 3)
            }.padding(6), alignment: .topLeading)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
            .frame(width: 60, height: 30)
    }
}

private struct MiniWindow: View {
    var label: String? = nil
    var hue: Double = 0
    var body: some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Color(red: 0.88, green: 0.54, blue: 0.41), Color(red: 0.79, green: 0.39, blue: 0.25)], startPoint: .top, endPoint: .bottom))
                .hueRotation(.degrees(hue))
                .frame(width: 36, height: 24)
            if let label { Text(label).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
    }
}

private struct Arrow: View {
    var body: some View { Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
}

/// What a click on the Dock icon opens, for the chosen action.
struct ClickPicture: View {
    let action: ClickAction
    let seconds: Double

    var body: some View {
        HStack(spacing: 7) {
            MiniIcon()
            Arrow()
            switch action {
            case .peekThenOpen:
                MiniPanel()
                Text(PeekDuration.text(seconds)).font(.system(size: 10)).foregroundStyle(.secondary)
                Arrow()
                MiniWindow()
            case .details:
                MiniPanel()
            case .open:
                MiniWindow()
            }
        }
    }
}

/// Which Claude window an account opens.
struct WindowPicture: View {
    let mode: DesktopMode

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            switch mode {
            case .standard:
                MiniWindow(label: "standard, shared")
            case .separate:
                MiniWindow(label: "standard")
                MiniWindow(label: "its own", hue: 140)
            case .none:
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.6))
                    .overlay(Text(">_").font(.system(size: 9, design: .monospaced)).foregroundStyle(.green).padding(4), alignment: .topLeading)
                    .frame(width: 36, height: 24)
                Text("Claude Code in Terminal only").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 5)
            }
        }
    }
}

/// The account's icon with and without the window-open dot.
struct DotPicture: View {
    let entry: AccountEntry
    var body: some View {
        HStack(spacing: 14) {
            ForEach([false, true], id: \.self) { open in
                VStack(spacing: 3) {
                    Image(nsImage: tile(open)).resizable().frame(width: 40, height: 40)
                    Text(open ? "window open" : "window closed").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func tile(_ open: Bool) -> NSImage {
        var m = TileModel(label: entry.label.isEmpty ? "?" : entry.label, fiveHour: 26, weekly: 12, stale: false,
                          style: entry.style, tint: entry.color, frame: entry.frame, fiveHourElapsed: 40, weeklyElapsed: 50)
        m.windowOpen = open
        return Painter.image(m, pixels: 96)
    }
}

// MARK: - cl_usage and its Claude window

/// The four ways a profile's cl_usage and its Claude window can open and close, as pictures:
/// cl_usage on the left, the Claude window on the right, the arrow pointing at whoever follows.
struct LifecycleChooser: View {
    @Binding var selection: Lifecycle

    private static let options: [(Lifecycle, String, String)] = [
        (.independent, "Independent", "each on its own"),
        (.usageFollows, "cl_usage follows", "the window leads"),
        (.windowFollows, "Window follows", "cl_usage leads"),
        (.lockstep, "Lockstep", "either one leads")]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Self.options, id: \.0) { o in tile(o.0, o.1, o.2) }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Self.lines(selection), id: \.self) { l in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("→").foregroundStyle(Color.accentPill)
                        Text(l).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    /// What the chosen mode does, spelled out.
    static func lines(_ m: Lifecycle) -> [String] {
        switch m {
        case .independent: return ["cl_usage and its Claude window open and close on their own"]
        case .usageFollows: return ["Claude window opens → cl_usage starts (while cl_audit runs)",
                                    "Claude window quits → cl_usage quits, after 10 s",
                                    "cl_usage on its own → the window isn't touched"]
        case .windowFollows: return ["cl_usage starts → its Claude window opens (not at login)",
                                     "cl_usage quits → its Claude window quits; Claude asks about unsent work",
                                     "the window on its own → cl_usage isn't touched"]
        case .lockstep: return ["either one opens → the other opens (cl_usage: while cl_audit runs; window: not at login)",
                                "either one quits → the other quits",
                                "cl_usage menu ▸ Quit and keep Claude window: quits only cl_usage"]
        }
    }

    private func tile(_ m: Lifecycle, _ title: String, _ sub: String) -> some View {
        let on = selection == m
        return Button { selection = m } label: {
            VStack(spacing: 6) {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.2)))
                        .frame(width: 18, height: 18)
                    FollowArrow(mode: m).frame(width: 30, height: 10)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [Color(red: 0.88, green: 0.54, blue: 0.41), Color(red: 0.79, green: 0.39, blue: 0.25)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 24, height: 16)
                }
                Text(title).font(.system(size: 11, weight: on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.85)
                Text(sub).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, 7).padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? Color.accentPill.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Color.accentPill.opacity(0.75) : Color.primary.opacity(0.1), lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The line between cl_usage (left) and its window (right): dashed when independent, arrowheads at the follower.
struct FollowArrow: View {
    let mode: Lifecycle
    var body: some View {
        Canvas { ctx, size in
            let y = size.height / 2, w = size.width
            var line = Path(); line.move(to: CGPoint(x: 2, y: y)); line.addLine(to: CGPoint(x: w - 2, y: y))
            let color: Color = mode == .independent ? .secondary.opacity(0.6) : .primary
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.4, dash: mode == .independent ? [2, 3] : []))
            func head(_ x: CGFloat, _ dir: CGFloat) {
                var p = Path(); p.move(to: CGPoint(x: x + 4 * dir, y: y - 3.5)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + 4 * dir, y: y + 3.5))
                ctx.stroke(p, with: .color(color), lineWidth: 1.4)
            }
            if mode.usageFollowsWindow { head(2, 1) }        // points at cl_usage: it follows
            if mode.windowFollowsUsage { head(w - 2, -1) }   // points at the window: it follows
        }
    }
}
