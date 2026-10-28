# Changelog

All notable changes to cl_audit are listed here, newest first.

cl_audit uses calendar versions, `YY.M.R` (see README ▸ Versioning): the year and month of the
release date, then a counter within that month. The number can't signal a breaking change, so read
the notes before updating.

## Unreleased

- **When a limit is full, when it's back.** While a limit is at 100%, the profile's card shows the limits on the
  left and one box on the right for the full limit that holds it back: "5-hour full", how long until it's back
  ("in 1h 42m", updated as it goes) and when ("back at 15:28", or "back Thu 09:00", "back 11 Nov"). "Reset time
  unknown" when Anthropic doesn't say. The details panel has the same box, the launcher the countdown, the Dock
  menu both times, and the Dock icon becomes the countdown with a red frame. With nothing full, nothing changes.
  At the reset the agent reads the profile again at once.
- **Alerts:** the "limit full" alert says when it's back. New, per profile, on by default: **Notify when back**,
  one alert when a full limit resets ("Claude Work is back").
- **One background agent reads every profile's usage.** A helper inside cl_audit, its one background item,
  reads the usage, checks the account, renews the sign-in and sends every alert, for all profiles, whatever
  is open, quit or hidden. Quitting a Dock icon or a Claude window never stops a profile's usage or alerts
  any more. macOS starts the agent at login and again if it crashes; updates restart it with no new prompt.
  Alerts now come from cl_audit itself, so macOS asks once, when you open cl_audit (System Settings ▸
  Notifications ▸ cl_audit); the old per-profile entries there can be removed.
- **Dock icons only show.** A Dock icon draws what the agent saved and asks it for Refresh now and Renew login;
  it no longer reads the Keychain or the network. Usage in the Dock off quits the icon, unpins it and removes its
  app with what macOS keeps for it (no hidden app any more); turn it back on and it's installed again in the
  same place in the Dock, with its look and click settings. A usage only profile installs nothing at all.
  Apps older versions kept for profiles with Usage in the Dock off are removed once.
- **Opening and closing, simplified:** **Dock icon runs** At login, With its window or When started, and one
  switch, **Claude window opens and quits with the Dock icon**. The agent runs these, whether or not cl_audit
  is open (before, "start the Dock icon with its window" needed cl_audit running). Old settings carry over:
  Open at login on → At login; "start or quit the Dock icon too" → With its window; both off → When started;
  "open or quit the Claude window too" → the window switch.
- **One display in the dashboard's top strip:** the profile keys, one display and the refresh key. It shows one
  thing at a time, most important first: the agent won't start (red, with the numbers' age), starting the agent,
  paused after crashes, updating, a profile Anthropic didn't answer for, or "Updated · 2 min ago". No Start key:
  cl_audit starts its agent itself when its window opens and whenever it has been silent for 90 s, and the
  refresh key always works.
- **General settings, grouped:** column 1 is the app: Usage in the background (new: is usage being read, do alerts
  reach you, when it last read; the dashboard's red display opens it) and About (with the clean-up's last run and an
  Uninstall key). Column 2 is what you see: Emails, Face, Dashboard cards. Column 3 is the Dock: App icon (now one
  row of designs with Front panel's choices under it) and Dock. Every value starts on the same line and every row
  is one line, also in the narrowest column.
- **Settings columns** grow to their full width as the window widens; before, they dropped back to the narrowest
  width once a fourth column would have fit.
- **New profile:** a new profile's Dock icon is put in the Dock (it could otherwise be taken for one dragged
  out, and switched off). **Start reading usage** (Usage in the Dock off) installs nothing.
- **Fixed:** an alert could come again for the same limit and reset, because Anthropic's reset time differs by
  a fraction of a second between replies.
- **Fixed:** the details panel's content sat off to the left and stopped short on the right (its bottom row was
  wider than the panel). Every row now has the same inset on all sides, in every panel design and face; when
  room is short, "Updated 3 min ago" becomes "3 min ago".
- **Clean-up of older installs, once:** each Dock icon's own login item, and the hidden apps of usage only
  profiles.
- **Automatic clean-up:** the agent tidies up at login, after every change and every 6 hours: Dock icon apps no
  profile wants, second copies, what macOS keeps for them (now in all six places), saved usage of removed profiles,
  Dock pins of apps that are gone and old Terminal scripts. Only what is provably cl_audit's; never a Claude Code
  folder, a Claude window's data or a sign-in. General settings shows the last run.
