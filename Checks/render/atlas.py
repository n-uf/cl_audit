#!/usr/bin/env python3
"""The switch atlas: every state of a switch from the account in use to a standby one, on every surface, in one page.

  python3 -I -B atlas.py PICTURES OUT.html [--findings FINDINGS.json]

PICTURES: the render harness's pictures made with ATLAS_SWITCH=1 (Checks/.work/render/pages/out, files
atlas-<row>-<column>-std.png). OUT.html: one self-contained page (inline CSS, the pictures downscaled and embedded as WebP,
or JPEG without WebP), under ~15 MB. On top a table of what each state should show and the rule it comes from, then the
rows x surfaces grid ("—" where a surface has nothing to show), then the findings (a JSON list of {"cell", "shows",
"table"}, written by whoever looked at the pictures).

Every embedded picture is run through the leak scan's own text check (Checks/tools/leakscan.py) as base64, and encoded
again at another quality until it is clean, so the page passes the scan as a whole. Needs Pillow.
"""
import base64, html, importlib.util, io, json, os, sys

try:
    from PIL import Image, features
except ImportError:
    sys.exit('atlas: needs Pillow (python3 -m pip install --user Pillow)')

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('leakscan', os.path.join(HERE, '..', 'tools', 'leakscan.py'))
leakscan = importlib.util.module_from_spec(spec); spec.loader.exec_module(leakscan)
leakscan.NAMES = leakscan.load_words(os.path.join(HERE, '..'))

COLUMNS = [('menubar', 'Menu bar menu'), ('dock', 'Dock icon, menu and panel'), ('card', 'Dashboard card'),
           ('settings', 'Settings ▸ the profile (Accounts, Sessions)'), ('switch', 'Switch page'), ('alert', 'Alert')]

# each state: its row id, its name, what every surface should show (account in use, whose numbers, which keys), the rules
ROWS = [
    ('01', 'Before', 'ann in use (the Claude app and Claude Code on ann); ann\'s numbers (week 40%); ben on standby, '
           '"last in use 3 days ago", no numbers. Keys: Switch account › ben…; no Log in…', 'A, B2'),
    ('02', 'ann\'s week full', 'ann in use, ann\'s week full with when it\'s back; ben offered first everywhere: "Switch to '
           'ben…" in both menus, ben picked in the card\'s tray, the alert\'s Switch account… button; the Switch page with ben '
           'picked', 'A, B'),
    ('03', 'Switch page open', 'NOW ann, TO ben; the steps: close the window, back up and move 6 Code-tab sessions and 2 '
           'tasks, Claude Code\'s sign-in. Every other surface as in 01', 'B, §8'),
    ('04a', 'Switching: the window closing', 'step 1 under way, Cancel offered; nothing moved yet, so every other surface still '
           'has ann in use with ann\'s numbers', 'B'),
    ('04b', 'Switching: moving', 'step 2 (backup, then the sessions and tasks); no Cancel (the move ends by itself); other '
           'surfaces still ann', 'B, §8'),
    ('04c', 'Switching: the sign-in waited for', 'sessions and tasks under ben now (Undo possible); Claude Code still on ann, '
           'so every surface still has ann in use; the waiting alert (Show switch, Cancel switch), never an address',
           'B, §8'),
    ('05', 'Done, the Claude app still on ann', 'Claude Code on ben, the app on ann: ann is in use (the app\'s account, A); '
           'the numbers are Claude Code\'s on ben and say so; the page: "Claude Code on ben · the Claude app still on ann"; '
           'the switch is linked (no Undo); ben not shown on standby and in use at once', 'A, B, B2'),
    ('06', 'Done, the app on ben', 'ben in use everywhere with ben\'s numbers; ann on standby ("last in use just now", her '
           'last week remembered); Switch account › ann…; nothing on standby twice', 'A, B2'),
    ('07', 'The sign-in landed on another account', 'Claude Code on dan (no profile\'s): the profile follows its folder, ann '
           'goes to standby, ben stays on standby; the app still on ann, so ann is in use by A\'s rule and the numbers say '
           'they are Claude Code\'s on dan; the page says another account signed in, and offers Undo while the move is open',
           'A, B, B2'),
    ('08', 'Timed out', 'no sign-in in 10 minutes: Claude Code still on ann, so ann in use with ann\'s numbers; the sessions '
           'already under ben (Undo and Try again offered)', 'B, B4'),
    ('09', 'Stopped part way', 'the window opened during the move: 2 sessions under ben, the rest under ann; the move step '
           'failed, the tile says how many are still moved and that Undo puts them back; Undo on the page and the Sessions '
           'card; ann in use', 'B4, §8'),
    ('10', 'Partly undone', 'Undo left 1 session that changed since, the rest is back; the page says partly undone and what '
           'was left; the Sessions card offers Undo again and Leave it as it is; ann in use', 'B4, §8'),
    ('11', 'The folder gone', 'Main\'s Claude Code folder deleted: the switch refused before anything (not started, nothing '
           'changed), said in one line naming the folder; no sign-in started', 'A, B4'),
    ('12', 'Cancelled before starting', 'Cancel while the window was closing: nothing moved; everything as in 01 (ann in use, '
           'ben on standby)', 'B'),
]

