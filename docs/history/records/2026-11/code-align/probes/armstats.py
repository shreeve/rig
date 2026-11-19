#!/usr/bin/env python3
"""armstats.py REF BOARD.json: for each arm (a program's name up to its
last `-`: base-s3 is arm base, placement s3) and worker count, each
placement's qsort median and paired ratio to REF, and the arm's spread:
its slowest placement's median over its fastest's."""
import json, statistics as st, sys
from collections import defaultdict
ref, f = sys.argv[1], sys.argv[2]
t = defaultdict(list); pair = defaultdict(dict)
for k, w, n, lines in json.load(open(f)):
    for l in lines:
        p = l.split()
        if len(p) == 3 and p[0] == "qsort":
            v = int(p[1]) / 1e6; t[w, n].append(v); pair[w, k][n] = v
arms = defaultdict(list)
for (w, n) in t: arms[w, n.rsplit("-", 1)[0]].append(n)
for (w, a) in sorted(arms):
    ms = []
    for n in sorted(arms[w, a], key=lambda x: (len(x), x)):
        m = st.median(t[w, n]); ms.append(m)
        r = sorted(d[n] / d[ref] for (ww, _), d in pair.items() if ww == w and n in d and ref in d)
        q = st.quantiles(r, n=4)
        print("w=%-2d %-14s %7.1f  /ref %.3f [%.3f-%.3f]" % (w, n, m, st.median(r), q[0], q[2]))
    print("w=%-2d arm %-10s median of placements %.1f, spread %.3f\n" % (w, a, st.median(ms), max(ms) / min(ms)))
