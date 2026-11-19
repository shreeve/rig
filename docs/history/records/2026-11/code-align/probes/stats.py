#!/usr/bin/env python3
"""stats.py REF BOARD.json...: per program and worker count, the median
[quartiles] of each timed row (ms), and the paired ratio to REF by round
(median [quartiles], rounds faster)."""
import json, statistics as st, sys
from collections import defaultdict
ref = sys.argv[1]
t = defaultdict(list); pair = defaultdict(dict)
for f in sys.argv[2:]:
    for k, w, n, lines in json.load(open(f)):
        for l in lines:
            p = l.split()
            if len(p) == 3:
                v = int(p[1]) / 1e6
                t[w, p[0], n].append(v); pair[w, p[0], f, k][n] = v
def q(v):
    if len(v) < 2: return "%.2f" % v[0]
    a = st.quantiles(v, n=4); return "%.3f [%.3f-%.3f]" % (st.median(v), a[0], a[2])
for (w, row, n) in sorted(t, key=lambda x: (x[0], x[1], x[2])):
    v = t[w, row, n]
    r = sorted(d[n] / d[ref] for (ww, rr, _, _), d in pair.items() if ww == w and rr == row and n in d and ref in d)
    rs = "" if n == ref or len(r) < 2 else "  /%s %s %d/%d" % (ref, q(r), sum(x < 1 for x in r), len(r))
    a = st.quantiles(v, n=4) if len(v) > 1 else [v[0], v[0], v[0]]
    print("w=%-2d %-5s %-8s %7.1f [%.1f-%.1f]%s" % (w, row, n, st.median(v), a[0], a[2], rs))
