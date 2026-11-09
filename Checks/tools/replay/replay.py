#!/usr/bin/env python3
"""Rebuild files from the tool calls recorded in Claude Code transcripts (ops.jsonl from extract.py). Nothing recorded is executed.

  replay.py OPS OUTDIR [--until TS] [--allow-slices]

The files live in memory (path -> text), keyed by the session's scratch folder (its first 8 characters) and the path inside it.
Applied:
  - Write payloads, Edit payloads (same rule as the tool: the text must occur, once unless replace_all) and whole-file Read
    snapshots (a snapshot is the truth: it replaces the replayed text and clears a gap). Partial Reads are compared only.
  - From Bash commands, recorded DATA only, each applied by this program: `cat > f <<'EOF'` and `cat >> f <<'EOF'` bodies;
    cp, mv, rm, touch between known paths; `sed -n 'A,Bp'`, `sed -e 'Nd;Md'`, `sed -i '' 's/lit/lit/'` with literal text;
    `{ sed -n ..; cat f; } > out` groups; `git merge-file -p a b c > out` (the one program started: on temp copies of
    recovered texts, with an empty environment); and python heredocs whose AST shows only literal text operations on a file:
        p = '<lit>'; s = open(p).read(); s = s.replace('<lit>', '<lit>'[, n]); s += '<lit>'; assert '<lit>' in s;
        assert s.count('<lit>') == 1; the helper `def rep(old, new)` built from those; open(p, 'w').write(s)
    A python script is never run: it is read as data. With --allow-slices the reader also does s.index('<lit>') and slicing
    (offsets computed from literals, still only text operations); without it such a script is a gap.
  - Anything else in a command that could change a text file (another interpreter, awk, sed -i with a pattern, a pipeline into a
    file, a loop that writes files, ...) is not applied: the files it names are marked as GAPS, and so is every file copied or
    merged from a gap. A gap ends at the next Write or whole-file Read of that file.
OUTDIR gets replay.log, gaps.json and, for each .swift/.sh/.py file, every version it had (versions/<name>@<ts>@<hash>).
"""
import ast, collections, hashlib, json, os, re, shutil, subprocess, sys, tempfile

ops_file, OUT = sys.argv[1], os.path.abspath(sys.argv[2])
until = sys.argv[sys.argv.index('--until') + 1] if '--until' in sys.argv else '9999'
ALLOW_SLICES = '--allow-slices' in sys.argv
GIT = shutil.which('git')
os.makedirs(os.path.join(OUT, 'versions'), exist_ok=True)
log = open(os.path.join(OUT, 'replay.log'), 'w')
def L(*a):
    log.write(' '.join(str(x) for x in a) + '\n'); log.flush()

SCR = re.compile(r'/private/tmp/claude-\d+/(-[A-Za-z0-9_-]+)/([0-9a-f]{8})-[0-9a-f-]{27}/scratchpad')
TRACKED = ('.swift', '.sh', '.py')
files, gaps = {}, {}
versions = collections.defaultdict(list)
stats = collections.Counter()

def resolve(path, cwd):
    p = path
    if not p.startswith('/'):
        if cwd is None: return None
        p = cwd.rstrip('/') + '/' + p
    p = os.path.normpath(p)
    m = SCR.match(p)
    return (m.group(2) + p[m.end():]) if m else 'ABS:' + p

def tracked(key): return key is not None and key.endswith(TRACKED)

def put(key, text, ts, gap=None):
    files[key] = text
    if gap: gaps[key] = gap
    else: gaps.pop(key, None)
    if key.endswith(TRACKED):
        h = hashlib.md5(text.encode('utf-8', 'surrogateescape')).hexdigest()[:8]
        if not versions[key] or versions[key][-1][2] != h:
            # the timestamp becomes part of a file name: only digits, T, ':', '.', '-' are kept, whatever the transcript says
            versions[key].append((re.sub(r'[^0-9T:.-]', '', ts)[:19].replace(':', ''), text, h))

def mark_gap(key, why):
    if tracked(key) and not key.startswith('ABS:'):
        if key not in gaps: stats['gap'] += 1
        gaps[key] = why; L('GAP', key, '|', why)

class Unsupported(Exception): pass
class Aborted(Exception): pass

# ------------------------------------------------------------------------------------------------ shell reading
HDRE = re.compile(r"<<-?\s*(['\"]?)(\w+)\1")

