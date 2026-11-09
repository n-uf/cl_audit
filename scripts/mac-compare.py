#!/usr/bin/env python3
"""mac-compare: a read-only manifest of one Mac, and a diff of two (for a move to another Mac).

  python3 -I -B scripts/mac-compare.py manifest [--home H] [--projects-root R] [--label NAME] [-o FILE]
  python3 -I -B scripts/mac-compare.py diff A.json B.json

manifest  prints (or writes to FILE) a JSON manifest of this Mac: names and counts only, never a file's contents, a token, an
          address or an account id in the clear. It covers
            projects   every git repo under the projects root (default /opt/projects) down to depth 4: HEAD, branch, how many
                       files `git status --porcelain` lists, how many commits are ahead of the upstream
            claudeCode every Claude Code folder in the home (~/.claude and each ~/.claude-*): per projects/<folder> the number
                       of transcripts, and the number of file-history, plans, tasks, scheduled-tasks, skills, agents and
                       commands entries, and whether CLAUDE.md, settings.json and keybindings.json exist
            claudeApp  every Claude app data folder (~/Library/Application Support/Claude and each Claude-*): its size, the
                       Code-tab entries and scheduled tasks per account folder
            clAudit    cl_audit's profiles (~/Library/Application Support/usage-n-uf/accounts.json): name, id, number of
                       accounts, and the number of backups per profile in the default backups place
          Ids (a Claude account folder, an organisation folder, an account's id) appear only as a fingerprint: the first 8
          hex digits of the SHA-256 of the id (UTF-8), in lower case. The same id gives the same fingerprint on every Mac.
          Nothing is ever written except the -o file. Git is only asked rev-parse, status --porcelain and rev-list --count,
          with GIT_OPTIONAL_LOCKS=0 and the file-system monitor off; nothing is fetched. Links are never followed.
diff      prints what differs between two manifests, grouped and readable: only on one side, or different values. Exit 0
          when they are equal, 1 when not (2: a file that is no manifest). Sizes and times are shown as information only.

Python 3 standard library only; works with macOS's /usr/bin/python3 (3.9).
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time

FORMAT = 1
MAX_DEPTH = 4
SKIP_DIRS = {'.git', 'node_modules', '.next', '.venv', '__pycache__', 'Pods', 'DerivedData', '.build', '.cache',
             '.gradle', '.Trash'}
JSON_LIMIT = 8 * 1024 * 1024
GIT_TIMEOUT = 120


def fp(value):
    """The short keyed fingerprint of an id: the first 8 hex digits of its SHA-256."""
    return hashlib.sha256(str(value).encode('utf-8', 'replace')).hexdigest()[:8]


def lst(path):
    try:
        return os.lstat(path)
    except OSError:
        return None


def is_dir(path):
    st = lst(path)
    return bool(st) and (st.st_mode & 0o170000) == 0o040000


def is_file(path):
    st = lst(path)
    return bool(st) and (st.st_mode & 0o170000) == 0o100000


def is_link(path):
    st = lst(path)
    return bool(st) and (st.st_mode & 0o170000) == 0o120000


def names(path):
    """The entries of a folder, sorted; None when it can't be read."""
    try:
        return sorted(os.listdir(path))
    except OSError:
        return None


def count_entries(path, kind):
    """How many real (not linked) entries of a kind ('dir', 'file' or 'any') a folder holds directly.
    A string ('missing', 'unreadable', 'link') when it can't be counted."""
    st = lst(path)
    if st is None:
        return 'missing'
    if is_link(path):
        return 'link'
    if not is_dir(path):
        return 'unreadable'
    n = names(path)
    if n is None:
        return 'unreadable'
    total = 0
    for name in n:
        if name == '.DS_Store':
            continue
        p = os.path.join(path, name)
        if kind == 'dir' and not is_dir(p):
            continue
        if kind == 'file' and not is_file(p):
            continue
        total += 1
    return total


