// AddressMenuRow: a menu row that holds an account address ("Switch to ultra-3…", a standby account in the Switch account
// submenu), drawn by hand so the rows of several hidden accounts can still be told apart on screen while nothing of any
// address is in a title, a label or a sentence.
//
// While the address is hidden the row draws AddressPrivacy's one fixed stand-in, blurred (AddressInk), the same for every
// account, and the real address sharp only while the menu highlights the row (the pointer or the arrow keys are on it) or the
// "Show emails" setting is on. The room it gives the address is the stand-in's width and nothing else (a longer address is
// cut while sharp), so the width of the row, and where its suffix is, never depend on the address. Its item's title (the
// menu's type-ahead) and its accessibility label are the sentence form, "hidden address" in the address's place, for every
// account: distinct words for hidden rows would tell the accounts apart again.
//
// The model is cl_quick's standby row (QCStandbyMenuRow); the module draws, this file lays the row out.

import AddressPrivacy
import AppKit

final class AddressMenuRow: NSView {
    let prefix: String
    /// The whole address, for drawing only: every word of the row (title, accessibility label) holds it as the sentence form.
    let address: String
    let suffix: String
    let enabled: Bool
    let pick: () -> Void
    /// For pictures: drawn as if the menu highlighted the row.
    var highlighted = false
    /// A test override of the setting (nil: the app's, AddressPrivacy.shared); it reaches what is drawn and what is spoken.
    var blur: Bool?

    static let font = NSFont.menuFont(ofSize: 0)
    static let padX: CGFloat = 14
    static let highlightH: CGFloat = 22
    /// As tall as the blurred address's picture (the text's height and the blur's reach above and below), so the blur is never
    /// cut; the highlight is a native item's height, centred.
    static let height: CGFloat = ceil(("Ag" as NSString).size(withAttributes: [.font: font]).height) + 2 * AddressInk.blurPad

    /// The item: the row as its view, and a title and action of its own for the menu's type-ahead and Return (a click on the
    /// row closes the menu, then runs `pick`; Return runs it too). `enabled` false: dimmed, never lit, does nothing.
    /// The caller may put its own `representedObject` on it: the row keeps its own handler in `target`.
    static func item(prefix: String = "", address: String, suffix: String = "", enabled: Bool = true,
                     pick: @escaping () -> Void) -> NSMenuItem {
        let row = AddressMenuRow(prefix: prefix, address: address, suffix: suffix, enabled: enabled, pick: pick)
        let item = NSMenuItem(title: row.title, action: #selector(AddressMenuRow.fire), keyEquivalent: "")
        item.target = row                       // (the item keeps its view, so its target lives as long as it does)
        item.isEnabled = enabled
        if !enabled { item.action = nil }       // a dimmed row has nothing to run
        item.view = row
        return item
    }

    /// The words of the row for a setting: the sentence form (nothing of the address while hidden).
    static func words(prefix: String, address: String, suffix: String, blur: Bool) -> String {
        prefix + AddressText.sentence(address: address, blur: blur) + suffix
    }

    init(prefix: String, address: String, suffix: String, enabled: Bool, pick: @escaping () -> Void) {
        self.prefix = prefix; self.address = address; self.suffix = suffix; self.enabled = enabled; self.pick = pick
        super.init(frame: .zero)
        frame = NSRect(x: 0, y: 0, width: naturalWidth, height: Self.height)
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityEnabled(enabled)
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    /// Whether the address is blurred now: the override, or the app's setting.
    var blurred: Bool { blur ?? AddressPrivacy.shared.blur }
    /// The item's title: the sentence form.
    var title: String { Self.words(prefix: prefix, address: address, suffix: suffix, blur: blurred) }
    /// What VoiceOver reads, worked out on each call (so a change of the setting reaches it): the same words for every account.
    override func accessibilityLabel() -> String? { title }

    private let ink = AddressInk(font: AddressMenuRow.font)
    private func w(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: Self.font]).width) }
    /// The room of the address: the stand-in's while it is hidden, whatever the address (its own width while shown).
    var room: CGFloat { ink.room(for: address, blur: blurred) }
    /// The least width that shows it all.
    var naturalWidth: CGFloat { Self.padX + w(prefix) + room + w(suffix) + Self.padX }
    override var intrinsicContentSize: NSSize { NSSize(width: naturalWidth, height: Self.height) }

    /// Whether the menu lights the row (the address is sharp then); a dimmed row never is.
    var lit: Bool { enabled && (highlighted || enclosingMenuItem?.isHighlighted == true) }
    /// The address is drawn sharp: the row is lit, or addresses are not hidden.
    var sharp: Bool { lit || !blurred }
    /// The text of the address drawn now: its own while sharp, else the stand-in (never any part of the address).
    var drawnAddress: String { AddressText.drawn(address: address, revealed: sharp, blur: true) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { needsDisplay = true }
    override func mouseExited(with e: NSEvent) { needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        if bounds.contains(convert(e.locationInWindow, from: nil)) { press() }
    }

    /// A click on the row: closes the menu, then runs `pick` once it has closed (not inside the menu's tracking loop, where a
    /// window or a question would not take the keyboard). Nothing while dimmed.
    func press() {
        guard enabled else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        let run = pick
        DispatchQueue.main.async { run() }
    }
    /// Return on the highlighted row (the item's action).
    @objc func fire() { if enabled { pick() } }
    /// VoiceOver's press does the same as a click.
    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        press()
        return true
    }

    override func draw(_ dirty: NSRect) {
        let on = lit
        if on {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 5, y: bounds.midY - Self.highlightH / 2, width: bounds.width - 10, height: Self.highlightH),
                         xRadius: 4, yRadius: 4).fill()
        }
        let color: NSColor = on ? .selectedMenuItemTextColor : enabled ? .controlTextColor : .disabledControlTextColor
        let h = ink.lineHeight, mid = bounds.midY
        func text(_ s: String, x: CGFloat) {
            (s as NSString).draw(at: NSPoint(x: x, y: mid - h / 2), withAttributes: [.font: Self.font, .foregroundColor: color])
        }
        var x = Self.padX
        if !prefix.isEmpty { text(prefix, x: x); x += w(prefix) }
        ink.draw(address: address, readable: sharp, color: color, x: x, midY: mid, blur: blurred)
        x += room
        if !suffix.isEmpty { text(suffix, x: x) }
    }

    // (the blurred stand-in is made once per colour by `ink`, and made again if the appearance changes)
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ink.reset()
        needsDisplay = true
    }
}
