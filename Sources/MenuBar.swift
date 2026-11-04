// Menu bar: each profile can have its own icon in the menu bar, exactly like its Dock icon: switched on and styled in
// that profile's settings (Menu bar card), drawn by the agent (it runs whatever is open, quit or hidden, so the icons
// work with no Dock icons at all), each with its own menu. ⌘-drag arranges them; macOS remembers where.
//
// An icon is one of six styles (two bars, a ring, a number, with or without the number), in the level colours, the
// system's own (drawn the way macOS draws its icons: white or black, dimmed on an inactive screen), the Mac's accent
// colour or the profile's colour, with its label if asked; while a limit holds it back, the countdown or just red.

import AppKit
import SwiftUI

enum MenuBarStyle: String, CaseIterable, Identifiable, Codable {
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

enum MenuBarColours: String, CaseIterable, Identifiable, Codable {
    case levels, system, accent, profile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .levels: return "Levels"
        case .system: return "System"
        case .accent: return "Accent"
        case .profile: return "Profile colour"
        }
    }
    var blurb: String {
        switch self {
        case .levels: return "green, amber, red as the limits fill up"
        case .system: return "the menu bar's own colour, like Apple's icons: white or black, dimmed on an inactive screen. A full limit shows by its countdown, as macOS doesn't colour these icons"
        case .accent: return "your Mac's accent colour (System Settings ▸ Appearance), following it when it changes"
        case .profile: return "this profile's colour"
        }
    }
}

enum MenuBarWhenFull: String, CaseIterable, Identifiable, Codable {
    case countdown, red
    var id: String { rawValue }
    var title: String { self == .countdown ? "Countdown" : "Red only" }
}

/// How a profile's menu bar icon looks; kept in the profile.
struct MenuBarLook: Codable, Hashable {
    var style: MenuBarStyle = .bars
    var colours: MenuBarColours = .levels
    var label = false                   // the profile's label before its icon ("MAIN")
    var whenFull: MenuBarWhenFull = .countdown

    init() {}

    private enum Keys: String, CodingKey { case style, colours, label, whenFull }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        style = (try? c.decodeIfPresent(MenuBarStyle.self, forKey: .style)) ?? .bars
        let raw = (try? c.decodeIfPresent(String.self, forKey: .colours)) ?? "levels"
        colours = MenuBarColours(rawValue: raw == "plain" ? "system" : raw) ?? .levels
        label = (try? c.decodeIfPresent(Bool.self, forKey: .label)) ?? false
        whenFull = (try? c.decodeIfPresent(MenuBarWhenFull.self, forKey: .whenFull)) ?? .countdown
    }
}

/// The menu bar item used to be a single one, set in Settings ▸ General. When it was on, the profiles it showed get their
/// own icon in the look it had. Runs once: the old settings are removed after.
enum MenuBarLegacy {
    static let keys = ["menuBarItem", "menuBarStyle", "menuBarColours", "menuBarShows", "menuBarProfile", "menuBarLabel", "menuBarWhenFull"]

    static func carryOver() {
        guard let d = UserDefaults(suiteName: Installer.managerID), d.object(forKey: "menuBarItem") != nil else { return }
        if d.bool(forKey: "menuBarItem") {
            var look = MenuBarLook()
            if let v = d.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init) { look.style = v }
            if let v = d.string(forKey: "menuBarColours") { look.colours = v == "plain" ? .system : MenuBarColours(rawValue: v) ?? .levels }
            look.label = d.bool(forKey: "menuBarLabel")
            if let v = d.string(forKey: "menuBarWhenFull").flatMap(MenuBarWhenFull.init) { look.whenFull = v }
            let only = d.string(forKey: "menuBarShows") == "one" ? d.string(forKey: "menuBarProfile") : nil
            for e in Store.load() where only == nil || e.id == only {
                Store.update(e.id) { $0.menuBar = true; $0.menuBarLook = look }
            }
            agentLog.log("menu bar: the old single item carried over to the profiles' own icons")
        }
        keys.forEach { d.removeObject(forKey: $0) }
    }
}

/// Whether the Mac is in its dark look now (the menu bar follows it), and the notice when that changes.
enum MacAppearance {
    /// The system-wide setting (in the global domain every app's defaults read), not this app's own look: cl_audit's
    /// Silver face makes its window light whatever the Mac is.
    static var dark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    static let changed = Notification.Name("AppleInterfaceThemeChangedNotification")
}

