#!/usr/bin/env python3
"""stats.py REF OUT.json...: medians (ms) with ranges for every program,
row and worker count, and each program's time over REF's, paired by
round: median [quartiles]."""
import json, statistics as st, sys
from collections import defaultdict

ref, files = sys.argv[1], sys.argv[2:]
t = defaultdict(dict)  # (w, row) -> prog -> {round: ns}
for i, f in enumerate(files):
    for k, w, p, row, ns, chk in json.load(open(f)):
        t[(w, row)].setdefault(p, {})[(i, k)] = ns

def q(xs):
    xs = sorted(xs)
    if len(xs) < 4:
        return xs[0], st.median(xs), xs[-1]
    a = st.quantiles(xs, n=4)
    return a[0], st.median(xs), a[2]

for (w, row) in sorted(t, key=lambda x: (x[1].rstrip("0123456789"), x[1], x[0])):
    progs = t[(w, row)]
    print("\n%s, %d worker%s" % (row, w, "" if w == 1 else "s"))
    print("| program | n | median ms | range | / %s, paired: median [quartiles] |" % ref)
    print("|---|---:|---:|---|---|")
    r = progs.get(ref, {})
    for p, d in progs.items():
        v = [x / 1e6 for x in d.values()]
        rat = [d[k] / r[k] for k in d if k in r]
        rs = "%.3f [%.3f-%.3f]" % (q(rat)[1], q(rat)[0], q(rat)[2]) if rat and p != ref else ""
        print("| %s | %d | %.3f | %.3f-%.3f | %s |" % (p, len(v), st.median(v), min(v), max(v), rs))
