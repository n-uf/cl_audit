# Changelog

All notable changes to cl_audit are listed here, newest first.

cl_audit uses calendar versions, `YY.M.R` (see README ▸ Versioning): the year and month of the
release date, then a counter within that month. The number can't signal a breaking change, so read
the notes before updating.

## Unreleased

This is 26.11.2.

- **A first-run page, instead of an automatic "main".** On a Mac with no profile, cl_audit no longer makes a profile
  called "main" on `~/.claude` by itself (the one with "not signed in yet" and every sign-in greyed). It opens
  **Set up cl_audit**: 1 Claude Code (found, with its version and place, or the install command with Copy and Check
  again), 2 the account (a signed-in Claude Code folder on this Mac, one click, or Sign in… through Claude Code's browser
  sign-in), 3 a name and colour prefilled from the account. The Dock menu and the empty dashboard and launcher offer
  "Set up cl_audit…". A Mac where 26.11.1 already made that "main" and it was never signed in gets the page too, and
  Done replaces it; a profile you have changed in any way, or signed in, is never touched.
- **Claude Code is found in more places, and looked for again.** Besides the usual folders and the login shell,
  cl_audit now checks `~/.local/bin` (the native installer) first, `~/.volta/bin`, nvm's node versions, npm's own
  prefix and, as a last resort, the copy the Claude app keeps for itself (shown as "from the Claude app"; a real
  install is preferred). It looks again when cl_audit comes to the front, on Check again, every few seconds while it is
  missing and before any sign-in, so installing Claude Code afterwards is noticed without a restart. Before, it
  looked once at launch.
- **A greyed sign-in now says why.** Wherever a sign-in needs Claude Code and it isn't installed, the key stays and a
  line beside it reads "Claude Code isn't installed on this Mac · Install…" (also in Add account and the Account
  pop-up); Install… opens the install help. The Dock menu's and the launcher's Log in and Terminal keys say it in a
  dialog instead of beeping.

## 26.11.1 — 2026-11-07

