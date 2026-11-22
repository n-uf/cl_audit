// SwitchAccountMenu: the dashboard card's "Switch account" menu as an NSMenu (it was a SwiftUI Menu), so that its rows for
// accounts can be AddressMenuRows: while addresses are hidden each draws AddressPrivacy's one blurred stand-in (the same for
// every account) and the real address only while the menu highlights it, with "hidden address" as its title and accessibility
// label. A SwiftUI Menu's items are plain titles, which would have to say "hidden address" for every account and so couldn't
// tell the accounts apart on screen.
//
// The items are what they were, in the same order, with the same actions:
//   - the account in use, ticked, with its plan
//   - Divider, every standby account (by address only), a pick opens the Switch page with that account picked
//   - Divider, "Sign in to another account…"
// The control is the same key (FaceKeyLabel); it pops the menu under itself when pressed (MenuPopButton).

import AddressPrivacy
import AppKit
import SwiftUI

final class SwitchAccountMenu: NSObject {
    /// A standby account in the menu: its Switch page key and its address (or "account 1a2b3c4d" label).
    struct Row: Equatable { var key: String; var address: String }

    let label: String?
    let plan: String?
    let standby: [Row]
    let pick: (String) -> Void
    let newAccount: () -> Void

    /// `label`: the account in use (nil: none known, no ticked row); `plan`: its plan, shown beside it.
    init(label: String?, plan: String?, standby: [Row], pick: @escaping (String) -> Void, newAccount: @escaping () -> Void) {
        self.label = label; self.plan = plan; self.standby = standby; self.pick = pick; self.newAccount = newAccount
    }

    @objc private func picked(_ item: NSMenuItem) {
        if let key = item.representedObject as? String { pick(key) }
    }
    @objc private func signInToAnother(_ item: NSMenuItem) { newAccount() }

    /// The menu now (built each time it is asked for, so it follows Show emails).
    func menu() -> NSMenu {
        let m = NSMenu(title: "Switch account"); m.autoenablesItems = false
        if let label {
            // (one row, the account in use: its words, never a row drawn by hand; "hidden address" while hidden)
            let words = AddressSettings.words(label)
            let i = NSMenuItem(title: AccountCard.tickedTitle(label: words, plan: plan), action: nil, keyEquivalent: "")
            i.state = .on; i.isEnabled = true
            m.addItem(i)
        }
        if !standby.isEmpty {
            m.addItem(.separator())
            for s in standby { m.addItem(accountItem(s)) }
        }
        m.addItem(.separator())
        let other = NSMenuItem(title: "Sign in to another account…", action: #selector(signInToAnother(_:)), keyEquivalent: "")
        other.target = self
        m.addItem(other)
        return m
    }

    /// A standby account: an AddressMenuRow while its address is an address (hidden: the stand-in, the address only while the menu
    /// highlights the row; shown: the address), else a native item (a phrase). Its title is the words (nothing of the address
    /// while hidden) and a pick sends the Switch page's key to `pick`.
    private func accountItem(_ s: Row) -> NSMenuItem {
        let i: NSMenuItem
        if AddressSettings.hides(s.address) {
            let key = s.key, pick = pick
            i = AddressMenuRow.item(address: s.address) { pick(key) }
        } else {
            i = NSMenuItem(title: s.address, action: #selector(picked(_:)), keyEquivalent: "")
            i.target = self
        }
        i.representedObject = s.key
        return i
    }

    /// Pops the menu from `view`, under it, and keeps this object alive while it is open (a native item's target is weak).
    func pop(from view: NSView) {
        let m = menu()
        withExtendedLifetime(self) {
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY : 0), in: view)
        }
    }
}

/// Where a MenuPopButton's menu opens: the control's own frame.
final class MenuAnchor { weak var view: NSView? }

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView { let v = NSView(); anchor.view = v; return v }
    func updateNSView(_ v: NSView, context: Context) { anchor.view = v }
}

/// A key that opens an NSMenu under itself: `make` builds the menu each time it is pressed.
struct MenuPopButton<Label: View>: View {
    let make: () -> SwitchAccountMenu
    let label: Label
    @State private var anchor = MenuAnchor()

    init(make: @escaping () -> SwitchAccountMenu, @ViewBuilder label: () -> Label) {
        self.make = make; self.label = label()
    }

    var body: some View {
        Button { if let v = anchor.view { make().pop(from: v) } } label: { label }
            .background(MenuAnchorView(anchor: anchor))
            // (the SwiftUI Menu this replaces was read as a pop-up button: VoiceOver still says it opens a menu)
            .accessibilityHint("Opens a menu")
    }
}
