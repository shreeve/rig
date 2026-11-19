#!/usr/bin/env python3
"""stats.py BOARD.json...: the boards pooled. Medians in ms, then each
pair's ratio taken round by round: median [quartiles], and the rounds the
first program won. Programs: rig (fork.rig), aa (the same source built
again), left (fork-left.rig), rayon, rayonR (rayon-right-first)."""
import json, statistics as st, sys

t, checks, rounds = {}, {}, []
for b, f in enumerate(sys.argv[1:]):
    for r, w, n, row, ns, c in json.load(open(f)):
        t[w, row, n, (b, r)] = ns / 1e6
        checks.setdefault(row, set()).add(c)
        if (b, r) not in rounds: rounds.append((b, r))
bad = {k: v for k, v in checks.items() if len(v) != 1}
if bad: sys.exit("checks differ: %s" % bad)
print("checks", {k: sorted(v) for k, v in checks.items()}, "rounds", len(rounds))
ws = sorted({k[0] for k in t})
progs = ["rig", "aa", "left", "rayon", "rayonR"]
pairs = [("rig", "rayon"), ("left", "rayonR"), ("left", "rayon"), ("left", "rig"), ("rayonR", "rayon"), ("aa", "rig")]
g = lambda w, row, n: [t[w, row, n, r] for r in rounds]
print("\n| row | workers | " + " | ".join(progs) + " |\n|---|---:|" + "---:|" * len(progs))
for row in ("psum", "qsort"):
    for w in ws:
        print("| %s | %d | " % (row, w) + " | ".join("%.2f" % st.median(g(w, row, n)) for n in progs) + " |")
print("\n| row | workers | " + " | ".join("%s/%s" % p for p in pairs) + " |\n|---|---:|" + "---|" * len(pairs))
for row in ("psum", "qsort"):
    for w in ws:
        cells = []
        for a, b in pairs:
            x = sorted(p / q for p, q in zip(g(w, row, a), g(w, row, b)))
            q = st.quantiles(x, n=4)
            cells.append("%.3f [%.3f-%.3f] %d/%d" % (st.median(x), q[0], q[2], sum(v < 1 for v in x), len(x)))
        print("| %s | %d | " % (row, w) + " | ".join(cells) + " |")
