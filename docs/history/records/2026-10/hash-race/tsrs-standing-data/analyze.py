#!/usr/bin/env python3
"""analyze.py TIMES.txt: per project and variant, the median and fastest
wall time, median cycles, instructions, peak RSS and minor faults."""
import sys, statistics as st, collections
rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    if line.startswith('#'): continue
    f = line.split(); proj = f[0]; d = dict(x.split('=') for x in f[1:])
    rows[(proj, d['v'])].append(d)
order = ['main-pgo', 'main-rel', 'f7ed-rel', 'a38f-rel', 'tsrs', 'tsrs-src']
for proj in ['ts-pattern', 'zod3']:
    print(f'\n{proj}')
    print('| variant | n | wall median ms | wall fastest ms | cycles (median) | instructions (median) | peak RSS MB (median) | minor faults (median) | output |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|---|')
    for v in order:
        r = rows.get((proj, v))
        if not r: continue
        ns = [int(x['ns']) for x in r]
        med = lambda k: st.median(int(x[k]) for x in r)
        same = all(x['same'] == '1' and x['exit'] in ('0', '2') for x in r)
        exits = sorted(set(x['exit'] for x in r))
        print(f"| {v} | {len(r)} | {st.median(ns)/1e6:,.1f} | {min(ns)/1e6:,.1f} | {med('cycles')/1e9:.3f}G | {med('instructions')/1e9:.3f}G | {med('rss_kb')/1024:.1f} | {med('minflt'):,.0f} | {'same' if same else 'DIFF'} exit {','.join(exits)} |")
    def m(v, k, f=st.median):
        return f(int(x[k]) for x in rows[(proj, v)])
    print()
    for a, b in [('main-pgo', 'tsrs'), ('main-rel', 'tsrs'), ('main-rel', 'tsrs-src'), ('main-rel', 'f7ed-rel'), ('f7ed-rel', 'a38f-rel'), ('main-rel', 'a38f-rel')]:
        if (proj, a) not in rows or (proj, b) not in rows: continue
        print(f"{a} / {b}: wall median {m(a,'ns')/m(b,'ns'):.3f}, fastest {m(a,'ns',min)/m(b,'ns',min):.3f}, cycles {m(a,'cycles')/m(b,'cycles'):.4f}, instructions {m(a,'instructions')/m(b,'instructions'):.4f}, RSS {m(a,'rss_kb')/m(b,'rss_kb'):.3f}, faults {m(a,'minflt')/m(b,'minflt'):.3f}")
    loads = [float(x['load']) for k, r in rows.items() if k[0] == proj for x in r]
    print(f'load: {min(loads)} to {max(loads)}')
