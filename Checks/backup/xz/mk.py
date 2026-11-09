import os, struct, sys, zlib, random

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

def defl(data):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(data) + c.flush()

def build(path, entries):
    """entries: list of dict(name, data(raw stored bytes as written), method, usize, crc, extra_c, dosdate, dostime, attrs)"""
    body = b""; cd = b""
    for e in entries:
        nb = e["name"].encode()
        off = len(body)
        raw = e["raw"]
        lx = e.get("extra_l", b"")
        body += struct.pack("<IHHHHHIIIHH", 0x04034b50, 20, 0, e["method"], e.get("time", 0), e.get("date", 0x5821),
                            e["crc"], len(raw), e["usize"], len(nb), len(lx)) + nb + lx + raw
        cx = e.get("extra_c", b"")
        cd += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014b50, (3 << 8) | 20, 20, 0, e["method"], e.get("time", 0), e.get("date", 0x5821),
                          e["crc"], len(raw), e["usize"], len(nb), len(cx), 0, 0, 0, e.get("attrs", 0o100600 << 16), off) + nb + cx
    eocd = struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, len(entries), len(entries), len(cd), len(body), 0)
    open(os.path.join(out, path), "wb").write(body + cd + eocd)

def ent(name, data, method=8, raw=None, usize=None, crc=None, **kw):
    if raw is None: raw = defl(data) if method == 8 else data
    d = dict(name=name, method=method, raw=raw, usize=len(data) if usize is None else usize,
             crc=(zlib.crc32(data) & 0xffffffff) if crc is None else crc)
    d.update(kw); return d

rnd = random.Random(7)
small = b"hello world\n" * 10
mid = bytes(rnd.getrandbits(8) for _ in range(3000))          # compresses to ~3000 (< 4 KB)
big = bytes(rnd.getrandbits(8) for _ in range(200000))        # > 4 KB + 64 KB compressed

build("ok.zip", [ent("r/a.txt", small), ent("r/b.bin", mid), ent("r/c.bin", big), ent("r/d/", b"", method=0, attrs=0o40700 << 16)])
# trailing bytes inside csize, after the stream's end
for nm, data in [("small", small), ("mid", mid), ("big", big)]:
    for k in (1, 7, 5000, 100000):
        build(f"trail_{nm}_{k}.zip", [ent("r/x", data, raw=defl(data) + b"PK\x03\x04" + b"A" * (k - 4) if k >= 4 else defl(data) + b"Z" * k)])
# zero-length deflate stream
build("defl_empty.zip", [ent("r/e", b"", raw=b"\x03\x00")])
build("defl_csize0.zip", [ent("r/e", b"", raw=b"")])
build("stored_empty.zip", [ent("r/e", b"", method=0)])
# usize one more / one less
build("usize_plus1.zip", [ent("r/x", big, usize=len(big) + 1)])
build("usize_minus1.zip", [ent("r/x", big, usize=len(big) - 1)])
build("usize_minus1_small.zip", [ent("r/x", small, usize=len(small) - 1)])
build("crc_bad.zip", [ent("r/x", big, crc=1)])
build("trunc.zip", [ent("r/x", big, raw=defl(big)[:-3])])
build("trunc_small.zip", [ent("r/x", small, raw=defl(small)[:-1])])
# a non-final stored block only (stream never ends)
nf = b"\x00" + struct.pack("<HH", 5, 0xFFFA) + b"abcde"
build("nonfinal.zip", [ent("r/x", b"abcde", raw=nf)])
# a stream of only empty non-final stored blocks: decoder consumes, outputs nothing, never ends
nf2 = (b"\x00\x00\x00\xff\xff") * 2000
build("nonfinal_empty.zip", [ent("r/x", b"", raw=nf2)])
# mtimes
ut = lambda t: struct.pack("<HHB", 0x5455, 5, 1) + struct.pack("<I", t)
build("mtime_future.zip", [ent("r/x", small, extra_c=ut(0xFFFFFFFF))])
build("mtime_dos_future.zip", [ent("r/x", small, date=(127 << 9) | (12 << 5) | 31, time=(23 << 11) | (59 << 5) | 29)])
build("mtime_dos_zero.zip", [ent("r/x", small, date=0, time=0)])
# long paths: 16 parts of 255 bytes
long = "r/" + "/".join(["L" * 255] * 14) + "/f"
build("longpath.zip", [ent(long, small)])
# file then a path under it
build("file_then_dir.zip", [ent("r/a", small), ent("r/A/b", small)])
# folders that APFS folds together but lowercased() keeps apart (final sigma)
build("sigma.zip", [ent("r/σ/x", small), ent("r/ς/y", small)])
# NFD vs NFC file names
build("nfd.zip", [ent("r/café", small), ent("r/café", small)])
