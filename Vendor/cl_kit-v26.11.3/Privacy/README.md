# AddressPrivacy

Hiding an account address on screen, shared by cl_quick and cl_audit. Self-contained: it imports no other module of ours (not
even ProfileCore), Swift 5 language mode, macOS 13. Built from cl_kit, vendored by cl_audit and cl_quick; it came from
cl_quick's `Shared/AddressPrivacy/`.

One rule: **a hidden address is never the real address under a blur, a mask or a first letter.** A Gaussian blur over the real
text keeps its length and letter shapes (a screenshot gives them back by trying candidates); a mask like `y•••@example.com`
keeps the first letter, a length band and the domain. What is drawn instead is one fixed stand-in
(`abcdefghijkl@mnopqrst.com`, blurred where a context can blur), and what goes in a sentence is the fixed words
`hidden address`: the same for every address, never made from one (no letter, no length, no hash, no domain). The real
address appears only on an explicit reveal: the pointer on it, a "peek" the app asks for, or the app's setting turned off.

Built by `scripts/modules.sh` (`kit_build_privacy`) as its own static library (`libAddressPrivacy.a`, module
`AddressPrivacy`): Foundation, AppKit, CoreImage, Combine and SwiftUI only. `Checks/run.sh addressprivacy` is its own suite (in
CI); the apps' suites check how they use it.

