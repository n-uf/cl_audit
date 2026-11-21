// The AddressPrivacy module's own checks (Checks/run.sh addressprivacy): only the module (Privacy/), no app code, no window
// shown, no mouse, no Keychain, nothing written outside Checks/.work (the prefs checks use a dictionary, never a real
// domain). Sample addresses only (example.com and the like, reserved names).
//
// What they prove, for every way an app can show an address: with the blur on, what is drawn, put in a sentence or spoken
// is the fixed stand-in or "hidden address" and never any part of the real address (asserted on the string each piece
// draws, and, for the views, on the pixels too: they draw the same for two addresses and are not blank); with the blur off,
// or on an explicit reveal (the pointer, a peek), it is the real address; the room is the stand-in's alone, so the address's
// length is never in a neighbour's position; a reveal ends reliably; and the setting is a value the app passes in.

import AddressPrivacy
import AppKit
import SwiftUI

var failed = 0, passed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failed += 1; print("FAIL \(name) \(detail())") }
}
func spin(_ s: TimeInterval = 0.2) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

let samples = ["zed.sample@example.com", "kim@example.org", "q@e.test", "alexandra.long.name@sample-domain.example.net", "ultra-1@example.com"]
let one = samples[0], two = samples[1], long = samples[3]
let uuid = "1A2B3C4D-5E6F-4A8B-9C0D-1E2F3A4B5C6D"

/// The pieces of an address a candidate match could use: the local part, the domain, each word of three letters or more
/// (".com" is the stand-in's own ending, so "com" is no piece), and its first letter before the @.
func parts(_ a: String) -> [String] {
    let at = a.firstIndex(of: "@")!
    var out = [String(a[..<at]), String(a[a.index(after: at)...])]
    out += a.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    return out.filter { $0.count >= 3 && $0 != "com" }          // (one or two letters are in any text)
}
/// Whether a string holds any part of the address: a piece, its first letter next to an @ or a dot, a bullet mask.
func leaks(_ s: String, of a: String) -> Bool {
    parts(a).contains { s.contains($0) } || s.contains(String(a.prefix(1)) + "@") || s.contains("•")
}

// ── the plain forms (Foundation only): drawn, sentence, short ───────────────────────────────────────────────
check("stand-in: one fixed string, address-shaped (letters, an @, .com)", AddressText.standIn == "abcdefghijkl@mnopqrst.com"
      && AddressText.standIn.contains("@") && AddressText.standIn.hasSuffix(".com"))
check("drawn: the stand-in for every address with the blur on, nothing revealed",
      Set(samples.map { AddressText.drawn(address: $0, revealed: false, blur: true) }) == [AddressText.standIn])
check("drawn: never any part of any sample address", samples.allSatisfy { !leaks(AddressText.drawn(address: $0, blur: true), of: $0) })
check("drawn: the same length for an 8- and a 45-letter address (no length in it)",
      AddressText.drawn(address: "q@e.test", blur: true).count == AddressText.drawn(address: long, blur: true).count)
check("drawn: revealed it is the address; with the blur off too", samples.allSatisfy {
    AddressText.drawn(address: $0, revealed: true, blur: true) == $0 && AddressText.drawn(address: $0, blur: false) == $0 })
check("drawn: the default is no reveal", AddressText.drawn(address: one, blur: true) == AddressText.standIn)
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
let attributed = AddressText.attributed(address: one, blur: true, attributes: attrs)
check("attributed: the stand-in with the caller's attributes, never the address",
      attributed.string == AddressText.standIn && !leaks(attributed.string, of: one) && (attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) == (attrs[.font] as? NSFont))
check("attributed: revealed or blur off, the address",
      AddressText.attributed(address: one, revealed: true, blur: true).string == one && AddressText.attributed(address: one, blur: false).string == one)

check("sentence: 'hidden address' for every address while the blur is on, holding nothing of it (no first letter, no length, no domain, no dots)",
      samples.allSatisfy { AddressText.sentence(address: $0, blur: true) == "hidden address" && !leaks(AddressText.sentence(address: $0, blur: true), of: $0) }
      && AddressText.hidden == "hidden address")
check("sentence: the address itself with the blur off, or on an explicit reveal",
      samples.allSatisfy { AddressText.sentence(address: $0, blur: false) == $0 && AddressText.sentence(address: $0, revealed: true, blur: true) == $0 })
check("sentence: words(_:blur:) and the old maskEmail say the same, the same for every address",
      samples.allSatisfy { AddressText.words($0, blur: true) == "hidden address" && AddressText.mask($0) == "hidden address" })
