#!/usr/bin/env python3
"""pstats.py BOARD.json...: from pboard's samples, per program and workers:
qsort medians; per node of the top levels (depth, path): its length, the
partition's time, the time from its maker's fork to its start (a node on
the high side, path odd), its extends and its wait, medians in ms; and the
paired ratios of the plain programs."""
import json, statistics as st, sys
from collections import defaultdict
rows = []
for f in sys.argv[1:]:
    rows += [(f,) + tuple(r) for r in json.load(open(f))]
q = defaultdict(list); node = defaultdict(lambda: defaultdict(list)); checks = defaultdict(set)
pair = defaultdict(dict)
for f, k, w, n, lines in rows:
    ph = {}
    for l in lines:
        p = l.split()
        if p[0] == "ph":
            d, path, ln, t0, t1, t2, t3, t4, t5 = map(int, p[1:])
            ph[d, path] = (ln, t0, t1, t2, t3, t4, t5)
        else:
            q[w, n, p[0]].append(int(p[1]) / 1e6); checks[p[0]].add(p[2])
            pair[w, p[0], (f, k)][n] = int(p[1]) / 1e6
    for (d, path), (ln, t0, t1, t2, t3, t4, t5) in ph.items():
        s = node[w, n]
        s[d, path, "len"].append(ln)
        s[d, path, "part"].append((t1 - t0) / 1e6)
        s[d, path, "own"].append((t2 - t1) / 1e6)
        s[d, path, "wait"].append((t4 - t3) / 1e6)
        s[d, path, "ext"].append((t5 - t4 + t3 - t2) / 1e6)
        s[d, path, "all"].append((t5 - t0) / 1e6)
        if path % 2 == 1 and (d - 1, path // 2) in ph:
            s[d, path, "late"].append((t0 - ph[d - 1, path // 2][2]) / 1e6)
print("checks", dict(checks))
for (w, n, row), v in sorted(q.items()):
    qs = st.quantiles(v, n=4)
    print("%-6s w=%-2d %-6s median %.2f [%.2f-%.2f] n=%d" % (n, w, row, st.median(v), qs[0], qs[2], len(v)))
for (w, n), s in sorted(node.items()):
    print("\n%s w=%d" % (n, w))
    keys = sorted({(d, p) for d, p, _ in s})
    print("%-8s %9s %7s %7s %7s %7s %7s %7s" % ("node", "len", "late", "part", "own", "ext", "wait", "all"))
    for d, p in keys:
        g = lambda c: ("%.2f" % st.median(s[d, p, c])) if s[d, p, c] else "-"
        print("%-8s %9d %7s %7s %7s %7s %7s %7s" % ("%d/%d" % (d, p), st.median(s[d, p, "len"]), g("late"), g("part"), g("own"), g("ext"), g("wait"), g("all")))
def ratio(a, b, w, row):
    x = sorted(v[a] / v[b] for (ww, rr, _), v in pair.items() if ww == w and rr == row and a in v and b in v)
    if len(x) < 4: return None
    qs = st.quantiles(x, n=4)
    return "%.3f [%.3f-%.3f] %d/%d" % (st.median(x), qs[0], qs[2], sum(r < 1 for r in x), len(x))
print()
names = sorted({n for (_, n, _) in q})
for a, b in [(x, y) for x in names for y in names if x != y]:
    for w in sorted({w for (w, _, _) in q}):
        for row in ("psum", "qsort"):
            r = ratio(a, b, w, row)
            if r and (b in ("fork", "rayon") or (a, b) in [("rig", "rust"), ("aa", "rig"), ("nopsum", "rnopsum"), ("drop", "rdrop")]):
                print("%s/%s w=%d %s: %s" % (a, b, w, row, r))
