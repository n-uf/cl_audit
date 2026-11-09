"""Extract the file-affecting tool calls (Write, Edit, Read, Bash) of Claude Code transcripts into one time-ordered ops.jsonl.

  python3 -I extract.py PROJECT_DIR OUT SESSION_ID [SESSION_ID...]

PROJECT_DIR is the folder of the transcripts (~/.claude/projects/<project>); each session is <id>.jsonl there, with its
subagents in <id>/subagents/*.jsonl. Rows without a timestamp are repeats of dated ones and are dropped."""
import json,glob,sys,re,os
proj=os.path.expanduser(sys.argv[1])
out=sys.argv[2]; sids=sys.argv[3:]
files=[]
for s in sids:
    files.append(f'{proj}/{s}.jsonl')
    files+=sorted(glob.glob(f'{proj}/{s}/subagents/*.jsonl'))
rows=[]
numre=re.compile(r'^\s*\d+\t',re.M)
def strip_cat_n(t):
    lines=t.split('\n'); res=[]
    for l in lines:
        m=re.match(r'^\s*(\d+)\t(.*)$',l,re.S)
        if m: res.append(m.group(2))
        elif l.strip()=='' : res.append(None)
        else: res.append(None)
    return res
for fn in files:
    uses={}
    seq=0
    with open(fn,errors='replace') as f:
        for ln,line in enumerate(f):
            if ('tool_use' not in line) and ('tool_result' not in line): continue
            try: ev=json.loads(line)
            except: continue
            m=ev.get('message')
            if not isinstance(m,dict): continue
            c=m.get('content')
            if not isinstance(c,list): continue
            ts=ev.get('timestamp','')
            for b in c:
                t=b.get('type')
                if t=='tool_use':
                    n=b['name']; i=b['input']
                    if n in('Write','Edit','Read'):
                        uses[b['id']]=(n,i,ts)
                        if n=='Write': rows.append(dict(ts=ts,src=os.path.basename(fn),ln=ln,k='Write',path=i['file_path'],content=i['content']))
                        elif n=='Edit': rows.append(dict(ts=ts,src=os.path.basename(fn),ln=ln,k='Edit',path=i['file_path'],old=i.get('old_string',''),new=i.get('new_string',''),all=i.get('replace_all',False)))
                    elif n in ('Bash','bash'):
                        rows.append(dict(ts=ts,src=os.path.basename(fn),ln=ln,k='Bash',cmd=i.get('command','')))
                elif t=='tool_result':
                    u=uses.get(b.get('tool_use_id'))
                    if u and u[0]=='Read':
                        cont=b.get('content')
                        if isinstance(cont,list): cont=''.join(x.get('text','') for x in cont if isinstance(x,dict))
                        if not isinstance(cont,str): continue
                        if b.get('is_error'): continue
                        i=u[1]
                        rows.append(dict(ts=ts,src=os.path.basename(fn),ln=ln,k='Read',path=i['file_path'],off=i.get('offset'),lim=i.get('limit'),text=cont))
rows=[r for r in rows if r['ts']]
rows.sort(key=lambda r:(r['ts'],r['src'],r['ln']))
with open(out,'w') as o:
    for r in rows: o.write(json.dumps(r)+'\n')
print(len(rows),'ops')
