#!/usr/bin/env python3
# Makes hostile variants of a good export zip (stage E checks): usage mkzips.py <good.zip> <outdir>
import os, struct, sys, zipfile, json

base, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)
zin = zipfile.ZipFile(base)
infos = zin.infolist()
root = infos[0].filename.split('/')[0]


def copy_all(z, skip=lambda n: False, replace=None):
    replace = replace or {}
    for i in infos:
        if skip(i.filename):
            continue
        data = zin.read(i.filename) if not i.filename.endswith('/') else b''
        if i.filename in replace:
            data = replace[i.filename]
        zi = zipfile.ZipInfo(i.filename, i.date_time)
        zi.external_attr = i.external_attr
        zi.compress_type = i.compress_type
        z.writestr(zi, data)


def make(name, fn):
    with zipfile.ZipFile(os.path.join(outdir, name), 'w', zipfile.ZIP_DEFLATED) as z:
        fn(z)


def add(z, name, data=b'x', attr=None):
    zi = zipfile.ZipInfo(name)
    zi.compress_type = zipfile.ZIP_DEFLATED
    zi.external_attr = attr if attr is not None else (0o100644 << 16)
    z.writestr(zi, data)


export = json.loads(zin.read(root + '/export.json'))
a_transcript = next(i.filename for i in infos if '/transcripts/' in i.filename and i.filename.endswith('.jsonl'))
a_window = next(i.filename for i in infos if '/window/' in i.filename and not i.filename.endswith('/'))

def v(z): copy_all(z); add(z, root + '/../cl_audit-e-slip-evil.txt')
make('slip.zip', v)
def v(z): copy_all(z); add(z, '/tmp/cl_audit-e-abs-evil.txt')
make('absolute.zip', v)
def v(z): copy_all(z); add(z, root + '/profiles/p1/lnk', b'/etc', attr=(0o120777 << 16))
make('symlink.zip', v)
def v(z): copy_all(z); add(z, root + '/profiles/p1\\evil')
make('backslash.zip', v)
def v(z): copy_all(z); add(z, root + '/profiles/p1/transcripts/extra.txt')
make('extra-file.zip', v)
def v(z): copy_all(z, skip=lambda n: n == a_transcript)
make('missing-file.zip', v)
def v(z): copy_all(z, replace={a_transcript: b'{"different":"size"}\n'})
make('size-mismatch.zip', v)
def v(z): copy_all(z); add(z, os.path.dirname(a_window) + '/.claude.json', b'{}')
make('signin-name.zip', v)
def v(z): copy_all(z); add(z, root + '/profiles/p1/transcripts/-app/credentials.json', b'{}')
make('signin-name2.zip', v)
def v(z):
    e = dict(export); e['version'] = 7  # 5 is read since move stage 1 (the code checklist), 6 since stage 2 (side files)
    copy_all(z, replace={root + '/export.json': json.dumps(e).encode()})
make('newer-format.zip', v)
def v(z):
    e = dict(export); e['format'] = 'something-else'
    copy_all(z, replace={root + '/export.json': json.dumps(e).encode()})
make('wrong-format.zip', v)
def v(z): copy_all(z); add(z, 'other/x.txt')
make('two-roots.zip', v)
def v(z): copy_all(z); add(z, os.path.dirname(a_transcript) + '/' + os.path.basename(a_transcript).upper())
make('case-duplicate.zip', v)
def v(z): copy_all(z, skip=lambda n: n == root + '/export.json')
make('no-export-json.zip', v)
def v(z): copy_all(z, replace={root + '/export.json': b'not json at all'})
make('bad-export-json.zip', v)
def v(z): copy_all(z); add(z, root + '/profiles/p1/.DS_Store')
make('ds-store.zip', v)
def v(z): copy_all(z); add(z, root + '/profiles/p1/transcripts/-app/dev', b'x', attr=(0o020644 << 16))
make('device.zip', v)
def v(z): copy_all(z); add(z, root + '/profiles/p1/transcripts/-app/f.jsonl', b'x', attr=(0o104755 << 16))   # setuid bit on an unlisted file
make('setuid-extra.zip', v)

# a bomb: far more than export.json states
def v(z):
    copy_all(z)
    add(z, root + '/profiles/p1/transcripts/-app/bomb.jsonl', b'\0' * (400 << 20))
make('bomb.zip', v)

