#!/usr/bin/env python3
"""clock.py TIMES.txt...: per project and variant, the cycles a millisecond of
CPU time (user and kernel cycles over user and system time) and the wall time
outside the CPU time, medians."""
import sys, collections, statistics as st
rows = collections.defaultdict(list)
for p in sys.argv[1:]:
    for line in open(p):
        if ' v=' not in line: continue
        f = line.split(); d = dict(x.split('=', 1) for x in f[1:]); rows[(f[0], d['v'])].append(d)
for (proj, v), r in sorted(rows.items()):
    ghz = [(float(x['cycles/u']) + float(x['cycles/k'])) / (float(x['user_time']) + float(x['system_time'])) for x in r]
    off = [float(x['duration_time']) - float(x['user_time']) - float(x['system_time']) for x in r]
    print(f"{proj:15} {v:8} GHz {st.median(ghz):.2f} (lowest {min(ghz):.2f})  wall outside CPU time {st.median(off)/1e6:6.2f} ms")
