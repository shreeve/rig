#!/usr/bin/env python3
"""Fastest and median of each measure in a time-bench .raw file, against the first variant."""
import sys, collections, statistics as st
d = collections.defaultdict(list); order = []
for l in open(sys.argv[1]):
    r, p, k, v, x = l.rstrip().split("\t"); d[(p, k, v)].append(float(x))
    if v not in order: order.append(v)
def pc(a, b): return "%.1f%% %s" % (((a / b - 1) if a >= b else (b / a - 1)) * 100, "faster" if a >= b else "slower")
def u(x): return "%.1f ms" % (x * 1e3) if x > 1e-3 else "%.0f us" % (x * 1e6)
print("| measure | variant | runs | fastest | median | fastest vs %s | median vs %s |" % (order[0], order[0]))
print("|---|---|---:|---:|---:|---|---|")
for (p, k) in sorted({(p, k) for p, k, _ in d}):
    b = d[(p, k, order[0])]
    for v in order:
        xs = d.get((p, k, v))
        if not xs: continue
        print("| %s %s | %s | %d | %s | %s | %s | %s |" % (p, k, v, len(xs), u(min(xs)), u(st.median(xs)), "" if v == order[0] else pc(min(b), min(xs)), "" if v == order[0] else pc(st.median(b), st.median(xs))))