# a lying directory: the central directory says the bomb is 100 bytes, the data is 400 MB
make('bomb-lie.zip', lambda z: (copy_all(z), add(z, root + '/profiles/p1/transcripts/-app/bomb.jsonl', b'\0' * (400 << 20))))
p = os.path.join(outdir, 'bomb-lie.zip')
raw = bytearray(open(p, 'rb').read())
name = (root + '/profiles/p1/transcripts/-app/bomb.jsonl').encode()
pos = 0
while True:
    pos = raw.find(b'PK\x01\x02', pos)
    if pos < 0:
        break
    nl = struct.unpack_from('<H', raw, pos + 28)[0]
    if bytes(raw[pos + 46:pos + 46 + nl]) == name:
        struct.pack_into('<I', raw, pos + 24, 100)          # usize in the central directory
    pos += 4
open(p, 'wb').write(raw)

open(os.path.join(outdir, 'not-a-zip.zip'), 'wb').write(os.urandom(5000))
open(os.path.join(outdir, 'empty.zip'), 'wb').write(b'')
good = open(base, 'rb').read()
open(os.path.join(outdir, 'truncated.zip'), 'wb').write(good[:len(good) // 2])
print('made', len(os.listdir(outdir)))

# ======================================================================== fix round 1
import json as J
good = open(base, 'rb').read()


def parse_cd(raw):
    e = raw.rfind(b'PK\x05\x06')
    n = struct.unpack_from('<H', raw, e + 10)[0]
    cdsz, cdoff = struct.unpack_from('<II', raw, e + 12)
    ents, p = [], cdoff
    for _ in range(n):
        nl, el, cl = struct.unpack_from('<HHH', raw, p + 28)
        off = struct.unpack_from('<I', raw, p + 42)[0]
        name = bytes(raw[p + 46:p + 46 + nl]).decode()
        ents.append({'cd': p, 'off': off, 'name': name})
        p += 46 + nl + el + cl
    return e, cdoff, ents


def save(name, data):
    open(os.path.join(outdir, name), 'wb').write(bytes(data))


e0, cdoff0, ents0 = parse_cd(good)
victim = next(x for x in ents0 if x['name'].endswith('.jsonl'))
# 1. the central name is one thing, the local name (what ditto writes) another of the same length
raw = bytearray(good)
nl = struct.unpack_from('<H', raw, victim['off'] + 26)[0]
evil = (b'../../evil-local-name-' + b'x' * nl)[:nl]
raw[victim['off'] + 30:victim['off'] + 30 + nl] = evil
save('local-name.zip', raw)
# 2. a local record no central entry names, hidden before the directory
raw = bytearray(good)
nm = (root + '/hidden.txt').encode()
rec = b'PK\x03\x04' + struct.pack('<HHHHHIIIHH', 20, 0, 0, 0, 0, 0, 5, 5, len(nm), 0) + nm + b'evil!'
raw[cdoff0:cdoff0] = rec
e = bytes(raw).rfind(b'PK\x05\x06')
struct.pack_into('<I', raw, e + 16, cdoff0 + len(rec))
save('hidden-local.zip', raw)
# 3. a local header whose size lies (the central one is right); from a zip without data descriptors, whose local sizes count
import io
bio = io.BytesIO()
with zipfile.ZipFile(bio, 'w', zipfile.ZIP_DEFLATED) as zz:
    copy_all(zz)
raw = bytearray(bio.getvalue())
_, _, entsb = parse_cd(bytes(raw))
vb = next(x for x in entsb if x['name'].endswith('.jsonl'))
struct.pack_into('<I', raw, vb['off'] + 22, 7)
save('local-size-lie.zip', raw)
# 4. a gap between two records (every later offset moved to match, so the directory is consistent with it)
raw = bytearray(good)
srt = sorted(ents0, key=lambda x: x['off'])
cut = srt[1]['off']
raw[cut:cut] = b'J' * 16
for x in ents0:
    if x['off'] >= cut:
        struct.pack_into('<I', raw, x['cd'] + 42 + 16, x['off'] + 16)
e = bytes(raw).rfind(b'PK\x05\x06')
struct.pack_into('<I', raw, e + 16, cdoff0 + 16)
save('gap.zip', raw)
# 5. bytes in front of the first record (offsets moved to match)
raw = bytearray(good)
raw[0:0] = b'P' * 24
for x in ents0:
    struct.pack_into('<I', raw, x['cd'] + 24 + 42, x['off'] + 24)
e = bytes(raw).rfind(b'PK\x05\x06')
struct.pack_into('<I', raw, e + 16, cdoff0 + 24)
save('prepended.zip', raw)
# 6. a central directory entry whose local header is not where it says (points into another record)
raw = bytearray(good)
struct.pack_into('<I', raw, victim['cd'] + 42, srt[0]['off'])
save('offset-elsewhere.zip', raw)


# 7. hand-made zips with zip64 numbers no file can have
def handzip(name, big_usize=0xFFFFFFFF, big_csize=0xFFFFFFFF, big_off=0xFFFFFFFF, extra=b'', off32=None):
    nm1 = (root + '/export.json').encode(); body = b'{}'
    loc = b'PK\x03\x04' + struct.pack('<HHHHHIIIHH', 20, 0, 0, 0, 0, 0, len(body), len(body), len(nm1), 0) + nm1 + body
    def cdent(nm, usz, csz, off, ex):
        return b'PK\x01\x02' + struct.pack('<HHHHHHIIIHHHHHII', 0x031E, 45, 0, 0, 0, 0, 0, csz, usz, len(nm), len(ex), 0, 0, 0, 0o100644 << 16, off) + nm + ex
    nm2 = (root + '/big.bin').encode()
    cd = cdent(nm1, len(body), len(body), 0, b'') + cdent(nm2, 0xFFFFFFFF if extra else (off32 and 5 or 5), 0xFFFFFFFF if extra else 5, 0xFFFFFFFF if extra else (off32 if off32 is not None else 0), extra)
    eo = b'PK\x05\x06' + struct.pack('<HHHHIIH', 0, 0, 2, 2, len(cd), len(loc), 0)
    open(os.path.join(outdir, name), 'wb').write(loc + cd + eo)

handzip('zip64-usize-max.zip', extra=struct.pack('<HHQQQ', 1, 24, 0xFFFFFFFFFFFFFFFF, 5, 0))
handzip('zip64-csize-max.zip', extra=struct.pack('<HHQQQ', 1, 24, 5, 0xFFFFFFFFFFFFFFFF, 0))
handzip('zip64-offset-max.zip', extra=struct.pack('<HHQQQ', 1, 24, 5, 5, 0xFFFFFFFFFFFFFFFF))
handzip('zip64-usize-int64.zip', extra=struct.pack('<HHQQQ', 1, 24, 0x7FFFFFFFFFFFFFFF, 5, 0))
handzip('offset-past-file.zip', off32=0x00FFFFFF)

# 8. a bomb that outruns 1.5 s: 1.5 GB of zeros, the directory AND the local header claiming 100 bytes (so the sizes agree)
raw = bytearray(good)
with zipfile.ZipFile(os.path.join(outdir, 'fastbomb.zip'), 'w', zipfile.ZIP_DEFLATED, compresslevel=1) as z:
    copy_all(z)
    zi = zipfile.ZipInfo(root + '/profiles/p1/transcripts/-app/bomb.jsonl'); zi.compress_type = zipfile.ZIP_DEFLATED; zi.external_attr = 0o100644 << 16
    z.writestr(zi, b'\0' * (1500 << 20), compresslevel=1)
raw = bytearray(open(os.path.join(outdir, 'fastbomb.zip'), 'rb').read())
bn = (root + '/profiles/p1/transcripts/-app/bomb.jsonl').encode()
li = raw.find(bn) - 30            # the local header sits right before its name
struct.pack_into('<I', raw, li + 22, 100)
j = 0
while True:
    j = raw.find(b'PK\x01\x02', j)
    if j < 0: break
    nl2 = struct.unpack_from('<H', raw, j + 28)[0]
    if bytes(raw[j + 46:j + 46 + nl2]) == bn:
        struct.pack_into('<I', raw, j + 24, 100)
    j += 4
open(os.path.join(outdir, 'fastbomb.zip'), 'wb').write(raw)

# 9. a manifest that lies about its accounts, its counts and an item's part
bj = root + '/profiles/p1/backup.json'
m = J.loads(zin.read(bj))
m['accounts'] = [{'account': 'leak@example.com', 'organization': 'x'}]
m['counts'] = {'sessions': 999999, 'sidebar': 1, 'tasks': 77, 'transcripts': 5000}
for it in m['items']:
    if it['role'] == 'transcript':
        it['part'] = 'evil'; break
with zipfile.ZipFile(os.path.join(outdir, 'doctored.zip'), 'w', zipfile.ZIP_DEFLATED) as z:
    copy_all(z, replace={bj: J.dumps(m).encode()})
print('made more', len(os.listdir(outdir)))

# ======================================================================== fix round 2: zips built by hand on top of a real export
import zlib, bz2

def raw_deflate(b, level=6):
    c = zlib.compressobj(level, zlib.DEFLATED, -15); return c.compress(b) + c.flush()

DOS_DATE, DOS_TIME = ((2025 - 1980) << 9) | (3 << 5) | 4, (12 << 11)

def lhdr(name, method, crc, cs, us, flags=0, extra=b''):
    n = name.encode()
    return struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, flags, method, DOS_TIME, DOS_DATE, crc, cs, us, len(n), len(extra)) + n + extra

def chdr(name, method, crc, cs, us, off, flags=0, mode=0o100644, host=3):
    n = name.encode()
    return struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, (host << 8) | 20, 20, flags, method, DOS_TIME, DOS_DATE, crc, cs, us, len(n), 0, 0, 0, 0, mode << 16, off) + n

