#!/usr/bin/env python3
# Makes hostile (and old-format) variants of a good export zip for the setup suite: usage mkhostile.py <good.zip> <outdir>
#
# The good zip is one cl_audit's own Export made from a made-up profile (Checks/setup/main.swift). Each variant is a copy with one
# thing changed in export.json, in the profile's backup.json or in the files under profiles/p1/setup/; the sizes in both manifests
# are made to add up again (unless the variant is about sizes), so the import has to refuse a variant for the one thing that is
# wrong with it. Nothing here touches anything but the two paths it is given.
import hashlib, json, os, sys, zipfile

base, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)
zin = zipfile.ZipFile(base)
infos = zin.infolist()
root = infos[0].filename.split('/')[0]
P = root + '/profiles/p1/'
FILE_MODE = 0o100644 << 16


def sha(b):
    return hashlib.sha256(b).hexdigest()


class Zip:
    """The good zip's members, in memory, to be changed."""
    def __init__(self):
        self.members = {}
        self.order = []
        self.attr = {}
        self.ctype = {}
        for i in infos:
            self.order.append(i.filename)
            self.attr[i.filename] = i.external_attr
            self.ctype[i.filename] = i.compress_type      # (a folder entry is stored, empty: a deflated one would "hold data")
            self.members[i.filename] = b'' if i.filename.endswith('/') else zin.read(i.filename)
        self.export = json.loads(self.members[root + '/export.json'])
        self.manifest = json.loads(self.members[P + 'backup.json'])

    def put(self, name, data, attr=FILE_MODE):
        if name not in self.members:
            self.order.append(name)
        self.members[name] = data
        self.attr[name] = attr

    def drop(self, name):
        self.members.pop(name, None)
        if name in self.order:
            self.order.remove(name)

    def item(self, rel):
        return next(i for i in self.manifest['items'] if i['path'] == 'setup/' + rel)

    def add_setup(self, rel, data=b'x', exec_=None, path=None, drop_sha=False, sha_of=None):
        """A setup file under profiles/p1/setup/<rel> and its item in backup.json."""
        path = path or 'setup/' + rel
        it = {'role': 'setup', 'original': path, 'path': path, 'bytes': len(data), 'sha': sha_of or sha(data)}
        if exec_ is not None:
            it['exec'] = exec_
        if drop_sha:
            del it['sha']
        self.manifest['items'].append(it)
        if '..' not in path.split('/') and not path.startswith('/') and '//' not in path:
            self.put(P + path, data)

    def settle_sizes(self):
        total = sum(i['bytes'] for i in self.manifest['items'])
        self.manifest['bytes'] = total
        self.export['parts'][0]['bytes'] = total
        self.export['bytes'] = total

    def write(self, name, sizes=True):
        if sizes:
            self.settle_sizes()
        self.members[root + '/export.json'] = json.dumps(self.export).encode()
        self.members[P + 'backup.json'] = json.dumps(self.manifest).encode()
        with zipfile.ZipFile(os.path.join(outdir, name + '.zip'), 'w', zipfile.ZIP_DEFLATED) as z:
            for n in self.order:
                zi = zipfile.ZipInfo(n)
                zi.compress_type = self.ctype.get(n, zipfile.ZIP_DEFLATED)
                zi.external_attr = self.attr.get(n, FILE_MODE)
                z.writestr(zi, self.members[n])


def make(name, fn, sizes=True):
    z = Zip()
    fn(z)
    z.write(name, sizes)


# ---- places and names an export doesn't carry (refused whole: "doesn't carry")
make('e2-plugin-cache', lambda z: z.add_setup('plugins/cache/x/y.txt'))
make('e2-projects', lambda z: z.add_setup('projects/a.md'))
make('e2-dotfile', lambda z: z.add_setup('skills/alpha/.hidden'))
make('e2-git', lambda z: z.add_setup('skills/alpha/.git/config'))
make('e2-in-skills-root', lambda z: z.add_setup('skills/x.md'))
make('e2-todos', lambda z: z.add_setup('todos/a.md'))
make('e2-too-deep', lambda z: z.add_setup('skills/alpha/' + '/'.join('d%d' % k for k in range(12)) + '/f.md'))


def v1_with_setup(z):
    z.manifest['version'] = 1
    z.export['version'] = 1
make('e2-v1-with-setup', v1_with_setup)

# ---- names that are never carried, anywhere in the setup (refused at the walk: "sign-in name")
make('e2-localjson', lambda z: z.add_setup('settings.local.json'))
make('e2-nested-settings', lambda z: z.add_setup('skills/alpha/settings.json'))
make('e2-claude-json', lambda z: z.add_setup('.claude.json'))
make('e2-credentials', lambda z: z.add_setup('skills/alpha/.credentials.json'))
make('e2-claude-json-nested', lambda z: z.add_setup('skills/alpha/.claude.json.bak'))

# ---- what only the encrypted image carries, in a zip
make('e2-zip-settings', lambda z: z.add_setup('settings.json', b'{}'))
make('e2-zip-marketplaces', lambda z: z.add_setup('plugins/known_marketplaces.json', b'{}'))
make('e2-zip-script', lambda z: z.add_setup('bin/x.sh', b'#!/bin/sh\n', exec_=True))

# ---- the execute flag only on a skill's own files and on scripts
def exec_on(rel):
    def f(z):
        z.item(rel)['exec'] = True
    return f
