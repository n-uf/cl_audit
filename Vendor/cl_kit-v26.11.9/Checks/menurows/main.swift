// The MenuRows module's own checks (Checks/run.sh menurows): the module and the two it imports (ProfileCore, AddressPrivacy),
// no app code, no window shown, no mouse, nothing written outside Checks/.work. Sample addresses only (example.com).
//
// What they prove: the usage line says what ProfileCore's display value says and nothing else (the week-only rule, the
// levels, a full limit's countdown, grey for old numbers, none without numbers); with addresses hidden, nothing of an
// address is in a row's title, its spoken words or its drawn text, two addresses draw the very same pixels and take the
// same room, a keyboard highlight never reveals the address and the pointer on the lit row does; the tick and "selected"
// for the account in use; the item's title, action, state and a dimmed row's silence; one line or two.

@testable import MenuRows
import AddressPrivacy
import AppKit
import ProfileCore

var failed = 0, passed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failed += 1; print("FAIL \(name) \(detail())") }
}

let short = "wu@example.com", long = "zedekiah.with.a.long.name@sample-domain.example.net", other = "ines@example.org"
let uuid8 = "1a2b3c4d"
/// The pieces of an address a match could use: its local part, its domain, each word of three letters or more.
func parts(_ a: String) -> [String] {
    let at = a.firstIndex(of: "@")!
    var out = [String(a[..<at]), String(a[a.index(after: at)...])]
    out += a.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    return out.filter { $0.count >= 3 && $0 != "com" }
}
func leaks(_ s: String, of a: String) -> Bool { parts(a).contains { s.contains($0) } || s.contains(String(a.prefix(1)) + "@") }

let now = Date(timeIntervalSince1970: 1_800_000_000)
func display(five: Double? = nil, week: Double? = nil, weekResets: Date? = nil, tier: ProfileDisplay.Tier = .fresh,
             full: FullLimit? = nil, hasFiveHour: Bool = true, none: Bool = false) -> ProfileDisplay {
    let u = none ? nil : Usage(fiveHour: five, weekly: week, weeklyResets: weekResets, fetchedAt: now, source: "sample")
    return ProfileDisplay(usage: u, none: none ? .notRead : nil, readAt: now, tier: tier, full: full, lamp: true, key: nil,
                          line: nil, clash: nil, split: nil, sign: .ok, otherAccount: false, hasFiveHour: hasFiveHour)
}

// ── the usage line: what the display value says, and nothing of its own ────────────────────────────────────
let both = MenuUsageLine.of(display(five: 34.4, week: 12), now: now)
check("usage: both limits, rounded, 5-hour first, the standard words", both?.words == "5h 34% · Week 12%", "\(both?.words ?? "nil")")
check("usage: each part's level is the display's (ProfileCore.Level)",
      both?.parts.map(\.level) == [display(five: 34.4).level(34.4), display().level(12)])
let weekOnly = MenuUsageLine.of(display(five: 40, week: 20, hasFiveHour: false), now: now)
check("usage: the week-only rule (display.hasFiveHour false): no 5-hour part even with a number", weekOnly?.words == "Week 20%",
      "\(weekOnly?.words ?? "nil")")
check("usage: a limit with no number is left out", MenuUsageLine.of(display(five: 7), now: now)?.words == "5h 7%")
check("usage: no numbers (display.usage nil): no line, the app says why in its note",
      MenuUsageLine.of(display(none: true), now: now) == nil && MenuUsageLine.of(display(), now: now) == nil)
let resets = now.addingTimeInterval(2 * 86400 + 19 * 3600)
let full = MenuUsageLine.of(display(five: 10, week: 100, weekResets: resets, full: FullLimit(kind: .week, resets: resets)), now: now)
check("usage: a full limit replaces the parts: its name, the words' full, the countdown (TimeWords)",
      full?.full == "Week full · \(TimeWords.countdown(resets, now: now))" && full?.parts.isEmpty == true && full?.words == full?.full,
      "\(full?.full ?? "nil")")
let passedFull = MenuUsageLine.of(display(five: 10, week: 100, weekResets: now.addingTimeInterval(-60),
                                          full: FullLimit(kind: .week, resets: now.addingTimeInterval(-60))), now: now)
check("usage: a full limit whose reset has passed holds nothing back (display.full(now:)): the parts again",
      passedFull?.full == nil && passedFull?.words == "5h 10% · Week 100%", "\(passedFull?.words ?? "nil")")
