#!/usr/bin/env python3
import sys, statistics, re
from collections import defaultdict
rows = defaultdict(lambda: defaultdict(list))
same = True
for l in open(sys.argv[1]):
    if "round=" not in l: continue
    f = dict(kv.split("=") for kv in l.split()[1:])
    proj = l.split()[0]
    if f["same"] != "1": same = False
    for k in ("ucycles", "kcycles", "instructions", "l3miss", "faults", "secs", "rss_kb"):
        rows[proj][(f["build"], k)].append(float(f[k]))
print("outputs identical every round:", same)
for proj in rows:
    n = len(rows[proj][("main", "ucycles")])
    print(f"\n{proj} ({n} rounds; medians, min in brackets)")
    print(f"{'':14} {'main':>16} {'new':>16} {'new/main':>9}")
    for k in ("rss_kb", "ucycles", "kcycles", "instructions", "l3miss", "faults", "secs"):
        a, b = rows[proj][("main", k)], rows[proj][("new", k)]
        ma, mb = statistics.median(a), statistics.median(b)
        print(f"{k:14} {ma:16,.0f} {mb:16,.0f} {mb/ma:9.4f}   [{min(a):,.0f} / {min(b):,.0f} = {min(b)/min(a):.4f}]" if k != "secs" else f"{k:14} {ma:16.3f} {mb:16.3f} {mb/ma:9.4f}")