check("sentence: a template's {} places are filled in order, hidden, never with the address",
      AddressText.sentence("Signed in as {}, not {}.", addresses: [one, two], blur: true) == "Signed in as hidden address, not hidden address."
      && AddressText.sentence("Signed in as {}, not {}.", addresses: [one, two], blur: false) == "Signed in as \(one), not \(two)."
      && AddressText.sentence("Forget {}?", addresses: [one], blur: true) == "Forget hidden address?"
      && AddressText.sentence("no pieces", addresses: [one], blur: true) == "no pieces")
check("short: 'hidden address' while hidden (no first letter or dots), the part before the @ when shown",
      samples.allSatisfy { AddressText.short(address: $0, blur: true) == "hidden address" && !leaks(AddressText.short(address: $0, blur: true), of: $0) }
      && AddressText.short(address: one, blur: false) == "zed.sample" && AddressText.short(address: one, revealed: true, blur: true) == "zed.sample"
      && AddressText.short(address: "not an address", blur: false) == "not an address")
check("short: a row built from it holds nothing of the address ('Switch to hidden address')",
      !leaks("Switch to " + AddressText.short(address: one, blur: true), of: one) && "Switch to \(AddressText.short(address: two, blur: true))" == "Switch to hidden address")

// account ids count as hidden
check("ids: a UUID or its first characters are something to hide, like an address; ordinary words are not",
      AddressText.needsHiding(uuid) && AddressText.needsHiding("1a2b3c4d") && AddressText.needsHiding("1a2b3c4d-5e6f") && AddressText.needsHiding(one)
      && !AddressText.needsHiding("Main") && !AddressText.needsHiding("account") && !AddressText.needsHiding("12345"))
check("ids: an id of letters a-f only is hidden too (hiding only those with a digit would give the others away)",
      AddressText.needsHiding("deadbeef") && AddressText.needsHiding("feedface-cafe") && !AddressText.needsHiding("deadbee") && !AddressText.needsHiding("deadbeeg"))
check("ids: through the forms an id is the stand-in / 'hidden address', never itself, unless revealed",
      AddressText.sentence(id: uuid, blur: true) == "hidden address" && !AddressText.sentence(id: uuid, blur: true).contains("1A2B")
      && AddressText.drawn(address: uuid, blur: true) == AddressText.standIn && AddressText.sentence(id: uuid, revealed: true, blur: true) == uuid)

// ── the setting is a value the app passes in; the module reads no key of its own ──────────────────────────────
do {
    let s = AddressPrivacy(blur: true)
    check("setting: an instance takes the value given, and the shared one is untouched by it", s.blur && AddressPrivacy.shared.blur)
    s.apply(blur: false)
    check("setting: apply(blur:) takes it", !s.blur && AddressPrivacy.shared.blur)
    final class Store: AddressBlurStore { var blurAddresses = false }
    let st = Store()
    s.apply(blur: true)
    s.store = st
    check("setting: a store (optional) is read when it is set", !s.blur)
    st.blurAddresses = true
    s.setBlur(false)
    check("setting: setBlur takes it and writes it back to the store", !s.blur && !st.blurAddresses)
    s.apply(blur: true)
    check("setting: apply(blur:) alone writes nothing (the app keeps its own storage)", s.blur && !st.blurAddresses)
    let shared = AddressPrivacy.shared
    shared.apply(blur: true)
    check("setting: the static conveniences read the shared setting",
          AddressPrivacy.words(one) == "hidden address" && AddressPrivacy.drawn(address: one) == AddressText.standIn
          && AddressPrivacy.drawn(address: one, revealed: true) == one && AddressPrivacy.short(address: one) == "hidden address" && AddressPrivacy.standIn == AddressText.standIn)
    shared.apply(blur: false)
    check("setting: …and follow it", AddressPrivacy.words(one) == one && AddressPrivacy.drawn(address: one) == one && AddressPrivacy.short(address: one) == "zed.sample")
    shared.apply(blur: true)
}