def ender(cnt, cdsize, cdoff):
    return struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, cnt, cnt, cdsize, cdoff, 0)

base_entries = [(i.filename, zin.read(i.filename)) for i in infos if not i.filename.endswith('/')]
victim_name = next(n for n, d in base_entries if '/transcripts/' in n and n.endswith('.jsonl') and len(d) > 50)

def build(path, tweak=None):
    """A valid export zip made by hand (deflate entries); tweak(name, data) may return (method, payload, crc, usize, csize) for one entry."""
    body, cd = b'', b''
    for name, data in base_entries:
        crc, us = zlib.crc32(data) & 0xFFFFFFFF, len(data)
        method, payload, cs = 8, raw_deflate(data), None
        if tweak:
            t = tweak(name, data)
            if t: method, payload, crc, us, cs = t
        cs = len(payload) if cs is None else cs
        cd += chdr(name, method, crc, cs, us, len(body))
        body += lhdr(name, method, crc, cs, us) + payload
    open(os.path.join(outdir, path), 'wb').write(body + cd + ender(len(base_entries), len(cd), len(body)))

def hidden_record(name, content=b'escaped\n'):
    return lhdr(name, 0, zlib.crc32(content) & 0xFFFFFFFF, len(content), len(content)) + content

def only_victim(fn):
    return lambda name, data: fn(name, data) if name == victim_name else None

