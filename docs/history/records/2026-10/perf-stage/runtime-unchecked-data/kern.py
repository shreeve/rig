#!/usr/bin/env python3
"""kern.py TIMES: per project and variant, median user and kernel cycles, the kernel's share, and peak RSS."""
import sys, statistics as st, collections
d = collections.defaultdict(lambda: collections.defaultdict(list))
for l in open(sys.argv[1]):
    if l.startswith("#"): continue
    f = l.split(); kv = dict(x.split("=", 1) for x in f[1:])
    for k in ("cycles", "total_cycles", "rss_kb", "exit"): d[(f[0], kv["v"])][k].append(float(kv[k]))
for k, v in sorted(d.items()):
    u = st.median(v["cycles"]); t = st.median(v["total_cycles"]); r = v["rss_kb"]
    print(f"{k[0]} {k[1]}: user {u/1e9:.3f}G kernel {(t-u)/1e9:.3f}G ({100*(t-u)/t:.1f}%) rss median {st.median(r):.0f} KB max {max(r):.0f} exits {sorted(set(v['exit']))}")