def split_statements(cmd):
    """[(head, [(tag, quoted, body)])]: top-level statements; heredoc bodies belong to the statement that announced them."""
    out, pend, i, n = [], [], 0, len(cmd)
    cur = {'head': [], 'hd': []}
    quote, depth, brace = None, 0, 0
    def flush():
        nonlocal cur
        t = ''.join(cur['head']).strip()
        if t: out.append((t, cur['hd']))
        cur = {'head': [], 'hd': []}
    while i < n:
        c = cmd[i]
        if quote:
            cur['head'].append(c)
            if c == '\\' and quote == '"' and i + 1 < n: cur['head'].append(cmd[i + 1]); i += 2; continue
            if c == quote: quote = None
            i += 1; continue
        if c == '\\' and i + 1 < n: cur['head'].append(c + cmd[i + 1]); i += 2; continue
        if c in '\'"': quote = c; cur['head'].append(c); i += 1; continue
        if c == '#' and (not cur['head'] or cur['head'][-1] in ' \t\n;&|('):
            j = cmd.find('\n', i); i = n if j < 0 else j; continue
        if cmd.startswith('$(', i): depth += 1; cur['head'].append('$('); i += 2; continue
        if c == '(' and depth: depth += 1
        if c == ')' and depth: depth -= 1
        if cmd.startswith('<<', i) and not cmd.startswith('<<<', i):
            m = HDRE.match(cmd, i)
            if m:
                pend.append((cur, m.group(2), bool(m.group(1)), cmd.startswith('<<-', i)))
                cur['head'].append(m.group(0)); i = m.end(); continue
        if c == '{' and (i == 0 or cmd[i - 1] in ' \t\n;&|(') and i + 1 < n and cmd[i + 1] in ' \n': brace += 1
        if c == '}' and brace and cmd[i - 1] in ' \t\n;': brace -= 1
        if c == '\n':
            i += 1
            for owner, tag, quoted, dash in pend:
                lines = []
                while i < n:
                    j = cmd.find('\n', i); j = n if j < 0 else j
                    line = cmd[i:j]; i = min(j + 1, n)
                    if (line.strip() if dash else line) == tag: break
                    lines.append(line)
                owner['hd'].append((tag, quoted, '\n'.join(lines) + ('\n' if lines else '')))
            pend = []
            if depth or brace: cur['head'].append('\n')
            else: flush()
            continue
        if not depth and not brace and (c == ';' or cmd.startswith('&&', i) or cmd.startswith('||', i)):
            if c == ';' and cmd.startswith(';;', i): cur['head'].append(';;'); i += 2; continue
            flush(); i += 1 if c == ';' else 2; continue
        cur['head'].append(c); i += 1
    flush()
    units, k = [], 0
    while k < len(out):
        t, hd = out[k]
        first = re.match(r'\s*([A-Za-z_]+)', t)
        if first and first.group(1) in ('for', 'if', 'while', 'until', 'case'):
            parts, hds, d = [], [], 0
            while k < len(out):
                t2, h2 = out[k]; parts.append(t2); hds += h2
                for w in re.findall(r'(?<![\w$-])(for|while|until|case|if|done|fi|esac)(?![\w-])', t2):
                    d += 1 if w in ('for', 'while', 'until', 'case', 'if') else -1
                k += 1
                if d <= 0: break
            units.append(('\n'.join(parts), hds))
        else:
            units.append((t, hd)); k += 1
    return units

def split_simple(text):
    """Cuts a group's inside at ; and newlines outside quotes and $( )."""
    parts, cur, quote, depth, i = [], [], None, 0, 0
    while i < len(text):
        c = text[i]
        if quote:
            cur.append(c)
            if c == quote: quote = None
        elif c in '\'"': quote = c; cur.append(c)
        elif text.startswith('$(', i): depth += 1; cur.append('$('); i += 1
        elif c == ')' and depth: depth -= 1; cur.append(c)
        elif c in ';\n' and not depth: parts.append(''.join(cur)); cur = []
        else: cur.append(c)
        i += 1
    parts.append(''.join(cur))
    return [p.strip() for p in parts if p.strip()]

def arith(expr, env):
    expr = re.sub(r'\$?\b([A-Za-z_]\w*)\b', lambda m: str(env[m.group(1)]) if m.group(1) in env else m.group(0), expr)
    if not re.fullmatch(r'[\d\s+\-*/()]+', expr) or '**' in expr or len(expr) > 60: raise Unsupported('arith ' + expr[:60])   # no powers
    return str(int(eval(expr, {'__builtins__': {}}, {})))      # digits and + - * / ( ) only, after the check above