- **Uninstall cl_audit…** (Settings ▸ General, the cl_audit menu, or `UsageDock --uninstall`): removes everything
  cl_audit made and moves it to the Trash; per profile you choose whether its folders go too. Dragged to the Trash
  instead, cl_audit offers once to remove its Dock icons, agent and settings.
- **Fixed:** restarting the agent could hang (launchctl waits for ever on a job that couldn't start).

## 26.10.10 — 2026-10-26

- **Fixed:** with Usage in the Dock off, quitting a profile's Claude window could quit its background app too
  (when Opening and closing linked the two), so its usage and alerts stopped until it was started again. With
  Usage in the Dock off a profile now always starts at login and its Claude window opens and quits on its own;
  the Opening and closing card fades whole under "Not in use · no Dock icon" with a **Show in the Dock** key.
  The saved choices are kept and apply again once the Dock icon is back.

## 26.10.9 — 2026-10-26

- **New profile without a Claude window:** no "Quit the desktop app" step. With Claude window off the only new
  folder is the Claude Code folder, which the desktop app never writes, so the open app no longer holds up
  Create; the remaining steps are numbered on from 1. With a Claude window the step is as before.

## 26.10.8 — 2026-10-26

- **What a profile includes:** two keys in a profile's settings, **Usage in the Dock** and **Claude window**, each
  with a line saying what the current choice does. With both off a profile is *usage only*: its usage shows on the
  dashboard, in the launcher and in alerts, with nothing in the Dock and no window. Turning either off never deletes
  anything (its app, window folder and sign-in are kept); that happens only in Remove profile. New profile has the
  same keys: without a Claude window its Claude app sign-in step drops out, and without Usage in the Dock the last
  step is **Start reading usage**, which doesn't touch the Dock.
- **No Dock icon card:** Usage in the Dock replaces Show in the Dock, **Open at login** moves to the top of Opening
  and closing, and what the profile is doing now, or the change going through, shows in the main display at the
  top ("Running · in the Dock", "Reading usage · every 2 min", "Restarting the Dock…", "Saved · Claude window off").
  Cards that don't apply fade with a strip and a key (Show in the Dock, Add Claude window).
- **Dashboard:** a usage only profile's card has no switches, just "Usage only · not in the Dock · no window"
  (with Start when it isn't reading).
- **Fixed:** after renaming a profile whose Dock icon was running, the Dock could keep the old name's icon and show
  the renamed one separately (and then switch it to hidden). The Dock put its old list back each time it restarted;
  cl_audit now restarts it so that it can't.
- **Profiles are linked to their Claude account:** each profile now records the Claude account seat (account and
  organisation) its Claude Code folder is signed in to, linked once and kept. One profile per seat: New profile
  refuses to finish when another profile already has the account it's signed in to, and a profile left out that way
  says so in its Profile card. A personal plan and a team seat on the same email are two seats.

## 26.10.7 — 2026-10-26

- **Fixed:** renaming a profile left a second Dock icon behind (the old name's, which then stayed in the Dock) and
  could switch the renamed one to hidden. A rename now moves the profile's Dock icon app to its new name and keeps
  its place in the Dock; leftover Dock entries of renamed or removed profiles are cleaned up.
- **Fixed:** changes to the Dock could be lost when several happened within seconds (the Dock put its older list
  back as it restarted), which could switch a profile's Dock icon to hidden. cl_audit now changes the Dock one change
  at a time and checks after each restart that the Dock kept it, trying again if not.
- **Unsaved name or label:** while a typed name or icon label isn't saved yet, its line turns into an amber
  hairline with "Return saves · Esc undoes" under it; Return and Esc are key caps you can also click. The label
  stays level with the typed text. When it can't be saved, the line and the reason (such as "Another profile is
  called “Work”") are red.
- **Fixed:** typing a profile's name or icon label and switching to another profile's tab before pressing Return
  showed the typed text in the other profile's field, where Return would have saved it to that profile. Each
  profile's settings now start fresh, and the typed text is saved to the profile it was typed for when you leave.

## 26.10.6 — 2026-10-25

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
