import os, sys, random
sys.argv = [sys.argv[0], sys.argv[1]]
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "mk.py")).read().split("rnd = random.Random(7)")[0])
z = b"\0" * (1 << 20)
hidden = b"PK\x03\x04" + b"H" * 26 + b"r/evil" + b"E" * 994
for k in (1030, 5000, 70000, 200000):
    build(f"hid_{k}.zip", [ent("r/z", z, raw=defl(z) + (hidden + b"Q" * max(0, k - len(hidden)))[:k])])
# text-like data (realistic transcript) with slack
t = b"".join(b'{"type":"user","message":"hello %d"}\n' % i for i in range(30000))
for k in (1, 30, 1000):
    build(f"txt_{k}.zip", [ent("r/t.jsonl", t, raw=defl(t) + b"Z" * k)])
r = random.Random(3); rb = bytes(r.getrandbits(8) for _ in range(300000))
build("rnd_30.zip", [ent("r/r", rb, raw=defl(rb) + b"Z" * 30)])