build('plain-by-hand.zip')                                                    # control: the same export, built here, must open
build('early.zip', only_victim(lambda n, d: (8, raw_deflate(d) + hidden_record(root + '/hidden.txt'), zlib.crc32(d) & 0xFFFFFFFF, len(d), None)))
build('early_dotdot.zip', only_victim(lambda n, d: (8, raw_deflate(d) + hidden_record('../../EV-dotdot.txt'), zlib.crc32(d) & 0xFFFFFFFF, len(d), None)))
build('early_abs.zip', only_victim(lambda n, d: (8, raw_deflate(d) + hidden_record('/tmp/cl_audit-e-abs2-evil.txt'), zlib.crc32(d) & 0xFFFFFFFF, len(d), None)))
build('csize0.zip', only_victim(lambda n, d: (8, b'', zlib.crc32(d) & 0xFFFFFFFF, len(d), 0)))
build('defl-early.zip', only_victim(lambda n, d: (8, raw_deflate(d) + b'GARBAGE-AFTER-THE-END', zlib.crc32(d) & 0xFFFFFFFF, len(d), None)))
build('defl-past.zip', only_victim(lambda n, d: (8, raw_deflate(d)[:-3], zlib.crc32(d) & 0xFFFFFFFF, len(d), None)))
build('crc-bad.zip', only_victim(lambda n, d: (8, raw_deflate(d), (zlib.crc32(d) ^ 0xDEADBEEF) & 0xFFFFFFFF, len(d), None)))
build('stored-mismatch.zip', only_victim(lambda n, d: (0, d + b'X', zlib.crc32(d) & 0xFFFFFFFF, len(d), None)))
build('method-bzip2.zip', only_victim(lambda n, d: (12, bz2.compress(d), zlib.crc32(d) & 0xFFFFFFFF, len(d), None)))
build('method-lzma.zip', only_victim(lambda n, d: (14, b'\x05\x02\x05\x00' + raw_deflate(d), zlib.crc32(d) & 0xFFFFFFFF, len(d), None)))
build('stored-ok.zip', lambda n, d: (0, d, zlib.crc32(d) & 0xFFFFFFFF, len(d), None))                       # stored entries are fine
# host byte 0 and 19 claiming a link: refused whatever the host
for tag, host in [('host0', 0), ('host19', 19)]:
    body, cd = b'', b''
    for name, data in base_entries:
        crc, us = zlib.crc32(data) & 0xFFFFFFFF, len(data); payload = raw_deflate(data)
        mode = 0o120777 if name == victim_name else 0o100644
        cd += chdr(name, 8, crc, len(payload), us, len(body), mode=mode, host=host)
        body += lhdr(name, 8, crc, len(payload), us) + payload
    open(os.path.join(outdir, 'link-%s.zip' % tag), 'wb').write(body + cd + ender(len(base_entries), len(cd), len(body)))
