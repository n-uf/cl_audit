// Settings layout pieces: columns that follow the window width (cards never stretch into long forms), a
// colour row that wraps, and the small pictures some (i) explanations carry.

import SwiftUI

/// Settings cards in groups, a group per column, in reading order: as many columns as fit (each 340–460 pt,
/// never stretched). When there are fewer columns than groups, the later groups stack in the last column, or, for
/// two columns, the `two` arrangement when one is given; with one column everything follows in order. Extra width
/// stays empty rather than widening cards.
struct SettingsColumns: View {
    let width: CGFloat
    let groups: [[AnyView]]
    var two: [[AnyView]]? = nil

    static let minColumn: CGFloat = 340
    static let maxColumn: CGFloat = 460
    static let spacing: CGFloat = 10

    var body: some View {
        // as many columns as fit, never more than there are groups: the width is shared by the columns in use, so cards
        // grow to 460 pt as the window widens instead of dropping back to 340 when a fourth column would fit
        let n = min(groups.count, max(1, Int(((width + Self.spacing) / (Self.minColumn + Self.spacing)).rounded(.down))))
        let w = min(Self.maxColumn, (width - CGFloat(n - 1) * Self.spacing) / CGFloat(n))
        let cols: [[AnyView]] = n >= groups.count ? groups
            : n == 1 ? [groups.flatMap { $0 }]
            : n == 2 && two != nil ? two!
            : Array(groups.prefix(n - 1)) + [groups.dropFirst(n - 1).flatMap { $0 }]
        HStack(alignment: .top, spacing: Self.spacing) {
            ForEach(cols.indices, id: \.self) { i in
                VStack(spacing: Self.spacing) {
                    ForEach(cols[i].indices, id: \.self) { j in cols[i][j] }
                }
                .frame(width: w)
                .fixedSize(horizontal: false, vertical: true)    // each card keeps its own height
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
