#!/usr/bin/env python3
"""Looks for what must never be committed to this public repo: secrets, real addresses, real ids, personal paths and names.

  python3 -I -B leakscan.py ROOT [--skip DIR]... [--no-keys]

Refuses (exit 1, one line per hit) on:
  - keys and tokens: the app's own SecretScan finds them (Sources/SecretScan.swift, the engines' one secret scan: no pattern
    lives here), through the secretscan tool that $SECRETSCAN names, or, when it isn't set, the one Checks/run.sh scan builds
    (Checks/.work/scan/cl_audit-checks-scan). Without the tool the scan doesn't run at all (exit 2): a key check that skips
    itself is worse than none. --no-keys leaves keys to a caller that has just run the tool over the same files (run.sh's scan);
  - an e-mail address whose domain is not example.com/.org/.net, *.invalid, *.test, *.example or a single word (x);
  - a UUID that is not one of the obviously synthetic fixtures (000...-4000-8000-..., aaaaaaaa-1111-..., abcdef01-...);
  - a path /Users/<anyone>;
  - a personal or business word: the list is a local file, one word per line, never committed: $LEAKWORDS, or
    Checks/.work/leakwords (the folder git ignores). Without that file the word check is skipped, and the first line of the
    output says so.
"""
import os, re, subprocess, sys, tempfile

def secretscan():
    """The app's secretscan tool ($SECRETSCAN; when it isn't set at all, the one Checks/run.sh scan builds), or the scan stops
    here (exit 2): never a key check that quietly didn't run. Set but empty means no tool."""
    p = os.environ.get('SECRETSCAN')
    if p is None:
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '.work', 'scan', 'cl_audit-checks-scan')
    if not p or not (os.path.isfile(p) and os.access(p, os.X_OK)):
        print('leak scan: the key check needs the app\'s secretscan tool: set $SECRETSCAN (Checks/run.sh scan builds '
              'Checks/.work/scan/cl_audit-checks-scan); not run')
        sys.exit(2)
    return p

def key_hits(paths):
    """{path: [(line, what)]}: the keys the app's own SecretScan finds in these files, a line at a time."""
    out = {}
    tool = secretscan()
    for i in range(0, len(paths), 400):
        r = subprocess.run([tool, '--lines', *paths[i:i + 400]], capture_output=True, text=True, errors='replace')
        if r.returncode not in (0, 1): print(f'leak scan: the secretscan tool failed ({r.returncode})'); sys.exit(2)
        for l in r.stdout.splitlines():
            if l.startswith('HIT '):
                where, kinds = l[4:].rsplit(': ', 1)
                path, line = where.rsplit(':', 1)
                out.setdefault(path, []).append((int(line), f'secret ({kinds})'))
            elif l.startswith('UNREAD '):
                out.setdefault(l[7:], []).append((0, 'secret (not readable by the key check)'))
    return out

EMAIL = re.compile(r'[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)')
OK_DOMAIN = re.compile(r'^(?:example\.(?:com|org|net)|[a-z0-9.-]*\.(?:invalid|test|example)|[A-Za-z0-9-]+)$')
UUID = re.compile(r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b')
OK_UUID = re.compile(r'^(?:00000000-0000-4000-8000-0{10}[0-9a-f]{2}|([a-f])\1{7}-1111-4222-8333-444444444444|abcdef01-0000-4000-8000-0{10}[0-9]{2})$')
PATHS = re.compile(r'/Users/[A-Za-z0-9._-]+')

def load_words(here):
    """The personal and business words (one per line), from $LEAKWORDS or Checks/.work/leakwords: a local file that is never
    committed. None when there is no such file."""
    path = os.environ.get('LEAKWORDS') or os.path.join(here, '.work', 'leakwords')
    try:
        words = [w.strip() for w in open(path, errors='replace') if w.strip() and not w.startswith('#')]
    except OSError:
        return None
    return re.compile('|'.join(re.escape(w) for w in words), re.I) if words else None

NAMES = None

def scan_text(text, keys=True):
    """The hits in a text: (line, what). Keys through the app's own SecretScan (the text goes to it as a file of its own)."""
    hits = []
    def at(i): return text.count('\n', 0, i) + 1
    if keys:
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, 'text')
            with open(p, 'w', encoding='utf-8', errors='replace') as f: f.write(text)
            hits += key_hits([p]).get(p, [])
    for m in EMAIL.finditer(text):
        if not OK_DOMAIN.match(m.group(1)): hits.append((at(m.start()), f'address {m.group(0)}'))
    for m in UUID.finditer(text):
        if not OK_UUID.match(m.group(0).lower()): hits.append((at(m.start()), f'id {m.group(0)}'))
    for m in PATHS.finditer(text): hits.append((at(m.start()), f'path {m.group(0)}'))
    if NAMES:
        for m in NAMES.finditer(text): hits.append((at(m.start()), 'word ' + m.group(0)[:2] + '...'))
    return hits

def main(argv):
    global NAMES
    roots, skip = [], []
    it = iter(argv)
    NAMES = load_words(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
    if NAMES is None: print('leak scan: no word list (Checks/.work/leakwords or $LEAKWORDS): the word check is SKIPPED')
    keys = True
    for a in it:
        if a == '--skip': skip.append(next(it))
        elif a == '--no-keys': keys = False
        else: roots.append(a)
    if keys: secretscan()                               # (before anything is read: no tool, no scan)
    else: print('leak scan: keys are left to the caller (--no-keys): it ran the app\'s secretscan tool over these files')
    total = files = 0
    for root in roots:
        found = []
        for d, dirs, fs in os.walk(root):
            dirs[:] = [x for x in dirs if x not in ('.work', '.git') and os.path.relpath(os.path.join(d, x), root) not in skip]
            for f in sorted(fs):
                p = os.path.join(d, f)
                try: text = open(p, errors='replace').read()
                except OSError: continue
                found.append(p)
                files += 1
                for line, what in scan_text(text, keys=False):
                    total += 1; print(f'{os.path.relpath(p, root)}:{line}: {what}')
        if keys:
            for p, hs in key_hits(found).items():
                for line, what in hs: total += 1; print(f'{os.path.relpath(p, root)}:{line}: {what}')
    print(f'leak scan: {files} files, {total} hits' + (f' (skipped: {", ".join(skip)})' if skip else ''))
    return 1 if total else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
