<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/logo-light.svg">
    <img alt="cl_audit by n-uf" src="docs/logo-light.svg" height="60">
  </picture>
</p>

# cl_audit

> [!CAUTION]
> ## Not yet stable
>
> **cl_audit is young and still changing. Its settings, the data it stores and the way it reads Claude's files are not final.**
>
> Version numbers are dates (YY.M.R), not semantic versions, so any release may change them, and a newer Claude Code or Claude app can stop parts of cl_audit working until it is updated. Backups and exports stay readable by newer versions, but an older cl_audit can't open newer ones. Read the [CHANGELOG](CHANGELOG.md) before you upgrade. For figures you can rely on, Claude's own Settings ▸ Usage page and `/usage` in Claude Code are the source.

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

**Checked with Claude Code 2.1.318 and the Claude app 5.1231.2** (cl_audit 26.11.19). cl_audit relies on how
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
   it is, and the step says in one line that other accounts come later (by themselves, or New profile). Or **Sign in…**
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
cl_audit says "Claude Code isn't installed on this Mac · Install…" beside the key (and in the Account
pop-up) instead of greying it silently; Install… opens the same install help.

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

**One sign-in per profile.** cl_audit reads only the sign-in of the account in use in each profile's folder. A
profile's standby accounts have no sign-in kept anywhere: switching to one is Claude Code's own sign-in again, in
Terminal and the browser. The Claude Code folders 26.11.16 and earlier made for standby accounts' sign-ins are listed
with **Move to Trash…** (see [Profile settings](#profile-settings)); their Keychain items are named so you can delete them
in Keychain Access, and cl_audit never touches them.

## Words used here

- **Profile:** one Claude setup in cl_audit: its Claude Code folder and sign-in, and, if you want them, a Dock
  icon and a Claude window. **Account** means only the claude.ai account a profile is signed in to: each
  profile is linked to one account seat (account and organisation), and no two profiles share one.
- **In use / standby:** a profile's folder holds one signed-in account at a time, the one **in use**; the profile's
  other accounts are **standby**: remembered on it, signed out, never read. A **switch** signs Claude Code in again on
  the same folder as one of them.
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

### Which account is in use

Each profile has one **active account**, shown with a green lamp and "in use" on every screen: the menu bar icon's
menu, the Dock icon's menu and its panel, the dashboard card, Settings ▸ the profile ▸ Accounts, the Switch page and
the quick chat.

- **The Claude app's signed-in account comes first.** The app's settings file names the account
  (`lastKnownAccountUuid` in its `config.json`); its log gives the organisation and whether it signed out. The log is the
  app's `main*.log` in `~/Library/Logs/Claude`, newest first, after the app's launch: the newest line about that account
  ("Initialization succeeded", "identity reevaluate" or "oauth-v2 lookup") gives its organisation, else the newest of the
  app's `claude-code-sessions/<account>/<organisation>` folders does; an "Account logged out" or "Login-state transition
  … loggedOut … true" line newer than `config.json` means signed out. So an app that switched accounts and back shows the
  account it is on. Without a `config.json`, the log's own account line says it, as claude-transplant reads it. Only
  those lines are looked at and only the ids are kept; the log is used only while one Claude app runs (several windows
  share it). This was worked out from the Claude app's own files, not by running it.
- **Then Claude Code's.** With the app signed out or not readable (or a profile without a Claude window), the account
  Claude Code's folder is signed in to (its `.claude.json`) is the active one, and a muted line says why.
- **The numbers say whose they are.** They come through Claude Code's sign-in in the profile's folder. When that isn't
  the active account: "Usage: Claude Code on b…@example.com".
- **Live:** the folders that hold `.claude.json` and `config.json`, and the app's logs, are watched; a sign-in changed
  in Terminal or the Claude app shows within a few seconds, without restarting anything.
- **One answer:** cl_audit's background agent decides this once per profile (`Sources/AccountResolver.swift`) and writes
  it into the profile's status record; every screen shows that record and decides nothing itself, so they never
  disagree. While the agent isn't running, the settings window fills the record with the same rule.

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
- **Another account.** A profile is one Claude Code folder, and the folder holds one signed-in account at a time: the
  one **in use**. The profile's other accounts (Settings ▸ the profile ▸ Claude Code ▸ Accounts) are **found on this
  Mac by themselves**, the way claude-transplant finds them: the Claude window's `claude-code-sessions/<account>/<org>` and
  `local-agent-mode-sessions` folders, Claude Code's `.claude.json` records and their backups, and the `accountUuid` in
  the folder's transcripts; each is named "address · organisation" (an organisation that isn't a team's is "Personal"), or
  "account" and the first 8 characters of its id until it is seen signed in. Only ids, dates and those named fields are
  read, never a token. There is no Add account: **Forget…** takes one off for good, and **Sign in with another
  account…** runs Claude Code's sign-in with no address for a brand-new one. They stay **signed out**: no folder or
  Keychain item of their own, nothing reads them, so they show no usage. The card shows
  them as **unlit trays** under its limits, one line each: the address, STANDBY, then its plan and when it was last in
  use ("Ultra · last in use 3 days ago"). They come in the order a full limit offers them: those not known to be full
  first, the least used by the week they left with, then the most recently in use (that week is kept only for this
  order, never shown). **While a limit is full, the first is selected already**: its
  row lights mint across the card with the lit bar, and its STANDBY display becomes the lit **Switch account** key,
  which opens the Switch page with that account picked; a click on another tray picks it instead. **With room left
  nothing is selected**: a click selects a tray, a second click deselects it (as in Settings). The alert adds "You can
  switch to another of its accounts: Claude Code signs in again on this profile's folder." with **Switch account…** (and Later): alerts
  reach the lock screen, so they never name an account by its address or any part of it. **The menus** (the menu bar
  icon's and the Dock icon's, with the same items) show the account in use under the profile's name with a lit green
  lamp ("ultra-1 · in use"; the Dock menu's first line reads "Claude Main · ultra-1 in use") and have **Switch account
  ›**, a submenu with the account in use ticked ("in use · week 94%") and every other account in the same order, each
  with when it was last in use ("3 days ago"). While a limit is full, the first one not known to be full
  also sits on the top level, "Switch to ultra-3…": right under the full line in the Dock menu, first in the menu bar
  menu's actions. All of them open the **Switch page** in cl_audit. A short name is the address before the @, its first
  letter only while emails are hidden (and in the menus).
- **The Switch page.** The account in use (NOW, lit, with its limits) and, under TO, the account picked (in mint) and the
  profile's other accounts below it (click another to switch to it instead); **What changes**: Claude Code in Terminal
  and editors using the profile's folder moves to that account, sessions running now included; the Claude window's
  Code-tab sessions and scheduled tasks on ultra-1 move to ultra-2 inside the profile's folder (how many, said), with a
  backup first; the window closes for the move, and you sign it in to ultra-2 yourself when you open it again; the
  transcripts stay in the folder; the profile's name, Dock icon, look, folder and settings stay; the account it leaves
  stays on the profile as a standby account. Then the steps and **Switch to ultra-2**. Once it has ended the card is
  **What changed**, in the past tense: what is true now (reached: ultra-2 in use, the sessions moved, ultra-1 standing
  by; another account or no sign-in: where the sessions are, with **Undo the move**).
- **The move** is claude-transplant's (4.2.1, MIT): with the window closed (its own quit; it stays closed until the
  sign-in ends), under cl_audit's lock and claude-transplant's own, a backup first; each `local_<id>.json` entry is
  written to the new account's `claude-code-sessions/<account>/<org>/` without the old account's error keys and Remote
  Control ids, checked, and only then is the original set aside in cl_audit's folder (nothing is deleted); the scheduled
  tasks follow with their skips and retries (a task the new account has with other state stays, and so do its sessions);
  a transcript that last pointed at the old account's Remote Control copy gets Claude Code's own empty pointer line. A
  session a running Claude Code owns (its id on a `claude` process's command line, or in the folder's
  `sessions/<pid>.json`) is **held**: it stays with the old account until a later switch. A receipt notes every step
  before and after it, so **Undo the move** puts back whatever got done, until Claude Code is on the new account.
- **Switching**, after the move, is signing in again on the same folder, as the other account, the way
  cl_quick does: Claude Code's own sign-in opens in Terminal for the profile's folder
  (`claude auth login --claudeai --email <address>`, with `CLAUDE_CONFIG_DIR` unset for `~/.claude` and set for any other
  folder, and a key or another provider the shell's settings name unset), finished in the browser. The browser's
  claude.ai account decides which account signs in, so cl_audit checks: it looks at the folder's `.claude.json` every
  2 seconds, for up to 10 minutes, until its account changes. **Reached** ("Now on ultra-2 · ultra-1 on standby",
  with Switch back to ultra-1… and Back to Main's settings); **another account** ("Signed in as ultra-3 · not
  ultra-2": the profile works on ultra-3 now, ultra-1 stands by; Sign in as ultra-2 again, after switching the
  browser's account, or Keep ultra-3); **timed out** ("No sign-in · sessions on ultra-2", with Try again and Undo the
  move; "· nothing changed" when nothing moved). Signed out for a moment while you sign in is still waiting. **Cancel**
  stops waiting; moved sessions stay where they went until Undo. cl_audit never sees a password or a token, and never
  copies, moves or reads a sign-in; the Claude app's sign-in is yours to change.
  Beside the profile's tile in Settings a display says the same in two lines ("Switching ● · to ultra-2" in mint while it
  waits; "Switched to · ultra-2"; "Signed in as · ultra-3"). One switch of a profile at a time.
- **The folder's account is the one in use, whoever signed it in.** Run `claude auth login` yourself in Terminal, or
  sign in from another app on the same folder: within a second (cl_audit watches the folders that hold `.claude.json`
  and the window's `config.json`) the profile works on that account and the one before stands by (the agent notices it
  too while cl_audit's window is closed). Its numbers show at once, and every screen labels them with the account they
  were read for, never a stored name. **The Claude app's account** is read the way claude-transplant reads it: the
  app's `main*.log`, newest first, after the app's launch ("[LocalSessionManager] Initialization succeeded …
  accountId=…, orgId=…"; a "Login-state transition … loggedOut … true" or "Account logged out" line means signed out),
  cross-checked with its `config.json` `lastKnownAccountUuid`; only those lines are looked at and nothing else from the
  log is kept. That account is the profile's active one, and every screen, the Switch page included, shows the one
  answer the agent records for the profile: see [Which account is in use](#which-account-is-in-use). One account
  belongs to one profile: an account
  another profile works on is refused (the card says whose, and the profile's numbers wait until its folder is on one of
  its own); an account on another profile's standby list moves to this one, said on both profiles' Accounts card.
- **A switch waiting for you.** While Claude Code's sign-in waits in the browser, the Switch page is easy to lose behind
  it. Then, only while the page isn't in front, one alert says so: "Claude Main: the switch is waiting for you · Finish
  Claude Code's sign-in in Terminal and the browser. cl_audit checks the account when it's done." with **Show switch**
  and **Cancel switch**; a plain click on it is Show switch too. It goes when the switch ends or the page comes to the
  front, never outlives cl_audit, and follows the profile's alerts. Like every alert it names no account.
- **A switch that stopped half way** (now or in 26.11.16 and earlier): the Sessions card says how many of the window's
  sessions sit under which account (they show while the window is signed in to it), with **Undo it** (the window
  closed). Switches' backups stay listed and restorable (Settings ▸ the profile ▸ Sessions); an unfinished switch's
  backup is never pruned.

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
| Right-click | The menu: numbers, reset times, the sign-in, and actions (Switch account › with each of the profile's other accounts and when it was last in use (and, while a limit is full, Switch to … for the one offered first), Quick chat, Open or Show Claude window, Quit Claude window, Refresh now, Dashboard, Profile settings…, and Quit and keep Claude window when the window follows the Dock icon) |

A Dock icon draws what the agent saved for its profile, and asks the agent for Refresh now. With the sign-in expired or
signed out, its one key is Log in… (Claude Code's own sign-in in Terminal).

Press and hold has no event of its own: the Dock asks the app for its menu on both right-click and
press-and-hold, and the icon checks which mouse button is down at that moment.

## Quick chat

A floating chat over any app, in Claude's own colours: a bar first ("Ask anything"), and after the first message a
chat window that stays floating, on every Space, until Esc hides it. It never brings cl_audit or the Claude app forward.
Your own Claude Code answers it, signed in to the account a profile has in use, so it counts against that account's limits
and follows a switch.

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
  send and offers **Switch account…** for the standby account offered first (not known to be full, the least used by
  the week it left with), through the Switch page; what you
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
  which in Settings is every column), so accounts and paths get the card's full width. Folders other profiles use are
  marked and can't be picked. The Claude window follows from the
  folder (see Profile above); it isn't a setting.

  **Accounts** lists the profile's claude.ai accounts, one box each. A profile is one Claude Code folder, and the folder
  holds one signed-in account at a time: **IN USE**, the one Claude Code in its folder is signed in to, lit, with
  the plan and organisation ("Ultra · Personal") and every limit its plan has as bars, drawn like the dashboard's
  (Ultra: week and Fable; Max: 5-hour, week and Fable; Pro: 5-hour and week; usage credits while it spends them). The
  others are **STANDBY**: remembered on the profile, signed out, with no folder or Keychain item of their own. Nothing
  reads them, so a standby box shows no limits: its plan and when it was last in use on the profile ("Last in use on
  Main 3 days ago"), or "Remembered by its
  address: it signs in when you switch to it". They come in the order a full limit offers them. Click one below its
  address to select it: its row lights in mint, and a **Switch account** key takes the place of STANDBY and opens the
  Switch page (click again to deselect). The order holds still while one is selected.
  - The **account in use** box shows the profile's **active account** (see
    [Which account is in use](#which-account-is-in-use)): its lamp is green while it is in use, also when only Claude
    Code's account can be shown (the Claude app signed out or unreadable: a muted line says so), off when Claude Code's
    folder is on another profile's account, and an account in use is never listed on
    standby at the same time. Its address is a pop-up: it ticks the account Claude Code in the folder is signed in to
    (red with a warning sign inside when it is another profile's account; a clock when the sign-in ran out; a
    long address is cut at its end), then **Log in…** (Claude Code's sign-in in Terminal with its address
    filled in, watched like a switch: "Logging in" until Claude Code's login ends well; the same key under the box when
    the sign-in ran out or the folder is signed out) and **Renew sign-in by
    itself** (opt-in, see the (i)). Whatever account signs in to the folder, from cl_audit or Terminal, is the one in
    use, by itself: the one before joins standby. If another profile works on that account, the line under Accounts
    names it, with **Open** it instead: one profile per account, and the profile's numbers wait until its folder is on
    one of its own. An account that came from another profile's standby list (or left for another profile) says so in
    one line with **OK**. When the profile's Claude window is signed in to another account than its Claude Code (read
    from the app's log and `config.json`), the box shows the app's account and says whose the numbers are ("Usage: Claude
    Code on b…@example.com"). A switch moves the window's Code-tab sessions and scheduled tasks inside the profile's
    folder (a backup first, with Undo); the Claude app's own sign-in is yours to change. For a week after a switch, the line under Accounts says when, which account it was and what stays with it.
    See [Moving a profile to another account](#moving-a-profile-to-another-account).
  - A **standby** account's address is a pop-up with **Switch to it…** and **Forget…** (asks first; it takes the account
    off the profile for good, and nothing on this Mac changes).
  - The standby accounts are **found by themselves** (see the dashboard's Another account above); no sign-in is ever
    copied, and an account belongs to one profile. **Sign in with another account…** runs Claude Code's own sign-in on
    the profile's folder with no address filled in: the account that signs in becomes the one in use, and the one
    before goes on standby. New profile still starts with one account.
  - **Folders from before.** Up to 26.11.16 cl_audit kept a standby account's sign-in, and the account in use's when it
    had standby accounts, in a small Claude Code folder of its own (`~/.claude-ultra-2`). Those folders aren't used any
    more. Each one that is still there (a plain `~/.claude-<name>` folder directly in your home folder that no profile
    uses as its folder or Claude window folder) is listed under Accounts with **Move to Trash…** and **Keep it**. Move
    to Trash asks first, says what is in it ("its sign-in record, settings.json and 2 other items") and names the
    folder's Keychain item ("Its sign-in stays in your Keychain as “Claude Code-credentials-1a2b3c4d”: delete that in
    Keychain Access if you no longer need it"); cl_audit never touches that item, never signs the folder out, and never
    deletes a folder by itself. A folder that holds sessions is never offered for the Trash: it says how many and offers
    **Show in Finder** instead. Keep it stops this list asking.
  - A folder that isn't there is never read, and cl_audit never starts Claude Code for it (not Renew sign-in, logout,
    quick chat, Terminal or the Claude window), so a folder you deleted isn't made again; a sign-in you start makes its
    new folder first, and never goes through a link.

  As on every card, the pop-ups and fields fill their width, so their right edges line up; the
  address row is one line with its key and Cancel at its end (Cancel is a × when narrower), or, narrower still, the
  address on its own line with its key and × under it.
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
    asks first and refuses a backup that an old switch which stopped half way names, or whose switch's receipt can't be read. **Back up now** makes one: with the profile's window open it says "close it first, or the Code-tab
    list and sidebar records are left out" and backs up only what is safe, Claude Code's transcripts and cl_audit's
    records. A line under the list says how many are kept (General ▸ Backups).
  - **Export:** **Export…** opens the Export page (see [Exporting a profile's sessions](#exporting-a-profiles-sessions)); the
    row says "Never exported. A file for another Mac or for keeping." and, after one, "Last exported 5 Nov · 5.5 GB".
  - **Import:** **Import…** opens the Import page ([Importing an export](#importing-an-export)): "From an export of this profile,
    another profile or another Mac." After an import, **Undo last import** is there too ("Last import 5 Nov 18:40: 210 sessions
    added from cl_audit Work 2026-10-30") until it is undone.
- **Alerts:** how often the agent reads the usage, and a notification from cl_audit when a limit
  reaches a set level (once per limit and reset). When a limit is full, a notification says when it's back
  ("Claude Work: 5-hour limit full · Back at 15:28, in 1h 42m"), and, when the profile has another account on standby,
  offers it ("You can switch to its other account…"; with several, the one that had the most of its week left when it
  was last in use, with no figure, since standby accounts show no usage) with **Switch account…** and **Later** (see
  [When a limit is full](#when-a-limit-is-full)). **Notify when back** (on by default) sends one
  more when a full limit resets ("Claude Work is back · The 5-hour limit reset at 15:28"); while the other limit
  is still full, it waits for that one. Fable's weekly limit alerts the same way ("Claude Main: Fable weekly limit
  full · Back Thu 09:00", "Claude Main: Fable is back"). With alerts on, one more when a profile starts spending
  usage credits ("Claude Work is using usage credits · The 5-hour limit is full · $0.40 spent so far") and one when
  they run out.
- **Claude window** (run by the agent, whether or not cl_audit is open):
  - **Claude window:** on ("its own window", or "the usual Claude app"), a Claude window signed
    in to the profile's account; off ("none"), none, and nothing opens one. The window's data folder and its sign-in are kept, so
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
  preferences. Backups already made stay where they were if the folder changes. When the folder is one you picked, a
  line says once that backups hold copies of Claude Code's settings and scripts (CLAUDE.md, settings.json, the scripts its
  hooks run), and that a key found in settings.json or a script its hooks run is left out; **Got it**
  hides it for that folder, and a folder you pick later shows it again (remembered per folder, since where the copies sit is
  what the line is about; cl_audit's own folder never shows it). See
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

- **Account first:** the Claude Code card's **Account** pop-up lists the accounts signed
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

### Experimental: switching, import, export, restore and the default profile

Switching a profile's account, importing, restoring a backup, exporting or moving to another Mac, and making the default
profile are **experimental**: they are still unstable and can lose data, so use them for testing only, never on anything
you can't afford to lose. Each of their pages starts with an **"Experimental: may lose data"** panel. Before one of them
runs, cl_audit asks for your consent every time: a sheet that says what can go wrong, with a box to tick ("I understand
the risk and use this feature at my own risk"); **Cancel** is the default, and nothing runs until you tick the box and
**Continue**. Each accepted run adds one line to `consent.log` in cl_audit's own folder (the date, the feature and
cl_audit's version: no address or account). cl_audit comes as is: the **No Liability** clause of its
[license](#license) (PolyForm Perimeter 1.0.1) applies.

### The default profile

*Experimental: see [above](#experimental-switching-import-export-restore-and-the-default-profile).*

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
the menu bar icon open the usual app; Opens from and With Dock icon stay as set).

- **A profile already on `~/.claude`** (a sign-in exists): window data only. No sign-in step and no transcript move,
  since it is the same Claude Code folder. Both Claude windows are closed (the usual app's and the profile's own),
  a backup is made of the profile's window data and of the usual app's own, the profile's `desktop` becomes the usual
  app (saved), and the profile's whole Code-tab list and sidebar arrangement move from its data folder
  (`~/Library/Application Support/Claude-<profile>`) into the usual app's (`~/Library/Application Support/Claude`):
  every entry, not only an import's, by the restore engine, merging and never overwriting. An entry the usual app
  already has by id stays exactly as it is and is listed; one missing is written into the account folder the profile
  works on, without its old account's error keys and Remote Control ids. A helper session then arranges the sidebar
  groups.
- **A profile on another folder** (`~/.claude-account` with its own window): step one signs Claude Code into
  `~/.claude` (its own login, in Terminal, with the old profile's address filled in; cl_audit never moves or copies a
  sign-in). The `~/.claude` profile is the one already in the list, or is made then. Then the same moves, plus the old
  profile's transcripts into `~/.claude/projects` (never over one that is there). The What moves card says, as the
  Restore page does, how many of those transcripts Claude Code's clean-up would delete again where they land (**Would
  be deleted**, by the Sessions card's rule and `~/.claude`'s settings; the row isn't there when none would be), and the
  restore's own page says the same with its **Keep for 90 days** key. Last, the old profile's account can stay as a
  standby account of the default profile (remembered, signed out; only when it is another Claude account): its folder
  with its sessions, settings and sign-in stays exactly as it is and is never offered for the Trash; or the
  old profile is removed with the usual remove flow (which signs its folder out of Claude Code).
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
`backup.json` that says what is in it. One is made by **Back up now** in Settings ▸ the profile ▸ Sessions (and by the
default-profile move), and by every switch that moves the window's sessions, before anything moves ("Before switch to
ultra-2"); those stay listed and restorable. **Restore…** on a backup puts back what is missing, merged, and never overwrites anything (see
[Restoring a backup](#restoring-a-backup)).

- **In it:** the window's Code-tab list (every `claude-code-sessions/<account>/<org>` folder, scheduled tasks
  included, for both accounts and any other found there), its sidebar records (only the `epitaxyPrefs` part of
  `claude_desktop_config.json`, as its own file: the rest of that file, the window's **MCP settings**, is **never in a
  backup**, since it can carry keys; it travels only in the encrypted export), each scheduled task's prompt
  (`setup/scheduled-tasks/<id>/SKILL.md`, which the window runs),
  cl_audit's records (the profile's name and its account and standby ids, never an address; an old switch's backup also
  holds that switch's receipt) and, on by default, Claude
  Code's transcripts (`<Claude Code folder>/projects`) and Claude Code's **setup** (`setup/…`: CLAUDE.md and what it includes,
  skills, agents, commands, output styles, keybindings, settings.json with its scripts and the plugin list, by the rules
  of [Exporting](#exporting-a-profiles-sessions): links left out and named in the manifest only, never where they point;
  each file with its SHA-256 and execute bit; format version 2, or 3 when it holds a task's prompt; version-1 and -2 backups
  are read as before).
  **settings.json in a backup keeps its `env` names with every value blank** (`envBlanked` in the manifest): it is written
  from the parsed file, so nothing a parse drops comes along, and no command (a hook, `apiKeyHelper`) is ever run. One that
  isn't a JSON object is left out, with the scripts its hooks run, and listed. Env values travel only in the encrypted
  export. Backups made by 26.11.8 still hold them (and their MCP settings) as they were.
  **A plain backup then runs the Export page's key check** (the same `SecretScan` as "sessions mention API keys or tokens") over
  what it is about to write. It scans exactly three things: settings.json, the scripts its hooks and status line run together with
  the skills, agents or commands that hold such a script, and the plugin marketplaces file. It does not scan CLAUDE.md, included
  files, or skills that no hook runs. And it finds only the key shapes the Export page knows (GitHub, AWS, `sk-`, Slack, Stripe, npm
  and similar keys, private keys, JWTs): an opaque token of another shape is not found. Scripts are scanned as the copies that
  landed in the backup (a UTF-16 file with a byte order mark is decoded first); settings.json as the object that is written.
  - Inside `hooks`, a hook entry any of whose values matches (a command, an http hook's `url` or headers) is **dropped whole**, its
    matcher too when that empties, and the event when that empties: a hook is never blanked, because an empty http `url` makes
    Claude Code ignore the whole settings.json, and a blank command would run nothing while looking like a guard. In
    `permissions.allow`, `deny` and `ask` a rule that matches is dropped as well. The manifest names them ("PreToolUse (Bash)",
    `permissions.deny[1]`: `secretHooksDropped`, `secretRulesDropped`, names only).
  - Any other string value that matches (an `apiKeyHelper` like `echo sk-…`, a value deep in the file; an array element too) is
    blanked to `""` with its key kept, and the manifest lists where, as dotted paths (`secretBlanked`).
  - A script a hook runs, a skill, agent or command that holds one (the unit goes whole or not at all), and
    `plugins/known_marketplaces.json` whose bytes match are left out and named in the manifest (`secretLeftOut`, "script
    hooks/x.sh"). A file that can't be read back counts as a match.

  Restore says it on the setup row ("a hook held a key: left out of backups", "held a key: left out of backups; it travels only in
  the encrypted export"); Export from a backup says the image lacks them. The image of the profile as it is now, and an import's
  staged backup, keep everything.
  The manifest has the backup's id, profile, kind (before a
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
  leaves out the Code-tab list and sidebar records (the window rewrites its entries from memory).
- **How many are kept:** General ▸ Backups sets the last N (3) and any under D days (30). After Back up now the rest are
  deleted, never one named by an old switch that stopped half way (it holds the sessions that switch moved, as they
  were), nor one a restore that stopped half way needs; **Delete…** in the list asks first and refuses those too.

### Restoring a backup

*Experimental: see [Experimental](#experimental-switching-import-export-restore-and-the-default-profile).*

**Restore…** on a backup in Settings ▸ the profile ▸ Sessions opens the **Restore page**, a sibling of the Switch page
with the same keys and the same line at the top. It starts as a **preview** ("Preview · nothing written yet ·
nothing is ever overwritten"); nothing is written until **Close and restore N** is pressed. The backup can be any in
General ▸ Backups, or one an old switch's or a restore's receipt names in a folder General ▸ Backups no longer points at: the
Sessions list shows those too, with where they are ("in ~/Old/backups"), and Restore, Show in Finder and Delete… use
that place.

**What happens** is counted from the backup against what is there now, by session id across every account folder of
the window's Code-tab list, and transcripts by their path under the Claude Code folder's `projects`:

- **Back where it was:** entries (and transcripts) that are there, unchanged since: nothing to do. An entry an old
  switch re-encoded when it moved it (the old account's error keys and Remote Control ids off) counts as unchanged. A
  transcript that has grown since (the backup is its first part) counts here too.
- **Missing, restored:** written back. Entries go into the folder of the account the profile works on now, never into
  the folder of an account it no longer uses; an entry that was on another account in the backup is written without
  that account's error keys and Remote Control ids. A task file comes back only when the account in use's
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

**Scheduled tasks** row: the account in use's task file comes back as it was (this Mac's own tasks, not paused) only when none
is here, with the tasks' prompts that are missing (`<Claude Code folder>/scheduled-tasks/<id>/SKILL.md`); a prompt that is here
stays. There is no MCP row: this Mac's own backups don't keep the window's MCP settings (Stays as it is says so in one line);
only a backup an import staged from an encrypted image has them, and its Restore page has the Import page's MCP row. The
setup row says in one line that a backup's settings.json has its env values blank, when it has one.

**Stays as it is:** the account (Main stays on the account it works on; a switch changes that), sign-ins (never in a
backup, never written), a `claude_desktop_config.json` that is here and `settings.json` other than Keep for, and claude.ai
(Chats and Projects). **Sidebar:** the groups and pins of the restored sessions are taken from the backup's own sidebar records
and arranged by one Return in a helper session; the window's cache is off, so claude.ai's copy wins
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
  with what is back kept and the receipt says so. **One restore, import or move at a time** (cl_audit's lock, and
  claude-transplant's lock too), and none while another restore of the profile stopped half way: the page says **Not
  yet · one thing first** and names it. (An old switch that stopped half way no longer holds a restore back.)
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
  does. Deleting a backup says when it ends Undo for a finished restore from it. A file in a project folder that is
  shorter than the backup's file and that the backup's file begins with (what a crash during a copy from another
  volume leaves, among other things) is shown as "Shorter copy" and left as it is; the receipt remembers how many, so the
  Restored page says so too. An Undo that leaves a restored transcript a running session holds does not close the
  receipt: it says how many it left and why, and Undo again once the session has ended takes the rest. If which
  sessions run can't be read, an Undo that has transcripts to take back takes nothing back and says so.

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
- **A key written twice.** In `settings.json` and in a managed document, `cleanupPeriodDays`,
  `desktopSessionCleanupPeriodDays`, `policyHelper` and `policyHelpers` take their last top-level value, as Claude Code's
  JSON.parse does (a name written with escapes is the same name; nested ones don't count). Keep for refuses a file that
  has `cleanupPeriodDays` twice.
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

*Experimental: see [Experimental](#experimental-switching-import-export-restore-and-the-default-profile).*

**Export…** (Settings ▸ the profile ▸ Sessions) makes the profile's sessions one file, for another Mac or for keeping. It
is a backup in a file: the same format, so Import restores it by the same rules. The **Export page** is a sibling of the
Restore page and starts as a preview ("Preview · nothing written yet"):

- **What:** **From** is the profile as it is now (a fresh copy is made under cl_audit's lock, in a hidden folder of the
  backups place, and taken away again: the only copy that keeps the MCP settings and settings.json's env values, for the
  image), one of its backups (which keep neither: the image then has settings.json with blank env values, and the setup row
  says so in one line), or all profiles. Claude Code: "310 sessions, with their
  sub-agent files" (the transcripts and what sits beside them in their folders); Claude window: the Code-tab entries and
  scheduled tasks, and the sidebar records (with the window open they are left out, as for Back up now); Cowork: left out.
  A scheduled task travels with its prompt (`scheduled-tasks/<id>/SKILL.md` in the Claude Code folder, key-scanned like a
  skill; a prompt no task names stays out), also when the setup row says Leave them out: "4 scheduled tasks with their
  prompts: an import adds them only if you pick Add them, and paused".
- **MCP settings:** the window's `claude_desktop_config.json` without its sidebar part: "2 MCP servers (github, remote) and the
  window's other settings". Its env values, headers and arguments can hold tokens no scan recognises, so **only the encrypted
  disk image carries it**; a zip leaves it out and says so. In the image it is scrubbed like the window's other files (a known
  address or account id becomes its fingerprint) and the leak check reads it. One that is a link, over 8 MB (an import refuses
  one that big) or not a JSON object is left out at the source, and the row says why.
- **Claude Code setup** (on by default; the menu says **Include them** or **Leave them out**): "CLAUDE.md with 2 included files,
  23 skills, 4 agents, 6 commands, 1 output style, keybindings, settings.json with 4 hooks and a status line, 3 scripts, 2
  plugins to reinstall". It is the part of the profile's Claude Code folder that is configuration, not history:
  `CLAUDE.md` and every `.md` file it pulls in with `@path` (recursively, 5 deep; an `@` in a code span or fenced block is
  not an import; a path is taken relative to the importing file, or `~/…`, and must be a plain file inside the folder),
  `skills/` (a skill is its whole folder, scripts and references included), `agents/`, `commands/`, `output-styles/`,
  `keybindings.json`, `settings.json` and every file inside the folder that a command in it points to (a hook or the status
  line: paths that start with `~/`, `$HOME/`, `${HOME}/` or `/` are looked at, a relative one isn't guessed), and the plugin
  list (`plugins/installed_plugins.json`, assumed to be a JSON object of plugin entries, with or without a `plugins` key:
  only the count is read). Never: a sign-in (`.claude.json*`, `.credentials*`), `settings.local.json` (machine-local by Claude
  Code's own definition), plugin caches and repos (everything else under `plugins/`), `projects/`, `todos/`, `statsig/`,
  `shell-snapshots/`, `ide/`, a dot-file, version history and build leftovers (`.git`, `.hg`, `.svn`, `node_modules`, `.venv`,
  `venv`, `__pycache__`, `.DS_Store`, `*.pyc`: counted, not an error). **A link is never followed**: a skill that is one, or
  holds one anywhere (left out whole), a link in place of `CLAUDE.md`, an agent, a command, an included file, or `skills/`
  itself, is left out and listed with where it points ("3 links left out, never followed: skill foo points to
  ~/projects/x/skills/foo"): on this Mac's page only; the file and the manifest name them and never say where they point.
  What an `@` include or a hook script points to outside the folder is listed too ("hook script outside ~/.claude:
  ~/bin/foo.sh, not carried"). The setup's files go through the key scan like transcripts: the unit is `CLAUDE.md` alone,
  each included file alone, a skill's whole folder, an agent or a command or a style its file; **the Found line counts
  them with the sessions** ("5 sessions and 1 skill hold keys: 3 GitHub tokens"), and **Leave them out** leaves the unit out
  (listed) while **Keep them** keeps it and forces the encrypted image. There is **no address check and no rewriting** in
  setup files: they are your own words, like a transcript. **Sensitive setup** (`settings.json`, the scripts it points to
  and `plugins/known_marketplaces.json`, which can hold addresses with credentials) can hold tokens no scan recognises, so
  **only the encrypted disk image carries it**: a zip leaves it out and the page says so ("settings.json, the 3 scripts it runs
  and the plugin marketplaces need the encrypted disk image: left out of a zip"; the Password row's choice decides, no extra menu).
  A skill, agent, command or output style that holds a script a hook runs is sensitive too: left out of a zip with the same note,
  carried whole, as itself, in an image. This holds when `settings.json` is a link too (it is then read only to learn what its
  hooks and status line run, never carried, and where it points is never written); a backup records those units by name for
  a later export. When `settings.json` can't be read, a zip leaves out every skill, agent, command or output style that holds an
  executable file. An included file goes only with what includes it: when `CLAUDE.md` (or the skill that includes it) is left
  out for a key, the file it includes is left out too.
  Each file is recorded in the manifest with its size, its SHA-256 and whether its owner-execute bit was set.

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
  OAuth or `auth.json`; in the setup only the exact names `.claude.json*` and `.credentials*` are refused, so a skill's `auth.py`,
  `token-counter.md` or `credentials-guide.md` travel), the window's MCP settings in a zip, `settings.local.json`, a switch's receipt,
  `deleted_` markers, an address or a raw account id (outside the setup and the transcripts). Accounts appear as a **fingerprint**: `fp-` and 8 hex characters of an HMAC-SHA256 of the id under a key made
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
  or more that can't be checked, stops the export with a message naming the file; nothing is stripped silently. (The setup
  files, under `profiles/pN/setup/` and nowhere else, are your own words too and are copied as they are.) Any other id
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
- **The file:** `<name>/export.json` (format `cl_audit-export`, version 2, 3 or 4, when, cl_audit's version, a fingerprint of this Mac's
  name, zip or image, what was done with keys, the profiles and their sizes) and `<name>/profiles/p1/` (a backup's layout:
  `backup.json`, `window/<fp>/<fp>/…`, `sidebar/`, `config/` (image only), `records/`, `transcripts/…`, `setup/…`), one `pN`
  per profile for "All profiles", and, in an image only, `<name>/cl_audit.json` (cl_audit's own profiles and settings, below).
  The manifests carry no absolute path of this Mac. **Version 2** added the `setup/` part (each item with its `sha` and `exec`);
  **version 3** added `config/claude_desktop_config.json` and the scheduled tasks' prompts (`setup/scheduled-tasks/<id>/SKILL.md`);
  **version 4** added `cl_audit.json` and the move (parts whose window folders are the real account ids, `move` in the manifests).
  A file is written in the lowest version that holds it: 4 only for a move or with `cl_audit.json`, 3 only with a version-3 part,
  else 2, so 26.11.8 still imports a plain zip. Version-1, -2 and -3 files still import; 26.11.7 (which reads version 1 only),
  26.11.8 (up to 2) and 26.11.9 (up to 3) refuse a newer file with their "newer cl_audit" message.
- **cl_audit's profiles** (a row of its own, **left out** unless you include it; on in the Move preset): `cl_audit.json` holds each
  exported profile's record (name, label and look, how it behaves, its place in the order, whether it had a Dock icon, its
  accounts and which one is in use; never its folders) and cl_audit's General and backup
  settings (Face, Emails, Usage history, the dashboard's cards and charts, the app icon, where backups go and how many are
  kept; the Dock's own settings stay with each Mac; none of them holds a secret). It names your accounts and their
  addresses, so only the **encrypted disk image** carries it; a zip leaves it out and says so. Outside a move its ids and
  addresses are fingerprints like everywhere else in the file.
- **Move to another Mac** (a key at the top of the page, and the **Move** row): one click sets everything a new Mac needs:
  All profiles, the encrypted disk image (a password), Claude Code's setup, the window's MCP settings and scheduled tasks,
  and cl_audit's profiles and settings. Keys found stays as you chose it, and the page says which rows the preset changed from
  your choice. You can still change any row; only the zip is off while it is a move. Sign-ins don't travel: on the new Mac
  you sign in again to each account (Accounts ▸ Sign in with another account…). A move **keeps the real account and organisation ids and the addresses** (no
  fingerprints), because the Claude window files its Code-tab list and scheduled tasks by account folder: the new Mac puts
  them back where the window looks once you sign in. That is safe only in the encrypted image, so cl_audit refuses a move as
  a zip in the export itself, not only on the page, and an import refuses a zip that claims to be one. Every other export
  keeps its fingerprints and its leak check exactly as before.

### Moving to another Mac

*Experimental: see [Experimental](#experimental-switching-import-export-restore-and-the-default-profile).*

**Can I move everything to another Mac?** Yes, everything but the sign-ins. In short:

**On the old Mac**
1. Settings ▸ any profile ▸ Sessions ▸ **Export…**, then **Move to another Mac** at the top of the page. It sets All
   profiles, the encrypted disk image, Claude Code's setup, the window's MCP settings and scheduled tasks, and cl_audit's own
   profiles and settings.
   The page's **Code** row lists the projects your sessions ran in, read with read-only git (never a fetch, nothing written),
   and warns about work that is only on this Mac: "garden-app: 3 commits not pushed: push them before you move", files not
   committed, a branch that isn't on a remote yet, a folder that isn't a git repo, and anything git couldn't read. It never
   runs a program a repo's own settings name (a filter, for one): such a repo is listed as not read. Push and commit first: a
   clone on the new Mac won't have what is only here. The list (each project's clone source with any user name, password or
   token taken out of the address, or left out when it can't be cleaned, the branch, the latest commit and those counts) goes
   into the encrypted disk image only. Without git on this Mac it lists the folders only and says so.
   The **Side files** row lists what each moved session keeps beside its chat: its task list, its plan, the prompts you typed
   in it (the up-arrow history, with any pasted text) and its project folder's trust and allowed tools in Claude Code's
   `.claude.json`, with that folder's MCP servers. They go into the encrypted disk image only. **Rewind** is a row of its own
   with its size: Rewind's copies of the files the sessions edited can be hundreds of MB, so a move leaves them out unless you
   pick **Include them**. Keys found also searches the history, pasted text, plans and task lists: a line or file holding a key
   is left out, or kept in the image if you keep keys. Not carried: session environments (hooks write them again, and they hold
   tokens), the image cache, shell snapshots, debug files and old to-do lists. From `.claude.json` only those fields of the
   sessions' own folders are read; cl_audit never copies the file itself, and a backup cl_audit makes never holds any of this.
2. Type a password twice (not stored anywhere: lose it and the file can't be opened), then **Export** and choose where.
   Close the profiles' Claude windows first, or their Code-tab lists are left out (the page tells you per profile). Your
   Keys found choice stays as you set it. Sign-ins don't travel. On the new Mac you sign in again to each account
   (Accounts ▸ Sign in with another account…).
3. Copy the `.dmg` to the new Mac (a disk, AirDrop, a shared folder).

**On the new Mac**
1. Install cl_audit and go through its first run: it sets up your first profile (on `~/.claude`, with its sign-in).
2. Get your code: clone each project first, or after the import. The Import page's **Code** card shows, per project, where to
   clone it from, where it was, its branch, and what wasn't pushed or committed on the old Mac, with the commands as text to
   copy (`git clone -- …`, `cd …`, `git checkout …`). cl_audit never runs git on the new Mac. At the same path as on the old
   Mac, a session needs nothing more; elsewhere, clone it into the folder you pick for its sessions (or pick the folder you
   cloned it to).
3. Settings ▸ that profile ▸ Sessions ▸ **Import…**, choose the file, type its password. The page says it is a move. Its
   **cl_audit's profiles** card lists the profiles it makes (those not on this Mac yet), the ones already here (a profile counts
   as already here when it has one of the file's accounts, or, for a file with no accounts, the same name) and the settings that
   differ, with both values. **Make 2 profiles** makes them, each in folders of its own (`~/.claude-<name>` and its own
   window), whatever the file says, after the profiles that are here; your settings stay unless you pick **Take the file's** (a
   backups folder that isn't on this Mac is never taken, and keeping fewer backups than here is said). Nothing that is here
   changes. Do this before Close and import: until the profiles exist, a profile's sessions have nowhere of their own to go,
   and the key waits.
4. After that, pick **Into**: the page offers the part's own profile ("Into Studio"); it never picks it for you. **Folder not
   here** lists each session whose folder isn't on this Mac (not cloned yet, or cloned somewhere else). **Pick its folder on
   this Mac…** for each one you have: right after the import, the session is pointed there: its saved chat moves to the
   folder named for the new place in Claude Code's folder, the folder paths inside it and in its Code-tab entry are updated
   (nothing else changes), and a worktree that isn't on this Mac is dropped, so the session runs in the project folder. The
   profile's Claude window closes for a moment while its entries change. Undo this import takes that back too (a session you
   have resumed since stays where it is, and Undo says so). Leave the others: they are added anyway, and once you have cloned
   the code, Settings ▸ the profile ▸ Sessions ▸ **Folder not here** lists them with **Pick its folder…** (the window closes
   for a moment while the entry is written; **Undo** takes back the last change). Memory files start as **Add them** for a move, since they belong to its sessions.
   The side files are rows too (**Task lists**, **Plans**, **Prompt history**, **Trust**, **Rewind** when the file has it, each
   with its count and size), on for a move like the memory; **Project MCP servers** start left out, as the window's MCP settings
   do. Task lists, plans, pasted text and Rewind's copies are added where missing (one already there stays, and the page says
   so). The prompt history goes at the end of the profile's `history.jsonl`, each line pointed at the session's folder on this
   Mac, and a folder's trust becomes that folder's entry in `.claude.json`, only when it has none (an entry already there wins),
   with nothing else in the file changed. Both are written the way Claude Code writes them (its own lock, the file replaced
   whole for `.claude.json`), only while Claude Code isn't running for that profile and its window is closed, and only for a
   folder that is on this Mac: a session whose folder you pick later gets its history and trust then. Rewind's saved paths are
   pointed at a picked folder with the rest of the session. **Close and
   import** puts that profile's sessions in. Each Code-tab entry and scheduled task goes back into the folder of the account it
   was on, so the window shows it once that account is signed in. Then the same for each other profile: Settings ▸ that
   profile ▸ Sessions ▸ Import…, the same file: Into is that profile there, and Profile in the file shows its part.
5. **Sign in to each account** of each made profile: Settings ▸ the profile ▸ Claude Code ▸ Accounts ▸ Sign in with another account…. The page
   lists which as soon as the profiles are made. Nothing is signed in by an import: sign-ins never travel, and cl_audit never
   reads the Keychain.
6. **Put the profiles in the Dock**: the page's key, or Settings ▸ the profile ▸ Dock icon ▸ Usage in the Dock. A made profile
   has no Dock icon until you do (the import never builds its app or touches the Dock).
7. **Turn on the scheduled tasks** you want, in each profile's Claude window (open it from its Dock icon), under Scheduled tasks, once it is signed in: they come paused,
   so nothing runs twice. Setup and the MCP settings come only if you pick **Add them** on the import page (hooks and MCP
   servers run commands on their own, and nothing in a file can prove it was made for a move on your Mac).

**What moves:** the transcripts (sessions), the Code-tab list, the sidebar arrangement; Claude Code's setup (`CLAUDE.md` and
the files it includes, skills, agents, commands, output styles, keybindings, `settings.json` with its hooks and their
scripts, the plugin list so Claude Code can reinstall the plugins); the Claude window's MCP settings and scheduled tasks
with their prompts and the sessions they ran; and cl_audit's own profiles (names, looks, Dock places, accounts and which one
is in use) and General and backup settings; each session's task list, plan, prompt history and pasted text, its folder's trust
and allowed tools (and, if you add them, the folder's MCP servers), and Rewind's copies when you include them. **What never
moves:** sign-ins (Claude Code's and the window's), the Keychain, `settings.local.json`, `.claude.json` itself (only the trust
fields above), session environments, the image cache, shell snapshots, debug files, and claude.ai chats and Projects, which
already follow the account.

**Confirmed only from the programs' own text, not by running them:** how Claude Code 2.1.318 writes `history.jsonl` (appended
under a lock folder, read from the end per project, never sorted) and `.claude.json` (a lock folder, read again under it, a temp
file renamed over it), which `.claude.json` fields mean trust (`hasTrustDialogAccepted`, `allowedTools`), and how Rewind finds
its copies (by the names in the session's own lines, a file in the session's folder by a relative path, one outside it by its
full path, each with its folder's real path), how a plan is named (the name the session's own lines give it) and where a session's
task list is kept (`tasks/<session id>/` in its Claude Code folder). Undo this import takes back exactly what was written (a
history line or a trust entry changed since stays, and Undo says so). A prompt already in `history.jsonl` is never added twice, and
trust is never added for the top of the disk, `/Users` or your home folder.

**Where the side files are kept, and for how long.** The import keeps them with the imported backup, in a private folder beside
its files (`side/` in that backup's folder, readable by your user only; never in the backup's own list, so an export of that
backup never carries them): task lists, plans, prompt history, pasted text, Rewind's copies, and the trust entries with any MCP
servers. They stay as long as the import can be undone (30 days, or until the backup is deleted), so a Restore of that backup
brings them the same way the import did; after that they are deleted with the import's record, and a later Restore of that backup
brings the sessions without them. A session still waiting for its folder keeps only its own prompts and trust, in cl_audit's
record of the import (`sides/` in cl_audit's folder, readable by your user only), until it is picked or the import is undone.
The record keeps the trust entries it added (to take them back), never a copy of `.claude.json`. A Pick from the Sessions page
adds a waiting session's prompts and trust, and that Pick's **Undo** takes them back too.

Undo is two steps: **Undo this import** on the done page (or Undo last import under the profile's Sessions) takes back the
sessions, then **Take back the profiles it made** removes the made profiles (those unchanged since), their empty folders and the settings it
took. Export the profiles as they are now, not from a backup: backups keep neither the MCP settings nor settings.json's env
values (backups made by 26.11.8 still hold them).

### Importing an export

*Experimental: see [Experimental](#experimental-switching-import-export-restore-and-the-default-profile).*

**Import…** (Settings ▸ the profile ▸ Sessions) opens the **Import page**: **Choose…** (an Open panel for a `.zip` or
`.dmg`; an image asks for its password), then **Into** (the profile; a file of several profiles also asks which one). It
reads the file, and shows a preview ("Preview · nothing written yet · nothing is ever overwritten") that says how it was made
("made on another Mac"). **The file is unpacked as a backup of the target first, then restored from: the same rules as Restore**
(kind "Imported from cl_audit Work 2026-10-30", listed with the other backups, Restore… on it works).

- **cl_audit's profiles** (a file that carries them: an encrypted image, always for a move; the page's title says "Move from
  another Mac"): **Profiles** lists what the import would make ("2 to make: Work (2 accounts), Home (1 account) · here already:
  Main"), each with what was cleaned on the way, and **Settings** each setting that differs ("Face: Std here, Silver in the
  file"), **Keep this Mac's** by default, or **Take the file's**. A profile is **here already** when one of its accounts (the
  account and organisation ids) is a profile's here, in use or standing by; for a file that names no account (not a move),
  when a profile here has its name. One whose name a profile here has, with other accounts, isn't made; nothing that is here is
  ever changed. **Make 2 profiles** (a step of its own, before the sessions; Close and import waits for it, or for Leave them
  out, and says why) writes them into cl_audit's profiles file after the profiles that are here, with their accounts and the
  one in use, Usage in the Dock off, and their own folders: always `~/.claude-<id>` and its own window
  (`Claude-<id>`), never `~/.claude`, the usual Claude app or a folder the file names. A folder of that name already on this Mac
  is used only when no profile has it, it isn't a link and it holds no sign-in (else the next name), and the page says so; the
  rest are made empty. Nothing is signed in, the Dock isn't touched and no app is built, opened or quit. **Into** stays as you
  chose it: the page offers the part's own profile ("Into Studio"). For a file that isn't a move (its accounts are only
  fingerprints) the profiles start as Leave them out. A move's entries and task files go into their own account's folder (an entry from an account the
  target doesn't have goes into the one it works on, as for any import). As soon as the profiles are made, the page lists, per
  made profile, the accounts to sign in to, its Dock step, its paused tasks and where its sessions come from; **Take back the
  profiles it made** undoes them (after Undo this import, once its sessions are in).
  `cl_audit.json` is read through a 1 MB cap, 16 levels deep at most, field by field: a name with control or direction
  characters becomes one plain line, an account id that isn't one is dropped, a place out of range is clamped, any folder it
  names is ignored, a backups folder is judged where it really is (links resolved): one in a system folder, on this Mac's own
  disk outside the home folder, in ~/Library, ~/Public or a hidden folder, or missing here is never taken; a file that can't be
  read at all is refused whole.

- **What happens:** **New** (transcripts, their other files and Code-tab entries that aren't here: added), **Already here** (the
  same content, or longer here: skipped), **Grown on both sides** (there and different, or the file's is longer: the target's
  copy stays, listed), **Code-tab entries** (the window closes and opens again), **Scheduled tasks** (left out unless you pick
  **Add them, paused**: then the file's tasks go into the task file of the account the target works on, only when that
  account has none (one that is here stays, and the row lists the tasks it lacks), every task written with `enabled: false` and
  nothing else changed, each with its prompt where the window looks for it (`<Claude Code folder>/scheduled-tasks/<id>/SKILL.md`;
  the window works that path out from the task's id, whatever `filePath` the task records). A task is written only with its
  prompt: one whose prompt isn't in the file, whose id the window wouldn't keep, whose `filePath` points anywhere but its own
  prompt, or whose prompt here is a different one, is listed and not written. The list shows each task's schedule, the folder it
  runs in and a permission mode that isn't the default, and the row flags a task that runs with permission checks off or with
  permissions approved on the other Mac. The done page says which came paused and where to
  turn them on; cl_audit never changes a task after that), **Scheduled tasks' sessions** (a session a task ran, by the entry's
  `scheduledTaskId`, comes in with its task; when the task isn't added it is left out with its transcript, with the task's
  name), **MCP settings** (left out unless you pick **Add them**, which lists each server's name and the program it runs with how
  many arguments aren't shown, never an argument, an env value, a header or a URL; the whole `claude_desktop_config.json` is
  written only where the profile has none, and always without its sidebar part, which only the sidebar step arranges: one that
  is here stays byte for byte and the row lists the servers it lacks; a zip has none and the row says so. The Claude window may
  rewrite the file when it opens; Undo then leaves it as it is and says so), **Folder not here** (added, shown
  once that folder exists), **Would be deleted** (only the sessions Claude Code would delete again, as on the Restore page; **Keep for 90 days** when it would keep some). Entries go into the folder of the account the target
  works on now, never a fingerprint's, without the old account's error keys and Remote Control ids, and the sidebar's groups and pins follow them through the fingerprint (one Return in a helper session). **Close and
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
- **Claude Code setup** (CLAUDE.md, skills, agents, commands, output styles, keybindings, settings.json, the scripts it points to
  and the plugin list) in a file is **left out by default**, like memory files, and so it is on **Restore** from a backup (a skill
  that is missing now was most likely deleted on purpose; putting it back unasked would surprise). The row lists each unit as
  **New** (missing here), **Already here** (same content) or **Different here** (it stays as it is; for settings.json the
  names that differ, such as `hooks.PreToolUse` or `env.FOO`, never values), with **Leave them out / Add them** and the list;
  for settings.json it can show the command of each hook and the status line, so you see what will run. **Add them** adds only
  New units: nothing is replaced, nothing is written into a skill folder that exists, `CLAUDE.md`, settings.json,
  keybindings.json and the plugin files that are here stay as they are, an included file comes only when it is missing and
  with a `CLAUDE.md` that comes too, and nothing is written through a link (if `skills/`, `agents/`, `commands/` or any folder on
  the way is a link here, nothing is added there and the preview says where it points). Files are made new (cloned from the
  backup, exclusive, no overwrite), **0600** and folders **0700**. **Executable scripts:** a file the manifest marks executable
  gets **0700** (owner only; never setuid, setgid, sticky, group or other) when it is inside a skill that this run adds, and a
  script settings.json points to gets it only when that settings.json is added by the same run (else it stays 0600 and the row
  lists it "to make executable yourself"); the preview says "3 scripts made executable". It is judged safe because the import is
  opt-in, the files are created by this run, the bit is set on the descriptor of the file this run just made (never by name,
  never on an existing file), and a skill's script runs only when Claude or you start it. Agents, commands, `CLAUDE.md` and
  included files are never made executable. A hook or status-line path in an added settings.json that isn't on this Mac is
  listed after the import ("hook points to /opt/tools/x.sh: not here"). A **Hostile file** that marks a file outside a skill
  executable, names a path outside the allowed places or `settings.local.json`/`settings.json` under another name, or carries
  settings.json, its scripts or the marketplaces in a zip, is refused whole, as is a script that no hook or status-line command in
  the file's own settings.json names (a path mentioned in a value that isn't a command doesn't count, nor a command under another
  key, such as an MCP server's), an `.md` that the file's
  own CLAUDE.md doesn't include (its `@` lines, followed as the export followed them), a name that is CLAUDE.md, settings.json,
  keybindings.json, `skills/`, `plugins/` or `projects/` under another case, and a file whose SHA-256 isn't the manifest's.
  A script is made executable only when this run created the settings.json that names it; settings.json is written first. **Undo last import** takes the setup back like everything else
  (only files still exactly what was written). A backup made before this version says "not in this backup".
  The window's parts are refused whole the same way: a `claude_desktop_config.json` in a zip, under another name or place, over
  8 MB (never read into memory), not a JSON object, a link or a folder; a task's prompt whose task isn't in the file, any other
  file of a task's folder, or a prompt marked executable. A crafted task inside the task file (an id that climbs out of its
  folder, a `filePath` outside, something that isn't a task) is only data: it is listed and never written.
- **Scheduled tasks' sessions** come in with their task when it is added; otherwise they are left out whole: the entry, its
  transcript and the files in its folder, none counted as added. (An entry marks one with its `scheduledTaskId`, the key real Code-tab entries carry, taken exactly; the name shown is the
  `displayName` of the task in scheduled-tasks.json with that `id`, else the id.)
- **Group names** from the file reach the sidebar helper session's prompt, so for an import they are cut to letters, digits,
  spaces and `- _ . , ( ) & '`, at most 40 characters (a name with nothing left is dropped); the preview's Sidebar card lists
  the groups it will create.
- **Work folders** (`.import-…`, `.export-…`) are hidden in the backups place, each with a file naming the process that made
  it (its pid and start time). They are taken away when the page is left, the action ends or cl_audit quits (the tools it runs
  are stopped, an attached image detached); a later launch removes at once one whose process is gone, and one with no such
  file only after a day. A folder that still holds a mount is never removed or entered.

### Moving a profile to another account

*Experimental: see [Experimental](#experimental-switching-import-export-restore-and-the-default-profile).*

For example to a new plan, whose weekly limit starts at zero. Claude Code's side is a **switch**: once the account
is listed under Claude Code ▸ Accounts (found by itself, or **Sign in with another account…**), use **Switch to it…** (or
Switch account in the menus; it moves the window's sessions too), or sign Claude Code in yourself (step 5 below): either way the profile works on the account its folder is signed in to, by itself,
and the old one stays as a standby account. A profile keeps everything (name, look, Dock icon, Claude window,
settings). A switch moves the window's Code-tab sessions and scheduled tasks inside the profile's folder (a backup
first, with Undo); you sign the Claude app in to the new account yourself, in its own sign-in window. The steps below
are for doing it all by hand instead. Two sign-ins move then, Claude Code's and the Claude window's, and **Claude Code's is the one
cl_audit reads the usage from**: signing in only the Claude app leaves the numbers on the old account.

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
6. **Nothing to link:** within seconds the profile works on the new account and the old one stands by (refused if
   another profile works on that account: the card says whose).

Staying with the old account: a CI token from `claude setup-token` (make a new one), claude.ai connectors and MCP
servers, cloud sessions and environments, synced plugins, and the plan and billing. Its standby box remembers it,
signed out; to watch its limits at the same time, give it a profile of its own (**New profile**).

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

### Credits

How cl_audit finds a profile's accounts (`Sources/AccountList.swift`), reads the Claude app's account
(`Sources/AppSignIn.swift`) and moves the window's sessions on a switch (`Sources/SwitchEngine.swift`) is adapted from
[claude-transplant](https://github.com/vitaliyhayda/claude-transplant) 4.2.1, Copyright (c) 2026 Vitaliy Hayda, under the
MIT License: "Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to
whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this
permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS
IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE." The notice is in each of those files too.

---

cl_audit is an independent tool. It is not affiliated with, endorsed by or sponsored by Anthropic.
"Claude" is a trademark of Anthropic.
