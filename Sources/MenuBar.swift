// Menu bar: an optional item with every profile's limits, drawn by the agent (it runs whatever is open, quit or
// hidden, so the item works with no Dock icons at all). Off by default: Settings ▸ General ▸ Menu bar.
//
// The icon shows the profile with the least room, one chosen profile, or every profile, in one of six styles (two
// bars, a ring, a number, with or without the number), in the level colours, plain or the profile's colour, with its
// label if asked; while a limit holds it back, the countdown or just red. A click opens a menu with every profile: its
// limits, when they reset, usage credits while they're spent; then Refresh now and Open cl_audit.

import AppKit
import SwiftUI

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case bars, barsNumber, ring, ringNumber, number, twoNumbers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bars: return "Two bars"
        case .barsNumber: return "Bars + number"
        case .ring: return "Ring"
        case .ringNumber: return "Ring + number"
        case .number: return "Number"
        case .twoNumbers: return "Two numbers"
        }
    }
    var blurb: String {
        switch self {
        case .bars: return "the 5-hour limit over the week, as thin bars"
        case .barsNumber: return "the bars, then the fuller limit as a number"
        case .ring: return "the week outside, the 5-hour limit inside"
        case .ringNumber: return "the ring, then the fuller limit as a number"
        case .number: return "the fuller of the two limits as a number"
        case .twoNumbers: return "the 5-hour and the weekly limit as numbers"
        }
    }
    static let families: [(title: String, styles: [MenuBarStyle])] =
        [("Bars", [.bars, .barsNumber]), ("Rings", [.ring, .ringNumber]), ("Numbers", [.number, .twoNumbers])]
}

enum MenuBarColours: String, CaseIterable, Identifiable {
    case levels, plain, profile
    var id: String { rawValue }
    var title: String { self == .levels ? "Levels" : self == .plain ? "Plain" : "Profile colour" }
}

enum MenuBarShows: String, CaseIterable, Identifiable {
    case least, one, every
    var id: String { rawValue }
    var title: String { self == .least ? "Least room" : self == .one ? "One profile" : "Every profile" }
}

enum MenuBarWhenFull: String, CaseIterable, Identifiable {
    case countdown, red
    var id: String { rawValue }
    var title: String { self == .countdown ? "Countdown" : "Red only" }
}

/// How the menu bar item looks; kept with cl_audit's settings, read by the agent.
struct MenuBarLook: Equatable {
    var style: MenuBarStyle = .bars
    var colours: MenuBarColours = .levels
    var shows: MenuBarShows = .least
    var profile: String? = nil          // the profile for "One profile" (its id)
    var label = false                   // the profile's label before its icon ("MAIN")
    var whenFull: MenuBarWhenFull = .countdown

    static func load(from d: UserDefaults) -> MenuBarLook {
        var l = MenuBarLook()
        if let v = d.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init) { l.style = v }
        if let v = d.string(forKey: "menuBarColours").flatMap(MenuBarColours.init) { l.colours = v }
        if let v = d.string(forKey: "menuBarShows").flatMap(MenuBarShows.init) { l.shows = v }
        if let v = d.string(forKey: "menuBarWhenFull").flatMap(MenuBarWhenFull.init) { l.whenFull = v }
        l.profile = d.string(forKey: "menuBarProfile")
        l.label = d.bool(forKey: "menuBarLabel")
        return l
    }

    func save(to d: UserDefaults) {
        d.set(style.rawValue, forKey: "menuBarStyle")
        d.set(colours.rawValue, forKey: "menuBarColours")
        d.set(shows.rawValue, forKey: "menuBarShows")
        d.set(whenFull.rawValue, forKey: "menuBarWhenFull")
        if let profile { d.set(profile, forKey: "menuBarProfile") } else { d.removeObject(forKey: "menuBarProfile") }
        d.set(label, forKey: "menuBarLabel")
    }
}

/// The switch and the look, kept with cl_audit's own settings (like Show emails) and read by the agent.
final class MenuBarPrefs: ObservableObject {
    static let shared = MenuBarPrefs()
    static let key = "menuBarItem"
    static let changedNote = Notification.Name("local.usage-n-uf.menubar-changed")

