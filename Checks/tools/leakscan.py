#!/usr/bin/env python3
"""Looks for what must never be committed to this public repo: secrets, real addresses, real ids, personal paths and names.

  python3 -I -B leakscan.py ROOT [--skip DIR]...

Refuses (exit 1, one line per hit) on:
  - keys and tokens: the shapes the app's own SecretScan looks for (GitHub, AWS, private keys, Anthropic, OpenAI, Slack,
    Google, Stripe, npm, Supabase, GitLab, Hugging Face) and JWTs;
  - an e-mail address whose domain is not example.com/.org/.net, *.invalid, *.test, *.example or a single word (x);
  - a UUID that is not one of the obviously synthetic fixtures (000...-4000-8000-..., aaaaaaaa-1111-..., abcdef01-...);
  - a path /Users/<anyone>;
  - a personal or business word: the list is a local file, one word per line, never committed: $LEAKWORDS, or
    Checks/.work/leakwords (the folder git ignores). Without that file the word check is skipped, and the first line of the
    output says so.
"""
import os, re, sys

A = '[A-Za-z0-9]'
SECRETS = [
    ('github', r'gh[pousr]_' + A + '{36}'), ('github', r'github_pat_[A-Za-z0-9_]{22}'),
    ('aws', r'(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9])'),
    ('private key', r'-----BEGIN [^\n]{0,48}PRIVATE KEY(?: BLOCK)?-----'),
    ('anthropic', r'sk-ant-[A-Za-z0-9_-]{20}'),
    ('openai', r'sk-(?!ant-)(?=[A-Za-z0-9_-]{0,39}[0-9])[A-Za-z0-9_-]{40}'),
    ('slack', r'xox[baprse]-[A-Za-z0-9-]{10}'), ('slack', r'xoxe\.xox[A-Za-z0-9.-]{10}'),
    ('google', r'AIza[A-Za-z0-9_-]{35}'), ('stripe', r'[sr]k_live_' + A + '{16}'),
    ('npm', r'npm_' + A + '{36}'), ('supabase', r'sbp_' + A + '{30}'), ('gitlab', r'glpat-[A-Za-z0-9_-]{20}'),
    ('huggingface', r'hf_' + A + '{30}'),
    ('jwt', r'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{20,}'),
]
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

def scan_text(text):
    hits = []
    def at(i): return text.count('\n', 0, i) + 1
    for kind, p in SECRETS:
        for m in re.finditer(p, text):
            i = m.start(); before = text[i - 1] if i else ' '
            if not re.match(r'[A-Za-z0-9_-]', before): hits.append((at(i), f'secret ({kind}) {m.group(0)[:10]}...'))
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
    for a in it:
        if a == '--skip': skip.append(next(it))
        else: roots.append(a)
    total = files = 0
    for root in roots:
        for d, dirs, fs in os.walk(root):
            dirs[:] = [x for x in dirs if x not in ('.work', '.git') and os.path.relpath(os.path.join(d, x), root) not in skip]
            for f in sorted(fs):
                p = os.path.join(d, f)
                try: text = open(p, errors='replace').read()
                except OSError: continue
                files += 1
                for line, what in scan_text(text):
                    total += 1; print(f'{os.path.relpath(p, root)}:{line}: {what}')
    print(f'leak scan: {files} files, {total} hits' + (f' (skipped: {", ".join(skip)})' if skip else ''))
    return 1 if total else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