def read_json(path):
    """Parse a JSON file (never followed through a link, never over 8 MB): (value, None) or (None, reason)."""
    st = lst(path)
    if st is None:
        return None, 'missing'
    if not is_file(path):
        return None, 'unreadable'
    if st.st_size > JSON_LIMIT:
        return None, 'too big'
    try:
        with open(path, 'rb') as f:
            return json.loads(f.read().decode('utf-8', 'replace')), None
    except (OSError, ValueError):
        return None, 'unreadable'


# ---------------------------------------------------------------------------------------------------- projects (git repos)

def git(repo, *args):
    """Run one read-only git command in a repo: (stdout, None) or (None, reason)."""
    env = dict(os.environ)
    env['GIT_OPTIONAL_LOCKS'] = '0'
    env['GIT_TERMINAL_PROMPT'] = '0'
    env['LC_ALL'] = 'C'
    cmd = ['git', '-c', 'core.fsmonitor=false', '-C', repo] + list(args)
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, env=env,
                           timeout=GIT_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, 'timeout'
    except OSError:
        return None, 'git not found'
    if p.returncode != 0:
        return None, 'failed'
    return p.stdout.decode('utf-8', 'replace'), None


def repo_facts(repo):
    out = {}
    head, err = git(repo, 'rev-parse', '--short=8', 'HEAD')
    out['head'] = head.strip() if head else 'no commits'
    branch, err = git(repo, 'rev-parse', '--abbrev-ref', 'HEAD')
    b = branch.strip() if branch else ''
    out['branch'] = 'detached' if b == 'HEAD' else (b or 'none yet')
    status, err = git(repo, 'status', '--porcelain', '--untracked-files=normal')
    out['dirty'] = len([l for l in status.splitlines() if l.strip()]) if status is not None else 'unreadable'
    up, err = git(repo, 'rev-parse', '--abbrev-ref', '@{upstream}')
    if up and up.strip():
        n, err = git(repo, 'rev-list', '--count', '@{upstream}..HEAD')
        try:
            out['ahead'] = int(n.strip())
        except (AttributeError, ValueError):
            out['ahead'] = 'unreadable'
        out['upstream'] = 'yes'
    else:
        out['ahead'] = 0
        out['upstream'] = 'no upstream'
    return out


def find_repos(root):
    """Repos (a .git folder or file) under root, down to MAX_DEPTH, by path relative to root. Links are not followed."""
    found, unreadable = [], 0
    stack = [(root, 0)]
    while stack:
        d, depth = stack.pop()
        if lst(os.path.join(d, '.git')) is not None:
            found.append(os.path.relpath(d, root))
        if depth >= MAX_DEPTH:
            continue
        n = names(d)
        if n is None:
            unreadable += 1
            continue
        for name in n:
            if name in SKIP_DIRS:
                continue
            p = os.path.join(d, name)
            if is_dir(p):
                stack.append((p, depth + 1))
    return sorted(found), unreadable


def projects(root):
    if lst(root) is None:
        return {'status': 'missing'}
    if not is_dir(root):
        return {'status': 'unreadable'}
    found, unreadable = find_repos(root)
    repos = {}
    for rel in found:
        repos[rel] = repo_facts(os.path.join(root, rel) if rel != '.' else root)
    out = {'status': 'ok', 'depth': MAX_DEPTH, 'repos': repos}
    if unreadable:
        out['unreadableFolders'] = unreadable
    return out


# ---------------------------------------------------------------------------------------------------- Claude Code folders

