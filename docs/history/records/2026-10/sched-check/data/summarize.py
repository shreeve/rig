#!/usr/bin/env python3
"""Summarize a time-trig .raw file: per project and variant, the fastest
wall, the median wall, the fewest cycles, and the median instructions."""
import sys, statistics as st, collections
rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    r, proj, n, w, i, c, m = line.split("\t")
    rows[(proj, n)].append((float(w), int(i), int(c)))
names = []
for (p, n) in rows:
    if n not in names: names.append(n)
print("| project | variant | fastest wall | median wall | fewest cycles | median instructions |")
print("|---|---|---:|---:|---:|---:|")
def pc(a, b, up, down):
    s = a / b
    return "%.1f%% %s" % (((s - 1) if s >= 1 else (1 / s - 1)) * 100, up if s >= 1 else down)
for proj in sorted({p for p, _ in rows}, key=lambda p: (p != "ts-pattern", p)):
    base = rows[(proj, names[0])]
    bw, bmw = min(x[0] for x in base), st.median(x[0] for x in base)
    bc, bi = min(x[2] for x in base), st.median(x[1] for x in base)
    for n in names:
        v = rows[(proj, n)]
        w, mw, c, i = min(x[0] for x in v), st.median(x[0] for x in v), min(x[2] for x in v), st.median(x[1] for x in v)
        if n == names[0]:
            print("| %s | %s | %.1f ms | %.1f ms | %.3fG | %.3fG |" % (proj, n, w*1e3, mw*1e3, c/1e9, i/1e9))
        else:
            print("| %s | %s | %s | %s | %s | %s |" % (proj, n, pc(bw, w, "faster", "slower"), pc(bmw, mw, "faster", "slower"), pc(bc, c, "fewer", "more"), pc(bi, i, "fewer", "more")))