let old = MenuUsageLine.of(display(five: 60, week: 30, tier: .stale), now: now)
check("usage: old numbers are grey, their levels none (the display's rule)", old?.grey == true && old?.parts.allSatisfy { $0.level == .none } == true)
let own = MenuRowWords(fiveHour: "5-hour", week: "wk", full: "is full")
check("usage: the app's own words", MenuUsageLine.of(display(five: 1, week: 2), words: own, now: now)?.words == "5-hour 1% · wk 2%")

// ── the row, addresses hidden ──────────────────────────────────────────────────────────────────────────────
func view(_ a: String, inUse: Bool = false, usage: MenuUsageLine? = nil, note: String? = nil, tag: String = "", hint: String? = nil,
          enabled: Bool = true, blur: Bool = true) -> MenuAccountRowView {
    let v = MenuAccountRowView(row: MenuAccountRow(address: a, inUse: inUse, usage: usage, note: note, tag: tag, hint: hint,
                                                   enabled: enabled), pick: {})
    v.blur = blur
    v.frame.size = NSSize(width: max(v.naturalWidth, 320), height: v.height)
    return v
}
let hShort = view(short, inUse: true, usage: both, tag: " · in use"), hLong = view(long, usage: both, tag: " · in use")
check("hidden: the title is the sentence form, the same for every account",
      hShort.title == "hidden address · in use" && hLong.title == hShort.title && !leaks(hShort.title, of: short) && !leaks(hLong.title, of: long))
check("hidden: VoiceOver's label holds nothing of the address, the usage line after it",
      hShort.accessibilityLabel() == "hidden address · in use, 5h 34% · Week 12%"
      && !leaks(hShort.accessibilityLabel() ?? short, of: short) && !leaks(hLong.accessibilityLabel() ?? long, of: long))
check("hidden: what is drawn is the stand-in, never the address", hShort.drawnAddress == AddressText.standIn && hLong.drawnAddress == AddressText.standIn)
check("hidden: a short and a long address take the same room and the same width (no length in it)",
      hShort.room == hLong.room && view(short).naturalWidth == view(long).naturalWidth)

// the reveal: only the pointer on the lit row
let r = view(short, hint: "Switch…")
check("reveal: at rest, not lit, not sharp", !r.lit && !r.sharp)
r.menuLit = true
check("reveal: lit by the keyboard (the arrow keys), the pointer elsewhere: still the stand-in", r.lit && !r.sharp && r.drawnAddress == AddressText.standIn)
r.pointer(true)
check("reveal: lit with the pointer on it: the address, sharp", r.sharp && r.drawnAddress == short)
r.menuLit = false
check("reveal: the pointer on it but not lit (the menu moved on): the stand-in again", !r.sharp && r.drawnAddress == AddressText.standIn)
r.pointer(false)
check("reveal: the title and spoken words stay hidden whatever the pointer does", r.title == "hidden address" && r.accessibilityLabel() == "hidden address")
let dim = view(short, enabled: false); dim.menuLit = true; dim.pointer(true)
check("reveal: a dimmed row is never lit and never reveals", !dim.lit && !dim.sharp)
let picture = view(short); picture.highlighted = true
check("reveal: drawn lit for a picture, sharp", picture.lit && picture.sharp)

// the pixels: two addresses, hidden, draw the very same row, and it isn't blank
func pixels(_ v: NSView) -> Data? {
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
    v.cacheDisplay(in: v.bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
}
func inked(_ v: NSView) -> Bool {
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
    v.cacheDisplay(in: v.bounds, to: rep)
    for x in stride(from: 0, to: rep.pixelsWide, by: 2) { for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.05 { return true } } }
    return false
}
let p1 = view(short, inUse: true, usage: both), p2 = view(long, inUse: true, usage: both)
p2.frame.size = p1.frame.size
check("pixels: hidden, a short and a long address draw the very same row", pixels(p1) != nil && pixels(p1) == pixels(p2))
check("pixels: the row isn't blank", inked(p1))
let s1 = view(short, blur: false), s2 = view(other, blur: false)
s2.frame.size = s1.frame.size
check("pixels: shown, two addresses draw differently (the address is there)", pixels(s1) != pixels(s2))

// ── shown ──────────────────────────────────────────────────────────────────────────────────────────────────
let shown = view(short, tag: " · standby", blur: false)
check("shown: the title and the drawn text are the address", shown.title == "\(short) · standby" && shown.drawnAddress == short && shown.sharp)
check("shown: the room is the address's own (nothing to hide, nothing cut)", view(long, blur: false).room > view(short, blur: false).room)

