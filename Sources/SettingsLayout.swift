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

/// The Claude open dot, picked like a colour: the profile's icon without and with the dot.
struct DotChoice: View {
    @Binding var entry: AccountEntry
    var body: some View {
        HStack(spacing: 8) {
            ForEach([false, true], id: \.self) { on in
                Button { entry.windowDot = on } label: {
                    VStack(spacing: 3) {
                        Image(nsImage: tile(on)).resizable().frame(width: 30, height: 30)
                        Text(on ? "while open" : "none").font(.system(size: 10, weight: entry.windowDot == on ? .semibold : .regular))
                            .foregroundStyle(entry.windowDot == on ? Color.primary : Color.secondary)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(entry.windowDot == on ? Color.primary.opacity(0.1) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

// MARK: - Opening and closing

/// Two plain questions, one per cause, and a table of what each action then does to the other one.
struct OpenCloseQuestions: View {
    let profile: String
    @Binding var lifecycle: Lifecycle

    private var iconFollows: Bool { lifecycle.usageFollowsWindow }
    private var windowFollows: Bool { lifecycle.windowFollowsUsage }
    private func set(iconFollows a: Bool, windowFollows b: Bool) {
        lifecycle = a ? (b ? .lockstep : .usageFollows) : (b ? .windowFollows : .independent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            question("When \(profile)'s Claude window opens or quits", options: [
                ("leave the Dock icon alone", nil),
                ("start or quit the Dock icon too", "it quits 10 s after the window; starting needs cl_audit running")],
                     selected: iconFollows ? 1 : 0) { set(iconFollows: $0 == 1, windowFollows: windowFollows) }
            question("When \(profile)'s Dock icon starts or quits", options: [
                ("leave the Claude window alone", nil),
                ("open or quit the Claude window too", "not at login; Claude asks about unsent work")],
                     selected: windowFollows ? 1 : 0) { set(iconFollows: iconFollows, windowFollows: $0 == 1) }
            result
        }
    }

    private func question(_ title: String, options: [(String, String?)], selected: Int, pick: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary)
            ForEach(options.indices, id: \.self) { i in
                Button { pick(i) } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Circle().strokeBorder(i == selected ? Color.primary : Color.secondary, lineWidth: i == selected ? 4 : 1.3)
                            .frame(width: 12, height: 12).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(options[i].0).font(.system(size: 12, weight: i == selected ? .medium : .regular))
                            if let note = options[i].1 { Text(note).font(.system(size: 10)).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.07)))
    }

    /// The four things you can do and what happens to the other one.
    private var result: some View {
        let title: String = {
            switch lifecycle {
            case .independent: return "Independent"
            case .usageFollows: return "The Dock icon follows the window"
            case .windowFollows: return "The window follows the Dock icon"
            case .lockstep: return "Together"
            }
        }()
        let rows: [(Bool, String, String?, String?)] = [
            (true, "You open the window", iconFollows ? "Dock icon starts" : nil, nil),
            (true, "You quit the window", iconFollows ? "Dock icon quits" : nil, "10 s later"),
            (false, "You start the Dock icon", windowFollows ? "window opens" : nil, "not at login"),
            (false, "You quit the Dock icon", windowFollows ? "window quits" : nil, iconFollows ? "or ⌥ Quit and keep" : "Claude may ask")]
        return VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 12, weight: .bold))
                Spacer()
                Text(profile).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.accentPill.opacity(0.14))
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i]
                HStack(spacing: 8) {
                    Group {
                        if r.0 {
                            RoundedRectangle(cornerRadius: 2).fill(LinearGradient(colors: [Color(red: 0.88, green: 0.54, blue: 0.41), Color(red: 0.79, green: 0.39, blue: 0.25)], startPoint: .top, endPoint: .bottom)).frame(width: 14, height: 10)
                        } else {
                            RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.12)).overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.35))).frame(width: 10, height: 10)
                        }
                    }
                    .frame(width: 14)
                    Text(r.1).font(.system(size: 11.5)).foregroundStyle(Color.primary.opacity(0.8)).frame(width: 150, alignment: .leading)
                    if let effect = r.2 {
                        Text(effect).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(nsColor: Painter.green))
                            .padding(.horizontal, 8).padding(.vertical, 1)
                            .background(Capsule().fill(Color(nsColor: Painter.green).opacity(0.16)))
                        if let note = r.3 { Text(note).font(.system(size: 10)).foregroundStyle(.secondary) }
                    } else {
                        Text("not touched").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.09)))
        .padding(.top, 4)
    }
}