// a prefs domain the app names (here: a key of the shown sense, an older inverted one, one change note)
do {
    final class Prefs: AddressPrefs {
        var d: [String: Bool] = [:]
        func addressBool(_ key: String) -> Bool? { d[key] }
        func setAddressBool(_ value: Bool, _ key: String) { d[key] = value }
        func removeAddressKey(_ key: String) { d[key] = nil }
    }
    let note = "local.check.addressprivacy.changed.\(UUID().uuidString)"
    let p = Prefs()
    let store = AddressDefaultsStore(key: "showEmails", valueMeansShown: true, legacyKey: "blurEmails", changeNote: note, prefs: p)
    check("prefs: nothing set means the blur is on", store.blurAddresses)
    p.d["blurEmails"] = false
    check("prefs: the older inverted key is read when the new one is missing (blurEmails false = shown)", !store.blurAddresses)
    p.d["blurEmails"] = true
    check("prefs: …and blurEmails true = blurred", store.blurAddresses)
    p.d["showEmails"] = true
    check("prefs: the key wins over the older one, in its own sense (showEmails true = shown)", !store.blurAddresses)
    store.blurAddresses = true
    check("prefs: a write goes to the named key in its sense and removes the older one", p.d["showEmails"] == false && p.d["blurEmails"] == nil && store.blurAddresses)
    let other = AddressDefaultsStore(key: "blur", prefs: p)
    other.blurAddresses = false
    check("prefs: a key of the other sense (true = blur) reads and writes the value as it is", p.d["blur"] == false && !other.blurAddresses)
    // a reader in this process takes the value now, and again when the note arrives (another process's write)
    let reader = AddressPrivacy(blur: true)
    p.d["showEmails"] = true
    store.observe(reader)
    check("prefs: observe hands the setting over at once", !reader.blur)
    p.d["showEmails"] = false
    DistributedNotificationCenter.default().postNotificationName(Notification.Name(note), object: nil, userInfo: nil, deliverImmediately: true)
    let until = Date().addingTimeInterval(4)
    while reader.blur == false, Date() < until { spin(0.05) }
    check("prefs: the change note reloads it (a distributed notification, as from another process)", reader.blur)
    check("prefs: the module's own default key does not exist: nothing is read until an app names one", AddressPrivacy().blur)
}

// ── the hover gate: the pointer, a hover cut short, an outside reveal (a peek) ─────────────────────────────
do {
    var g = AddressHoverGate()
    check("gate: at rest nothing is revealed", !g.on)
    g.pointer(true)
    check("gate: the pointer on it reveals", g.on)
    g.pointer(false)
    check("gate: the pointer off blurs it again", !g.on)
    g.pointer(true)
    g.sync(AddressPrivacy.shared.hoverEnded)
    check("gate: with no cut-short hover in between, the sync changes nothing", g.on)
    AddressPrivacy.shared.endHover()
    g.sync(AddressPrivacy.shared.hoverEnded)
    check("gate: a hover cut short (no exit comes) ends it", !g.on)
    g.sync(AddressPrivacy.shared.hoverEnded)
    check("gate: …and it stays ended until the pointer enters anew", !g.on)
    g.pointer(true)
    check("gate: …when it enters, it reveals again", g.on)
    g.reset()
    check("gate: a view that went away or whose text changed ends it there and then", !g.on)
    var p = AddressHoverGate()
    p.peek = true
    check("gate: an outside reveal (a peek) reveals with no pointer", p.on)
    p.pointer(true); p.pointer(false)
    check("gate: …the pointer coming and going doesn't end it", p.on)
    AddressPrivacy.shared.endHover()
    p.sync(AddressPrivacy.shared.hoverEnded)
    check("gate: …nor does a hover cut short (a peek is the app's own)", p.on)
    p.peek = false
    check("gate: …and the app turning it off blurs it", !p.on)

    // a view that computes the reveal in its body from the counter is never one update late
    var q = AddressHoverGate()
    q.pointer(true)
    let now = AddressPrivacy.shared.hoverEnded
    check("gate: isOn(at:) with the counter as the gate last saw it: revealed", q.isOn(at: now))
    check("gate: …at once false when the counter has moved on (the hover ended), before any sync", !q.isOn(at: now + 1) && q.on)
    q.sync(now + 1)
    check("gate: …and after the sync too", !q.on && !q.isOn(at: now + 1))
    q.pointer(true, counter: now + 1)
    check("gate: a pointer entering anew takes the counter as it is: revealed", q.isOn(at: now + 1))
    var pk = AddressHoverGate(); pk.peek = true
    check("gate: a peek is revealed whatever the counter", pk.isOn(at: now + 5))

    // a hover ends by itself when the app loses focus, a window loses focus or closes, a menu starts tracking
    let before = AddressPrivacy.shared.hoverEnded
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
    spin(0.05)
    check("ends: the app losing focus (the user switches to another app) counts as a hover cut short", AddressPrivacy.shared.hoverEnded > before)
    let b2 = AddressPrivacy.shared.hoverEnded
    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
    spin(0.05)
    check("ends: a menu starting to track (no exit comes while it does) counts too", AddressPrivacy.shared.hoverEnded > b2)
    let b3 = AddressPrivacy.shared.hoverEnded
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w)
    spin(0.05)
    let b4 = AddressPrivacy.shared.hoverEnded
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: w)
    spin(0.05)
    check("ends: a window losing focus, and a window closing, count too", b4 > b3 && AddressPrivacy.shared.hoverEnded > b4)
}