# zip64 entries (force_zip64: the local header says 0xFFFFFFFF and carries the sizes in its zip64 extra): still opens
with zipfile.ZipFile(os.path.join(outdir, 'zip64-force.zip'), 'w', zipfile.ZIP_DEFLATED) as z:
    for name, data in base_entries:
        zi = zipfile.ZipInfo(name, (2025, 3, 4, 12, 0, 0)); zi.external_attr = 0o100644 << 16; zi.compress_type = zipfile.ZIP_DEFLATED
        with z.open(zi, 'w', force_zip64=True) as f: f.write(data)
# a deflate stream that ends exactly at csize but whose entry is a data descriptor with a lying local width: refused by the tiling
print('made by hand', len(os.listdir(outdir)))

# data descriptors: width decided by the local zip64 extra; local sizes 0 or the central ones; and the end-of-directory gap
def build_desc(path, mode):
    body, cd = b'', b''
    for name, data in base_entries:
        crc, us = zlib.crc32(data) & 0xFFFFFFFF, len(data); payload = raw_deflate(data); cs = len(payload)
        cd += chdr(name, 8, crc, cs, us, len(body), flags=8)
        if mode == 'ok32':
            lh = lhdr(name, 8, 0, 0, 0, flags=8); desc = struct.pack('<IIII', 0x08074b50, crc, cs, us)
        elif mode == 'lie':
            lh = lhdr(name, 8, 0, 5, 5, flags=8); desc = struct.pack('<IIII', 0x08074b50, crc, cs, us)
        elif mode == 'w64-no-extra':
            lh = lhdr(name, 8, 0, 0, 0, flags=8); desc = struct.pack('<IIQQ', 0x08074b50, crc, cs, us)
        elif mode == 'ok64':
            lh = lhdr(name, 8, 0, 0xFFFFFFFF, 0xFFFFFFFF, flags=8, extra=struct.pack('<HHQQ', 1, 16, 0, 0)); desc = struct.pack('<IIQQ', 0x08074b50, crc, cs, us)
        body += lh + payload + desc
    open(os.path.join(outdir, 'desc-%s.zip' % mode), 'wb').write(body + cd + ender(len(base_entries), len(cd), len(body)))

for m in ['ok32', 'lie', 'w64-no-extra', 'ok64']:
    build_desc(None, m)

# a zip64 locator that points somewhere else; and 76 bytes of junk between the directory and the end record
ge = bytes(good); e_at = ge.rfind(b'PK\x05\x06'); cdend = struct.unpack_from('<I', ge, e_at + 12)[0] + struct.unpack_from('<I', ge, e_at + 16)[0]
loc = struct.pack('<IIQI', 0x07064b50, 0, 1234, 1)
open(os.path.join(outdir, 'bad-locator.zip'), 'wb').write(ge[:cdend] + b'\0' * 56 + loc + ge[e_at:])
open(os.path.join(outdir, 'junk-gap.zip'), 'wb').write(ge[:cdend] + b'J' * 76 + ge[e_at:])
print('made desc', len(os.listdir(outdir)))

# ======================================================================== fix round 3
import random
rnd3 = random.Random(11)

def chdr_x(name, method, crc, cs, us, off, extra=b'', dosd=DOS_DATE, dost=DOS_TIME, mode=0o100644, host=3):
    n = name.encode()
    return struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, (host << 8) | 20, 20, 0, method, dost, dosd, crc, cs, us, len(n), len(extra), 0, 0, 0, mode << 16, off) + n + extra

