#!/usr/bin/env python3
"""analyze.py TIMES.txt: per project, each variant's median and fastest wall
time, median user cycles and peak RSS, and each as a percentage more or less
than tsrs1 (tsrs on one thread)."""
import sys, statistics as st, collections
rows, projs = collections.defaultdict(list), []
for line in open(sys.argv[1]):
    if ' v=' not in line: continue
    f = line.split(); proj = f[0]; d = dict(x.split('=', 1) for x in f[1:])
    if proj not in projs: projs.append(proj)
    rows[(proj, d['v'])].append(d)
def pct(a, b, less, more):
    r = a / b - 1
    if abs(r) < 0.0005: return 'the same as tsrs1'
    return f'{abs(r) * 100:.1f}% {more if r > 0 else less} than tsrs1'
print('| project | variant | n | wall median ms | wall fastest ms | user cycles | peak RSS MB | wall median vs tsrs1 | user cycles vs tsrs1 | peak RSS vs tsrs1 | output |')
print('|---|---|---:|---:|---:|---:|---:|---|---|---|---|')
for proj in projs:
    base = rows[(proj, 'tsrs1')]
    bm = lambda k, f=st.median: f(float(x[k]) for x in base)
    for v in ['trig1', 'trig4', 'tsrs1', 'tsrs4']:
        r = rows.get((proj, v))
        if not r: continue
        g = lambda k, f=st.median: f(float(x[k]) for x in r)
        same = 'same' if all(x['same'] == '1' for x in r) else 'DIFF'
        exits = ','.join(sorted(set(x['exit'] for x in r)))
        cmp = ['', '', ''] if v == 'tsrs1' else [pct(g('duration_time'), bm('duration_time'), 'less', 'more'),
                                                 pct(g('cycles/u'), bm('cycles/u'), 'fewer', 'more'),
                                                 pct(g('rss_kb'), bm('rss_kb'), 'less', 'more')]
        print(f"| {proj} | {v} | {len(r)} | {g('duration_time')/1e6:,.1f} | {g('duration_time', min)/1e6:,.1f} | {g('cycles/u')/1e9:.3f}G | {g('rss_kb')/1024:.1f} | {cmp[0]} | {cmp[1]} | {cmp[2]} | {same}, exit {exits} |")