    private static var defaults: UserDefaults {
        Bundle.main.bundleIdentifier == Installer.managerID ? .standard
            : UserDefaults(suiteName: Installer.managerID) ?? .standard
    }
    static var on: Bool { defaults.bool(forKey: key) }
    static var currentLook: MenuBarLook { MenuBarLook.load(from: defaults) }

    @Published private(set) var show = MenuBarPrefs.on
    @Published private(set) var look = MenuBarPrefs.currentLook

    private init() {
        DistributedNotificationCenter.default().addObserver(forName: Self.changedNote, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.show != Self.on { self.show = Self.on }
            let l = Self.currentLook
            if self.look != l { self.look = l }
        }
    }

    func set(_ on: Bool) {
        show = on
        Self.defaults.set(on, forKey: Self.key)
        Self.notify()
    }

    func set(look: MenuBarLook) {
        self.look = look
        look.save(to: Self.defaults)
        Self.notify()
    }

    private static func notify() {
        DistributedNotificationCenter.default().postNotificationName(changedNote, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

/// What the menu bar item draws: one profile, or each in turn, in the chosen look. The Settings card draws its
/// previews with it too, for a dark and a light menu bar.
struct MenuBarGlyph {
    struct Item {
        var label: String
        var accent: NSColor
        var five: Double?
        var week: Double?
        var countdown: String?          // set while a full limit holds the profile back ("1h 42m", or "full")
    }

    let look: MenuBarLook
    let items: [Item]
    static let height: CGFloat = 18

    /// dark: nil draws in the colours of the menu bar it's shown in; true or false for a dark or light bar.
    func image(dark: Bool? = nil) -> NSImage {
        let list = items.isEmpty ? [Item(label: "", accent: .systemGray, five: nil, week: nil, countdown: nil)] : items
        let width = list.enumerated().reduce(CGFloat(0)) { w, e in w + (e.offset > 0 ? 8 : 0) + draw(e.element, at: 0, dark: dark, measure: true) }
        let img = NSImage(size: NSSize(width: max(ceil(width), 4), height: Self.height), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, item) in list.enumerated() {
                if i > 0 { x += 8 }
                x += draw(item, at: x, dark: dark, measure: false)
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    // MARK: drawing

    private func ink(_ dark: Bool?) -> NSColor { dark.map { $0 ? NSColor.white : NSColor.black } ?? .labelColor }
    private func track(_ dark: Bool?) -> NSColor { ink(dark).withAlphaComponent(0.25) }

    /// A limit's colour: a full one is always red; otherwise the level colours, the menu bar's own or the profile's.
    private func colour(_ p: Double?, _ item: Item, _ dark: Bool?) -> NSColor {
        if AtLimit.isFull(p) { return Painter.red }
        switch look.colours {
        case .levels: return p == nil ? track(dark) : Painter.color(p, stale: false)
        case .plain: return ink(dark)
        case .profile: return item.accent
        }
    }

    private func text(_ s: String, size: CGFloat, weight: NSFont.Weight, colour: NSColor, tracking: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
                                                   .foregroundColor: colour, .kern: tracking])
    }

    /// Draws one profile from x (or only measures it); returns its width.
    private func draw(_ item: Item, at x0: CGFloat, dark: Bool?, measure: Bool) -> CGFloat {
        var x = x0
        let mid = Self.height / 2
        func put(_ s: NSAttributedString, gapAfter: CGFloat = 0) {
            let size = s.size()
            if !measure { s.draw(at: NSPoint(x: x, y: mid - size.height / 2)) }
            x += ceil(size.width) + gapAfter
        }
        // which profile, when several share the bar and their colour doesn't say it
        if look.shows == .every && look.colours != .profile && !look.label {
            if !measure {
                item.accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: mid - 2.5, width: 5, height: 5)).fill()
            }
            x += 8
        }
        if look.label && !item.label.isEmpty { put(text(item.label, size: 9, weight: .bold, colour: ink(dark), tracking: 0.6), gapAfter: 4) }

        let showCount = item.countdown != nil && look.whenFull == .countdown
        let fuller: Double? = [item.five, item.week].compactMap { $0 }.max()
        func number() { put(text(fuller.map { "\(Int($0.rounded()))%" } ?? "–", size: 12, weight: .semibold, colour: colour(fuller, item, dark))) }
        func bars() {
            if !measure {
                for (i, p) in [item.five, item.week].enumerated() {
                    let r = NSRect(x: x, y: i == 0 ? mid + 1 : mid - 5, width: 20, height: 4)
                    track(dark).setFill(); NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
                    if let p {
                        var f = r; f.size.width = max(4, 20 * CGFloat(min(max(p, 0), 100)) / 100)
                        colour(p, item, dark).setFill(); NSBezierPath(roundedRect: f, xRadius: 2, yRadius: 2).fill()
                    }
                }
            }
            x += 20
        }
        func ring() {
            if !measure {
                let c = NSPoint(x: x + 8, y: mid)
                for (p, r) in [(item.week, CGFloat(6.5)), (item.five, CGFloat(3))] {
                    let t = NSBezierPath(); t.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
                    t.lineWidth = 2; track(dark).setStroke(); t.stroke()
                    if let p, p > 0 {
                        let a = NSBezierPath()
                        a.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(p, 100)) / 100, clockwise: true)
                        a.lineWidth = 2; a.lineCapStyle = .round; colour(p, item, dark).setStroke(); a.stroke()
                    }
                }
            }
            x += 16
        }
        switch look.style {
        case .bars: bars()
        case .barsNumber: bars(); if !showCount { x += 4; number() }
        case .ring: ring()
        case .ringNumber: ring(); if !showCount { x += 4; number() }
        case .number: if !showCount { number() }
        case .twoNumbers:
            if !showCount {
                put(text(item.five.map { "\(Int($0.rounded()))" } ?? "–", size: 11.5, weight: .semibold, colour: colour(item.five, item, dark)))
                put(text(" · ", size: 11.5, weight: .regular, colour: ink(dark).withAlphaComponent(0.45)))
                put(text(item.week.map { "\(Int($0.rounded()))" } ?? "–", size: 11.5, weight: .semibold, colour: colour(item.week, item, dark)))
            }
        }
        if showCount, let cd = item.countdown {
            if look.style != .number && look.style != .twoNumbers { x += 4 }
            put(text(cd, size: 11.5, weight: .semibold, colour: Painter.red))
        }
        return x - x0
    }
}