// ── the views ──────────────────────────────────────────────────────────────────────────────────────────
check("view: BlurredAddress draws the stand-in at rest, never any part of the address",
      samples.allSatisfy { let d = BlurredAddress.drawn(address: $0, readable: false, blur: true); return d == AddressText.standIn && !leaks(d, of: $0) })
check("view: …the address when readable (the pointer, a peek or `revealed`), and when the blur is off",
      BlurredAddress.drawn(address: one, readable: true, blur: true) == one && BlurredAddress.drawn(address: one, readable: false, blur: false) == one)
check("view: it says 'hidden address' to accessibility, whether or not the pointer is on it; the address only with the blur off",
      samples.allSatisfy { BlurredAddress.spoken(address: $0, blur: true) == "hidden address" } && BlurredAddress.spoken(address: one, blur: false) == one)
check("view: the blur radius is a fifth of the text size at rest, none when revealed or off",
      abs(BlurredAddress.blurRadius(size: 12.5, revealed: false) - 2.625) < 0.01 && BlurredAddress.blurRadius(size: 12.5, revealed: true) == 0
      && BlurredAddress.blurRadius(size: 12.5, revealed: false, blur: false) == 0)
check("view: a test override of the setting reaches the view (blur: true hides whatever the app's setting is)",
      BlurredAddress(address: one, blur: true).blurred && !BlurredAddress(address: one, blur: false).blurred)