def claude_code_folder(path):
    if is_link(path):
        return {'status': 'link, not followed'}
    if not is_dir(path):
        return {'status': 'missing'}
    if names(path) is None:
        return {'status': 'unreadable'}
    out = {'status': 'ok'}
    proj_dir = os.path.join(path, 'projects')
    proj = {}
    state = count_entries(proj_dir, 'dir')
    if isinstance(state, int):
        for name in names(proj_dir) or []:
            p = os.path.join(proj_dir, name)
            if is_dir(p):
                inner = names(p)
                if inner is None:
                    proj[name] = 'unreadable'
                else:
                    proj[name] = len([n for n in inner if n.endswith('.jsonl') and is_file(os.path.join(p, n))])
        out['projects'] = proj
        out['transcripts'] = sum(v for v in proj.values() if isinstance(v, int))
    else:
        out['projects'] = state
    out['fileHistory'] = count_entries(os.path.join(path, 'file-history'), 'dir')
    out['plans'] = count_entries(os.path.join(path, 'plans'), 'file')
    out['tasks'] = count_entries(os.path.join(path, 'tasks'), 'dir')
    out['scheduledTasks'] = count_entries(os.path.join(path, 'scheduled-tasks'), 'dir')
    out['skills'] = count_entries(os.path.join(path, 'skills'), 'any')
    out['agents'] = count_entries(os.path.join(path, 'agents'), 'any')
    out['commands'] = count_entries(os.path.join(path, 'commands'), 'any')
    out['has'] = {n: lst(os.path.join(path, n)) is not None for n in ('CLAUDE.md', 'settings.json', 'keybindings.json')}
    return out


def claude_code(home):
    found = {}
    for name in names(home) or []:
        if name == '.claude' or name.startswith('.claude-'):
            p = os.path.join(home, name)
            if is_dir(p) or is_link(p):
                found[name] = claude_code_folder(p)
    return found


# ---------------------------------------------------------------------------------------------------- Claude app folders

def disk_usage(path):
    """The disk space under path, like `du -sk` (blocks used, a hard link once, links not followed): (bytes, complete)."""
    total, complete, seen = 0, True, set()
    stack = [path]
    while stack:
        d = stack.pop()
        st = lst(d)
        if st is None:
            complete = False
            continue
        if st.st_nlink > 1 and not is_dir(d):
            key = (st.st_dev, st.st_ino)
            if key in seen:
                continue
            seen.add(key)
        total += st.st_blocks * 512
        if is_dir(d):
            try:
                with os.scandir(d) as it:
                    stack.extend(os.path.join(d, e.name) for e in it)
            except OSError:
                complete = False
    return total, complete


def claude_app_folder(path):
    if is_link(path):
        return {'status': 'link, not followed'}
    if not is_dir(path):
        return {'status': 'missing'}
    if names(path) is None:
        return {'status': 'unreadable'}
    out = {'status': 'ok'}
    size, complete = disk_usage(path)
    out['sizeBytes'] = size
    if not complete:
        out['sizeNote'] = 'partial: some items could not be read'
    root = os.path.join(path, 'claude-code-sessions')
    accounts, entries, tasks, notes = {}, 0, 0, []
    state = count_entries(root, 'dir')
    if isinstance(state, int):
        for account in names(root) or []:
            adir = os.path.join(root, account)
            if not is_dir(adir):
                continue
            orgs = names(adir)
            row = {'entries': 0, 'scheduledTasks': 0, 'orgs': {}}
            if orgs is None:
                accounts[fp(account)] = 'unreadable'
                continue
            for org in orgs:
                odir = os.path.join(adir, org)
                if not is_dir(odir):
                    continue
                inner = names(odir)
                if inner is None:
                    row['orgs'][fp(org)] = 'unreadable'
                    continue
                n = len([f for f in inner if f.startswith('local_') and f.endswith('.json') and is_file(os.path.join(odir, f))])
                t = 0
                if 'scheduled-tasks.json' in inner:
                    j, why = read_json(os.path.join(odir, 'scheduled-tasks.json'))
                    if isinstance(j, dict) and isinstance(j.get('scheduledTasks'), list):
                        t = len(j['scheduledTasks'])
                    elif why:
                        notes.append('scheduled-tasks.json ' + why)
                row['orgs'][fp(org)] = n
                row['entries'] += n
                row['scheduledTasks'] += t
            accounts[fp(account)] = row
            entries += row['entries']
            tasks += row['scheduledTasks']
    elif state != 'missing':
        out['codeTabStatus'] = state
    out['accounts'] = accounts
    out['codeTabEntries'] = entries
    out['scheduledTasks'] = tasks
    if notes:
        out['notes'] = sorted(set(notes))
    return out