/// The item itself, in the agent.
final class MenuBarItem: NSObject, NSMenuDelegate {
    struct Profile { let entry: AccountEntry; let usage: Usage? }

    private var item: NSStatusItem?
    private let profiles: () -> [Profile]
    private let refresh: () -> Void

    init(profiles: @escaping () -> [Profile], refresh: @escaping () -> Void) {
        self.profiles = profiles
        self.refresh = refresh
    }

    /// Shows or hides the item as the switch says, and redraws it (the agent calls this every 30 s).
    func update(now: Date = Date()) {
        guard MenuBarPrefs.on else {
            if let item {
                NSStatusBar.system.removeStatusItem(item)
                self.item = nil
                NSApp.setActivationPolicy(.prohibited)
            }
            return
        }
        if item == nil {
            NSApp.setActivationPolicy(.accessory)          // still no Dock icon; a status item needs more than .prohibited
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            i.autosaveName = "cl_audit usage"
            let menu = NSMenu()
            menu.delegate = self
            i.menu = menu
            item = i
        }
        draw(now: now)
    }

    /// The profile with the least room: one a full limit holds back first (the longest wait), then the fullest.
    static func leastRoom(_ list: [Profile], now: Date = Date()) -> Profile? {
        func rank(_ p: Profile) -> Double {
            guard let u = p.usage else { return -1 }
            if let full = AtLimit.blocker(fiveHour: u.fiveHour, fiveHourResets: u.fiveHourResets, weekly: u.weekly,
                                          weeklyResets: u.weeklyResets, now: now) {
                return 1000 + (full.resets.map { $0.timeIntervalSince(now) / 60 } ?? 100_000)
            }
            return max(u.fiveHour ?? 0, u.weekly ?? 0)
        }
        return list.max { rank($0) < rank($1) }       // the first of equals stays
    }