def substitution(inner, env, cwd):
    """The pure-text forms: $(grep -n 'lit' file | cut -d: -f1) and $(wc -l < file)."""
    inner = inner.strip()
    m = re.fullmatch(r"grep -n ('[^']*'|\"[^\"]*\") (\S+) \| cut -d: -f1", inner)
    if m:
        pat = m.group(1)[1:-1]
        if m.group(1)[0] == '"': pat = expand(pat, env, cwd)
        if '\\' in pat.replace('\\"', '') or re.search(r'[\[\]*^]', pat): raise Unsupported('grep pattern')
        key = resolve(expand(m.group(2).strip('"'), env, cwd), cwd)
        if key not in files: raise Unsupported('grep of an unknown file')
        return '\n'.join(str(i + 1) for i, l in enumerate(files[key].split('\n')) if pat in l)
    m = re.fullmatch(r'wc -l < (\S+)', inner)
    if m:
        key = resolve(expand(m.group(1).strip('"'), env, cwd), cwd)
        if key not in files: raise Unsupported('wc of an unknown file')
        t = files[key]; return str(t.count('\n') + (0 if t.endswith('\n') or not t else 1))
    raise Unsupported('substitution ' + inner[:40])

def balanced(text, i, opener):
    depth, j = len(opener) - 1 + 1 if False else (2 if opener == '$((' else 1), i + len(opener)
    while j < len(text) and depth:
        depth += (text[j] == '(') - (text[j] == ')'); j += 1
    return j

def expand(text, env, cwd):
    out, i = [], 0
    while i < len(text):
        c = text[i]
        if text.startswith('$((', i):
            j = balanced(text, i, '$(('); out.append(arith(text[i + 3:j - 2], env)); i = j
        elif text.startswith('$(', i):
            j = balanced(text, i, '$('); out.append(substitution(text[i + 2:j - 1], env, cwd)); i = j
        elif c == '`': raise Unsupported('backticks')
        elif c == '$':
            m = re.match(r'\$\{(\w+)\}|\$(\w+)', text[i:])
            if not m: out.append(c); i += 1; continue
            name = m.group(1) or m.group(2)
            if name not in env: raise Unsupported('unset $' + name)
            out.append(env[name]); i += m.end()
        elif c == '\\' and i + 1 < len(text):
            out.append(text[i + 1] if text[i + 1] in '$"\\`' else text[i:i + 2]); i += 2
        else: out.append(c); i += 1
    return ''.join(out)

def words_of(head, env, cwd):
    words, cur, has, i, n = [], [], False, 0, len(head)
    def end():
        nonlocal cur, has
        if has: words.append(''.join(cur))
        cur, has = [], False
    while i < n:
        c = head[i]
        if c in ' \t\n': end(); i += 1; continue
        if c == "'":
            j = head.find("'", i + 1)
            if j < 0: raise Unsupported('quote')
            cur.append(head[i + 1:j]); has = True; i = j + 1; continue
        if c == '"':
            j, buf = i + 1, []
            while j < n and head[j] != '"':
                if head[j] == '\\' and j + 1 < n: buf.append(head[j:j + 2]); j += 2; continue
                if head.startswith('$((', j): k = balanced(head, j, '$(('); buf.append(head[j:k]); j = k; continue
                if head.startswith('$(', j): k = balanced(head, j, '$('); buf.append(head[j:k]); j = k; continue
                buf.append(head[j]); j += 1
            cur.append(expand(''.join(buf), env, cwd)); has = True; i = j + 1; continue
        if c in '|&': end(); words.append(c); i += 1; continue
        if c in '<>':
            if has and ''.join(cur).isdigit(): cur, has = [], False        # a file descriptor in front: 2>/dev/null
            end()
            mm = re.match(r'(>>|>&|>\||>|<<<|<<-?|<&|<)', head[i:]); words.append(mm.group(1)); i += mm.end(); continue
        if c == '\\' and i + 1 < n: cur.append(head[i + 1]); has = True; i += 2; continue
        if c == '$':
            if head.startswith('$((', i): k = balanced(head, i, '$(('); cur.append(arith(head[i + 3:k - 2], env)); has = True; i = k; continue
            if head.startswith('$(', i): k = balanced(head, i, '$('); cur.append(substitution(head[i + 2:k - 1], env, cwd)); has = True; i = k; continue
            m = re.match(r'\$\{(\w+)\}|\$(\w+)', head[i:])
            if m:
                name = m.group(1) or m.group(2)
                if name not in env: raise Unsupported('unset $' + name)
                cur.append(env[name]); has = True; i += m.end(); continue
        cur.append(c); has = True; i += 1
    end()
    return words

