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
// is AddressMenuRow (the blurred stand-in, the address while the row has the pointer on it). Every row is at most 40
// characters (a longer one is cut in the middle). Every item has its own tag, the submenu's too: the Dock hands a click on a
// Dock tile's menu back by the item's tag (_sendDockMenuCommand:withTag:).
//
// The plug-in starts nothing itself: Quick chat (cl_quick, opened by the agent: ClQuick) and Refresh now post their notices;
// the rest ask the agent (DockTile.menuNote), which does them. Its menu (dockRows) needs only the profiles file's entry: it
// reads no sign-in and no record.

import AddressPrivacy
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

    /// The menu's rows for a profile and its value now. `header` true: a Dock menu, the profile row then the actions (no
    /// accounts, numbers or states: the Dock icon's panel has them); false: the menu bar's, under its row (which says the
    /// profile and its numbers), the accounts then the actions. `windowOpen`: its Claude window runs; `appRunning`: the Dock
    /// icon app's own menu (Quit and keep is its own). Without the agent (`agentRuns` false: the Dock tile's) the actions, the
    /// agent's to do, are left out and the menu says so.
    static func rows(_ e: AccountEntry, _ show: ProfileShow, windowOpen: Bool, agentRuns: Bool = true, appRunning: Bool = false,
                     header: Bool = true, now: Date = Date()) -> [Row] {
        header ? dockRows(e, windowOpen: windowOpen, agentRuns: agentRuns, appRunning: appRunning)
               : actions(e, after: accounts(e, show, actions: agentRuns, now: now), windowOpen: windowOpen, agentRuns: agentRuns,
                         appRunning: appRunning)
    }

    /// A Dock menu's rows: the profile, then the Claude window and the actions. Nothing of the profile's record (no account,
    /// number or state), so the menu needs none read.
    static func dockRows(_ e: AccountEntry, windowOpen: Bool, agentRuns: Bool = true, appRunning: Bool = false) -> [Row] {
        actions(e, after: [.profile(title(e.name.isEmpty ? Account.label(e) : e.name))], windowOpen: windowOpen,
                agentRuns: agentRuns, appRunning: appRunning)
    }

    /// `rows` then the Claude window and the actions; without the agent, the line that says so instead.
    private static func actions(_ e: AccountEntry, after head: [Row], windowOpen: Bool, agentRuns: Bool, appRunning: Bool) -> [Row] {
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
                    + (appRunning && e.runs.windowFollowsDock ? [.action("Quit and keep", .quitKeep, e.id)] : [])
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

    /// The menu bar menu's accounts: the one in use ticked (with why its numbers aren't fresh, problemLine), in the split
    /// Terminal's account and the sign-in to the app's, each standby account, Sign in to another account…. `actions` false
    /// (no agent to do them): the account in use only.
    static func accounts(_ e: AccountEntry, _ show: ProfileShow, actions: Bool = true, now: Date = Date()) -> [Row] {
        let d = show.display
        let listed = e.listed(by: show.view)                    // never the account in use on standby too
        // (in the split, and while a switch waits, Terminal's own account is listed but never offered: its numbers are the full ones)
        let lines = SwitchMenu.lines(listed, notOffered: { show.view.isCodeRow(id: $0.seat?.account, email: $0.seat?.email ?? $0.email) }, now: now)
        var out: [Row] = []
        // the account in use (none while signed out)
        if d.sign != .signedOut, let inUse = show.view.label {
            out.append(.address(AddressRow(address: inUse, ticked: true)))
        }
        if let why = problemLine(state: show.record?.state) { out.append(.status(why)) }
        guard actions else { return out }
        // the split by hand: Terminal's account is its own row (a click switches to it, as the card's row does)
        var terminal: String?
        if d.split != nil, show.splitWords?.switched != true,
           let code = listed.standby.first(where: { show.view.isCodeRow(id: $0.seat?.account, email: $0.seat?.email ?? $0.email) }) {
            let key = SwitchOffer(profile: e.id, standby: code).key
            if let l = lines.first(where: { $0.key == key }) {
                terminal = key
                out.append(.address(AddressRow(address: l.address, suffix: " · Terminal", act: .switchTo, target: key, enabled: l.canSwitch)))
            }
        }
        // the one key: Claude Code's own sign-in in Terminal, the address it fills in named (the split's: the app's own)
        if d.key != nil {
            if let a = show.loginAddress, !a.isEmpty {
                out.append(.address(AddressRow(prefix: "Sign Terminal in to ", address: a, suffix: "…", act: .signIn, target: e.id, account: false)))
            } else {
                out.append(.action("Sign in…", .signIn, e.id))
            }
        }
        for l in lines where l.key != terminal {
            out.append(.address(AddressRow(address: l.address, act: .switchTo, target: l.key, enabled: l.canSwitch)))
        }
        out.append(.action("Sign in to another account…", .addAccount, e.id))
        return out
    }

    /// Why the numbers aren't fresh, in a few fixed words (never a system's own), under the menu bar menu's account in use: a
    /// read that failed, the usage service busy. A sign-in that expired, is signed out, refused or unreadable is the menu bar
    /// row's to say.
    static func problemLine(state: String?) -> String? {
        guard let state else { return nil }
        if state.hasPrefix("failed") { return "Couldn't update · retrying" }
        if state == "rateLimited" { return "Usage service busy · retrying later" }
        return nil
    }

    // MARK: words

    /// A row cut to `max` characters in the middle ("Usage hidden: Terminal on bob.sm…ample.com"), so both ends still read.
    static func fit(_ s: String, max: Int = rowCharacters) -> String {
        guard s.count > max, max > 1 else { return s }
        let keep = max - 1, head = (keep + 1) / 2, tail = keep - head
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
    }

    /// Whether the row's address is hidden now (`blur`: a test override of the setting).
    static func hidden(_ r: AddressRow, blur: Bool? = nil) -> Bool {
        AddressSettings.hides(r.address) && (blur ?? AddressPrivacy.shared.blur)
    }

    /// A row's words as plain text (a native item's title, the checks' lines): the address as it is, or "hidden address"
    /// while hidden (the menu bar draws a hidden one as AddressMenuRow, whose title this is). Only the address is cut to keep
    /// the row within 40 characters, never the words around it ("Sign Terminal in to …", " · Terminal").
    static func words(_ r: AddressRow, blur: Bool? = nil) -> String {
        let shown = AddressSettings.words(r.address, blur: blur)
        let room = rowCharacters - r.prefix.count - r.suffix.count
        return r.prefix + (shown.count > room ? fit(shown, max: max(room, 9)) : shown) + r.suffix
    }

    /// The rows as plain lines, top to bottom (the checks read the menu this way): "✓ " before the ticked row, "▸" after a
    /// submenu's title and its rows indented.
    static func lines(_ rows: [Row], blur: Bool? = nil) -> [String] {
        var out: [String] = []
        for row in rows {
            switch row {
            case .profile(let s), .info(let s): out.append(fit(s))
            case .status(let s): out.append(fit(s))
            case .separator: out.append("—")
            case .action(let s, _, _): out.append(fit(s))
            case .address(let r): out.append((r.ticked ? "✓ " : "") + words(r, blur: blur))
            case .submenu(let s, let inside): out.append(fit(s) + " ▸"); out += lines(inside, blur: blur).map { "  " + $0 }
            }
        }
        return out
    }

    // MARK: the menu

    /// The rows as an NSMenu. `views`: a menu this process draws (the menu bar's), where a hidden address is AddressMenuRow;
    /// false for a Dock menu (plain titles). Each action sends `action` to `target` from an item whose representedObject is
    /// "<action>:<target>" (DockTileMenu.object). `light`: the profile's own colour, nil for none (the light unlit).
    static func menu(_ rows: [Row], light: NSColor?, views: Bool, target: AnyObject, action: Selector) -> NSMenu {
        let m = NSMenu(); m.autoenablesItems = false
        add(rows, to: m, light: light, views: views, target: target, action: action)
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

    /// The rows' items added to `m` (the menu bar's menu adds them under its own row).
    static func add(_ rows: [Row], to m: NSMenu, light: NSColor?, views: Bool, target: AnyObject, action: Selector) {
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
                m.addItem(item(r, views: views, target: target, action: action))
            case .submenu(let s, let inside):
                let i = NSMenuItem(title: fit(s), action: nil, keyEquivalent: "")
                let sub = NSMenu(title: s); sub.autoenablesItems = false
                add(inside, to: sub, light: light, views: views, target: target, action: action)
                i.submenu = sub
                m.addItem(i)
            }
        }
    }

    /// An address row's item: AddressMenuRow while its address is hidden in a menu this process draws, else a native item
    /// titled with its words. The account in use is ticked and enabled (so it doesn't read as broken); choosing it does
    /// nothing unless it has an act.
    static func item(_ r: AddressRow, views: Bool, target: AnyObject, action: Selector) -> NSMenuItem {
        let what = r.act.map { object($0, r.target) }
        let i: NSMenuItem
        if views, hidden(r) {
            i = AddressMenuRow.item(prefix: r.prefix, address: r.address, suffix: r.suffix,
                                    enabled: r.enabled, ticked: r.ticked) { [weak target] in
                guard let what, let target else { return }
                let sender = NSMenuItem(); sender.representedObject = what      // what the action reads
                NSApp.sendAction(action, to: target, from: sender)
            }
        } else {
            i = NSMenuItem(title: words(r), action: what == nil || !r.enabled ? nil : action, keyEquivalent: "")
            i.target = target
            i.isEnabled = r.enabled
            if r.ticked { i.state = .on }
        }
        i.representedObject = what
        return i
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
        a == .switchTo ? (SwitchOffer.parse(target)?.profile ?? "") : target
    }
}

private extension NSFont {
    func withWeight(_ w: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: pointSize, weight: w) }
}
