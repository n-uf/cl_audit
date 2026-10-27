# cl_audit

Usage audit for all your Claude setups on one Mac. A small background agent inside cl_audit reads how much
of each **profile**'s 5-hour and weekly limits is used and sends the alerts. Each profile can have its own
Dock icon showing its usage (a click opens that profile's Claude window). The cl_audit app adds a dashboard,
a launcher and the settings.

**Claude login:** sign-in happens in Claude's own screens, so cl_audit never sees the password. It reads
Claude Code's saved login read-only and sends it only to Anthropic ([details](#security-how-cl_audit-handles-the-claude-login)).

Home: <https://cl-audit.n-uf.com> · Changes: [CHANGELOG.md](CHANGELOG.md) · Version: see [Versioning](#versioning)

## Install

Requires a Mac with Apple silicon, macOS 13 or later, and Claude Code. The Claude desktop app is optional
(for Claude windows).

**Download** (easiest): [cl_audit.zip](https://github.com/n-uf/cl_audit/releases/latest/download/cl_audit.zip),
the latest release, ready-built. Unzip it, move **cl_audit** to Applications and open it. cl_audit isn't
signed with an Apple Developer ID yet, so the first time macOS says it can't verify the app: open System
Settings ▸ Privacy & Security and click **Open Anyway** (once). The Dock icon apps cl_audit makes for your
profiles are created on your Mac and open without asking.

**Checked with Claude Code 2.1.310 and the Claude app 3.6556.2** (cl_audit 26.10.10). cl_audit relies on how
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

Then open **cl_audit**, go to Settings and add a profile (**New profile**). With **Usage in the Dock** on,
cl_audit installs "cl_audit &lt;profile&gt;" in `/Applications` and puts it in the Dock. The first time,
macOS says cl_audit added an item that can run in the background (its agent, see [How it works](#how-it-works)),
and asks once to allow notifications for cl_audit (System Settings ▸ Notifications ▸ cl_audit, if you
missed it). To update, download the new zip (or pull and run `./build.sh` again); profiles and settings are
kept, and the agent restarts with the new version on its own.

## Security: how cl_audit handles the Claude login

**You sign in with Claude's own sign-in, never with cl_audit.** Claude Code's sign-in (`claude auth login`
in Terminal) and the Claude app's sign-in window are Anthropic's. cl_audit only opens them. Everything you
type to sign in goes straight to Anthropic; cl_audit never sees it.

**What cl_audit reads, and how.** Claude Code saves its login in your macOS Keychain, in an item called
`Claude Code-credentials` (`Claude Code-credentials-<8 characters>` for a profile's own Claude Code folder).
cl_audit reads that item with Apple's `/usr/bin/security` tool, read-only, exactly the way Claude Code reads
it. Only cl_audit's background agent reads it, one reader for every profile; the Dock icons and the cl_audit
window never do. It asks for no Keychain permission; macOS shows no prompt because the item already trusts
that tool.
It keeps only the short-lived access token, in memory, and discards the rest (including the long-lived
renewal token). It never writes, renews, copies or logs your login. On your Mac only, it also reads the
account email in Claude Code's settings file (`.claude.json`) and, for the usage history, Claude Code's
session logs (only time, model, token counts, project folder and surface of each reply).

**Where it goes: only to Anthropic.** cl_audit uses the token for two requests to Anthropic's own server:
`api.anthropic.com/api/oauth/usage` (your 5-hour and weekly figures) and `api.anthropic.com/api/oauth/profile`
(which account a profile is signed in to). There is no cl_audit server, no analytics and no sign-up, and
nothing else goes over the network. **Renew sign-in** (off by default) runs Claude Code once with a tiny prompt
when the saved access key has run out, so Claude Code fetches a fresh one itself; cl_audit never writes it.

**What it doesn't change.** Any app running under your macOS user can read Claude Code's saved login the
same way; that is how Claude Code stores it. cl_audit makes it neither safer nor more exposed, so install
only software you trust. cl_audit's code is open to check: `Login.read` in `Sources/Model.swift` and
`request` in `Sources/Reader.swift`.

## Words used here

- **Profile:** one Claude setup in cl_audit: its Claude Code folder and sign-in, and, if you want them, a Dock
  icon and a Claude window. **Account** means only the claude.ai account a profile is signed in to: each
  profile is linked to one account seat (account and organisation), and no two profiles share one.
- **Usage only:** a profile with **Usage in the Dock** and **Claude window** both off: its usage shows on the
  dashboard, in the launcher and in alerts, with nothing in the Dock and no window.
- **Dock icon:** the profile's own small app ("cl_audit &lt;profile&gt;") that shows its usage. It only shows:
  quitting it never stops the usage or the alerts.
- **cl_audit agent:** the helper inside cl_audit that reads every profile's usage, renews sign-ins, sends
  the alerts and starts and quits Dock icons and Claude windows by the Opening and closing rules. It has no
  window or Dock icon; macOS starts it at login and again if it crashes.
- **Claude window:** the profile's running Claude desktop app: the usual Claude app for the profile using
  `~/.claude`, its own Claude window (own sign-in, chats and settings) for every other profile.
- **Profile settings** (Settings ▸ a profile) and **General settings** (Settings ▸ General, app-wide).

## The dashboard

Opening **cl_audit** shows a card per profile: its icon, both limits and a switch for each thing it has (its
Claude window, its Dock icon). A usage only profile has no switches: one display says "Usage only · not in
the Dock · no window".

The top strip says what the agent is doing: "Reading usage · 2 profiles · every 2–5 min", "Anthropic didn't
answer · 1 profile", or "cl_audit agent stopped" with **Start**; then how old the newest numbers are, with a
refresh key.

- **Claude window:** open or quit the profile's Claude window.
- **Dock icon:** start or quit only the profile's Dock icon app; its usage keeps being read. Pins are never
  touched, so the Dock doesn't restart. A missing app shows **Reinstall**.
- A flipped switch stays where you put it, with a spinner, until the change is done. Quitting a window
  that Claude asks about (for example unsent work) shows "Claude is asking" with **Show**; a window that
  doesn't open within 30 s offers **Retry**.
- What the agent does by Opening and closing shows on the switches: "quits in 8 s", "starting…", "opening…",
  or "starts with its window" for a Dock icon that runs with its window.
- Under the limits: **Sign in…** when needed, otherwise **Open/Show window** (with a Claude window), then
  **Terminal**, and "⋯" (Refresh now, Profile settings…); a usage only profile has just "⋯".

Below the cards, **Usage history** (24 h / 7 d / 30 d) is read from the session files Claude Code writes
on this Mac (only time, model, token counts, project folder and surface of each reply): when you use
Claude, tokens per day per profile, and where they go (by project, model and surface). The period and
the **Show** chips next to it filter the charts and are kept between launches. Usage from claude.ai
chats, other computers or cloud sessions isn't there.

cl_audit stays in the Dock as a launcher:

| On the cl_audit icon | What happens |
|---|---|
| Click | The launcher palette: every profile with its icon and mini bars; ↑↓, ↩ Claude window, ⌘↩ Terminal, ⌘1–9, type to filter |
| Click, with the cl_audit window open | Behind other windows: brings it to the front as it was (Dashboard or Settings). Already in front: goes to the Dashboard |
| Press and hold | The dashboard |
| Right-click | Open Claude for any profile, Dashboard, Launcher, Settings… |

## A profile's Dock icon

| Action | What happens |
|---|---|
| Click | The profile's click action; by default its usage for 3 s while its Claude window opens |
| Double-click or ⌥-click | The details panel: both limits with bars and reset times, the sign-in, Open Claude, Sign in, Refresh, Settings |
| Press and hold | The details panel next to a short Dock menu (on by default, per profile) |
| Right-click | The menu: numbers, reset times, the sign-in, and actions (Open or Show Claude window, Quit Claude window, Refresh now, Dashboard, Profile settings…, and Quit and keep Claude window when the window follows the Dock icon) |

A Dock icon draws what the agent saved for its profile, and asks the agent for Refresh now and Renew login.

Press and hold has no event of its own: the Dock asks the app for its menu on both right-click and
press-and-hold, and the icon checks which mouse button is down at that moment.

## Settings

Settings is a page of the same window as the dashboard (switch at the top, or ⌘,). The profiles run along
the top, with **General** first and **New profile** last. Changes are saved as you make them and the
icons follow at once; a profile's name or icon label is saved when you press Return or click elsewhere (Esc puts it back),
because that renames its Dock icon app; the top strip says when it's done. **Show emails** (General settings) off leaves email addresses out of the launcher, dashboard,
panels and Dock menus, and blurs them in Settings (hover one to see it), for screen sharing.

Cards are at most one column wide: three columns from about 1180 pt, two from 800, one below. Controls
sit next to their labels; every (i) opens a short explanation, some with a picture. Changing a setting that
has no picture of its own shows a short note at the bottom of the page saying what it now does; it floats
over the page, so nothing moves, and closes after 6 s or with ×.

### Profile settings

- **Profile:** name, icon label (up to 6 letters, drawn on the icon), the profile's colour (launcher,
  dashboard, panels), then two keys, each with a line under it saying what the current choice does:
  - **Usage in the Dock:** on, a Dock icon shows the profile's usage (click it for details); off, no Dock
    icon: it quits, is unpinned and its app is removed with what macOS keeps for it. Turn it back on and the
    app is installed again and returns to its place in the Dock, with the same look and click settings (they
    live in the profile). The agent reads the usage either way. Changing it restarts the Dock once, to pin
    or unpin; the main display says "Restarting the Dock…" and the keys wait meanwhile. Dragging the icon out
    of the Dock by hand turns it off too.
  - **Claude window:** on, a Claude window signed in to the profile's account; off, none, and nothing opens
    one. Its folder and sign-in are kept, so turning it back on needs no new sign-in.

  Turning either off never deletes anything; that happens only in **Remove profile…**. Both off is usage
  only. What the profile is doing now shows in the main display at the top: "Running · in the Dock",
  "Stopped · in the Dock", "Reading usage · every N min" (no Dock icon), "Missing · reinstall", or "Not
  reading · cl_audit agent stopped"; while a change goes through it says "Saving…", then "Saved" and what
  changed.
- **Claude Code:** the Claude Code folder (`~/.claude` or a `CLAUDE_CONFIG_DIR` folder) and the sign-in
  found there; **Renew sign-in** (opt-in). Folders other profiles use are marked and can't be picked. The
  Claude window follows from the folder (see Profile above); it isn't a setting.
- **Updates and alerts:** how often the agent reads the usage, and a notification from cl_audit when a limit
  reaches a set level (once per limit and reset).
- **Dock icon clicks:** what a click does (usage for N seconds while Claude opens, just open Claude,
  or the details panel), press and hold, and the panel design (Glow, Rings, Numbers, Segments, Pace),
  previewed at full size. Without a Claude window a click only shows the usage ("just open Claude" shows
  the details panel).
- **Icon:** the style, previewed as the limit fills up:
  - classic: Two numbers, Rings (outer = 5-hour, inner = week), Big number;
  - like the panels: Twin rings, Segmented, Pace bars (a white tick for how much of the window has passed);
  - status colours, where colours follow the levels: Tile, Gauge, Worst, Tile + bar, Bars, Batteries,
    Gauge + bar.

  Then the icon's colour, an optional frame colour and the **Claude open dot**: none, or a Claude-orange
  dot at the top-left while the profile's Claude window is open.
- **Opening and closing** (run by the agent, whether or not cl_audit is open):
  - **Dock icon runs:** **At login** (always there, from when you log in), **With its window** (starts when
    the profile's Claude window opens and quits 10 s after it quits, since a Claude update restarts the
    window) or **When started** (only when you start it: a click on its Dock tile, or its dashboard switch).
  - **Claude window opens and quits with the Dock icon:** starting the Dock icon opens its window (not at
    login), and quitting it quits the window too, so Claude can ask about unsent work; the Dock icon's menu
    then has **Quit and keep Claude window**.

  With Usage in the Dock off the card fades under "Not in use · no Dock icon to open or close" with **Show
  in the Dock**; without a Claude window the window switch fades (**Add Claude window**). Saved choices stay
  stored and apply again when they can. Older settings carried over: Open at login on → At login; "start or
  quit the Dock icon too" → With its window; both off → When started; "open or quit the Claude window too" →
  the window switch.

### General settings

- **Emails:** Show emails (see above).
- **Face:** the look of the cl_audit window, as on the home site: **Std** (a dark brushed panel, the
  default), **Black** (black anodised) or **Silver** (light brushed silver; the window takes the Mac's light
  appearance). Keys, display windows and LED switches throughout; the Dock icons keep their own designs.
- **Dashboard cards:** one card style for every profile (Glow, Rings, Numbers, Segments or Pace).
- **About:** the version and build, and a link to what's new.
- **Clean-up:** when the agent last tidied up ("Cleaned up 2 leftovers · 26 Oct"; the (i) lists what went),
  and **Uninstall cl_audit…** (see [Uninstalling](#uninstalling)).
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
- **Usage in the Dock** and **Claude window**, the same two keys as in profile settings. Which Claude window
  isn't asked: `~/.claude` gets the usual Claude app, any other folder its own Claude window. With Claude
  window off, the Claude app sign-in step drops out; with Usage in the Dock off, the last step is **Start
  reading usage**, which installs nothing and leaves the Dock alone: the agent reads its usage from then on.
- **Quit the Claude app first** (with a Claude window), until the folder is created or connected: while open
  it writes its sign-in and settings. The page lists its windows, checking every 2 s, with Quit and Check
  again. Without a Claude window this step isn't there: the only new folder is the Claude Code folder, which
  the Claude app never writes. Claude Code in Terminal doesn't get in the way.
- **Sign in, in two parts:** Claude Code (Terminal runs `claude auth login` for the folder), then, with a
  separate window, that window, signed in to the same claude.ai account (checked by account id; no email
  or token is read). "Finish now" leaves sign-in for later. An account another profile already has is
  refused: one profile per account.
- New profiles start with an existing profile's click and panel settings. **Cancel** undoes only what
  the page created: an existing folder is never deleted or signed out.

### Removing a profile

**Remove profile…** (profile settings, or right-click its tile) removes its Dock icon app and what macOS
keeps for it: preferences, caches, saved window state, its pin and recent-apps entry in the Dock (the Dock
restarts only if one was there) and its Launch Services record, plus its saved usage, the agent's alert
marks for it, Terminal scripts and place on the dashboard. **Delete its folders too** also signs its Claude Code
folder out (its Keychain login goes) and deletes that folder and its Claude window's data folder; links
inside are removed, never what they point to. The default `~/.claude`, the standard window and a folder
another profile shares items from are never deleted, and Claude must be closed first.

### Uninstalling

**Uninstall cl_audit…** (Settings ▸ General, or the cl_audit menu) always removes every Dock icon app and its pin
(your other pins stay), the agent and its background item, saved usage, settings, caches and preferences, the
Terminal scripts cl_audit wrote, and then moves cl_audit itself to the Trash. Per profile, off by default, it can
also delete its Claude Code folder (signed out first) and its own Claude window's data; `~/.claude` and the standard
window are never offered, a folder another profile shares items from goes only together with that profile's, and
Claude must be closed first where it uses a folder that goes. A note at the end lists what was kept.

From Terminal: `/Applications/cl_audit.app/Contents/MacOS/UsageDock --uninstall` lists what would go; add `--yes`
to do it, and `--delete-folders=work,starpay` (profile ids) for those profiles' folders.

Dragged cl_audit to the Trash instead? While its agent still runs (it does until you log out), it offers once to
remove the Dock icon apps, the agent and the settings; later, the first Dock icon you open does. It never deletes
a folder. macOS can't start the agent again from the Trash, so nothing of cl_audit keeps reading after that.

Profiles are saved on this Mac only, in `~/Library/Application Support/usage-n-uf/accounts.json`
(format: `accounts.example.json`). Only the cl_audit window edits it (and the agent, to record a Dock icon
dragged out by hand), through one locked write. When cl_audit starts it brings the Dock icon apps up to
date; the agent starts the ones that should run.

## How it works

One program in three roles: **cl_audit** (the window: dashboard, settings, launcher), the **cl_audit agent**
(a helper inside cl_audit.app) and each profile's **Dock icon** (a copy of the app with its own bundle id).

- **The agent:** `cl_audit.app/Contents/Library/LoginItems/cl_audit Agent.app`, registered with macOS as
  cl_audit's one background item (a launch agent, `SMAppService`). launchd starts it at login and again
  right after a crash; started four times within ten minutes it waits before reading again (1 min, doubling
  up to 30 min). launchd actually starts `Contents/Helpers/cl_audit-agent`, a small launcher that hands over
  to the agent: macOS knows an ad hoc signed program it may start by its exact fingerprint, and the
  launcher's never changes, so an update needs no new approval and shows no new notice. cl_audit restarts the
  agent after an update.
- **Numbers:** the agent asks Anthropic's usage endpoint for every profile on its own interval (and backs
  off when Anthropic is busy), with the profile's Claude Code login (see
  [Security](#security-how-cl_audit-handles-the-claude-login)). The login is kept in memory and read again
  only when it has expired or was refused. What it sees goes to
  `~/Library/Application Support/usage-n-uf/status/<profile>.json` (no secrets), and it writes an "alive"
  mark (`agent.json`) every 30 s, so cl_audit can tell "nothing is reading" from "Anthropic didn't answer".
  The Dock icons and the window only read these files.
- **Which login:** Claude Code names its Keychain item after the settings folder. The default
  `~/.claude` uses `Claude Code-credentials`; a `CLAUDE_CONFIG_DIR` folder uses
  `Claude Code-credentials-<first 8 hex of SHA-256 of the folder path>`.
- **Account check:** the agent looks up which email a login belongs to and compares it with the account
  the folder is set up for (`oauthAccount` in its `.claude.json`). On a mismatch the icon shows a red "!",
  and the panel and menu say how to fix it.
- **Alerts:** one source, cl_audit, so macOS asks once. One alert per limit and reset.
- **Clean-up:** the agent tidies up at login, after every saved change and every 6 hours. It removes only what
  is provably cl_audit's (Dock icon apps in `/Applications` or `~/Applications` with a bundle id under
  `local.usage-n-uf.` and a profile id): apps no profile wants, second copies, the files macOS keeps under their
  id in six places in `~/Library`, saved usage of removed profiles, Dock pins and recent-app entries of apps that
  are gone (one Dock change, only when there is one) and Terminal scripts older than a day. Never a Claude Code
  folder, a Claude window's data, a Keychain sign-in or anything without cl_audit's id. With the profiles file
  missing or unreadable it removes nothing, and it leaves an app installed or renamed in the last minute alone.
  `UsageDock --cleanup --dry-run` lists what it would remove.
- **Which Claude window:** running Claude apps are matched to profiles by their exact `--user-data-dir`,
  read from the process arguments (no `ps`); the standard window is the one without it.
- **Fallback:** `statusline/usage-statusline.sh` is a Claude Code status line script that writes
  `<settings folder>/usage.json` after every reply in Terminal sessions. The agent uses that file when the
  endpoint can't be reached. The Claude app's Code tab doesn't run status lines. To use it, add to the
  folder's `settings.json`:
  `{ "statusLine": { "type": "command", "command": "~/.claude/bin/usage-statusline.sh" } }`
- **One app per Dock icon:** macOS gives each running app one Dock icon, so a profile with Usage in the
  Dock on gets its own copy of the app (same binary, its own bundle id and `UsageAccountID`), signed ad hoc.
  Only those profiles have one: with Usage in the Dock off the copy is removed (its Dock place is kept by the
  agent). Earlier versions made each copy its own login item and kept a hidden copy with Usage in the Dock
  off; the agent removes those once.

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
