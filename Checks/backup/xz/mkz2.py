import os, sys
sys.argv = [sys.argv[0], sys.argv[1]]
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "mk.py")).read().split("rnd = random.Random(7)")[0])
for mb, label in [(256 << 10, "256k"), (50 << 20, "50m"), ((256 << 10) + 1, "256k1"), (1 << 20, "1m")]:
    z = b"\0" * mb
    for k in (1, 2, 3, 30):
        build(f"z{label}_s{k}.zip", [ent("r/z", z, raw=defl(z) + b"PK\x03\x04" * 8)][:1] if False else [ent("r/z", z, raw=defl(z) + (b"\0" * k))])
        build(f"z{label}_sZ{k}.zip", [ent("r/z", z, raw=defl(z) + (b"Z" * k))])
