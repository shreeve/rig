#!/usr/bin/env python3
"""analyze.py TIMES.txt: per project, checker-tasks (ct) against main (base) at
one checker and at four: median and fastest wall, median user plus kernel
cycles, median peak RSS, each as a percentage more or less than base."""
import sys, statistics as st, collections
rows, projs = collections.defaultdict(list), []
for line in open(sys.argv[1]):
    if ' v=' not in line: continue
    f = line.split(); proj = f[0]; d = dict(x.split('=', 1) for x in f[1:])
    if proj not in projs: projs.append(proj)
    rows[(proj, d['v'])].append(d)
def g(proj, v, k, f=st.median): return f(float(x[k]) for x in rows[(proj, v)])
def cyc(proj, v): return st.median(float(x['cycles/u']) + float(x['cycles/k']) for x in rows[(proj, v)])
def pct(a, b, less, more):
    r = a / b - 1
    return 'the same' if abs(r) < 0.0005 else f'{abs(r)*100:.1f}% {more if r > 0 else less}'
print('| project | checkers | base wall median ms | ct wall median ms | wall median | wall fastest | user+kernel cycles | peak RSS | outputs |')
print('|---|---|---:|---:|---|---|---|---|---|')
for proj in projs:
    for n in '14':
        b, c = 'base' + n, 'ct' + n
        same = all(x['same'] == '1' for v in (b, c) for x in rows[(proj, v)])
        print(f"| {proj} | {n} | {g(proj, b, 'duration_time')/1e6:.1f} | {g(proj, c, 'duration_time')/1e6:.1f} | "
              f"{pct(g(proj, c, 'duration_time'), g(proj, b, 'duration_time'), 'less', 'more')} | "
              f"{pct(g(proj, c, 'duration_time', min), g(proj, b, 'duration_time', min), 'less', 'more')} | "
              f"{pct(cyc(proj, c), cyc(proj, b), 'fewer', 'more')} | {pct(g(proj, c, 'rss_kb'), g(proj, b, 'rss_kb'), 'less', 'more')} | {'same' if same else 'DIFF'} |")