    /// The profiles the icon shows, as the look says: the least room, the chosen one (or the least room when it's
    /// gone), or every profile in order.
    static func shown(_ list: [Profile], look: MenuBarLook, now: Date = Date()) -> [Profile] {
        switch look.shows {
        case .every: return list
        case .one: if let p = list.first(where: { $0.entry.id == look.profile }) { return [p] }
        case .least: break
        }
        return leastRoom(list, now: now).map { [$0] } ?? []
    }

    static func item(_ p: Profile, now: Date = Date()) -> MenuBarGlyph.Item {
        let u = p.usage
        let full = u.flatMap { AtLimit.blocker(fiveHour: $0.fiveHour, fiveHourResets: $0.fiveHourResets, weekly: $0.weekly,
                                               weeklyResets: $0.weeklyResets, now: now) }
        return MenuBarGlyph.Item(label: p.entry.label, accent: p.entry.accentNSColor, five: u?.fiveHour, week: u?.weekly,
                                 countdown: full.map { f in f.resets.map { TimeWords.countdown($0, now: now) } ?? "full" })
    }

    private func draw(now: Date) {
        guard let button = item?.button else { return }
        let list = profiles(), look = MenuBarPrefs.currentLook
        let shown = Self.shown(list, look: look, now: now)
        button.image = MenuBarGlyph(look: look, items: shown.map { Self.item($0, now: now) }).image()
        button.title = ""
        button.imagePosition = .imageOnly
        let worst = Self.leastRoom(list, now: now), u = worst?.usage
        if let w = worst, let u, let full = AtLimit.blocker(fiveHour: u.fiveHour, fiveHourResets: u.fiveHourResets,
                                                          weekly: u.weekly, weeklyResets: u.weeklyResets, now: now) {
            button.toolTip = "Claude \(w.entry.name): \(full.title) · \(full.both(now))"
        } else {
            button.toolTip = worst.map { w in
                "Claude \(w.entry.name), the least room: 5-hour \(Painter.pct(u?.fiveHour)) · week \(Painter.pct(u?.weekly))"
            } ?? "cl_audit"
        }
    }

    // MARK: the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        let list = profiles()
        if list.isEmpty { menu.addItem(withTitle: "No profiles yet", action: nil, keyEquivalent: "").isEnabled = false }
        for p in list {
            let row = MenuBarRow(profile: p, now: now)
            let view = NSHostingView(rootView: row)
            view.frame.size = view.fittingSize
            let i = NSMenuItem()
            i.view = view
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let open = NSMenuItem(title: "Open cl_audit", action: #selector(openApp), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide from the menu bar", action: #selector(hideItem), keyEquivalent: "")
        hide.target = self
        hide.toolTip = "Settings ▸ General ▸ Menu bar shows it again."
        menu.addItem(hide)
    }

    @objc private func refreshNow() { refresh() }
    @objc private func openApp() { Installer.openDashboard() }
    @objc private func hideItem() { MenuBarPrefs.shared.set(false); update() }
}

/// One profile in the menu: name, its limits with bars and when they reset, credits while they're spent.
struct MenuBarRow: View {
    let profile: MenuBarItem.Profile
    let now: Date

    private var limits: [Limit] {
        let u = profile.usage
        return [Limit(id: "5h", title: "5-hour session", name: "5-hour", p: u?.fiveHour, resets: u?.fiveHourResets, window: 5 * 3600),
                Limit(id: "wk", title: "Week", name: "Week", p: u?.weekly, resets: u?.weeklyResets, window: 7 * 86400)]
            + (u?.scoped ?? []).map(\.limit)
    }

