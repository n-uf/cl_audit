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

**Checked with Claude Code 2.1.318 and the Claude app 4.23118.0** (cl_audit 26.11.5). cl_audit relies on how
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

Then open **cl_audit**. On a Mac with no profile yet it opens **Set up cl_audit** (see [First run](#first-run)):
Claude Code, then the account, then a name. After that, **New profile** in Settings adds more. With **Usage in the Dock** on,
cl_audit installs "cl_audit &lt;profile&gt;" in `/Applications` and puts it in the Dock. The first time,
macOS says cl_audit added an item that can run in the background (its agent, see [How it works](#how-it-works)),
and asks once to allow notifications for cl_audit (System Settings ▸ Notifications ▸ cl_audit, if you
missed it). To update, download the new zip (or pull and run `./build.sh` again); profiles and settings are
kept, and the agent restarts with the new version on its own.

## First run

With no profile yet (a fresh install, or every profile removed) cl_audit opens **Set up cl_audit** instead of making a
profile by itself. Three steps; each says what it needs:

1. **Claude Code.** Found: "✓ Claude Code 2.1.x · ~/.local/bin/claude". Not found: "Claude Code isn't on this Mac", the
   official install command (`curl -fsSL https://claude.ai/install.sh | bash`, from code.claude.com/docs/en/setup) with a
   **Copy** key, a link to the install page and **Check again**. It looks again by itself every few seconds while
   this page (or an "isn't installed" note) is on screen, and whenever cl_audit comes to the front, so installing it
   needs no restart.
2. **Account.** The first profile is the [default profile](#the-default-profile): `~/.claude` with the usual Claude
   app. A signed-in `~/.claude` is offered first, with its address (never a sign-in): one click (**Use**) takes it, as
   it is, and the step says in one line that other accounts come later (Add account, New profile). Or **Sign in…**
   when `~/.claude` has no sign-in yet: Claude Code's own browser sign-in opens in Terminal and signs in `~/.claude`
   (run with `CLAUDE_CONFIG_DIR` unset, which is what makes it the default folder, not a custom one); the address is
   optional, and the page goes on by itself when the account shows up. A separate folder and its own Claude window
   come only with profiles added after the first.
3. **Name and colour.** Prefilled from the account (a team's name, else the address's name part). **Done** adds the
   profile and opens its Settings.

Where `claude` is looked for, in this order: first exactly where 26.11.1 looked (Homebrew `/opt/homebrew/bin`,
`/usr/local/bin`, `~/.local/bin` (the native installer), `~/.claude/local`, `~/.npm-global/bin`, `~/.bun/bin`), then
the login shell (`zsh -lc 'command -v claude'`, stopped after 5 s), and only then the newer places: `~/.volta/bin`,
nvm's node versions (newest first), npm's own prefix (`npm config get prefix`) and, last, the Claude app's own copy
(`~/Library/Application Support/Claude*/claude-code/<version>/…/claude.app`, "from the Claude app"). A Mac where an
earlier version found `claude` gets the same one; a real install always wins over the app's copy. Anywhere a sign-in needs Claude Code and it isn't there,
cl_audit says "Claude Code isn't installed on this Mac · Install…" beside the key (and in the Add account and Account
pop-ups) instead of greying it silently; Install… opens the same install help.

Who sees it: a Mac with no profile, or whose only profile is the "main" that cl_audit 26.11.1 made by itself on
`~/.claude` (exactly as made, never signed in, no setting changed). Done replaces that "main". A profile you have named,
restyled, signed in or set anything on is never replaced, and anyone who has used profiles never sees the page.

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
session logs (only time, model, token counts, project folder and surface of each reply). Settings ▸ General ▸
Privacy ▸ **Usage history** turns that off.

**Where it goes: only to Anthropic.** cl_audit uses the token for two requests to Anthropic's own server:
`api.anthropic.com/api/oauth/usage` (your 5-hour and weekly figures) and `api.anthropic.com/api/oauth/profile`
(which account a profile is signed in to). There is no cl_audit server, no analytics and no sign-up, and
nothing else goes over the network, with one exception: what you type in [Quick chat](#quick-chat) goes to
Anthropic through Claude Code, as any Claude Code prompt does. **Renew sign-in** (off by default) runs Claude Code once with a tiny prompt
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
- **Claude window:** the profile's running Claude desktop app: the usual Claude app (what Claude shows when opened
  from the Dock or Applications), or the profile's own Claude window (own sign-in, chats and settings, opened from its
  Dock icon). Which one is profile data, decided once when the profile is made and kept (never worked out from the
  folder's name later): the first profile gets the usual app, profiles added after it get their own windows.
- **Default profile:** the profile on `~/.claude` with the usual Claude app: what Claude shows when opened directly, and
  what `claude` uses in Terminal. See [The default profile](#the-default-profile).
- **Profile settings** (Settings ▸ a profile) and **General settings** (Settings ▸ General, app-wide).

## The dashboard

Opening **cl_audit** shows a card per profile: its icon, its plan, both limits and a switch for each thing it has
(its Claude window, its Dock icon). A usage only profile has no switches: one display says "Usage only · not in
the Dock · no window". The plan is Claude's own name for it, as Claude Code recorded it in the profile's
`.claude.json` ("Ultra"; the sign-in itself says "max" for an Ultra account), else the sign-in's. A plan without a
5-hour limit (Ultra) shows the week alone: no empty 5-hour row on the cards, panels, menus, the menu bar icon and
the widget (the Dock icon still shows "5h –"). Drag a card (not by one of its keys) to put the profiles in another
order, the same order as Settings' tile bar (see Profile order under Settings); the display says "Saved · order".

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
- A flipped switch stays where you put it, its lamp pulsing (green turning on, red turning off), until the change
  is done. Quitting a window that Claude asks about (for example unsent work) shows "Claude is asking" with
  **Show**; a window that doesn't open within 30 s offers **Retry**.
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
  it, a crimson frame).
- **Another account with room.** When the profile has other accounts (Settings ▸ the profile ▸ Claude Code ▸
  Accounts), only the one in use is lit. The card shows the others as **unlit trays** under its limits, most room
  first, their levels dimmed, each on a compact line (the address, STANDBY, then its 5-hour and week rows). An
  account with no numbers (no sign-in kept for it) stays off the card. **While a limit is full, the tray with the
  most room is selected already**: its row lights mint across the card with the lit bar, and its STANDBY display
  becomes the lit **Switch account** key, which opens the Switch page with that account picked; a click on another
  tray picks it instead. **With room left nothing is selected**: a click selects a tray, a second click deselects it
  (as in Settings). The alert adds "The other account has 92% of its week left" with **Switch account…** (and
  Later): alerts reach the lock screen, so they never name an account by its address or any part of it. Room means
  current numbers too: an account whose sign-in ran out, or whose numbers are older than three of the profile's read
  intervals, isn't preselected. **The menus** (the menu bar icon's and the Dock icon's, with the same items) show the
  account in use under the profile's name with a lit green lamp ("ultra-1 · in use"; the Dock menu's first line reads
  "Claude Main · ultra-1 in use") and have **Switch account ›**, a submenu with the account in use ticked ("in use ·
  week 94%") and every other account, most room first, each with its week ("week 12%", or "no numbers"; one not linked to its account yet is greyed, "· sign in first"). While a limit
  is full, the best one also sits on the top level, "Switch to ultra-3…  week 12%": right under the full line in the
  Dock menu, first in the menu bar menu's actions. All of them
  open the **Switch page** in cl_audit: the account in use (NOW) and, under TO, every other account with their
  limits, most room first, the one it was opened for picked in mint (click another to switch to it instead; the
  answers given so far go with it); what stays (name, Dock icon, look; the folder with its projects, settings, MCP
  and CLAUDE.md; Claude Code's history); the sessions (the Claude window's sessions in the sidebar, its sections and
  groups, pins and scheduled tasks, counted from the window's own files) with **Move them?**: **Move to ultra-2** or
  **Leave with ultra-1**, asked every time with nothing chosen; with **Move to ultra-2**, a **Backup** card (below);
  and the steps. A short name is the address before the @, its first letter only while emails are hidden (and in the
  menus).
- **A switch waiting for you.** At the steps only you can do (Claude Code's sign-in in the browser, the Claude
  window's own sign-in, the Return in the sidebar session), the Switch page waits out of sight when the browser or
  the Claude window is in front. Then, once per step and only while the page isn't in front (cl_audit's window isn't
  the key window, or another page is selected), one alert says which: "Claude Main: the switch is waiting for you ·
  Step 3 of 5: finish the sign-in in the browser. cl_audit checks the account before it goes on." Its keys are
  **Show switch** (opens that switch's page) and **Cancel switch** (Claude Code's sign-in only: the sessions go back;
  after linking there is nothing to cancel, so **Show switch** alone); a plain click on it is Show switch too. It
  goes when the step moves on, the switch ends or the page comes to the front, never outlives cl_audit, and follows
  the profile's alerts. Several switches (one per profile) each have their own alert. A step that is over in a moment
  never alerts (it must be seen twice in a row), nor does the window's sign-in of a profile without a Claude window,
  nor the Return step before its session is open or after its link missed. Like every alert it names no account.
- **Switching.** **Close and switch to ultra-2** (once the sessions question is answered) does it in order, each
  step checked before the next:
  1. Only that profile's Claude window closes, gracefully (it may ask about work under way; nothing is forced, and
     if it doesn't close, nothing moves). From here until the profile is switched or the switch is undone, nothing
     opens that window again (its Dock icon, the menu bar, cl_audit's rules and reopening after a Claude update all
     wait; a click shows the switch instead), and a second switch of it is refused. This holds only while that
     cl_audit runs.
  2. With **Move to ultra-2**, a **backup** of the sessions is made first, right after the window is known closed
     and before anything moves (see [Backups](#backups-of-a-profiles-sessions)); if it can't be made, the switch
     stops with nothing moved. Then its Code sessions and scheduled tasks move to ultra-2 the way
     [claude-transplant](https://github.com/vitaliyhayda/claude-transplant) moves them: same ids, each entry kept byte
     for byte or re-encoded without the old account's error keys and Remote Control ids, through a write that can't
     overwrite, checked, and only then the original parked in cl_audit's folder (`switches/<id>/`), never deleted.
     Both task files are backed up; the old account's is emptied first, then ultra-2's gets them, so a task never
     runs in both. One switch at a time, and none while claude-transplant runs (its own lock is held meanwhile).
     Sessions the other account already has, or deleted, stay where they are. A receipt (accounts by id, never by
     address) says what each step will do before it does it, so Undo puts back whatever got done, also after a stop
     or a crash: the Switch page shows a switch that stopped half way with **Undo**, and a new switch waits for it.
     A session whose Claude Code transcript still points at the old account's Remote Control copy gets Claude Code's
     own empty pointer line, in one append, and only when nothing is writing that transcript (changed in the last
     seconds, open in a program, or Claude Code running that session: left as it is; a Claude Code session is seen
     by its id on the command line, `--resume <id>` or `--session-id <id>`, not one resumed from its own picker,
     which the first two checks cover); Undo takes the line off again if it's still the transcript's last bytes.
     claude-transplant's lock file is made if it isn't there yet, so a first claude-transplant run waits too.
  3. Claude Code's own sign-in opens in Terminal for the profile's folder, with ultra-2's address filled in: finish
     in the browser. Until then **Cancel switch** puts the sessions back from the receipt. cl_audit never copies
     or moves a stored sign-in.
  4. Once the folder is signed in as ultra-2, the profile works on it (name, Dock icon, folder, projects and
     settings stay); the account it was on joins standby, with the folder that kept its own sign-in if it had one.
     Each account takes its own last numbers with it, and numbers read for one account never show under another's
     name (until the next read, an account without its own shows none).
  5. The window opens again; log out there and sign in as ultra-2. Once it's on ultra-2, a new Code session opens
     in it, named "cl_audit · arrange sidebar", with a prompt filled in: press Return, and it puts the moved
     sessions back in their groups (made by the same name where ultra-2 has none) and pins them again, with the
     app's own sidebar tools, then archives itself. When the window would ask before moving sessions (its
     permission mode there isn't auto), the step says so: allow them. cl_audit sends the link to that window's own
     process, not through `open`, so it never lands in another Claude window; the first time, macOS asks to let
     cl_audit control Claude. Without that leave, it opens the link the usual way only when no other Claude window
     runs, and otherwise says what to do.
  The sidebar's groups, order and pins are kept by claude.ai for each account (synced per organisation), so
  cl_audit doesn't write them: before the move it notes, from the window's own copy, which group each moved session
  sat in, in what order, and which were pinned (in the receipt). The prompt holds only session ids, group names and
  their order: no address, title or transcript. Run again, it changes nothing; in a window that doesn't have those
  sessions, it changes nothing either. Groups none of the moved sessions sat in aren't made. The way back is the same
  switch the other way.
- **The Backup card.** Shown while the answer is **Move to ultra-2**. Before the switch: **When** (every time the
  sessions move, right after the window closes and before anything moves), **What** (the window's Code-tab list for
  both accounts with its scheduled tasks, its sidebar records, cl_audit's records), **Transcripts** (a switch:
  "Claude Code's too, 310", on by default; fixed once the switch starts) and **Takes** ("a few seconds, as clones";
  on another volume it says it's a full copy and how big), then what's never in a backup. During and after: "Made ·
  Before switch to ultra-2 · 5 Nov 18:40 · 3 s", and step 1 reads "Main's Claude window closed, backup made" with a
  check "Backup · 3 s ✓". The switch's receipt names the backup and the backup names the receipt, so Undo and the
  backup point at each other; Undo leaves the backup where it is. After a switch's backup is made, the backups past
  the number kept (General ▸ Backups) are deleted, never one a half-done switch names.
- **While it runs.** The page keeps every block; only the steps move on. Display colours mean one thing each: green
  is the account in use, mint is switching and the account switched to, amber is waiting for you or a warning, red
  is a failure; only the account in use is lit. A step under way is mint, one waiting for you amber, a done one a
  green tick, a failed one red. Each sign-in shows what its check saw ("Claude Code · ultra-2 ✓", "Window · ultra-1 ·
  not ultra-2"), compared by account, never by name. The line at the top says how far it got ("Switching · step 3
  of 5 · Claude Code") and holds the keys that lead out: **Cancel switch** (a red lamp, always in sight: while the
  window closes, and until Claude Code has signed in, when it puts everything back), then **Undo this switch…** (the
  switch the other way, then what the switch changed comes back from its backup: see
  [Restoring a backup](#restoring-a-backup)) once the profile is on ultra-2, and at Done "Main works on ultra-2 · ultra-1 on standby"
  with **Back to Main's settings**. Cancelled while the window was asked to quit, the window opens again if it
  closes anyway. When something fails, that step turns red and the line says where it stopped: the window didn't
  close (nothing moved), stopped half way (**Undo**), signed in as another account, the sidebar session didn't
  open, cancelled (**Close and switch** starts it again), or Undo itself stopped (**Try Undo again**; the receipt
  keeps the rest). Beside the profile's tile in Settings a display says the same in two lines: "Switch from ·
  ultra-1" while the page is open, "Switching ● · to ultra-2" in mint while it runs, "Switched to · ultra-2" at
  Done, and "Stopped half way · Undo it" in amber, with the page closed too, until it's undone. One switch of a
  profile runs at a time: while one does, every way to the Switch page leads to it.
- **The other account is back.** When a standby account's full limit resets (ultra-1's week, after the profile
  switched to ultra-2), one alert says so: "Claude Main: the other account is back · Its week starts again" (no
  address, as with every alert), with **Switch back…** and **Stay**; it follows the profile's Notify when back. The
  card gets a row, "ultra-1 is back: its week starts again", with **Stay** and **Switch back to ultra-1…**, and the
  Dock icon's and menu bar icon's menus list **Switch back to ultra-1…** above Switch account ›. The agent watches it from the
  account's last numbers: with a folder of its own, numbers read after the reset, current and not full (a reset
  that comes late waits for that read); without one, whose numbers nothing reads after a switch, once the reset
  time it last saw has passed. Missing numbers never count as "not full". Stay takes the offer away until it comes
  back again (if Stay starts cl_audit, it shows nothing and quits again); it goes by itself when the account fills
  up again or is switched to. **Switch back** opens the Switch page ("Switch Claude Main back to ultra-1"), the same switch the other way:
  every session in the window's sidebar goes back, those started on ultra-2 too, and the sidebar step puts them in
  their groups again (ultra-1's groups are still there, by their ids).

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
("Fable · week" in the large panel). Full, the row turns crimson and says when it's back ("full · back Thu 09:00"); it
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
(input, output, 5-minute and 1-hour cache writes, cache reads) and the cost estimate. cl_audit reads a session file
only from where it stopped last time, and only while the dashboard is showing. **Settings ▸ General ▸ Privacy ▸
Usage history** turns it off: then no session file is read, and the dashboard shows the limits only (the history,
the cost estimate, the CSV key and the launcher's 7-day row are hidden).

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
| Right-click | The menu: numbers, reset times, the sign-in, and actions (Switch account › with each of the profile's other accounts and their weeks (and, while a limit is full, Switch to … for the best one), Quick chat, Open or Show Claude window, Quit Claude window, Refresh now, Dashboard, Profile settings…, and Quit and keep Claude window when the window follows the Dock icon) |

A Dock icon draws what the agent saved for its profile, and asks the agent for Refresh now and Renew login.

Press and hold has no event of its own: the Dock asks the app for its menu on both right-click and
press-and-hold, and the icon checks which mouse button is down at that moment.

## Quick chat

A floating chat over any app, in Claude's own colours: a bar first ("Ask anything"), and after the first message a
chat window that stays floating, on every Space, until Esc hides it. It never brings cl_audit or the Claude app forward.
Claude Code answers it on the account a profile has in use, so it needs no API key and follows a switch.

- **Opening it:** the shortcut (off until you turn it on in General ▸ Quick chat; ⌥Space by default), or **Quick
  chat** in a profile's menu bar or Dock icon menu, which chats on that profile. Esc or ⌘W hides it and keeps the chat;
  opening it again brings it back as it was.
- **Asking:** Return sends, Shift-Return adds a line. Answers stream in as Markdown, code blocks have Copy, and under
  each answer are Copy, Ask again and "answered by Haiku 5.5 · 2.4 s". Follow-ups go on in the same Claude Code
  session; the pencil (⌘N) starts a new chat and shrinks the window back to the bar. Stop ends an answer where it is.
- **Model and thinking:** a picker for each under the field. Haiku with thinking off by default; a pick holds for that
  chat, and New chat goes back to the defaults in General. With thinking on, "Thought for 5 s" sits above the answer;
  it opens to show the thinking when Claude Code passes it on (for Haiku 5.5 it reports only that it thought).
  A model may still answer at once when it judges the question needs no thinking.
- **The account line:** the profile, the address of its account in use (masked unless Privacy shows addresses) and its
  week, in the level colours; the bar shows the profile and the week. When a limit is full, it says so before you
  send and offers **Switch account…** for the standby account with the most room, through the Switch page; what you
  typed goes once the switch is done.
- **When something goes wrong:** if Claude Code stops mid-answer, the window keeps what arrived, says what happened and
  offers Retry. Claude Code not installed, or the profile not signed in, says so with a way to fix it.

How it runs: the agent hosts it. Each chat is one `claude` process kept open between messages (closed after 10 minutes
idle; the next message goes on with the session), in print mode with stream-json in and out, on the profile's own
folder (`CLAUDE_CONFIG_DIR`) and in quick chat's work folder. It runs with no tools, no MCP servers, no settings files
and no slash commands, and it gets only an allowlisted part of the Mac's environment (home, user, language, proxies
and certificates), never a key, a token or another provider's settings, with Claude Code's non-essential traffic
(telemetry, error reports, update checks) off. Nothing of yours is sent but your messages, and only through Claude
Code; cl_audit adds a short system prompt of its own (answer briefly, no tools).

## Settings

Settings is a page of the same window as the dashboard (switch at the top, or ⌘,). The profiles run along
the top, with **General** first and **New profile** last. Changes are saved as you make them and the
icons follow at once; a profile's name or icon label is saved when you press Return or click elsewhere (Esc puts it back),
because that renames its Dock icon app; the top strip says when it's done. **Show emails** (General settings) off leaves email addresses out of the launcher, dashboard,
panels and Dock menus, and blurs them in Settings (hover one to see it), for screen sharing.

**Profile order:** drag a profile's tile left or right along the top (General stays first, ＋ last), or its card on
the dashboard (by the card itself, not one of its keys); the others move aside and a lit socket shows where it lands. It's saved when you let go ("Saved · order"); VoiceOver has Move left and
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
small lamp switch with a few words that follow the state, the same switch everywhere in cl_audit (the dashboard's
too). A change shows on it while it's under way: the lamp pulses green turning on, red turning off, and the words
say "turning on…" / "turning off…"; a setting that takes effect at once pulses briefly, one that takes work (Usage
in the Dock, In the menu bar, Keep in order, the dashboard's Claude window and Dock icon) pulses until the work is
really done. If it couldn't be done, the lamp blinks red twice, the switch goes back, and a grey line under it says
why. With Reduce motion the lamp stays lit green or red instead of pulsing. Two or three short choices are segments, longer ones a
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
- **Claude Code:** laid out like New profile's card: **Accounts** first, then **Folder**
  (`~/.claude` or a `CLAUDE_CONFIG_DIR` folder), then, for any folder but `~/.claude`, **Share from** and
  **Shared** (what the folder links to from another one: instructions, agents, skills, commands, memory and
  history). Shared is read-only here: cl_audit never moves or deletes real files, so a grey line says to change the
  links in the folder in Finder. The card's labels sit above their values (it stacks in any column under 480 pt,
  which in Settings is every column), so accounts and paths get the card's full width. Folders other profiles use
  (their own or one keeping a standby sign-in) are marked and can't be picked. The Claude window follows from the
  folder (see Profile above); it isn't a setting.

  **Accounts** lists the profile's claude.ai accounts, one box each. A profile works on one at a time, marked
  **IN USE**: the one Claude Code in its folder is signed in to. The others are **STANDBY**. Each box shows the
  address, the plan and organisation ("Ultra · Personal"), and every limit its plan has as bars, drawn like the
  dashboard's (Ultra: week and Fable; Max: 5-hour, week and Fable; Pro: 5-hour and week; usage credits while it
  spends them). A standby account's limits come from a sign-in kept for it in a small Claude Code folder of its own
  (say `~/.claude-ultra-2`), read like the profile's own, so you can see which account has room. Its sign-in always
  renews by itself (the box says so), unlike the account in use's opt-in **Renew sign-in by itself**, and only while
  that folder is signed in to the account cl_audit linked: one signed in to another account, or not linked yet, is
  neither read nor renewed. Only the account in use is lit ("Main works on it"); the standby accounts are unlit,
  most room first. Click one below its address to select it: its row lights in mint, and a **Switch account** key
  takes the place of STANDBY and opens the Switch page (click again to deselect). The order holds still while one is
  selected.
  - **Every account keeps a folder of its own.** With more than one account, the account in use gets one too
    (**Sign in…** in its box: "Keep its limits showing after a switch: sign it in once to a folder of its own"; one
    confirmation in the browser). Once that folder is signed in to it, the profile's numbers come from there, renewed
    by itself, instead of from the working folder, which still signs in again at each switch. So both accounts' limits
    stay live whichever is in use; nothing moves between Keychain items, it's one more sign-in, once per account. The
    box then says "Its limits come from a sign-in kept for it, renewed by itself." Log in… and the Dock icon's log-in
    sign in the folder the numbers come from.
  - Before a switch leaves an account without a folder of its own, the Switch page asks first: "Keep ultra-1's limits
    showing after the switch" with **Sign in ultra-1…** or **Skip**. Skipped, that account's limits show as last read
    on standby, and the page says when its week started again ("cl_audit hasn't read it since").
  - The **account in use**'s address is a pop-up: it ticks the account Claude Code in the folder is signed in to
    (green; red with a warning sign inside when it isn't the profile's account; a clock when the sign-in ran out; a
    long address is cut at its end), then, when it isn't the profile's, the profile's own account to log back in
    to, and **Renew sign-in by itself** (opt-in, see the (i)). Signed in to another account outside cl_audit
    (Terminal), **Use this account** shows in the box, and the profile shows no numbers until you choose, since
    they would be the other account's. If another profile has that account, the line under Accounts names it,
    with **Open** it instead: one profile per account. Anything else needing a word gets one grey line. A
    **Claude window** row says when the profile's window is signed in to another account than its Claude Code
    (only the account id is known, from the window's `config.json`; the usual Claude app is checked too). For a
    week after linking, the line under Accounts says when, which account it was and what stays with it, and that
    **New profile** gives the old account a profile again. See
    [Moving a profile to another account](#moving-a-profile-to-another-account).
  - A **standby** account's address is a pop-up with **Sign in…** (again) and **Remove from <profile>**, which
    takes it off the profile and leaves its folder and the sign-in in it as they are. Without a sign-in kept, its
    box says "Limits unknown: no sign-in kept for it" with **Sign in…**, which makes its folder and opens Claude
    Code's own sign-in in Terminal with the address filled in; once done, its limits show and its sign-in renews by
    itself. A folder signed in to the wrong account, or to another profile's, says so in the box.
  - **Add account** opens a pop-up (macOS's own menu) of what it finds on this Mac, two lines a row: the address,
    then in grey what is known about it. One click adds it. Accounts signed in in Claude Code folders no profile uses
    ("Ultra · Personal · signed in, ~/.claude-ultra-3 · limits once added") and the accounts this profile's Claude
    window has used, with their addresses from Claude Code's records ("Pro · Personal · needs a sign-in · used in
    Main's window in August"); other profiles' accounts are greyed and can't be added ("Work's · one profile per
    account"). Found accounts show no usage: cl_audit reads limits only for a profile's own accounts. Old or team
    accounts the window once used are only listed, never added by themselves. **Sign in to another account…** (last in
    the pop-up) turns the key into the address and **Sign in**: cl_audit makes a folder for it, named under the field
    ("in a folder of its own (~/.claude-ultra-4); Main keeps working meanwhile"), and opens Claude Code's own sign-in
    there in Terminal. An account belongs to one profile; no sign-in is ever copied between folders. New profile still
    starts with one account.
  - **A new account is a standby box from the start**, its display and one line saying what's left. **Signing in**
    (mint): "Finish the sign-in in the browser, as ultra-4@example.com." with **Cancel** (takes it off the profile
    again; its folder stays) and **Show Terminal**. **Wrong account** (amber), when Claude Code's sign-in in its
    folder is the profile's own account or another profile's: "The browser signed in as ultra-1, not ultra-4. Switch
    the browser's account, then sign in again." with **Cancel** and **Sign in again…**; cl_audit sees only what Claude
    Code recorded in the folder, not the browser, so it names the account the sign-in came back as. A sign-in to any
    other account is simply the account it names, linked within seconds. A sign-in under way for 15 minutes with
    nothing new in the folder turns amber, **Not finished**: "The sign-in didn't finish. Sign in again, or cancel."
    with **Cancel** and **Sign in again…**. cl_audit remembers (in memory only, nothing is saved) which account the
    folder was signed in to when you clicked Sign in…, and the sign-in is under way until that changes; after a restart
    of cl_audit it goes by the dates of the Terminal script each sign-in writes and of the folder's record. An account
    already linked (found as needing a sign-in, or signed in to another account since) shows the same states without
    **Cancel**: only an account with no seat yet can be taken off with it; Remove from the address menu does it for
    any. **Standby**: "No numbers yet: cl_audit reads them within a few minutes, from the sign-in kept in its folder,
    and keeps that sign-in renewed." until its limits show.

  Whether the Claude window's sessions go with the account (the sessions, the sidebar's sections and groups, pins
  and scheduled tasks) isn't a setting: the Switch page asks every time, with nothing chosen. As on every card, the
  pop-ups and fields fill their width, so their right edges line up; the
  address row is one line with Sign in and Cancel at its end (Cancel is a × when narrower), or, narrower still, the
  address on its own line with Sign in and × under it.
- **Sessions** (after Claude Code): what the profile keeps and the backups of it.
  - **Kept here:** "310 in Claude Code · 84 in the Claude window (24 in the sidebar) · 5.6 GB · since 6 Oct. Claude
    Code deletes terminal sessions 30 days after their last use; ones from the Claude window it keeps (Claude Code
    2.1.248 and later)." Counted in the background and remembered, so it shows at once. Sessions started or last
    continued in the Claude window or Cowork are kept at any age (Claude Code 2.1.248 and later), unless
    `desktopSessionCleanupPeriodDays` gives them a limit, you deleted or archived them in the window, or your
    organisation's managed settings (or an error in them), HIPAA or zero data retention make `cleanupPeriodDays` apply to
    everything; the line and the note under Keep for say which case applies. While `cleanupPeriodDays` or
    `desktopSessionCleanupPeriodDays` in `settings.json` isn't a valid number (or the file can't be read), Claude Code
    2.1.318 skips its clean-up; cl_audit adds a note and still shows what would be deleted once it's fixed. See [How cl_audit tells](#how-cl_audit-tells-what-claude-code-deletes).
  - **Keep for:** how long Claude Code keeps the transcripts of sessions you ran in the terminal: 30 days (its default), 90 days or a year. It writes
    `cleanupPeriodDays` in the Claude Code folder's `settings.json`, changing only that number in the file's own
    text (or adding the key after the opening brace of an ordinary object); everything else stays byte for byte. A
    `settings.json` that is a link is written where it points, replaced atomically, with its permissions; if it
    changed meanwhile nothing is written. It is made if the folder is there and there is none (or it is empty), and
    a folder that isn't there is never made. Anything else is refused and left as it was, with the reason in the row: a
    file that can't be read, isn't a JSON object, is a link to nowhere, has the key twice or deeper too, or whose
    value isn't a plain whole number ("set cleanupPeriodDays there by hand"). Then the row says "unknown".
  - **Backups:** one row each, "Before switch to ultra-2 · 5 Nov 18:40" over "84 sessions · 12 tasks · sidebar ·
    transcripts · 5.5 GB, sharing space with the originals" (on another volume: "a full copy"). **Restore…** opens
    the Restore page on that backup (see [Restoring a backup](#restoring-a-backup)). The **⋯** menu has **Show in Finder** and **Delete…**, which
    asks first and refuses a backup that a half-done switch names, or whose switch's receipt can't be read. **Back up now** makes one: with the profile's window open it says "close it first, or the Code-tab
    list and sidebar records are left out" and backs up only what is safe, Claude Code's transcripts and cl_audit's
    records. A line under the list says how many are kept (General ▸ Backups).
  - **Export:** **Export…** opens the Export page (see [Exporting a profile's sessions](#exporting-a-profiles-sessions)); the
    row says "Never exported. A file for another Mac or for keeping." and, after one, "Last exported 5 Nov · 5.5 GB".
  - **Import:** **Import…** opens the Import page ([Importing an export](#importing-an-export)): "From an export of this profile,
    another profile or another Mac." After an import, **Undo last import** is there too ("Last import 5 Nov 18:40: 210 sessions
    added from cl_audit Work 2026-10-30") until it is undone.
- **Alerts:** how often the agent reads the usage, and a notification from cl_audit when a limit
  reaches a set level (once per limit and reset). When a limit is full, a notification says when it's back
  ("Claude Work: 5-hour limit full · Back at 15:28, in 1h 42m"), and, when another of the profile's accounts has
  room, how much ("The other account has 92% of its week left") with **Switch account…** and **Later** (see
  [When a limit is full](#when-a-limit-is-full)). **Notify when back** (on by default) sends one
  more when a full limit resets ("Claude Work is back · The 5-hour limit reset at 15:28"); while the other limit
  is still full, it waits for that one. Fable's weekly limit alerts the same way ("Claude Main: Fable weekly limit
  full · Back Thu 09:00", "Claude Main: Fable is back"). With alerts on, one more when a profile starts spending
  usage credits ("Claude Work is using usage credits · The 5-hour limit is full · $0.40 spent so far") and one when
  they run out.
- **Claude window** (run by the agent, whether or not cl_audit is open):
  - **Claude window:** on ("its own window", or "the usual Claude app"), a Claude window signed
    in to the profile's account; off ("none"), none, and nothing opens one. Its folder and sign-in are kept, so
    turning it back on needs no new sign-in. One plain line under the switch says which window it is ("Opens as the
    usual Claude app, the one you get from the Dock or Applications." or "Opens as its own window, from this profile's
    Dock icon or menu. Opening Claude directly shows a different window, with other sessions."), the (i) names the data
    folder, and a profile on its own window that the offer below applies to has **Make the default profile…** here.
    A profile on its own window also has a small "own window" mark on its dashboard card and its tile.
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
  - **Press and hold**, then the **Usage panel** design as keys (Glow, Rings, Numbers, Segments, Pace) with one
    large preview under them, the panel's limits at this profile's numbers, like General ▸ Card style; then the
    **Icon** style as tiles: Two numbers, Rings (outer = 5-hour, inner = week), Big number; Twin rings, Segmented, Pace
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
    changes; or the profile's colour. A full limit is crimson, except in System, where its countdown shows it.
  - **Label:** none, or the profile's label before its icon ("MAIN").
  - **When full:** the countdown beside the icon ("1h 42m"), or crimson only.

  A click opens the profile's menu: its limits (Fable's when the plan has one, when each resets, usage credits
  while they're spent), when they were read, then **Open Claude window**, **Refresh now**, **Dashboard**,
  **Profile settings…** and **Hide from the menu bar**.

The cards sit in three columns: Profile, Claude Code, Sessions, Claude window and Alerts on the left, the Dock icon in the
middle, the menu bar on the right. In two columns the menu bar goes under the left cards and the Dock icon stays
beside them; in one column everything follows in that order.

### General settings

Three columns, each with its subject printed at the top: **cl_audit** (Usage in the background, Privacy, Backups,
Quick chat, About),
**How usage looks** (Face, Dashboard cards, Widget) and **The Dock** (App icon, Dock). In two columns the Dock goes
under cl_audit; one column keeps the same order, top to bottom. Every row is one line.

- **Usage in the background:** whether usage is being read ("Reading usage · 2 profiles · every 2–5 min", or red
  "Not reading · stopped 12 min ago"), then whether **Alerts** reach you (Allowed, or "Not allowed" with **Allow…**,
  which opens System Settings ▸ Notifications ▸ cl_audit), **Last read**, and only while reading has stopped
  **Start reading**, with a note under the rows (cl_audit also retries by itself every minute) and the reason it
  won't start. The dashboard's red display opens this card. The agent shows as **cl_audit Agent** in Activity
  Monitor; macOS restarts it if it's force-quit. To stop it, turn cl_audit off in System Settings ▸ General ▸ Login
  Items & Extensions.
- **About:** the version and build, a link to what's new, when the agent last cleaned up ("Nothing to clean up ·
  11:38", "Cleaned up 2 leftovers · Thu 09:00"; the (i) lists what went) and **Uninstall cl_audit…** (see
  [Uninstalling](#uninstalling)).
- **Privacy:** **Show emails** ("shown" / "hidden", see above), and **Usage history** ("tokens, cost, CSV", read from
  this Mac's Claude Code session files; or "limits only": no session file is read and the dashboard shows the
  limits only).
- **Backups:** where the profiles' session backups go and how many are kept. **Where** is "cl_audit's folder ▸
  backups" (`~/Library/Application Support/usage-n-uf/backups`) or a folder you pick with **Change…** (a Finder
  panel; **Use default** goes back), with **Show in Finder**. **Keep the last** (3) and **And any under** (30 days)
  say what stays: the last N of each profile plus any made under D days ago. Stored with cl_audit's other
  preferences. Backups already made stay where they were if the folder changes. See
  [Backups of a profile's sessions](#backups-of-a-profiles-sessions).
- **Quick chat:** see [Quick chat](#quick-chat).
  - **Shortcut:** off by default. On, it opens the chat from any app: ⌥Space, ⌃⌥Space, ⌥⇧Space, ⌃Space or ⌘Space.
    It's checked against macOS's own Space shortcuts (Spotlight, Finder's search, the input sources, as this Mac has
    them set) and the Claude app's Quick Entry, and a line says which it clashes with, or that another app already
    holds it. It's registered the way macOS's own app shortcuts are, so there's no Accessibility permission to give.
  - **Profile** the shortcut chats on (the first by default), **Model** (Haiku) and **Thinking** (off) for a new chat.
  - **Where it keeps things:** each profile's chats, which Claude Code keeps in that profile's folder under
    `projects/<the work folder's name>/` and deletes after 30 days by default, with their count and size; the work
    folders and the settings in `~/Library/Application Support/usage-n-uf/quick-chat/`. Each has **Show in Finder**.
    Nothing goes into macOS preferences.
  - **Counting:** off by default: quick chats are left out of a profile's Sessions card and backups.
  - **Remove quick chat data…** moves every profile's quick chats, the work folders and the settings to the Trash,
    after the chat closes; the shortcut turns off. A profile's other sessions stay as they are.
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

- **Account first:** the Claude Code card's **Account** pop-up, like a profile's Claude Code ▸ Accounts ▸ Add account, lists the accounts signed
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
  isn't asked: a new profile on `~/.claude` gets the usual Claude app while no profile has it, any other new profile
  its own Claude window; it is saved in the profile and doesn't change with the folder's name. With Claude
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

### The default profile

The default profile is the one on `~/.claude` with the usual Claude app: what Claude shows when it is opened from the
Dock or Applications, and what `claude` uses in Terminal. First run makes it (above). A Mac set up the old way (26.11.4
and earlier could make the first profile on a new folder such as `~/.claude-account` with its own Claude window, or move
the folder to `~/.claude` later and keep the window kind) shows other sessions when Claude is opened directly.

For that, cl_audit offers once, in a card, never automatically: **Make the default profile the one Claude opens
directly** (Settings ▸ General, the first card). **Not now** folds that card to one line in Settings ▸ General; the
**Make the default profile…** key also stays on the profile's Claude window card. Until **Not now**, the Accounts card
carries a note when the account in use is also the one the usual app uses; **Not now** takes that note away too. It shows for the sole or first profile when that profile has its own window, whatever its folder
(including `~/.claude`), and for a `~/.claude` profile without a sign-in next to a profile on its own window. It does
not show when the usual app already belongs to a signed-in profile. The page lists what each step does and what each
window-dependent setting becomes (Claude window stays as it is, and is now the usual app; Dock icon, Open Claude and
the menu bar icon open the usual app; Opens from, With Dock icon and Sessions follow stay as set).

- **A profile already on `~/.claude`** (a sign-in exists): window data only. No sign-in step and no transcript move,
  since it is the same Claude Code folder. Both Claude windows are closed (the usual app's and the profile's own),
  a backup is made of the profile's window data and of the usual app's own, the profile's `desktop` becomes the usual
  app (saved), and the profile's whole Code-tab list and sidebar arrangement move from its data folder
  (`~/Library/Application Support/Claude-<profile>`) into the usual app's (`~/Library/Application Support/Claude`):
  every entry, not only an import's, by the restore engine, merging and never overwriting. An entry the usual app
  already has by id stays exactly as it is and is listed; one missing is written into the account folder the profile
  works on, as a switch would place it. A helper session then arranges the sidebar groups, as after a switch.
- **A profile on another folder** (`~/.claude-account` with its own window): step one signs Claude Code into
  `~/.claude` (its own login, in Terminal, with the old profile's address filled in; cl_audit never moves or copies a
  sign-in). The `~/.claude` profile is the one already in the list, or is made then. Then the same moves, plus the old
  profile's transcripts into `~/.claude/projects` (never over one that is there). The What moves card says, as the
  Restore page does, how many of those transcripts Claude Code's clean-up would delete again where they land (**Would
  be deleted**, by the Sessions card's rule and `~/.claude`'s settings; the row isn't there when none would be), and the
  restore's own page says the same with its **Keep for 90 days** key. Last, the old profile can stay as a
  standby account of the default profile (its folder and sign-in untouched; only when it is another Claude account),
  or be removed with the usual remove flow (which signs its folder out of Claude Code).
- **Nothing is deleted** from the old window's folder: it stays as the backup's source and for Undo.
- **Undo this move** (on the page, or **Undo this restore** on the move's restore page) takes back exactly what was
  added, only files unchanged since, and puts the profile's window kind back (and removes a `~/.claude` profile the
  move made). Cancel works while waiting for the sign-in and while the windows close; a stopped move keeps what is back
  (Finish or Undo). If cl_audit quits while the files are being written, the card on Settings ▸ General sends you to
  that restore's page (Finish or Undo); **Put it back** is offered only when no file was written.
- **Once the old profile was kept as a standby account or removed,** the move can't be undone any more (Undo would take
  away a profile or folder that now holds the only copy of something), and the page says so; its backup is still listed
  under Sessions in the default profile's settings.
- **An import made earlier into the old window's data** is carried over with everything else. Its own **Undo last
  import** is then not offered (it would change only the old folder); **Undo this move** takes the sessions out of the
  usual app, and the Sessions card says so.

Import, Restore and the Switch page say which window they write into: "the usual Claude app", or "Main's own window,
opened from its Dock icon" (with the profile's name), and the Import and Restore previews say whose data the entries go
into and where to open it.

Technical notes. A profile's window kind is `AccountEntry.desktop`, decided once when the profile is made
(`DesktopMode.forNew`: the usual app for `~/.claude` while no profile has it, else its own window) and stored; nothing
works it out from the folder's name later. The default folder is always used with `CLAUDE_CONFIG_DIR` unset: set to
`~/.claude`, Claude Code takes it for a custom folder (its record moves to `~/.claude/.claude.json` and its Keychain item
gets a hash suffix), which is not the sign-in the usual app and cl_audit read. The move keeps a record of its own in
cl_audit's folder (`default-moves/`) next to the restore's receipt and journal (`restores/`); the receipt's id is written
into the record the moment the restore creates it. The agent watches a profile that has no readable sign-in every 3
seconds (one stat of its folder's record) and reads the Keychain only once that record names an account, at most every 30
seconds.

### Removing a profile

**Remove profile…** (profile settings, or right-click its tile) removes its Dock icon app and what macOS
keeps for it: preferences, caches, saved window state, its pin and recent-apps entry in the Dock (the Dock
restarts only if one was there) and its Launch Services record, plus its saved usage, the agent's alert
marks for it, Terminal scripts and place on the dashboard. **Delete its folders too** also signs its Claude Code
folder out (its Keychain login goes) and deletes that folder and its Claude window's data folder; links
inside are removed, never what they point to. The default `~/.claude`, the standard window and a folder
another profile shares items from are never deleted, and Claude must be closed first.

### Backups of a profile's sessions

A backup is a quick copy of a profile's sessions on this Mac, in `<backups folder>/<profile id>/<backup id>/` with a
`backup.json` that says what is in it. One is made by every switch that moves the sessions (right after the window is
known closed, before anything moves, under the switch's lock) and by **Back up now** in Settings ▸ the profile ▸
Sessions. **Restore…** on a backup puts back what is missing, merged, and never overwrites anything (see
[Restoring a backup](#restoring-a-backup)).

- **In it:** the window's Code-tab list (every `claude-code-sessions/<account>/<org>` folder, scheduled tasks
  included, for both accounts and any other found there), its sidebar records (only the `epitaxyPrefs` part of
  `claude_desktop_config.json`, as its own file: the rest of that file holds MCP settings, which can carry keys),
  cl_audit's records (the profile's name and its account and standby ids, never an address, and the receipt of the
  switch it was made for) and, on by default, Claude
  Code's transcripts (`<Claude Code folder>/projects`). The manifest has the backup's id, profile, kind (before a
  switch, naming the receipt, or manual), when, how many seconds it took, the accounts by id only (never an
  address), counts (sessions, sidebar ones, tasks, transcripts), the size and, per item, its original absolute path
  and its path inside the backup.
- **Never in it:** a sign-in. No `.claude.json`, nothing named like credentials, nothing from the Keychain (cl_audit
  doesn't touch it for this), and nothing outside those paths. Each file is opened without following links and
  copied from that open file, so a link swapped in meanwhile is left out; under `projects/` a file with another hard
  link is left out too. The backups folder can't be, or hold, what is copied from (the Claude Code `projects`
  folder, the Claude window's data).
- **How it is copied:** as APFS clones, file by file, so it takes seconds and shares space with the originals; the
  list says "sharing space with the originals". On another volume a clone can't be made, so the file is copied for
  real (first checking there is room), and the list says "a full copy". A source file is never changed, and a backup
  is built under a hidden name and renamed into place whole, never over another.
- **If it can't be made,** a switch stops with nothing moved and says why (step 1 on the Switch page). The window is
  checked closed again when the backup is done; if it opened meanwhile, the backup is taken away and nothing moves.
  The receipt records the backup's id and folder, so changing the folder later doesn't lose it. **Back up now** with the window open
  leaves out the Code-tab list and sidebar records (the window rewrites its entries from memory); a switch always
  has the window closed.
- **How many are kept:** General ▸ Backups sets the last N (3) and any under D days (30). After a switch's backup
  (and after Back up now) the rest are deleted, never one named by a switch that stopped half way (its Undo and the
  backup point at each other, nor one a restore that stopped half way needs); **Delete…** in the list asks first
  and refuses those too.

### Restoring a backup

**Restore…** on a backup in Settings ▸ the profile ▸ Sessions opens the **Restore page**, a sibling of the Switch page
with the same keys and the same line at the top. It starts as a **preview** ("Preview · nothing written yet ·
nothing is ever overwritten"); nothing is written until **Close and restore N** is pressed. The backup can be any in
General ▸ Backups, or one a switch's or restore's receipt names in a folder General ▸ Backups no longer points at: the
Sessions list shows those too, with where they are ("in ~/Old/backups"), and Restore, Show in Finder and Delete… use
that place.

**What happens** is counted from the backup against what is there now, by session id across every account folder of
the window's Code-tab list, and transcripts by their path under the Claude Code folder's `projects`:

- **Back where it was:** entries (and transcripts) that are there, unchanged since: nothing to do. An entry a switch
  re-encoded when it moved it (the old account's error keys and Remote Control ids off) counts as unchanged. A
  transcript that has grown since (the backup is its first part) counts here too.
- **Missing, restored:** written back. Entries go into the folder of the account the profile works on now (where a
  switch would have moved them), never into the folder of an account it no longer uses; an entry that was on another
  account in the backup is written as a switch would place it. A task file comes back only when the account in use's
  own is missing; one that is there is never replaced, even when it is empty. A transcript comes back as a clone of the
  backup's file (a real copy from another volume), with the backup's modification time.
- **Made after it:** sessions made later stay. **Deleted since:** an entry the window deleted since (its own
  `deleted_` marker) stays deleted.
- **Changed since:** there, and different: what is there stays, and the copy in the backup is only listed
  (**Show the list**: sessions by a short id, never a title, transcripts by path). Never overwritten.
- **In use:** transcripts of a Claude Code session that runs: left alone and listed. A session is seen only by its id on
  a process's command line (`--resume <id>`, `--session-id <id>`: one `ps`). A session resumed from its own picker, or
  with `--continue`, is not named there, so **a missing transcript of such a session is not seen as held** and is
  written back (the write only ever creates a file that isn't there; if the session writes the same name first, the
  restore leaves it as it is). A transcript that is already there is never written to either way; one changed in the
  last two minutes is only listed as in use. If `ps` can't be read, no missing transcript is written and the page says so.
- **Would be deleted:** only the restored transcripts Claude Code's own clean-up would delete again (the rule is the
  Sessions card's, decided per transcript from the backup's own bytes and its release marker; a marker already in the
  folder stays as it is and decides): terminal sessions older than `cleanupPeriodDays`; sessions of the Claude window
  only when `desktopSessionCleanupPeriodDays` or the organisation's managed settings give them a limit and they are past
  it, or you deleted or archived them in the window. The row isn't there when none would be. **Keep for 90 days** (not
  when the organisation sets the number) sets `cleanupPeriodDays` in `settings.json`, the one key cl_audit ever writes
  there, and is shown only when 90 days would keep some of them ("Keep for 90 days would save 1"): never for one 90 days
  still deletes.

**Stays as it is:** the account (Main stays on the account it works on; Switch back changes that), sign-ins (never in a
backup, never written), the window's MCP settings and `settings.json` other than Keep for, and claude.ai (Chats and
Projects). **Sidebar:** the groups and pins of the restored sessions are taken from the backup's own sidebar records
and arranged by one Return in a helper session, as after a switch; the window's cache is off, so claude.ai's copy wins
at sign-in.

**Steps:** 1 the profile's Claude window closes (only that window, about half a minute; skipped when nothing in the
window comes back); 2 what is listed comes back, merged by the rules above; 3 the window opens, and the sidebar is
arranged. The page then reads **Restored · 86 back · nothing overwritten · 3 listed** with **Undo this restore** and
**Back to Main's settings**.

- **Nothing is overwritten, ever.** Files are made with an exclusive create (a clone that fails when the name is taken,
  or a temp file linked into place), never over a name that exists, never through a link. The backup is read through
  directory descriptors without following a link; **a backup holding anything that isn't a plain file with one link
  refuses the whole restore** (as does a file named like a sign-in, a path that isn't a plain relative one, a file its
  `backup.json` names that is missing, a newer manifest, or another profile's backup). A project folder (or `projects`
  itself) that is a link is not written through: its transcripts are left out and the page says so.
- **The window stays closed** while its files are written, asked again before every one; if it opens, the run stops
  with what is back kept and the receipt says so. **One switch, restore or import at a time** (the switch lock, and
  claude-transplant's lock too), and none while a switch of the profile stopped half way: the page says **Not yet ·
  one thing first**, names it and offers **Open the switch** (Undo puts back exactly what it moved; then restore if
  anything is still missing).
- **A receipt** in cl_audit's folder (`restores/<id>/receipt.json`, with `journal.jsonl` beside it: one line before a
  file is written and flushed to disk, one after) says what was put back. The line before holds the hash the file must
  have (an entry's own bytes as written; a transcript's from the backup's file, read before the clone is made), so a
  crash between the write and its second line is still known: Undo takes such a file back if it is exactly that, and
  finishing the restore counts it as back. **Stop, keep what's back** stops after the file being written. A restore that
  stopped (Stop, the window opened, the Mac stopped) shows on the profile's tile as "Restore stopped · Finish or
  undo" and opens on a page with **Finish restoring** (continues the same receipt; also when nothing is left to write,
  when it is only marked finished) and **Undo this restore**, which takes back exactly what it put back and only files
  unchanged since (a restored transcript Claude Code has written to since stays, and it says so), and the folders it
  made, if empty. Undo closes the profile's window itself when window files are among them (the click is the
  consent; the same Cancel while it closes, the same rules as a restore), and stops, keeping what it took back, if the
  window opens meanwhile. A file that has landed is never deleted by name afterwards, except by Undo's check: if what
  is there isn't the backup's file (a running session may have appended to it), the restore leaves it and says so.
  Temp files of a restore (`.restore-<the first 20 characters of the receipt id>-….tmp`, in the window's folder) are swept
  at the end, at Undo and whenever finishing starts (also with the window open: only those names are touched), and a
  crash's second hard link goes with them. A step the finish can't check safely (a window file while the window is
  open) stays "not done" in the receipt, not dropped, and Undo takes it back if the file is exactly what the step says.
  An Undo leaves a restored transcript a running Claude Code session holds, and lists it, like a restore does. cl_audit
  offers to finish after a stop rather than finishing by itself: it would have to close the window unasked. Receipts of
  finished or undone restores go when their backup is gone (its place can be looked at, and the backup isn't in it; a
  place on a disk that isn't plugged in says nothing) or after 30 days; one that wrote something and didn't finish never
  does. Deleting a backup says when it ends Undo for a finished restore from it. A backup an Undo this switch is about
  to restore from is kept from pruning until that restore has run (30 days at most). A file in a project folder that is
  shorter than the backup's file and that the backup's file begins with (what a crash during a copy from another
  volume leaves, among other things) is shown as "Shorter copy" and left as it is; the receipt remembers how many, so the
  Restored page says so too. An Undo that leaves a restored transcript a running session holds does not close the
  receipt: it says how many it left and why, and Undo again once the session has ended takes the rest. If which
  sessions run can't be read, an Undo that has transcripts to take back takes nothing back and says so.
- **Undo this switch…** on the Switch page is the switch the other way and then a restore from the backup the
  switch made: the page says so before it starts ("Switches back to ultra-1, then puts back anything the switch
  changed from its backup: nothing is overwritten"), the sessions follow, and its last step (and a key at Done) opens
  the Restore page on that backup, counted fresh after the switch back. It stays two pages because the restore needs the
  window closed again and its counts only mean something after the sessions have moved back.

### How cl_audit tells what Claude Code deletes

For people who want the detail (Sessions card ▸ Kept here and Keep for, and Would be deleted on the Restore, Import and
default-profile pages). cl_audit follows the clean-up of the installed Claude Code (checked against 2.1.318) and reads,
never writes:

- **Which sessions belong to the Claude window.** The transcript itself, never the Code tab: the `entrypoint` of its
  first line that has one (within the first 64 KB), or of its last (within the last 64 KB), is `claude-desktop`,
  `claude-desktop-3p` or `local-agent`. A session begun in the terminal, continued in the window and then in the terminal
  again is a terminal session: only the two ends count.
- **Release markers.** `<session>.desktop-released.json` next to the transcript (an object with a `reason`, at most 4096
  bytes) is what the Claude window writes when you delete or archive a session. `delete` ends the exemption at once;
  `archive` after a grace period (once the marker is older than `cleanupPeriodDays`).
- **The limit for the window's sessions.** `desktopSessionCleanupPeriodDays` above 0 caps them (a hard cap, grace
  included): the longer of it and `cleanupPeriodDays` applies; 0 is no limit.
- **The organisation's managed settings, from every source.** The server-managed cache `remote-settings.json` in the
  Claude Code folder, MDM (`/Library/Managed Preferences/…/com.anthropic.claudecode.plist`) and
  `/Library/Application Support/ClaudeCode/managed-settings.json` plus `managed-settings.d/*.json` (alphabetical, a later
  value replacing an earlier one); plain files only, at most 2 MiB (8 MiB for the cache). `cleanupPeriodDays` in any one of
  them ends the window exemption (the first source that holds any setting supplies the value, else the smallest); so does a
  managed document that is there but can't be used (not readable, not a plain file, too big, not a JSON object, a bad
  value). The cap is the smallest any source sets; a 0 counts only when none caps. A missing file is simply not there.
  When your organisation's managed settings use a policy helper (`policyHelper` or `policyHelpers`, a program that
  computes managed settings when Claude Code starts), cl_audit can't see the period it sets, so it counts the Claude
  window's sessions as deleted too (the safe side).
- **A skipped clean-up is only a note.** While `cleanupPeriodDays` or `desktopSessionCleanupPeriodDays` in your own
  `settings.json` isn't a valid number, or the file can't be read, Claude Code (2.1.318) skips its clean-up (unless
  managed settings set `cleanupPeriodDays` or use a policy helper); cl_audit adds a note and still shows what would be
  deleted once it's fixed. It counts with the defaults: 30 days for an invalid `cleanupPeriodDays`, no limit for an
  invalid `desktopSessionCleanupPeriodDays`, both for a file that can't be read. Any whole number up to 2^53−1 is valid, as for Claude Code. A
  `settings.json` that is a link to nowhere, a folder or a FIFO counts as no file (it is read at most 2 MiB, never
  waiting). The same skip for a bad managed document isn't modelled: there it says the sessions are deleted (the safe
  side).
- **Not visible from here.** HIPAA and zero data retention (the info text says so), and a project's or local
  `.claude/settings.json`, which can set a shorter `cleanupPeriodDays`.

### Exporting a profile's sessions

**Export…** (Settings ▸ the profile ▸ Sessions) makes the profile's sessions one file, for another Mac or for keeping. It
is a backup in a file: the same format, so Import restores it by the same rules. The **Export page** is a sibling of the
Restore page and starts as a preview ("Preview · nothing written yet"):

- **What:** **From** is the profile as it is now (a fresh copy is made under the switch lock, in a hidden folder of the
  backups place, and taken away again), one of its backups, or all profiles. Claude Code: "310 sessions, with their
  sub-agent files" (the transcripts and what sits beside them in their folders); Claude window: the Code-tab entries and
  scheduled tasks, and the sidebar records (with the window open they are left out, as for Back up now); Cowork: left out.
- **Keys found:** every transcript and the window's files are searched, in chunks that overlap so nothing is missed at a
  boundary, for **GitHub tokens** (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_` and `github_pat_`), **AWS access keys**
  (`AKIA`/`ASIA` and 16 more), **private keys** (a `-----BEGIN … PRIVATE KEY-----` header, PGP too), **Anthropic API
  keys** (`sk-ant-`), **OpenAI-style keys** (`sk-` with 40 more characters, one a digit), **Slack tokens** (`xoxb-` and the
  other `xox` kinds), **Google API keys** (`AIza`), **Stripe live keys** (`sk_live_`, `rk_live_`) and **npm tokens**
  (`npm_`), **Supabase** (`sbp_`), **GitLab** (`glpat-`), **Hugging Face** (`hf_`), Slack's refresh tokens (`xoxe-`,
  `xoxe.xoxp-`) and **JWT tokens** (`eyJ…​.eyJ…​.` and a signature; counted as their own kind). A shape counts only at the start
  of a word ("task-fix-the-login-page" is not a key); in a transcript a newline is the two characters `\n`, and a key right
  after `\n`, `\t` or `\r` starts a word (a key after an escaped newline is found, also at a chunk boundary). The page counts the sessions
  that hold each kind ("5 sessions hold keys: 2 GitHub tokens, 3 private keys") and never shows or writes a key. A session is
  its transcript and the files in its folder, so one key anywhere in it holds the whole session. **Leave them out** (the
  default) or **Keep them: needs a password**, which forces an encrypted disk image.
- **Password:** **None: a zip** (made with macOS's own `ditto`, so Finder opens it) or **An encrypted disk image** (AES-256, made
  with `hdiutil`, read-only compressed). The password is typed twice into secure fields (at least 8 characters), handed to
  `hdiutil` on its standard input, never as an argument, and emptied from the page the moment the export starts; it is never
  stored, shown again or logged, and lost means the image can't be opened.
- **Preview:** per project folder (the folder the transcripts ran in, read from the transcripts), "210 · 3.9 GB · 2 in use,
  copied up to their last full line", "5 with keys: left out". A transcript a running Claude Code session holds, or changed
  in the last two minutes, or that doesn't end on a full line, is copied up to its last complete line. The file's name is
  "cl_audit Main 2026-11-05.zip"; the Save panel asks where (the folder you used last, else Downloads). Keys: **Cancel** and
  **Export 305 sessions · ≈ 5.5 GB**; **Stop** while it runs; **Show in Finder** when done. The row in Sessions then reads
  "Last exported 5 Nov · 5.5 GB".
- **What is never in it:** a sign-in (nothing a backup excludes: `.claude.json*`, anything named like credentials, Keychain,
  OAuth or `auth.json`), the window's MCP settings, `settings.json`, a switch's receipt, `deleted_` markers, an address or a raw
  account id. Accounts appear as a **fingerprint**: `fp-` and 8 hex characters of an HMAC-SHA256 of the id under a key made
  at random for each export and never written anywhere, so a guessed address or id can't be confirmed by hashing it, and the
  same account is the same fingerprint everywhere in one file only (folder names, the manifests, the sidebar records' scope
  keys, and any account id or address of the profile inside the window's entries and task file). "Made on this Mac" is a
  random install id kept in cl_audit's preferences, not made from the Mac's name. The identities replaced are the ones cl_audit
  knows: every profile's accounts (account ids, organisation ids, addresses, from the list and from what Claude Code recorded in
  each folder's `.claude.json`: ids and addresses only, never a token) and every account and organisation folder name under each
  profile's `claude-code-sessions/`, whichever profile is exported, case-insensitively. In the JSON files (entries, the task
  file, the sidebar records) it is done on the decoded strings and field names, so an address written `@` is found too;
  every other byte is left as it was. Before packing, every file but the transcripts is searched for those same identities
  (as written, written with the line breaks and spaces taken out, and decoded) and for a private key; a hit, or a file of 64 MB
  or more that can't be checked, stops the export with a message naming the file; nothing is stripped silently. Any other id
  and any other address (a stranger's in a title) is content, as it is in a transcript: your own words, copied as they are. So
  an export of a backup knows only the identities cl_audit knows **today**: an address of an account that is no longer known
  anywhere on this Mac passes like a stranger's. The profiles' names, and the folder the archive is made in, are scrubbed too
  (a profile named for its address shows its fingerprint).
  A **zip** also leaves out each Code-tab entry's `remoteMcpServersConfig` and `sessionSettings` (connection settings and
  environment values the key scan can't recognise); the page says so ("Connection settings in 12 Code-tab entries need the
  encrypted disk image: left out of a zip"), and an entry or task file it can't read as UTF-8 JSON (UTF-16, say) is left out of a zip too,
  said on the same line. The encrypted disk image keeps them, and the keys looked for are searched in them.
  Claude Code's **retention markers** (`<session>.desktop-released.json` in a project's folder) travel with their
  transcript: one whose transcript isn't in the file (it is gone, or left out for keys) is left out too and counted on the
  page ("5 leftover markers left out"), never a reason to stop. **Restore** and **Import** write a marker only together with
  its transcript in the same run, never over a marker that is there; Undo takes both back.
- **The file:** `<name>/export.json` (format `cl_audit-export`, version 1, when, cl_audit's version, a fingerprint of this Mac's
  name, zip or image, what was done with keys, the profiles and their sizes) and `<name>/profiles/p1/` (a backup's layout:
  `backup.json`, `window/<fp>/<fp>/…`, `sidebar/`, `records/`, `transcripts/…`), one `pN` per profile for "All profiles". The
  manifests carry no absolute path of this Mac.

### Importing an export

**Import…** (Settings ▸ the profile ▸ Sessions) opens the **Import page**: **Choose…** (an Open panel for a `.zip` or
`.dmg`; an image asks for its password), then **Into** (the profile; a file of several profiles also asks which one). It
reads the file, and shows a preview ("Preview · nothing written yet · nothing is ever overwritten") that says how it was made
("made on another Mac"). **The file is unpacked as a backup of the target first, then restored from: the same rules as Restore**
(kind "Imported from cl_audit Work 2026-10-30", listed with the other backups, Restore… on it works).

- **What happens:** **New** (transcripts, their other files and Code-tab entries that aren't here: added), **Already here** (the
  same content, or longer here: skipped), **Grown on both sides** (there and different, or the file's is longer: the target's
  copy stays, listed), **Code-tab entries** (the window closes and opens again), **Scheduled tasks' sessions** (sessions a
  scheduled task ran are left out, with the task's name; the tasks themselves aren't imported), **Folder not here** (added, shown
  once that folder exists), **Would be deleted** (only the sessions Claude Code would delete again, as on the Restore page; **Keep for 90 days** when it would keep some). Entries go into the folder of the account the target
  works on now, never a fingerprint's, written as a switch would place them (the old account's error keys and Remote Control
  ids off), and the sidebar's groups and pins follow them through the fingerprint (one Return in a helper session). **Close and
  import 210 sessions** then runs the Restore page's steps (window closes, files added with a receipt kept as it goes, window
  opens), with the page reading "Importing ●" and "Imported · 210 added · nothing overwritten".
- **Undo last import,** under the profile's Sessions, opens that import's page, where **Undo this import** takes back exactly what
  it added (B2's Undo this restore on the import's receipt: only files unchanged since, only folders it made, if empty).
- **The file is hostile input.** The whole import is refused, with nothing written into any profile and nothing left unpacked, on:
  a file that is not a zip or an encrypted `.dmg`; **a zip** whose central directory is damaged, in several parts, with an
  encrypted entry, a compression an export doesn't use, a name that is absolute, has `..`, a backslash, a NUL or an empty part, more
  than one top-level folder, two names that are one on this Mac's disks (case, Unicode form), a link, a device or any entry
  that is neither a file nor a folder, or that declares more data than twice what its `export.json` states (plus 64 MB) or
  more than 128 GB (a size, offset or count no file can have, such as zip64's 2^64 - 1, is refused, never added up); **a zip
  that is not exactly its central directory**: each local header must carry the directory entry's name, method, flags and
  sizes (a data descriptor's width is decided by the local header's zip64 extra, and its local sizes must be 0 or the
  directory's), and the local records must tile the file from its first byte to the directory (a hidden local-only entry, a
  gap, bytes before the first record, a lying local size: refused), only the zip64 end record its locator points at may sit
  between the directory and the end record; an `export.json` (read out of the zip itself before anything is unpacked) that isn't format
  `cl_audit-export`, is a **newer version**, or whose sizes don't add up; **an image** that isn't encrypted (cl_audit makes no
  other), with a wrong password, or whose top isn't exactly one folder.
  **Import does not unpack with ditto** (Export still makes its zip with `ditto -c -k`, so Finder opens it). ditto goes by the
  local headers and by where a deflate stream ends, and it writes a record hidden after that end, whatever the directory
  says. cl_audit unpacks with its own reader into a fresh 0700 folder under the backups place: for each entry the directory
  names, in order, stored or deflate only (anything else, such as bzip2 or lzma, is refused); the data read from the checked
  place and inflated with zlib's raw inflate in 64 KB steps, which must end exactly at the entry's last byte with no input
  left over (zlib says how many input bytes are left after the stream's end, so slack is seen however well the data
  compresses; Apple's Compression doesn't say, and swallowed up to a chunk of it, so it isn't used); the
  output exactly the size the directory says, stopped the moment it would pass it; the CRC-32 the directory's; a folder entry
  holding data is refused. Names are at most 512 bytes in all, 255 a part, 16 parts, and two names that a case-insensitive APFS
  holds as one (case folded after NFC: "σ" and "ς") are refused as a duplicate.
  Files are made `O_CREAT|O_EXCL|O_NOFOLLOW` at 0600 with no attribute, flag or mode of the archive, every folder above one
  made step by step through descriptors opened `O_NOFOLLOW|O_DIRECTORY`, the entry's own modification time set (the UTC time
  of the Info-ZIP Unix extra 0x5855 that ditto writes, or of the extended timestamp 0x5455, else the DOS time, which is local
  time; held to 1 Jan 1980 ... now, so a hostile 2106 can't make every file look recent). The zip64 end record, when there
  is one, must have its signature and say what the 32-bit end record says. Any failure
  refuses the whole import and removes the folder. The bomb guard is exact: a running total of bytes written is checked
  against the cap (twice what `export.json` states plus 64 MB and 8 KB an entry) before every write, and the volume's free
  space against a floor (2 GB or 1% of the disk, whichever is more, never more than a quarter of it: from the disk's size,
  not from what is free) at every step; the room check before unpacking is "free > declared + floor", a disk that fills has
  its own message ("the disk is nearly full"), and a volume that can't be looked at stops the unpacking, never runs it
  unguarded. An image is attached read-only, not browsable, in a private mount point after checking macOS really mounted it
  read-only, nosuid and nodev, walked, copied out file by file **as data only** and detached. After unpacking,
  **anything that isn't a folder or a plain file with
  one hard link**, **a file or folder with a file flag (uchg and the like would land immutable, and neither Undo nor the sweep
  could remove it), an ACL, an extended attribute (but the ones macOS puts on a new file itself) or a setuid, setgid or sticky
  bit**, a name that isn't plain or is named like a sign-in, a file its manifests don't name, a file they name that is
  missing, a size that differs from the manifest's, a manifest from a newer cl_audit, a path in it outside the places a backup
  keeps things, or anything written outside the unpacking folder. Modes are set to 0700/0600 on what is unpacked (a mode that
  can't be set refuses the import). It is then made a backup file by file through the backup's own copy rules (a clone or a
  copy from an open file, plain single-link files only, never over a file), each file looked at again after it landed (no
  flag, ACL, attribute or mode but 0600), and the backup.json's accounts, counts and parts are rebuilt from what was checked
  (not believed). The restore clones from that backup, so what it clones is data only: a clone carries the source's flags, ACL
  and attributes, and the backup's files have none. It is restored create-only, as a restore.
- **Memory files** (`<project>/memory/…`, which Claude Code loads into every session of that project) from **any** import
  file are **left out by default**: whenever the file holds any, the preview has a row "Memory files N: left out" (or "N:
  added" once you pick **Add them**) with **Leave them out / Add them** and the list. Where a file says it came from (this
  Mac's install id, this profile's id) is only what it says, and a forged file says the same, so it earns no trust; "made on
  this Mac / another Mac" is information on the File row only. A file already there is never replaced either way.
- **Scheduled tasks' sessions** are left out whole: the entry, its transcript and the files in its folder, none counted as added.
  (Which key of an entry marks one is not verified against a real entry: any top-level key with "scheduledtask" in its name.)
- **Group names** from the file reach the sidebar helper session's prompt, so for an import they are cut to letters, digits,
  spaces and `- _ . , ( ) & '`, at most 40 characters (a name with nothing left is dropped); the preview's Sidebar card lists
  the groups it will create.
- **Work folders** (`.import-…`, `.export-…`) are hidden in the backups place, each with a file naming the process that made
  it (its pid and start time). They are taken away when the page is left, the action ends or cl_audit quits (the tools it runs
  are stopped, an attached image detached); a later launch removes at once one whose process is gone, and one with no such
  file only after a day. A folder that still holds a mount is never removed or entered.

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
5. **Sign Claude Code in** to the new account, for the profile's folder, in Terminal:
   `env -u CLAUDE_CONFIG_DIR claude auth login --claudeai --email <new>` for `~/.claude`,
   `CLAUDE_CONFIG_DIR=<folder> claude auth login --claudeai --email <new>` for a profile's own folder, and finish in
   the browser.
6. **Link it:** the agent notices within half a minute; the profile then shows no numbers until you press **Use
   this account** (Claude Code card, in the account in use's box), which links it (refused if another profile
   already has that account).

Staying with the old account: a CI token from `claude setup-token` (make a new one), claude.ai connectors and MCP
servers, cloud sessions and environments, synced plugins, and the plan and billing. To keep watching the old
account's limits, add it to the profile as a standby account (Claude Code ▸ Accounts ▸ **Add account**), or give it
a profile of its own (**New profile**).

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
