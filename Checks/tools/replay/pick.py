#!/usr/bin/env python3
"""Pick the version of recovered files as they stood at a moment, from the history replay.py keeps.

  python3 -I pick.py OUTDIR SESSION8 CUTOFF DEST NAME...

OUTDIR is the folder replay.py wrote (its versions/ holds every version), SESSION8 the first 8 characters of the session whose
scratch folder held the files, CUTOFF a timestamp like 2026-11-07T064000, NAME a path inside that scratch folder
(signin-test/main.swift). For each NAME the latest version at or before CUTOFF is copied to DEST/NAME. A file that is in
OUTDIR/gaps.json is refused: its history includes something that was not applied.
"""
import glob, json, os, sys

outdir, sid, cut, dest, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
gaps = json.load(open(os.path.join(outdir, 'gaps.json'))) if os.path.exists(os.path.join(outdir, 'gaps.json')) else {}
for n in names:
    if f'{sid}/{n}' in gaps:
        print('GAP ', n, '|', gaps[f'{sid}/{n}']); continue
    base = n.replace('/', '__')
    cands = [(f.split('@')[1], f) for f in glob.glob(os.path.join(outdir, 'versions', f'{sid}__{base}@*')) if f.split('@')[1] <= cut]
    if not cands:
        print('NONE', n); continue
    ts, f = max(cands)
    t = open(f, errors='surrogateescape').read()
    out = os.path.join(dest, n)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, 'w', errors='surrogateescape').write(t)
    print(n, ts, len(t.splitlines()), 'lines')
