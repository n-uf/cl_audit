# Where the signin suite comes from

The suite was hand-built in a scratch folder that a restart wiped on Nov 8. `main.swift` here is its last state: the copy
the one-folder release (B) kept beside the app and last ran green (355 of 355, Nov 11, on its fix worktree), with the blocks
that model removed fenced off in `#if RETIRED_ONEFOLDER`.

## Which copy is the final one

Two copies were left in the held-back folder:

- `held-back/signin` (2,713 lines, Nov 11). The Nov 9 recovery (a subagent of the Nov 6–10 session) assembled the suite with
  its `build_tree.py` and copied it there; it passed 567 of 567 against 26.11.3. On Nov 10 the one-folder builder kept a copy
  of it and edited this one in place: the blocks for kept folders, Use this account, the switch that moved sessions between
  accounts, "the other account is back" and Add account's sign-in were fenced off, and rebuilt blocks were added after
  them. On Nov 11 a subagent added release A's `AccountView` calls to it (B was built on top of A), and the builder's last
  two Edits fixed a fixture; the next run passed 355 of 355.
- `held-back/signin-a` (2,208 lines). On Nov 11 the hub copied the one-folder builder's "before" copy there and adapted it
  to release A alone (`AccountView`, a kept folder made where a reader is expected). It is a sibling, not a later stage:
  of its 159 lines that the final copy lacks, every one is in a block B fenced off or rebuilt (the standby folders, the
  kept-folder switch, stage B2's multi-folder world, stage D's sign-in states), or is A's `AccountView` change that B made in
  its own words.

So nothing has to be combined: `held-back/signin` is the final suite, and it is what the first commit of this file holds.

## How every line is shown to come from the transcripts

Every line was compared, as text only, with the literal text recorded in the session transcripts (`Write` payloads, `Edit`
strings, whole-file `Read`s, shell commands and their heredoc bodies) of the three sessions that built it, their subagents
included. Nothing recorded was run for this. The replay's gaps for this file (a `git merge-file` and a
`sed '1343d;1581d;1816d'` on Nov 7, a python split of `c/signin-test` on Nov 6) only join or delete lines, so they bring no
text of their own. All but 54 of the 2,713 lines are recorded lines as they stand. The rest (line numbers are those of the
first commit of this file):

| Lines | How they come about | The ops |
|---|---|---|
| 14 (13; 50, 64, 91, 128, 162, 203, 205, 208, 209, 230, 236; 967, 971) | the recovery's recorded substitutions: the home guard moved to `/Checks/.work/signin/home`, two sample addresses and a profile name made neutral (`first@…`, `second@…`, `NP First`), and a sample folder in a home folder made one on a volume (`/Volumes/x/My Folder+1`) | `build_tree.py`'s `sub` and `common` pairs (Nov 9) |
| 1 (201) | the recovery's own `Edit` moving a sample address with a space in it to example.com | Nov 9 |
| 1 (2561) | a recorded line with an empty interpolation `\("")` after a fake token's first two characters | `build_tree.py`'s `split_secrets` (Nov 9), so no committed file holds a whole key |
| 7 (1939, 2070, 2076–2078, 2128, 2133) | text inside a recorded python heredoc, read as python reads it (`\\(` is `\(`, `\\.kind` is `\.kind`) | stage D and stage B2's review (Nov 6) |
| 4 (1188–1191) | a recorded line renamed by its recorded `sed` script (`ra`, `rb`, `rcx` to `rmA`, `rmB`, `rmC`, also inside `[ra, rb, rcx]`) | Nov 6 |
| 4 (377, 2137–2139) | a recorded python insertion, then a recorded `sed` on it (`added` to `addedLook`; `"Personal · "` put before the window account's words) and a python `s.replace` after | stage D (Nov 6) |
| 23 (740, 759, 1321, 1323, 1336, 1519, 1521, 1541, 1620, 1622, 1629, 1633, 1889, 1941, 2123, 2140, 2162, 2163, 2193, 2208, 2628, 2649, 2686) | a recorded line with one or two recorded literal replacements undone: an `Edit` that starts or ends mid-line, or a python `s.replace('lit', 'lit')` | stage C and D's fix rounds and stage E (Nov 6–7), Quick chat in the menus (the recovery's Edits, Nov 9), the one-folder Edits (Nov 10) and release A's `AccountView` (Nov 11) |

Text alone can't prove that a splice landed where its script put it; that is shown by the suite compiling and running green
here. Nothing was left out for want of an explanation: every one of the 54 lines is plain check code with sample data.

## Changes for the repo

- Two sample account ids the recovery's substitution left beside the neutral addresses are `acct1` and `acct2` now, with the
  variables named after them (11 lines).

## Ported to 26.11.62

Only the calls moved; no expectation changed:
- `import ProfileCore` (Seat and StandbyAccount live there) and `import ClaudeAuth` (the watch's `RecordStamp`).
- SignInWatch takes ClaudeAuth's `RecordStamp` (date, size, file) instead of a dictionary of attributes: the same sizes, as
  `RecordStamp(size:)`.
- The one lock is `Flows.takeLock()` (was `SwitchEngine.Lock.take()`), a switch's receipt is read through its store
  (`SwitchEngine.store.load`), and a process's program is `Processes.executable(of:)` (was `SwitchMarker.executable`), as in
  `backup`.
- `FolderRules.seatOwner` answers the owner with whether it is a standby account: the profile's id is `.profile.id`.
- `AccountFacts` reads a folder's record (`AccountFacts.of(configDir:)`, through `Account.record`) instead of a dictionary:
  the same oauthAccount block is written to a throwaway folder's `.claude.json` and read from there.
- The switch's bounded checks run through `Processes` since 26.11.35: `SwitchEngine.probe` is a three-line helper in the suite
  that reads `Processes.run`'s status the way `Processes.fileOpen` does (none in time: unknown; 0: found; else none).

Changes on purpose reached four fixtures; their expectations stay:
- New profile's window check: since 26.11.39 the window's `lastKnownAccountUuid` counts only when it is a real id (a UUID),
  so the window and the folder carry UUID-shaped ids (`…00b1`, `…00b2`) instead of three-letter ones.
- The window's sidebar counts: every lister reads entries through ClaudeFiles, which takes only `local_<UUID>.json`, so the
  sample entries have UUID names instead of `local_1.json`.
- The switch's tasks: since 26.11.37 a task the target already has under the same id must be the same task, whole
  (TaskRegistry's twin rule, claude-transplant's), so the source's `t2` is the target's `t2` (`"x":1` on both sides); the
  plan still counts two tasks and the join still keeps the target's own.
- Numbers on another account (§4): since 26.11.24 whose numbers they are is the reading's own account, never the folder's
  `.claude.json`, so the new account's numbers are read with a key whose account the lookup returns (`finish(…, key:)`,
  `profileFound`) instead of `apply`, which names no account. The check's message now also prints what it got.

And one change on purpose reached the words: the menus' account in use is shown plain since 26.11.32 ("No "in use" text
outside the card": `ultra-1`, `Claude Main · ultra-1`; in Switch account › it is ticked and enabled, choosing it does
nothing, and standby accounts are listed by address only), and Switch account › opens with the Experimental warning and a
line since 26.11.21. Those checks expect today's words and still check every item, its state and its page.