/// What a profile's menu bar icon draws. The Menu bar card draws its previews with it too.
struct MenuBarGlyph {
    struct Item {
        var label: String
        var accent: NSColor
        var five: Double?
        var week: Double?
        var countdown: String?          // set while a full limit holds the profile back ("1h 42m", or "full")
    }

    let look: MenuBarLook
    let item: Item
    static let height: CGFloat = 18

    /// System colours: macOS colours the icon itself (a template), so it's drawn in black.
    private var template: Bool { look.colours == .system }

    /// dark: nil draws for the menu bar it's shown in; true or false for a dark or light bar (previews).
    func image(dark: Bool? = nil) -> NSImage {
        let width = draw(at: 0, dark: dark, measure: true)
        let img = NSImage(size: NSSize(width: max(ceil(width), 4), height: Self.height), flipped: false) { _ in
            _ = self.draw(at: 0, dark: dark, measure: false)
            return true
        }
        img.isTemplate = template && dark == nil
        return img
    }

    // MARK: drawing

    private func ink(_ dark: Bool?) -> NSColor {
        if let dark { return dark ? .white : .black }
        return template ? .black : .labelColor
    }
    private func track(_ dark: Bool?) -> NSColor { ink(dark).withAlphaComponent(template ? 0.3 : 0.25) }

    /// A limit's colour: a full one is red (except in the system's colours, which macOS draws in one colour).
    private func colour(_ p: Double?, _ dark: Bool?) -> NSColor {
        guard p != nil else { return track(dark) }
        if template { return ink(dark) }
        if AtLimit.isFull(p) { return Painter.red }
        switch look.colours {
        case .levels: return Painter.color(p, stale: false)
        case .accent: return .controlAccentColor
        case .profile: return item.accent
        case .system: return ink(dark)
        }
    }

