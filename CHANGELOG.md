# Changelog

All notable changes to cl_audit are listed here, newest first.

cl_audit uses calendar versions, `YY.M.R` (see README ▸ Versioning): the year and month of the
release date, then a counter within that month. The number can't signal a breaking change, so read
the notes before updating.

## Unreleased

- Release notes and the README say which Claude Code and Claude app versions a release was checked with
  (now Claude Code 2.1.310 and the Claude app 3.6556.2): a newer Claude version can change how Claude
  Code saves its login or the usage figures.
Nothing pending.

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
