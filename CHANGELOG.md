# Changelog

All notable changes to cl_audit are listed here, newest first.

cl_audit uses calendar versions, `YY.M.R` (see README ▸ Versioning): the year and month of the
release date, then a counter within that month. The number can't signal a breaking change, so read
the notes before updating.

## Unreleased

- **Refresh key:** while the numbers update, its arrow itself lights up green and pulses, like an LED.

## 26.10.5 — 2026-10-25

- **Trying Dock icon styles is calm:** while a profile's Dock icon runs, its tile shows a new style, colour or
  frame at once, and nothing restarts; the closed-app picture and the Dock tile are brought up to date when it
  quits.
- **Refresh key:** while the numbers update, its arrow becomes a pulsing green LED.
- **Dashboard while starting:** Usage history says "Reading the session files…" until the first scan is done,
  instead of "No profile selected".
- **Fixed:** turning Show in the Dock on for a running Dock icon that had never been in the Dock was undone at
  once.
- **Fixed:** Settings could save an older copy of the profiles over changes made elsewhere (a Dock icon's own
  menu, Show in the Dock following the Dock); saves now keep those changes.

## 26.10.4 — 2026-10-25

- **Dock icons keep their look when closed:** a profile's Dock icon now looks the same while its app isn't
  running as while it runs, in the profile's own style, colour and frame (only the numbers and the Claude open
  dot are missing). Before, a closed Dock icon always showed Two numbers, with the colour and frame from the
  last Apply. Changing the style, colour or frame redraws it a moment after the last click; a pinned Dock icon
  then gets a fresh place in the Dock and the Dock restarts once, since the Dock otherwise keeps the old picture.
- **Icon preview:** Settings ▸ Icon ▸ Preview starts with the Dock icon as it looks while not running.

## 26.10.3 — 2026-10-25

- **App icon:** cl_audit has its own icon, no longer the same tile as the profiles' Dock icons, so it stands
  apart in the Dock. Six designs in General settings ▸ App icon: Front panel (the default), Stack, VU meter,
  Level meter, Knob and Monogram. Choosing Front panel opens its own choices under it, as in a profile's Icon
  settings: the plate (grey, grey with a lit frame, or orange), the display (cyan, bluish, orange, or green → red
  levels), the keys (classic, graphite, strip, round, plate-coloured, wide) and the slot (lit, light, dark). The
  chosen icon shows while cl_audit runs; while it's closed, the Dock shows the plain Front panel. Profile Dock
  icons don't change.

## 26.10.2 — 2026-10-25

- **Faces:** the cl_audit window now looks like the home site's hi-fi front panel, in three faces chosen in
  General settings ▸ Face: Std (dark, the default), Black and Silver (light). Buttons are keys, pickers are
  tracks with the chosen item raised, switches are keys with an LED, and status lines sit in glowing display
  windows. Std and Black keep the window dark and Silver light, whatever the Mac's appearance. The Dock icons
  and their panels don't change.
- **Show in the Dock follows the Dock:** drag a profile's Dock icon out of the Dock and its switch turns off
  (the icon keeps running in the background); keep it in the Dock by hand and the switch turns on. On means
  pinned, so the icon is there even while stopped. "Keep the Dock in order" no longer pins hidden icons.
- Clicking cl_audit's own Dock icon with its window open: behind other windows, the window comes to the front
  on the page it was showing; already in front, it goes to the Dashboard (it always went to the Dashboard).
- Hidden from the Dock, a profile's **Icon** and **Dock icon clicks** cards are faded and locked, each with a
  Show in the Dock key: nothing in the Dock to see or click. Everything about the running Dock icon app
  (Open at login, Opening and closing, updates and alerts) stays as it is.
- **Claude window** is no longer a setting: the profile using `~/.claude` opens the usual Claude app, every
  other profile its own Claude window. "None (Terminal only)" is gone; a profile set that way gets its own
  window.
- **Renew sign-in** (was Renew if expired) explains what it does: Claude Code swaps its short-lived access key
  when it runs, so the Dock icon runs it once with a tiny prompt when the key has run out.
- The window's top strip: on the dashboard, which profiles it shows and the last update with a refresh
  key; in Settings, whether everything is saved.
- No more Apply: a profile's name or icon label is saved when you press Return or click elsewhere (Esc puts
  it back), and its Dock icon app is renamed then.
- Release notes and the README say which Claude Code and Claude app versions a release was checked with
  (now Claude Code 2.1.310 and the Claude app 3.6556.2): a newer Claude version can change how Claude
  Code saves its login or the usage figures.

## 26.10.1 — 2026-10-24

- **Direct download:** each release now has a ready-built `cl_audit.zip` on its GitHub Release, and
  <https://github.com/n-uf/cl_audit/releases/latest/download/cl_audit.zip> always gets the newest.
  It isn't signed with an Apple Developer ID yet: the first time, allow it in System Settings ▸
  Privacy & Security ▸ Open Anyway. The Dock icon apps it makes for your profiles open without asking.
- Settings: changing a setting that has no picture of its own (Renew if expired, Claude window, Data
  folder, Folder, Refresh every, Notify at, Click, Show usage for, Press and hold, Show in the Dock,
  Open at login, Show emails) shows a short note at the bottom of the page saying what it now does.
  It floats over the page, so nothing moves, and closes after 6 s or with ×.

## 26.10.0 — 2026-10-24

First calendar-versioned release; earlier builds called themselves 0.2.

### Profiles
- A profile is one Claude setup: its Claude Code folder and sign-in, its Claude window and its
  Dock icon. "Account" now means only the claude.ai account it is signed in to.
- Add profile: a new or existing folder, sign in to Claude Code, then the Claude app; one profile
  per folder and window. Remove profile cleans up everything it installed, and can delete its folders.
- Ten profile colours.

### Dashboard
- Each card has two switches: **Claude window** (open or quit it) and **Dock icon** (start or quit
  it; pins are never touched, so the Dock is not restarted). A missing Dock icon gets Reinstall.
- A flipped switch stays put with a spinner until the change is done; quitting a window that
  Claude asks about shows "Claude is asking" with Show; a window that doesn't open offers Retry.
- Changes from Opening and closing are announced: "quits in 8 s", "waits for the window".
- Chart filters sit next to the period switch.

### Profile settings
- **Dock icon:** Show in the Dock (hiding restarts the Dock), Open at login, and what it is
  doing now, with Pin when it isn't pinned.
- **Opening and closing:** two questions decide whether the Dock icon follows the Claude window,
  the window follows the Dock icon, both or neither; a table shows what each action then does.
- **Claude open dot:** an orange dot on the icon while the profile's Claude window is open.
- Controls sit next to their labels in column-wide cards, with previews of what they change;
  every (i) opens a short explanation.

### Dock
- General settings ▸ Dock can keep the cl_audit icons together and at most one Claude pin
  (experimental: it rewrites the Dock).

### Fixes
- 100% fits inside every icon style.
- The panel preview card grows with taller designs (Pace, Segments).
- Claude windows are matched to profiles by their exact data folder.
- No more crash loop while the app draws, or crash on launch with a very wide card grid.