/// A view's picture (pixels, as tiff data) and how many of its pixels are lit (not the black background).
@MainActor func rendered<V: View>(_ v: V) -> NSImage? {
    let r = ImageRenderer(content: v.environment(\.colorScheme, .dark).background(Color.black))
    r.scale = 2
    return r.nsImage
}
func lit(_ image: NSImage?) -> Int {
    guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return -1 }
    var n = 0
    for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
        if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.genericGray), c.whiteComponent > 0.08 { n += 1 }
    } }
    return n
}
if #available(macOS 14, *) {
    MainActor.assumeIsolated {
        let a = rendered(BlurredAddress(address: one, blur: true)), b = rendered(BlurredAddress(address: two, blur: true))
        check("view pixels: hidden, two different addresses look exactly alike (the stand-in blurred), so nothing of either is in the picture",
              a?.tiffRepresentation != nil && a?.tiffRepresentation == b?.tiffRepresentation)
        check("view pixels: …and the hidden picture is not blank (the stand-in really draws)", lit(a) > 200, "\(lit(a)) lit pixels")
        let sharpA = rendered(BlurredAddress(address: one, revealed: true, blur: true))
        check("view pixels: revealed it is the address (a different picture, and two addresses differ)",
              sharpA?.tiffRepresentation != a?.tiffRepresentation && sharpA?.tiffRepresentation != rendered(BlurredAddress(address: two, revealed: true, blur: true))?.tiffRepresentation && lit(sharpA) > 200)
        check("view pixels: with the blur off (the override) it draws the address at rest, whole (the room is its own, nothing to hide)",
              rendered(BlurredAddress(address: one, blur: false))?.tiffRepresentation == rendered(BlurredAddress(address: one, revealed: true, blur: false))?.tiffRepresentation
              && rendered(BlurredAddress(address: one, blur: false))?.tiffRepresentation != a?.tiffRepresentation)
        check("view pixels: the same short and very long address look alike hidden",
              rendered(BlurredAddress(address: "q@e.test", blur: true))?.tiffRepresentation == rendered(BlurredAddress(address: long, blur: true))?.tiffRepresentation)

        // layout: an address longer than the stand-in, in a real container, leaves a neighbour where a short one does
        func width<V: View>(_ v: V) -> CGFloat {
            let h = NSHostingView(rootView: v)
            return h.fittingSize.width
        }
        func row(_ address: String, revealed: Bool, reserve: Bool = true) -> some View {
            HStack(spacing: 0) {
                Text("Account ")
                BlurredAddress(address: address, revealed: revealed, reserve: reserve, blur: true)
                Image(systemName: "chevron.down")
            }
        }
        let shortHidden = width(row("q@e.test", revealed: false)), longHidden = width(row(long, revealed: false)), usualHidden = width(row(one, revealed: false))
        check("layout: hidden, a short, a usual and a very long address leave the neighbour (the chevron) at the same place: the room is the stand-in's alone",
              shortHidden == longHidden && longHidden == usualHidden && shortHidden > 0, "\(shortHidden) \(usualHidden) \(longHidden)")
        check("layout: …revealed too: the long address is truncated to the room, the short one leaves room; nothing moves",
              width(row(long, revealed: true)) == longHidden && width(row("q@e.test", revealed: true)) == shortHidden && width(row(one, revealed: true)) == usualHidden)
        let flowing = width(row(long, revealed: false, reserve: false))
        check("layout: inline in flowing text (no reserve) the hidden address is the stand-in's width too", flowing == width(row(one, revealed: false, reserve: false)) && flowing > 0)
        let two1 = NSHostingView(rootView: row(long, revealed: false).frame(width: 600, alignment: .leading))
        let heightHidden = two1.fittingSize.height
        let two2 = NSHostingView(rootView: row(long, revealed: true).frame(width: 600, alignment: .leading))
        check("layout: no jump in height on a reveal (one line, whatever the address)", heightHidden == two2.fittingSize.height && heightHidden > 0)
    }

    // accessibility: walk a note with an address and a Menu label; the address is masked, the rest is readable
    func labels(of element: Any, depth: Int = 0) -> [String] {
        guard depth < 14, let o = element as? NSAccessibilityProtocol else { return [] }
        var out: [String] = []
        if let l = o.accessibilityLabel(), !l.isEmpty { out.append(l) }
        if let v = o.accessibilityValue() as? String, !v.isEmpty { out.append(v) }
        for c in (o.accessibilityChildren() ?? []) { out += labels(of: c, depth: depth + 1) }
        return out
    }
    func walk<V: View>(_ v: V) -> [String] {
        MainActor.assumeIsolated {
            let host = NSHostingView(rootView: v.frame(width: 420, height: 80))
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 80), styleMask: [.borderless], backing: .buffered, defer: true)     // never shown
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            return labels(of: host)
        }
    }
    // SwiftUI builds its accessibility tree only for an assistive client (VoiceOver); a headless check has none (and the
    // process can't turn it on: AXManualAccessibility on itself is refused), so the walk of a SwiftUI view finds nothing
    // here. When the tree IS exposed (a runner with an assistive client) the walk is asserted; otherwise what the views
    // declare is (the label strings they attach, which the walk would read), and the AppKit walk below is real either way.
    AddressPrivacy.shared.apply(blur: true)
    let note = walk(HStack { Image(systemName: "exclamationmark.triangle").accessibilityLabel("Warning"); Text("Main is on "); BlurredAddress(address: one); Text(" now.") })
    let menu = walk(Menu { Button("Switch") {} } label: { HStack(spacing: 0) { Text("Account "); BlurredAddress(address: one) } })
    let key = walk(AddressKeyLabel(title: "Try again as ", address: one))
    if !note.isEmpty {
        check("accessibility (SwiftUI walk): the address is an element of its own, 'hidden address', and nothing of it is spoken anywhere", note.contains("hidden address") && !note.contains { leaks($0, of: one) }, "\(note)")
        check("accessibility (SwiftUI walk): what is next to it stays readable (the warning, the words)", note.contains("Warning") && note.contains { $0.contains("Main is on") } && note.contains { $0.contains("now.") }, "\(note)")
        check("accessibility (SwiftUI walk): a Menu whose label holds an address: the address is masked, its words are readable", !menu.contains { leaks($0, of: one) } && (menu.contains { $0.contains("Account") } || menu.contains("hidden address")), "\(menu)")
        check("accessibility (SwiftUI walk): a key's label says its words and 'hidden address', never the address", key.contains { $0.contains("Try again as hidden address") } && !key.contains { leaks($0, of: one) }, "\(key)")
    } else {
        check("accessibility (declared): the address view speaks 'hidden address' for every address, and the key its words with it",
              samples.allSatisfy { BlurredAddress.spoken(address: $0, blur: true) == "hidden address" }
              && ("Try again as " + BlurredAddress.spoken(address: one, blur: true)) == "Try again as hidden address")
    }
}

