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
    static func apply<T>(_ ids: [String], to list: [T], id: (T) -> String) -> [T] {
        let rank = ranks(ids)
        return list.enumerated().sorted { a, b in
            let ra = rank[id(a.element)] ?? Int.max, rb = rank[id(b.element)] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    static func apply(_ ids: [String], to list: [AccountEntry]) -> [AccountEntry] { apply(ids, to: list, id: \.id) }

    /// A move made in a list that leaves some profiles out (the dashboard's shown cards), as a new order of `all`:
    /// the profile goes just before the shown one it now stands in front of (after the one before it, at the end);
    /// the others, hidden ones included, keep their places.
    static func moving(_ id: String, to index: Int, among shown: [String], in all: [String]) -> [String] {
        let now = moving(id, to: index, in: shown)
        // put back where it was: no new order (a hidden profile before it mustn't make one)
        guard now != shown, let k = now.firstIndex(of: id) else { return all }
        var out = all.filter { $0 != id }
        if k + 1 < now.count, let j = out.firstIndex(of: now[k + 1]) { out.insert(id, at: j) }
        else if k > 0, let j = out.firstIndex(of: now[k - 1]) { out.insert(id, at: j + 1) }
        else { return all }
        return out
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
        setOrder(ProfileOrder.moving(id, to: index, in: accounts.map(\.id)))
    }

    /// The one save behind every move (the tile bar's, the dashboard's cards'): the profiles in the order of `wanted`
    /// (any it doesn't name after them, as they are). False when that order isn't what's saved now.
    @discardableResult
    func setOrder(_ wanted: [String]) -> Bool {
        let before = accounts.map(\.id)
        let ids = ProfileOrder.apply(wanted, to: accounts).map(\.id)
        guard ids != before else { return true }
        // nothing saved yet (the first setup, before Apply): the order goes with the rest when Apply saves
        guard !saved.isEmpty else { accounts = ProfileOrder.apply(ids, to: accounts); return false }
        do { try Store.edit { ProfileOrder.apply(ids, to: $0) } }
        catch { message = "Couldn't save: \(error.localizedDescription)"; return false }
        takeInOutsideChanges()                       // the file as saved, with any change made here kept on top
        accounts = ProfileOrder.apply(ids, to: accounts)
        showSaved("order")
        WidgetCenter.shared.reloadAllTimelines()     // placed widgets redraw now, not at their next look in 5 min
        return true
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
        // a scan under way would bring back the order it started with: start it again instead
        if stats.loading { stats.reload() } else { stats.follow(ids) }
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

/// The agent's menu bar icons. macOS places an icon by its autosave name: it puts it back where it was (⌘-dragged
/// or not), whatever order the icons are created in. On macOS 26 and later the system's MenuBarAgent keeps that
/// itself, out of the app's reach (nothing in its defaults; seen on 27.2); earlier versions kept it in the app's
/// defaults. So after a new order the icons are put up again under new names, which carry the order (they also sort in
/// it) and which macOS has no place for: they line up in the new order, and ⌘-drag still moves them until the next
/// new order. Until the first new order the names stay "cl_audit <id>", so icons already placed keep their places.
enum MenuBarOrder {
    private static let key = "menuBarProfileOrder"
    private static let roundKey = "menuBarProfileOrderRound"

    /// Whether the profiles are in a new order since the icons were last put up; remembers this order either way, and
    /// counts a new one (the names' round). The first time (no order kept yet) is not a new one.
    static func reordered(_ ids: [String], defaults: UserDefaults = .standard) -> Bool {
        let before = defaults.stringArray(forKey: key)
        if before != ids { defaults.set(ids, forKey: key) }
        guard let before, ProfileOrder.reordered(from: before, to: ids) else { return false }
        defaults.set(defaults.integer(forKey: roundKey) + 1, forKey: roundKey)
        return true
    }

    /// The icon's autosave name: "cl_audit <id>" until the first new order, then "cl_audit <round>.<place> <id>"
    /// (place: the profile's index in the order, two digits).
    static func autosaveName(_ id: String, place: Int, defaults: UserDefaults = .standard) -> String {
        let round = defaults.integer(forKey: roundKey)
        return round == 0 ? "cl_audit \(id)" : "cl_audit \(round).\(String(format: "%02d", place)) \(id)"
    }
}

// MARK: - Dragging a profile: one engine for the tile bar's tiles and the dashboard's cards

/// A profile being dragged: which one, and how far the pointer has moved since it was picked up.
struct ProfileDrag: Equatable {
    var id: String
    var offset: CGSize
}

/// Where the dragged profile lands, as the last layout worked it out (read at the drop).
final class ProfileDragLanding { var index: Int? }

/// Marks the socket among a layout's subviews.
struct ProfileDragSocket: LayoutValueKey { static let defaultValue = false }

/// The drag itself, the same for a tile and a card: picked up after 4 pt (a click stays a click), measured in the
/// window's coordinates as the profile moves under the pointer, and on release moved to where the layout says it lands.
/// `state` is cleared by itself when the drag ends or is cut short (a menu opening, the window losing focus), so
/// nothing is left lifted, and only a drag that ends moves anything.
enum ProfileDragGesture {
    static func make(_ id: String, state: GestureState<ProfileDrag?>, enabled: Bool, landing: ProfileDragLanding,
                     drop: @escaping (String, Int) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating(state) { v, drag, _ in if enabled { drag = ProfileDrag(id: id, offset: v.translation) } }
            .onEnded { _ in
                guard let to = landing.index else { return }
                withAnimation(.easeOut(duration: 0.18)) { drop(id, to) }
            }
    }

    /// How long the others take to move aside, and the dropped one to settle.
    static let reset = Transaction(animation: .easeOut(duration: 0.18))
}

extension View {
    /// One profile's part in a drag: lifted (a touch bigger, with a shadow, over the others) and glued to the pointer
    /// while it's the one in hand, and the drag gesture. `overOwnClicks`: the drag goes before the view's own click
    /// (a tile); otherwise the view's keys go first, so a drag never starts from one (a card's Show window, Terminal…).
    /// `step`: VoiceOver's Move left / Move right, for a view that is one element (a tile; a card's keys are each
    /// their own, and would all get them).
    func profileDragItem<G: Gesture>(lifted: Bool, live: Bool, scale: CGFloat, shadow: CGFloat, gesture: G,
                                     overOwnClicks: Bool, step: ((Int) -> Void)? = nil) -> some View {
        self
            .scaleEffect(lifted ? scale : 1)
            .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: lifted ? shadow : 0, y: lifted ? shadow * 0.7 : 0)
            .contentShape(Rectangle())
            .zIndex(lifted ? 1 : 0)
            .transaction { t in if lifted && live { t.animation = nil } }
            .modifier(ProfileDragAttach(gesture: gesture, first: overOwnClicks, step: step))
    }
}

private struct ProfileDragAttach<G: Gesture>: ViewModifier {
    let gesture: G
    let first: Bool
    let step: ((Int) -> Void)?
    @ViewBuilder func body(content: Content) -> some View {
        if let step {
            attached(content)
                .accessibilityHint("Drag to change the order")
                .accessibilityAction(named: "Move left") { withAnimation(.easeOut(duration: 0.18)) { step(-1) } }
                .accessibilityAction(named: "Move right") { withAnimation(.easeOut(duration: 0.18)) { step(1) } }
        } else {
            attached(content)
        }
    }
    @ViewBuilder private func attached(_ content: Content) -> some View {
        if first { content.highPriorityGesture(gesture) } else { content.gesture(gesture) }
    }
}

/// Where a dragged profile would land: the space it leaves, sunk in, with a dim lamp strip.
struct DropSocket: View {
    var radius: CGFloat = 4
    @Environment(\.face) private var face
    var body: some View {
        WellShape(well: face.track, radius: radius)
            .overlay(LampStrip(color: FaceTheme.led.opacity(0.5)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The profiles' tiles in the tile bar, in their order. Drag one left or right: the others move aside, a lit socket
/// shows where it lands, and the drop saves the new order. A click still selects; right-click still offers Remove.
struct ProfileTiles: View {
    @ObservedObject var model: SettingsModel
    @GestureState(resetTransaction: ProfileDragGesture.reset) private var drag: ProfileDrag? = nil
    @State private var landing = ProfileDragLanding()
    /// Offscreen renders only: a tile shown mid-drag (never saved).
    static var renderDrag: ProfileDrag?

    var body: some View {
        let d = drag ?? Self.renderDrag
        let dragged = d.flatMap { d in model.accounts.firstIndex { $0.id == d.id } }
        ProfileTilesLayout(spacing: 8, dragged: dragged, offset: d?.offset ?? .zero, landing: landing) {
            if dragged != nil { DropSocket().layoutValue(key: ProfileDragSocket.self, value: true).zIndex(-1) }
            ForEach(model.accounts) { a in
                // lifted: a touch bigger, with a short shadow (the bar's scroll view leaves 3 pt above and below)
                AccountTile(entry: a, selected: a.id == model.selection, model: model)
                    .profileDragItem(lifted: d?.id == a.id, live: drag != nil, scale: 1.03, shadow: 2.5,
                                     gesture: ProfileDragGesture.make(a.id, state: $drag, enabled: model.accounts.count > 1,
                                                                      landing: landing) { id, to in model.moveProfile(id, to: to) },
                                     overOwnClicks: true) { model.stepProfile(a.id, by: $0) }
            }
        }
        .animation(.easeOut(duration: 0.16), value: d)
    }
}

/// The dashboard's profile cards, in the profiles' order. Drag a card by its body or header (never by one of its keys)
/// left, right, up or down: the others move aside, a lit socket shows where it lands, and the drop saves the new order
/// with the tile bar's own save, so everything follows the same way and the display says "Saved · order".
/// Hidden profiles keep their places: the card lands just before the shown card it's dropped in front of.
struct ProfileCards: View {
    @ObservedObject var model: LauncherModel
    let actions: LauncherActions
    @GestureState(resetTransaction: ProfileDragGesture.reset) private var drag: ProfileDrag? = nil
    @State private var landing = ProfileDragLanding()
    @Environment(\.face) private var face
    /// Offscreen renders only: a card shown mid-drag (never saved).
    static var renderDrag: ProfileDrag?

    var body: some View {
        let rows = model.shownRows, shown = rows.map(\.id)
        let d = drag ?? Self.renderDrag
        let dragged = d.flatMap { d in rows.firstIndex { $0.id == d.id } }
        CardGrid(minWidth: 352, spacing: 12, dragged: dragged, offset: d?.offset ?? .zero, landing: landing) {
            if dragged != nil {
                DropSocket(radius: face.moduleRadius).layoutValue(key: ProfileDragSocket.self, value: true).zIndex(-1)
            }
            ForEach(rows) { row in
                AccountCard(row: row, actions: actions)
                    .profileDragItem(lifted: d?.id == row.id, live: drag != nil, scale: 1.015, shadow: 9,
                                     gesture: ProfileDragGesture.make(row.id, state: $drag, enabled: rows.count > 1,
                                                                      landing: landing) { id, to in move(id, to: to, shown: shown) },
                                     overOwnClicks: false)
            }
        }
        .animation(.easeOut(duration: 0.16), value: d)
    }

    /// `to`: the card's place among the shown cards. The cards take the new order at once (no wait for the file).
    private func move(_ id: String, to: Int, shown: [String]) {
        let all = model.rows.map(\.id)
        let ids = ProfileOrder.moving(id, to: to, among: shown, in: all)
        guard ids != all else { return }
        model.rows = ProfileOrder.apply(ids, to: model.rows, id: \.id)
        actions.moveProfile(ids)
    }
}

/// The dashboard's display after a card was dropped: "Saved · order" for a moment (the tile bar's own words, from the
/// same save), else what `content` says.
struct SavedOrderDisplay<Content: View>: View {
    let settings: SettingsModel?
    @ViewBuilder let content: Content
    var body: some View {
        if let settings { Watch(settings: settings, content: content) } else { content }
    }
    private struct Watch: View {
        @ObservedObject var settings: SettingsModel
        let content: Content
        var body: some View {
            if settings.savedNote == "order" {
                DisplayWindow(text: "Saved", dim: "· order", tone: .ok, height: TopStrip.height, fill: true)
                    .frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity)
            } else { content }
        }
    }
}

/// The tiles in a row; while one is dragged, the others packed around a gap its width where it would land (the
/// socket there), and the dragged one where the pointer has it, kept between the first and the last tile.
struct ProfileTilesLayout: Layout {
    var spacing: CGFloat
    var dragged: Int?                 // the dragged tile's index
    var offset: CGSize
    let landing: ProfileDragLanding

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.filter { !$0[ProfileDragSocket.self] }.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0)),
                      height: sizes.map(\.height).max() ?? 0)
    }

    /// The tiles side by side, in `order`, from the bar's left edge.
    static func row(_ widths: [CGFloat], spacing: CGFloat, in bounds: CGRect) -> ([Int]) -> [CGRect] {
        { order in
            var x = bounds.minX
            return order.map { i in
                defer { x += widths[i] + spacing }
                return CGRect(x: x, y: bounds.minY, width: widths[i], height: bounds.height)
            }
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let tiles = subviews.filter { !$0[ProfileDragSocket.self] }
        let widths = tiles.map { $0.sizeThatFits(.unspecified).width }
        let plan = ProfileDragPlan(count: tiles.count, dragged: dragged, offset: offset,
                                   arrange: Self.row(widths, spacing: spacing, in: bounds))
        plan.place(tiles, socket: subviews.first { $0[ProfileDragSocket.self] }, landing: landing)
    }
}

/// The arithmetic of a drag, apart from the views, for a row or a grid alike. `arrange` lays the items out in a given
/// order (frame k for the k-th of the order). The dragged one follows the pointer, kept inside the area the items take
/// (so a tile never passes General or ＋, a card never leaves the cards), and lands in the place whose middle is
/// nearest its own; the others are laid out around that place, where the socket goes.
struct ProfileDragPlan {
    var frames: [CGRect]              // each item's frame, by its index in the list
    var target: Int?                  // the dragged one's index once moved
    var socket: CGRect?

    init(count: Int, dragged: Int?, offset: CGSize, arrange: ([Int]) -> [CGRect]) {
        let ids = Array(0..<count)
        let home = arrange(ids)
        frames = home
        guard let d = dragged, ids.contains(d), count > 1 else { return }
        let area = home.dropFirst().reduce(home[0]) { $0.union($1) }
        var held = home[d].offsetBy(dx: offset.width, dy: offset.height)
        held.origin.x = min(max(held.minX, area.minX), area.maxX - held.width)
        held.origin.y = min(max(held.minY, area.minY), area.maxY - held.height)
        func order(_ t: Int) -> [Int] { var o = ids.filter { $0 != d }; o.insert(d, at: t); return o }
        var best: (t: Int, distance: CGFloat, frames: [CGRect])?
        for t in 0..<count {
            let f = arrange(order(t))
            let distance = hypot(f[t].midX - held.midX, f[t].midY - held.midY)
            if best == nil || distance < best!.distance { best = (t, distance, f) }
        }
        let b = best!
        for (k, i) in order(b.t).enumerated() { frames[i] = b.frames[k] }
        frames[d] = held
        target = b.t
        socket = b.frames[b.t]
    }

    /// Puts the items (and the socket, while there's a drag) where the plan says; notes where the dragged one lands.
    func place(_ items: [LayoutSubview], socket view: LayoutSubview?, landing: ProfileDragLanding?) {
        landing?.index = target
        for (i, v) in items.enumerated() { v.place(at: frames[i].origin, proposal: ProposedViewSize(frames[i].size)) }
        if let view { let s = socket ?? .zero; view.place(at: s.origin, proposal: ProposedViewSize(s.size)) }
    }
}

/// The tile bar's ⓘ: what the order does, and what it leaves alone.
struct ProfileOrderInfo: View {
    var body: some View {
        InfoDot(text: "Drag a profile's tile left or right to change the order. On the dashboard, drag a profile's card: it's the same order. The dashboard, the launcher (⌘1, ⌘2…), the menu bar icons, the widget, the usage history and the Dock menu follow it. It's saved when you let go.\nThe menu bar icons line up in the new order; ⌘-drag still moves them after.\nThe Dock icons stay where they are: the Dock is macOS's, so move them there. (With General ▸ Dock ▸ Keep in order on, cl_audit puts them in this order the next time it arranges the Dock: Arrange Dock, or adding, renaming or removing a profile.)")
    }
}