def build3(path, tweak=None, extra=None, dosd=DOS_DATE, dost=DOS_TIME):
    """The export rebuilt by hand; tweak(name, data) -> (data, trailer) for one entry; extra(name) -> the central directory's extra field."""
    body, cd = b'', b''
    for name, data in base_entries:
        trailer = b''
        if tweak:
            t = tweak(name, data)
            if t: data, trailer = t
        crc, us = zlib.crc32(data) & 0xFFFFFFFF, len(data)
        payload = raw_deflate(data) + trailer
        cd += chdr_x(name, 8, crc, len(payload), us, len(body), extra=extra(name) if extra else b'', dosd=dosd, dost=dost)
        body += lhdr(name, 8, crc, len(payload), us) + payload
    open(os.path.join(outdir, path), 'wb').write(body + cd + ender(len(base_entries), len(cd), len(body)))

# 1. trailing bytes inside csize after a deflate stream's end: 1, 7, 5000 and 100000 bytes, on a small, a mid (3 KB) and a big (150 KB) entry
sizes3 = {'small': None, 'mid': 3000, 'big': 150000}
for tag, size in sizes3.items():
    for k in (1, 7, 5000, 100000):
        trailer = (b'PK\x03\x04' + b'A' * (k - 4)) if k >= 4 else b'Z' * k
        def tw(n, d, size=size, trailer=trailer):
            if n != victim_name: return None
            return ((bytes(rnd3.getrandbits(8) for _ in range(size)) if size else d), trailer)
        build3('trail_%s_%d.zip' % (tag, k), tw)

# 2. times: a hostile future UT (2106), a future DOS time (2107), a fixed time in the Unix extra (0x5855) that the DOS time contradicts,
#    the extended timestamp with its flags byte saying "no mtime" (then 0x5855 is the one), DOS zero
FIXED = 1700000000
ux = lambda t: struct.pack('<HHII', 0x5855, 8, t, t)
ut = lambda t, flags=1: struct.pack('<HHB', 0x5455, 5, flags) + struct.pack('<I', t)
build3('mt-future-ut.zip', extra=lambda n: ut(0x7FFFFFF0))
build3('mt-ut-signed.zip', extra=lambda n: ut(0xFFFFFFFF))                                            # read as a signed 32-bit number: 1969, held to 1980
build3('mt-future-dos.zip', dosd=(127 << 9) | (12 << 5) | 31, dost=(23 << 11) | (59 << 5) | 29)
build3('mt-ux-fixed.zip', extra=lambda n: ux(FIXED), dosd=((2031 - 1980) << 9) | (1 << 5) | 1)          # DOS time says 2031: not believed
build3('mt-ut-fixed.zip', extra=lambda n: ut(FIXED), dosd=((2031 - 1980) << 9) | (1 << 5) | 1)
build3('mt-ut-noflag.zip', extra=lambda n: ut(0xFFFFFFFF, flags=0) + ux(FIXED))                        # flags: no mtime in 0x5455; 0x5855 has it
build3('mt-ux-future.zip', extra=lambda n: ux(0xFFFFFFFF))
build3('mt-ux-ancient.zip', extra=lambda n: ux(5))                                                     # 1970: held to 1980
build3('mt-dos-zero.zip', dosd=0, dost=0)

# 3. a folder entry that says it holds data
dirs = [i.filename for i in infos if i.filename.endswith('/')]
if dirs:
    d0 = dirs[0]
    ents = [(i.filename, zin.read(i.filename) if not i.filename.endswith('/') else b'') for i in infos]
    for tag in ('usize', 'csize'):
        body, cd = b'', b''
        for name, data in ents:
            if name == d0:
                payload = b'\x03\x00' if tag == 'csize' else b''
                us = 5 if tag == 'usize' else 0
                method = 0 if tag == 'usize' else 8
                if tag == 'usize': payload = b'hello'
                cs = len(payload)
                crc = zlib.crc32(b'hello') & 0xFFFFFFFF if tag == 'usize' else 0
                cd += chdr_x(name, method, crc, cs, us, len(body), mode=0o040755)
                body += lhdr(name, method, crc, cs, us) + payload
            else:
                crc, us = zlib.crc32(data) & 0xFFFFFFFF, len(data)
                if name.endswith('/'):
                    cd += chdr_x(name, 0, 0, 0, 0, len(body), mode=0o040755); body += lhdr(name, 0, 0, 0, 0)
                else:
                    payload = raw_deflate(data)
                    cd += chdr_x(name, 8, crc, len(payload), us, len(body)); body += lhdr(name, 8, crc, len(payload), us) + payload
        open(os.path.join(outdir, 'folder-%s.zip' % tag), 'wb').write(body + cd + ender(len(ents), len(cd), len(body)))