// ── the tick, the item, acting ─────────────────────────────────────────────────────────────────────────────
var picks = 0
let inUseItem = MenuAccountRowView.item(MenuAccountRow(address: short, inUse: true, usage: both), blur: true) { picks += 1 }
let standbyItem = MenuAccountRowView.item(MenuAccountRow(address: long, inUse: false, note: "Last used yesterday", hint: "Switch…"), blur: true) { picks += 1 }
let dimItem = MenuAccountRowView.item(MenuAccountRow(address: other, inUse: false, enabled: false), blur: true) { picks += 1 }
check("tick: the account in use is the item's .on state and 'selected' to VoiceOver; a standby account neither",
      inUseItem.state == .on && inUseItem.view?.accessibilityValue() as? String == "selected"
      && standbyItem.state == .off && standbyItem.view?.accessibilityValue() == nil)
check("item: its title is the row's sentence form, its view the row, its target the row with Return's action",
      inUseItem.title == "hidden address" && inUseItem.view is MenuAccountRowView && inUseItem.target === inUseItem.view
      && inUseItem.action == #selector(MenuAccountRowView.fire))
(standbyItem.target as? MenuAccountRowView)?.fire()
check("item: Return (the item's action) runs pick", picks == 1)
check("item: a dimmed row is disabled, has no action and does nothing",
      !dimItem.isEnabled && dimItem.action == nil && (dimItem.view as? MenuAccountRowView)?.accessibilityPerformPress() == false)
(dimItem.view as? MenuAccountRowView)?.fire()
check("item: a dimmed row's Return does nothing", picks == 1)

// one line or two
let oneLine = view(short), withUsage = view(short, usage: both), withNote = view(short, note: "Signed out")
check("size: one line without a second line; two with the usage line or a note, the same height either way",
      withUsage.height > oneLine.height && withNote.height == withUsage.height && oneLine.height == MenuAccountRowView.addressLineH)
check("size: the second line's words, the note when there are no numbers", withNote.secondLine == "Signed out" && oneLine.secondLine == nil)
check("size: compact (a native item's height for one line, under 40 pt for two)",
      oneLine.height <= 30 && withUsage.height < 40, "\(oneLine.height) \(withUsage.height)")

// ── review fixes: the pointer forgotten, the prefix, the standby look, the pick's order, help, hidden words, the title ──
// the pointer is never remembered: leaving the window or the menu's end drops a stand-in, and without one the row asks
// the window (none here: not on it)
let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
let roaming = view(short); host.contentView?.addSubview(roaming)
roaming.menuLit = true; roaming.pointer(true)
check("pointer: lit with the pointer on it (a stand-in): sharp", roaming.sharp)
roaming.removeFromSuperview()
check("pointer: the row left its window (the menu closed): the stand-in is gone, the stand-in address back",
      roaming.pointerStandIn == nil && !roaming.sharp && roaming.drawnAddress == AddressText.standIn)
let menu = NSMenu(), menuItem = MenuAccountRowView.item(MenuAccountRow(address: short, inUse: false), blur: true) {}
menu.addItem(menuItem)
let inMenu = menuItem.view as! MenuAccountRowView
inMenu.menuLit = true; inMenu.pointer(true)
check("pointer: in a menu, lit with the pointer on it: sharp", inMenu.sharp)
NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
check("pointer: its menu ended tracking: nothing remembered, a later keyboard highlight shows the stand-in",
      inMenu.pointerStandIn == nil && { inMenu.menuLit = true; return !inMenu.sharp }())
let other2 = NSMenu(); let stays = view(short); stays.pointer(true)
NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: other2)
check("pointer: another menu's end doesn't touch the row", stays.pointerStandIn == true)
check("pointer: with no stand-in and no window, the pointer isn't on it", view(short).pointerOn == false)

// the prefix: before the address, in the title, the room and the spoken words, nothing of a hidden address
let signRow = view(short, blur: true)
let sign = MenuAccountRowView(row: MenuAccountRow(prefix: "Sign Terminal in to ", address: short, inUse: false, tag: "…"), pick: {})
sign.blur = true
check("prefix: the title and VoiceOver say it, then 'hidden address', then the tag",
      sign.title == "Sign Terminal in to hidden address…" && sign.accessibilityLabel() == "Sign Terminal in to hidden address…"
      && !leaks(sign.title, of: short))
check("prefix: the address starts after it, and the row is wider by it",
      sign.addressX > MenuRowColumns.standard.addressX && sign.naturalWidth > signRow.naturalWidth)
