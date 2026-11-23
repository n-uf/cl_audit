// DockMenu: a profile's right-click menus. The Dock menus (the Dock icon app's, IconApp.profileMenu, over the rows macOS adds:
// Options, Show All Windows, Hide, Quit; and the Dock tile plug-in's while the app isn't running, DockTile/Plugin.swift, macOS
// adding Options and Open) are short, since the Dock icon's own panel (Details.swift) shows the accounts, numbers and states
// with views the Dock menu can't draw (it takes plain titles only, no hover reaches the app: probed live 2026-11-22):
//
//   ● Claude Main                          the profile and its light (its own colour)
//   ———
//     Claude window ▸                      Open while it's closed; Show, Quit (and Quit and keep, the app running)
//     Quick chat · Refresh now
//   ———
//     Dashboard · Profile settings…
//
// The menu bar icon's menu (MenuBar.menuNeedsUpdate) draws its own views, so under its row it also lists the accounts: the
// account in use ticked, in the split Terminal's account and the sign-in, each standby account, Sign in to another account….
// Addresses there are whole, never a name made from one, through AddressPrivacy (Settings ▸ General ▸ Emails): a hidden one
// is the kit's account row (MenuRows: the blurred stand-in, the address only while the pointer is on the row). Every row is at most 40
// characters (a longer one is cut in the middle). Every item has its own tag, the submenu's too: the Dock hands a click on a
// Dock tile's menu back by the item's tag (_sendDockMenuCommand:withTag:).
//
// The plug-in starts nothing itself: Quick chat (cl_quick, opened by the agent: ClQuick) and Refresh now post their notices;
// the rest ask the agent (DockTile.menuNote), which does them. Its menu (dockRows) needs only the profiles file's entry
// (PluginProfile): it reads no sign-in and no record.
//
// This file is the part the plug-in compiles too (build.sh: the plug-in's sources): the rows, the Dock menus, the tags and
// the notices. The menu bar's accounts and their address rows (AddressPrivacy, MenuRows) are the app's: DockMenuAccounts.swift.

import AppKit
import ProfileCore

enum DockTileMenu {
    enum Act: String, CaseIterable {
        case switchTo, signIn, addAccount, quickChat, openWindow, quitWindow, quitKeep, refresh, dashboard, settings
    }

    /// A row that holds an address: `prefix` + the address + `suffix`.
    struct AddressRow: Equatable {
        var prefix = ""
        let address: String
        var suffix = ""
        /// The account in use: the menu's checkmark.
        var ticked = false
        /// What a click does (with `target`, DockTileMenu.object); nil: nothing (the account in use).
        var act: Act? = nil
        /// The profile's id, or for a switch the Switch page's key ("<profile>~<standby>").
        var target = ""
        var enabled = true
        /// One account's row (the account in use, Terminal's, a standby one), not an action that names an address.
        var account = true
    }

    indirect enum Row: Equatable {
        case profile(String)                // "Claude Main", with the profile's light
        case address(AddressRow)
        case status(String)                 // a grey line under the menu bar menu's account in use (problemLine)
        case info(String)
        case separator
        case action(String, Act, String)    // the profile's id
        case submenu(String, [Row])         // "Claude window ▸"
    }

    /// The longest row, in characters.
    static let rowCharacters = 40

    /// "Claude Main"; a name that starts with Claude as it is (cl_quick's rule).
    static func title(_ name: String) -> String { name.lowercased().hasPrefix("claude") ? name : "Claude " + name }

    // (the menu bar's rows, `rows(_:_:…)` with its accounts: DockMenuAccounts.swift)

    /// A Dock menu's rows: the profile, then the Claude window and the actions. Nothing of the profile's record (no account,
    /// number or state), so the menu needs none read. `windowOpen`: its Claude window runs; `appRunning`: the Dock icon app's
    /// own menu (Quit and keep is its own). Without the agent (`agentRuns` false: the Dock tile's) the actions, the agent's to
    /// do, are left out and the menu says so.
    static func dockRows(_ e: PluginProfile, windowOpen: Bool, agentRuns: Bool = true, appRunning: Bool = false) -> [Row] {
        actions(e, after: [.profile(title(e.name.isEmpty ? e.shortLabel : e.name))], windowOpen: windowOpen,
                agentRuns: agentRuns, appRunning: appRunning)
    }

    /// `rows` then the Claude window and the actions; without the agent, the line that says so instead.
    static func actions(_ e: PluginProfile, after head: [Row], windowOpen: Bool, agentRuns: Bool, appRunning: Bool) -> [Row] {
        var rows = head
        guard agentRuns else {
            rows.append(.separator)
            rows.append(.info("cl_audit's agent isn't running"))
            return rows
        }
        if !rows.isEmpty { rows.append(.separator) }
        if e.claudeWindow {
            let inside: [Row] = windowOpen
                ? [.action("Show", .openWindow, e.id), .action("Quit", .quitWindow, e.id)]
                    + (appRunning && e.windowFollowsDock ? [.action("Quit and keep", .quitKeep, e.id)] : [])
                : [.action("Open", .openWindow, e.id)]
            rows.append(.submenu("Claude window", inside))
        }
        rows.append(.action(ClQuick.itemTitle, .quickChat, e.id))      // cl_quick, or Get cl_quick… (ClQuick)
        rows.append(.action("Refresh now", .refresh, e.id))
        rows.append(.separator)
        rows.append(.action("Dashboard", .dashboard, e.id))
        rows.append(.action("Profile settings…", .settings, e.id))
        return rows
    }

