// SwitchMenu: the switch items of a profile's menus, the same in the menu bar icon's menu and the Dock icon's menu.
//
//   - the account in use, with a lit (green) lamp under the profile's name: "ultra-1 · in use" (the Dock menu's top line:
//     "Claude Main · ultra-1 in use")
//   - Switch account ›: a submenu that opens with "Experimental: may lose data" (disabled) and a line, then the account in
//     use ticked ("in use · week 94%") and every standby account, in the
//     order a full limit offers them, each with when it was last in use ("3 days ago"; a standby account isn't read, so
//     it has no week); picking one opens the Switch page with it picked
//   - while a limit is full, the one offered first also on the top level: "Switch to ultra-3…"
//
// Names are short names (AccountNames.short), which follow Settings ▸ General ▸ Emails: the part before the @ while addresses
// are shown, "hidden address" while they are hidden. The rows that must tell several accounts apart ("Switch to …", the
// standby accounts) are drawn by AddressMenuRow while hidden: one blurred stand-in, the real address only while the menu
// highlights the row; their titles and accessibility labels say "hidden address" for every account.

import AddressPrivacy
import AppKit
import ProfileCore

enum SwitchMenu {
    /// One standby account in a menu.
    struct Line: Equatable {
        let key: String             // "<profile>~<standby account>": the Switch page's
        let short: String
        /// The account's address (or its "account 1a2b3c4d" label), for a row drawn by AddressMenuRow; never in a title.
        var address = ""
        let words: String           // "3 days ago", or "" when it was never in use here
        /// Not known to be full: it may be offered while a limit is full.
        let room: Bool
        var canSwitch = true
        /// The one a full limit offers first (AccountBook.best, the one rule the card and the alert use too).
        var offered = false
        /// The profile's own account in a clash (ProfileShow.ownStandbyID): the menu's ticked row, not a standby one.
        var own = false
    }

    /// The account in use, short ("ultra-1"), as the profile's record says it (AccountView); nil while none is known.
    static func inUseShort(_ v: AccountView) -> String? { v.short }

    /// "ultra-1": under the profile's name in the menu bar icon's menu (no "in use": showing it says so).
    static func inUseLine(_ v: AccountView) -> String? { v.inUseLine }

    /// The Dock menu's top line: "Claude Main · ultra-1" (its lamp says it's in use); the usual "Claude Main" + plan while
    /// no account is known.
    static func dockTitle(name: String, _ v: AccountView, plan: String?) -> String {
        if let s = inUseShort(v) { return "Claude \(name) · \(s)" }
        return "Claude \(name)" + (plan.map { " · \($0)" } ?? "")
    }

    /// "week 12%", "5-hour 8%", or "no numbers".
    static func weekWords(_ used: Double?, week: Bool) -> String {
        guard let p = used else { return "no numbers" }
        return "\(week ? "week" : "5-hour") \(Int(p.rounded()))%"
    }

    /// Every standby account, in the order a full limit offers them (the card's and the Switch page's, SwitchOffer), each with
    /// when it was last in use.
    /// `own`: the standby id of the profile's own account in a clash, flagged so the submenu ticks it once (still switchable)
    /// and leaves it out of the standby rows.
    static func lines(_ e: AccountEntry, now: Date = Date(), own: String? = nil) -> [Line] {
        let offers = e.switchOffers(now: now)
        let best = AccountBook.best(offers.map(\.standby), now: now)
        return offers.map { o in
            let full = o.knownFull(now: now)          // orders and picks the offer only; never shown
            let words = o.standby.lastInUse.map { AccountBook.ago($0, now: now) } ?? ""
            return Line(key: o.key, short: o.short, address: o.standby.label, words: words, room: !full, canSwitch: o.standby.seat != nil || !o.standby.email.isEmpty,
                        offered: o.standby.id == best?.id, own: o.standby.id == own)
        }
    }

    /// The own account's ticked row: "ann · move Claude Code back here".
    static func backTitle(_ short: String) -> String { "\(short) · \(SwitchOffer.moveBackWords)" }

    /// The one to offer while a limit is full: AccountBook.best's (an account remembered by its address only is never it).
    static func best(_ lines: [Line]) -> Line? { lines.first { $0.offered } }

    /// "Switch to ultra-3…": on the top level, only while a limit is full.
    static func bestItem(_ l: Line, target: AnyObject, action: Selector) -> NSMenuItem {
        accountItem(l, prefix: l.own ? SwitchOffer.moveBackPrefix : "Switch to ", suffix: "…", enabled: true, target: target, action: action)
    }

    /// A row for one account: a native item with its short name while that tells the accounts apart (an address that is
    /// shown), else an AddressMenuRow (the blurred stand-in, the address while the menu highlights the row), so several hidden
    /// accounts stay distinguishable. Either way its action sends `action` to `target` from an item that holds the Switch
    /// page's key, and its title is the words ("hidden address" while hidden).
    private static func accountItem(_ l: Line, prefix: String, suffix: String, enabled: Bool, target: AnyObject, action: Selector) -> NSMenuItem {
        let i: NSMenuItem
        if AddressSettings.hides(l.address) && AddressPrivacy.shared.blur {
            let key = l.key
            i = AddressMenuRow.item(prefix: prefix, address: l.address, suffix: suffix, enabled: enabled) { [weak target] in
                let sender = NSMenuItem(); sender.representedObject = key      // what the action reads
                NSApp.sendAction(action, to: target, from: sender)
            }
        } else {
            i = NSMenuItem(title: prefix + l.short + suffix, action: enabled ? action : nil, keyEquivalent: "")
            i.target = target; i.isEnabled = enabled
        }
        i.representedObject = l.key
        return i
    }

    /// "Switch account ›": the account in use ticked, then every standby account. Nil for a profile with one account.
    static func submenuItem(_ v: AccountView, lines: [Line], inUseUsed: Double?, inUseWeek: Bool,
                            target: AnyObject, action: Selector) -> NSMenuItem? {
        guard !lines.isEmpty else { return nil }
        let sub = NSMenu(title: "Switch account"); sub.autoenablesItems = false
        // first, always: switching is experimental (Experimental.swift)
        let warn = NSMenuItem(title: ExperimentalPanel.title, action: nil, keyEquivalent: "")
        warn.isEnabled = false
        sub.addItem(warn)
        sub.addItem(.separator())
        if let s = inUseShort(v) {
            // the account in use: the menu's own checkmark, enabled so it doesn't read as broken; choosing it does nothing
            // (a clash: the profile's own account is on its standby list too: this one row, ticked, says what choosing it does)
            let back = lines.first { $0.own }
            let i = NSMenuItem(title: back != nil ? backTitle(s) : s + (inUseUsed == nil ? "" : " · " + weekWords(inUseUsed, week: inUseWeek)),
                               action: back?.canSwitch == true ? action : nil, keyEquivalent: "")
            i.state = .on; i.isEnabled = true
            if let back, back.canSwitch { i.target = target; i.representedObject = back.key }
            sub.addItem(i)
        }
        for l in lines where !l.own || inUseShort(v) == nil {
            // standby accounts plain, by address only
            sub.addItem(accountItem(l, prefix: "", suffix: "…", enabled: l.canSwitch, target: target, action: action))
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
