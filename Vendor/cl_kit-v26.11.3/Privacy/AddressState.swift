// The app's blur setting as an observable value, and the hover gate. No SwiftUI views here (AddressViews.swift has them);
// AppKit only for the notifications that end a hover.

import AppKit
import Combine

/// Where an app keeps its "Blur addresses" setting, if it wants the module to write it back (optional: an app can just call
/// `apply(blur:)` whenever its setting changes and keep the storage entirely to itself; AddressDefaultsStore is one
/// ready-made store, for an app that keeps it in a prefs domain). The module never reads a UserDefaults key or a file of
/// its own: two apps never share the setting.
public protocol AddressBlurStore: AnyObject {
    var blurAddresses: Bool { get set }
}

/// The app's "Blur addresses" setting (on unless turned off), and the count of hovers cut short. On: an address is its
/// stand-in, blurred, until it is revealed, and as words it is "hidden address". Off: it is drawn in full, and the words hold
/// it in full. Views read it as they are drawn, so a change reaches them at once (menus: the next time they open).
public final class AddressPrivacy: ObservableObject {
    /// The app's one setting.
    public static let shared = AddressPrivacy()

    private var observers: [NSObjectProtocol] = []

    public init(blur: Bool = true) {
        self.blur = blur
        // A hover gets no exit while a menu is tracking, when the app loses focus or the user switches to another app, when
        // the window loses focus with the pointer where it was, or when it closes: all of these end every reveal that
        // hover made (a peek, being the app's own, is left alone).
        let nc = NotificationCenter.default
        func end(_ name: Notification.Name) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.endHover() })
        }
        end(NSApplication.didResignActiveNotification)
        end(NSApplication.didHideNotification)
        end(NSWindow.didResignKeyNotification)
        end(NSWindow.didResignMainNotification)
        end(NSWindow.willCloseNotification)
        end(NSWindow.didMiniaturizeNotification)
        end(NSMenu.didBeginTrackingNotification)
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Whether addresses are blurred.
    @Published public private(set) var blur: Bool

    /// Takes the setting as the app has it (as it starts, and whenever its setting changes). Nothing is written.
    public func apply(blur on: Bool) { if blur != on { blur = on } }

    /// An optional store: set it and `blur` is read from it now; `setBlur` then writes it back.
    public var store: AddressBlurStore? {
        didSet { if let s = store { apply(blur: s.blurAddresses) } }
    }
    /// The user changed the setting here: taken, and written to the store if there is one.
    public func setBlur(_ on: Bool) { apply(blur: on); store?.blurAddresses = on }

    /// Counts the times a pointer's hover was cut short without a mouse-exit: a panel ordered out under the pointer (it
    /// gets no exit), a modal alert that took the pointer, a window covered, a menu that opened, the app deactivated, a
    /// window that closed. Views that reveal an address on hover drop it when this changes (AddressHoverGate). The module
    /// also counts one for each of those it can see (see `init`); an app calls `endHover()` for any other.
    @Published public private(set) var hoverEnded = 0
    public func endHover() { hoverEnded += 1 }

    // MARK: the plain API on the shared setting

    public static var standIn: String { AddressText.standIn }
    /// An address in running text now: "hidden address" while blurring, else in full.
    public static func words(_ address: String) -> String { AddressText.sentence(address: address, blur: shared.blur) }
    /// The text to draw for an address now: its own when `revealed` (or the blur is off), else the stand-in.
    public static func drawn(address: String, revealed: Bool = false) -> String {
        AddressText.drawn(address: address, revealed: revealed, blur: shared.blur)
    }
    /// The short name for a compact row now.
    public static func short(address: String, revealed: Bool = false) -> String {
        AddressText.short(address: address, revealed: revealed, blur: shared.blur)
    }
}

/// Whether the pointer is on something that reveals an address, or something else asks for it (`peek`: a press-to-show
/// key, say). SwiftUI's onHover reports only enters and exits, and a window hidden or covered under the pointer, a menu
/// tracking, a modal alert, a lost focus, send no exit: so the hover also ends when `AddressPrivacy.hoverEnded` changes, and
/// is not taken up again until the pointer enters anew. A `peek` is the app's own, so a cut-short hover leaves it alone.
public struct AddressHoverGate: Equatable {
    private var pointerOn = false
    private var seen: Int
    /// An outside reveal (a peek); the app sets and clears it.
    public var peek = false
    public init(seen: Int = AddressPrivacy.shared.hoverEnded) { self.seen = seen }
    /// The address is to be read: the pointer is on it, or a peek is on. (As of the last `sync`: a view that already knows
    /// the counter asks `isOn(at:)`, which is right in the same update as the hover's end.)
    public var on: Bool { pointerOn || peek }
    /// The same, for the counter's value now: a hover that ended since the gate last saw the counter does not count, so a
    /// view that computes it in its body is never one update late.
    public func isOn(at counter: Int) -> Bool { peek || (pointerOn && seen == counter) }
    /// The pointer entered (true) or left (false).
    /// (An entering pointer is a new hover: it takes the counter as it is now, so an earlier cut-short one doesn't end it.)
    public mutating func pointer(_ inside: Bool, counter: Int = AddressPrivacy.shared.hoverEnded) {
        pointerOn = inside
        if inside { seen = counter }
    }
    /// The counter's value now: a change ends the hover.
    public mutating func sync(_ ended: Int) { if ended != seen { seen = ended; pointerOn = false } }
    /// The view went away, or its text changed: the hover ends there and then.
    public mutating func reset() { pointerOn = false }
}
