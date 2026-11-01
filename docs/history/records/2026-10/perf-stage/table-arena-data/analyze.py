#!/usr/bin/env python3
"""analyze.py TIMES.txt [BASE]: per project and checkers, each arm against
BASE (default base): median and fastest wall, median user plus kernel
cycles and instructions, median peak RSS."""
import sys, statistics as st, collections
rows, jobs, arms = collections.defaultdict(list), [], []
for line in open(sys.argv[1]):
    if ' v=' not in line:
        continue
    f = line.split()
    d = dict(x.split('=', 1) for x in f[1:])
    job = (f[0], d['c'])
    if job not in jobs:
        jobs.append(job)
    if d['v'] not in arms:
        arms.append(d['v'])
    rows[(job, d['v'])].append(d)
base = sys.argv[2] if len(sys.argv) > 2 else 'base'


def g(job, v, k, f=st.median):
    return f(float(x[k]) for x in rows[(job, v)])


def two(job, v, a, b):
    return st.median(float(x[a]) + float(x[b]) for x in rows[(job, v)])


def pct(a, b, less, more):
    r = a / b - 1
    return 'the same' if abs(r) < 0.0005 else f'{abs(r)*100:.1f}% {more if r > 0 else less}'


print(f'| project | checkers | arm | wall median ms | wall median | wall fastest | user+kernel cycles | user+kernel instructions | peak RSS | outputs |')
print('|---|---|---|---:|---|---|---|---|---|---|')
for job in jobs:
    for v in arms:
        if not rows[(job, v)]:
            continue
        same = all(x['same'] == '1' and x['exit'] == rows[(job, base)][0]['exit'] for x in rows[(job, v)])
        w = g(job, v, 'duration_time')
        if v == base:
            print(f"| {job[0]} | {job[1]} | {v} | {w/1e6:.2f} | | | | | {g(job, v, 'rss_kb')/1024:.1f} MB | {'same' if same else 'DIFF'} |")
            continue
        print(f"| {job[0]} | {job[1]} | {v} | {w/1e6:.2f} | "
              f"{pct(w, g(job, base, 'duration_time'), 'less', 'more')} | "
              f"{pct(g(job, v, 'duration_time', min), g(job, base, 'duration_time', min), 'less', 'more')} | "
              f"{pct(two(job, v, 'cycles/u', 'cycles/k'), two(job, base, 'cycles/u', 'cycles/k'), 'fewer', 'more')} | "
              f"{pct(two(job, v, 'instructions/u', 'instructions/k'), two(job, base, 'instructions/u', 'instructions/k'), 'fewer', 'more')} | "
              f"{pct(g(job, v, 'rss_kb'), g(job, base, 'rss_kb'), 'less', 'more')} | {'same' if same else 'DIFF'} |")