def claude_app(support):
    found = {}
    for name in names(support) or []:
        if name == 'Claude' or name.startswith('Claude-'):
            p = os.path.join(support, name)
            if is_dir(p) or is_link(p):
                found[name] = claude_app_folder(p)
    return found


# ---------------------------------------------------------------------------------------------------- cl_audit

def seat_ids(seat):
    if not isinstance(seat, dict) or not isinstance(seat.get('account'), str) or not seat['account']:
        return None
    org = seat.get('organization')
    return fp(seat['account']) + '/' + (fp(org) if isinstance(org, str) and org else 'none')


def cl_audit(support):
    folder = os.path.join(support, 'usage-n-uf')
    if lst(folder) is None:
        return {'status': 'missing'}
    data, why = read_json(os.path.join(folder, 'accounts.json'))
    if why:
        return {'status': 'accounts.json ' + why}
    entries = data.get('accounts') if isinstance(data, dict) else None
    if not isinstance(entries, list):
        return {'status': 'accounts.json unreadable'}
    backups_dir = os.path.join(folder, 'backups')
    profiles, used = {}, {}
    for e in entries:
        if not isinstance(e, dict) or not isinstance(e.get('id'), str):
            continue
        pid = e['id']
        used[pid] = used.get(pid, 0) + 1
        key = pid if used[pid] == 1 else '%s#%d' % (pid, used[pid])
        seats = []
        main = seat_ids(e.get('seat'))
        seats.append(main if main else 'unlinked')
        standby = e.get('standby')
        for s in standby if isinstance(standby, list) else []:
            if isinstance(s, dict):
                seats.append(seat_ids(s.get('seat')) or 'unlinked')
        row = {'name': e['name'] if isinstance(e.get('name'), str) else pid,
               'accounts': len(seats),
               'accountIds': sorted(seats)}
        b = count_entries(os.path.join(backups_dir, pid), 'dir')
        row['backups'] = b if b != 'missing' else 0
        profiles[key] = row
    out = {'status': 'ok', 'profiles': profiles}
    other = count_entries(backups_dir, 'dir')
    if isinstance(other, int):
        stray = {}
        for name in names(backups_dir) or []:
            if name not in profiles and is_dir(os.path.join(backups_dir, name)):
                stray[name] = count_entries(os.path.join(backups_dir, name), 'dir')
        if stray:
            out['backupsOfOtherFolders'] = stray
    return out


# ---------------------------------------------------------------------------------------------------- manifest

def manifest(home, root, label):
    support = os.path.join(home, 'Library', 'Application Support')
    return {
        'tool': 'mac-compare',
        'format': FORMAT,
        'fingerprint': 'first 8 hex digits of the SHA-256 of the id (UTF-8), lower case',
        'label': label,
        'generated': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'projects': projects(root),
        'claudeCode': claude_code(home),
        'claudeApp': claude_app(support),
        'clAudit': cl_audit(support),
    }


def cmd_manifest(args):
    home = os.path.expanduser('~')
    root = '/opt/projects'
    label = ''
    out = None
    it = iter(args)
    for a in it:
        try:
            if a == '--home':
                home = next(it)
            elif a == '--projects-root':
                root = next(it)
            elif a == '--label':
                label = next(it)
            elif a == '-o':
                out = next(it)
            else:
                return usage('unknown argument: ' + a)
        except StopIteration:
            return usage(a + ' needs a value')
    text = json.dumps(manifest(os.path.abspath(home), os.path.abspath(root), label), indent=2, sort_keys=True) + '\n'
    if out:
        try:
            fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, 'O_NOFOLLOW', 0), 0o600)
            with os.fdopen(fd, 'w') as f:
                f.write(text)
        except OSError as e:
            sys.stderr.write('mac-compare: cannot write %s (%s)\n' % (out, e.strerror))
            return 2
    else:
        sys.stdout.write(text)
    return 0


# ---------------------------------------------------------------------------------------------------- diff

INFO_KEYS = {'sizeBytes', 'sizeNote'}
SKIP_TOP = {'generated', 'label', 'fingerprint'}


def short(v):
    if isinstance(v, (dict, list)):
        return json.dumps(v, sort_keys=True)
    return json.dumps(v) if isinstance(v, str) and v.strip() != v else str(v)


