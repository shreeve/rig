#!/usr/bin/env python3
# absum.py RUNS: per project/checkers: median ms of a, b, f; f vs a, A/A; instructions, RSS, faults, free blocks.
import re,sys,statistics as st,collections
d=collections.defaultdict(lambda: collections.defaultdict(list))
FLOOR=int(sys.argv[2]) if len(sys.argv)>2 else -1
below={}
order=[]
for l in open(sys.argv[1]):
    if l.startswith('#'): continue
    m=re.match(r'(\S+) c=(\d+) round=\d+ v=(\w) (.*)',l)
    if not m: continue
    p,c,v,rest=m.groups(); k=(p,int(c))
    if k not in order: order.append(k)
    g=lambda n: float(re.search(n+r'=([\d.]+)',rest).group(1))
    fr=re.search(r'free=(\d+)>(\d+)',rest)
    if int(fr.group(1))<=FLOOR:
        below[k]=below.get(k,0)+1
        continue
    r=d[k][v]
    r.append(dict(t=g('duration_time')/1e6,cy=g('cycles/u'),i=g('instructions/u'),rss=g('rss_kb')/1024,fl=g('minflt'),s=g('stime'),free=int(fr.group(1)),ex=int(re.search(r'exit=(\d+)',rest).group(1))))
med=lambda r,k: st.median(x[k] for x in r)
q25=lambda r,k: sorted(x[k] for x in r)[len(r)//4]
print(f"{'project':14} c  {'a ms':>8} {'b ms':>8} {'f ms':>8} {'f/a':>7} {'A/A':>7} {'q25 f/a':>7} {'cy f/a':>7} {'ins f/a':>8} {'rss a':>7} {'rss f':>7} {'flt a':>7} {'flt f':>7} free")
for k in order:
    a,b,f=d[k]['a'],d[k]['b'],d[k]['f']
    if not a or not f: continue
    pc=lambda x,y: f"{(x/y-1)*100:+.1f}%"
    print(f"{k[0]:14} {k[1]}  {med(a,'t'):8.2f} {med(b,'t'):8.2f} {med(f,'t'):8.2f} {pc(med(f,'t'),med(a,'t')):>7} {pc(med(b,'t'),med(a,'t')):>7} {pc(q25(f,'t'),q25(a,'t')):>7} {pc(med(f,'cy'),med(a,'cy')):>7} {pc(med(f,'i'),med(a,'i')):>8} {med(a,'rss'):7.1f} {med(f,'rss'):7.1f} {med(a,'fl'):7.0f} {med(f,'fl'):7.0f} {min(x['free'] for x in a+f)}-{max(x['free'] for x in a+f)}")

print('runs at or below the floor:',sum(below.values()),below)
print('runs kept per cell:',{k:(len(d[k]['a']),len(d[k]['b']),len(d[k]['f'])) for k in order})