def split_redirects(words):
    plain, tgt, app, inp, i = [], None, False, None, 0
    while i < len(words):
        w = words[i]
        if w in ('>', '>>', '>|'): tgt, app = words[i + 1], (w == '>>'); i += 2
        elif w == '<': inp = words[i + 1]; i += 2
        elif w in ('>&', '<&', '<<', '<<-', '<<<'): i += 2
        else: plain.append(w); i += 1
    return plain, tgt, app, inp

# ----------------------------------------------------------------------------------------------------- the effects
def get(key):
    if key is None or key not in files: raise Unsupported('unknown file ' + str(key))
    return files[key]

def sed_print(spec, text):
    m = re.fullmatch(r'(\d+)(?:,(\d+|\$))?p', spec.strip())
    if not m: raise Unsupported('sed spec ' + spec)
    lines = text.split('\n')
    if lines and lines[-1] == '': lines = lines[:-1]
    a = int(m.group(1)); b = len(lines) if m.group(2) == '$' else int(m.group(2) or a)
    return ''.join(l + '\n' for l in lines[a - 1:b])

def sed_delete(spec, text):
    lines = text.split('\n')
    if lines and lines[-1] == '': lines = lines[:-1]
    dele = set()
    for part in spec.split(';'):
        m = re.fullmatch(r'\s*(\d+)(?:,(\d+))?d\s*', part)
        if not m: raise Unsupported('sed delete ' + spec)
        a = int(m.group(1)); dele |= set(range(a, int(m.group(2) or a) + 1))
    return ''.join(l + '\n' for i, l in enumerate(lines, 1) if i not in dele)

def sed_substitute(script, text):
    m = re.fullmatch(r's(.)(.*?)(?<!\\)\1(.*?)(?<!\\)\1(g?)', script, re.S)
    if not m: raise Unsupported('sed script ' + script)
    pat, rep, g = m.group(2), m.group(3), m.group(4)
    if re.search(r'\\[(){}|+?1-9]|[\[\]*]|&', pat + rep.replace('\\n', '')): raise Unsupported('sed pattern')
    rx = re.compile(pat, re.M)           # only . ^ $ and literal characters: the same meaning in sed's basic syntax
    rep = rep.replace('\\n', '\n').replace('\\/', '/')
    return rx.sub(lambda _m: rep, text, count=0 if g else 1)

def write_out(tgt, text, app, ts, cwd, deps):
    key = resolve(tgt, cwd)
    if tgt == '/dev/null': return
    if key is None: raise Unsupported('relative target without cwd')
    if app:
        if key not in files: raise Unsupported('append to an unknown file')
        text = files[key] + text
    gap = next((f'copied from a gap: {d}' for d in deps if d in gaps), None)
    if app and key in gaps and not gap: gap = gaps[key]
    put(key, text, ts, gap)

MUTATING = re.compile(r'(\bsed\s+-\w*i|\bperl\b|\bruby\b|\bawk\b|\btee\b|\bpython3?\b|\bcp\b|\bmv\b|\bln\b|\bpatch\b|>>?\s*[^&\s]|\bxargs\b)')
def taint(head, hds, st, why):
    """The files a command we could not apply may have changed: its redirect targets, the files of sed -i / perl -i, the
    files a python script opens for writing, and the destinations of cp/mv. Files it only reads are not touched."""
    if not MUTATING.search(head): return
    cwd, env, cand = st['cwd'], st['env'], set()
    def add(tok):
        tok = tok.strip('"\'')
        try: key = resolve(expand(tok, env, cwd), cwd)
        except Unsupported:
            # an unknown variable: the file name's tail is still the file
            key = None
        if key: cand.add(key)
    for m in re.finditer(r'(?<![<>&\d])\d?>>?\s*("[^"]+"|\'[^\']+\'|[^\s;&|)]+)', head):
        if not m.group(1).startswith(('&', '/dev/null')): add(m.group(1))
    if re.search(r'\bsed\s+-\w*i|\bperl\b.*-\w*i', head):
        for m in re.finditer(r'[\w$"{}./~-]+\.(?:swift|sh|py)\b', head): add(m.group(0))
    if re.search(r'\b(cp|mv)\b', head):
        for m in re.finditer(r'\b(?:cp|mv)\b((?:\s+-\w+)*)\s+([^;&|\n]+)', head):
            toks = m.group(2).split()
            if toks: add(toks[-1])
    if re.search(r'\bpython3?\b', head):
        body = '\n'.join(b for _, _, b in hds)
        for m in re.finditer(r"\b(?:p|t|f|path|dst|out)\s*=\s*['\"]([\w./-]+)['\"]", body): add(m.group(1))
        for m in re.finditer(r"open\(\s*['\"]([\w./-]+)['\"]\s*,\s*['\"]w", body): add(m.group(1))
    for key in cand: mark_gap(key, why)