sign.blur = false
check("prefix: shown, the address itself after it", sign.title == "Sign Terminal in to \(short)…")

// the standby look: dimmed, a hollow lamp, the columns
let plainRow = view(short, tag: " · standby")
let dimmedRow = MenuAccountRowView(row: MenuAccountRow(address: short, inUse: false, tag: " · standby", dimmed: true, marker: .hollowLamp), pick: {})
dimmedRow.blur = true; dimmedRow.frame.size = plainRow.frame.size
check("standby look: dimmed with a hollow lamp draws differently from a plain row (and still lights and acts)",
      pixels(dimmedRow) != pixels(plainRow) && { dimmedRow.menuLit = true; return dimmedRow.lit }())
let lined = MenuAccountRowView(row: MenuAccountRow(address: short, inUse: false), columns: MenuRowColumns(markerX: 14, addressX: 27), pick: {})
lined.blur = true
check("columns: the address stands at the app's column (cl_quick's block: 27 pt), the row wider by the difference",
      lined.addressX == 27 && lined.naturalWidth == view(short).naturalWidth + 13)

// the pick runs once the menu's tracking has ended, in the default mode
var pressed = 0
let presser = MenuAccountRowView(row: MenuAccountRow(address: short, inUse: false), pick: { pressed += 1 })
presser.press()
check("press: pick doesn't run inside the press (the menu is still tracking)", pressed == 0)
let pressDeadline = Date().addingTimeInterval(1)
while pressed == 0 && Date() < pressDeadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
check("press: pick runs in the default run-loop mode, after", pressed == 1)

// VoiceOver's help: the hint
check("help: VoiceOver's help is the hint (a hidden standby row says it switches)",
      view(short, hint: "Switch…").accessibilityHelp() == "Switch…" && view(short).accessibilityHelp() == nil)

// the app's words never carry an address while hidden
let sloppy = MenuAccountRowView(row: MenuAccountRow(prefix: "Back to \(other) or ", address: short, inUse: false, note: "Was on \(long)",
                                                    tag: " · \(uuid8)", hint: "Switch to \(other)"), pick: {})
sloppy.blur = true
check("hidden words: a prefix, note, tag or hint naming an address or an id is 'hidden address' while hidden",
      !leaks(sloppy.title, of: other) && !leaks(sloppy.accessibilityLabel() ?? "", of: long) && !(sloppy.accessibilityLabel() ?? "").contains(uuid8)
      && !leaks(sloppy.accessibilityHelp() ?? "", of: other) && sloppy.secondLine == "Was on hidden address"
      && sloppy.accessibilityHelp() == "Switch to hidden address" && sloppy.title.hasSuffix(" · hidden address"), "\(sloppy.accessibilityLabel() ?? "")")
sloppy.blur = false
check("hidden words: shown, the app's words as given", sloppy.secondLine == "Was on \(long)" && sloppy.accessibilityHelp() == "Switch to \(other)")
let dated = view(short, note: "Last used 2026-11-20 at 9:41")
check("hidden words: a date is not an id, shown as given", dated.secondLine == "Last used 2026-11-20 at 9:41", dated.secondLine ?? "")
let uuid = "12345678-1234-1234-1234-123456789012"
check("hidden words: ids still hidden: a UUID of digits, a bare digit run, hex letters",
      view(short, note: "id \(uuid)").secondLine == "id hidden address" && view(short, note: "id 12345678").secondLine == "id hidden address"
      && view(short, note: "id 1a2b-3c4d").secondLine == "id hidden address")
let spaced = view(short, note: "Was\u{00A0}on\u{00A0}\(other)\nthen  \t\(uuid8)")
check("hidden words: split at any white space (no-break space, newline, tab), the spaces kept",
      spaced.secondLine == "Was\u{00A0}on\u{00A0}hidden address\nthen  \thidden address", spaced.secondLine ?? "")

// the title follows the setting
let live = MenuAccountRowView.item(MenuAccountRow(address: short, inUse: false), blur: true) {}
check("title: hidden at first", live.title == "hidden address")
(live.view as? MenuAccountRowView)?.blur = false
check("title: the item's title follows a change of the setting (refresh)", live.title == short)

// numbers that aren't numbers, and the app's own marks
check("usage: a number that isn't finite is left out, never a trap",
      MenuUsageLine.of(display(five: .nan, week: .infinity), now: now) == nil && MenuUsageLine.of(display(five: .nan, week: 3), now: now)?.words == "Week 3%")
