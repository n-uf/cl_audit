// AddressLabel: an address on its own line in an alert's accessory view (an NSAlert's text can't blur): the stand-in
// blurred, the address sharp while the pointer is on it.
//
// Its frame is the stand-in's width, whatever the address and whatever the setting (a longer address is truncated while
// revealed). Its accessibility label is computed on each call ("hidden address" while blurred), and it follows a change of
// the app's setting (unless it was given a test override). The reveal ends when the pointer leaves, the alert closes, its
// window loses focus, the app is deactivated or hidden, a menu starts tracking; and once ended it stays ended until the
// pointer has left the label (the poll must not take it up again a moment later).

import AppKit
import Combine

public final class AddressLabel: NSView {
    public let address: String
    /// A test override of the setting (nil: the app's, AddressPrivacy.shared).
    public let blur: Bool?
    /// The pointer is on it: drawn readable.
    public private(set) var revealed = false
    /// A reveal that was cut off (focus lost, menu opened) stays ended until the pointer has left the label.
    public private(set) var suppressed = false

    public static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private let ink = AddressInk(font: AddressLabel.font)
    private var observers: [NSObjectProtocol] = []
    private var setting: AnyCancellable?
    /// The frame holds the blur's reach on every side.
    public static var pad: CGFloat { AddressInk.blurPad }

    /// What the poll reads (swappable, for the checks: a stand-in for the screen, the key window, the app's state, the
    /// modal session and the pointer).
    public struct Surroundings {
        public var shown: (NSWindow) -> Bool = { $0.isVisible }
        public var key: (NSWindow) -> Bool = { $0.isKeyWindow }
        public var appActive: () -> Bool = { NSApp.isActive }
        public var modalWindow: () -> NSWindow? = { NSApp.modalWindow }
        public var pointer: (NSWindow) -> NSPoint? = { $0.mouseLocationOutsideOfEventStream }
        public init() {}
    }
    public var surroundings = Surroundings()

    public init(address: String, blur: Bool? = nil) {
        self.address = address
        self.blur = blur
        let ink = AddressInk(font: Self.font)
        super.init(frame: NSRect(x: 0, y: 0, width: ink.room + 2 * Self.pad, height: ink.lineHeight + 2 * Self.pad))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        // a live label follows the app's setting: drawn again at once (its label is computed on each call)
        if blur == nil { setting = AddressPrivacy.shared.$blur.sink { [weak self] _ in self?.needsDisplay = true } }
    }
    public required init?(coder: NSCoder) { fatalError("not from a nib") }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); poll?.invalidate() }

    public override var isFlipped: Bool { true }

    /// "hidden address" while blurred, the address when the blur is off (computed on each call, so a setting change reaches it).
    public override func accessibilityLabel() -> String? { AddressText.sentence(address: address, blur: blurred) }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    public override func mouseEntered(with e: NSEvent) { suppressed = false; reveal(true) }
    public override func mouseExited(with e: NSEvent) { suppressed = false; reveal(false) }
    public func reveal(_ on: Bool) { guard on != revealed else { return }; revealed = on; needsDisplay = true }

    /// The reveal is cut off (focus lost, a menu opened, the alert closing): ended, and kept ended until the pointer leaves.
    public func cutOff() {
        if revealed { suppressed = true }
        reveal(false)
    }

    // A modal alert (NSAlert.runModal) gets no enter and exit from the tracking area above, so while the label is in a
    // window the pointer's place is also read every 50 ms, in every run loop mode (the modal one included): the address is
    // readable exactly while the pointer is on the label, its window is on screen and key, and the app is active. The poll
    // stops when the label leaves its window, when its window closes, or when another window takes over the modal session
    // (a hidden or deactivated app only pauses it).
    private var poll: Timer?
    /// Whether the poll is running.
    public var isPolling: Bool { poll?.isValid == true }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopPolling()
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        guard let w = window else { cutOff(); return }
        w.acceptsMouseMovedEvents = true
        let nc = NotificationCenter.default
        for (name, object) in [(NSWindow.didResignKeyNotification, w as AnyObject?), (NSApplication.didResignActiveNotification, nil),
                               (NSApplication.didHideNotification, nil), (NSMenu.didBeginTrackingNotification, nil)] {
            observers.append(nc.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.cutOff() })
        }
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.cutOff(); self?.stopPolling()
        })
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }
    private func stopPolling() { poll?.invalidate(); poll = nil }

    /// One reading of the pointer (the timer's, and the checks').
    public func tick() {
        guard let w = window else { stopPolling(); return }
        if let m = surroundings.modalWindow(), m !== w { stopPolling(); cutOff(); return }        // another modal session took over
        let there = surroundings.shown(w) && surroundings.key(w) && surroundings.appActive()
        follow(inWindow: there ? surroundings.pointer(w) : nil)
    }

    /// The pointer at a point of the window (nil: it is nowhere): the address is readable while it is on the label, unless
    /// the reveal was cut off and the pointer has not left since.
    public func follow(inWindow p: NSPoint?) {
        let inside = p.map { bounds.contains(convert($0, from: nil)) } ?? false
        if suppressed {
            if !inside { suppressed = false }
            reveal(false)
            return
        }
        reveal(inside)
    }

    /// Whether the address is blurred now: the override, or the app's setting.
    public var blurred: Bool { blur ?? AddressPrivacy.shared.blur }
    /// Drawn readable: the pointer is on it, or addresses are not blurred.
    public var sharp: Bool { revealed || !blurred }
    /// The text drawn now: the address while readable, else the stand-in (never any part of the address).
    public var drawnText: String { AddressText.drawn(address: address, revealed: sharp, blur: true) }

    public override func draw(_ dirty: NSRect) {
        // (the room is the stand-in's whatever the setting: a longer address is cut, as it is while revealed)
        ink.draw(address: address, readable: sharp, color: .labelColor, x: Self.pad, midY: bounds.midY)
    }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ink.reset()
        needsDisplay = true
    }
}
