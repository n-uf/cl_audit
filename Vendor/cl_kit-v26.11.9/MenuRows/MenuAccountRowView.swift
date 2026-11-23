// MenuRows · the row: one account in a menu bar menu, drawn by hand so a hidden address can be the blurred stand-in
// (AddressPrivacy) and still be told apart from its neighbours by its place, never by its text. Merged from cl_audit's
// AddressMenuRow (the tick in the margin, the words before and after the address, VoiceOver's "selected") and cl_quick's
// QCStandbyMenuRow (the reveal only with the pointer on the row, the quiet hint at the right while lit, the press that
// closes the menu first, the dimmed standby look with its hollow lamp, the columns that line up with the block above).
// It adds the compact usage line under the address (MenuUsageLine, from ProfileCore's display).
//
//   ✓ Sign Terminal in to abcdefghijkl@mnopqrst.com…        address line: the stand-in blurred at rest
//   ○ abcdefghijkl@mnopqrst.com · standby          Switch…  a dimmed standby row, lit: the hint at the right
//     5h 34% · Week 12%                                     usage line (or the app's note), smaller
//
// - Hidden (the setting on): the address is AddressPrivacy's one fixed stand-in, blurred, the same for every account, and
//   sharp only while the menu lights the row AND the pointer is on it, as the window says now (never a remembered
//   flag: a menu that closed or scrolled leaves nothing behind). Only the pointer on the row reveals it, resting or moving;
//   a keyboard highlight or type-ahead alone lights the row but never does. Its room is the stand-in's width whatever the
//   address, so nothing moves on a reveal and an address's length is never in the position of the words after it.
// - Its title (the menu's type-ahead) and its VoiceOver label hold the sentence form: "hidden address" in the address's
//   place, the same for every account; any of the app's words that names an address is "hidden address" too.
// - Compact: one line (two with the usage line), a native item's highlight, no stripe on any edge.

import AddressPrivacy
import AppKit
import ProfileCore

public final class MenuAccountRowView: NSView {
    /// What the row says.
    public let row: MenuAccountRow
    /// The tick's and VoiceOver's words, and the usage line's.
    public let words: MenuRowWords
    /// Where the mark and the address stand.
    public let columns: MenuRowColumns
    /// Runs on a click (after the menu has closed), on Return, and on VoiceOver's press. Never while disabled.
    public let pick: () -> Void
    /// The address's font, and the prefix's with it (default `font`, the menu's 13 pt; cl_quick 11.5 pt, its in-use line's).
    /// The stand-in, the room, the line's height and the width all follow it, so at one size every hidden address takes the
    /// same room.
    public let addressFont: NSFont
    /// For pictures: drawn as if the menu lit the row with the pointer on it (the address sharp).
    public var highlighted = false { didSet { needsDisplay = true } }
    /// A test override of the setting (nil: the app's, AddressPrivacy.shared); it reaches what is drawn, written and spoken,
    /// and the item's title follows it.
    public var blur: Bool? { didSet { refresh() } }

    // MARK: metrics

    public static let font = NSFont.menuFont(ofSize: 0)
    /// The usage line's, the note's, the tag's and the hint's font, a step smaller.
    public static let smallFont = NSFont.menuFont(ofSize: 11)
    /// The tick's font: a little smaller than the row's, so it sits in the margin with room before the address.
    public static let tickFont = NSFont.menuFont(ofSize: 11)
    public static let padX: CGFloat = 14
    /// Room between the tick and the address.
    public static let tickGap: CGFloat = 3
    /// Least room between the tag and the hint.
    public static let hintGap: CGFloat = 18
    /// The hollow lamp's size.
    public static let lampSize: CGFloat = 7
    /// A waiting row's text: fainter than a disabled row's.
    public static let waitingText = NSColor.quaternaryLabelColor
    /// The highlight: a native item's, inset from the menu's edges, rounded.
    public static let highlightInset: CGFloat = 5, highlightH: CGFloat = 22, highlightRadius: CGFloat = 4
    /// The address line at the standard font (`font`): as tall as the blurred stand-in's picture (the text and the blur's
    /// reach above and below), so the blur is never cut. A row's own is `lineH`, for its `addressFont`.
    public static let addressLineH: CGFloat = lineH(font)
    /// Where the second line (usage or note) starts at the standard font: right under the address's text (the blur's reach
    /// below it is only a faint edge, so the line may start there). A row's own is `secondTop`.
    public static let secondLineTop: CGFloat = addressLineH - AddressInk.blurPad
    static func lineH(_ f: NSFont) -> CGFloat { textH(f) + 2 * AddressInk.blurPad }
    /// The second line's height, with a little room below it.
    public static let secondLineH: CGFloat = textH(smallFont) + 3

