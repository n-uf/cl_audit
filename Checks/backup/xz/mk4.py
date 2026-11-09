import os, struct, sys, zlib, random
sys.argv = [sys.argv[0], sys.argv[1]]
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "mk.py")).read().split("rnd = random.Random(7)")[0])
rnd = random.Random(9)
def stored(blocks):
    """blocks: list of bytes; last one final"""
    s = b""
    for i, b in enumerate(blocks):
        s += bytes([1 if i == len(blocks) - 1 else 0]) + struct.pack("<HH", len(b), len(b) ^ 0xFFFF) + b
    return s
def rb(n): return bytes(rnd.getrandbits(8) for _ in range(n))
small = b"hello world\n" * 10
big = rb(200000)
# slack k = 0..6 on zlib streams
for nm, data in [("small", small), ("big", big)]:
    for k in range(0, 7):
        build(f"slack_{nm}_{k}.zip", [ent("r/x", data, raw=defl(data) + b"Z" * k)])
# exact csizes via stored blocks; chunk boundaries where a 1-byte non-final call happens
for cs in [10, 11, 65536, 65537, 65538, 65539, 2*65536+1, 2*65536+2, 2*65536+3]:
    a = (cs - 10) // 2; b = cs - 10 - a
    A = rb(a); B = rb(b)
    raw = stored([A, B]); assert len(raw) == cs
    build(f"exact_{cs}.zip", [ent("r/x", A + B, raw=raw)])
    if b > 0: build(f"exactslack_{cs}.zip", [ent("r/x", A + B, raw=stored([A, B[:-1]]) + b"Z", usize=len(A)+len(B)-1, crc=zlib.crc32(A+B[:-1]) & 0xffffffff)])
# csize 1 and 2
build("c1_03.zip", [ent("r/e", b"", raw=b"\x03")])
build("c1_00.zip", [ent("r/e", b"", raw=b"\x00")])
build("c2_empty.zip", [ent("r/e", b"", raw=b"\x03\x00")])
build("c3_empty_slack1.zip", [ent("r/e", b"", raw=b"\x03\x00Z")])
# tiny fixed-huffman streams with one literal
lit = defl(b"a"); print("defl(a) len", len(lit))
build("c_lit.zip", [ent("r/e", b"a", raw=lit)])
build("c_lit_slack1.zip", [ent("r/e", b"a", raw=lit + b"\x00")])
# mtime 0x5855 (ditto) and precedence
ux = lambda at, mt: struct.pack("<HH", 0x5855, 8) + struct.pack("<II", at, mt)
ut = lambda t: struct.pack("<HHB", 0x5455, 5, 1) + struct.pack("<I", t)
build("m5855.zip", [ent("r/x", small, extra_c=ux(1, 1_600_000_000))])
build("m5855_short.zip", [ent("r/x", small, extra_c=struct.pack("<HH", 0x5855, 4) + struct.pack("<I", 1_600_000_000))])
build("m5855_then5455.zip", [ent("r/x", small, extra_c=ux(1, 1_600_000_000) + ut(1_700_000_000))])
build("m5455_then5855.zip", [ent("r/x", small, extra_c=ut(1_700_000_000) + ux(1, 1_600_000_000))])
build("m5455_noflag.zip", [ent("r/x", small, extra_c=struct.pack("<HHB", 0x5455, 5, 0) + struct.pack("<I", 1_700_000_000) + ux(1, 1_600_000_000))])
build("m_future.zip", [ent("r/x", small, extra_c=ux(1, 0xFFFFFFF0))])
build("m_past.zip", [ent("r/x", small, extra_c=ut(5))])
# folder entry with data
build("dir_data.zip", [ent("r/d/", b"x", method=0, attrs=0o40700 << 16)])
