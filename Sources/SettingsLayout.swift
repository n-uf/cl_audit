// Settings layout pieces: columns that follow the window width (cards never stretch into long forms), a
// colour row that wraps, and the small pictures some (i) explanations carry.

import SwiftUI

/// Settings cards in groups, a group per column, in reading order: as many columns as fit (each 340–460 pt,
/// never stretched). When there are fewer columns than groups, the later groups stack in the last column, or, for
/// two columns, the `two` arrangement when one is given; with one column everything follows in order. Extra width
/// stays empty rather than widening cards.
/// A printed label at the top of a settings column: what its cards are about ("How usage looks").
struct ColumnHead: View {
    let text: String
    @Environment(\.face) private var face
    var body: some View {
        Text(text).font(.system(size: 9.5, weight: .bold)).tracking(1.6).textCase(.uppercase)
            .foregroundStyle(face.active ? FaceTheme.led.opacity(face.light ? 1 : 0.9) : Color.secondary)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4).padding(.top, 2).padding(.bottom, -3)
    }
}

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

// MARK: - One pattern for every settings card (layout A)
//
// A card: one title with (i), then rows. A row: its label on the left, regular, with (i), in the same width on every
// card (SRow.labelWidth), its value on the right. On/off: SSwitch (the small lamp switch and a few words that follow
// the state). Two or three short words: SSegments beside the label. Longer words or more choices: a pop-up beside the
// label (MenuWell(fill:) with .faceMenuFill()). Pictures: STiles under the label (SRow(stacked:)). At most one grey line
// under a row (SRowLine), saying what the current choice means. A card's preview: one PreviewStrip at its foot.

/// On/off in a settings row: the small lamp switch, then a few words that follow the state ("shown and alerted" /
/// "left out"). Never a switch alone, never two lines beside it.
struct SSwitch: View {
    @Binding var isOn: Bool
    let on: String
    let off: String
    /// Shorter "on" words for a narrow column (340 pt), used only when the full ones don't fit.
    var onShort: String? = nil
    @Environment(\.face) private var face
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isOn).toggleStyle(LEDSwitchStyle()).labelsHidden()
            if isOn, let onShort {
                ViewThatFits(in: .horizontal) { words(on).fixedSize(); words(onShort) }
            } else {
                words(isOn ? on : off)
            }
        }
        .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
    }

    private func words(_ s: String) -> some View {
        Text(s).font(.system(size: 11.5)).foregroundStyle(face.muted).lineLimit(1).opacity(enabled ? 1 : 0.6)
    }
}

/// Two or three short choices beside a row's label: segments in a recessed track, the chosen one raised.
struct SSegments<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var enabled: (Value) -> Bool = { _ in true }
    let title: (Value) -> String

    var body: some View {
        PillPicker(options: options, selection: Binding(get: { selection }, set: { if enabled($0) { selection = $0 } }),
                   compact: true, fill: true, title: title)
            .frame(maxWidth: .infinity)
            .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
    }
}

/// The looks of a large thing (a usage panel, a dashboard card, the widget) under a row's label: the choices as
/// segments and, under them, one large preview of the chosen look, together in one pane. Small things (Dock icon
/// styles, menu bar styles and colours) are tiles instead (STiles).
struct SLooks<Value: Hashable, Preview: View>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    let preview: (Value) -> Preview
    @Environment(\.face) private var face

    init(options: [Value], selection: Binding<Value>, title: @escaping (Value) -> String,
         @ViewBuilder preview: @escaping (Value) -> Preview) {
        self.options = options; self._selection = selection; self.title = title; self.preview = preview
    }

    var body: some View {
        VStack(spacing: 7) {
            PillPicker(options: options, selection: $selection, compact: true, fill: true, title: title)
            preview(selection)
        }
        .padding(7)
        .background(SurfaceShape(surface: face.strip, radius: 7))
    }
}

/// Pictures of small things to pick from (Dock icon styles, menu bar styles and colours), under a row's label, the
/// card's full width: a grid of tiles, each a picture and its name; the chosen one raised like a key, the others in
/// recessed wells. A large thing (a usage panel, a card) gets SLooks instead: its picture would be too small here.
struct STiles<ID: Hashable>: View {
    struct Tile: Identifiable {
        let id: ID
        let title: String
        var help = ""
        var enabled = true
        let picture: AnyView
    }
    let tiles: [Tile]
    let selected: ID
    var minWidth: CGFloat = 92
    var pictureHeight: CGFloat = 34
    let pick: (ID) -> Void
    @Environment(\.face) private var face

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 5)], spacing: 5) {
            ForEach(tiles) { t in
                let on = t.id == selected
                VStack(spacing: 4) {
                    t.picture.frame(height: pictureHeight)
                    Text(t.title).font(.system(size: 10, weight: on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(on ? face.text : face.muted)
                }
                .padding(.horizontal, 4).padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background {
                    if on { RaisedShape(finish: face.key, radius: 6, pressed: false) } else { WellShape(well: face.win, radius: 6) }
                }
                .opacity(t.enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onTapGesture { if t.enabled { withAnimation(.easeOut(duration: 0.12)) { pick(t.id) } } }
                .help(t.help.isEmpty ? t.title : t.help)
            }
        }
        .padding(.top, 2).padding(.bottom, 4)
    }
}

/// At most one grey line under a row, the card's width: what the current choice means.
struct SRowLine: View {
    let text: String
    var color: Color? = nil
    @Environment(\.face) private var face

    var body: some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(color ?? face.muted)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
    }
}

/// A card's preview, at its foot: "Preview" and what it shows, then the same states left to right (not running or no
/// numbers yet · plenty left · half used · at limit · full), each a picture over its name.
struct PreviewStrip: View {
    struct Item { let title: String; let picture: AnyView }
    let caption: String
    let items: [Item]
    @Environment(\.face) private var face

    /// The states every preview shows, in order, with the 5-hour and weekly levels they're drawn at (nil: no numbers).
    static let states: [(title: String, five: Double?, week: Double?)] =
        [("no numbers", nil, nil), ("plenty left", 12, 20), ("half used", 58, 45), ("at limit", 88, 78), ("full", 100, 64)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Preview").font(.system(size: 11, weight: .semibold)).foregroundStyle(face.text)
                Text(caption).font(.system(size: 10.5)).foregroundStyle(face.muted).lineLimit(1)
            }
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    VStack(spacing: 3) {
                        items[i].picture
                        Text(items[i].title).font(.system(size: 9.5)).foregroundStyle(face.muted).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .faceWindow(radius: 6)
        .padding(.top, 6)
    }
}