def statement(head, hds, ts, st):
    env, cwd = st['env'], st['cwd']
    m = re.fullmatch(r'\{(.*)\}\s*(>>?)\s*(\S+)', head.strip(), re.S)
    if m:                                                    # { sed -n 1,8p a; cat b; } > out
        pieces, deps = [], []
        for part in split_simple(m.group(1)):
            w, tgt, _, _ = split_redirects(words_of(part, env, cwd))
            if tgt: raise Unsupported('redirect inside a group')
            if w[0] == 'sed' and w[1] == '-n':
                key = resolve(w[3], cwd); pieces.append(sed_print(w[2], get(key))); deps.append(key)
            elif w[0] == 'cat':
                for f in w[1:]:
                    key = resolve(f, cwd); pieces.append(get(key)); deps.append(key)
            else: raise Unsupported('group command ' + w[0])
        write_out(expand(m.group(3).strip('"'), env, cwd), ''.join(pieces), m.group(2) == '>>', ts, cwd, deps)
        return
    if re.match(r'\s*(for|if|while|until|case)\b', head): raise Unsupported('compound command')
    words = words_of(head, env, cwd)
    j = 0
    while j < len(words) and re.fullmatch(r'[A-Za-z_]\w*=.*', words[j], re.S):
        k, _, v = words[j].partition('='); env[k] = v; j += 1
    words = words[j:]
    if not words: return
    if '|' in words or '||' in words:
        k = words.index('|') if '|' in words else words.index('||')
        if any(w in ('>', '>>') for w in words[k:]): raise Unsupported('pipeline into a file')
        words = words[:k]
    words = [w for w in words if w != '&']
    plain, tgt, app, inp = split_redirects(words)
    if not plain: return
    cmd, args = plain[0], plain[1:]
    if cmd == 'cd':
        if args and not args[0].startswith('-'):
            t = args[0]; st['cwd'] = os.path.normpath(t if t.startswith('/') else (cwd or '/') + '/' + t)
        return
    if cmd == 'cat':
        deps = []
        if hds and not args:
            tag, quoted, body = hds[0]
            if not quoted and re.search(r'[$`]', body): raise Unsupported('unquoted heredoc with expansions')
            text = body
        elif args or inp:
            text = ''
            for f in (args or [inp]):
                key = resolve(f, cwd); text += get(key); deps.append(key)
        else: raise Unsupported('cat without input')
        if tgt: write_out(tgt, text, app, ts, cwd, deps)
        return
    if cmd == 'echo':
        if tgt: write_out(tgt, ' '.join(a for a in args if not a.startswith('-')) + '\n', app, ts, cwd, [])
        return
    if cmd == 'touch':
        for f in args:
            key = resolve(f, cwd)
            if key and key not in files: put(key, '', ts)
        return
    if cmd in ('cp', 'mv'):
        paths = [a for a in args if not a.startswith('-')]
        if len(paths) < 2: raise Unsupported(cmd + ' arguments')
        srcs, dst = paths[:-1], paths[-1]
        dkey = resolve(dst, cwd)
        if dkey is None: raise Unsupported('relative path without cwd')
        has_children = any(k.startswith(dkey.rstrip('/') + '/') for k in files)
        into_dir = (len(srcs) > 1 or dst.endswith('/') or has_children) and dkey not in files
        for s in srcs:
            skey = resolve(s, cwd)
            if skey is None: raise Unsupported('relative path without cwd')
            items = [(skey, files[skey])] if skey in files else [(k, v) for k, v in files.items() if k.startswith(skey.rstrip('/') + '/')]
            if not items:
                if tracked(skey) or tracked(dkey): raise Unsupported(f'{cmd} of unknown {s}')
                continue
            for k, v in items:
                if k == skey: nk = dkey.rstrip('/') + '/' + os.path.basename(skey) if into_dir else dkey
                else:
                    rel = k[len(skey.rstrip('/')) + 1:]
                    nk = (dkey.rstrip('/') + '/' + os.path.basename(skey) + '/' + rel) if into_dir else dkey.rstrip('/') + '/' + rel
                put(nk, v, ts, f'copied from a gap: {k}' if k in gaps else None)
                if cmd == 'mv': files.pop(k, None); gaps.pop(k, None)
        return
    if cmd == 'rm':
        for a in args:
            if a.startswith('-'): continue
            key = resolve(a, cwd)
            if key is None: continue
            for k in [k for k in files if k == key or k.startswith(key.rstrip('/') + '/')]:
                files.pop(k); gaps.pop(k, None)
        return
    if cmd == 'sed':
        opts = [a for a in args if a.startswith('-') and a != '-']
        rest = [a for a in args if not a.startswith('-') or a == '-']
        if any(o.startswith('-i') for o in opts):
            rest = [a for a in rest if a != '']
            script, fs = rest[0], rest[1:]
            for f in fs:
                key = resolve(f, cwd); put(key, sed_substitute(script, get(key)), ts, gaps.get(key))
            return
        if opts == ['-n'] and len(rest) >= 2:
            if tgt: key = resolve(rest[1], cwd); write_out(tgt, sed_print(rest[0], get(key)), app, ts, cwd, [key])
            return
        if opts == ['-e'] and len(rest) >= 2:
            if tgt: key = resolve(rest[1], cwd); write_out(tgt, sed_delete(rest[0], get(key)), app, ts, cwd, [key])
            return
        if tgt: raise Unsupported('sed form')
        return
    if cmd == 'git':
        if args[:1] != ['merge-file']: return
        a = [x for x in args[1:] if not x.startswith('-')]
        if len(a) != 3 or '-p' not in args: raise Unsupported('merge-file form')
        keys = [resolve(x, cwd) for x in a]
        with tempfile.TemporaryDirectory() as td:
            ps = []
            for n, k in enumerate(keys):
                p = os.path.join(td, f'f{n}'); open(p, 'w', errors='surrogateescape').write(get(k)); ps.append(p)
            res = subprocess.run([GIT, 'merge-file', '-p'] + ps, capture_output=True, text=True, errors='surrogateescape',
                                 env={'PATH': '/usr/bin:/bin', 'HOME': td, 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'},
                                 stdin=subprocess.DEVNULL, timeout=30)
        if res.returncode < 0 or res.returncode > 127: raise Unsupported('merge-file failed')
        L('merge-file: conflicts', res.returncode, a)
        if tgt: write_out(tgt, res.stdout, app, ts, cwd, keys)
        return
    if cmd in ('python3', 'python'):
        python_literal(args, hds, ts, st); return
    if tgt or cmd in ('perl', 'ruby', 'awk', 'tee', 'ln', 'patch'): raise Unsupported('program ' + cmd)
    # a build, a run, a viewer, a read: no text file of the suites changes by it

# ------------------------------------------------------------------------------------------------ python, as data
def python_literal(args, hds, ts, st):
    if not hds: raise Unsupported('python without a heredoc')
    try: tree = ast.parse(hds[0][2])
    except SyntaxError: raise Unsupported('python syntax')
    cwd = st['cwd']
    argv = ['-'] + [a for a in args if a not in ('-', '-I', '-B')]
    names, texts, written, helper = {}, {}, {}, []
    def val(n):
        if isinstance(n, ast.Constant) and isinstance(n.value, (str, int)): return n.value
        if isinstance(n, ast.Name) and n.id in names: return names[n.id]
        if isinstance(n, ast.Name) and texts.get(n.id) is not None: return texts[n.id]
        if isinstance(n, ast.Subscript) and isinstance(n.value, ast.Attribute) and n.value.attr == 'argv' and isinstance(n.slice, ast.Constant):
            return argv[n.slice.value]
        if isinstance(n, ast.BinOp) and isinstance(n.op, ast.Add): return val(n.left) + val(n.right)
        raise Unsupported('python value')
    def text(n):
        """The text an expression stands for; None for a file we don't hold (a repository file): its edits are not ours."""
        if isinstance(n, ast.Name) and n.id in texts: return texts[n.id]
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == 'replace' and len(n.args) in (2, 3):
            base = text(n.func.value)
            if base is None: return None
            return base.replace(val(n.args[0]), val(n.args[1]), val(n.args[2]) if len(n.args) == 3 else -1)
        if isinstance(n, ast.BinOp) and isinstance(n.op, ast.Add):
            a = text(n.left) if isinstance(n.left, (ast.Name, ast.Call, ast.BinOp, ast.Subscript)) and not (isinstance(n.left, ast.Name) and n.left.id in names) else val(n.left)
            b = text(n.right) if isinstance(n.right, (ast.Call, ast.Subscript)) or (isinstance(n.right, ast.Name) and n.right.id in texts) else val(n.right)
            return None if a is None or b is None else a + b
        if ALLOW_SLICES and isinstance(n, ast.Subscript) and isinstance(n.slice, ast.Slice):
            base = text(n.value)
            lo = val(n.slice.lower) if n.slice.lower else None; hi = val(n.slice.upper) if n.slice.upper else None
            return None if base is None else base[lo:hi]
        raise Unsupported('python expression: ' + ast.unparse(n)[:90])
    def target(n):
        p = val(n); return resolve(p, cwd)
    def assign(t, v):
        if isinstance(v, ast.Call) and isinstance(v.func, ast.Attribute) and v.func.attr == 'read' and isinstance(v.func.value, ast.Call) \
                and getattr(v.func.value.func, 'id', '') == 'open':
            key = target(v.func.value.args[0])
            if key is None: raise Unsupported('relative path without cwd')
            if key.startswith('ABS:') and key not in files: texts[t] = None            # a repository file
            else: texts[t] = get(key)
        elif isinstance(v, ast.Constant): names[t] = v.value
        elif isinstance(v, ast.Call) and isinstance(v.func, ast.Attribute) and v.func.attr in ('index', 'find'):
            if not ALLOW_SLICES: raise Unsupported('python offset computed from the text')
            base = text(v.func.value); names[t] = None if base is None else getattr(base, v.func.attr)(val(v.args[0]))
        elif isinstance(v, ast.Call) and isinstance(v.func, ast.Attribute) and v.func.attr == 'replace':
            texts[t] = text(v)
        elif isinstance(v, ast.Name) and v.id in texts: texts[t] = texts[v.id]
        else:
            try: names[t] = val(v)
            except Unsupported: texts[t] = text(v)
    def run(stmts):
        for s in stmts:
            if isinstance(s, (ast.Import, ast.ImportFrom)):
                if any(m not in ('sys', 'os', 're') for m in ([a.name for a in s.names] if isinstance(s, ast.Import) else [s.module])):
                    raise Unsupported('python import')
            elif isinstance(s, ast.Assign) and len(s.targets) == 1 and isinstance(s.targets[0], ast.Name):
                assign(s.targets[0].id, s.value)
            elif isinstance(s, ast.AugAssign) and isinstance(s.op, ast.Add) and isinstance(s.target, ast.Name):
                base = texts.get(s.target.id, '')
                texts[s.target.id] = None if base is None else base + val(s.value)
            elif isinstance(s, ast.Assert):
                t = s.test
                if isinstance(t, ast.Compare) and len(t.ops) == 1 and isinstance(t.ops[0], ast.In) and isinstance(t.comparators[0], ast.Name):
                    base = texts.get(t.comparators[0].id, '')
                    if base is not None and val(t.left) not in base: raise Aborted('assert in')
                elif isinstance(t, ast.Compare) and isinstance(t.ops[0], ast.Eq) and isinstance(t.left, ast.Call) and getattr(t.left.func, 'attr', '') == 'count':
                    base = text(t.left.func.value)
                    if base is not None and base.count(val(t.left.args[0])) != val(t.comparators[0]): raise Aborted('assert count')
                else: raise Unsupported('python assert')
            elif isinstance(s, ast.Expr) and isinstance(s.value, ast.Call):
                c = s.value
                if isinstance(c.func, ast.Attribute) and c.func.attr == 'write' and isinstance(c.func.value, ast.Call) and getattr(c.func.value.func, 'id', '') == 'open':
                    a = c.func.value.args
                    if len(a) < 2 or val(a[1]) != 'w': raise Unsupported('python open mode')
                    key = target(a[0])
                    if key is None: raise Unsupported('relative path without cwd')
                    body = text(c.args[0])
                    if body is not None and not key.startswith('ABS:'): written[key] = body
                elif getattr(c.func, 'id', '') == 'print': pass
                elif getattr(c.func, 'id', '') == 'rep' and helper:
                    cur = texts.get(helper[0])
                    if cur is not None:
                        old, new = val(c.args[0]), val(c.args[1])
                        if cur.count(old) != 1: raise Aborted('rep count')
                        texts[helper[0]] = cur.replace(old, new)
                else: raise Unsupported('python call')
            elif isinstance(s, ast.FunctionDef) and s.name == 'rep' and len(s.args.args) == 2 and len(s.body) <= 4:
                src = ast.unparse(s)
                if not re.search(r'assert s\.count\(old\) == 1', src) or not re.search(r's = s\.replace\(old, new\)', src): raise Unsupported('python helper')
                helper.append('s')
            else: raise Unsupported('python statement ' + type(s).__name__)
    try: run(tree.body)
    except Aborted as e:
        L('python script stopped by its own assert:', ts[:19], e); return
    for key, body in written.items():
        put(key, body, ts, gaps.get(key))

# --------------------------------------------------------------------------------------------------------- replay
def strip_cat_n(text):
    out = []
    for l in text.split('\n'):
        m = re.match(r'^\s*(\d+)\t(.*)$', l)
        if m: out.append((int(m.group(1)), m.group(2)))
    return out

state, mism = {}, 0
for line in open(ops_file):
    r = json.loads(line)
    if r['ts'] >= until: break
    if not r['ts']: continue
    k = r['k']
    if k == 'Bash':
        st = state.setdefault(r['src'], {'cwd': None, 'env': {}}); st['env'] = {}
        for head, hds in split_statements(r['cmd']):
            try: statement(head, hds, r['ts'], st)
            except Unsupported as e:
                stats['bash-unsupported'] += 1
                taint(head, hds, st, f'{r["ts"][:19]} {r["src"][:14]} ln {r["ln"]}: {e}')
        continue
    if not r['path'].startswith('/'): continue
    key = resolve(r['path'], '/')
    if key.startswith('ABS:'): continue
    if k == 'Write':
        put(key, r['content'], r['ts']); stats['write'] += 1
    elif k == 'Edit':
        t = files.get(key)
        if t is None: mism += 1; L('EDIT-NOFILE', r['ts'][:19], r['src'][:14], r['ln'], key); continue
        n = t.count(r['old'])
        if n == 0: mism += 1; L('EDIT-MISMATCH', r['ts'][:19], r['src'][:14], r['ln'], key, repr(r['old'][:70])); continue
        if n > 1 and not r['all']: L('EDIT-AMBIGUOUS', r['ts'][:19], key); continue
        put(key, t.replace(r['old'], r['new']) if r['all'] else t.replace(r['old'], r['new'], 1), r['ts'], gaps.get(key)); stats['edit'] += 1
    elif k == 'Read':
        if key.endswith(('.png', '.jpg', '.pdf')): continue
        rows = strip_cat_n(r['text'])
        if not rows: continue
        whole = r['off'] is None and r['lim'] is None
        have = files.get(key)
        if have is None:
            if whole: put(key, '\n'.join(x[1] for x in rows) + '\n', r['ts']); L('READ-SNAPSHOT-NEW', key)
            continue
        hl = have.split('\n')
        bad = [(n, s) for n, s in rows if n - 1 >= len(hl) or hl[n - 1] != s]
        if bad:
            L('READ-DIFF', 'whole' if whole else f"part@{r['off']}", r['ts'][:19], key, f'{len(bad)}/{len(rows)} lines differ; first line {bad[0][0]}')
            stats['read-diff'] += 1
            if whole and len(rows) >= len(hl) - 2: put(key, '\n'.join(x[1] for x in rows) + '\n', r['ts'])
        else:
            stats['read-ok'] += 1
            if whole and key in gaps: gaps.pop(key); L('GAP closed by a whole-file Read:', key)

for key, vs in versions.items():
    for ts, text, h in vs:
        open(os.path.join(OUT, 'versions', key.replace('/', '__') + f'@{ts}@{h}'), 'w', errors='surrogateescape').write(text)
json.dump({k: v for k, v in gaps.items() if k in files}, open(os.path.join(OUT, 'gaps.json'), 'w'), indent=1)
summary = f'DONE {dict(stats)} edit-mismatches {mism} files {len(files)} gaps {len([k for k in gaps if k in files])}'
L(summary); print(summary)
