# Receipts written by 26.11.29 (commit 20489f5)

What cl_audit 20489f5 wrote, for the accounts suite's section 15: each receipt is read through its ReceiptStore and saved
again, and must come out byte for byte the same.

## From 20489f5's own check runs

Written by the engines while `Checks/run.sh` ran at 20489f5, in the suites' throwaway homes
(`Checks/.work/<suite>/home/Library/Application Support/usage-n-uf/...`):

| Fixture | Suite that wrote it |
| --- | --- |
| `switches/20261114-164317-3190-ff/receipt.json` | `Checks/run.sh surfaces` |
| `restores/20261114-170329-3175-studio/receipt.json` and `journal.jsonl` | `Checks/run.sh resume` (its second home, `resume/b/home`) |
| `repoints/20261114-170330-3a0b-studio/receipt.json` | `Checks/run.sh resume` (`resume/b/home`) |
| `moves/20261114-165545-d800/move.json` | `Checks/run.sh move` (`move/b/home`) |

## From 20489f5's save functions

A small program compiled against 20489f5's `Sources/`, `Core/` and `Widget/` (from `git archive 20489f5`, built the way
`Checks/run.sh` builds a suite) and run in a throwaway HOME. It called the old `SwitchEngine.save`, `SideFiles.save` and
`DefaultProfile.save` on sample values:

- `switches/20270115-080000-ab12-main/receipt.json`: a switch with an entry, a tasks and a pointer step, partly undone
- `sides/20270115-080500-ef56-main-side/receipt.json`: side files with every step kind and a session waiting with trust
- `default-moves/00000000-0000-4000-8000-00000000001e.json`: a default-profile move record

## What was changed afterwards

Only strings, so the files pass `Checks/tools/leakscan.py`:

- the throwaway home paths became `/sample` (and `/sample/work` for the suites' code folders);
- the sample ids `00000000-0000-4000-8000-000000000NNN` with NNN 100 and above became ids ending in two hex digits
  (`...0a`, `...0b`, ...), one for each, and the default-move record's file name with its id.

The keys, their order, the escaping (`\/`), the dates and the layout are as 20489f5 wrote them. The journal's lines keep
the key order 20489f5 wrote, which JSONEncoder picks at random each run; a journal is only appended to, never saved again.