let marks = MenuRowWords(fiveHour: "5h", week: "Week", full: "full", tick: "•", selected: "in use")
let marked = MenuAccountRowView.item(MenuAccountRow(address: short, inUse: true), words: marks, blur: true) {}
check("words: the tick and VoiceOver's word for the account in use are the app's to say",
      marked.view?.accessibilityValue() as? String == "in use" && (marked.view as? MenuAccountRowView)?.words.tick == "•")

// ── 26.11.9: the address's size, the columns by the address, the add row, the waiting look, the keyboard's stand-in ──
let small = NSFont.menuFont(ofSize: 11.5)
func sized(_ a: String, _ f: NSFont, prefix: String = "", note: String? = nil) -> MenuAccountRowView {
    let v = MenuAccountRowView(row: MenuAccountRow(prefix: prefix, address: a, inUse: false, note: note), addressFont: f, pick: {})
    v.blur = true
    v.frame.size = NSSize(width: max(v.naturalWidth, 320), height: v.height)
    return v
}
let s11 = sized(short, small), l11 = sized(long, small), s13 = sized(short, MenuAccountRowView.font)
check("size: by default the menu's font, today's metrics",
      view(short).addressFont == MenuAccountRowView.font && view(short).lineH == MenuAccountRowView.addressLineH
      && view(short, note: "x").secondTop == MenuAccountRowView.secondLineTop)
check("size: at 11.5 pt, hidden, every address takes the same room, the stand-in's at that size",
      s11.room == l11.room && s11.room == AddressInk(font: small).room(for: short, blur: true) && s11.naturalWidth == l11.naturalWidth,
      "\(s11.room) \(l11.room)")
check("size: at 11.5 pt the room, the line, the height and the width are smaller than at the default",
      s11.room < s13.room && s11.lineH < s13.lineH && s11.height < s13.height && s11.naturalWidth < s13.naturalWidth)
let pre11 = sized(short, small, prefix: "Sign in to "), pre13 = sized(short, MenuAccountRowView.font, prefix: "Sign in to ")
check("size: the prefix is in the address's font, and the address starts after it at that size",
      pre11.addressX == MenuRowColumns.standard.addressX + MenuAccountRowView.w("Sign in to ", small) && pre11.addressX < pre13.addressX)
let two11 = sized(short, small, note: "Signed out")
check("size: the second line starts under the smaller address line, the row lower",
      two11.secondTop == two11.lineH - AddressInk.blurPad && two11.height < view(short, note: "Signed out").height)
let l11b = sized(long, small); l11b.frame.size = s11.frame.size
check("size: hidden at 11.5 pt, a short and a long address draw the very same row", pixels(s11) != nil && pixels(s11) == pixels(l11b) && inked(s11))
let smallItem = MenuAccountRowView.item(MenuAccountRow(address: short, inUse: false), addressFont: small, blur: true) {}
check("size: the item passes the font on", (smallItem.view as? MenuAccountRowView)?.addressFont == small)

check("columns: by the address alone: 14 is the standard, 27 puts the mark at 14 (cl_quick), never under 4",
      MenuRowColumns(addressX: 14) == .standard && MenuRowColumns(addressX: 27) == MenuRowColumns(markerX: 14, addressX: 27)
      && MenuRowColumns(addressX: 8).markerX == 4)

var adds = 0
let addItem = MenuAccountRowView.item(.add("Add an account…"), blur: true) { adds += 1 }
let addView = addItem.view as! MenuAccountRowView
addView.frame.size = NSSize(width: max(addView.naturalWidth, 320), height: addView.height)
check("add: its words alone in the title and VoiceOver, never 'hidden address'",
      addItem.title == "Add an account…" && addView.accessibilityLabel() == "Add an account…", addItem.title)
check("add: no address and no room; the plus in the leading column; drawn",
      addView.room == 0 && addView.drawnAddress == "" && addView.row.marker == .plus && addView.row.isAdd && inked(addView))
