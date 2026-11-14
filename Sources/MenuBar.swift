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
        case .levels: return "green, amber, red, crimson as the limits fill up"
        case .system: return "the menu bar's own colour, like Apple's icons: white or black, dimmed on an inactive screen. A full limit shows by its countdown, as macOS doesn't colour these icons"
        case .accent: return "your Mac's accent colour (System Settings ▸ Appearance), following it when it changes"
        case .profile: return "this profile's colour"
        }
    }
}

enum MenuBarWhenFull: String, CaseIterable, Identifiable, Codable {
    case countdown, red
    var id: String { rawValue }
    var title: String { self == .countdown ? "Countdown" : "Crimson only" }
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
        var noFive = false              // the plan has no 5-hour limit (Ultra): the week alone
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

    /// A limit's colour: a full one is crimson (except in the system's colours, which macOS draws in one colour).
    private func colour(_ p: Double?, _ dark: Bool?) -> NSColor {
        guard p != nil else { return track(dark) }
        if template { return ink(dark) }
        if AtLimit.isFull(p) { return Painter.crimson }
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

        // the system's colours can't turn crimson, so a full limit always shows its countdown there
        let showCount = item.countdown != nil && (look.whenFull == .countdown || template)
        let fuller: Double? = [item.noFive ? nil : item.five, item.week].compactMap { $0 }.max()
        func number() { put(text(fuller.map { "\(Int($0.rounded()))%" } ?? "–", size: 12, weight: .semibold, colour: colour(fuller, dark))) }
        func bars() {
            if !measure {
                // the 5-hour bar over the week's; a plan without a 5-hour limit has the week's alone, in the middle
                let rows: [(Double?, CGFloat)] = item.noFive ? [(item.week, mid - 2)] : [(item.five, mid + 1), (item.week, mid - 5)]
                for (p, y) in rows {
                    let r = NSRect(x: x, y: y, width: 20, height: 4)
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
                for (p, r) in [(item.week, CGFloat(6.5))] + (item.noFive ? [] : [(item.five, CGFloat(3))]) {
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
        case .twoNumbers where item.noFive:
            if !showCount { number() }
        case .twoNumbers:
            if !showCount {
                put(text(item.five.map { "\(Int($0.rounded()))" } ?? "–", size: 11.5, weight: .semibold, colour: colour(item.five, dark)))
                put(text(" · ", size: 11.5, weight: .regular, colour: ink(dark).withAlphaComponent(0.45)))
                put(text(item.week.map { "\(Int($0.rounded()))" } ?? "–", size: 11.5, weight: .semibold, colour: colour(item.week, dark)))
            }
        }
        if showCount, let cd = item.countdown {
            if look.style != .number && look.style != .twoNumbers { x += 4 }
            put(text(cd, size: 11.5, weight: .semibold, colour: template ? ink(dark) : Painter.crimson))
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
        /// The record says the sign-in needs the person (IconStatus.needsLogin): the menu's key is Log in….
        var needsLogin = false
        /// The profile's account as its record says it (AccountResolver): the line under the name.
        var view = AccountView(label: nil, numbersOwner: nil, line: nil, lit: false, clash: nil)
        /// The Claude app on another account than Claude Code (SplitUsage): no numbers, its line, and its key.
        var split: SplitUsage? = nil
    }

    private var items: [String: NSStatusItem] = [:]      // by profile id
    /// The profiles whose icon is up, for the agent's mark (In the menu bar's switch waits until it's there or gone).
    var shown: [String] { items.keys.sorted() }

    /// In the menu bar switched: done once the agent's mark shows the icon up (on) or gone (off). An agent from before
    /// the mark had this has nothing to wait for. Not done in 20 s: failed, with why.
    static func progress(_ id: String, _ on: Bool, since: Date) -> SwitchProgress {
        let mark = Agent.readMark()
        if let up = mark?.menuBar, up.contains(id) == on { return .done }
        if let mark, mark.menuBar == nil, Agent.isAlive(mark) { return .done }
        guard Date().timeIntervalSince(since) > 20 else { return .working }
        if case .stopped = Agent.health(mark) { return .failed("The agent isn't running") }
        return .failed(on ? "Not in the menu bar after 20 s" : "Still in the menu bar after 20 s")
    }
    private var accessory = false
    private let profiles: () -> [Profile]
    private let refresh: (String) -> Void

    init(profiles: @escaping () -> [Profile], refresh: @escaping (String) -> Void) {
        self.profiles = profiles
        self.refresh = refresh
    }

    static func needsLogin(_ s: IconStatus?) -> Bool { s?.needsLogin ?? false }

    /// Adds, removes and redraws the icons as the profiles say (the agent calls this every 30 s and after a change).
    func update(now: Date = Date()) {
        let all = profiles()
        // the profiles in a new order (cl_audit's tile bar): the icons come down and go up again below under new
        // names, which macOS has no place for, so they line up in the new order (ProfileOrder.swift)
        if MenuBarOrder.reordered(all.map(\.entry.id)) {
            items.values.forEach { NSStatusBar.system.removeStatusItem($0) }
            items = [:]
        }
        let place = ProfileOrder.ranks(all.map(\.entry.id))
        let list = all.filter { $0.entry.menuBar }
        let ids = Set(list.map(\.entry.id))
        for (id, it) in items where !ids.contains(id) {
            NSStatusBar.system.removeStatusItem(it)
            items[id] = nil
        }
        guard !list.isEmpty else {
            // no icon left: no windows either, unless the quick chat holds the accessory role (its panel is up, or its
            // shortcut is registered)
            if accessory, !QuickChat.shared.holdsAccessory { NSApp.setActivationPolicy(.prohibited) }
            accessory = false
            return
        }
        if !accessory { NSApp.setActivationPolicy(.accessory); accessory = true }   // still no Dock icon
        // a new icon goes left of the ones already there: added from the last profile, they read in profile order
        let adding = list.contains { items[$0.entry.id] == nil }
        for p in list.reversed() where items[p.entry.id] == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // where the user ⌘-dragged it is kept by this name (until the next new order)
            it.autosaveName = MenuBarOrder.autosaveName(p.entry.id, place: place[p.entry.id] ?? 0)
            let menu = NSMenu(title: p.entry.id)
            menu.delegate = self
            menu.autoenablesItems = false
            it.menu = menu
            items[p.entry.id] = it
        }
        for p in list { draw(p, now: now) }
        // where macOS put them, once it has (for checking a new order: log show … 'menu bar: left to right')
        if adding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                let shown = self.items.map { ($0.key, $0.value.button?.window?.frame.minX ?? -1) }.sorted { $0.1 < $1.1 }
                agentLog.log("menu bar: left to right \(shown.map(\.0).joined(separator: ", "), privacy: .public)")
            }
        }
    }

    static func item(_ p: Profile, now: Date = Date()) -> MenuBarGlyph.Item {
        let u = p.usage
        let full = u.flatMap { AtLimit.blocker(fiveHour: $0.fiveHour, fiveHourResets: $0.fiveHourResets, weekly: $0.weekly,
                                               weeklyResets: $0.weeklyResets, now: now) }
        return MenuBarGlyph.Item(label: p.entry.label, accent: p.entry.accentNSColor, five: u?.fiveHour, week: u?.weekly,
                                 countdown: full.map { f in f.resets.map { TimeWords.countdown($0, now: now) } ?? "full" },
                                 noFive: u?.noFiveHour ?? false)
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
        // the profile's other accounts (Accounts.swift; SwitchMenu.swift): while a limit is full, the one offered first,
        // then Switch account › with every standby account. Each opens cl_audit's Switch page with that account picked
        let listed = p.entry.listed(by: p.view)              // never the account in use on standby too
        let lines = SwitchMenu.lines(listed, now: now)
        let isFull = p.usage.flatMap { AtLimit.blocker(fiveHour: $0.fiveHour, fiveHourResets: $0.fiveHourResets, weekly: $0.weekly,
                                                       weeklyResets: $0.weeklyResets, now: now) } != nil
        var switches = SwitchMenu.group(p.view, lines: lines, inUseUsed: p.usage?.weekly ?? p.usage?.fiveHour,
                                        inUseWeek: p.usage?.weekly != nil, target: self, action: #selector(switchAccount(_:)))
        if isFull, let best = SwitchMenu.best(lines) {
            switches.insert(SwitchMenu.bestItem(best, target: self, action: #selector(switchAccount(_:))), at: 0)
        }
        if !switches.isEmpty {
            switches.forEach(menu.addItem)
            menu.addItem(.separator())
        }
        add("Quick chat", #selector(quickChat(_:)))
        if p.entry.claudeWindow { add("Open Claude window", #selector(openClaude(_:))) }
        add("Refresh now", #selector(refreshNow(_:)))
        if p.needsLogin { add("Log in…", #selector(logIn(_:))) }
        // the split: Claude Code's own sign-in, to the Claude app's account (the same Log in, its address filled in)
        else if let k = p.split?.key { add(k + "…", #selector(logIn(_:))) }
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
    /// The quick chat, on this profile (QuickChat.swift).
    @objc private func quickChat(_ sender: NSMenuItem) { QuickChat.shared.open(profile: sender.representedObject as? String) }
    @objc private func refreshNow(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { refresh(id) } }
    @objc private func logIn(_ sender: NSMenuItem) { if let e = entry(sender) { ClaudeCLI.logIn(profile: e) } }
    @objc private func dashboard(_ sender: NSMenuItem) { Installer.openDashboard() }
    @objc private func switchAccount(_ sender: NSMenuItem) { if let k = sender.representedObject as? String { Installer.openSwitch(k) } }
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
        return (u?.noFiveHour == true ? []
                : [Limit(id: "5h", title: "5-hour session", name: "5-hour", p: u?.fiveHour, resets: u?.fiveHourResets, window: 5 * 3600)])
            + [Limit(id: "wk", title: "Week", name: "Week", p: u?.weekly, resets: u?.weeklyResets, window: 7 * 86400)]
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
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(nsColor: Painter.crimson)).lineLimit(1)
                }
            }
            // the active account and the one line of state, from the profile's record (AccountResolver)
            if let inUse = profile.view.inUseLine {
                HStack(spacing: 6) {
                    Circle().fill(Color(nsColor: profile.view.lit ? .systemGreen : .tertiaryLabelColor)).frame(width: 7, height: 7)
                        .shadow(color: Color(nsColor: .systemGreen).opacity(profile.view.lit ? 0.7 : 0), radius: 2.5)
                    Text(inUse).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let n = profile.view.line {
                Text(n).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(2)
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

/// A profile's settings ▸ Menu bar, in the one pattern of every card: its switch first (off, the card folds to it),
/// Style and Colours as tiles drawn the way your menu bar is now, Label and When full as segments, and the preview
/// strip at the foot, from "no numbers" to "full".
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
    /// shrink: the preview strip, five side by side, may scale the icon down (never up) to fit its column; with a label
    /// or a countdown they're wider than a column's fifth.
    private func bar(_ img: NSImage, dark: Bool, shrink: Bool = false) -> some View {
        Group {
            if shrink {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: img.size.width, maxHeight: img.size.height)
            } else {
                Image(nsImage: img).fixedSize()
            }
        }
            .padding(.horizontal, shrink ? 4 : 7).frame(maxWidth: shrink ? .infinity : nil).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(dark ? Color(white: 0.13) : Color(white: 0.93)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(dark ? Color.white.opacity(0.09) : Color.black.opacity(0.12)))
    }

    enum LabelChoice: String, Identifiable { case none, label; var id: String { rawValue } }

    /// A look with one choice changed, drawn at sample levels in your menu bar: a tile's picture.
    private func tilePicture(_ change: (inout MenuBarLook) -> Void) -> AnyView {
        var l = look; change(&l)
        return AnyView(bar(glyph(l, 55, 77, dark: dark), dark: dark, shrink: true))
    }

    var body: some View {
        let _ = accentTick
        SCard(title: "Menu bar", info: "An icon for this profile in the menu bar, like its Dock icon: drawn by the cl_audit agent, so it works with or without the Dock icon. Its menu has the limits, Open Claude window, Refresh now and Profile settings. ⌘-drag it to move it; macOS remembers where.") {
            SRow(label: "In the menu bar", info: "On: an icon for this profile in the menu bar. Off: none; the usage is read either way.", first: true) {
                SSwitch(isOn: $entry.menuBar, on: "shows the usage", off: "no icon",
                        progress: { on, since in MenuBarItems.progress(entry.id, on, since: since) })
            }
            if entry.menuBar {
                SRow(label: "Style", info: "How the icon draws the usage: two bars (the 5-hour limit over the week), a ring (the week outside, the 5-hour limit inside), with or without the fuller limit as a number, or just numbers.", stacked: true) {
                    STiles(tiles: MenuBarStyle.allCases.map { st in
                        .init(id: st, title: st.title, help: "\(st.title): \(st.blurb)", picture: tilePicture { $0.style = st })
                    }, selected: look.style, minWidth: 96, pictureHeight: 24) { st in set { $0.style = st } }
                }
                SRow(label: "Colours", info: "Levels: green, amber, red, then crimson from 95 % as the limits fill up. System: the menu bar's own colour, like Apple's icons (a full limit shows by its countdown, as macOS doesn't colour these icons). Accent: your Mac's accent colour, following it when it changes. Profile colour: this profile's colour.", stacked: true) {
                    STiles(tiles: MenuBarColours.allCases.map { c in
                        .init(id: c, title: c.title, help: "\(c.title): \(c.blurb)", picture: tilePicture { $0.colours = c })
                    }, selected: look.colours, minWidth: 96, pictureHeight: 24) { c in set { $0.colours = c } }
                }
                SRow(label: "Label", info: "The profile's label before its icon (\"MAIN\"), or none.") {
                    SSegments(options: [LabelChoice.none, .label],
                              selection: Binding(get: { look.label ? .label : .none }, set: { v in set { $0.label = v == .label } }),
                              title: { $0 == .label ? "Profile label" : "None" })
                }
                SRow(label: "When full", info: "While a full limit holds the profile back: its countdown beside the icon (\"1h 42m\"), or the icon in crimson only. With the System colours it's always the countdown.") {
                    SSegments(options: MenuBarWhenFull.allCases,
                              selection: Binding(get: { look.colours == .system ? .countdown : look.whenFull }, set: { v in set { $0.whenFull = v } }),
                              enabled: { $0 == .countdown || look.colours != .system }, title: { $0.title })
                }
                if look.colours == .system { SRowLine(text: "System colours can't turn crimson: a full limit shows its countdown.") }
                PreviewStrip(caption: "your menu bar (\(dark ? "dark" : "light")), then as the limit fills up",
                             items: Self.lane.map { s in
                                 .init(title: s.title, picture: AnyView(bar(glyph(look, s.five, s.week, full: s.full, dark: dark), dark: dark, shrink: true)))
                             })
            }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: MacAppearance.changed)) { _ in dark = MacAppearance.dark }
        .onReceive(NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)) { _ in accentTick += 1 }
    }
}