Files: `AddressText.swift` (Foundation only: the plain forms), `AddressSetting.swift` (an optional prefs-domain store),
`AddressState.swift` (the setting as an observable value, the hover gate), `AddressInk.swift` (AppKit drawing),
`AddressLabel.swift` (the alert's address), `AddressViews.swift` (SwiftUI).

## The setting comes in as a value

The module reads no UserDefaults key and no file of its own: each app stores its own "Blur addresses" setting and passes it in.
Two apps never share it.

```swift
AddressPrivacy.shared.apply(blur: settings.blurAddresses)      // at launch and whenever the setting changes. Nothing is written.
```

The plain functions take it as a parameter (`blur:`), so they work in any process: a WidgetKit extension, the menu bar's agent,
a Dock plug-in, an icon app.

An app that keeps the setting in a prefs domain and announces changes with a distributed notification (cl_audit: key
`showEmails` in `local.usage-n-uf`, true = shown, the older inverted `blurEmails`, the note `local.usage-n-uf.privacy-changed`)
names them, and every process reloads on the note:

```swift
let store = AddressDefaultsStore(suite: "local.usage-n-uf", key: "showEmails", valueMeansShown: true,
                                 legacyKey: "blurEmails", changeNote: "local.usage-n-uf.privacy-changed")
store.observe()                        // applies it now, and again on each change note (any process's write)
AddressPrivacy.shared.store = store    // optional: setBlur(_:) then writes it back (and posts the note)
store.blurAddresses                    // reads the domain right now: a Dock plug-in with no observable object reads on each draw
```

(A missing setting means the blur is on. Any other storage: conform a class to `AddressBlurStore`, or just call `apply(blur:)`.)

For tests, every form takes an override of the setting that reaches what is drawn and what is spoken: `blur:` on the views and
the label, the `blur:` parameter of the plain functions. A check never has to touch the machine's real setting.

## The three forms

### 1. View form (SwiftUI): the stand-in under the blur

```swift
BlurredAddress(address: a, size: 12.5)                     // the stand-in blurred; the address while the pointer is on it
BlurredAddress(address: a, revealed: peeking)              // an outside reveal (a peek; a key around it carries the pointer)
BlurredAddress(address: a, reserve: false)                 // inline in flowing text: as wide as what it draws
BlurredAddress(address: a, blur: true)                     // test override of the setting
AddressKeyLabel(title: "Try again as ", address: a)        // a button's label with an address in it
```

- Layout: the view is as wide as the **stand-in** and no wider, whatever the address (a hidden address longer than that is
  cut while revealed; a shorter one leaves room), so its length is never in a neighbour's position or in a height.
- Instant: there is no cross-fade between hidden and revealed (a recording must not catch a half-blurred frame).
- Accessibility: it is an element of its own, labelled `hidden address`; what is around it stays readable (never mask a
  container). A reveal never changes what VoiceOver says.
- A reveal ends when the hover ends, the view disappears, its text changes, the pointer is cut off (the window or the app loses
  focus, the window closes, a menu starts tracking: `AddressPrivacy.shared.hoverEnded` counts them, `AddressHoverGate` reads it).
  An app calls `AddressPrivacy.shared.endHover()` for any other case. `AddressHoverGate` also has `peek` (an outside reveal
  that the pointer and a cut-short hover leave alone) and `reset()`.

For an address piece inside a sentence of mixed text use `reserve: false` (cl_quick's `QCSentence` lays its `.address` pieces out
that way, and speaks the sentence with `hidden address` in the address's place).

### 2. Plain-string forms (Foundation only: `AddressText`)

Anything that can't blur: running text, a line, a tooltip, an alert's text, a pop-up row, a notification, an `NSStatusItem`
title, VoiceOver's words, a log. Nothing of the address is in the result while hidden.

```swift
AddressText.sentence(address: a, blur: blur)                  // "hidden address", or a when the blur is off / revealed: true
AddressText.sentence("Forget {}?", addresses: [a], blur: blur)   // fill a template's {} in order: "Forget hidden address?"
AddressText.drawn(address: a, revealed: false, blur: blur)    // the STAND-IN to draw/show where text can't blur (CGContext, widget, Dock tile)
AddressText.attributed(address: a, blur: blur, attributes: [.font: f])   // the same as NSAttributedString
AddressText.words(a, blur: blur)                              // = sentence (accessibility labels); AddressText.mask(a) is the same words
AddressText.standIn, AddressText.hidden                       // the constants
```

`AddressPrivacy.words(_:)`, `.drawn(address:revealed:)` and `.short(address:revealed:)` are the same on the shared setting.

### 3. Short names for compact rows (a menu's "Switch to …", a tab, a chip)

```swift
AddressText.short(address: a, blur: blur)     // the part before the @ when shown, "hidden address" while hidden
"Switch to \(AddressText.short(address: a, blur: blur))"
```

While hidden `short` (like `sentence`) reads "hidden address" for **every** account, so a list of rows can't be told apart by it.
An app that needs distinguishable hidden rows (cl_audit's "Switch to …" menu with several accounts) should not build them from
text: draw each row with `AddressInk` (the stand-in blurred, the real address on highlight with the pointer on the row), as
cl_quick's `QCStandbyMenuRow` does, and give the row's accessibility label `sentence` (the same words for all). Distinct
accessibility labels for hidden rows would tell the accounts apart again, which is the point of hiding them.

### Account ids

An account id (a UUID or its first characters) counts as hidden like an address: never drawn, never in accessibility, never in a
tooltip. The forms hide whatever text they are given, so pass an id through them (`AddressText.sentence(id:blur:)`), and use
`AddressText.needsHiding(_:)` (an `@`, or an id) to decide what to pass. A title that is only an id prefix is hidden too. An
id is any run of 8 or more hex-like characters (a-f, 0-9, dashes), all-letter ones included (hiding only those with a digit
would give the others away).

## Drawing in AppKit (`AddressInk`, `AddressLabel`)

A menu row's `draw(_:)`, or an `NSImage` drawing handler (a Dock tile): the address sharp while `readable`, else the stand-in
blurred (made once per colour; `reset()` on an appearance change).

```swift
let ink = AddressInk(font: .systemFont(ofSize: 11.5))
ink.draw(address: a, readable: highlighted || !blur, color: .secondaryLabelColor, x: 14, midY: bounds.midY, blur: blur)   // alignRight: true ends at x
ink.room(for: a, blur: blur)       // the room to give it: the stand-in's, whatever the address (the address's own with the blur off)
```

A readable address longer than the room is truncated with a tail ellipsis. `AddressInk.blurred(_:color:font:)` is the blur
(callers pass the stand-in, never an address); `AddressInk.blurPad` is how far it reaches.

**An address in an alert** (NSAlert text can't blur): `alert.accessoryView = AddressLabel(address: a)`. The stand-in blurred,
the address while the pointer is on it. Its frame is the stand-in's width whatever the address and the setting. It works while
the alert runs modally (the tracking area gets no enter or exit then, so the label reads the pointer's place every 50 ms in
every run loop mode, while its window is shown and key and the app active). The reveal ends when the alert closes, the window
loses focus, the app is deactivated or hidden, or a menu starts tracking, and stays ended until the pointer has left the
label. The poll stops when the label leaves its window, its window closes, or another window takes over the modal session
(a hidden app only pauses it). Its accessibility label is `hidden address` (computed on each call), and it follows a change
of the app's setting; `blur:` is a test override, and `surroundings` swaps what the poll reads (for checks).

**A menu row** (`NSMenuItem.view`): draw with an `AddressInk`; the row is "readable" while the menu highlights it
(`enclosingMenuItem?.isHighlighted`) or the blur is off. Its item's title and accessibility label come from `sentence`/`short`.

## What the checks hold, for every form

With the blur on, what each piece draws, puts in a sentence or speaks (asserted on the string, and for the views and the ink
on the pixels too) is the stand-in or `hidden address` and never any part of any sample address (local part, domain, words,
first letter, a bullet mask); two different addresses draw identically hidden; the hidden picture is not blank; revealed, or
with the blur off, it is the address; a short, a usual and a very long address leave a neighbour (a chevron) in the same place,
hidden and revealed, and no height jumps; an accessibility walk of a note and of a `Menu` label finds the address masked and
what is next to it readable (the AppKit walk is real; SwiftUI builds its accessibility tree only for an assistive client, which
a headless check has none of, so there the suite asserts the labels the views declare, and walks the tree when one is exposed);
a reveal ends on app deactivation, window resign/close and menu tracking; the setting is a value
(an instance never touches the shared one, `apply(blur:)` writes nothing, a named prefs domain reads both key senses and the
change note).

## Adopting it in another app

1. Vendor a cl_kit tag and build `Privacy/*.swift` as a static library with the copy's `scripts/modules.sh`
   (`kit_build_privacy OUT`, then link `kit_privacy_link OUT`).
2. `import AddressPrivacy`, and hand it your stored setting (`apply(blur:)`, or an `AddressDefaultsStore`).
3. Replace every place that shows an address: views by `BlurredAddress`; sentences, tooltips, alerts, pop-up rows, titles by
   `AddressText.sentence`; compact rows by `AddressText.short`; text that can't blur by `drawn`. Never `Text(address).blur(…)`,
   never a first-letter-plus-dots mask, never an `NSAttributedString` of the real address with a shadow.
4. Run the copy's `Checks/run.sh addressprivacy` in CI.
