// Profile order: the order of the profiles in accounts.json is the one order every list of profiles follows: the
// dashboard's cards and its profile keys, the launcher and its ⌘1, ⌘2…, the menu bar icons, the widget, the usage
// history (charts, legend, CSV), cl_audit's Dock menu and the agent. It changes by dragging a profile's tile in the
// Settings tile bar (General stays first, ＋ last) and is saved as the tile is dropped. No separate setting: a
// profile file from before keeps its order. The Dock icons stay where they are in the Dock; the Dock is macOS's, and
// they're moved there by hand.

import SwiftUI
import WidgetKit

enum ProfileOrder {
    /// `list` in the order of `ids`; profiles `ids` doesn't name keep their own order after them.
    static func apply(_ ids: [String], to list: [AccountEntry]) -> [AccountEntry] {
        let rank = ranks(ids)
        return list.enumerated().sorted { a, b in
            let ra = rank[a.element.id] ?? Int.max, rb = rank[b.element.id] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// `ids` with `id` moved to `index`, counted in the list without it.
    static func moving(_ id: String, to index: Int, in ids: [String]) -> [String] {
        guard let from = ids.firstIndex(of: id) else { return ids }
        var out = ids
        out.remove(at: from)
        out.insert(id, at: min(max(index, 0), out.count))
        return out
    }

    /// Each id's place, for putting other things (chart bars, CSV rows) in profile order.
    static func ranks(_ ids: [String]) -> [String: Int] {
        Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Whether the ids both lists have are in another order in `now` than in `before` (a profile added or removed
    /// alone isn't a new order).
    static func reordered(from before: [String], to now: [String]) -> Bool {
        let a = Set(before), b = Set(now)
        return before.filter(b.contains) != now.filter(a.contains)
    }
}

// MARK: - Saving a new order

extension SettingsModel {
    /// Moves a profile to `index` among the profiles and saves the order at once: the file is read fresh and only its
    /// order changes, so nothing saved elsewhere meanwhile is lost. Everything that lists the profiles follows; the
    /// Dock is left alone.
    func moveProfile(_ id: String, to index: Int) {
        let before = accounts.map(\.id)
        let ids = ProfileOrder.moving(id, to: index, in: before)
        guard ids != before else { return }
        do { try Store.edit { ProfileOrder.apply(ids, to: $0) } }
        catch { message = "Couldn't save: \(error.localizedDescription)"; return }
        takeInOutsideChanges()                       // the file as saved, with any change made here kept on top
        accounts = ProfileOrder.apply(ids, to: accounts)
        showSaved("order")
        WidgetCenter.shared.reloadAllTimelines()     // placed widgets redraw now, not at their next look in 5 min
    }

    /// One place left or right (VoiceOver's Move left / Move right).
    func stepProfile(_ id: String, by step: Int) {
        guard let i = accounts.firstIndex(where: { $0.id == id }), accounts.indices.contains(i + step) else { return }
        moveProfile(id, to: i + step)
    }
}

// MARK: - The others follow it at once

extension ManagerUI {
    /// The profiles file changed: a new order shows on the dashboard (cards, profile keys, history) and in the
    /// launcher right away, not at the next 10-second look.
    func followOrder() {
        let ids = Store.load().map(\.id)
        guard ProfileOrder.reordered(from: model.rows.map(\.id), to: ids)
                || ProfileOrder.reordered(from: stats.accounts.map(\.id), to: ids) else { return }
        model.reload()
        stats.follow(ids)
    }
}

extension StatsModel {
    /// The same profiles in a new order (the charts' colours, the legend, the CSV), without reading the session files
    /// again.
    func follow(_ ids: [String]) {
        let sorted = ProfileOrder.apply(ids, to: accounts)
        guard sorted.map(\.id) != accounts.map(\.id) else { return }
        objectWillChange.send()
        accounts = sorted
    }
}

/// The agent's menu bar icons: macOS remembers where each was ⌘-dragged (by its autosave name) and puts it back
/// there, whatever the profiles' order. After a new order those places are forgotten, so the icons line up in it;
/// ⌘-drag still moves them afterwards, until the next new order.
enum MenuBarOrder {
    private static let key = "menuBarProfileOrder"

    /// Whether the profiles are in a new order since the icons were last put up; remembers this order either way.
    /// The first time (no order kept yet) is not a new one: icons already placed keep their places.
    static func reordered(_ ids: [String], defaults: UserDefaults = .standard) -> Bool {
        let before = defaults.stringArray(forKey: key)
        if before != ids { defaults.set(ids, forKey: key) }
        guard let before else { return false }
        return ProfileOrder.reordered(from: before, to: ids)
    }

    /// Forgets where macOS put these profiles' icons (call once the icons are removed: macOS may save it on removal).
    static func forgetPlaces(_ ids: [String], defaults: UserDefaults = .standard) {
        for id in ids { defaults.removeObject(forKey: "NSStatusItem Preferred Position cl_audit \(id)") }
    }
}

// MARK: - The tile bar: drag a profile's tile left or right

/// A tile being dragged: which profile, and how far the pointer has moved since it was picked up.
struct ProfileDrag: Equatable {
    var id: String
    var offset: CGFloat
}

/// The profiles' tiles in the tile bar, in their order. Drag one left or right: the others move aside, a lit socket
/// shows where it lands, and the drop saves the new order. A click still selects; right-click still offers Remove.
struct ProfileTiles: View {
    @ObservedObject var model: SettingsModel
    @State private var drag: ProfileDrag?
    @State private var landing = ProfileTilesLayout.Landing()
    /// Offscreen renders only: a tile shown mid-drag (never saved).
    static var renderDrag: ProfileDrag?

    var body: some View {
        let d = drag ?? Self.renderDrag
        let dragged = d.flatMap { d in model.accounts.firstIndex { $0.id == d.id } }
        ProfileTilesLayout(spacing: 8, dragged: dragged, offset: d?.offset ?? 0, landing: landing) {
            if dragged != nil { DropSocket().layoutValue(key: ProfileTilesLayout.IsSocket.self, value: true).zIndex(-1) }
            ForEach(model.accounts) { a in
                let lifted = d?.id == a.id
                AccountTile(entry: a, selected: a.id == model.selection, model: model)
                    .scaleEffect(lifted ? 1.04 : 1)
                    .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: lifted ? 7 : 0, y: lifted ? 4 : 0)
                    .zIndex(lifted ? 1 : 0)
                    // the tile in hand follows the pointer; the others glide aside
                    .transaction { t in if lifted && drag != nil { t.animation = nil } }
                    .highPriorityGesture(dragGesture(a.id))
                    .accessibilityHint("Drag left or right to change the order")
                    .accessibilityAction(named: "Move left") { withAnimation(.easeOut(duration: 0.18)) { model.stepProfile(a.id, by: -1) } }
                    .accessibilityAction(named: "Move right") { withAnimation(.easeOut(duration: 0.18)) { model.stepProfile(a.id, by: 1) } }
            }
        }
        .animation(.easeOut(duration: 0.16), value: d)
    }

    /// The window's coordinates, as the tile moves under the pointer; a click (under 4 pt) is still a click.
    private func dragGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { v in
                guard model.accounts.count > 1 else { return }
                if drag?.id != id { landing.index = nil }
                drag = ProfileDrag(id: id, offset: v.translation.width)
            }
            .onEnded { _ in
                let to = landing.index
                withAnimation(.easeOut(duration: 0.18)) {
                    drag = nil
                    if let to { model.moveProfile(id, to: to) }
                }
            }
    }
}

/// Where a dragged tile would land: the space it leaves in the row, sunk in, with a dim lamp strip.
struct DropSocket: View {
    @Environment(\.face) private var face
    var body: some View {
        WellShape(well: face.track, radius: 4)
            .overlay(LampStrip(color: FaceTheme.led.opacity(0.5)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The tiles in a row; while one is dragged, the others packed around a gap its width where it would land (the
/// socket there), and the dragged one where the pointer has it, kept between the first and the last tile.
struct ProfileTilesLayout: Layout {
    var spacing: CGFloat
    var dragged: Int?                 // the dragged tile's index
    var offset: CGFloat
    let landing: Landing

    /// Where the dragged tile lands, as worked out at the last layout (read at the drop).
    final class Landing { var index: Int? }
    struct IsSocket: LayoutValueKey { static let defaultValue = false }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.filter { !$0[IsSocket.self] }.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0)),
                      height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let tiles = subviews.filter { !$0[IsSocket.self] }
        let widths = tiles.map { $0.sizeThatFits(.unspecified).width }
        let plan = ProfileDragPlan(widths: widths, spacing: spacing, dragged: dragged, offset: offset)
        landing.index = plan.target
        for (i, t) in tiles.enumerated() {
            t.place(at: CGPoint(x: bounds.minX + plan.x[i], y: bounds.midY), anchor: .leading,
                    proposal: ProposedViewSize(width: widths[i], height: bounds.height))
        }
        if let socket = subviews.first(where: { $0[IsSocket.self] }) {
            let s = plan.socket ?? (x: 0, width: 0)
            socket.place(at: CGPoint(x: bounds.minX + s.x, y: bounds.midY), anchor: .leading,
                         proposal: ProposedViewSize(width: s.width, height: bounds.height))
        }
    }
}

/// The arithmetic of a drag, apart from the views: each tile's left edge, where the dragged one lands (its index
/// once moved) and the socket there.
struct ProfileDragPlan {
    var x: [CGFloat]
    var target: Int?
    var socket: (x: CGFloat, width: CGFloat)?

    init(widths: [CGFloat], spacing: CGFloat, dragged: Int?, offset: CGFloat) {
        var home: [CGFloat] = [], at: CGFloat = 0
        for w in widths { home.append(at); at += w + spacing }
        x = home
        guard let d = dragged, widths.indices.contains(d), widths.count > 1 else { return }
        // the dragged tile stays between the first and the last tile: it never passes General or ＋
        let end = home[widths.count - 1] + widths[widths.count - 1]
        let left = min(max(home[d] + offset, 0), end - widths[d])
        // its leading edge (the right one going right, the left one going left) decides: it lands after every other
        // tile whose middle that edge has passed, so it can reach either end whatever the widths
        let edge = offset >= 0 ? left + widths[d] : left
        let others = widths.indices.filter { $0 != d }
        let t = others.filter { home[$0] + widths[$0] / 2 < edge }.count
        var pos: CGFloat = 0, gap: CGFloat = 0
        for (k, i) in others.enumerated() {
            if k == t { gap = pos; pos += widths[d] + spacing }
            x[i] = pos
            pos += widths[i] + spacing
        }
        if t == others.count { gap = pos }
        x[d] = left
        target = t
        socket = (gap, widths[d])
    }
}

/// The tile bar's ⓘ: what the order does, and what it leaves alone.
struct ProfileOrderInfo: View {
    var body: some View {
        InfoDot(text: "Drag a profile left or right to change the order. The dashboard, the launcher (⌘1, ⌘2…), the menu bar icons, the widget, the usage history and the Dock menu follow it. It's saved when you let go.\nThe menu bar icons line up in the new order; ⌘-drag still moves them after.\nThe Dock icons stay where they are: the Dock is macOS's, so move them there. (With General ▸ Dock ▸ Keep in order on, Arrange Dock puts them in this order.)")
    }
}
