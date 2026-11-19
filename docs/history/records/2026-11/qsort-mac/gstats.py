#!/usr/bin/env python3
"""gstats.py BOARD.json A B...: medians per row and program, and each
program's ratio to A paired by round, median [quartiles], rounds won."""
import json, statistics as st, sys
from collections import defaultdict
d = json.load(open(sys.argv[1])); base = sys.argv[2]
t = defaultdict(dict); checks = defaultdict(set)
for k, w, n, lines in d:
    for l in lines:
        p = l.split()
        if len(p) == 3 and p[1].isdigit():
            t[w, p[0], k][n] = int(p[1]) / 1e6; checks[p[0]].add(p[2])
print("checks", {k: sorted(v) for k, v in checks.items()})
rows = sorted({(w, r) for w, r, _ in t})
names = sorted({n for v in t.values() for n in v})
for w, r in rows:
    vals = {n: [v[n] for (ww, rr, _), v in t.items() if ww == w and rr == r and n in v] for n in names}
    out = []
    for n in names:
        if not vals[n] or not vals.get(base): continue
        if n == base: out.append("%s %.3f" % (n, st.median(vals[n]))); continue
        x = sorted(v[n] / v[base] for (ww, rr, _), v in t.items() if ww == w and rr == r and n in v and base in v)
        if len(x) < 4: continue
        q = st.quantiles(x, n=4)
        out.append("%s %.3f, %.3f [%.3f-%.3f] %d/%d" % (n, st.median(vals[n]), st.median(x), q[0], q[2], sum(y < 1 for y in x), len(x)))
    print("w=%d %-8s %s" % (w, r, " | ".join(out)))