    private func text(_ s: String, size: CGFloat, weight: NSFont.Weight, colour: NSColor, tracking: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
                                                   .foregroundColor: colour, .kern: tracking])
    }

    /// Draws the icon from x (or only measures it); returns its width.
    private func draw(at x0: CGFloat, dark: Bool?, measure: Bool) -> CGFloat {
        var x = x0
        let mid = Self.height / 2
        func put(_ s: NSAttributedString, gapAfter: CGFloat = 0) {
            let size = s.size()
            if !measure { s.draw(at: NSPoint(x: x, y: mid - size.height / 2)) }
            x += ceil(size.width) + gapAfter
        }
        if look.label && !item.label.isEmpty { put(text(item.label, size: 9, weight: .bold, colour: ink(dark), tracking: 0.6), gapAfter: 4) }

        // the system's colours can't turn red, so a full limit always shows its countdown there
        let showCount = item.countdown != nil && (look.whenFull == .countdown || template)
        let fuller: Double? = [item.five, item.week].compactMap { $0 }.max()
        func number() { put(text(fuller.map { "\(Int($0.rounded()))%" } ?? "–", size: 12, weight: .semibold, colour: colour(fuller, dark))) }
        func bars() {
            if !measure {
                for (i, p) in [item.five, item.week].enumerated() {
                    let r = NSRect(x: x, y: i == 0 ? mid + 1 : mid - 5, width: 20, height: 4)
                    track(dark).setFill(); NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
                    if let p {
                        var f = r; f.size.width = max(4, 20 * CGFloat(min(max(p, 0), 100)) / 100)
                        colour(p, dark).setFill(); NSBezierPath(roundedRect: f, xRadius: 2, yRadius: 2).fill()
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
                        a.lineWidth = 2; a.lineCapStyle = .round; colour(p, dark).setStroke(); a.stroke()
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
                put(text(item.five.map { "\(Int($0.rounded()))" } ?? "–", size: 11.5, weight: .semibold, colour: colour(item.five, dark)))
                put(text(" · ", size: 11.5, weight: .regular, colour: ink(dark).withAlphaComponent(0.45)))
                put(text(item.week.map { "\(Int($0.rounded()))" } ?? "–", size: 11.5, weight: .semibold, colour: colour(item.week, dark)))
            }
        }
        if showCount, let cd = item.countdown {
            if look.style != .number && look.style != .twoNumbers { x += 4 }
            put(text(cd, size: 11.5, weight: .semibold, colour: template ? ink(dark) : Painter.red))
        }
        return x - x0
    }
}

/// The profiles' menu bar icons, in the agent: one per profile with its switch on, each with that profile's menu.
final class MenuBarItems: NSObject, NSMenuDelegate {
    struct Profile {
        let entry: AccountEntry
        let usage: Usage?
        var problem: String? = nil
        var expired = false
    }

    private var items: [String: NSStatusItem] = [:]      // by profile id
    private var accessory = false
    private let profiles: () -> [Profile]
    private let refresh: (String) -> Void
    private let renew: (String) -> Void

    init(profiles: @escaping () -> [Profile], refresh: @escaping (String) -> Void, renew: @escaping (String) -> Void) {
        self.profiles = profiles
        self.refresh = refresh
        self.renew = renew
    }

    /// Adds, removes and redraws the icons as the profiles say (the agent calls this every 30 s and after a change).
    func update(now: Date = Date()) {
        let list = profiles().filter { $0.entry.menuBar }
        let ids = Set(list.map(\.entry.id))
        for (id, it) in items where !ids.contains(id) {
            NSStatusBar.system.removeStatusItem(it)
            items[id] = nil
        }
        guard !list.isEmpty else {
            if accessory { NSApp.setActivationPolicy(.prohibited); accessory = false }
            return
        }
        if !accessory { NSApp.setActivationPolicy(.accessory); accessory = true }   // still no Dock icon
        // a new icon goes left of the ones already there: added from the last profile, they read in profile order
        for p in list.reversed() where items[p.entry.id] == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            it.autosaveName = "cl_audit \(p.entry.id)"          // where the user ⌘-dragged it
            let menu = NSMenu(title: p.entry.id)
            menu.delegate = self
            menu.autoenablesItems = false
            it.menu = menu
            items[p.entry.id] = it
        }
        for p in list { draw(p, now: now) }
    }

    static func item(_ p: Profile, now: Date = Date()) -> MenuBarGlyph.Item {
        let u = p.usage
        let full = u.flatMap { AtLimit.blocker(fiveHour: $0.fiveHour, fiveHourResets: $0.fiveHourResets, weekly: $0.weekly,
                                               weeklyResets: $0.weeklyResets, now: now) }
        return MenuBarGlyph.Item(label: p.entry.label, accent: p.entry.accentNSColor, five: u?.fiveHour, week: u?.weekly,
                                 countdown: full.map { f in f.resets.map { TimeWords.countdown($0, now: now) } ?? "full" })
    }

    private func draw(_ p: Profile, now: Date) {
        guard let button = items[p.entry.id]?.button else { return }
        button.image = MenuBarGlyph(look: p.entry.menuBarLook, item: Self.item(p, now: now)).image()
        button.title = ""
        button.imagePosition = .imageOnly
        let u = p.usage
        if let u, let full = AtLimit.blocker(fiveHour: u.fiveHour, fiveHourResets: u.fiveHourResets, weekly: u.weekly,
                                             weeklyResets: u.weeklyResets, now: now) {
            button.toolTip = "Claude \(p.entry.name): \(full.title) · \(full.both(now))"
        } else {
            button.toolTip = "Claude \(p.entry.name): 5-hour \(Painter.pct(u?.fiveHour)) · week \(Painter.pct(u?.weekly))"
        }
    }

    // MARK: a profile's menu, like its Dock icon's

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let id = menu.title, now = Date()
        guard let p = profiles().first(where: { $0.entry.id == id }) else { return }
        let view = NSHostingView(rootView: MenuBarRow(profile: p, now: now))
        view.frame.size = view.fittingSize
        let row = NSMenuItem(); row.view = view
        menu.addItem(row)
        func info(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        if let u = p.usage { info("Updated \(DetailsFormat.ago(u.fetchedAt)) · \(u.source)") }
        if let why = p.problem { info(why) }
        menu.addItem(.separator())
        func add(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self; i.representedObject = id
            menu.addItem(i)
        }
        if p.entry.claudeWindow { add("Open Claude window", #selector(openClaude(_:))) }
        add("Refresh now", #selector(refreshNow(_:)))
        if p.expired { add("Renew login now (uses a little usage)", #selector(renewLogin(_:))) }
        menu.addItem(.separator())
        add("Dashboard", #selector(dashboard(_:)))
        add("Profile settings…", #selector(settings(_:)))
        menu.addItem(.separator())
        add("Hide from the menu bar", #selector(hide(_:)))
    }

    private func entry(_ sender: NSMenuItem) -> AccountEntry? {
        guard let id = sender.representedObject as? String else { return nil }
        return profiles().first(where: { $0.entry.id == id })?.entry
    }
    @objc private func openClaude(_ sender: NSMenuItem) { if let e = entry(sender) { Launcher.openClaude(Account(e)) } }
    @objc private func refreshNow(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { refresh(id) } }
    @objc private func renewLogin(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { renew(id) } }
    @objc private func dashboard(_ sender: NSMenuItem) { Installer.openDashboard() }
    @objc private func settings(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { Installer.openSettings(account: id) } }
    /// Its switch off, as in the profile's settings (saved to the profiles file; the agent then removes the icon).
    @objc private func hide(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        DispatchQueue.global(qos: .userInitiated).async { Store.update(id) { $0.menuBar = false } }
    }
}

/// The top of a profile's menu: its name, its limits with bars and when they reset, credits while they're spent.
struct MenuBarRow: View {
    let profile: MenuBarItems.Profile
    let now: Date

    private var limits: [Limit] {
        let u = profile.usage
        return [Limit(id: "5h", title: "5-hour session", name: "5-hour", p: u?.fiveHour, resets: u?.fiveHourResets, window: 5 * 3600),
                Limit(id: "wk", title: "Week", name: "Week", p: u?.weekly, resets: u?.weeklyResets, window: 7 * 86400)]
            + (profile.entry.showFable ? u?.scoped ?? [] : []).map(\.limit)
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

/// A profile's settings ▸ Menu bar: its icon there, switched on and styled like its Icon card: the styles in families,
/// a preview from "no numbers yet" to "full" drawn the way your menu bar is now (then the other way), and the choices,
/// each drawn as it would look.
struct MenuBarCard: View {
    @Binding var entry: AccountEntry
    @Environment(\.face) private var face
    @State private var dark = MacAppearance.dark
    @State private var accentTick = 0           // the Mac's accent colour changed: draw again

    /// The previews: the profile as its limits fill up.
    static let lane: [(title: String, five: Double?, week: Double?, full: String?)] =
        [("no numbers yet", nil, nil, nil), ("plenty left", 12, 20, nil), ("half used", 55, 48, nil),
         ("at limit", 88, 72, nil), ("full", 100, 64, "1h 42m")]

    private var look: MenuBarLook { entry.menuBarLook }
    private func set(_ change: (inout MenuBarLook) -> Void) {
        var l = entry.menuBarLook; change(&l)
        withAnimation(.easeOut(duration: 0.12)) { entry.menuBarLook = l }
    }

    /// The icon in a look, for this profile at these levels, on a dark or light bar.
    private func glyph(_ l: MenuBarLook, _ five: Double?, _ week: Double?, full: String? = nil, dark: Bool) -> NSImage {
        let item = MenuBarGlyph.Item(label: entry.label.isEmpty ? "?" : entry.label, accent: entry.accentNSColor,
                                     five: five, week: week, countdown: full)
        return MenuBarGlyph(look: l, item: item).image(dark: dark)
    }

    /// A piece of menu bar with the icon on it.
    private func bar(_ img: NSImage, dark: Bool) -> some View {
        Image(nsImage: img).fixedSize()
            .padding(.horizontal, 7).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(dark ? Color(white: 0.13) : Color(white: 0.93)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(dark ? Color.white.opacity(0.09) : Color.black.opacity(0.12)))
    }

    /// One choice: the icon as it would look in your menu bar, its name under it; the chosen one on a raised key.
    private func choice(_ title: String, on: Bool, img: NSImage, help: String, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        VStack(spacing: 3) {
            bar(img, dark: dark)
            Text(title).font(.system(size: 9.5, weight: on ? .semibold : .regular)).foregroundStyle(on ? face.text : face.muted)
                .lineLimit(1).fixedSize()
        }
        .padding(4)
        .background { if on { RaisedShape(finish: face.key, radius: 5, pressed: false) } }
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .onTapGesture { if enabled { action() } }
        .help(help)
    }

    private func optionRow<V: Identifiable & Equatable>(_ label: String, _ options: [V], selected: V, title: @escaping (V) -> String,
                                                       help: @escaping (V) -> String = { _ in "" },
                                                       enabled: @escaping (V) -> Bool = { _ in true },
                                                       apply: @escaping (inout MenuBarLook, V) -> Void,
                                                       state: (five: Double?, week: Double?, full: String?) = (55, 77, nil)) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(face.soft).frame(width: 64, alignment: .leading)
            FlowLayout(spacing: 4) {
                ForEach(options) { o in
                    let l: MenuBarLook = { var l = look; apply(&l, o); return l }()
                    choice(title(o), on: o == selected, img: glyph(l, state.five, state.week, full: state.full, dark: dark),
                           help: "\(label): \(title(o))" + (help(o).isEmpty ? "" : ": \(help(o))"), enabled: enabled(o)) { set { apply(&$0, o) } }
                }
            }
        }
    }

    enum LabelChoice: String, Identifiable { case none, label; var id: String { rawValue } }

    var body: some View {
        let _ = accentTick
        SCard(title: "Menu bar", info: "An icon for this profile in the menu bar, like its Dock icon: drawn by the cl_audit agent, so it works with or without the Dock icon. Its menu has the limits, Open Claude window, Refresh now and Profile settings. ⌘-drag it to move it; macOS remembers where.") {
            SRow(label: "In the menu bar", info: "Off: no icon in the menu bar for this profile. The usage is read either way.", first: true) {
                Toggle("", isOn: $entry.menuBar).smallSwitch()
            }
            VStack(alignment: .leading, spacing: 10) {
                // the styles, in families like the Icon card (a family wraps to the next line in a narrow card)
                FlowLayout(spacing: 12) {
                    ForEach(MenuBarStyle.families, id: \.title) { fam in
                        VStack(alignment: .leading, spacing: 3) {
                            Printed(text: fam.title, size: 9)
                            HStack(spacing: 2) {
                                ForEach(fam.styles) { st in
                                    choice(st.title, on: look.style == st, img: glyph({ var l = look; l.style = st; return l }(), 55, 77, dark: dark),
                                           help: "\(st.title): \(st.blurb)") { set { $0.style = st } }
                                }
                            }
                        }
                    }
                }
                preview
                VStack(alignment: .leading, spacing: 6) {
                    optionRow("Colours", MenuBarColours.allCases, selected: look.colours, title: { $0.title }, help: { $0.blurb },
                              apply: { $0.colours = $1 })
                    optionRow("Label", [LabelChoice.none, .label], selected: look.label ? .label : LabelChoice.none,
                              title: { $0 == .label ? "Profile label" : "None" }, apply: { $0.label = $1 == .label })
                    optionRow("When full", MenuBarWhenFull.allCases, selected: look.colours == .system ? .countdown : look.whenFull,
                              title: { $0.title },
                              help: { $0 == .red && look.colours == .system ? "not with the system's colours: macOS draws those icons in one colour" : "" },
                              enabled: { $0 == .countdown || look.colours != .system },
                              apply: { $0.whenFull = $1 }, state: (100, 64, "1h 42m"))
                }
                .padding(8)
                .faceWindow(radius: 6)
            }
            .padding(.top, 8)
            .opacity(entry.menuBar ? 1 : 0.55)
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: MacAppearance.changed)) { _ in dark = MacAppearance.dark }
        .onReceive(NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)) { _ in accentTick += 1 }
    }

    /// The chosen look as the limits fill up: first the way your menu bar is now, then the other way.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Preview").font(.system(size: 11, weight: .semibold)).foregroundStyle(face.text)
                Text("your menu bar (\(dark ? "dark" : "light")), then \(dark ? "light" : "dark")")
                    .font(.system(size: 10.5)).foregroundStyle(face.muted)
            }
            HStack(alignment: .top, spacing: 4) {
                ForEach(Self.lane.indices, id: \.self) { i in
                    let s = Self.lane[i]
                    VStack(spacing: 3) {
                        bar(glyph(look, s.five, s.week, full: s.full, dark: dark), dark: dark)
                        bar(glyph(look, s.five, s.week, full: s.full, dark: !dark), dark: !dark).opacity(0.85)
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
