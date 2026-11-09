# Recovering files from session transcripts

Claude Code writes every tool call of a session into a JSONL transcript. When a scratch folder is lost, the files that were
written there can be rebuilt from the calls: a `Write` is a whole file, an `Edit` is a replacement, a whole-file `Read` is a
snapshot, and a `Bash` command may have copied, merged or written files in between.

This is how some of the suites in `Checks/` were brought back after a restart wiped the folder they were built in.

1. `extract.py PROJECT_DIR OPS SESSION...` collects those tool calls from the sessions and their subagents into one
   time-ordered `OPS` file.
2. `replay.py OPS OUTDIR [--until TS]` rebuilds the files in memory. **Nothing recorded is executed.** `Write`, `Edit` and
   whole-file `Read` are applied the way the tool applied them. From a shell command only recorded data is taken, each piece
   applied by the program itself: `cat > f <<'EOF'` bodies, `cp`, `mv`, `rm`, `sed -n 'A,Bp'`, `sed -e 'Nd'`, literal
   `sed -i '' 's/a/b/'`, `{ sed -n ..; cat f; } > out` groups, `git merge-file -p` (the one program started, on temporary
   copies of recovered texts with an empty environment) and python heredocs whose syntax tree shows only literal text
   operations on a file (`s = open(p).read()`, `s = s.replace('lit', 'lit')`, `s += 'lit'`, `assert 'lit' in s`, the
   `rep(old, new)` helper, `open(p, 'w').write(s)`). A python script is read, never run.
   Anything else that could change a text file (a computed offset such as `s[s.index(a):s.index(b)]`, a list of lines edited
   by index, regular expressions, loops, another interpreter, awk, `sed -i` with a pattern, a pipeline into a file) is not
   applied: the files it names become **gaps**, and so does everything copied or merged from a gap. A gap ends only at a
   later `Write` or whole-file `Read` of that file. Gaps are listed in `OUTDIR/gaps.json`. With `--allow-slices` the reader
   also follows `s.index('lit')`, `s.find('lit')` and slices of the text (offsets computed from the text itself, still only text
   operations): fewer gaps, but the rebuilt files are only as trustworthy as the offsets, so verify them by running them.
3. `pick.py OUTDIR SESSION8 CUTOFF DEST NAME...` takes the files as they were at a moment, and refuses a file that is a gap.

Edits whose text isn't there and `Read`s that differ from the replayed file are logged (`OUTDIR/replay.log`): they mark a
problem in the rebuild. Each `.swift`, `.sh` or `.py` file's every version is kept in `OUTDIR/versions`.

The result is only as good as its verification: a rebuilt suite is compiled and run against the app, and its count compared
with the count the transcript shows.
