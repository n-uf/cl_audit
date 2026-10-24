# cl_audit

Usage audit for all your Claude accounts: Dock icons that show Claude plan usage, one icon per account. Each icon shows how much of the
5-hour and weekly limits is used, and a click opens that account's Claude desktop window.

## Install

```bash
./build.sh              # build "cl_audit", install it into /Applications, update the icons
./build.sh --no-install # build into ./build only
```

Open **cl_audit** and add your accounts. **Apply** saves the list and creates one
"cl_audit &lt;name&gt;" icon app per account in `/Applications`, where Spotlight finds them. Drag them into the Dock and choose
Options ▸ Keep in Dock.

## Settings

Settings is a page of the same cl_audit window as the dashboard (switch at the top, or ⌘,).
The accounts run across the top (＋ adds one, right-click removes); the selected account's settings
sit below in compact cards. Changes are saved as you make them and the icons follow at once; only new
names, labels or accounts need **Apply**, because that installs or renames icon apps.

**Show emails** (right of the account strip in Settings): turn it off for screen sharing and screenshots. Email
addresses are then left out of the launcher, dashboard, panels and Dock menus; Settings still shows
them blurred (hover one to see it).

**Adding an account** (＋): in a wide window, three columns: the account and its window, the Claude Code
folder, and a summary with the live icon and five numbered steps. Narrower, one column with a progress strip
on top and the next action pinned at the bottom; each check sits under the field it's about, and one button
does the next step (Create/Connect, Sign in…, Finish). Each choice says what it means (New or Existing folder; its own, the standard or no Claude window), and the chosen one opens its details. The standard window is offered only while no other account uses it, and only folders the account can take are listed (the others are named underneath with whose they are). The icon label comes from the name; change it later in Settings.
- **Where it lives:** a *new* Claude Code folder (`~/.claude-<name>`, optionally linking instructions, agents,
  skills, commands or memory from `~/.claude` or another Claude Code folder), or an *existing* one: any Claude Code folder on this Mac,
  the default `~/.claude` too, or one you pick in Finder (a Claude Code folder, or an empty one).
- **Its Claude window:** the standard window, a separate one with its own sign-in and data folder, or none.
- **One account per folder and per window.** Folders are compared after resolving `~`, links and letter
  case; a folder inside (or around) another account's folder counts as the same. Folders and windows
  another account uses are shown as such and can't be picked; the line under the field says why. A sign-in that
  another account also uses is only a warning (both icons would show the same usage).
- **Quit the desktop app first.** Until the folder is created or connected, the Claude desktop app must be closed:
  while open it writes its sign-in and settings. Step 1 lists its windows (and their Code tab sessions), checking
  every 2 s, with Quit the desktop app and Check again. Claude Code in Terminal doesn't get in the way and isn't
  listed. Once the folder exists, the desktop app can stay open.
- **Sign in, in two parts.** a · Claude Code: Terminal runs `claude auth login` for the folder. b · Desktop app
  (only with its own Claude window): open that window and sign in to the same claude.ai account; the page checks
  every 2 s that the window is signed in and that its account id matches Claude Code's (no email or token is
  read). One button does the next part; "Finish now" leaves sign-in for later.
- **Cancel** undoes only what the setup created: an existing folder is never deleted or signed out.

**Managing the Dock** (Settings ▸ Dashboard ▸ Dock, off by default; experimental, invasive and error-prone: it rewrites the Dock's pin list and restarts the Dock, and macOS can misplace or drop pins). macOS ties running Claude windows to Claude
pins in its own order, so several Claude pins get mixed up between windows; the cl_audit icons are the reliable way
to reach each account's window. When on, cl_audit keeps its icons pinned together in account order (the cl_audit
app last) and keeps one Claude pin before them (or none), and redoes it after accounts are added, removed or
renamed. Other apps keep their places. Only the Dock's pin list changes, the Dock restarts once and only when
something differs, and the list is saved before the first change ("Restore my Dock"). A cl_audit icon you removed
from the Dock comes back with "Arrange Dock"; without the setting, use Options ▸ Keep in Dock or drag it from /Applications.

**Removing an account** (Settings ▸ account ▸ Remove account…, or right-click its tile) always removes its
Dock icon app and what macOS keeps for it: the open-at-login entry, preferences, caches, network storage,
saved window state, its pin and recent-apps entry in the Dock (only that exact app; the Dock restarts only if one was there) and its Launch Services record, plus its saved usage, Terminal scripts
and place on the dashboard. **Delete its folders too** also signs its Claude Code folder out (its Keychain
login goes) and deletes that folder and its Claude window's data folder; links inside are removed, never what
they point to. The default `~/.claude`, the standard window, and a folder another account shares items from
are never deleted, and Claude using the folders must be closed first. Each sync also cleans up leftovers of
accounts removed by older versions.

**Settings layout.** Every row keeps its control right next to the label; wide controls (card style, panel design,
colours) sit under their label. Cards are at most one column wide: three columns from about 1180 pt, two from 800,
one below. An account has five cards: Account, Claude Code and window, Icon, Clicking and panels, Updates and
alerts. The Dock card always shows your pinned apps with their real icons (the ones cl_audit looks after outlined), and,
when the Dock doesn't match its settings, the Dock now and after "Arrange Dock"; some (i) explanations include a small picture.

