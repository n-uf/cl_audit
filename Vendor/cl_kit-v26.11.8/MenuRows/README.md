# MenuRows

One account row for a menu bar menu, shared by cl_quick and cl_audit: the account's address (through AddressPrivacy), a
compact usage line from ProfileCore's display value, and the tick for the account in use. It imports ProfileCore and
AddressPrivacy only (and Apple's Foundation and AppKit), holds no rule of its own, names no app and never logs; nothing of
ours imports it. Swift 5 language mode, macOS 13.

Built by `scripts/modules.sh` (`kit_build_menurows OUT`, after `kit_build` and `kit_build_privacy` into the same OUT; link
with `kit_menurows_link OUT` placed before the other two's flags). `Checks/run.sh menurows` is its suite (lint first).

## The row

```
  ✓ Sign Terminal in to abcdefghijkl@mnopqrst.com…        the address line: the stand-in blurred at rest
  ○ abcdefghijkl@mnopqrst.com · standby          Switch…  a dimmed standby row, lit: the hint at the right
    5h 34% · Week 12%                                     the usage line (or the app's note), smaller
```

- **The address.** Always whole. While addresses are hidden (the app's setting, `AddressPrivacy.shared.blur`) it is
  AddressPrivacy's one fixed stand-in, blurred, the same for every account, and sharp only while the menu lights the row
  **and** the pointer is on it, as the window says at that moment: only the pointer on the row reveals it (resting or
  moving); a keyboard highlight or type-ahead alone lights the row but never does, and nothing is remembered once the
  menu closes or scrolls. Its room is the stand-in's whatever the address, so nothing moves on a reveal and an address's
  length is never in the tag's position.
- **Words.** `prefix` before the address and `tag` after it (smaller), the `hint` at the right while lit, a `note` under
  it when there's no usage line: all the app's words. The app's rule is to put no address in them; while addresses are
  hidden, any word in them that is an address or an account id is drawn and spoken as `hidden address` anyway (a date such
  as 2026-11-20 is not an id; words split at any white space, the spaces kept).
- **Title and VoiceOver.** The item's title (type-ahead) and VoiceOver's label are the sentence form: `hidden address` in
  the address's place, with the prefix and tag, then the second line. The hint is VoiceOver's help. The account in use is
  the item's `.on` state, the tick before the address (in the margin by default), and "selected" to VoiceOver
  (`MenuRowWords.tick`, `.selected`).
- **The usage line.** `MenuUsageLine.of(display, words:, now:)` from a `ProfileDisplay`: each limit that shows with its
  rounded percent in its colour level (`display.level`), the 5-hour part only where the week-only rule lets it
  (`display.hasFiveHour`), a full limit holding the profile back now (`display.full(now:)`) with the countdown to its reset
  instead of the parts, grey for old numbers (`display.grey`), a number that isn't finite left out; nil when the display
  shows no numbers. The words are `MenuRowWords` (`standard`: "5h", "Week", "full", "✓", "selected"), or the app's own.
- **The standby look.** `dimmed: true` draws the row in tertiary text (it still lights and acts); `marker: .hollowLamp`
  puts a hollow lamp in the leading column. `MenuRowColumns` sets where the mark and the address stand (`standard`: the
  tick in the margin, the text at 14 pt; cl_quick's block lines its address up at 27 pt).
- **Compact.** One line, two with the usage line or a note (39 pt); a native item's highlight; no stripe on any edge.
- **Acting.** A click closes the menu, then runs `pick` in the default run-loop mode once the menu's tracking has ended;
  Return runs it at once, VoiceOver's press as a click. A disabled row (`enabled: false`) is never lit and does nothing.
- **The setting.** A menu builds its rows each time it opens, so they follow the setting. A row kept across a change calls
  `refresh()` (setting `blur` does it): the item's title, the size and the picture follow.

```swift
import MenuRows

let line = MenuUsageLine.of(display, now: now)                              // ProfileDisplay, from ProfileCore
let row = MenuAccountRow(address: "wu@example.com", inUse: true, usage: line)
menu.addItem(MenuAccountRowView.item(row) {})                               // the account in use: nothing to do

let standby = MenuAccountRow(address: "zedekiah@example.com", inUse: false, note: "Last used yesterday",
                             tag: " · standby", hint: "Switch…", dimmed: true, marker: .hollowLamp)
menu.addItem(MenuAccountRowView.item(standby, columns: MenuRowColumns(markerX: 14, addressX: 27)) { [weak self] in
    self?.openSwitch(to: standby.address)
})

let signIn = MenuAccountRow(prefix: "Sign Terminal in to ", address: "wu@example.com", inUse: false, tag: "…")
menu.addItem(MenuAccountRowView.item(signIn) { [weak self] in self?.signTerminalIn() })
```

The app keeps what is its own: which accounts are listed and in what order, its words, what a pick does, and its setting
(`AddressPrivacy.shared.apply(blur:)`). For tests and pictures every row takes `blur:` (an override of the setting) and
`highlighted` (drawn lit with the pointer on it), and `pointer(_:)` stands in for the mouse (nil: the real one).

Files: `MenuAccountRow.swift` (the model: `MenuAccountRow` with its `Marker`, `MenuRowColumns`, `MenuUsageLine`,
`MenuRowWords`; Foundation and ProfileCore), `MenuAccountRowView.swift` (the view and its menu item; AppKit,
AddressPrivacy).
