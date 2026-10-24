# cl_audit

Usage audit for all your Claude setups on one Mac. Each **profile** gets its own Dock icon showing how
much of its 5-hour and weekly limits is used; a click opens that profile's Claude window. The cl_audit
app adds a dashboard, a launcher and the settings.

**Claude login:** sign-in happens in Claude's own screens, so cl_audit never sees the password. It reads
Claude Code's saved login read-only and sends it only to Anthropic ([details](#how-cl_audit-handles-the-claude-login)).

Home: <https://cl-audit.n-uf.com> · Changes: [CHANGELOG.md](CHANGELOG.md) · Version: see [Versioning](#versioning)

## Install

Requires a Mac with Apple silicon, macOS 13 or later, and Claude Code. The Claude desktop app is optional
(for Claude windows).

**Download** (easiest): [cl_audit.zip](https://github.com/n-uf/cl_audit/releases/latest/download/cl_audit.zip),
the latest release, ready-built. Unzip it, move **cl_audit** to Applications and open it. cl_audit isn't
signed with an Apple Developer ID yet, so the first time macOS says it can't verify the app: open System
Settings ▸ Privacy & Security and click **Open Anyway** (once). The Dock icon apps cl_audit makes for your
profiles are created on your Mac and open without asking.

**Checked with Claude Code 2.1.310 and the Claude app 3.6556.2** (cl_audit 26.10.1). cl_audit relies on how
Claude Code saves its login and on Anthropic's usage figures, which aren't public interfaces, so a newer
Claude version can change them. If something stops working after a Claude update, update cl_audit. Each
release's notes list the versions it was checked with.

**Or build it from source**, to read every line before it runs (needs the Xcode Command Line Tools,
`xcode-select --install`):

```bash
git clone https://github.com/n-uf/cl_audit.git
cd cl_audit
git checkout v26.10.1     # optional: exactly a released version (see CHANGELOG.md)
./build.sh                # build cl_audit, install it into /Applications, update the Dock icon apps
./build.sh --no-install   # build into ./build only
```

Then open **cl_audit**, go to Settings and add a profile (**New profile**). cl_audit installs one
"cl_audit &lt;profile&gt;" app per profile in `/Applications` and starts it; drag it into the Dock (or let
General settings ▸ Dock pin it for you). To update, download the new zip (or pull and run `./build.sh`
again); profiles and settings are kept.

## How cl_audit handles the Claude login

**You sign in with Claude's own sign-in, never with cl_audit.** Claude Code's sign-in (`claude auth login`
in Terminal) and the Claude app's sign-in window are Anthropic's. cl_audit only opens them. Everything you
type to sign in goes straight to Anthropic; cl_audit never sees it.

**What cl_audit reads, and how.** Claude Code saves its login in your macOS Keychain, in an item called
`Claude Code-credentials` (`Claude Code-credentials-<8 characters>` for a profile's own Claude Code folder).
cl_audit reads that item with Apple's `/usr/bin/security` tool, read-only, exactly the way Claude Code reads
it. It asks for no Keychain permission; macOS shows no prompt because the item already trusts that tool.
It keeps only the short-lived access token, in memory, and discards the rest (including the long-lived
renewal token). It never writes, renews, copies or logs your login. On your Mac only, it also reads the
account email in Claude Code's settings file (`.claude.json`) and, for the usage history, Claude Code's
session logs (only time, model, token counts, project folder and surface of each reply).

**Where it goes: only to Anthropic.** cl_audit uses the token for two requests to Anthropic's own server:
`api.anthropic.com/api/oauth/usage` (your 5-hour and weekly figures) and `api.anthropic.com/api/oauth/profile`
(which account a profile is signed in to). There is no cl_audit server, no analytics and no sign-up, and
nothing else goes over the network. **Renew if expired** (off by default) runs one small Claude Code request
and lets Claude Code renew its own login.

**What it doesn't change.** Any app running under your macOS user can read Claude Code's saved login the
same way; that is how Claude Code stores it. cl_audit makes it neither safer nor more exposed, so install
only software you trust. cl_audit's code is open to check: `Login.read` in `Sources/Model.swift` and
`request` in `Sources/IconApp.swift`.

## Words used here

- **Profile:** one Claude setup in cl_audit: its Claude Code folder and sign-in, its Claude window and its
  Dock icon. **Account** means only the claude.ai account a profile is signed in to; several profiles
  can use one account.
- **Dock icon:** the profile's own small app ("cl_audit &lt;profile&gt;") that shows its usage.
- **Claude window:** the profile's running Claude desktop app: the standard one, or a separate one with its
  own sign-in and data folder.
- **Profile settings** (Settings ▸ a profile) and **General settings** (Settings ▸ General, app-wide).

## The dashboard

Opening **cl_audit** shows a card per profile: its icon, both limits and two switches.

- **Claude window:** open or quit the profile's Claude window.
- **Dock icon:** start or quit the profile's Dock icon app. Pins are never touched, so the Dock doesn't
  restart. While it's stopped the profile doesn't refresh or alert. A missing app shows **Reinstall**.
- A flipped switch stays where you put it, with a spinner, until the change is done. Quitting a window
  that Claude asks about (for example unsent work) shows "Claude is asking" with **Show**; a window that
  doesn't open within 30 s offers **Retry**.
- Changes made by Opening and closing are announced on the other switch: "quits in 8 s",
  "starting…", or "waits for the window" when the Dock icon stopped with its window.
- Under the limits: **Sign in…** when needed, otherwise **Open/Show window**, then **Terminal**, and "⋯"
  (Refresh now, Profile settings…).

Below the cards, **Usage history** (24 h / 7 d / 30 d) is read from the session files Claude Code writes
on this Mac (only time, model, token counts, project folder and surface of each reply): when you use
Claude, tokens per day per profile, and where they go (by project, model and surface). The period and
the **Show** chips next to it filter the charts and are kept between launches. Usage from claude.ai
chats, other computers or cloud sessions isn't there.

cl_audit stays in the Dock as a launcher:

| On the cl_audit icon | What happens |
|---|---|
| Click | The launcher palette: every profile with its icon and mini bars; ↑↓, ↩ Claude window, ⌘↩ Terminal, ⌘1–9, type to filter |
| Press and hold | The dashboard |
| Right-click | Open Claude for any profile, Dashboard, Launcher, Settings… |

## A profile's Dock icon

| Action | What happens |
|---|---|
| Click | The profile's click action; by default its usage for 3 s while its Claude window opens |
| Double-click or ⌥-click | The details panel: both limits with bars and reset times, the sign-in, Open Claude, Sign in, Refresh, Settings |
| Press and hold | The details panel next to a short Dock menu (on by default, per profile) |
| Right-click | The menu: numbers, reset times, the sign-in, and actions (Open or Show Claude window, Quit Claude window, Refresh now, Dashboard, Profile settings…, and Quit and keep Claude window when the window follows the Dock icon) |

Press and hold has no event of its own: the Dock asks the app for its menu on both right-click and
press-and-hold, and the icon checks which mouse button is down at that moment.

## Settings

Settings is a page of the same window as the dashboard (switch at the top, or ⌘,). The profiles run along
the top, with **General** first and **New profile** last. Changes are saved as you make them and the
icons follow at once; only new names, labels or profiles need **Apply**, because that installs or renames
Dock icon apps. **Show emails** (top bar) off leaves email addresses out of the launcher, dashboard,
panels and Dock menus, and blurs them in Settings (hover one to see it), for screen sharing.

Cards are at most one column wide: three columns from about 1180 pt, two from 800, one below. Controls
sit next to their labels; every (i) opens a short explanation, some with a picture. Changing a setting that
has no picture of its own shows a short note at the bottom of the page saying what it now does; it floats
over the page, so nothing moves, and closes after 6 s or with ×.

### Profile settings

- **Profile:** name, icon label (up to 6 letters, drawn on the icon), the profile's colour (launcher,
  dashboard, panels), and **Remove profile…**.
- **Claude Code and window:** the Claude Code folder (`~/.claude` or a `CLAUDE_CONFIG_DIR` folder) and the
  sign-in found there; **Renew if expired** (opt-in); which **Claude window** opens (standard, separate
  with its own sign-in and data folder, or none) and its data folder. Folders and windows other profiles
  use are marked and can't be picked; two profiles can't share a folder or a window.
- **Updates and alerts:** how often to refresh, and a notification when a limit reaches a set level.
- **Clicking and panels:** what a click does (usage for N seconds while Claude opens, just open Claude,
  or the details panel), press and hold, and the panel design (Glow, Rings, Numbers, Segments, Pace),
  previewed at full size.
- **Icon:** the style, previewed as the limit fills up:
  - classic: Two numbers, Rings (outer = 5-hour, inner = week), Big number;
  - like the panels: Twin rings, Segmented, Pace bars (a white tick for how much of the window has passed);
  - status colours, where colours follow the levels: Tile, Gauge, Worst, Tile + bar, Bars, Batteries,
    Gauge + bar.

  Then the icon's colour, an optional frame colour and the **Claude open dot**: none, or a Claude-orange
  dot at the top-left while the profile's Claude window is open.
- **Dock icon:** **Show in the Dock** (off: it runs without a Dock tile and still refreshes and alerts;
  changing it restarts the Dock, because the pin is taken out or put back), **Open at login**, and what
  it's doing **Now**, with **Pin** when it runs unpinned.
- **Opening and closing** (with a Claude window): two questions. When the Claude window opens or quits,
  start or quit the Dock icon too (it quits 10 s after the window; starting needs cl_audit running)? When
  the Dock icon starts or quits, open or quit the Claude window too (not at login; a normal quit, so
  Claude can ask about unsent work)? A table shows what each of the four actions then does. With the
  window following, the Dock icon's menu has **Quit and keep Claude window**.

### General settings

- **Dashboard cards:** one card style for every profile (Glow, Rings, Numbers, Segments or Pace).
- **Emails:** Show emails.
- **About:** the version and build, and a link to what's new.
- **Dock** (off by default; experimental and invasive: it rewrites the Dock's pin list and restarts the
  Dock, and macOS can misplace or drop pins). macOS ties running Claude windows to Claude pins in its own
  order, so several Claude pins get mixed up; the Dock icons are the reliable way to reach each profile's
  window. When on, cl_audit keeps its Dock icons pinned together in profile order (the cl_audit app last)
  with one Claude pin before them (or none), and redoes it after profiles are added, removed or renamed.
  Other apps keep their places. The card pictures your Dock with the changes marked; **Arrange Dock**
  applies them, and **Restore my Dock** puts back the pins saved before the first change.

### Adding a profile

**New profile** opens a page: in a wide window three columns (the profile and its window, the Claude Code
folder, a summary with the live icon and numbered steps); narrower, one column with the next step pinned
at the bottom.

- **Where it lives:** a *new* Claude Code folder (`~/.claude-<name>`, optionally sharing instructions,
  agents, skills, commands or memory from another Claude Code folder), or an *existing* one, including
  `~/.claude` or one you pick in Finder. Folders are compared after resolving `~`, links and letter case;
  a folder inside or around another profile's folder counts as the same.
- **Its Claude window:** the standard one (only while no other profile uses it), a separate one, or none.
- **Quit the Claude app first,** until the folder is created or connected: while open it writes its
  sign-in and settings. The page lists its windows, checking every 2 s, with Quit and Check again.
  Claude Code in Terminal doesn't get in the way.
- **Sign in, in two parts:** Claude Code (Terminal runs `claude auth login` for the folder), then, with a
  separate window, that window, signed in to the same claude.ai account (checked by account id; no email
  or token is read). "Finish now" leaves sign-in for later.
- New profiles start with an existing profile's click and panel settings. **Cancel** undoes only what
  the page created: an existing folder is never deleted or signed out.

### Removing a profile

**Remove profile…** (profile settings, or right-click its tile) removes its Dock icon app and what macOS
keeps for it: the open-at-login entry, preferences, caches, saved window state, its pin and recent-apps
entry in the Dock (the Dock restarts only if one was there) and its Launch Services record, plus its saved
usage, Terminal scripts and place on the dashboard. **Delete its folders too** also signs its Claude Code
folder out (its Keychain login goes) and deletes that folder and its Claude window's data folder; links
inside are removed, never what they point to. The default `~/.claude`, the standard window and a folder
another profile shares items from are never deleted, and Claude must be closed first.

Profiles are saved on this Mac only, in `~/Library/Application Support/usage-n-uf/accounts.json`
(format: `accounts.example.json`). When cl_audit starts it reinstalls missing Dock icon apps and starts
the ones that should run.

## How it works

- **Numbers:** every few minutes each Dock icon asks Anthropic's usage endpoint with the profile's
  Claude Code login (see [How cl_audit handles the Claude login](#how-cl_audit-handles-the-claude-login)). The login is kept in memory and read
  again only when it has expired or was refused.
- **Which login:** Claude Code names its Keychain item after the settings folder. The default
  `~/.claude` uses `Claude Code-credentials`; a `CLAUDE_CONFIG_DIR` folder uses
  `Claude Code-credentials-<first 8 hex of SHA-256 of the folder path>`.
- **Account check:** the icon looks up which email its login belongs to and compares it with the account
  the folder is set up for (`oauthAccount` in its `.claude.json`). On a mismatch it shows a red "!", and
  the panel and menu say how to fix it.
- **Which Claude window:** running Claude apps are matched to profiles by their exact `--user-data-dir`,
  read from the process arguments (no `ps`); the standard window is the one without it.
- **Fallback:** `statusline/usage-statusline.sh` is a Claude Code status line script that writes
  `<settings folder>/usage.json` after every reply in Terminal sessions. The icon uses that file when the
  endpoint can't be reached. The Claude app's Code tab doesn't run status lines. To use it, add to the
  folder's `settings.json`:
  `{ "statusLine": { "type": "command", "command": "~/.claude/bin/usage-statusline.sh" } }`
- **One app per Dock icon:** macOS gives each running app one Dock icon, so every profile gets its own
  copy of the app (same binary, its own bundle id and `UsageAccountID`), signed ad hoc.

`build/UsageDock --render-preview out.png STYLE LABEL 23 41 [COLOR [FRAME]]` renders a sample icon (STYLE
is one of bars, rings, twinRings, number, segmented, pace, statusTile, gauge, worst, statusBar, thinBars,
batteries, gaugeBar).

The usage endpoint is not publicly documented and may change.

## Versioning

cl_audit uses calendar versions, `YY.M.R`, like the other n-uf projects:

- `YY` is the year of the release date (`26` for 2026).
- `M` is the month of the release date, without a leading zero: a release made in October 2026 is
  `26.10.x`, never "the last month + 1".
- `R` counts releases within that month and starts again at `0` in a new month.

The number lives in `VERSION`; `build.sh` puts it in the app (General settings ▸ About), with the commit
count as the build number. Changes go into [CHANGELOG.md](CHANGELOG.md) under "Unreleased" as they land.
To release:

- `scripts/release.sh --dry-run` prints the next version.
- `scripts/release.sh --push` bumps `VERSION`, turns the Unreleased notes into the release's section,
  commits `release X`, tags `vX`, pushes both and publishes the GitHub Release with a ready-built
  `cl_audit.zip` (the download link above always gets the newest). Without `--push` it stops before
  pushing; `--nobump` keeps the current number.

A version can't signal a breaking change, so read the notes before updating.

## License

[PolyForm Perimeter 1.0.1](LICENSE): source-available. You may use, change and share it, but not to
build a product that competes with cl_audit.

---

cl_audit is an independent tool. It is not affiliated with, endorsed by or sponsored by Anthropic.
"Claude" is a trademark of Anthropic.