RULES = [('A', 'one record every surface reads (AccountResolver); the account in use is the Claude app\'s'),
         ('A3', 'no numbers when expired or signed out; Log in… the one key'),
         ('B', 'the switch moves the window\'s Code-tab sessions and tasks; the app is signed in by the person'),
         ('B2', 'one standby entry per account; the account in use never on standby too'),
         ('B4', 'the step that failed, and what is still moved'),
         ('§8', 'the claude-transplant model: backup first, receipts, Undo until linked')]


def encode(path, max_w):
    """The picture downscaled to max_w and encoded, clean of every leak-scan pattern as base64: (mime, base64, w, h)."""
    im = Image.open(path).convert('RGB')
    if im.width > max_w:
        im = im.resize((max_w, round(im.height * max_w / im.width)), Image.LANCZOS)
    fmt, mime = ('WEBP', 'image/webp') if features.check('webp') else ('JPEG', 'image/jpeg')
    for q in (72, 71, 73, 70, 74, 69, 75, 68, 76, 67):
        buf = io.BytesIO(); im.save(buf, fmt, quality=q, method=6) if fmt == 'WEBP' else im.save(buf, fmt, quality=q, optimize=True)
        b = base64.b64encode(buf.getvalue()).decode()
        if not leakscan.scan_text(b): return mime, b, im.width, im.height
    sys.exit(f'atlas: {os.path.basename(path)} keeps matching the leak scan as base64; not embedded')


CSS = """
:root { --bg:#f4f3ef; --ink:#1d1d1b; --mute:#6b6a65; --line:#d9d7cf; --cell:#1a1a1a; --hl:#fff6d6; --bad:#b4233a; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink); font:14px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
main { padding:24px 16px 64px; max-width:100%; }
h1 { font-size:22px; margin:0 0 4px; } h2 { font-size:17px; margin:32px 0 8px; }
p.lead { color:var(--mute); margin:0 0 16px; max-width:900px; }
table.states { border-collapse:collapse; width:100%; max-width:1400px; background:#fff; }
table.states th, table.states td { border:1px solid var(--line); padding:6px 8px; text-align:left; vertical-align:top; }
table.states th { background:#ecebe5; font-weight:600; }
table.states td.id { font-variant-numeric:tabular-nums; white-space:nowrap; font-weight:600; }
ul.rules { margin:8px 0 0; padding-left:18px; color:var(--mute); }
.grid-wrap { overflow-x:auto; border:1px solid var(--line); background:#fff; }
table.grid { border-collapse:collapse; }
table.grid th, table.grid td { border:1px solid var(--line); padding:6px; vertical-align:top; }
table.grid thead th { position:sticky; top:0; background:#ecebe5; z-index:1; font-weight:600; text-align:left; }
table.grid th.row { position:sticky; left:0; background:#ecebe5; z-index:1; min-width:150px; max-width:170px; text-align:left; font-weight:600; }
table.grid th.row small { display:block; font-weight:400; color:var(--mute); margin-top:4px; }
td.cell { width:330px; min-width:330px; } td.cell.wide { width:460px; min-width:460px; }
td.cell img { display:block; width:100%; height:auto; background:var(--cell); cursor:zoom-in; border-radius:4px; }
td.none { color:var(--mute); text-align:center; vertical-align:middle; font-size:20px; }
td.flag { box-shadow: inset 0 0 0 3px var(--bad); }
.tag { display:inline-block; margin-top:4px; font-size:11px; color:#fff; background:var(--bad); border-radius:3px; padding:0 5px; }
ol.findings { max-width:1200px; padding-left:22px; } ol.findings li { margin:0 0 10px; }
ol.findings b { font-variant-numeric:tabular-nums; }
.zoom { display:none; position:fixed; inset:0; background:rgba(0,0,0,.82); overflow:auto; z-index:9; cursor:zoom-out; padding:24px 16px; }
.zoom.on { display:block; } .zoom img { display:block; margin:0 auto; max-width:100%; height:auto; }
"""

