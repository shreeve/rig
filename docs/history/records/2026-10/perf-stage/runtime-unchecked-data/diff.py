#!/usr/bin/env python3
"""diff.py A.sym B.sym [lines]: samples per key in A and B (scaled to A's total run count is not needed: same runs), A - B, most first."""
import sys, collections
def rd(p):
    c = collections.Counter(); tot = None
    for l in open(p):
        if l.startswith("# total"): tot = int(l.split()[2]); continue
        n, k = l.split(" ", 1); c[k.strip()] += int(n)
    return c, tot
a, ta = rd(sys.argv[1]); b, tb = rd(sys.argv[2])
if ta: print(f"# totals {ta} {tb}")
d = {k: a[k] - b[k] for k in set(a) | set(b)}
for k, v in sorted(d.items(), key=lambda x: -x[1])[:int(sys.argv[3]) if len(sys.argv) > 3 else 40]:
    print(f"{v:6d} {a[k]:6d} {b[k]:6d} {k}")
