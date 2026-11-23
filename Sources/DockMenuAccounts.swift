// The menu bar menu's accounts (DockMenu.swift is the part the Dock tile plug-in compiles too): the account in use, in the
// split Terminal's account and the sign-in, each standby account, Sign in to another account…, their addresses through
// AddressPrivacy (a hidden one drawn by the kit's account row, MenuRows), and the rows' plain words the checks read.

import AddressPrivacy
import AppKit
import MenuRows
import ProfileCore

extension DockTileMenu {
    /// The menu's rows for a profile and its value now. `header` true: a Dock menu, the profile row then the actions (no
    /// accounts, numbers or states: the Dock icon's panel has them); false: the menu bar's, under its row (which says the
    /// profile and its numbers), the accounts then the actions. `windowOpen`: its Claude window runs; `appRunning`: the Dock
    /// icon app's own menu (Quit and keep is its own). Without the agent (`agentRuns` false: the Dock tile's) the actions, the
    /// agent's to do, are left out and the menu says so.
    static func rows(_ e: AccountEntry, _ show: ProfileShow, windowOpen: Bool, agentRuns: Bool = true, appRunning: Bool = false,
                     header: Bool = true, now: Date = Date()) -> [Row] {
        let p = PluginProfile(e)
        return header ? dockRows(p, windowOpen: windowOpen, agentRuns: agentRuns, appRunning: appRunning)
               : actions(p, after: accounts(e, show, actions: agentRuns, now: now), windowOpen: windowOpen, agentRuns: agentRuns,
                         appRunning: appRunning)
    }

    /// A Dock menu's rows for the app's entry (DockTileMenu.dockRows over its PluginProfile).
    static func dockRows(_ e: AccountEntry, windowOpen: Bool, agentRuns: Bool = true, appRunning: Bool = false) -> [Row] {
        dockRows(PluginProfile(e), windowOpen: windowOpen, agentRuns: agentRuns, appRunning: appRunning)
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

    /// Whether the row's address is hidden now (`blur`: a test override of the setting).
    static func hidden(_ r: AddressRow, blur: Bool? = nil) -> Bool {
        AddressSettings.hides(r.address) && (blur ?? AddressPrivacy.shared.blur)
    }

    /// A row's words as plain text (a native item's title, the checks' lines): the address as it is, or "hidden address"
    /// while hidden (the menu bar draws a hidden one as the kit's account row, whose title this is). Only the address is cut to keep
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

    // MARK: the menu with its addresses

    /// The rows as an NSMenu (DockTileMenu.menu), its address rows drawn: `views`, a menu this process draws (the menu
    /// bar's), where a hidden address is the kit's row; false for a Dock menu (plain titles).
    static func menu(_ rows: [Row], light: NSColor?, views: Bool, target: AnyObject, action: Selector) -> NSMenu {
        menu(rows, light: light, target: target, action: action) { item($0, views: views, target: target, action: action) }
    }

    /// The rows' items added to `m` (the menu bar's menu adds them under its own row), its address rows drawn as `menu` does.
    static func add(_ rows: [Row], to m: NSMenu, light: NSColor?, views: Bool, target: AnyObject, action: Selector) {
        add(rows, to: m, light: light, target: target, action: action) { item($0, views: views, target: target, action: action) }
    }

    /// An address row's item: the kit's account row (MenuRows' MenuAccountRowView) while its address is hidden in a menu this
    /// process draws, else a native item titled with its words. The account in use is ticked and enabled (so it doesn't read
    /// as broken); choosing it does nothing unless it has an act.
    static func item(_ r: AddressRow, views: Bool, target: AnyObject, action: Selector) -> NSMenuItem {
        let what = r.act.map { object($0, r.target) }
        let i: NSMenuItem
        if views, hidden(r) {
            let row = MenuAccountRow(prefix: r.prefix, address: r.address, inUse: r.ticked, tag: r.suffix, enabled: r.enabled)
            i = MenuAccountRowView.item(row) { [weak target] in
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
}