JS = """
const z = document.querySelector('.zoom'), zi = z.querySelector('img');
document.querySelectorAll('td.cell img').forEach(i => i.addEventListener('click', () => { zi.src = i.src; z.classList.add('on'); }));
z.addEventListener('click', () => { z.classList.remove('on'); zi.removeAttribute('src'); });
document.addEventListener('keydown', e => { if (e.key === 'Escape') z.click(); });
"""


def main(argv):
    if len(argv) < 2: sys.exit(__doc__)
    pics, out = argv[0], argv[1]
    findings = []
    if '--findings' in argv:
        with open(argv[argv.index('--findings') + 1]) as f: findings = json.load(f)
    flagged = {}
    for n, f in enumerate(findings, 1): flagged.setdefault(f['cell'], []).append(n)
    e = html.escape
    parts = ['<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">',
             '<title>Switch atlas</title><style>', CSS, '</style></head><body><main>',
             '<h1>Switch atlas: from the account in use to a standby one</h1>',
             '<p class="lead">Every state of a switch on every surface, drawn by cl_audit\'s own views through the render harness '
             '(Checks/render/pages/main.swift, ATLAS_SWITCH=1), each state set up through the app\'s own paths. Std look. Sample '
             'data: profile Main with ann@example.com in use and ben@example.com on standby; profile Work on cat@example.com; '
             'dan@example.com is no profile\'s. Menus are the app\'s own menu items drawn as their words. Click a picture to '
             'see it larger.</p>',
             '<h2>What each state should show</h2><table class="states"><thead><tr><th>State</th><th>What every surface should '
             'show</th><th>Rule</th></tr></thead><tbody>']
    for rid, name, should, rule in ROWS:
        parts.append(f'<tr><td class="id">{e(rid)}</td><td><b>{e(name)}</b>: {e(should)}</td><td>{e(rule)}</td></tr>')
    parts.append('</tbody></table><ul class="rules">' + ''.join(f'<li><b>{e(k)}</b>: {e(v)}</li>' for k, v in RULES) + '</ul>')
    parts.append('<h2>The grid</h2><div class="grid-wrap"><table class="grid"><thead><tr><th class="row">State</th>'
                 + ''.join(f'<th>{e(t)}</th>' for _, t in COLUMNS) + '</tr></thead><tbody>')
    filled = empty = 0
    for rid, name, _, _ in ROWS:
        parts.append(f'<tr><th class="row">{e(rid)} {e(name)}</th>')
        for cid, _ in COLUMNS:
            p = os.path.join(pics, f'atlas-{rid}-{cid}-std.png')
            wide = ' wide' if cid == 'switch' else ''
            key = f'{rid}/{cid}'
            flag = flagged.get(key, [])
            cls = 'cell' + wide + (' flag' if flag else '')
            tag = ''.join(f'<span class="tag">finding {n}</span> ' for n in flag)
            if os.path.exists(p):
                mime, b, w, h = encode(p, 920 if cid == 'switch' else 660)
                parts.append(f'<td class="{cls}"><img alt="{e(rid)} {e(cid)}" width="{w}" height="{h}" loading="lazy" '
                             f'src="data:{mime};base64,{b}">{tag}</td>')
                filled += 1
            else:
                parts.append(f'<td class="none{" flag" if flag else ""}">—{tag}</td>')
                empty += 1
        parts.append('</tr>')
    parts.append('</tbody></table></div>')
    parts.append(f'<h2>Findings: {len(findings)}</h2>')
    if findings:
        parts.append('<ol class="findings">' + ''.join(
            f'<li><b>{e(f["cell"])}</b>: shows {e(f["shows"])} The table says {e(f["table"])}</li>' for f in findings) + '</ol>')
    parts.append(f'<p class="lead">{filled} cells drawn, {empty} with nothing to show (—).</p>')
    parts.append('</main><div class="zoom"><img alt=""></div><script>' + JS + '</script></body></html>')
    page = ''.join(parts)
    hits = leakscan.scan_text(page)
    if hits: sys.exit(f'atlas: the page itself has {len(hits)} leak-scan hits (lines {sorted({h[0] for h in hits})[:10]}); not written')
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, 'w') as f: f.write(page)
    print(f'atlas: {out} ({os.path.getsize(out) / 1e6:.1f} MB), {filled} cells drawn, {empty} "—", {len(findings)} findings')


if __name__ == '__main__':
    main(sys.argv[1:])