    static func textH(_ f: NSFont) -> CGFloat { ceil(("Ag" as NSString).size(withAttributes: [.font: f]).height) }
    static func w(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) }

    private let ink: AddressInk
    private var menuEnd: NSObjectProtocol?
    /// This row's address line, for its `addressFont`.
    public var lineH: CGFloat { Self.lineH(addressFont) }
    /// Where this row's second line starts.
    public var secondTop: CGFloat { lineH - AddressInk.blurPad }

    // MARK: making one

    public init(row: MenuAccountRow, words: MenuRowWords = .standard, columns: MenuRowColumns = .standard,
                addressFont: NSFont = MenuAccountRowView.font, pick: @escaping () -> Void) {
        self.row = row; self.words = words; self.columns = columns; self.addressFont = addressFont; self.pick = pick
        ink = AddressInk(font: addressFont)
        super.init(frame: .zero)
        frame = NSRect(x: 0, y: 0, width: naturalWidth, height: height)
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityEnabled(row.enabled)
        setAccessibilitySelected(row.inUse)
        // the row's menu closed: nothing sharp left behind (a menu item's view has a window only while the menu shows)
        menuEnd = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) {
            [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let menu = note.object as? NSMenu, menu === self.enclosingMenuItem?.menu else { return }
                self.forgetPointer()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }
    deinit { if let menuEnd { NotificationCenter.default.removeObserver(menuEnd) } }

    /// The menu item for a row: the row as its view, the account in use ticked (the item's state says it too), a title and
    /// an action of its own for the menu's type-ahead and Return. A disabled row has no action.
    /// The caller may put its own `representedObject` or `tag` on it; the row keeps its handler in `target`.
    public static func item(_ row: MenuAccountRow, words: MenuRowWords = .standard, columns: MenuRowColumns = .standard,
                            addressFont: NSFont = MenuAccountRowView.font, blur: Bool? = nil,
                            pick: @escaping () -> Void) -> NSMenuItem {
        let view = MenuAccountRowView(row: row, words: words, columns: columns, addressFont: addressFont, pick: pick)
        let item = NSMenuItem(title: "", action: row.enabled ? #selector(MenuAccountRowView.fire) : nil, keyEquivalent: "")
        item.target = view                       // (the item keeps its view, so its target lives as long as it does)
        item.isEnabled = row.enabled
        item.state = row.inUse ? .on : .off
        item.view = view
        view.blur = blur                         // (the size, by the setting)
        item.title = view.title
        return item
    }

    // MARK: what it says

    /// Whether the address is hidden now: the override, or the app's setting.
    public var blurred: Bool { blur ?? AddressPrivacy.shared.blur }
    /// The app's words as the row draws and speaks them: as given, but while addresses are hidden any word in them that is
    /// an address or an account id (`namesAccount`) becomes "hidden address" ("Switch to hidden address"). Words are split
    /// at any white space (a no-break space too), and the spaces between them are kept as they were. The app's rule is to
    /// put no address in them; this only makes sure.
    public func safe(_ s: String) -> String {
        guard blurred else { return s }
        let edges = CharacterSet(charactersIn: "()[]{}<>,;:!?\"'«»“”‘’…·")
        func hide(_ w: String) -> String {
            let core = w.trimmingCharacters(in: edges)
            guard !core.isEmpty, Self.namesAccount(core), let r = w.range(of: core) else { return w }
            return w.replacingCharacters(in: r, with: AddressText.hidden)
        }
        var out = "", word = ""
        for ch in s {
            if ch.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                out += hide(word); out.append(ch); word = ""
            } else {
                word.append(ch)
            }
        }
        return out + hide(word)
    }

    /// Whether one of the app's words names an account: an address, or an account id (AddressText.needsHiding), except a
    /// date-shaped word ("2026-11-20"): digits split by dashes count as an id only in a UUID's shape (8-4-4-4-12). A word
    /// with a hex letter, or a bare run of 8 or more digits, still counts, so an id's first characters never show.
    static func namesAccount(_ word: String) -> Bool {
        guard AddressText.needsHiding(word) else { return false }
        if word.contains("@") || word.contains(where: { $0.isLetter }) || !word.contains("-") { return true }
        return word.split(separator: "-", omittingEmptySubsequences: false).map(\.count) == [8, 4, 4, 4, 12]
    }
    /// The item's title: the prefix, the address in its sentence form ("hidden address" while hidden) and the tag; a row
    /// with no address (`MenuAccountRow.add`) only its words.
    public var title: String {
        safe(row.prefix) + (row.isAdd ? "" : AddressText.sentence(address: row.address, blur: blurred)) + safe(row.tag)
    }
    /// The second line's words: the usage line's, else the app's note, else nil.
    public var secondLine: String? { row.usage?.words ?? row.note.map(safe) }
    /// The hint, as drawn and as VoiceOver's help.
    public var hint: String? { row.hint.map(safe) }
    /// What VoiceOver reads, worked out on each call (so a change of the setting reaches it): the title, then the second
    /// line. Nothing of a hidden address, whatever the pointer does.
    public override func accessibilityLabel() -> String? { [title, secondLine].compactMap { $0 }.joined(separator: ", ") }
    /// The account in use says so, as a native ticked item does.
    /// A waiting row says so ("waiting"), with "selected" first when it is the account in use.
    public override func accessibilityValue() -> Any? {
        let said = [row.inUse ? words.selected : nil, row.waiting ? words.waiting : nil].compactMap { $0 }
        return said.isEmpty ? nil : said.joined(separator: ", ")
    }
    /// What a press does, in the app's word ("Switch…").
    public override func accessibilityHelp() -> String? { hint }

    /// After the setting changed: the item's title, the size, the picture. A menu builds its rows each time it opens; a row
    /// kept open across a change of the app's setting needs this call.
    public func refresh() {
        enclosingMenuItem?.title = title
        frame.size = NSSize(width: max(frame.width, naturalWidth), height: height)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    // MARK: size

    /// The room of the address: the stand-in's at the row's font while hidden, whatever the address (its own width while
    /// shown); none for a row with no address.
    public var room: CGFloat { row.isAdd ? 0 : ink.room(for: row.address, blur: blurred) }
    /// Where the address starts: after the prefix (in the address's font).
    public var addressX: CGFloat { columns.addressX + Self.w(safe(row.prefix), addressFont) }
    /// One line, or two with a usage line or a note.
    public var height: CGFloat { secondLine == nil ? lineH : secondTop + Self.secondLineH }
    /// The least width that shows it all: the address line (the prefix, the address's room, the tag, the hint) or the
    /// second line.
    public var naturalWidth: CGFloat {
        let line1 = addressX + room + Self.w(safe(row.tag), Self.smallFont) + (hint.map { Self.hintGap + Self.w($0, Self.smallFont) } ?? 0) + Self.padX
        let line2 = secondLine.map { columns.addressX + Self.w($0, Self.smallFont) + Self.padX } ?? 0
        return max(line1, line2)
    }
    public override var intrinsicContentSize: NSSize { NSSize(width: naturalWidth, height: height) }
    public override var isFlipped: Bool { true }

    // MARK: lit and sharp

    /// Lit by the menu (the pointer or the arrow keys are on it, or drawn so for a picture); a disabled row never is.
    public var lit: Bool { row.enabled && (highlighted || (menuLit ?? (enclosingMenuItem?.isHighlighted == true))) }
    /// A check's stand-in for the menu's highlight (nil: the item's own): lit as by the arrow keys. Set with
    /// `standInMenuLit(_:)`.
    public internal(set) var menuLit: Bool? { didSet { needsDisplay = true } }
    /// A check stands in for the menu's highlight, as the arrow keys give it (true: lit, false: not, nil: the item's own
    /// again), so an app can check that arrowing away and back reveals nothing. Dropped, like the pointer's stand-in, when
    /// the row leaves its window or its menu closes.
    public func standInMenuLit(_ on: Bool?) { menuLit = on }
    /// The pointer is on the row: asked of the window each time (never remembered, so a menu that closed or scrolled under
    /// the pointer leaves no reveal behind), or a check's stand-in.
    public var pointerOn: Bool {
        if let pointerStandIn { return pointerStandIn }
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    /// A check's stand-in for the mouse (nil: the real pointer). Dropped when the row leaves its window or its menu closes.
    public private(set) var pointerStandIn: Bool?
    /// The address is drawn readable: lit with the pointer on it (or lit for a picture), or addresses aren't hidden.
    public var sharp: Bool { (lit && (highlighted || pointerOn)) || !blurred }
    /// The address text drawn now: its own while sharp, else the stand-in (never any part of the address).
    public var drawnAddress: String { row.isAdd ? "" : AddressText.drawn(address: row.address, revealed: sharp, blur: true) }

    /// A check stands in for the mouse (true: on the row, false: off it, nil: the real pointer again).
    public func pointer(_ on: Bool?) { pointerStandIn = on; needsDisplay = true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    // (the pointer is asked of the window when drawing: entering and leaving only redraw)
    public override func mouseEntered(with e: NSEvent) { needsDisplay = true }
    public override func mouseExited(with e: NSEvent) { needsDisplay = true }
    public override func mouseUp(with e: NSEvent) {
        if bounds.contains(convert(e.locationInWindow, from: nil)) { press() }
    }

    /// Leaving its window (the menu closed): forget any stand-in for the pointer.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { forgetPointer() }
    }
    /// The menu closed or the row left its window: no stand-in for the pointer, nothing sharp left behind.
    func forgetPointer() { pointerStandIn = nil; menuLit = nil; needsDisplay = true }

    // MARK: acting

    /// A click on the row: closes the menu, then runs `pick` once its tracking has ended (in the default run-loop mode,
    /// not the menu's, where a window or a question would not take the keyboard). Nothing while disabled.
    public func press() {
        guard row.enabled else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        perform(#selector(runPick), with: nil, afterDelay: 0, inModes: [.default])
    }
    @objc private func runPick() { pick() }
    /// Return on the lit row (the item's action).
    @objc public func fire() { if row.enabled { pick() } }
    /// VoiceOver's press does what a click does.
    public override func accessibilityPerformPress() -> Bool {
        guard row.enabled else { return false }
        press()
        return true
    }

    // MARK: drawing

    /// The colour of a usage level (ProfileCore.Level, the one colour rule): the menu's own greens and reds.
    public static func color(_ level: Level) -> NSColor {
        switch level {
        case .none: return .secondaryLabelColor
        case .green: return .systemGreen
        case .amber: return .systemOrange
        case .red: return .systemRed
        case .crimson: return NSColor(srgbRed: 0.86, green: 0.15, blue: 0.24, alpha: 1)
        }
    }

    public override func draw(_ dirty: NSRect) {
        let on = lit
        if on {
            NSColor.selectedContentBackgroundColor.setFill()
            let h = secondLine == nil ? Self.highlightH : bounds.height - 2
            NSBezierPath(roundedRect: NSRect(x: Self.highlightInset, y: bounds.midY - h / 2, width: bounds.width - 2 * Self.highlightInset,
                                             height: h), xRadius: Self.highlightRadius, yRadius: Self.highlightRadius).fill()
        }
        let lightText = NSColor.selectedMenuItemTextColor
        // waiting: fainter than disabled (cl_quick's row while something is under way)
        let text: NSColor = on ? lightText : row.waiting ? Self.waitingText : !row.enabled ? .disabledControlTextColor
            : row.dimmed ? .tertiaryLabelColor : .labelColor
        let quiet: NSColor = on ? lightText.withAlphaComponent(0.8) : row.waiting ? Self.waitingText : !row.enabled ? .disabledControlTextColor
            : row.dimmed ? .tertiaryLabelColor : .secondaryLabelColor
        let mid = lineH / 2, h = ink.lineHeight, hs = Self.textH(Self.smallFont)
        func put(_ s: String, _ f: NSFont, _ c: NSColor, x: CGFloat, y: CGFloat) {
            (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: f, .foregroundColor: c])
        }
        // the leading column: the tick of the account in use just before the address, else the row's mark
        if row.inUse {
            let tw = Self.w(words.tick, Self.tickFont)
            // centred on its own font's line, whatever the address's size
            put(words.tick, Self.tickFont, text, x: max(1, columns.addressX - tw - Self.tickGap), y: mid - Self.textH(Self.tickFont) / 2)
        } else if row.marker == .hollowLamp {
            let d = Self.lampSize, r = NSRect(x: columns.markerX, y: mid - d / 2, width: d, height: d).insetBy(dx: 0.5, dy: 0.5)
            text.setStroke()
            let p = NSBezierPath(ovalIn: r); p.lineWidth = 1; p.stroke()
        } else if row.marker == .plus {
            put("+", addressFont, text, x: columns.markerX, y: mid - h / 2)
        }
        // the prefix, the address (sharp, or the stand-in blurred), the tag after its room, the hint at the right while lit
        let prefix = safe(row.prefix)
        if !prefix.isEmpty { put(prefix, addressFont, text, x: columns.addressX, y: mid - h / 2) }
        if !row.isAdd { ink.draw(address: row.address, readable: sharp, color: text, x: addressX, midY: mid, blur: blurred) }
        let tag = safe(row.tag)
        if !tag.isEmpty { put(tag, Self.smallFont, quiet, x: addressX + room, y: mid - hs / 2) }
        if on, let hint {
            put(hint, Self.smallFont, quiet, x: bounds.maxX - Self.padX - Self.w(hint, Self.smallFont), y: mid - hs / 2)
        }
        // the second line: the usage line's parts in their levels' colours (grey when old), its full limit, or the note
        guard secondLine != nil else { return }
        let y = secondTop, f = Self.smallFont, x0 = columns.addressX
        if let u = row.usage {
            if let full = u.full {
                put(full, f, on ? text : u.grey || row.dimmed ? .tertiaryLabelColor : Self.color(.crimson), x: x0, y: y)
                return
            }
            var x = x0
            for (i, p) in u.parts.enumerated() {
                if i > 0 { put(" · ", f, quiet, x: x, y: y); x += Self.w(" · ", f) }
                let label = p.label + " "
                put(label, f, quiet, x: x, y: y); x += Self.w(label, f)
                let pct = "\(p.percent)%"
                put(pct, f, on ? text : u.grey || row.dimmed ? .tertiaryLabelColor : Self.color(p.level), x: x, y: y); x += Self.w(pct, f)
            }
        } else if let note = row.note {
            put(safe(note), f, quiet, x: x0, y: y)
        }
    }

    // (the blurred stand-in is made once per colour by `ink`, and made again if the appearance changes)
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ink.reset()
        needsDisplay = true
    }
}
