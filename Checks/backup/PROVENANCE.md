# Where the backup suite comes from

The suite was hand-built in a scratch folder that a restart wiped on Nov 8. `main.swift` and `mkzips.py` here are the
assembled suite as it was last run green (607 of 607, Nov 10): the stage A–D file, the stage E parent and child pieces
(`stage-e-parent.swift`, `stage-e-child.swift`, one binary with child roles) and the later blocks, joined by the stage's own
`assemble.sh`. `vol.sh`, `xz.py` and `xz/` were rebuilt and checked earlier (`tools/replay`).

## How every line is shown to come from the transcripts

Every line was compared, as text only, with the literal text recorded in the session transcripts (`Write` payloads, `Edit`
strings, whole-file `Read`s, shell commands and their heredoc bodies). Nothing recorded was run for this. All but 133 of the
2561 lines of `main.swift` and all but 7 of the 443 of `mkzips.py` are recorded lines as they stand. The rest (line numbers
are those of the first commit of this file):

| Lines | How they come about | The ops |
|---|---|---|
| 83 of `main.swift` (e.g. 225–231, 557, 1567–1570, 1617–1645, 2036–2043, 2087–2144, 2225–2250) and 5 of `mkzips.py` | text inside a recorded python heredoc's string literals, read as python reads it (`'\\('` is `\(`); line 700 is `'…cleanup' + chr(92) + 'u0050eriodDays…'` | the splices of the five offset scripts and the later python insertions (sessions of Nov 6–7) |
| 41 of `main.swift` (e.g. 90, 134, 370–371, 897, 1013, 1225, 1670, 1857, 1863, 1918, 2003, 2016–2017, 2445–2446) and 2 of `mkzips.py` | a recorded line with one to three recorded literal replacements undone: an `Edit` that starts or ends mid-line, a python `s.replace('lit', 'lit')` or `rep()`, also with names bound to literals (`old = '…'; s = s.replace(old, '…')`) | the stage E fix rounds (Nov 7) and the Edits on the held-back copy (Nov 9–10: format version 2, `backup.json`, the escaped key name, the one-folder model) |
| 5 (1754, 1755, 1798, 1830, 1831) | a recorded line with an empty interpolation `\("")` after a fake key's first characters | the recovery's `build_tree.py` (`split_secrets`, Nov 9), so no committed file holds a whole key |
| 3 (904, 1259, 1885) | the home and volume guards moved to `/Checks/.work/backup/…`, and `"/" + "Users"` | the same `build_tree.py` and its header script |
| 1 (1148) | a comment in which the earlier rebuild's path rewriting had dropped `/usr/bin/` | restored to its recorded text |

The recovery session that assembled the held-back copy is not lost: it is a subagent of the Nov 6–10 session, and its
`build_tree.py`, header script, absolute-path restore and copy into the held-back folder are all recorded. Text alone can't
prove that a splice landed at the offset its script computed; that is shown by the suite compiling and running green here.

Nothing was left out for want of an explanation: every one of the 133 lines is plain check code with sample data.

## Changes for the repo

- Two fake keys the recovery's split missed (an OpenSSH private-key header and a JWT) are cut by an empty interpolation too.
- Two made-up ids (`aaaaaaaa-1111-…`, `bbbbbbbb-1111-…`) are zero-pattern ids now (`00000000-0000-4000-8000-0000000000a1`,
  `…a2`). `abcdef01-0000-4000-8000-000000000051` stays: the check needs hex letters to change case.

## Ported to 26.11.60

Every flow writes through SafeFiles since then (no behaviour, wording or layout change), so only the calls moved:
`SwitchEngine.load` and `SessionsRestore.save` are their receipt stores' (`store.load`, `store.save`), `SessionsRestore.header` is
`store.load` (the header alone), `SessionsRestore.blocker` is `Flows.blocker(…, for: .restoring)`, the lock and its words are
`Flows.takeLock` and `Flows.busy`, the restore's `createNew` is `CreateOnly.write` (with the restore's temp name), and
`SessionsImport.startTime` is `Processes.startTime`. `import ProfileCore` is added, and run.sh builds the suite with
`-D CL_AUDIT_TESTING` (the import's claim seam, `claimFails`) as the held-back run did.

One change on purpose reached a fixture: since 26.11.18 a switch's Undo touches only the profile's own places
(`SwitchEngine.undoPlaces`, read from the profiles file), so for a profile that isn't saved it skipped every step as "outside
this switch's folders" and left the switch open. The switch block now saves its profile first (as `accounts` does) and removes
the file after. No expectation changed and no check was removed.

## Added since

- Import's own seam (before, only through Restore's apply loop): a transcript and an entry that appear between the plan and the
  write are left as they are and said, the rest comes in, and Undo leaves them.
- The zlib property check refuses a damaged stream only as a deflate-stream problem (any refusal passed before). The old loop
  isn't in the app any more to be shown failing; the cases it refused stay pinned by name.
- Work folders: a folder whose chmod fails (immutable and unreadable), two removers racing, a cancel in the middle of a 50 MB
  entry, and a write that fails with EFBIG (a file size limit) rather than ENOSPC.
- Already in the assembled suite, so nothing to add: the stage E leak-check refusals flipped to "passes" (leak1, leak2 and the four `leakx` jobs, Nov 9), and
  the `claimFails` seam (open and export stop and clean up when the work folder's `.owner` can't be written).