check("add: the same metrics as an account row (one line)", addView.height == view(short).height)
addView.fire()
check("add: Return picks it, as the others", adds == 1 && addItem.action == #selector(MenuAccountRowView.fire) && addItem.isEnabled)
let addOff = MenuAccountRowView.item(.add("Add an account…", enabled: false), blur: true) { adds += 1 }
check("add: disabled, no action and nothing done", addOff.action == nil && (addOff.view as? MenuAccountRowView)?.accessibilityPerformPress() == false && adds == 1)

/// How much ink a row puts down (the sum of its pixels' alpha): fainter text, less ink.
func inkAmount(_ v: NSView) -> Double {
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return 0 }
    v.cacheDisplay(in: v.bounds, to: rep)
    var sum = 0.0
    for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh { sum += Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) } }
    return sum
}
func styled(_ enabled: Bool, waiting: Bool) -> MenuAccountRowView {
    let v = MenuAccountRowView(row: MenuAccountRow(address: short, inUse: false, note: "Signing in", enabled: enabled, waiting: waiting), pick: {})
    v.blur = true; v.frame.size = NSSize(width: 320, height: v.height); return v
}
let waitInk = inkAmount(styled(false, waiting: true)), offInk = inkAmount(styled(false, waiting: false)), onInk = inkAmount(styled(true, waiting: false))
check("waiting: drawn fainter than a disabled row, which is fainter than a plain one, and still drawn",
      waitInk > 0 && waitInk < offInk && offInk < onInk, "\(waitInk) \(offInk) \(onInk)")
let waitItem = MenuAccountRowView.item(MenuAccountRow(address: short, inUse: false, enabled: false, waiting: true), blur: true) {}
check("waiting: acts as `enabled` says (here not)", waitItem.action == nil && !waitItem.isEnabled)

let k = view(short)
k.standInMenuLit(true)
check("keyboard: lit by the arrow keys (the stand-in), the pointer elsewhere: lit, the stand-in drawn", k.lit && !k.sharp && k.drawnAddress == AddressText.standIn)
k.pointer(true)
check("keyboard: the pointer on the lit row: sharp", k.sharp)
k.standInMenuLit(false); k.pointer(false)
check("keyboard: arrowed away, the pointer gone: nothing sharp", !k.lit && !k.sharp)
k.standInMenuLit(true)
check("keyboard: arrowed back: lit, still the stand-in (nothing remembered)", k.lit && !k.sharp && k.drawnAddress == AddressText.standIn)
k.standInMenuLit(nil)
check("keyboard: nil gives the menu's own highlight back", k.menuLit == nil && !k.lit)
k.standInMenuLit(true); k.forgetPointer()
check("keyboard: the menu's end (forgetPointer) drops the keyboard's stand-in too", k.menuLit == nil && k.pointerStandIn == nil)

// ── review of #17: the waiting word, the add row's note and flag, a waiting row that still acts ──
var waitPicks = 0
let waitOn = MenuAccountRowView.item(MenuAccountRow(address: short, inUse: false, waiting: true), blur: true) { waitPicks += 1 }
(waitOn.view as? MenuAccountRowView)?.fire()
check("waiting: enabled, it still acts, and VoiceOver says 'waiting'",
      waitPicks == 1 && waitOn.isEnabled && waitOn.view?.accessibilityValue() as? String == "waiting")
let waitInUse = MenuAccountRowView.item(MenuAccountRow(address: short, inUse: true, waiting: true), blur: true) {}
check("waiting: the account in use says 'selected, waiting'; the app's word for it", waitInUse.view?.accessibilityValue() as? String == "selected, waiting"
      && (MenuAccountRowView.item(MenuAccountRow(address: short, inUse: false, waiting: true),
                                  words: MenuRowWords(fiveHour: "5h", week: "Week", full: "full", waiting: "busy"), blur: true) {})
         .view?.accessibilityValue() as? String == "busy")
check("waiting: a plain row says nothing extra", view(short).accessibilityValue() == nil)
let addWait = MenuAccountRowView.item(.add("Add an account…", note: "Signing in…", enabled: false, waiting: true), blur: true) {}
let addWaitView = addWait.view as! MenuAccountRowView
check("add: waiting with a note: the second line, 'waiting' to VoiceOver, still no address and no action",
      addWaitView.secondLine == "Signing in…" && addWaitView.accessibilityValue() as? String == "waiting"
      && addWaitView.accessibilityLabel() == "Add an account…, Signing in…" && addWaitView.room == 0 && addWait.action == nil
      && addWaitView.height == view(short, note: "x").height, addWaitView.accessibilityLabel() ?? "")
let emptyAccount = MenuAccountRowView(row: MenuAccountRow(address: "", inUse: false), pick: {})
emptyAccount.blur = true
check("add: only `add` makes an address-less row: an account row with an empty address still draws and says the stand-in",
      !emptyAccount.row.isAdd && emptyAccount.drawnAddress == AddressText.standIn && emptyAccount.title == "hidden address"
      && emptyAccount.room == s13.room)

print("menurows: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