    var body: some View {
        let u = profile.usage
        let full = u.flatMap { AtLimit.blocker(fiveHour: $0.fiveHour, fiveHourResets: $0.fiveHourResets, weekly: $0.weekly,
                                               weeklyResets: $0.weeklyResets, now: now) }
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: profile.entry.accentNSColor)).frame(width: 7, height: 7)
                Text("Claude \(profile.entry.name)").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                if let full {
                    Text(full.resets.map { "\(full.title) · in \(TimeWords.countdown($0, now: now))" } ?? full.title)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(nsColor: .systemRed)).lineLimit(1)
                }
            }
            if u == nil {
                Text("No numbers yet").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(u == nil ? [] : limits) { l in
                HStack(spacing: 8) {
                    Text(l.name).font(.system(size: 11)).frame(width: 46, alignment: .leading).lineLimit(1)
                    LevelBar(p: l.p, height: 5, glow: false).frame(width: 110)
                    Text(Painter.pct(l.p)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                    Text(resetWords(l)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: 92, alignment: .leading)
                }
            }
            if let c = u?.credits, c.inUse(fiveHour: u?.fiveHour, weekly: u?.weekly, now: now) {
                CreditsLine(credits: c)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(width: 330, alignment: .leading)
    }

    private func resetWords(_ l: Limit) -> String {
        guard let r = l.resets else { return "" }
        return AtLimit.isFull(l.p) ? TimeWords.back(r, now: now) : "in \(TimeWords.countdown(r, now: now))"
    }
}

/// Settings ▸ General ▸ Menu bar: show it, then its look, built like a profile's Icon card and the App icon card: the
/// styles in families, a preview from "no numbers yet" to "full" in a dark and a light menu bar, then the choices,
/// each drawn as it would look.
struct MenuBarCard: View {
    @ObservedObject private var prefs = MenuBarPrefs.shared
    @Environment(\.face) private var face
    @State private var entries = Store.load()

    /// The previews: a profile as its limits fill up.
    static let lane: [(title: String, five: Double?, week: Double?, full: String?)] =
        [("no numbers yet", nil, nil, nil), ("plenty left", 12, 20, nil), ("half used", 55, 48, nil),
         ("at limit", 88, 72, nil), ("full", 100, 64, "1h 42m")]

    private var look: MenuBarLook { prefs.look }
    private func set(_ change: (inout MenuBarLook) -> Void) {
        var l = prefs.look; change(&l)
        withAnimation(.easeOut(duration: 0.12)) { prefs.set(look: l) }
    }

    /// The sample profiles the previews draw: yours (the first two), or made-up ones.
    private var samples: [MenuBarGlyph.Item] {
        let real = entries.prefix(2).map { MenuBarGlyph.Item(label: $0.label, accent: $0.accentNSColor, five: nil, week: nil, countdown: nil) }
        let made = [MenuBarGlyph.Item(label: "MAIN", accent: Painter.orange, five: nil, week: nil, countdown: nil),
                    MenuBarGlyph.Item(label: "WORK", accent: .systemTeal, five: nil, week: nil, countdown: nil)]
        return real.count == 2 ? Array(real) : made
    }

    /// The icon in a look, for a profile at these levels (with a second, quieter profile when it shows every one).
    private func glyph(_ l: MenuBarLook, _ five: Double?, _ week: Double?, full: String? = nil, dark: Bool = true) -> NSImage {
        var first = samples[0]; first.five = five; first.week = week; first.countdown = full
        var second = samples[1]; second.five = 13; second.week = 12
        return MenuBarGlyph(look: l, items: l.shows == .every ? [first, second] : [first]).image(dark: dark)
    }

    /// A piece of menu bar with the icon on it.
    private func bar(_ img: NSImage, dark: Bool = true, shrink: Bool = false) -> some View {
        // the preview may shrink it (never grow it) when its row is short of room: every profile with numbers is wide
        Group {
            if shrink {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: img.size.width, maxHeight: img.size.height)
            } else {
                Image(nsImage: img).fixedSize()
            }
        }
            .padding(.horizontal, 7).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(dark ? Color(white: 0.13) : Color(white: 0.93)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(dark ? Color.white.opacity(0.09) : Color.black.opacity(0.12)))
    }

    /// One choice: the icon as it would look, its name under it; the chosen one on a raised key.
    private func choice(_ title: String, on: Bool, img: NSImage, help: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 3) {
            bar(img)
            Text(title).font(.system(size: 9.5, weight: on ? .semibold : .regular)).foregroundStyle(on ? face.text : face.muted)
                .lineLimit(1).fixedSize()
        }
        .padding(4)
        .background { if on { RaisedShape(finish: face.key, radius: 5, pressed: false) } }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(help)
    }

    private func optionRow<V: Identifiable & Equatable>(_ label: String, _ options: [V], selected: V, title: @escaping (V) -> String,
                                                       apply: @escaping (inout MenuBarLook, V) -> Void,
                                                       state: (five: Double?, week: Double?, full: String?) = (55, 77, nil),
                                                       extra: AnyView? = nil) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(face.soft).frame(width: 64, alignment: .leading)
            FlowLayout(spacing: 4) {
                ForEach(options) { o in
                    let l: MenuBarLook = { var l = look; apply(&l, o); return l }()
                    choice(title(o), on: o == selected, img: glyph(l, state.five, state.week, full: state.full),
                           help: "\(label): \(title(o))") { set { apply(&$0, o) } }
                }
                if let extra { extra }
            }
        }
    }

    var body: some View {
        SCard(title: "Menu bar") {
            SRow(label: "In the menu bar", info: "An icon in the menu bar with every profile's limits, drawn by the cl_audit agent, so it works with or without Dock icons. Click it for every profile's limits, Refresh now and Open cl_audit.", first: true) {
                Toggle("", isOn: Binding(get: { prefs.show }, set: { prefs.set($0) })).smallSwitch()
            }
            VStack(alignment: .leading, spacing: 10) {
                // the styles, in families like a profile's Icon card (a family wraps to the next line in a narrow card)
                FlowLayout(spacing: 12) {
                    ForEach(MenuBarStyle.families, id: \.title) { fam in
                        VStack(alignment: .leading, spacing: 3) {
                            Printed(text: fam.title, size: 9)
                            HStack(spacing: 2) {
                                ForEach(fam.styles) { st in
                                    choice(st.title, on: look.style == st, img: glyph({ var l = look; l.style = st; return l }(), 55, 77),
                                           help: "\(st.title): \(st.blurb)") { set { $0.style = st } }
                                }
                            }
                        }
                    }
                }
                preview
                VStack(alignment: .leading, spacing: 6) {
                    optionRow("Colours", MenuBarColours.allCases, selected: look.colours, title: { $0.title }, apply: { $0.colours = $1 })
                    optionRow("Shows", MenuBarShows.allCases, selected: look.shows, title: { $0 == .one ? "One profile" : $0.title },
                              apply: { l, v in
                                  l.shows = v
                                  if v == .one, l.profile == nil || !entries.contains(where: { $0.id == l.profile }) { l.profile = entries.first?.id }
                              },
                              extra: look.shows == .one ? AnyView(profileMenu) : nil)
                    optionRow("Label", [LabelChoice.none, .label], selected: look.label ? .label : LabelChoice.none,
                              title: { $0 == .label ? "Profile label" : "None" }, apply: { $0.label = $1 == .label })
                    optionRow("When full", MenuBarWhenFull.allCases, selected: look.whenFull, title: { $0.title },
                              apply: { $0.whenFull = $1 }, state: (100, 64, "1h 42m"))
                }
                .padding(8)
                .faceWindow(radius: 6)
            }
            .padding(.top, 8)
            .opacity(prefs.show ? 1 : 0.55)
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Store.changed)) { _ in entries = Store.load() }
    }

    enum LabelChoice: String, Identifiable { case none, label; var id: String { rawValue } }

    /// Which profile "One profile" shows.
    private var profileMenu: some View {
        Menu {
            ForEach(entries) { e in Button(e.name) { set { $0.profile = e.id } } }
        } label: { MenuWell(text: entries.first(where: { $0.id == look.profile })?.name ?? "Pick…") }
        .faceMenu()
        .padding(.leading, 2)
    }

    /// The chosen look as the limits fill up, in a dark and a light menu bar.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Preview").font(.system(size: 11, weight: .semibold)).foregroundStyle(face.text)
                Text(look.shows == .every ? "every profile, the first as its limits fill up" : "as the limits fill up")
                    .font(.system(size: 10.5)).foregroundStyle(face.muted)
            }
            HStack(alignment: .top, spacing: 4) {
                ForEach(Self.lane.indices, id: \.self) { i in
                    let s = Self.lane[i]
                    VStack(spacing: 3) {
                        bar(glyph(look, s.five, s.week, full: s.full, dark: true), shrink: true)
                        bar(glyph(look, s.five, s.week, full: s.full, dark: false), dark: false, shrink: true)
                        Text(s.title).font(.system(size: 9.5)).foregroundStyle(face.muted).lineLimit(1).fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(8)
        .faceWindow(radius: 6)
    }
}
