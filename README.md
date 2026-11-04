<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/logo-light.svg">
    <img alt="cl_audit by n-uf" src="docs/logo-light.svg" height="60">
  </picture>
</p>

# cl_audit

Usage audit for all your Claude setups on one Mac. A small background agent inside cl_audit reads how much
of each **profile**'s 5-hour and weekly limits is used and sends the alerts. Each profile can have its own
Dock icon showing its usage (a click opens that profile's Claude window) and its own icon in the menu bar. The
cl_audit app adds a dashboard, a launcher and the settings.

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

**Checked with Claude Code 2.1.310 and the Claude app 3.6556.2** (cl_audit 26.10.11). cl_audit relies on how
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
  the alerts and starts and quits Dock icons and Claude windows as each profile's Dock icon and Claude window
  settings say. It has no
  window or Dock icon; macOS starts it at login and again if it crashes.
- **Claude window:** the profile's running Claude desktop app: the usual Claude app for the profile using
  `~/.claude`, its own Claude window (own sign-in, chats and settings) for every other profile.
- **Profile settings** (Settings ▸ a profile) and **General settings** (Settings ▸ General, app-wide).

## The dashboard

Opening **cl_audit** shows a card per profile: its icon, its plan, both limits and a switch for each thing it has
(its Claude window, its Dock icon). A usage only profile has no switches: one display says "Usage only · not in
the Dock · no window". The plan is Claude's own name for it, as Claude Code recorded it in the profile's
`.claude.json` ("Ultra"; the sign-in itself says "max" for an Ultra account), else the sign-in's. A plan without a
5-hour limit (Ultra) shows the week alone: no empty 5-hour row on the cards, panels, menus, the menu bar icon and
the widget (the Dock icon still shows "5h –").

The top strip is the profile keys, one display and the refresh key. The display shows one thing at a time, most
important first: "Not updating · agent won't start · numbers 7 min old" (red; a click opens Settings ▸ General with
the reason), "Starting the agent…", "Not updating · agent paused until 14:32" (after repeated crashes),
"Updating…", "Updated · 2 min ago · Work: no answer" (Anthropic didn't answer for that profile), or "Updated · 2
min ago" (its hover says how many profiles the agent reads, and how often). There's no Start key: cl_audit starts
its agent itself when its window opens and whenever the agent has been silent for 90 s, and the refresh key always
works: it refreshes, starts the agent first, or (paused) starts it now.

- **Claude window:** open or quit the profile's Claude window.
- **Dock icon:** start or quit only the profile's Dock icon app; its usage keeps being read. Pins are never
  touched, so the Dock doesn't restart. A missing app shows **Reinstall**.
- A flipped switch stays where you put it, with a spinner, until the change is done. Quitting a window
  that Claude asks about (for example unsent work) shows "Claude is asking" with **Show**; a window that
  doesn't open within 30 s offers **Retry**.
- What the agent does by those settings shows on the switches: "quits in 8 s", "starting…", "opening…",
  or "starts with its window" for a Dock icon that runs with its window.
- Under the limits: **Sign in…** when needed, otherwise **Open/Show window** (with a Claude window), then
  **Terminal**, and "⋯" (Refresh now, Profile settings…); a usage only profile has just "⋯".

### When a limit is full

At 100% the percentage stops being useful; what matters is when the profile works again. While a limit is full,
its card puts the limits on the left (name, reset line, bar, percentage; the full one's line in red) and one box
on the right for the full limit that holds the profile back, the one that resets last: "5-hour full" (or "Week
full · 5-hour too"), how long until it's back, large ("in 1h 42m"), and when, under it ("back at 15:28").

- The countdown updates as it goes and changes form: "in 2d 19h", "in 1h 42m", "in 19m". The time under it is
  "back at 15:28" today, "back Thu 09:00" within the week, "back 11 Nov" later, "back 12 Jan 2027" another year.
- Full means 100%. When Anthropic doesn't say when it resets, the box says "full · reset time unknown"; cl_audit
  never makes up a time.
- At the reset the agent reads that profile again right away, and the card goes back to its usual layout. With
  nothing full, the card is as always: no box.
- The same box is in the details panel; the launcher shows the countdown; the Dock icon's menu starts with "5-hour
  full · back at 15:28, in 1h 42m"; the Dock icon itself becomes the countdown (the time large, "5H FULL" under
  it, a red frame).

### Widget

cl_audit has a macOS widget (macOS 14 and later), **Claude usage**: every profile's 5-hour and weekly limits, and
when a full one is back ("back at 15:28"). Add it from the widget gallery (click the date in the menu bar, then Edit
Widgets) to the desktop or Notification Center, in three sizes. It fits itself to the size and the number of
profiles: one or two get large limits with when they reset, up to four get a block each in the large size, more get
a row each. In the large size one profile's limits are drawn bigger and spread over the whole height; two to four
get the next three resets below whenever they fit, and the biggest arrangement that fits is used, with the room
left shared out evenly, so no part stays empty.
Fable's limit shows for the profiles whose settings show it (Profile ▸ Fable's limit). Its look is in Settings ▸
General ▸ **Widget**, built like the Dashboard cards card, with the real widget as the preview:

- **Limits as:** Glow, Rings, Numbers, Segments or Pace, like the dashboard cards, in every row too.
- **Look:** System (the Mac's own widget background, light or dark) or cl_audit's Std, Black and Silver faces
  (Numbers in a glowing display window on Std and Black).

It only reads what cl_audit saves (the profiles, their usage and `widget.json` with its look), through a read-only
sandbox exception for cl_audit's own folder; no Keychain, no network. macOS refreshes it every few minutes, and at
once when the look changes.

### Fable's weekly limit and usage credits

Max and Ultra plans and premium Team and Enterprise seats also have a **weekly limit of Fable's own**: Fable may use
up to a share of the week (half, today). Pro and standard seats pay for Fable with usage credits instead, so they
have no such row. When Anthropic's reply has it, the cards, the panels and the Dock icon's menu show a third row, "Fable"
("Fable · week" in the large panel). Full, the row turns red and says when it's back ("full · back Thu 09:00"); it
doesn't take the full-limit box or the countdown face, because the profile can still work with the other models. The
Dock icon keeps its two bars.

**Usage credits** carry a profile on past its plan limits, and they're paid for. While a profile is spending them (credits
on and a limit full, or the amount spent went up within the hour), its card, panels and Dock menu say so: "Using usage
credits · $4.20 spent". At other times nothing about credits is shown.

Below the cards, **Usage history** (24 h / 7 d / 30 d) is read from the session files Claude Code writes
on this Mac (only time, model, token counts, project folder and surface of each reply): when you use
Claude, tokens per day per profile, and where they go (by project, model and surface). The period and
the **Show** chips next to it filter the charts and are kept between launches. Usage from claude.ai
chats, other computers or cloud sessions isn't there. The **CSV** key saves the period as a CSV file: one row per
day, profile and model (optionally split by project, by folder name only), with the replies and each kind of token
(input, output, 5-minute and 1-hour cache writes, cache reads) and the cost estimate.

The totals next to the title include a **cost estimate at Anthropic's API list prices** ("≈ $123 at list prices"):
what the same tokens would cost on the API, per model, with 5-minute and 1-hour cache writes and cache reads priced
apart (fast mode and US-only inference too). It's not your bill: use on a Pro, Max, Ultra or Team plan is paid for
by the plan. Models without a published price are left out, never guessed. The prices are built in, dated (see
`Sources/Pricing.swift`), and updated with cl_audit releases.

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

**Profile order:** drag a profile's tile left or right along the top (General stays first, ＋ last); the others move
aside and a lit socket shows where it lands. It's saved when you let go ("Saved · order"); VoiceOver has Move left and
Move right. The dashboard's cards and profile keys, the launcher and its ⌘1, ⌘2…, the menu bar icons, the widget,
the usage history (bars, legend, CSV) and cl_audit's Dock menu all follow it. The menu bar icons line up in the new
order (⌘-drag still moves them after, until the next new order). The Dock icons stay where you put them: move them in
the Dock. With General ▸ Dock ▸ Keep in order on, cl_audit puts them in this order the next time it arranges the Dock
(Arrange Dock, or adding, renaming or removing a profile). The order is the order of the profiles in `accounts.json`,
so there's no setting of its own.

Cards are at most one column wide: three columns from about 1180 pt, two from 800, one below. Controls
sit next to their labels; every (i) opens a short explanation, some with a picture. Changing a setting that
has no picture of its own shows a short note at the bottom of the page saying what it now does; it floats
over the page, so nothing moves, and closes after 6 s or with ×.

### Profile settings

Every card follows one pattern: one title with its (i), then rows, each with its label on the left (with an (i),
the same width on every card, so the values line up across the page) and its value on the right. On/off is the
small lamp switch with a few words that follow the state; two or three short choices are segments, longer ones a
pop-up, pictures tiles under the label; at most one grey line under a row says what the current choice means; a
card's preview is one strip at its foot (no numbers or not running · plenty left · half used · at limit · full).
Each part (the Dock icon, the Claude window, the menu bar icon) is one card with its switch first; switched off,
the card folds to that row, whose words say what's left ("no Dock icon", "none", "no icon").

- **Profile:** name, icon label (up to 6 letters, drawn on the icon), the profile's colour (launcher,
  dashboard, panels), **Fable's limit** ("shown and alerted" on its card, panels, menus and the widget; "left
  out" everywhere) and **Remove profile…**.

  Turning a part off never deletes anything; that happens only in **Remove profile…**. No Dock icon and no Claude
  window is usage only. What the profile is doing now shows in the main display at the top: "Running · in the Dock",
  "Stopped · in the Dock", "Reading usage · every N min" (no Dock icon), "Missing · reinstall", or the agent's
  state in the dashboard's words ("Starting the agent…", "Not updating · agent won't start"); while a change goes
  through it says "Saving…", then "Saved" and what changed.
- **Claude Code:** the Claude Code folder (`~/.claude` or a `CLAUDE_CONFIG_DIR` folder) and its sign-in, in two
  rows. Folders other profiles use are marked and can't be picked. The Claude window follows from the folder (see
  Profile above); it isn't a setting. **Login** is one row for everything about the sign-in: a pop-up in line with
  the Folder one, showing the account Claude Code in the folder is signed in to (green; red with a warning sign
  inside when it isn't the profile's account; a clock when the sign-in ran out; a long address gets shorter rather
  than widening the card). Its menu lists accounts: it ticks that one, then, when it isn't the profile's, the
  profile's own account to log back in to; the accounts signed in in Claude Code folders no profile uses (picking one only fills in the address; no sign-in is ever copied between folders); other profiles'
  accounts, dimmed; **Sign in to another account…**; and **Renew sign-in by itself** (opt-in, see the (i)).
  **Sign in to another account…** turns Login's value into the address and **Sign in**, in place (Esc or **Cancel**
  puts the pop-up back): Claude Code's own sign-in opens in Terminal with the address filled in, and the profile
  stays on its account until it's done. While it waits, Login says "signing in…" with **Cancel**; as soon as the
  folder's `.claude.json` names the new account, cl_audit links the profile to it by itself, keeping its name,
  look, Dock icon, Claude window and settings. Signed in to another account outside cl_audit (Terminal), **Use this
  account** shows under the pop-up (the same link), and the profile shows no numbers until you choose, since they
  would be the other account's. If another profile has that account, the line under Login names it, with
  **Open** it instead: one profile per account. Anything else needing a word gets one grey line under the row. A
  **Claude window** row says when the profile's window is signed in to another account than its Claude Code (only
  the account id is known, from the window's `config.json`; the usual Claude app is checked too). For a week after
  linking, the line under Login says when, which account it was and what stays with it, and that **New profile**
  gives the old account a profile again. See [Moving a profile to another account](#moving-a-profile-to-another-account).
  As on every card, the pop-ups and fields fill the value column, so their right edges line up; the address row is
  one line like Folder (Sign in and Cancel at its end; Cancel is a × in a narrow window).
- **Alerts:** how often the agent reads the usage, and a notification from cl_audit when a limit
  reaches a set level (once per limit and reset). When a limit is full, a notification says when it's back
  ("Claude Work: 5-hour limit full · Back at 15:28, in 1h 42m"). **Notify when back** (on by default) sends one
  more when a full limit resets ("Claude Work is back · The 5-hour limit reset at 15:28"); while the other limit
  is still full, it waits for that one. Fable's weekly limit alerts the same way ("Claude Main: Fable weekly limit
  full · Back Thu 09:00", "Claude Main: Fable is back"). With alerts on, one more when a profile starts spending
  usage credits ("Claude Work is using usage credits · The 5-hour limit is full · $0.40 spent so far") and one when
  they run out.
- **Claude window** (run by the agent, whether or not cl_audit is open):
  - **Claude window:** on ("its own window", or "the usual Claude app" for `~/.claude`), a Claude window signed
    in to the profile's account; off ("none"), none, and nothing opens one. Its folder and sign-in are kept, so
    turning it back on needs no new sign-in.
  - **With Dock icon:** the window goes with the Dock icon: quitting the Dock icon quits it too, so Claude can ask
    about unsent work (the Dock icon's menu then has **Quit and keep Claude window**), and, unless Opens from is
    "Only when asked", starting the Dock icon opens it (not at login). Its words: "opens and quits with it", "quits
    with it", or "on its own".
  - **Opens from:** **Dock click too** (the default) or **Only when asked**: a click on the Dock icon then never
    opens the window, and neither does starting the Dock icon (a click on its stopped tile starts it and shows the
    usage instead); the dashboard's Open window key and tile, **Open Claude window** in the Dock icon's and the menu
    bar icon's menus and the details panel's Open Claude open it.
- **Dock icon** (run by the agent, whether or not cl_audit is open):
  - **Usage in the Dock:** on ("shows the usage"), a Dock icon shows the profile's usage (click it for details);
    off ("no Dock icon"), it quits, is unpinned and its app is removed with what macOS keeps for it. Turn it back
    on and the app is installed again and returns to its place in the Dock, with the same look and click settings
    (they live in the profile). The agent reads the usage either way. Changing it restarts the Dock once, to pin
    or unpin; the main display says "Restarting the Dock…" and the switches wait meanwhile. Dragging the icon out
    of the Dock by hand turns it off too.
  - **Runs** (a pop-up, with a line saying what the choice means): **At login** (always there, from when you log
    in), **With its window** (starts when the profile's Claude window opens and quits 10 s after it quits, since
    a Claude update restarts the window) or **When started** (only when you start it: a click on its Dock tile, or
    its dashboard switch).
  - **Click:** what a click does (usage for N seconds while Claude opens, just open Claude, or the details
    panel), with **Usage shows for** when the usage shows briefly. Without a Claude window, or with Opens from ▸
    Only when asked, the Claude choices are off and a click shows the usage only: the usage panel briefly or the
    details panel (the stored choice comes back with the window).
  - **Press and hold**, then the **Usage panel** design (Glow, Rings, Numbers, Segments, Pace) and the **Icon**
    style as tiles: Two numbers, Rings (outer = 5-hour, inner = week), Big number; Twin rings, Segmented, Pace
    bars (a white tick for how much of the window has passed); and, where colours follow the levels, Tile, Gauge,
    Worst, Tile + bar, Bars, Batteries, Gauge + bar. Then the icon's **Colour**, an optional **Frame** and the
    **Claude open dot** ("while its window is open" or "none"), and the preview strip: not running, then as the
    limit fills up.

  Saved choices stay stored and apply again when they can. Older settings carried over: Open at login on → At
  login; "start or quit the Dock icon too" → With its window; both off → When started; "open or quit the Claude
  window too" → the window switch.
- **Menu bar:** the profile's own icon in the menu bar, exactly like its Dock icon. **In the menu bar** (off by
  default) switches it on; the agent draws it, so it works with or without the Dock icon. ⌘-drag it to move it;
  macOS remembers where. Its look, each choice a tile drawn the way your menu bar is now, and the preview strip
  from "no numbers" to "full":
  - **Style:** Two bars (5-hour over week), Bars + number, Ring (week outside, 5-hour inside), Ring + number,
    Number (the fuller limit), Two numbers.
  - **Colours:** the level colours; **System**, the menu bar's own colour, drawn the way macOS draws its icons
    (white or black, dimmed on an inactive screen); **Accent**, your Mac's accent colour, following it when it
    changes; or the profile's colour. A full limit is red, except in System, where its countdown shows it.
  - **Label:** none, or the profile's label before its icon ("MAIN").
  - **When full:** the countdown beside the icon ("1h 42m"), or red only.

  A click opens the profile's menu: its limits (Fable's when the plan has one, when each resets, usage credits
  while they're spent), when they were read, then **Open Claude window**, **Refresh now**, **Dashboard**,
  **Profile settings…** and **Hide from the menu bar**.

The cards sit in three columns: Profile, Claude Code, Claude window and Alerts on the left, the Dock icon in the
middle, the menu bar on the right. In two columns the menu bar goes under the left cards and the Dock icon stays
beside them; in one column everything follows in that order.

### General settings

Three columns, each with its subject printed at the top: **cl_audit** (Usage in the background, Privacy, About),
**How usage looks** (Face, Dashboard cards, Widget) and **The Dock** (App icon, Dock). In two columns the Dock goes
under cl_audit; one column keeps the same order, top to bottom. Every row is one line.

- **Usage in the background:** whether usage is being read ("Reading usage · 2 profiles · every 2–5 min", or red
  "Not reading · stopped 12 min ago"), then whether **Alerts** reach you (Allowed, or "Not allowed" with **Allow…**,
  which opens System Settings ▸ Notifications ▸ cl_audit), **Last read**, and only while reading has stopped
  **Start reading**, with a note under the rows (cl_audit also retries by itself every minute) and the reason it
  won't start. The dashboard's red display opens this card.
- **About:** the version and build, a link to what's new, when the agent last cleaned up ("Nothing to clean up ·
  11:38", "Cleaned up 2 leftovers · Thu 09:00"; the (i) lists what went) and **Uninstall cl_audit…** (see
  [Uninstalling](#uninstalling)).
- **Privacy:** Show emails (see above).
- **Face:** the look of the cl_audit window, as on the home site: **Std** (a dark brushed panel, the
  default), **Black** (black anodised) or **Silver** (light brushed silver; the window takes the Mac's light
  appearance). Keys, display windows and LED switches throughout; the Dock icons keep their own designs.
- **Dashboard cards:** one card style for every profile (Glow, Rings, Numbers, Segments or Pace).
- **App icon:** six designs in one row; Front panel's Plate, Display, Keys and Slot below it.
- **Dock:** **Keep in order** (off by default; experimental and invasive: it rewrites the Dock's pin list and
  restarts the Dock, and macOS can misplace or drop pins). macOS ties running Claude windows to Claude pins in its
  own order, so several Claude pins get mixed up; the Dock icons are the reliable way to reach each profile's
  window. When on, cl_audit keeps its Dock icons pinned together in profile order (the cl_audit app last)
  with one Claude pin before them (or none), and redoes it after profiles are added, removed or renamed.
  Other apps keep their places. The card pictures your Dock with the changes marked; **Arrange Dock**
  applies them, and **Restore my Dock** puts back the pins saved before the first change.
- **Widget:** see [Widget](#widget).

### Adding a profile

**New profile** opens a page: in a wide window three columns (the profile and its window, the Claude Code
folder, a summary with the live icon and numbered steps); narrower, one column with the next step pinned
at the bottom.

- **Account first:** the Claude Code card's **Account** pop-up, like Settings ▸ Login, lists the accounts signed
  in in Claude Code folders on this Mac that no profile uses, each with its folder (picking one connects that
  folder as it is: its sign-in, settings and history stay), other profiles' accounts dimmed, and **Sign in to
  another account…**. That opens the one-line address row: **Sign in** makes a new folder, `~/.claude-<name>`,
  and Terminal runs `claude auth login --claudeai --email <address>` for it. The address is only filled in:
  the browser's claude.ai account decides which account it is (switch it there first if it shows another
  one), and cl_audit checks the result by the folder's account and organisation ids. A folder holds one
  sign-in, so an account always comes with its folder. An account with no folder on this Mac (one whose folder
  was signed in to another account) comes back only this way.
- **Folder:** its own row, following the account: a *new* folder (`~/.claude-<name>`, optionally sharing
  instructions, agents, skills, commands or memory from another Claude Code folder), or an *existing* one,
  including `~/.claude` or one you pick in Finder; each shows who is signed in there. Folders are used where
  they are: Claude Code names a folder's Keychain sign-in after its path, so moving or renaming one loses it.
  Folders are compared after resolving `~`, links and letter case; a folder inside or around another profile's
  folder counts as the same.
- **Usage in the Dock** and **Claude window**, the same two keys as in profile settings. Which Claude window
  isn't asked: `~/.claude` gets the usual Claude app, any other folder its own Claude window. With Claude
  window off, the Claude app sign-in step drops out; with Usage in the Dock off, the last step is **Start
  reading usage**, which installs nothing and leaves the Dock alone: the agent reads its usage from then on.
- **Quit the Claude app first** (with a Claude window), until the folder is created or connected: while open
  it writes its sign-in and settings. The page lists its windows, checking every 2 s, with Quit and Check
  again. Without a Claude window this step isn't there: the only new folder is the Claude Code folder, which
  the Claude app never writes. Claude Code in Terminal doesn't get in the way.
- **Sign in, in two parts:** a profile is a pair, the Claude Code folder and the Claude window's data folder,
  each signed in on its own. Claude Code first (Terminal runs `claude auth login` for the folder, with the
  address filled in when you typed one), then the Claude window, its own or the usual Claude app, signed in to
  the same claude.ai account (checked by the account id it saved; no email or token is read; the address is
  shown as a reminder only). Its Code sidebar starts empty: Code sessions stay in the data folder they were made
  in. "Finish now" leaves sign-in for later. An account another profile already has is refused: one profile
  per account.
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

### Moving a profile to another account

For example to a new plan, whose weekly limit starts at zero. A profile keeps everything (name, look, Dock icon,
Claude window, settings); only its sign-ins and its link change. Two sign-ins move, Claude Code's and the Claude
window's, and **Claude Code's is the one cl_audit reads the usage from**: signing in only the Claude app leaves the
numbers on the old account.

1. **Back up**, if the window's Code sessions should come along (step 3): `~/.claude` and
   `~/Library/Application Support/Claude` (without its caches).
2. **Quit every Claude window**: the usual Claude app and every profile's own.
3. **Code sessions (optional, the profile using `~/.claude` only).** The Claude app lists only the signed-in
   account's Code sessions, so the earlier ones stay with the old account. The community tool
   [claude-transplant](https://github.com/vitaliyhayda/claude-transplant) (unofficial, MIT, needs Node 22) can move
   them for the usual Claude app; its paths are fixed to that app's folders, so other profiles' windows can't
   carry theirs this way. Run `npx claude-transplant --dry-run` first, then `npx claude-transplant`, pick the old
   account as From and the new one as To, and run the approval command it prints: it quits and reopens Claude,
   moves the session records and keeps the originals for `npx claude-transplant undo`. Leave `--cloud` off (it
   reads the Claude app's cookie key from the Keychain and goes to claude.ai). With other Claude windows open it
   can quit the wrong one, hence step 2.
4. **Sign the Claude window in** to the new account, in its own sign-in window.
5. **Sign Claude Code in** to the new account, for the profile's folder: Settings ▸ the profile ▸ Claude Code ▸
   Login ▸ **Sign in to another account…**, type the address, **Sign in**, and finish in the browser. cl_audit
   links the profile to it by itself once it's done (refused if another profile already has that account). Or in
   Terminal: `env -u CLAUDE_CONFIG_DIR claude auth login --claudeai --email <new>` for `~/.claude`,
   `CLAUDE_CONFIG_DIR=<folder> claude auth login --claudeai --email <new>` for a profile's own folder.
6. **Signed in from Terminal:** the agent notices within half a minute; the profile then shows no numbers until you
   press **Use this account** (Claude Code card, under Login), which links it.

Staying with the old account: a CI token from `claude setup-token` (make a new one), claude.ai connectors and MCP
servers, cloud sessions and environments, synced plugins, and the plan and billing. To keep watching the old
account's limits, add it as a profile of its own (**New profile**).

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
- **After a Claude update:** Claude updates itself quietly: each window quits by itself once idle (its log says
  "[stealth-update] Triggering stealth update"), the install waits for all of them, and then Claude reopens only its
  standard window. The agent notices which profile windows quit that way (within five minutes after the log line)
  and, as soon as Claude's installed version changes, opens them again in the background, with one alert ("Claude
  updated to 1.2.0 · Reopened Work's window"). A window you closed yourself, or opened again first, is left alone;
  so is a profile without its Claude window switch. Claude Code tasks that the quit stopped aren't restarted.
- **Numbers:** the agent asks Anthropic's usage endpoint for every profile on its own interval (and backs
  off when Anthropic is busy), with the profile's Claude Code login (see
  [Security](#security-how-cl_audit-handles-the-claude-login)). The login is kept in memory and read again
  only when it has expired or was refused, or when Claude Code was signed in to another account in the profile's
  folder: the agent sees its `.claude.json` name another account (it looks at the file's date on every round and
  reads it only when that changed), drops the old account's numbers and alert marks at once and reads the new
  sign-in, so there's no red "Wrong account" waiting for Refresh now. What it sees goes to
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
