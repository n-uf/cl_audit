#!/usr/bin/env python3
"""Makes the zlib probe zips the backup suite's "zlib" checks read, into OUTDIR (nothing binary is committed).

  python3 -I -B xz.py OUTDIR

Five small generators in xz/ write hand-built zips (slack bytes after a deflate stream, exact sizes around the buffer
edges, truncated and non-final streams, hidden records, zeros of 256 KB to 50 MB). Their files are gathered under the
prefixes the suite sorts them by: z_ (mk4), z3_ (mkz2), z4_ (mkz3), z5_ (mkz4) and e3_ (mk, the nine it uses).
"""
import os, shutil, subprocess, sys, tempfile

out = os.path.abspath(sys.argv[1])
here = os.path.dirname(os.path.abspath(__file__))
shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)
E3 = ["trunc", "trunc_small", "nonfinal", "nonfinal_empty", "defl_empty", "stored_empty", "crc_bad", "usize_plus1", "usize_minus1"]
with tempfile.TemporaryDirectory(dir=os.path.dirname(out)) as tmp:
    for script, prefix, only in [("mk4.py", "z_", None), ("mkz2.py", "z3_", None), ("mkz3.py", "z4_", None), ("mkz4.py", "z5_", None), ("mk.py", "e3_", E3)]:
        d = os.path.join(tmp, script)
        r = subprocess.run([sys.executable, "-I", "-B", os.path.join(here, "xz", script), d], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"{script} failed: {r.stderr[-400:]}")
        for f in sorted(os.listdir(d)):
            name, ext = os.path.splitext(f)
            if ext == ".zip" and (only is None or name in only):
                shutil.move(os.path.join(d, f), os.path.join(out, prefix + f))
print(len(os.listdir(out)), "zips in", out)