// accessibility, AppKit (a real walk): a container with words, an alert-style address label and a warning: the address is
// an element of its own and masked, the container and its neighbours stay readable
do {
    func labelsOf(_ element: Any, depth: Int = 0) -> [String] {
        guard depth < 8, let o = element as? NSAccessibilityProtocol else { return [] }
        var out: [String] = []
        if let l = o.accessibilityLabel(), !l.isEmpty { out.append(l) }
        if let v = o.accessibilityValue() as? String, !v.isEmpty { out.append(v) }
        for c in (o.accessibilityChildren() ?? []) { out += labelsOf(c, depth: depth + 1) }
        return out
    }
    AddressPrivacy.shared.apply(blur: true)
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
    let warn = NSTextField(labelWithString: "Warning: the account may be signed out"), lead = NSTextField(labelWithString: "Main is on ")
    let addr = AddressLabel(address: one)
    for v in [warn, lead, addr] { box.addSubview(v) }
    let seen = labelsOf(box)
    check("accessibility (AppKit walk): the address is an element of its own, 'hidden address', and nothing of it is spoken anywhere", seen.contains("hidden address") && !seen.contains { leaks($0, of: one) }, "\(seen)")
    check("accessibility (AppKit walk): the container's other content stays readable (the warning, the words)", seen.contains { $0.contains("Warning") } && seen.contains { $0.contains("Main is on") }, "\(seen)")
    check("accessibility (AppKit walk): the container itself is not masked", box.accessibilityLabel() == nil || box.accessibilityLabel() == "")
}

// AppKit: AddressInk draws into any current graphics context (here an image: a Dock tile's way), AddressLabel is a view
let font = NSFont.systemFont(ofSize: 11.5)
func inkImage(_ address: String, readable: Bool, blur: Bool = true, width: CGFloat = 260, alignRight: Bool = false) -> NSImage {
    let ink = AddressInk(font: font)
    return NSImage(size: NSSize(width: width, height: 30), flipped: true) { r in
        ink.draw(address: address, readable: readable, color: .white, x: alignRight ? 250 : 10, midY: r.midY, alignRight: alignRight, blur: blur)
        return true
    }
}
let restA = inkImage(one, readable: false), restB = inkImage(two, readable: false)
check("ink: hidden, two different addresses draw exactly alike (the stand-in blurred)", restA.tiffRepresentation != nil && restA.tiffRepresentation == restB.tiffRepresentation)
check("ink: …and the hidden picture is not blank (the stand-in really draws)", lit(restA) > 100, "\(lit(restA))")
check("ink: …the same for a short and a very long address", inkImage("q@e.test", readable: false).tiffRepresentation == inkImage(long, readable: false).tiffRepresentation)
check("ink: readable it draws the address (different for two addresses, and from the stand-in)",
      inkImage(one, readable: true).tiffRepresentation != restA.tiffRepresentation && inkImage(one, readable: true).tiffRepresentation != inkImage(two, readable: true).tiffRepresentation)
let ink = AddressInk(font: font)
check("ink: the room is the stand-in's, whatever the address, while hidden; the address's own with the blur off",
      ink.room(for: one, blur: true) == ink.room && ink.room(for: long, blur: true) == ink.room && ink.room(for: "q@e.test", blur: true) == ink.room
      && ink.room(for: long, blur: false) > ink.room && ink.room(for: "q@e.test", blur: false) < ink.room)
// a readable address longer than the room is cut to it: no ink beyond the room's right edge
func inkPast(_ image: NSImage, from x: CGFloat) -> Bool {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return true }
    let scale = Double(rep.pixelsWide) / Double(image.size.width)
    for y in 0..<rep.pixelsHigh { for px in Int(Double(x) * scale)..<rep.pixelsWide {
        if let c = rep.colorAt(x: px, y: y)?.usingColorSpace(.genericGray), c.alphaComponent > 0.05 { return true }
    } }
    return false
}
check("ink: a revealed address longer than the room is truncated to it (nothing drawn past the room)", !inkPast(inkImage(long, readable: true), from: 10 + ink.room + 2))
check("ink: with the blur off the long address is drawn whole (past the stand-in's room)", inkPast(inkImage(long, readable: true, blur: false, width: 400), from: 10 + ink.room + 2))
check("ink: right-aligned, the hidden stand-in is the same for two addresses", inkImage(one, readable: false, alignRight: true).tiffRepresentation == inkImage(two, readable: false, alignRight: true).tiffRepresentation)
check("ink: the blurred picture has the blur's room on every side", (AddressInk.blurred(AddressText.standIn, color: .white, font: font)?.size.height ?? 0) >= ink.lineHeight + 2 * AddressInk.blurPad - 1)
ink.reset()
check("ink: reset keeps drawing the same thing", inkImage(one, readable: false).tiffRepresentation == restA.tiffRepresentation)
do {
    let capped = AddressInk(font: font)
    for i in 0..<(AddressInk.cacheLimit * 3) { _ = capped.standIn(NSColor(white: CGFloat(i) / 30, alpha: 1)) }
    check("ink: the blurred pictures kept are capped (one per colour, the oldest dropped)", capped.cached == AddressInk.cacheLimit, "\(capped.cached)")
    check("ink: …and a colour dropped is made again, the same", capped.standIn(NSColor(white: 0, alpha: 1))?.tiffRepresentation != nil && capped.cached == AddressInk.cacheLimit)
}

