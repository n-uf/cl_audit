// SwitchMenu: the switch items of a profile's menus, the same in the menu bar icon's menu and the Dock icon's menu.
//
//   - the account in use, with a lit (green) lamp under the profile's name: "ultra-1 · in use" (the Dock menu's top line:
//     "Claude Main · ultra-1 in use")
//   - Switch account ›: a submenu with the account in use ticked ("in use · week 94%") and every standby account, most
//     room first, each with its week ("week 12%", or "no numbers"); picking one opens the Switch page with it picked
//   - while a limit is full, the best one also on the top level: "Switch to ultra-3…  week 12%"
//   - a standby account that is back keeps its own "Switch back to ultra-1…" (SwitchBack.swift)
//
// Names are short names (AccountNames.short), which follow Settings ▸ General ▸ Emails.

import AppKit

enum SwitchMenu {
    /// One standby account in a menu.
    struct Line: Equatable {
        let key: String             // "<profile>~<standby account>": the Switch page's
        let short: String
        let words: String           // "week 12%", "5-hour 8%" or "no numbers"
        let room: Bool
        /// Linked to its account and organization (what a switch plans with); one that isn't can't be switched to yet.
        var canSwitch = true
    }

    /// The account the profile works on, short ("ultra-1"); nil while the profile isn't linked to one.
    static func inUseShort(_ e: AccountEntry) -> String? { e.seat?.email.map(AccountNames.short) }

    /// "ultra-1 · in use": under the profile's name in the menu bar icon's menu.
    static func inUseLine(_ e: AccountEntry) -> String? { inUseShort(e).map { "\($0) · in use" } }

    /// The Dock menu's top line: "Claude Main · ultra-1 in use"; the usual "Claude Main" + plan while no account is known.
    static func dockTitle(name: String, _ e: AccountEntry, plan: String?) -> String {
        if let s = inUseShort(e) { return "Claude \(name) · \(s) in use" }
        return "Claude \(name)" + (plan.map { " · \($0)" } ?? "")
    }

    /// "week 12%", "5-hour 8%", or "no numbers".
    static func weekWords(_ used: Double?, week: Bool) -> String {
        guard let p = used else { return "no numbers" }
        return "\(week ? "week" : "5-hour") \(Int(p.rounded()))%"
    }

    /// Every standby account, most room first, then those whose limits are unknown (no sign-in kept for them), each with its
    /// week. The order is the card's and the Switch page's (SwitchOffer).
    static func lines(_ e: AccountEntry, status: (String) -> IconStatus? = Store.status, now: Date = Date()) -> [Line] {
        let offers = e.switchOffers(status: status, now: now)
        let known = Set(offers.map(\.standby.id))
        let line: (SwitchOffer) -> Line = { o in
            Line(key: o.key, short: o.short, words: weekWords(o.used, week: o.status?.weekly != nil), room: o.room,
                 canSwitch: AccountSettings.canSwitch(o.standby))
        }
        return offers.map(line) + e.standby.filter { !known.contains($0.id) }.map { s in
            Line(key: AccountEntry.standbyStatusID(e.id, s.id), short: AccountNames.short(s.email), words: "no numbers", room: false,
                 canSwitch: AccountSettings.canSwitch(s))
        }
    }

    /// The best one to offer while a limit is full: the standby account with the most room that can be switched to, unless it
    /// is back and has its own Switch back item.
    static func best(_ lines: [Line], backs: [BackOffer]) -> Line? {
        lines.first { l in l.room && l.canSwitch && !backs.contains { $0.key == l.key } }
    }

    /// "Switch to ultra-3…  week 12%": on the top level, only while a limit is full.
    static func bestItem(_ l: Line, target: AnyObject, action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: "Switch to \(l.short)…  \(l.words)", action: action, keyEquivalent: "")
        i.target = target; i.representedObject = l.key
        return i
    }

    /// "Switch account ›": the account in use ticked, then every standby account. Nil for a profile with one account.
    static func submenuItem(_ e: AccountEntry, lines: [Line], inUseUsed: Double?, inUseWeek: Bool,
                            target: AnyObject, action: Selector) -> NSMenuItem? {
        guard !lines.isEmpty else { return nil }
        let sub = NSMenu(title: "Switch account"); sub.autoenablesItems = false
        if let s = inUseShort(e) {
            let i = NSMenuItem(title: "\(s)  in use" + (inUseUsed == nil ? "" : " · " + weekWords(inUseUsed, week: inUseWeek)),
                               action: nil, keyEquivalent: "")
            i.state = .on; i.isEnabled = false
            sub.addItem(i)
        }
        for l in lines {
            if l.canSwitch {
                let i = NSMenuItem(title: "\(l.short)…  \(l.words)", action: action, keyEquivalent: "")
                i.target = target; i.representedObject = l.key
                sub.addItem(i)
            } else {
                // not linked to its account yet: nothing to switch to (Settings ▸ Accounts finishes the sign-in)
                let i = NSMenuItem(title: "\(l.short)…  \(l.words) · sign in first", action: nil, keyEquivalent: "")
                i.isEnabled = false
                sub.addItem(i)
            }
        }
        let top = NSMenuItem(title: "Switch account", action: nil, keyEquivalent: "")
        top.submenu = sub
        return top
    }

    /// The group both menus carry besides the full-limit item: "Switch back to ultra-1…" for each account that is back, then
    /// Switch account ›. Empty for a profile with one account that isn't back.
    static func group(_ e: AccountEntry, backs: [BackOffer], lines: [Line], inUseUsed: Double?, inUseWeek: Bool,
                      target: AnyObject, action: Selector) -> [NSMenuItem] {
        var out: [NSMenuItem] = backs.map { b in
            let i = NSMenuItem(title: b.title, action: action, keyEquivalent: "")
            i.target = target; i.representedObject = b.key; i.toolTip = b.words
            return i
        }
        if let sub = submenuItem(e, lines: lines, inUseUsed: inUseUsed, inUseWeek: inUseWeek, target: target, action: action) {
            out.append(sub)
        }
        return out
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