**Dashboard settings** (Settings ▸ Dashboard): one card style for every account card on the dashboard (Glow, Rings,
Numbers, Segments or Pace; each account's own panel design is for its panels), and the Dock. The history period
(24 h / 7 d / 30 d) and which charts to show ("Show" chips) are filters on the dashboard itself, kept between
launches. Cards in a row always share one height, with their buttons lined up at the bottom.

The same rules apply in Settings: the Folder, Claude window and Data folder menus mark what other accounts
use, and the account bar refuses to apply two accounts sharing a folder or a window.

- **Name** and **icon label** (up to 6 letters, drawn on the icon).
- **Colour**: the account's own colour in the launcher, the dashboard (chips, cards, charts) and the
  panels. The icon has its own colour setting.
- **Claude Code settings folder**: `~/.claude` or a `CLAUDE_CONFIG_DIR` folder. The window lists the
  folders it finds and the account each is set up for, and shows which login the icon actually found.
- **Clicking the icon**: what a click does (show usage briefly for N seconds while Claude opens,
  just open Claude, or show the details panel), and which Claude window opens: the standard one,
  a separate one with its own sign-in (`--user-data-dir`), or none.
- **Icon**: style, account colour, frame colour (none by default), refresh interval, notification
  threshold, open at login. Each style is previewed in one row from good to bad usage:
  - Two numbers, Rings (outer = 5-hour, inner = week), Big number;
  - matching the panel designs: Twin rings, Segmented, Pace bars (a white tick for how much of
    the window has passed);
  - status styles, where colours follow the levels and the week has its own colour: Status tile,
    Gauge, Worst of two, Status + week bar, Number + bars, Batteries, Gauge + week bar.
- **Renew an expired login automatically** (opt-in) and **Log in…** for a missing, expired or
  mismatched login.

The list is saved on this Mac only, in
`~/Library/Application Support/usage-n-uf/accounts.json` (format: `accounts.example.json`).
## The cl_audit app

Opening **cl_audit** shows the dashboard: a card per account (its icon, both limits, Desktop and
Terminal buttons, Log in… when needed) and a summary (closest to a limit, most room, next reset).
It stays in the Dock as a launcher:

| On the cl_audit icon | What happens |
|---|---|
| Click | The launcher palette: every account with its icon and mini bars; ↑↓, ↩ desktop, ⌘↩ terminal, ⌘1–9, type to filter |
| Press and hold | The dashboard |
| Right-click | Open Claude for any account, Dashboard, Launcher, Settings… |

The dashboard also shows **Usage history** (24 h / 7 d / 30 d), read from the session files Claude Code
writes on this Mac (only time, model, token counts, project folder and surface of each reply):
when you use Claude (hours × days, coloured by account), tokens per day per account, and where they go
(by project, model and surface). Usage from claude.ai chats, other computers or cloud sessions isn't there.

Clicking an account's icon in the palette or on a card opens Claude for that account. Settings: the gear,
⌘, or Settings… in any menu. Both screens read the numbers the icon apps save, so they need no login.

## Clicking an account icon

| Action | What happens |
|---|---|
| Click | The account's click action (by default a compact usage panel for 3 s while Claude opens) |
| Double-click or ⌥-click | The full details panel: both limits with bars and reset times, the login, Open Claude / Log in / Refresh / Settings |
| Press and hold | Experimental, per account: the details panel next to a short Dock menu |
| Right-click | The menu: numbers, reset times, login, Options, Settings… |

Press and hold has no event of its own: the Dock asks the app for its menu on both right-click and
press-and-hold, and the icon checks which mouse button is down at that moment.

## How it works

- **Numbers:** every few minutes the icon asks Anthropic's usage endpoint
  (`api.anthropic.com/api/oauth/usage`), using the account's existing Claude Code login.
  The login is read from the macOS Keychain, read-only: it is never refreshed, written, logged or sent
  anywhere else. It is read with `/usr/bin/security`, the way Claude Code reads it: Claude Code stores the
  item through that tool, so the item already trusts it. No prompt appears and the icons get no Keychain
  permission of their own (reading through the Keychain API needed "Always Allow", which macOS forgets
  every time Claude Code re-saves a renewed login). The login is kept in memory and read again only
  when it has expired or was refused.
- **Which login:** Claude Code names its Keychain item after the settings folder. The default
  `~/.claude` uses `Claude Code-credentials`; a `CLAUDE_CONFIG_DIR` folder uses
  `Claude Code-credentials-<first 8 hex of SHA-256 of the folder path>`.
- **Account check:** the icon looks up which e-mail its login belongs to and compares it with the
  account the folder is set up for (`oauthAccount` in its `.claude.json`). On a mismatch it shows a
  red "!", and the window and menu say how to fix it.
- **Fallback:** `statusline/usage-statusline.sh` is a Claude Code status line script that writes
  `<settings folder>/usage.json` after every reply in terminal sessions. The icon uses that file
  when the endpoint can't be reached. The desktop app's Code tab doesn't run status lines.
  To use it, add to the folder's `settings.json`:
  `{ "statusLine": { "type": "command", "command": "~/.claude/bin/usage-statusline.sh" } }`
- **One app per icon:** macOS gives each running app one Dock icon, so every account gets its own copy
  of the app (same binary, its own bundle id and `UsageAccountID`), signed ad hoc.

`build/UsageDock --render-preview out.png STYLE LABEL 23 41 [COLOR [FRAME]]` renders a sample icon
(STYLE is one of bars, rings, number, statusTile, gauge, worst, statusBar, thinBars, batteries, gaugeBar).

The usage endpoint is not publicly documented and may change.

---

cl_audit is an independent tool. It is not affiliated with, endorsed by or sponsored by Anthropic.
"Claude" is a trademark of Anthropic.