// AddressLabel: the alert's accessory
do {
    AddressPrivacy.shared.apply(blur: true)
    let l1 = AddressLabel(address: one), l2 = AddressLabel(address: two), longL = AddressLabel(address: long)
    func pic(_ v: NSView) -> Data? {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.tiffRepresentation
    }
    check("label: hidden it draws the stand-in, never any part of the address, and the same for another address",
          l1.drawnText == AddressText.standIn && l2.drawnText == AddressText.standIn && !leaks(l1.drawnText, of: one))
    check("label: its pixels hidden are the same for two addresses", pic(l1) != nil && pic(l1) == pic(l2))
    check("label: its accessibility label is 'hidden address', never the address", l1.accessibilityLabel() == "hidden address" && l1.isAccessibilityElement())
    check("label: as wide for a short, a usual and a very long address (the room is the stand-in's alone)", l1.frame.width == l2.frame.width && longL.frame.width == l1.frame.width)
    let rest = pic(l1)
    l1.mouseEntered(with: NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
    check("label: the pointer entering reveals the address", l1.revealed && l1.drawnText == one && pic(l1) != rest)
    l1.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
    check("label: …and leaving blurs it again", !l1.revealed && l1.drawnText == AddressText.standIn && pic(l1) == rest)
    // a modal alert gets no enter and exit: the label reads where the pointer is in its window (never shown here)
    let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
    host.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    host.contentView?.addSubview(l1)
    l1.frame.origin = NSPoint(x: 40, y: 50)
    check("label: in a window it asks for mouse moves", host.acceptsMouseMovedEvents)
    func inside(_ l: AddressLabel) -> NSPoint { l.convert(NSPoint(x: l.bounds.midX, y: l.bounds.midY), to: nil) }
    func outside(_ l: AddressLabel) -> NSPoint { l.convert(NSPoint(x: l.bounds.maxX + 40, y: l.bounds.midY), to: nil) }
    // the label's own timer keeps polling while the checks spin: its surroundings are the checks' (the window shown, key,
    // the app active, the pointer where `put` last said), so a reading by the timer agrees with the check's own
    var shown = true, key = true, active = true, modal: NSWindow? = nil, pointer: NSPoint? = nil
    l1.surroundings.shown = { _ in shown }; l1.surroundings.key = { _ in key }; l1.surroundings.appActive = { active }
    l1.surroundings.modalWindow = { modal }; l1.surroundings.pointer = { _ in pointer }
    func put(_ p: NSPoint?) { pointer = p; l1.follow(inWindow: p) }
    put(inside(l1))
    check("label: the pointer read on it reveals the address (no enter event)", l1.revealed && l1.drawnText == one)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
    spin(0.05)
    check("label: the app losing focus ends the reveal at once", !l1.revealed && l1.drawnText == AddressText.standIn)
    put(inside(l1))
    check("label: …and the poll doesn't take it up again while the pointer hasn't left (ended stays ended)", !l1.revealed && l1.suppressed)
    put(outside(l1))
    check("label: …until the pointer has left the label", !l1.revealed && !l1.suppressed)
    put(inside(l1))
    check("label: …then it reveals again on the next entry", l1.revealed)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: host)
    spin(0.05)
    check("label: its window losing focus ends it (and keeps it ended)", !l1.revealed); put(inside(l1)); check("label: …even when the poll reads the pointer on it", !l1.revealed)
    put(outside(l1)); put(inside(l1))
    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
    spin(0.05)
    check("label: a menu starting to track ends it", !l1.revealed)
    put(outside(l1))
    check("label: the pointer read off it keeps it blurred", !l1.revealed && l1.drawnText == AddressText.standIn)
    put(inside(l1)); put(nil)
    check("label: no pointer at all blurs it too", !l1.revealed)

    // the poll: it runs while the label is in a window, and its readings come through swappable surroundings
    check("poll: it runs while the label is in a window", l1.isPolling)
    pointer = inside(l1)
    l1.tick()
    check("poll: shown, key and active, with the pointer on it: readable", l1.revealed)
    shown = false; l1.tick()
    check("poll: shown → hidden (a hidden app, a covered window): the reveal ends, and the poll keeps running (it resumes when shown again)", !l1.revealed && l1.isPolling)
    shown = true; put(outside(l1)); pointer = inside(l1); l1.tick()
    check("poll: …and reveals again once shown, after the pointer has left", l1.revealed)
    key = false; l1.tick()
    check("poll: a window that is not key never reveals", !l1.revealed)
    key = true; put(outside(l1)); pointer = inside(l1); active = false; l1.tick()
    check("poll: nor does an app that isn't active", !l1.revealed && l1.isPolling)
    active = true; put(outside(l1)); pointer = inside(l1); l1.tick()
    check("poll: active again, it reveals", l1.revealed)
    modal = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.borderless], backing: .buffered, defer: true)
    l1.tick()
    check("poll: another window taking over the modal session stops the poll and ends the reveal", !l1.isPolling && !l1.revealed)
    modal = nil
    host.contentView?.addSubview(l1)       // moved out and in again: the poll starts anew
    l1.removeFromSuperview()
    check("poll: the label leaving its window stops the poll, and it is blurred", !l1.isPolling && !l1.revealed)
    host.contentView?.addSubview(l1)
    check("poll: put back in a window it polls again", l1.isPolling)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: host)
    spin(0.05)
    check("poll: its window closing stops it", !l1.isPolling && !l1.revealed)
    l1.removeFromSuperview()
    check("label: out of its window it is blurred", !l1.revealed)

    // a live label follows the app's setting: drawn again at once, its words and text recomputed, its frame unchanged
    AddressPrivacy.shared.apply(blur: true)
    let live = AddressLabel(address: one)
    host.contentView?.addSubview(live)          // (a view outside any window keeps no pending redraw)
    let width0 = live.frame.width
    live.needsDisplay = false
    AddressPrivacy.shared.apply(blur: false)
    check("live: a change of the setting redraws a live label at once", live.needsDisplay)
    check("live: …its text and its accessibility label follow (computed on each call), and its frame doesn't move",
          live.drawnText == one && live.accessibilityLabel() == one && live.frame.width == width0)
    AddressPrivacy.shared.apply(blur: true)
    check("live: …and back", live.drawnText == AddressText.standIn && live.accessibilityLabel() == "hidden address")
    let fixed = AddressLabel(address: one, blur: true)
    host.contentView?.addSubview(fixed)
    fixed.needsDisplay = false
    AddressPrivacy.shared.apply(blur: false)
    check("live: a label with a test override ignores the app's setting (same words, same text)", fixed.accessibilityLabel() == "hidden address" && fixed.drawnText == AddressText.standIn)
    AddressPrivacy.shared.apply(blur: true)
    live.removeFromSuperview(); fixed.removeFromSuperview()
    let forced = AddressLabel(address: one, blur: false)
    check("label: the test override of the setting reaches it (blur: false: the address, whole)", forced.sharp && forced.drawnText == one && forced.accessibilityLabel() == one)
    let forcedOn = AddressLabel(address: one, blur: true)
    AddressPrivacy.shared.apply(blur: false)
    check("label: …and blur: true holds whatever the app's setting is", !forcedOn.sharp && forcedOn.accessibilityLabel() == "hidden address")
    let off = AddressLabel(address: long)
    check("label: with the blur off it draws the address at rest (cut to the same room), and its label is the whole address",
          off.sharp && off.drawnText == long && off.accessibilityLabel() == long && off.frame.width == l2.frame.width)
    AddressPrivacy.shared.apply(blur: true)
}

// text that can't blur (a notification, a status item's title, an alert's text, a tooltip): the stand-in or the words, a reveal only on the app's word
do {
    let title = "Main · " + AddressText.drawn(address: one, blur: true)
    let tooltip = "Switch to " + AddressText.sentence(address: one, blur: true)
    check("plain text: a title or a notification body built from drawn(address:) holds the stand-in and nothing of the address", !leaks(title, of: one) && title.contains(AddressText.standIn))
    check("plain text: a tooltip, an alert's text and a pop-up row built from sentence(address:) hold 'hidden address' and nothing of the address", !leaks(tooltip, of: one) && tooltip == "Switch to hidden address")
    check("plain text: …and the address only when the app reveals it", ("Main · " + AddressText.drawn(address: one, revealed: true, blur: true)).contains(one))
}

print(failed == 0 ? "addressprivacy checks: \(passed) passed" : "addressprivacy checks: \(failed) FAILED, \(passed) passed")
exit(failed == 0 ? 0 : 1)
