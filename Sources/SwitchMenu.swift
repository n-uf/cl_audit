// SwitchMenu: a profile's standby accounts as its menus list them (the Dock icon's, the Dock tile's and the menu bar icon's,
// DockTileMenu; quick chat's offer), in the order a full limit offers them, each with when it was last in use ("3 days
// ago"; a standby account isn't read, so it has no week); picking one opens the Switch page with it picked. The rows
// themselves are DockTileMenu's (DockMenu.swift).

import Foundation
import ProfileCore

enum SwitchMenu {
    /// One standby account in a menu.
    struct Line: Equatable {
        let key: String             // "<profile>~<standby account>": the Switch page's
        let short: String
        /// The account's address (or its "account 1a2b3c4d" label), for a row drawn by the kit's account row (MenuRows); never in a title.
        var address = ""
        let words: String           // "3 days ago", or "" when it was never in use here
        /// Not known to be full: it may be offered while a limit is full.
        let room: Bool
        var canSwitch = true
        /// The one a full limit offers first (AccountBook.best, the one rule the card and the alert use too).
        var offered = false
    }

    /// "ultra-1": under the profile's name in the menu bar icon's menu (no "in use": showing it says so).
    static func inUseLine(_ v: AccountView) -> String? { v.inUseLine }

    /// Every standby account, in the order a full limit offers them (the card's and the Switch page's, SwitchOffer), each with
    /// when it was last in use. `notOffered`: listed but never the one a full limit offers (in the split, Terminal's own
    /// account: the full numbers are its, AccountEntry.fullOffer).
    static func lines(_ e: AccountEntry, notOffered: (StandbyAccount) -> Bool = { _ in false }, now: Date = Date()) -> [Line] {
        let offers = e.switchOffers(now: now)
        let best = AccountBook.best(offers.map(\.standby).filter { !notOffered($0) }, now: now)
        return offers.map { o in
            let full = o.knownFull(now: now)          // orders and picks the offer only; never shown
            let words = o.standby.lastInUse.map { AccountBook.ago($0, now: now) } ?? ""
            return Line(key: o.key, short: o.short, address: o.standby.label, words: words, room: !full, canSwitch: o.standby.seat != nil || !o.standby.email.isEmpty,
                        offered: o.standby.id == best?.id)
        }
    }

    /// The one to offer while a limit is full: AccountBook.best's (an account remembered by its address only is never it).
    static func best(_ lines: [Line]) -> Line? { lines.first { $0.offered } }
}
