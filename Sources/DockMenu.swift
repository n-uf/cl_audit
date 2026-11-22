// DockMenu: a profile's right-click menu in cl_quick's shape, one design for the Dock icon app's menu (IconApp.profileMenu,
// over the rows macOS adds: Options, Show All Windows, Hide, Quit), the Dock tile plug-in's while the app isn't running
// (DockTile/Plugin.swift, macOS adding Options and Open) and the menu bar icon's under its row (MenuBar.menuNeedsUpdate):
//
//   ● Claude Main                          the profile and its light (its own colour)
//   ✓ ann@example.com                      the account in use, ticked; choosing it does nothing
//     5-hour 34% · Week 12%                its one grey status line (a full limit in crimson)
//     bob@example.com · Terminal           in the split: Terminal's account, a click switches to it,
//     Sign Terminal in to ann@example.com… and the one extra action
//     cy@example.com                       each standby account: a click opens the Switch page with it
//     Sign in to another account…
//   ———
//     Claude window ▸                      Open while it's closed; Show, Quit (and Quit and keep, the app running)
//     Quick chat · Refresh now
//   ———
//     Dashboard · Profile settings…
//
// Addresses are whole, never a name made from one, and go through AddressPrivacy (Settings ▸ General ▸ Emails): shown as they
// are, or hidden. The menu bar's menu draws a hidden one as AddressMenuRow (the blurred stand-in, the address while the row
// is highlighted). The Dock draws the Dock menus itself and leaves out an item's view, so there a hidden address is the
// words "hidden address", numbered when several rows would read the same (a cue that holds nothing of any address). Every
// row is at most 40 characters (a longer one is cut in the middle). Every item has its own tag, the submenu's too: the
// Dock hands a click on a Dock tile's menu back by the item's tag (_sendDockMenuCommand:withTag:).
//
// The plug-in starts nothing itself: Quick chat and Refresh now post the notices the Dock icon app posts; the rest ask the
// agent (DockTile.menuNote), which does them. It reads no sign-in and no standby account's record: the standby rows are
// the profiles file's list (AccountEntry), the status line the profile's own record.

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
        case status(String, full: Bool)     // the account's one line; a full limit in crimson
        case info(String)
        case separator
        case action(String, Act, String)    // the profile's id
        case submenu(String, [Row])         // "Claude window ▸"
    }

    /// The longest row, in characters.
    static let rowCharacters = 40
    /// The split's status line when "Usage hidden: Terminal on <address>" wouldn't fit.
    static let splitDiffers = "Usage hidden: Terminal's account differs"

    /// "Claude Main"; a name that starts with Claude as it is (cl_quick's rule).
    static func title(_ name: String) -> String { name.lowercased().hasPrefix("claude") ? name : "Claude " + name }

    /// The menu's rows for a profile and its value now. `windowOpen`: its Claude window runs; `appRunning`: the Dock icon
    /// app's own menu (Quit and keep is its own); `header` false: the menu bar's, under its row, which already says the
    /// profile and its numbers (no profile row, no status line). Without the agent (`agentRuns` false: the Dock tile's) the
    /// actions, the agent's to do, are left out and the menu says so.
    static func rows(_ e: AccountEntry, _ show: ProfileShow, windowOpen: Bool, agentRuns: Bool = true, appRunning: Bool = false,
                     header: Bool = true, now: Date = Date()) -> [Row] {
        var rows: [Row] = []
        if header { rows.append(.profile(title(e.name.isEmpty ? Account.label(e) : e.name))) }
        rows += accounts(e, show, header: header, actions: agentRuns, now: now)
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
        rows.append(.action("Quick chat", .quickChat, e.id))
        rows.append(.action("Refresh now", .refresh, e.id))
        rows.append(.separator)
        rows.append(.action("Dashboard", .dashboard, e.id))
        rows.append(.action("Profile settings…", .settings, e.id))
        return rows
    }

    /// The accounts: the one in use ticked with its status line under it (`header`), in the split Terminal's account and the
    /// sign-in to the app's, each standby account, Sign in to another account…. `actions` false (no agent to do them): the
    /// account in use and its status only.
    static func accounts(_ e: AccountEntry, _ show: ProfileShow, header: Bool, actions: Bool = true, now: Date = Date()) -> [Row] {
        let d = show.display
        let listed = e.listed(by: show.view)                    // never the account in use on standby too
        let lines = SwitchMenu.lines(listed, now: now, own: show.ownStandbyID)
        var out: [Row] = []
        // the account in use (none while signed out); in a clash the profile's own account, whose click moves Claude Code
        // back to it ("ann@example.com · move back here", moveBackSuffix)
        if d.sign != .signedOut, let inUse = show.inUseLabel {
            if let own = lines.first(where: { $0.own }) {
                out.append(.address(AddressRow(address: inUse, suffix: moveBackSuffix, ticked: true,
                                               act: actions && own.canSwitch ? .switchTo : nil, target: own.key)))
            } else {
                out.append(.address(AddressRow(address: inUse, ticked: true)))
            }
        }
        if header { out.append(status(show, now: now)) }
        guard actions else { return out }
        // the split by hand: Terminal's account is its own row (a click switches to it, as the card's row does)
        var terminal: String?
        if d.split != nil, show.splitWords?.switched != true,
           let code = listed.standby.first(where: { show.view.isCodeRow(id: $0.seat?.account, email: $0.seat?.email ?? $0.email) }) {
            let key = SwitchOffer(profile: e.id, standby: code).key
            if let l = lines.first(where: { $0.key == key && !$0.own }) {
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
        for l in lines where !l.own && l.key != terminal {
            out.append(.address(AddressRow(address: l.address, act: .switchTo, target: l.key, enabled: l.canSwitch)))
        }
        out.append(.action("Sign in to another account…", .addAccount, e.id))
        return out
    }

    /// The account's one status line: a full limit (crimson), why the numbers aren't shown, the numbers, or why there are none.
    static func status(_ show: ProfileShow, now: Date = Date()) -> Row {
        let d = show.display
        if let full = d.full(now: now) {
            return .status(full.title + (full.resets.map { " · in \(TimeWords.countdown($0, now: now))" } ?? ""), full: true)
        }
        if d.split != nil, let w = show.splitWords {
            if w.switched { return .status(SplitUsage.switchingHead(w.code), full: false) }
            // Terminal's account is the row below: its address here only when the line still fits whole
            let named = "Usage hidden: Terminal on " + AddressSettings.words(w.code)
            return .status(named.count <= rowCharacters ? named : splitDiffers, full: false)
        }
        // the record's one line of state (the card's, cut to the row), then the sign-in, then why the numbers are another's
        if let line = show.lineWords(short: true), !line.contains("\n") { return .status(line, full: false) }
        switch d.sign {
        case .expired: return .status("The sign-in stopped working", full: false)
        case .signedOut: return .status("Signed out", full: false)
        case .unreadable: return .status("Can't read Terminal's sign-in", full: false)
        default: break
        }
        if let clash = d.clash, d.usage == nil { return .status("Terminal is on \(clash.name)'s account", full: false) }
        if d.otherAccount { return .status("Terminal is on another account", full: false) }
        if let u = d.usage, u.fiveHour != nil || u.weekly != nil {
            return .status([u.noFiveHour ? nil : "5-hour \(Painter.pct(u.fiveHour))", "Week \(Painter.pct(u.weekly))"]
                .compactMap { $0 }.joined(separator: " · "), full: false)
        }
        return .status(show.record == nil ? "No usage yet" : "No recent numbers", full: false)
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

    /// A row's words as plain text (a Dock menu's title, every row's accessibility words): the address as it is, or "hidden
    /// address" while hidden, with `number` after it ("hidden address 2") where several account rows would read the same.
    /// Only the address is cut to keep the row within 40 characters, never the words around it ("Sign Terminal in to …",
    /// " · Terminal", " · move back here").
    static func words(_ r: AddressRow, number: Int? = nil, blur: Bool? = nil) -> String {
        let shown = hidden(r, blur: blur) ? AddressText.hidden + (number.map { " \($0)" } ?? "")
                                          : AddressSettings.words(r.address, blur: blur)
        let room = rowCharacters - r.prefix.count - r.suffix.count
        return r.prefix + (shown.count > room ? fit(shown, max: max(room, 9)) : shown) + r.suffix
    }

    /// The clash's ticked row: what choosing the profile's own account does, short enough to leave its address room.
    static let moveBackSuffix = " · move back here"

    /// Each hidden account row's number, in the order they are shown, when more than one is hidden (else none).
    static func numbers(_ rows: [Row], blur: Bool? = nil) -> [Int: Int] {
        let hiddenRows = rows.enumerated().compactMap { n, row -> Int? in
            if case .address(let r) = row, r.account, hidden(r, blur: blur) { return n }
            return nil
        }
        guard hiddenRows.count > 1 else { return [:] }
        return Dictionary(uniqueKeysWithValues: hiddenRows.enumerated().map { ($1, $0 + 1) })
    }

    /// The rows as plain lines, top to bottom (the checks read the menu this way): "✓ " before the ticked row, "▸" after a
    /// submenu's title and its rows indented.
    static func lines(_ rows: [Row], blur: Bool? = nil) -> [String] {
        let nums = numbers(rows, blur: blur)
        var out: [String] = []
        for (n, row) in rows.enumerated() {
            switch row {
            case .profile(let s), .info(let s): out.append(fit(s))
            case .status(let s, _): out.append(fit(s))
            case .separator: out.append("—")
            case .action(let s, _, _): out.append(fit(s))
            case .address(let r): out.append((r.ticked ? "✓ " : "") + words(r, number: nums[n], blur: blur))
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
        let nums = numbers(rows)
        for (n, row) in rows.enumerated() {
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
            case .status(let s, let full):
                let i = NSMenuItem(title: fit(s), action: nil, keyEquivalent: ""); i.isEnabled = false
                i.indentationLevel = 1
                if full {
                    i.attributedTitle = NSAttributedString(string: i.title, attributes: [
                        .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold), .foregroundColor: Painter.crimson])
                }
                m.addItem(i)
            case .action(let s, let act, let what):
                let i = NSMenuItem(title: fit(s), action: action, keyEquivalent: "")
                i.target = target; i.representedObject = object(act, what)
                m.addItem(i)
            case .address(let r):
                m.addItem(item(r, number: nums[n], views: views, target: target, action: action))
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
    /// nothing unless it has an act (a clash's move back).
    static func item(_ r: AddressRow, number: Int?, views: Bool, target: AnyObject, action: Selector) -> NSMenuItem {
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
            i = NSMenuItem(title: words(r, number: number), action: what == nil || !r.enabled ? nil : action, keyEquivalent: "")
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