make('e2-exec-claude', exec_on('CLAUDE.md'))
make('e2-exec-agent', exec_on('agents/helper.md'))
make('e2-exec-include', exec_on('docs/style.md'))
make('e2-exec-command', exec_on('commands/ship.md'))
make('e2-exec-keybindings', exec_on('keybindings.json'))
make('e2-exec-plugins', exec_on('plugins/installed_plugins.json'))
make('e2-exec-skill-ok', exec_on('skills/alpha/refs/notes.md'))      # a skill's own file: allowed (opens)

# ---- hashes and sizes
def bad_sha(z):
    z.item('agents/helper.md')['sha'] = sha(b'something else')
make('e2-bad-sha', bad_sha)

def altered(z):                                                     # same size, other bytes
    n = P + 'setup/agents/helper.md'
    z.members[n] = bytes(b ^ 1 for b in z.members[n])
make('e2-altered', altered)

def no_sha(z):
    del z.item('agents/helper.md')['sha']
make('e2-no-sha', no_sha)

def short_sha(z):
    z.item('agents/helper.md')['sha'] = sha(b'x')[:63]
make('e2-short-sha', short_sha)

def upper_sha(z):
    z.item('agents/helper.md')['sha'] = z.item('agents/helper.md')['sha'].upper()
make('e2-upper-sha', upper_sha)

def wrong_size(z):                                                  # backup.json says a size the file doesn't have
    z.item('agents/helper.md')['bytes'] += 1
make('e2-wrong-size', wrong_size)

def wrong_total(z):                                                 # the manifests' totals don't add up
    z.manifest['bytes'] += 7
make('e2-wrong-total', wrong_total, sizes=False)

# ---- formats
def v6_export(z):                                                   # an export.json newer than this build's (5)
    z.export['version'] = 6
make('e2-v6-export', v6_export)

def v5_backup(z):                                                   # a backup.json newer than this build's (4)
    z.manifest['version'] = 5
make('e2-v5-backup', v5_backup)

def v2(z):                                                          # the format before (setup, no window settings): still read
    z.export['version'] = 2
    z.manifest['version'] = 2
make('e2-v2', v2)

def v1(z):                                                          # an export of the first format: no setup in it
    keep = []
    for it in z.manifest['items']:
        if it['role'] == 'setup':
            z.drop(P + it['path'])
        else:
            keep.append(it)
    z.manifest['items'] = keep
    for n in [n for n in z.order if n.startswith(P + 'setup')]:    # (and the folders it was in)
        z.drop(n)
    z.manifest.pop('setupLeftOut', None)
    z.manifest['version'] = 1
    z.export['version'] = 1
make('e2-v1', v1)

# ---- paths
make('e2-traversal', lambda z: z.add_setup('x.md', path='setup/skills/../../x.md'))
make('e2-traversal-deep', lambda z: z.add_setup('x.md', path='setup/../../../x.md'))
make('e2-empty-component', lambda z: z.add_setup('x.md', path='setup//x.md'))
make('e2-absolute', lambda z: z.add_setup('x.md', path='/setup/x.md'))
make('e2-backslash', lambda z: z.add_setup('x.md', path='setup\\..\\x.md'))
make('e2-not-setup-place', lambda z: z.add_setup('x.md', path='transcripts/x.md'))   # a setup item outside setup/
make('e2-setup-in-window', lambda z: z.add_setup('x.md', path='window/x.md'))
make('e2-setup-dup-item', lambda z: z.manifest['items'].append(dict(z.item('agents/helper.md'))))

def dup_case(z):                                                    # two names that are one on this Mac's disks
    z.add_setup('agents/HELPER.md', b'helper agent')
make('e2-dup-case', dup_case)

def file_and_folder(z):                                             # a file where a folder is expected
    z.add_setup('agents/helper.md/inner.md', b'x')
make('e2-file-and-folder', file_and_folder)

# ---- the same name under another case or Unicode form: opens, and the import must not treat it as a new place
def case_skills(z):                                                 # an "include" under Skills/ (this Mac's disks: the skills/ folder)
    z.add_setup('Skills/alpha/evil.md', b'evil include')
make('e2-case-skills', case_skills)

def case_plugins(z):
    z.add_setup('Plugins/cache/x.md', b'evil include')
make('e2-case-plugins', case_plugins)

def case_projects(z):
    z.add_setup('Projects/x.md', b'evil include')
make('e2-case-projects', case_projects)

def case_settings(z):                                               # a "script" named like settings.json, with no settings.json
    z.add_setup('Settings.json', b'{}', exec_=True)
make('e2-case-settings', case_settings)
make('e2-case-claude', lambda z: z.add_setup('claude.md', b'a second CLAUDE.md under another case'))
make('e2-case-keybindings', lambda z: z.add_setup('KEYBINDINGS.JSON', b'{}'))

# ---- an "include" is only what the file's own CLAUDE.md names (an .md left over in a folder of its own is not one)
make('e2-include-leftover', lambda z: z.add_setup('rules/evil.md', b'loaded into every session by a recent Claude Code'))
make('e2-include-top-leftover', lambda z: z.add_setup('evil.md', b'not named by CLAUDE.md'))

def unicode_skill(z):                                               # é as one character: the target holds it as e + a mark
    z.add_setup('skills/café/SKILL.md', b'cafe skill')
make('e2-unicode-skill', unicode_skill)

print('ok')