# 4. a deep long-named path: 16 parts of 255 bytes (the whole name is far over 512)
long_name = root + '/' + '/'.join(['L' * 255] * 14) + '/f'
body, cd = b'', b''
for name, data in base_entries + [(long_name, b'x')]:
    crc, us = zlib.crc32(data) & 0xFFFFFFFF, len(data); payload = raw_deflate(data)
    cd += chdr_x(name, 8, crc, len(payload), us, len(body)); body += lhdr(name, 8, crc, len(payload), us) + payload
open(os.path.join(outdir, 'longpath.zip'), 'wb').write(body + cd + ender(len(base_entries) + 1, len(cd), len(body)))
# ...a name of 600 bytes made of short parts
mid_name = root + '/' + '/'.join(['d' * 36] * 14) + '/f'
body, cd = b'', b''
for name, data in base_entries + [(mid_name, b'x')]:
    crc, us = zlib.crc32(data) & 0xFFFFFFFF, len(data); payload = raw_deflate(data)
    cd += chdr_x(name, 8, crc, len(payload), us, len(body)); body += lhdr(name, 8, crc, len(payload), us) + payload
open(os.path.join(outdir, 'longname-512.zip'), 'wb').write(body + cd + ender(len(base_entries) + 1, len(cd), len(body)))

# 5. names that APFS folds to one: a final sigma and a medial one, in folders
sig_dir = root + '/profiles/p1/transcripts/'
body, cd = b'', b''
for name, data in base_entries + [(sig_dir + 'σ/x.jsonl', b'x'), (sig_dir + 'ς/x.jsonl', b'y')]:
    crc, us = zlib.crc32(data) & 0xFFFFFFFF, len(data); payload = raw_deflate(data)
    cd += chdr_x(name, 8, crc, len(payload), us, len(body)); body += lhdr(name, 8, crc, len(payload), us) + payload
open(os.path.join(outdir, 'sigma.zip'), 'wb').write(body + cd + ender(len(base_entries) + 2, len(cd), len(body)))
print('made round 3', len(os.listdir(outdir)))

# 6. the zip64 end record: a locator that points at a record without the signature; one whose numbers disagree with the 32-bit end record
ge = bytes(good); e_at = ge.rfind(b'PK\x05\x06')
cdsz, cdoff = struct.unpack_from('<II', ge, e_at + 12); cnt = struct.unpack_from('<H', ge, e_at + 10)[0]
z64 = lambda sig, n, sz, off: struct.pack('<IQHHIIQQQQ', sig, 44, 45, 45, 0, 0, n, n, sz, off)
loc64 = struct.pack('<IIQI', 0x07064b50, 0, cdoff + cdsz, 1)
open(os.path.join(outdir, 'bad-z64-record.zip'), 'wb').write(ge[:cdoff + cdsz] + z64(0x01020304, cnt, cdsz, cdoff) + loc64 + ge[e_at:])
open(os.path.join(outdir, 'z64-disagrees.zip'), 'wb').write(ge[:cdoff + cdsz] + z64(0x06064b50, cnt, cdsz + 1, cdoff) + loc64 + ge[e_at:])
# ...and the same record told truly, which is fine (the control)
open(os.path.join(outdir, 'z64-true.zip'), 'wb').write(ge[:cdoff + cdsz] + z64(0x06064b50, cnt, cdsz, cdoff) + loc64 + ge[e_at:])

# 7. round 4: high-ratio data (zeros) and slack inside csize, on a real export (the zeros entry replaces the victim's data)
for tag, trailer in [('s1', b'Z'), ('s30', b'Z' * 30), ('hid', (b'PK\x03\x04' + b'H' * 26 + b'r/evil' + b'E' * 994) + b'Q' * 30)]:
    def tw(n, d, trailer=trailer):
        return (b'\0' * 100000, trailer) if n == victim_name else None
    build3('highratio_%s.zip' % tag, tw)