- **A fourth usage level: crimson from 95 %.** Green under 50 %, amber 50–79 %, red 80–94 %, and now a vivid crimson
  (#eb445b) from 95 % up, a full limit included, wherever a usage level shows: the menu bar icon and its menu, the
  dashboard cards and trays, the Switch page, the Dock icon's bars, rings and segments, and the widget. The level
  follows the number shown (94.5 reads 95, so it is crimson).
- **Backups of a profile's sessions.** Every switch that moves the sessions now makes a backup first, right after
  the window is known closed and before anything moves: the window's Code-tab list for both accounts with its
  scheduled tasks, its sidebar records (only the `epitaxyPrefs` part of its config, never the MCP settings), cl_audit's
  own records (ids only, never an address) and, on by default, Claude Code's transcripts. APFS clones, so it takes seconds and shares space with the
  originals (on another volume it is a full copy, and says so). Never a sign-in. The switch's receipt names the
  backup and the backup names the receipt; if it can't be made, nothing moves. The Switch page has a **Backup** card
  (before: when, what, a Transcripts switch, how long; after: "Made · Before switch to ultra-2 · 5 Nov 18:40 · 3 s")
  and step 1 reads "closed, backup made". Settings ▸ a profile has a **Sessions** card after Claude Code: what is
  kept here, **Keep for** (30 days, 90 days or a year: Claude Code's `cleanupPeriodDays`, other keys kept), the
  backups with Restore…, Show in Finder and Delete… and **Back up now**
  (with the window open it leaves out the Code-tab list and sidebar records). **General ▸ Backups** sets where they
  go and how many are kept (the last 3 and any under 30 days). The receipt records where the backup is; the
  window is checked closed again after the backup, and a switch whose backup can't be made stops at step 1.
- **Restore a backup, and Undo this switch puts back from it.** **Restore…** on a backup opens a Restore page: a
  preview first (nothing written, nothing ever overwritten) that counts, by session id across every account folder of
  the window's Code-tab list and by path for transcripts, what is back where it was, what is missing and would be
  restored, what was made after the backup, what changed since (the copy in the backup is only listed), what a running
  Claude Code session holds (left alone, listed), what the window deleted since (stays deleted) and which restored
  transcripts Claude Code's own clean-up would delete again (**Keep for 90 days**). Missing entries go into the folder
  of the account the profile works on now, never one it no longer uses; files are only ever created, never over a name
  that exists and never through a link, and a backup holding anything that isn't a plain file with one link, or
  anything named like a sign-in, refuses the whole restore. **Close and restore N** closes only that profile's window,
  writes with a receipt kept as it goes (**Stop, keep what's back**; a restore that stopped shows on the profile's tile
  and is finished from the same receipt), then arranges the sidebar with one Return as after a switch. **Undo this
  restore** takes back exactly what it put back (it closes the profile's window itself, on that click, and stops
  keeping what it took back if the window opens). A crash between a file and its line in the receipt is still known:
  each line before a write carries the hash the file must have, so Undo and finishing treat such a file as the
  restore's, and a restore stopped after its last file can still be finished. Backups a receipt names in another
  place are listed in the Sessions card too ("in ~/Old/backups"); receipts of finished restores go with their backup
  or after 30 days (a place on a disk that isn't plugged in says nothing about its backups); the backup an Undo this
  switch is about to restore from isn't pruned before that. Undo leaves a restored transcript a running session holds,
  and lists it; finishing a stopped restore sweeps its temp files also while the window is open and keeps a window
  file it can't check safely as "not done", so Undo still takes it back; each restore page has its own mark on the
  window, and a switch finishing never takes a restore's. A shorter copy of a backup file is shown as "Shorter copy", also on the Restored page. An Undo that leaves a transcript a running session holds stays open ("Undo again once it has ended"); one that can't tell which sessions run takes nothing back. One switch,
  restore or import at a time, none while a switch of the
  profile stopped half way ("Not yet · one thing first", with **Open the switch**) or while claude-transplant moves
  sessions. **Undo this switch…** is now the switch back plus a restore from the backup the switch made: the Switch
  page says so before it starts, and its last step opens the Restore page on that backup.
- **Export and Import of a profile's sessions.** Settings ▸ a profile ▸ Sessions has **Export…** and **Import…**. Export
  makes one file for another Mac or for keeping, in the backup format: a zip made with macOS's own `ditto`, or an
  AES-256 encrypted disk image (`hdiutil`, the password typed into a secure field, handed over on stdin, never stored or
  logged). It is made from the profile as it is now, one of its backups or all profiles, with accounts as a fingerprint of
  their id (`fp-` and 8 hex characters of the SHA-256) and never an address, an account id, a sign-in, an MCP setting,
  `settings.json` or a path of this Mac. The transcripts are searched for keys (GitHub tokens, AWS access keys, private
  keys, Anthropic, OpenAI, Slack, Google, Stripe and npm keys; counted by kind, never shown): a session that holds one is left
  out, or kept in an encrypted image if you say so. A transcript a running session holds is copied up to its last full
  line. The page previews per project folder and asks where in the Save panel. **Import** unpacks a file as a backup of the
  chosen profile (marked imported) and restores from it by exactly the rules of Restore: create-only, the window closed while
  entries are written, a receipt as it goes, **Undo last import** (under Sessions) takes back exactly what it added. Entries
  go into the folder of the account the profile works on now; sessions that scheduled tasks ran are left out, with the task's
  name; transcripts of a folder that isn't on this Mac are added and show once it is. The file is treated as hostile and the
  whole import is refused, with nothing written, on a link or device in it, a path outside its folder, an absolute or `..`
  name, two names that are one on this Mac, a sign-in name, a file its manifests don't name or a size that differs, a newer
  format, an unencrypted image, a wrong password, or more data than it declared (checked before and while unpacking). A zip
  must be exactly its central directory (the tool that unpacks it goes by the local headers, so each must agree and the records
  must tile the file), numbers no file can have are refused instead of trapped on, files with flags (immutable), ACLs, extended
  attributes or setuid bits are refused and what comes off an image is copied as data only, a zip bomb is stopped within a
  fifth of a second of writing by watching the volume's free space, and work folders are taken away when cl_audit quits and
  by a later launch if it was killed. Fingerprints are keyed by a random per-export key (a guessed address can't be checked
  against them), "this Mac" is a random install id, any address or unexplained id in a made export stops it, group names from a
  file are cleaned before they reach the sidebar helper's prompt, memory files from another Mac or profile are left out unless
  added, scheduled tasks' sessions are left out with their transcripts, and sessions and entries are counted apart ("25
  sessions · 12 entries"), never together as sessions. The key scan also finds a key right after an escaped newline in a
  transcript, and Supabase, GitLab, Hugging Face, Slack refresh and JWT tokens. Import unpacks a zip with cl_audit's own
  checked reader, not ditto (which writes a record hidden after a deflate stream's end): only the entries the directory
  names, each inflated to exactly its stated size, ending exactly at its last byte, with a matching CRC-32, written data-only;
  the bomb guard is exact. Memory files from any import file are left out unless you add them, and where a file says it came
  from earns no trust (and "Add them" doesn't carry over to the next file you choose). A file's time is read from the
  Unix extra that Finder's zips carry (UTC), so it is right in any time zone, and held to 1980 ... now; a name over 512
  bytes is refused, so an unpacked folder can always be taken away (by descriptors, whatever its depth); a 2,000-session
  file unpacks in under a second.
- **Switch page fits its columns.** The Move to / Leave with keys sit side by side when they fit and one under the
  other when they don't, instead of overhanging the card; the keys in the top bar wrap under the status display when
  the page is narrow; the account being switched to is printed in light text on its dark glass on the Silver face too.
- **A little use shows on segment meters.** Segments (the cards, panels, widget and the Dock icon's Segmented style)
  light the nearest number, but anything above 0 % lights the first one: 3 % no longer looks like nothing.
- **A profile can have more than one account.** Settings ▸ a profile ▸ Claude Code ▸ **Accounts** lists them, one
  box each with every limit its plan has as bars: the one in use (**IN USE**) and the others (**STANDBY**), whose
  limits come from a sign-in kept for each in a small Claude Code folder of its own and renewed by itself. **Add
  account** finds the accounts on this Mac (signed in in free Claude Code folders, or used by the profile's Claude
  window, with their addresses) and adds one with a click; **Sign in to another account…** makes a folder for a new
  one and opens Claude Code's own sign-in in Terminal. An account belongs to one profile; New profile still starts
  with one. Profiles saved before have their one account, in use; nothing changes for them.
- **Switching, clearer.** Display colours mean one thing each: green the account in use, mint switching and the
  account switched to, amber waiting or a warning, red a failure; only the account in use is lit. In Settings ▸
  Accounts the standby accounts are unlit, most room first; a click selects one (a mint row, a lit bar) and its
  **Switch account** key opens the Switch page. The Switch page lists every standby account under TO, most room
  first, and asks **Move them?** about the sessions every time, with nothing chosen (Sessions follow is gone). While
  it runs every block stays: each step shows its state, each sign-in what its check saw, and the line at the top how
  far it got, with **Cancel switch** always in sight and **Undo this switch…** once the profile is on the new
  account. A failure marks its step red and says where it stopped. A display beside the profile's tile reads
  "Switching ● to ultra-2", "Switched to ultra-2" or "Stopped half way · Undo it".
- **The card, the menus and the alerts follow the same pattern.** On a profile's dashboard card only the account in
  use is lit; the other accounts sit in **unlit trays** under its limits, most room first, their levels dimmed (an
  account with no numbers stays off the card). **While a limit is full, the tray with the most room is selected
  already**: its row lights mint across the card and its STANDBY display becomes the lit **Switch account** key,
  which opens the Switch page with it picked; click another tray to pick that one instead. With room left nothing is
  selected: a click selects a tray, a second click deselects it. The separate green "Switch to …" key under the
  full-limit box is gone. The **menu bar icon's and the Dock icon's menus** show the account in use with a lit green
  lamp ("ultra-1 · in use"; the Dock menu's first line is "Claude Main · ultra-1 in use") and have **Switch
  account ›**: the account in use ticked, then every other account, most room first, each with its week ("week
  12%", or "no numbers"); while a limit is full the best one also sits on the top level ("Switch to ultra-3…  week
  12%"). The old per-account "Switch to …" items are gone. The alerts' keys are **Switch account…** and **Switch
  back…**, and a new alert, **"Claude Main: the switch is waiting for you"** ("Step 3 of 5: finish the sign-in in the
  browser…"), says so once per step when a switch waits for your sign-in or your Return and its Switch page isn't in
  front, with **Show switch** and (at Claude Code's sign-in) **Cancel switch**; each switch waiting has its own, a
  step that ends in a moment never alerts, and none outlives cl_audit. No alert names an account.
- **Add account, redone.** **Add account** opens macOS's own menu with two lines a row: the address, then in grey
  what is known ("Ultra · Personal · signed in, ~/.claude-ultra-3 · limits once added", "Pro · Personal · needs a
  sign-in · used in Main's window in August"); another profile's account is greyed ("Work's · one profile per
  account"). Found accounts show no usage; one click adds one. **Sign in to another account…** names the folder it will
  use under the address field. A new account is a **standby box from the start**: **Signing in** (mint, with **Cancel**
  and **Show Terminal**), **Wrong account** (amber, with **Cancel** and **Sign in again…**: it says which account the
  sign-in came back as), **Not finished** (amber: 15 minutes under way with nothing new in the folder) and, once
  added, **Standby** with "No numbers yet…" until its limits show. A found account that needed a sign-in goes through
  the same states once you sign it in, without **Cancel** (only an account with no seat yet has it). A new sign-in
  isn't mistaken for the wrong account while Claude Code is still writing the folder. How a sign-in works is
  unchanged.
- **Another account with room, offered where a limit is full.** A profile's dashboard card shows its other
  accounts' limits, small, under its own. The full-limit alert says how much the other account has
  left ("The other account has 92% of its week left", never an address) and has a **Switch account…** button; the
  Dock icon's and menu bar icon's menus have **Switch account ›**. They open the new **Switch
  page**: both accounts' limits, what stays, what follows (the Claude window's sessions, sidebar and scheduled
  tasks, counted), and the steps. While cl_audit is at the front, its alerts now still show as banners.
- **Switching to another account.** The Switch page's **Close and switch** closes only that profile's Claude
  window, moves its Code sessions and scheduled tasks to the other account the way claude-transplant does (same
  ids, writes that never overwrite, originals parked in cl_audit's folder, a receipt; Cancel puts them back until
  Claude Code has signed in; a switch that stopped half way, even after a crash, shows on the Switch page with
  Undo), opens Claude Code's sign-in with the address filled in, then makes that account the
  one in use (the old one joins standby) and reopens the window for its own sign-in. No sign-in is ever copied.
  Each account keeps its own numbers through the switch; numbers read for one account never show under another's
  name, anywhere (Dock icon, card, menus, Settings).
  Once the window is on the new account, a session opens there ("cl_audit · arrange sidebar") that puts the moved
  sessions back in their groups and pins with the app's own sidebar tools: press Return in it. It archives itself
  when done, and running it again changes nothing. The link goes to that window's own process, so it never opens in
  another Claude window (macOS asks once to let cl_audit control Claude).
- **The other account is back.** When a standby account's full limit resets, one alert ("Claude Main: the other
  account is back · Its week starts again") offers **Switch back…** or **Stay**, and the dashboard card and the Dock
  and menu bar menus offer **Switch back to …** until then. Switching back is the same switch the other way; the
  sessions started on the second account go back too.
- **Every account's limits stay live.** The account in use signs in once to a folder of its own too (Settings ▸
  Accounts, or the Switch page's "Keep ultra-1's limits showing after the switch" before it leaves that account, with
  Skip), and its numbers come from there, so after a switch both accounts' limits keep showing.

## 26.11.0 — 2026-11-05

- **Profile windows come back after a Claude update.** Claude's quiet updates quit every window and reopen only the
  standard one. The cl_audit agent now reopens the profile windows the update closed (not ones you closed), in the
  background, as soon as the new version is installed, and says so in one alert.
- **Fable's weekly limit.** Max and Ultra plans and premium Team and Enterprise seats have a weekly limit of Fable's
  own; cl_audit now reads it from
  Anthropic's reply and shows it as a third row on the cards, the panels and the Dock menu. Full, the row turns red
  with when it's back, and it alerts like the other two ("Fable weekly limit full · Back Thu 09:00", "Fable is
  back"). It never takes the full-limit box: the other models still work. Each profile can leave it out (Profile ▸
  Fable's limit): off, it's neither shown nor alerted.
- **Usage credits.** While a profile is spending usage credits, its card, panels and Dock menu say "Using usage
  credits · $4.20 spent". Alerts when a profile starts spending them and when they run out.
- Three limits side by side in the Rings and Numbers designs are drawn a size smaller, so they fit the panels.
- **Menu bar icons, one per profile.** Like its Dock icon, each profile can have its own icon in the menu bar
  (profile settings ▸ Menu bar, off by default), drawn by the agent, so it works with or without Dock icons, with
  its own menu (limits, Open Claude window, Refresh now, Dashboard, Profile settings). Its look: six styles (two
  bars, bars + number, ring, ring + number, number, two numbers); colours in levels, **System** (drawn the way
  macOS draws its own icons), **Accent** (your Mac's accent colour) or the profile's; its label; the countdown or
  just red when a limit is full. The preview draws it the way your menu bar is now. ⌘-drag to arrange them.
- **Drag profiles into your order.** In Settings, drag a profile's tile left or right along the top, or drag its card
  on the dashboard; it's saved when you let go. The dashboard, the launcher (⌘1, ⌘2…), the menu bar icons, the widget, the usage history and its CSV,
  and cl_audit's Dock menu follow it. The Dock icons stay where you put them in the Dock.
- **Settings, grouped by subject.** General: cl_audit (Usage in the background, Privacy, About), How usage looks
  (Face, Dashboard cards, Widget), the Dock (App icon, Dock), each column with its subject printed at the top.
  "Opening and closing" and "Dock icon clicks" became one **Dock icon** card and a **Claude window** card;
  "Updates and alerts" is **Alerts**; "Emails" is **Privacy**. Pop-ups and text fields fill their row, so their
  right edges line up.
- **The agent has its own name.** It shows as **cl_audit Agent** in Activity Monitor, so it isn't mistaken for the
  cl_audit window. macOS restarts it if it's force-quit; to stop it, turn cl_audit off in System Settings ▸ General ▸
  Login Items & Extensions (Settings ▸ General ▸ Usage in the background ⓘ says so too).
- **A profile's settings in one pattern.** Each part is one card with its switch first: the **Dock icon** (when it
  runs, a click, the usage panel and the icon's look, which was a card of its own, with a preview strip), the
  **Claude window** (its switch, With Dock icon, Opens from) and the **Menu bar** (style and colours as tiles,
  label and when full as segments, a preview strip); a part that's off folds its card to the switch row, whose
  words say what's left. The two big keys at the foot of the Profile card are gone, and so are the column titles.
  Every row has its label in the same width with an (i), every on/off is the small switch with a few words, and at
  most one grey line under a row says what the current choice means. Small things (icon styles, menu bar styles
  and colours) are tiles; the usage panel keeps keys with one large preview, like General ▸ Card style.
- **One switch, and it shows a change under way.** Every on/off in cl_audit is the same lamp switch (Show emails,
  Notify at and Keep in order were plain ones). While a change is under way its lamp pulses, green turning on, red
  turning off, and its words say "turning on…" / "turning off…"; clicks wait until it's done. Instant settings
  pulse once, briefly. Usage in the Dock pulses until the Dock really has its icon or hasn't (no longer a fixed 10 s,
  and the key isn't dimmed meanwhile), In the menu bar until the agent has put the icon up or taken it down, Keep in
  order until the Dock matches. A change that can't be done blinks red twice and goes back, with one grey line saying
  why. With Reduce motion the lamp stays lit instead of pulsing.
- **Opens from** (profile ▸ Claude window): **Dock click too**, as before, or **Only when asked**: a click on the
  Dock icon never opens the Claude window, and neither does starting the Dock icon (a click on its stopped tile
  shows the usage instead); Open window on the dashboard, the Dock and menu bar menus and the details panel still
  do. The Click choices with Claude in them are off then, and the stored one comes back with Dock click too.
- Dashboard: the Open window key's light stays dark while the Claude window is closed and lights once it's open
  ("Show window"), like the switches above it; it no longer looks as if the window were running.
- **Widget** (macOS 14 and later): "Claude usage" in the widget gallery, with every profile's 5-hour and weekly
  limits and when a full one is back, in three sizes. Its look is in Settings ▸ General ▸ Widget, with the real
  widget as the preview: limits as Glow, Rings, Numbers, Segments or Pace (rows too); the System look or cl_audit's
  Std, Black and Silver faces. It fits itself to the size and the number of profiles, centred, with reset times and
  the next resets where there's room. It reads only what cl_audit saves.
- Widget, large size: one profile's limits are bigger and fill the height; three and four profiles are drawn a size
  larger, with the next resets below when they fit, so the blocks no longer sit apart with empty space between them.
  In rows, "100%" stays on one line.
- **Export the usage history as CSV.** The CSV key next to the period saves one row per day, profile and model
  (optionally per project, by folder name), with replies and each kind of token.
- **Cost estimate at API list prices** in the usage history's totals ("≈ $123 at list prices") and in the CSV:
  what the same tokens would cost on the API, per model, cache writes and reads priced apart. Not your bill;
  models without a published price are left out.
- **Another account signed in, noticed by itself.** When Claude Code is signed in to another account in a profile's
  folder (`claude auth login`), the agent sees its `.claude.json` change within half a minute and reads the new
  sign-in then: the old account's numbers go, and there's no red "Wrong account" waiting for Refresh now. One Keychain read, as
  at the start; the limit alerts start over for the new account, so the switch itself sends no "is back".
- **Changing a profile's account.** Profile ▸ Claude Code ▸ **Account** (it was Login) is now one row with a
  pop-up, the card's first: the account Claude Code there is signed in to (ticked), the profile's own account to log back in to when
  that isn't it, the accounts in unused Claude Code folders, other profiles' (dimmed), **Sign in to another account…** and **Renew
  sign-in by itself** (it was a row of its own). Sign in to another account… turns the row into the address and
  **Sign in** in place, opens Claude Code's own sign-in in Terminal with the address filled in, and links the
  profile to the new account by itself once it's done; name, look, Dock icon, Claude window and settings stay.
  Signed in elsewhere, **Use this account** shows under the pop-up, and the profile shows no numbers until you
  choose (they'd be the other account's). Refused, naming the profile, when another profile has that account. A
  **Claude window** row says when the window is on another account (the usual Claude app is checked too). After
  linking: when, what it was, what stays with the old account, and New profile to give it a profile again.
- **A profile's Claude Code card, like New profile's.** **Account** first, then **Folder**, then, for any folder
  but `~/.claude`, **Share from** and **Shared**: what the folder links to from another one, shown as it is today
  (cl_audit never moves or deletes real files; a grey line says to change the links in Finder). Its labels sit
  above their values, so accounts and paths get the card's full width.
- **New profile starts with the account.** Its Claude Code card leads with an **Account** pop-up, like a profile's
  Claude Code ▸ Account: accounts signed in in unused Claude Code folders (picking one connects its folder), other profiles'
  dimmed, and **Sign in to another account…**, which makes a new folder and opens Claude Code's sign-in with the
  address filled in. The result is checked by account and organisation ids (the browser decides the account);
  signed in to another address than the one typed, it says so. The folder is its own row, following the
  account and showing who is signed in in each. The Claude window step checks the usual Claude app too, and says
  its Code sidebar starts empty. The page is laid out like a profile's settings (one card per part, its switch
  first), its columns reflow to two and one in a narrower window, and it can sign in again with another address.
- **Claude's own plan name.** The plan badge, the panels and the menus show the plan as Claude names it ("Ultra"),
  read from the profile's `.claude.json` with the account it already reads; an Ultra account's sign-in says "max".
  Without that name, the sign-in's as before (Max, Pro, Team).
- **Plans without a 5-hour limit** (Ultra): Anthropic's reply has no 5-hour window for them, so the cards, panels,
  Dock and menu bar menus, the menu bar icon and the widget show the week alone instead of an empty 5-hour row.
- README: **Moving a profile to another account**, step by step: both sign-ins (Claude Code's is the one the usage
  comes from), linking, and, for the usual Claude app only, moving its Code sessions with claude-transplant.
- **cl_audit no longer grows to gigabytes of memory.** Reading the usage history kept every line it had read from
  Claude Code's session files until the read was over, and on a busy Mac the dashboard started a new read every
  minute beside the ones still running: cl_audit reached 1.7 GB in half an hour. Each line is now let go as soon as
  it's read, one read runs at a time, a session file is read only from where the last look stopped, and only while
  the dashboard's history can be seen. The history, totals and CSV are the same.
- **Usage history can be turned off** (Settings ▸ General ▸ Privacy ▸ Usage history, on by default). Off, cl_audit
  opens none of Claude Code's session files: the dashboard shows the limits only (no history charts, cost estimate or
  CSV) and the launcher's Dashboard row says "Limits". The limits come from Anthropic either way.

## 26.10.11 — 2026-10-27

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
