#!/usr/bin/env python3
# esumm.py FILE: medians per project and arm of ecore.sh's lines, against mainbase.
import sys, re, statistics as st, collections
d = collections.defaultdict(lambda: collections.defaultdict(list)); bad = []
for l in open(sys.argv[1]):
    if l.startswith('#'): continue
    w = l.split(); proj = w[0]; v = w[2][2:]
    f = dict(x.split('=', 1) for x in w[3:] if '=' in x)
    if f.get('same') != '1': bad.append(l.strip())
    for k in ('duration_time', 'cpu_atom/instructions/u', 'cpu_atom/instructions/k', 'cpu_atom/cycles/u', 'cpu_atom/cycles/k', 'rss_kb'):
        d[proj][(v, k)].append(float(f[k]))
names = {'duration_time': 'wall', 'cpu_atom/instructions/u': 'u-instr', 'cpu_atom/instructions/k': 'k-instr', 'cpu_atom/cycles/u': 'u-cyc', 'cpu_atom/cycles/k': 'k-cyc', 'rss_kb': 'rss'}
for proj in d:
    arms = sorted({v for v, _ in d[proj]}, key=lambda v: ['mainbase', 'mainbase2', 'mainlazy2', 'pbbase', 'pbdefer2'].index(v))
    for v in arms:
        line = f"{proj:12s} {v:10s}"
        for k, n in names.items():
            m = st.median(d[proj][(v, k)]); b = st.median(d[proj][('mainbase', k)])
            line += f" | {n} {(m / b - 1) * 100:+.2f}%"
        print(line)
for b in bad: print("DIFFERS:", b)
