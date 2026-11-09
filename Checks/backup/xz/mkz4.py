import os, sys
sys.argv = [sys.argv[0], sys.argv[1]]
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "mk.py")).read().split("rnd = random.Random(7)")[0])
t = b"".join(b'{"type":"user","message":"hello %d"}\n' % i for i in range(30000))
build("txt_0.zip", [ent("r/t.jsonl", t)])
for mb, l in [(256 << 10, "256k"), ((256 << 10) + 1, "256k1"), (1 << 20, "1m"), (50 << 20, "50m"), ((256 << 10) - 1, "256km1")]:
    build(f"z{l}_0.zip", [ent("r/z", b"\0" * mb)])
