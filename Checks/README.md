# Checks

The check suites of cl_audit: programs that compile the app's own sources (without its `main.swift`) together with a suite's
`main.swift`, run in a throwaway home and print `ok:` or `FAIL:` per check. They are not part of the app and not built by
`build.sh`.

```
Checks/run.sh [signin|backup|firstrun|retention|render|quick-chat|scan|all] [--volume] [--no-build]
```

The suites are heavy (a compile of all the sources, then minutes of runs): run them through a heavy-work queue if your
machine has one.

| Suite | What it covers | Checks |
|---|---|---|
| `firstrun` | the first-run page, the Claude lookup (the order of places, the shell, the app's copy), the sign-in step (always in ~/.claude) | 172 |
| `retention` | which transcripts Claude Code's clean-up deletes: the window's sessions by the transcript's own `entrypoint` (first and last 64 KB), release markers (delete, archive and its grace), the hard cap `desktopSessionCleanupPeriodDays`, the organisation's managed settings source by source and in order, the counts and words of Would be deleted (Restore, Import, the default-profile move), Keep for 90 days only when it helps | 190 |
| `render` | pictures of the pages (Sessions card, General › Backups, the Switch page, Restore, Export, Import, first run), Std and Silver, into `Checks/.work/render/` | – |
| `quick-chat` | the quick chat's engine and Markdown (its own `quick-chat/run.sh`, run here under the build lock) | 95 |
| `scan` | the app's own `SecretScan` over every file in `Checks/` (no secret-shaped string is committed), then `tools/leakscan.py`: no real address, id, personal path, and none of the words in your local `Checks/.work/leakwords` (one per line, never committed; without it that check is skipped and says so) | 0 hits |
| `signin`, `backup` | the model and page logic, and the Sessions backup, restore, export and import on real files: **not in this tree yet**, see below | – |

`run.sh` knows `signin` and `backup`; while their `main.swift` is missing it says so and skips them. `--volume` makes `backup`
mount a small HFS+ disk image in `Checks/.work/backup/` and run the cross-volume checks on it.

## Not recovered

The suites `signin` (about 567 checks) and `backup` (about 605) were hand-built in a scratch folder that a restart wiped. They
are rebuilt from the session transcripts with `tools/replay` (see its README), from recorded `Write` and `Edit` payloads,
whole-file `Read`s and `cat >` heredoc bodies only, and nothing recorded is executed. Some of their history was made by
python scripts that cut and splice a file by offsets computed from its text, which the rebuild does not take on trust, so
these files are left out:

| File | The op that could not be honoured | Why |
|---|---|---|
| `signin/main.swift` | a python script that replaced lines 1143 to 1195 of the stage C copy by list index (`L[start:end] = new`), then the copies and merges built from it | an offset into a file whose state is only known through the rebuild itself |
| `backup/main.swift` | python scripts that replaced a span of the file between two found markers (`s[s.index(a):s.index(b)]`, five of them: the copy-of-a-link check, two restore blocks and two review blocks), and the file's later copies | computed offsets |
| `backup/mkzips.py` | a python script that cut a function out of the file by offsets | computed offsets |
| `backup/stage-e-parent.swift` (part of `backup/main.swift`) | a python script that replaced the deep-tree helper between two markers | computed offsets |

An earlier rebuild did run those scripts and gave a `signin` suite that passes 567 of 567 and a `backup` suite that passes
604 of 605 against 26.11.3, but it executed recorded commands and is not used. The hand-built suites can be added back once
their gaps are closed (a whole-file `Read` of the file, or the original files).

What is rebuilt (and was checked against the earlier rebuild, hunk by hunk: identical): the page renders
(`render/pages/main.swift`, from the stage B1 render and its stage E block), the zlib probe zip generators (`backup/xz`),
and `render/trim.py`. The first-run suite and its render come from a saved copy of the files.

## Safety

- Each suite runs with `HOME` and `CFFIXED_USER_HOME` set to `Checks/.work/<suite>/home` (the render suites:
  `Checks/.work/render/<name>/home`), which `run.sh` empties first. Both `run.sh` and the suite's `main.swift` refuse to run
  with a home anywhere else. The suites write sample accounts (`ultra-1@example.com`, "Claude Main", "Work") and sample sessions
  there, and read nothing from the real `~/.claude*`, the Claude app's folders or the app's own data.
- Nothing opens the app, Terminal or the Dock, or quits a window. Outside `Checks/.work/` only two things are touched: the
  quick-chat suite builds into the repo's `build/checks/quick-chat` (ignored by git), and the preference files below.
- `cfprefsd` writes the checks' preference files to the real `~/Library/Preferences` whatever `CFFIXED_USER_HOME` says.
  `run.sh` removes exactly these, and only when no run of ours is alive: `cl-audit-{signin,hide,switch,plan}-test-<pid>.plist`
  when that pid is dead; `<binary>.plist` for the binaries it builds (`cl_audit-checks-signin`, `-backup`, `-firstrun`,
  `-retention`, `-render-pages`, `-render-firstrun`, `-scan`), names no other program has; and `cl_audit-backwatch-test.plist` and
  `cl_audit-reader-switch-test.plist` (named by the suites, no pid) only when they were not there before the run. No generic
  name is ever removed.
- Every compile goes through `/usr/bin/lockf -k /private/tmp/cl_audit-build.lock`, the lock `build.sh` users share.
- Fake keys and tokens (the suites check that exports leave them out, and that SecretScan finds them) are built at run time:
  in the sources each is cut by an empty string interpolation, so no committed file holds a whole key and GitHub's secret
  scanning stays quiet. `Checks/run.sh scan` proves it with the app's own patterns.

## Files

```
run.sh                  the entry point
firstrun/main.swift     the first-run suite
retention/main.swift    the retention suite (its managed-settings sources are folders inside its throwaway home)
render/pages/main.swift the page renders; render/firstrun/main.swift the first-run render; render/trim.py crops them
backup/xz.py, xz/*.py   make the ~100 zlib probe zips of the backup suite's "zlib" checks (nothing binary is committed)
backup/vol.sh           the HFS+ disk image for --volume
quick-chat/             the quick chat's checks (own run.sh)
tools/secretscan/       prints the files in which the app's SecretScan finds a key shape
tools/leakscan.py       refuses real addresses, ids, personal paths, your own word list, and key shapes (a Python port of SecretScan)
tools/replay/           rebuilds files from Claude Code session transcripts without running anything recorded
.work/                  homes, binaries, volumes and pictures (ignored by git)
```

## Adding a stage

One block per stage, opened by a `// --- stage X ---` line, just before the final print of a suite's `main.swift`. A
backup child role (the same binary started in another throwaway home, `BK_ROLE=<name>`) adds its home to `allowedHomes` at the
top of `backup/main.swift` and its `if BK_ROLE == "<name>"` block under "child roles"; `run.sh` empties the homes of the
roles it knows (`other`, `other-tz` under `Checks/.work/backup/`).

## When a check fails

Fix the app when the check is right; fix the check when the app's behaviour changed on purpose (the menu bar checks, for
instance, list the menu's items and were extended when Quick chat joined it). A suite's last line says `N of M checks passed`
(`checks: N passed, M failed` for `firstrun` and `retention`).
