// SwitchMenu: the switch items of a profile's menus, the same in the menu bar icon's menu and the Dock icon's menu.
//
//   - the account in use, with a lit (green) lamp under the profile's name: "ultra-1 · in use" (the Dock menu's top line:
//     "Claude Main · ultra-1 in use")
//   - Switch account ›: a submenu with the account in use ticked ("in use · week 94%") and every standby account, in the
//     order a full limit offers them, each with when it was last in use ("3 days ago"; a standby account isn't read, so
//     it has no week); picking one opens the Switch page with it picked
//   - while a limit is full, the one offered first also on the top level: "Switch to ultra-3…"
//
// Names are short names (AccountNames.short), which follow Settings ▸ General ▸ Emails.

import AppKit

enum SwitchMenu {
    /// One standby account in a menu.
    struct Line: Equatable {
        let key: String             // "<profile>~<standby account>": the Switch page's
        let short: String
        let words: String           // "3 days ago", or "" when it was never in use here
        /// Not known to be full: it may be offered while a limit is full.
        let room: Bool
        var canSwitch = true
    }

    /// The account in use, short ("ultra-1"), as the profile's record says it (AccountView); nil while none is known.
    static func inUseShort(_ v: AccountView) -> String? { v.short }

    /// "ultra-1 · in use": under the profile's name in the menu bar icon's menu.
    static func inUseLine(_ v: AccountView) -> String? { v.inUseLine }

    /// The Dock menu's top line: "Claude Main · ultra-1 in use"; the usual "Claude Main" + plan while no account is known.
    static func dockTitle(name: String, _ v: AccountView, plan: String?) -> String {
        if let s = inUseShort(v) { return "Claude \(name) · \(s) in use" }
        return "Claude \(name)" + (plan.map { " · \($0)" } ?? "")
    }

    /// "week 12%", "5-hour 8%", or "no numbers".
    static func weekWords(_ used: Double?, week: Bool) -> String {
        guard let p = used else { return "no numbers" }
        return "\(week ? "week" : "5-hour") \(Int(p.rounded()))%"
    }

    /// Every standby account, in the order a full limit offers them (the card's and the Switch page's, SwitchOffer), each with
    /// when it was last in use.
    static func lines(_ e: AccountEntry, now: Date = Date()) -> [Line] {
        e.switchOffers(now: now).map { o in
            let full = o.knownFull(now: now)          // orders and picks the offer only; never shown
            let words = o.standby.lastInUse.map { AccountBook.ago($0, now: now) } ?? ""
            return Line(key: o.key, short: o.short, words: words, room: !full, canSwitch: o.standby.seat != nil || !o.standby.email.isEmpty)
        }
    }

    /// The one to offer while a limit is full: the first standby account not known to be full.
    static func best(_ lines: [Line]) -> Line? { lines.first { $0.room && $0.canSwitch } }

    /// "Switch to ultra-3…": on the top level, only while a limit is full.
    static func bestItem(_ l: Line, target: AnyObject, action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: "Switch to \(l.short)…", action: action, keyEquivalent: "")
        i.target = target; i.representedObject = l.key
        return i
    }

    /// "Switch account ›": the account in use ticked, then every standby account. Nil for a profile with one account.
    static func submenuItem(_ v: AccountView, lines: [Line], inUseUsed: Double?, inUseWeek: Bool,
                            target: AnyObject, action: Selector) -> NSMenuItem? {
        guard !lines.isEmpty else { return nil }
        let sub = NSMenu(title: "Switch account"); sub.autoenablesItems = false
        if let s = inUseShort(v) {
            let i = NSMenuItem(title: "\(s)  in use" + (inUseUsed == nil ? "" : " · " + weekWords(inUseUsed, week: inUseWeek)),
                               action: nil, keyEquivalent: "")
            i.state = .on; i.isEnabled = false
            sub.addItem(i)
        }
        for l in lines {
            let i = NSMenuItem(title: "\(l.short)…" + (l.words.isEmpty ? "" : "  \(l.words)"), action: l.canSwitch ? action : nil, keyEquivalent: "")
            i.target = target; i.representedObject = l.key; i.isEnabled = l.canSwitch
            sub.addItem(i)
        }
        let top = NSMenuItem(title: "Switch account", action: nil, keyEquivalent: "")
        top.submenu = sub
        return top
    }

    /// The group both menus carry besides the full-limit item: Switch account ›. Empty for a profile with one account.
    static func group(_ v: AccountView, lines: [Line], inUseUsed: Double?, inUseWeek: Bool,
                      target: AnyObject, action: Selector) -> [NSMenuItem] {
        submenuItem(v, lines: lines, inUseUsed: inUseUsed, inUseWeek: inUseWeek, target: target, action: action).map { [$0] } ?? []
    }

    /// A small lit green lamp for a menu item's image (the account in use).
    static func lamp() -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let img = NSImage(size: size, flipped: false) { r in
            NSColor.systemGreen.withAlphaComponent(0.28).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 3, dy: 3)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}