    // (the menu bar menu's accounts and problemLine: DockMenuAccounts.swift)

    // MARK: words

    /// A row cut to `max` characters in the middle ("Usage hidden: Terminal on bob.sm…ample.com"), so both ends still read.
    static func fit(_ s: String, max: Int = rowCharacters) -> String {
        guard s.count > max, max > 1 else { return s }
        let keep = max - 1, head = (keep + 1) / 2, tail = keep - head
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
    }

    // (an address row's words and the rows as plain lines: DockMenuAccounts.swift)

    // MARK: the menu

    /// The rows as an NSMenu. Each action sends `action` to `target` from an item whose representedObject is
    /// "<action>:<target>" (DockTileMenu.object). `light`: the profile's own colour, nil for none (the light unlit).
    /// `address`: an address row's item (the app's, DockMenuAccounts.swift); nil, address rows are left out (the Dock
    /// tile's menu has none).
    static func menu(_ rows: [Row], light: NSColor?, target: AnyObject, action: Selector,
                     address: ((AddressRow) -> NSMenuItem)? = nil) -> NSMenu {
        let m = NSMenu(); m.autoenablesItems = false
        add(rows, to: m, light: light, target: target, action: action, address: address)
        tag(m)
        return m
    }

    /// Every item its own tag, the submenus' too (from `next` on): the Dock hands a click on a Dock tile's menu back by the
    /// item's tag, and with one tag for all every click went to the first item (seen live).
    static func tag(_ m: NSMenu, from next: Int = 1) {
        var n = next
        func walk(_ m: NSMenu) {
            for i in m.items {
                i.tag = n; n += 1
                if let sub = i.submenu { walk(sub) }
            }
        }
        walk(m)
    }

    /// The rows' items added to `m` (the menu bar's menu adds them under its own row). `address` as in `menu`.
    static func add(_ rows: [Row], to m: NSMenu, light: NSColor?, target: AnyObject, action: Selector,
                    address: ((AddressRow) -> NSMenuItem)? = nil) {
        for row in rows {
            switch row {
            case .separator: m.addItem(.separator())
            case .profile(let s):
                let i = NSMenuItem(title: fit(s), action: nil, keyEquivalent: ""); i.isEnabled = false
                i.attributedTitle = NSAttributedString(string: i.title, attributes: [
                    .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold), .foregroundColor: NSColor.secondaryLabelColor])
                i.image = Self.light(light)
                m.addItem(i)
            case .info(let s):
                let i = NSMenuItem(title: fit(s), action: nil, keyEquivalent: ""); i.isEnabled = false; m.addItem(i)
            case .status(let s):
                let i = NSMenuItem(title: fit(s), action: nil, keyEquivalent: ""); i.isEnabled = false
                i.indentationLevel = 1
                m.addItem(i)
            case .action(let s, let act, let what):
                let i = NSMenuItem(title: fit(s), action: action, keyEquivalent: "")
                i.target = target; i.representedObject = object(act, what)
                m.addItem(i)
            case .address(let r):
                // (a menu with address rows always comes with their items: only the Dock tile's has none, and no address rows)
                assert(address != nil, "an address row with no address item: DockTileMenu.menu(…, views:) draws them")
                if let address { m.addItem(address(r)) }
            case .submenu(let s, let inside):
                let i = NSMenuItem(title: fit(s), action: nil, keyEquivalent: "")
                let sub = NSMenu(title: s); sub.autoenablesItems = false
                add(inside, to: sub, light: light, target: target, action: action, address: address)
                i.submenu = sub
                m.addItem(i)
            }
        }
    }

    /// The profile's light for its row: its own colour, lit; for a profile with none an unlit ring.
    static func light(_ c: NSColor?) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            let dot = r.insetBy(dx: 2.5, dy: 2.5)
            if let c {
                c.withAlphaComponent(0.3).setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
                c.setFill()
                NSBezierPath(ovalIn: dot).fill()
            } else {
                NSColor.tertiaryLabelColor.setStroke()
                let p = NSBezierPath(ovalIn: dot); p.lineWidth = 1; p.stroke()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    // MARK: what a click asks

    /// The agent's notice for an action (object "<action>:<target>": a distributed notice carries a string only).
    static func object(_ a: Act, _ id: String) -> String { "\(a.rawValue):\(id)" }
    static func parse(_ object: Any?) -> (Act, String)? {
        guard let s = object as? String, let colon = s.firstIndex(of: ":"),
              let a = Act(rawValue: String(s[..<colon])) else { return nil }
        let id = String(s[s.index(after: colon)...])
        return id.isEmpty ? nil : (a, id)
    }

    /// The profile an action is for: its target, or for a switch the Switch page's key's profile.
    static func profile(_ a: Act, _ target: String) -> String {
        a == .switchTo ? (SwitchKey.parse(target)?.profile ?? "") : target
    }
}

/// The Switch page's key, "<profile>~<standby id>": the menus, the alerts and the card name a switch by it (SwitchOffer.key,
/// AccountEntry.switchKey). Here, so the Dock tile plug-in reads a menu action's profile the same way.
enum SwitchKey {
    static func make(_ profile: String, _ standby: String) -> String { "\(profile)~\(standby)" }
    static func parse(_ key: String) -> (profile: String, standby: String)? {
        let parts = key.split(separator: "~", maxSplits: 1).map(String.init)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty ? (parts[0], parts[1]) : nil
    }
}

private extension NSFont {
    func withWeight(_ w: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: pointSize, weight: w) }
}
