#!/usr/bin/env python3
"""fixed.py FIXED.txt: medians of the tiny projects' runs, Trig and tsrs."""
import sys, statistics as st, collections
rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    if " v=" not in line: continue
    f = line.split(); d = dict(x.split('=', 1) for x in f[1:])
    rows[(f[0], d['v'])].append(d)
print('| project | variant | n | wall median ms | fastest ms | user ms | system ms | user cycles | kernel cycles | instructions | page faults | peak RSS MB |')
print('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
for (k, v), r in sorted(rows.items()):
    g = lambda key, f=st.median: f(float(x[key]) for x in r)
    print(f"| {k} | {v} | {len(r)} | {g('duration_time')/1e6:.1f} | {g('duration_time', min)/1e6:.1f} | {g('user_time')/1e6:.1f} | {g('system_time')/1e6:.1f} | {g('cycles/u')/1e6:.0f}M | {g('cycles/k')/1e6:.0f}M | {g('instructions/u')/1e6:.0f}M | {g('page-faults'):,.0f} | {g('rss_kb')/1024:.1f} |")
