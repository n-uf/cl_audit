// Menu bar: an optional item with every profile's limits, drawn by the agent (it runs whatever is open, quit or
// hidden, so the item works with no Dock icons at all). Off by default: Settings ▸ General ▸ Menu bar.
//
// The icon is the profile with the least room: its 5-hour and weekly limits as two thin bars, and while a limit holds
// it back, the countdown beside them ("1h 42m"). A click opens a menu with every profile: its limits, when they reset,
// usage credits while they're spent; then Refresh now and Open cl_audit.

import AppKit
import SwiftUI

/// The switch, kept with cl_audit's own settings (like Show emails) and read by the agent.
final class MenuBarPrefs: ObservableObject {
    static let shared = MenuBarPrefs()
    static let key = "menuBarItem"
    static let changedNote = Notification.Name("local.usage-n-uf.menubar-changed")

    private static var defaults: UserDefaults {
        Bundle.main.bundleIdentifier == Installer.managerID ? .standard
            : UserDefaults(suiteName: Installer.managerID) ?? .standard
    }
    static var on: Bool { defaults.bool(forKey: key) }

    @Published private(set) var show = MenuBarPrefs.on

    private init() {
        DistributedNotificationCenter.default().addObserver(forName: Self.changedNote, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.show != Self.on else { return }
            self.show = Self.on
        }
    }

    func set(_ on: Bool) {
        show = on
        Self.defaults.set(on, forKey: Self.key)
        DistributedNotificationCenter.default().postNotificationName(Self.changedNote, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
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

    private func draw(now: Date) {
        guard let button = item?.button else { return }
        let list = profiles()
        let worst = Self.leastRoom(list, now: now)
        let u = worst?.usage
        button.image = Self.bars(five: u?.fiveHour, week: u?.weekly)
        if let u, let full = AtLimit.blocker(fiveHour: u.fiveHour, fiveHourResets: u.fiveHourResets, weekly: u.weekly,
                                             weeklyResets: u.weeklyResets, now: now) {
            button.title = full.resets.map { TimeWords.countdown($0, now: now) } ?? "full"
            button.imagePosition = .imageLeft
            button.toolTip = "Claude \(worst!.entry.name): \(full.title) · \(full.both(now))"
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = worst.map { w in
                "Claude \(w.entry.name), the least room: 5-hour \(Painter.pct(u?.fiveHour)) · week \(Painter.pct(u?.weekly))"
            } ?? "cl_audit"
        }
    }

    /// Two thin bars, 5-hour over week, in the level colours; the track follows the menu bar's light or dark look.
    static func bars(five: Double?, week: Double?) -> NSImage {
        let img = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { rect in
            for (i, p) in [five, week].enumerated() {
                let y: CGFloat = i == 0 ? 9 : 3
                let track = NSRect(x: 1, y: y, width: rect.width - 2, height: 4)
                NSColor.labelColor.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
                guard let p else { continue }
                var fill = track
                fill.size.width = max(track.height, track.width * CGFloat(min(max(p, 0), 100)) / 100)
                Painter.color(p, stale: false).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
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
