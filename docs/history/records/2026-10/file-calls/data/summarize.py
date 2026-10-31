#!/usr/bin/env python3
"""summarize.py times-rot.txt: medians of each measure by project and arm, and meta against main."""
import sys, statistics, collections
d = collections.defaultdict(lambda: collections.defaultdict(list))
for line in open(sys.argv[1]):
    if line.startswith('#') or 'round=' not in line: continue
    f = line.split(); proj = f[0]
    kv = dict(x.split('=', 1) for x in f[1:] if '=' in x)
    if kv.get('exit') not in ('0', '2'): print('# exit:', line.strip()); continue
    for k, v in kv.items():
        try: d[(proj, kv['v'])][k].append(float(v))
        except ValueError: pass
keys = [('duration_time', 'wall ms', 1e-6), ('cycles/u', 'user Gcyc', 1e-9), ('cycles/k', 'kern Mcyc', 1e-6),
        ('instructions/u', 'instr G', 1e-9), ('page-faults', 'faults', 1), ('rss_kb', 'RSS MB', 1e-3)]
projs = []
for p, v in d:
    if p not in projs: projs.append(p)
print(f"{'project':15s} {'arm':5s} n  " + '  '.join(f"{h:>10s}" for _, h, _ in keys) + "   wall min")
for p in projs:
    m = {}
    for v in ('main', 'meta'):
        x = d[(p, v)]
        m[v] = [statistics.median(x[k]) * s for k, _, s in keys]
        mn = min(x['duration_time']) * 1e-6
        print(f"{p:15s} {v:5s} {len(x['duration_time']):2d} " + '  '.join(f"{a:10.3f}" for a in m[v]) + f"   {mn:8.2f}")
    print(f"{p:15s} {'meta/main':10s}" + '  '.join(f"{100*(b/a-1):+9.1f}%" for a, b in zip(m['main'], m['meta'])))
