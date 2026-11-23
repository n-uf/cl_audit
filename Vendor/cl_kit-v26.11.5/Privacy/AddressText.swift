// AddressText: the plain part of AddressPrivacy, Foundation only (no SwiftUI, no AppKit views, no app state). An account
// address that is hidden on screen is never the real address under a blur (a Gaussian blur over the real text keeps its
// length and letter shapes, and a screenshot gives them back by trying candidates): it is one fixed stand-in, the same for
// every address and never made from one. The real address is drawn only on an explicit reveal.
//
// Three plain forms, none of which holds anything of the address while it is hidden (no first letter, no length, no domain):
//   - `drawn`: what to DRAW or show where text can't blur (a CGContext, a notification, a status item title): the stand-in.
//   - `sentence`: what to put in RUNNING TEXT, accessibility words, a tooltip, an alert, a pop-up row: "hidden address".
//   - `short`: the SHORT NAME for compact rows ("Switch to …"): the local part, or "hidden address" while hidden.
//
// Everything here takes the setting as a VALUE (`blur`: the app's own setting), so it works in any process: a WidgetKit
// extension, a Dock plug-in, the menu bar's agent, a notification, an alert's text. The module never reads a setting by itself
// here (AddressDefaultsStore, apart, is the optional convenience that reads one an app names).
//
// An account id (a UUID, or its first characters) counts as hidden too: `needsHiding` says so for a piece of text, and the
// forms below hide whatever they are given, so an id is passed like an address and never drawn, spoken or put in a tooltip.

import Foundation

public enum AddressText {
    /// What every hidden address is drawn as: a fixed, address-shaped run of letters. The same whatever the address
    /// (same length, same letters), so it carries nothing about the real one: no first letter, no length, no hash.
    public static let standIn = "abcdefghijkl@mnopqrst.com"

    /// The words for a hidden address, in sentences and for accessibility: the same whatever the address.
    public static let hidden = "hidden address"

    /// The text to draw for an address: the address itself only when `revealed` (the pointer on it, a "peek", …) or when the
    /// blur is off; otherwise the stand-in. Use this for anything that draws text that can't blur: a notification, an
    /// NSStatusItem title, a CGContext, an NSImage that draws a Dock tile.
    public static func drawn(address: String, revealed: Bool = false, blur: Bool) -> String {
        revealed || !blur ? address : standIn
    }

    /// `drawn` as attributed text (the attributes are the caller's: font, colour, paragraph style). A context that can
    /// draw the blur look draws the stand-in blurred (AddressInk); one that can't draws it as it is.
    public static func attributed(address: String, revealed: Bool = false, blur: Bool,
                                  attributes: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        NSAttributedString(string: drawn(address: address, revealed: revealed, blur: blur), attributes: attributes)
    }

    /// An address in RUNNING TEXT (a line, a note, a tooltip, an alert's text, a pop-up row, VoiceOver's words, a log):
    /// "hidden address" while the blur is on, the address when it is off. Nothing of it while hidden: not its first letter,
    /// not its length, not its domain. Reveal only on the app's explicit word (`revealed`).
    public static func sentence(address: String, revealed: Bool = false, blur: Bool) -> String {
        revealed || !blur ? address : hidden
    }

    /// The same as `sentence`, kept under the name the accessibility labels use.
    public static func words(_ address: String, blur: Bool) -> String { sentence(address: address, blur: blur) }

    /// The SHORT NAME for a compact row (a menu's "Switch to …", a tab, a chip): the part before the @ while the blur is
    /// off, "hidden address" while it is on. Never any part of it while hidden.
    public static func short(address: String, revealed: Bool = false, blur: Bool) -> String {
        guard revealed || !blur else { return hidden }
        guard let at = address.firstIndex(of: "@"), at != address.startIndex else { return address }
        return String(address[..<at])
    }

    /// A sentence with its address pieces filled in: `template` has `{}` where each address goes, in order.
    public static func sentence(_ template: String, addresses: [String], revealed: Bool = false, blur: Bool) -> String {
        var out = ""
        var rest = Substring(template)
        var i = 0
        while let r = rest.range(of: "{}") {
            out += rest[..<r.lowerBound]
            out += i < addresses.count ? sentence(address: addresses[i], revealed: revealed, blur: blur) : "{}"
            rest = rest[r.upperBound...]
            i += 1
        }
        return out + rest
    }

    /// Whether a piece of text is something to hide: an address (it holds an @) or an account id (a UUID, or at least 8
    /// hexadecimal characters of one, with or without dashes). Callers decide what to pass through the forms above with it,
    /// so a title that is an id prefix ("1a2b3c4d") is hidden like an address and never drawn, spoken or put in a tooltip.
    public static func needsHiding(_ text: String) -> Bool {
        text.contains("@") || isAccountID(text)
    }

    /// An account id: a UUID, or its first characters (8 or more hexadecimal digits and dashes). Every hex-like text of that
    /// length counts, an all-letter id ("deadbeef") too: an id that is hidden only when it happens to hold a digit would give
    /// itself away; an ordinary word of eight or more letters a-f is rare enough to hide with them.
    public static func isAccountID(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        let hex = t.filter { $0 != "-" }
        return hex.count >= 8 && t.count <= 36 && t.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// An account id as text: never drawn, never spoken, never in a tooltip while the blur is on (the stand-in words), and
    /// itself only on the app's explicit word.
    public static func sentence(id: String, revealed: Bool = false, blur: Bool) -> String { sentence(address: id, revealed: revealed, blur: blur) }

    /// An address in running text while hidden: "hidden address", whatever the address (the name of the old first-letter
    /// mask, kept so callers read as before; it no longer holds the first letter, a length or the domain).
    public static func mask(_ address: String) -> String { hidden }
}
