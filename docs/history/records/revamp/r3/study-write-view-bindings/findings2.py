import re, os, json
R='/Users/shreeve/Data/Code/rig/.git/revamp/r3'
out={}
for rev in ['payload-loan-1','payload-loan-2','payload-loan-3','payload-loan-4','payload-loan-5','syntax-b-2']:
    text=open(f'{R}/review-{rev}.md').read()
    pdir=f'{R}/review-{rev}-probes'
    stems={}
    for f in os.listdir(pdir):
        p=os.path.join(pdir,f)
        if f.endswith('.rig'): stems[f[:-4]]=p
        elif os.path.isdir(p) and os.path.exists(p+'/main.rig'): stems[f]=p+'/main.rig'
    byid={}
    for s in stems:
        byid.setdefault(s.split('_')[0],[]).append(s)
    secs=re.split(r'\n(?=###? )',text)
    for s in secs:
        m=re.match(r'###? ([CH]\d+)\.',s)
        if not m: continue
        fid=m.group(1)
        ids=[]
        for line in s.split('\n'):
            if line.startswith('| `') or line.startswith('| **`'):
                cell=line.split('|')[1]
                for t in re.findall(r'`([A-Za-z0-9_.\-]+)`',cell):
                    t=t[:-4] if t.endswith('.rig') else t
                    if t in stems: ids.append(t)
                    elif t in byid: ids.extend(byid[t])
        seen=[]
        for i in ids:
            if i not in seen: seen.append(i)
        out[f'{rev} {fid}']=seen
for k,v in out.items(): print(k,len(v),' '.join(v))
json.dump(out,open('findings.json','w'),indent=1)
