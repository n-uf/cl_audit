// Settings layout pieces: columns that follow the window width (cards never stretch into long forms), a
// colour row that wraps, and the small pictures some (i) explanations carry.

import SwiftUI

/// Settings cards laid out like blocks: as many columns as fit (each 340–460 pt wide, never stretched past
/// that), every card going into the shortest column in turn, so a wide window gets more columns instead of
/// wider cards. `one` is the order; `three` and `two` are kept for callers that still pass them.
struct SettingsColumns: View {
    let width: CGFloat
    let three: [[AnyView]]
    let two: [[AnyView]]
    let one: [AnyView]

    static let minColumn: CGFloat = 340
    static let maxColumn: CGFloat = 460

    var body: some View {
        Masonry(minColumn: Self.minColumn, maxColumn: Self.maxColumn, spacing: 10) {
            ForEach(one.indices, id: \.self) { i in one[i] }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Columns of a fixed width; each child goes into the shortest column (empty children take no room).
struct Masonry: Layout {
    var minColumn: CGFloat = 340
    var maxColumn: CGFloat = 460
    var spacing: CGFloat = 10

    private func columns(_ width: CGFloat) -> (n: Int, w: CGFloat) {
        let n = max(1, Int(((width + spacing) / (minColumn + spacing)).rounded(.down)))
        return (n, min(maxColumn, (width - CGFloat(n - 1) * spacing) / CGFloat(n)))
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], w: CGFloat, size: CGSize) {
        let (n, w) = columns(width)
        var heights = Array(repeating: CGFloat(0), count: n)
        var points: [CGPoint] = []
        for s in subviews {
            let h = s.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            guard h >= 1 else { points.append(.zero); continue }
            let c = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let y = heights[c] == 0 ? 0 : heights[c] + spacing
            points.append(CGPoint(x: CGFloat(c) * (w + spacing), y: y))
            heights[c] = y + h
        }
        let used = heights.filter { $0 > 0 }.count
        return (points, w, CGSize(width: CGFloat(max(used, 1)) * w + CGFloat(max(used, 1) - 1) * spacing, height: heights.max() ?? 0))
    }

    private func usable(_ proposal: ProposedViewSize) -> CGFloat {
        guard let w = proposal.width, w.isFinite, w > 0 else { return 3 * maxColumn + 2 * spacing }
        return w
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let a = arrange(subviews, width: usable(proposal))
        return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? a.size.width, height: a.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let a = arrange(subviews, width: bounds.width)
        for (i, s) in subviews.enumerated() {
            s.place(at: CGPoint(x: bounds.minX + a.points[i].x, y: bounds.minY + a.points[i].y),
                    proposal: ProposedViewSize(width: a.w, height: nil))
        }
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
                MiniWindow(label: "standard")
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
    @Environment(\.face) private var face
    var body: some View {
        HStack(spacing: 8) {
            ForEach([false, true], id: \.self) { on in
                Button { entry.windowDot = on } label: {
                    VStack(spacing: 3) {
                        Image(nsImage: tile(on)).resizable().frame(width: 30, height: 30)
                        Text(on ? "while open" : "none").font(.system(size: 10, weight: entry.windowDot == on ? .semibold : .regular))
                            .foregroundStyle(entry.windowDot == on ? face.text : face.muted)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background { if entry.windowDot == on { WellShape(well: face.win, radius: 6) } }
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
    @Environment(\.face) private var face

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
            Text(title).font(.system(size: 11.5)).foregroundStyle(face.muted).padding(.bottom, 1)
            ForEach(options.indices, id: \.self) { i in
                Button { pick(i) } label: {
                    HStack(alignment: .top, spacing: 7) {
                        LEDRadio(on: i == selected).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(options[i].0).font(.system(size: 12, weight: i == selected ? .medium : .regular))
                            if let note = options[i].1 { Text(note).font(.system(size: 10)).foregroundStyle(face.muted) }
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
        .faceWindow(radius: 6)
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
        // cause → what then happens to the other one (or that it is left alone)
        let rows: [(Bool, String, String?, String?)] = [
            (true, "Claude window opens", iconFollows ? "Dock icon starts" : nil, nil),
            (true, "Claude window quits", iconFollows ? "Dock icon quits" : nil, "10 s later"),
            (false, "Dock icon starts", windowFollows ? "Claude window opens" : nil, "not at login"),
            (false, "Dock icon quits", windowFollows ? "Claude window quits" : nil, iconFollows ? "or ⌥ Quit and keep" : "Claude may ask")]
        return VStack(spacing: 0) {
            HStack {
                Printed(text: title, size: 9)
                Spacer()
                Text(profile).font(.system(size: 10.5)).foregroundStyle(face.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.black(face.light ? 0.05 : 0.25))
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i]
                HStack(spacing: 8) {
                    Text(r.1).font(.system(size: 11.5)).foregroundStyle(face.soft).lineLimit(1)
                        .frame(width: 128, alignment: .leading)
                    Image(systemName: "arrow.right").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(face.faint)
                    if let effect = r.2 {
                        // the effect glows like a display's printing
                        Text(effect).font(.system(size: 9.5, weight: .semibold, design: .monospaced)).tracking(0.6).textCase(.uppercase)
                            .foregroundStyle(face.displayText)
                            .shadow(color: face.displayGlow ? face.displayText.opacity(0.6) : .clear, radius: 1.5)
                            .lineLimit(1).fixedSize()
                        if let note = r.3 { Text(note).font(.system(size: 10)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true) }
                    } else {
                        Text(r.0 ? "Dock icon left alone" : "Claude window left alone").font(.system(size: 11)).foregroundStyle(face.faint)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(alignment: .top) { Rectangle().fill(face.light ? Color.black(0.08) : Color.white(0.06)).frame(height: 1) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .faceWindow(radius: 6)
        .padding(.top, 4)
    }
}
