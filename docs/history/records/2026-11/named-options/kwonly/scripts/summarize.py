import sys, collections, re, os
S = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
rows = []
seen = set()
for fn in sys.argv[1:]:
    for line in open(fn, errors='replace'):
        f = line.rstrip('\n').split('\t')
        if len(f) < 9: continue
        kind, root, path, lc, callee, pidx, pname, arg, text = f[:9]
        key = (kind.split(':')[0] if kind!='fnvalue' else 'fnvalue', path, lc, pidx, callee)
        if key in seen: continue
        seen.add(key)
        rows.append(dict(kind=kind, root=root, path=path, lc=lc, callee=callee, pidx=pidx, pname=pname, arg=arg, text=text))

_cache={}
def locate(r):
    # A directory module's position is in its joined source: find the file by the line's text.
    p=r['path']
    if not p.endswith('/') or not os.path.isdir(p): return
    key=(p, r['text'])
    if key not in _cache:
        hits=[]
        for f in sorted(os.listdir(p)):
            if not f.endswith('.rig'): continue
            for n,l in enumerate(open(os.path.join(p,f), errors='replace'),1):
                if l.strip(' \t\n')==r['text']: hits.append((os.path.join(p,f),n))
        _cache[key]=hits
    hits=_cache[key]
    if len(hits)>=1:
        col=r['lc'].split(':')[1]
        r['path'], r['lc'] = hits[0][0], f"{hits[0][1]}:{col}"
        if len(hits)>1: r['lc'] += f" (+{len(hits)-1} same text)"

def source(r):
    p = r['path']; root = r['root']
    if p.startswith('std') or 'kwonly-count/std/' in p: return 'std'
    if 'kwonly/trig' in p or p.startswith('trig:'): return 'trig'
    if 'kwonly/loc/' in p: return 'loco'
    if 'rig-tests/doc-' in p or '/doc' in p and 'rig-tests' in p: return 'docs'
    if 'rig-tests' in p: return 'tests'
    if '/bench/' in p or p.startswith('bench/'): return 'bench'
    if '/examples/' in p or p.startswith('examples/'): return 'examples'
    if '/tools/' in p or p.startswith('tools/'): return 'tools'
    return 'other'
rows=[r for r in rows if (r['root'].startswith('/') or r['path'].startswith('std')) and 'rig-tests/tree/' not in r['path']]
R=os.path.expanduser('~/Data/Code/worktrees/rig/kwonly-count/')
for r in rows:
    if r['path'].startswith('std/'): r['path']=R+r['path']
    r['path']=os.path.realpath(r['path'])+('/' if r['path'].endswith('/') else '')
    r['orig']=(r['path'], r['lc'])
    locate(r)
# dedupe again after locating
u={}; 
for r in rows: u.setdefault((r['kind'].split(':')[0] if r['kind']!='fnvalue' else 'fnvalue', r['orig'], r['pidx']), r)
rows=list(u.values())
for r in rows: r['src'] = source(r)
out = open(os.path.join(S, 'calls.tsv'), 'w')
out.write('source\tkind\tpath\tline:col\tcallee\tparam#\tparam\targ\tline\n')
for r in sorted(rows, key=lambda r:(r['src'], r['kind'], r['path'], r['lc'])):
    out.write('\t'.join([r['src'], r['kind'], r['path'], r['lc'], r['callee'], r['pidx'], r['pname'], r['arg'], r['text']]) + '\n')
c = collections.Counter((r['src'], r['kind']) for r in rows)
for k in sorted(c): print(k, c[k])
print('by source (positional only, excl fnvalue):', collections.Counter(r['src'] for r in rows if r['kind']!='fnvalue'))
cc = collections.Counter((r['callee'], r['pname']) for r in rows if r['kind']!='fnvalue')
print('top callees:')
for (k,p),n in cc.most_common(40): print(f'  {n:5d} {k} ({p})')

# call sites: per (source, path, line, callee), the most arguments any one parameter got
g=collections.defaultdict(collections.Counter)
for r in rows:
    if r['kind']=='fnvalue': continue
    g[(r['src'], r['path'], r['lc'].split(':')[0].split()[0], r['callee'])][r['pidx']]+=1
calls=collections.Counter()
for (src,_,_,_),c in g.items(): calls[src]+=max(c.values())
print('call sites by source:', dict(calls), 'total', sum(calls.values()))
args=collections.Counter(r['src'] for r in rows if r['kind']!='fnvalue')
print('arguments by source:', dict(args), 'total', sum(args.values()))
# callee qualified by the text before it on the line
def qual(r):
    col=int(r['orig'][1].split(':')[1])
    name=r['callee'].split('.')[-1]
    best=None
    for m in re.finditer(r'([A-Za-z_][\w.]*\.)?'+re.escape(name)+r'\(', r['text']):
        if m.start() < col: best=m
    if best and best.group(1): return best.group(1).rstrip('.').split('.')[-1]+'.'+name
    return r['callee']
qc=collections.Counter()
for (src,path,line,callee),c in g.items():
    rr=next(r for r in rows if r['path']==path and r['lc'].split(':')[0].split()[0]==line and r['callee']==callee)
    qc[qual(rr)]+=max(c.values())
print('top callees by call sites:')
for k,n in qc.most_common(30): print(f'  {n:5d} {k}')
qs=collections.Counter()
for (src,path,line,callee),c in g.items():
    rr=next(r for r in rows if r['path']==path and r['lc'].split(':')[0].split()[0]==line and r['callee']==callee)
    qs[(src,qual(rr))]+=max(c.values())
print('call sites by source and callee:')
for (src,k),n in sorted(qs.items(), key=lambda x:(x[0][0],-x[1])): print(f'  {src:6s} {n:4d} {k}')