def compare(a, b, path, rows, info):
    """Collect differences of two values: rows of (path, kind, a, b); size-like leaves go to info."""
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if not path and k in SKIP_TOP:
                continue
            p = path + [k]
            if k not in b:
                rows.append((p, 'only A', a[k], None))
            elif k not in a:
                rows.append((p, 'only B', None, b[k]))
            else:
                compare(a[k], b[k], p, rows, info)
    elif isinstance(a, list) and isinstance(b, list) and all(isinstance(x, str) for x in a + b):
        for x in sorted(set(a) - set(b)):
            rows.append((path, 'only A', x, None))
        for x in sorted(set(b) - set(a)):
            rows.append((path, 'only B', None, x))
        if sorted(a) != sorted(b) and set(a) == set(b):
            rows.append((path, 'different', a, b))
    elif a != b:
        (info if path and path[-1] in INFO_KEYS else rows).append((path, 'different', a, b))


def group_of(path):
    return ' > '.join(path[:2]) if len(path) > 2 else (path[0] if path else '')


def fmt_path(path, depth):
    return ' > '.join(path[depth:]) if len(path) > depth else '(whole)'


def cmd_diff(args):
    if len(args) != 2:
        return usage('diff needs two manifest files')
    ms = []
    for p in args:
        j, why = read_json(p)
        if not isinstance(j, dict) or j.get('tool') != 'mac-compare':
            sys.stderr.write('mac-compare: %s is not a mac-compare manifest (%s)\n' % (p, why or 'wrong content'))
            return 2
        ms.append(j)
    a, b = ms
    if a.get('format') != b.get('format'):
        sys.stderr.write('mac-compare: the manifests are in different formats (%s and %s)\n' % (a.get('format'), b.get('format')))
        return 2
    rows, info = [], []
    compare(a, b, [], rows, info)
    la, lb = a.get('label') or 'A', b.get('label') or 'B'
    print('A = %s (%s)   B = %s (%s)' % (la, a.get('generated', '?'), lb, b.get('generated', '?')))
    if not rows:
        print('Equal: nothing differs (apart from sizes, shown below).' if info else 'Equal: nothing differs.')
    groups = {}
    for r in rows:
        groups.setdefault(group_of(r[0]), []).append(r)
    for g in sorted(groups):
        print('')
        print('== ' + g)
        depth = 2 if g.count(' > ') else 1
        for path, kind, va, vb in sorted(groups[g], key=lambda r: (r[0], r[1])):
            where = fmt_path(path, depth)
            if kind == 'only A':
                print('  only on A: %s%s' % (where, '' if isinstance(va, dict) else '  (' + short(va) + ')'))
            elif kind == 'only B':
                print('  only on B: %s%s' % (where, '' if isinstance(vb, dict) else '  (' + short(vb) + ')'))
            else:
                print('  different: %s   A %s | B %s' % (where, short(va), short(vb)))
    if info:
        print('')
        print('== information only (sizes differ between Macs; not a difference)')
        for path, kind, va, vb in info:
            print('  %s   A %s | B %s' % (' > '.join(path), short(va), short(vb)))
    if rows:
        print('')
        print('%d difference%s.' % (len(rows), '' if len(rows) == 1 else 's'))
    return 1 if rows else 0


def usage(msg=None):
    if msg:
        sys.stderr.write('mac-compare: %s\n' % msg)
    sys.stderr.write('usage: mac-compare.py manifest [--home H] [--projects-root R] [--label NAME] [-o FILE]\n'
                     '       mac-compare.py diff A.json B.json\n')
    return 2


def main(argv):
    if len(argv) < 2 or argv[1] in ('-h', '--help'):
        if len(argv) >= 2:
            print(__doc__)
            return 0
        return usage()
    if argv[1] == 'manifest':
        return cmd_manifest(argv[2:])
    if argv[1] == 'diff':
        return cmd_diff(argv[2:])
    return usage('unknown command: ' + argv[1])


if __name__ == '__main__':
    sys.exit(main(sys.argv))
