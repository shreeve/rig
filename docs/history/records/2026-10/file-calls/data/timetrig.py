#!/usr/bin/env python3
"""timetrig.py N VARIANT=BIN... [-- PROJECTS]: N rounds, every variant once a
round, the order rotated each round; wall, user, sys per run; prints median
and min per project and variant, and the gap of each variant to the first."""
import os, sys, time, subprocess, statistics, resource
args = sys.argv[1:]
n = int(args.pop(0))
projs = ['zod3', 'ts-pattern', 'tiny-invariant', 'superstruct', 'mitt', 'neverthrow']
if '--' in args:
    i = args.index('--'); projs = args[i+1:]; args = args[:i]
vs = [a.split('=', 1) for a in args]
P = os.path.expanduser('~/Data/Code/trig/misc/projects')
cmd = ['-p', 'tsconfig.trig.json', '--noEmit', '--singleThreaded']
res = {}
def run(b, p):
    r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    t = time.perf_counter()
    subprocess.run([b] + cmd, cwd=os.path.join(P, p), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    w = time.perf_counter() - t
    r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    return w * 1000, (r1.ru_utime - r0.ru_utime) * 1000, (r1.ru_stime - r0.ru_stime) * 1000
for p in projs:
    for name, b in vs: run(b, p)  # warm
    for r in range(n):
        order = vs[r % len(vs):] + vs[:r % len(vs)]
        for name, b in order:
            res.setdefault((p, name), []).append(run(b, p))
for p in projs:
    base = None
    for name, b in vs:
        x = res[(p, name)]
        med = statistics.median(a[0] for a in x); mn = min(a[0] for a in x)
        u = statistics.median(a[1] for a in x); s = statistics.median(a[2] for a in x)
        if base is None: base = (med, mn)
        print(f"{p:15s} {name:10s} wall med {med:7.2f} min {mn:7.2f}  user {u:7.2f} sys {s:6.2f}  vs first: med {100*(med/base[0]-1):+.1f}% min {100*(mn/base[1]-1):+.1f}%")
