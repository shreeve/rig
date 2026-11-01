#!/usr/bin/env python3
"""summ.py TIMES BASE (check-bisect's, with peak RSS): per project and variant, the medians of time.sh's
lines, and each against BASE: "faster" and "fewer" from the paired
per-round ratio (median over rounds, with the 25th-75th percentile range
of the wall ratio), and any output that differed."""
import sys, statistics, collections
rows = collections.defaultdict(lambda: collections.defaultdict(dict))
diff = collections.Counter(); order = []
for l in open(sys.argv[1]):
    if l.startswith("# DIFF"):
        f = l.split(); diff[(f[2], f[4][2:])] += 1; continue
    if l.startswith("#"): continue
    f = l.split(); proj = f[0]; kv = dict(x.split("=", 1) for x in f[1:])
    v = kv["v"]; r = int(kv["round"])
    if (proj, v) not in order: order.append((proj, v))
    for k in ("ns", "cycles", "total_cycles", "instructions", "rss_kb"):
        try: rows[(proj, v)][r][k] = float(kv[k])
        except (KeyError, ValueError): pass
base = sys.argv[2]
K = ("ns", "total_cycles", "cycles", "instructions")
def q(xs, p):
    xs = sorted(xs); i = (len(xs) - 1) * p; lo = int(i); hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (i - lo)
for proj in ("ts-pattern", "zod3"):
    vs = [v for (p, v) in order if p == proj]
    if not vs: continue
    print(f"\n{proj}")
    print(f"| variant | rounds | wall ms | total cycles G | user instructions G | peak RSS MB | vs {base}: faster (IQR) / fewer total cycles / fewer user cycles / fewer instructions |")
    print("|---|---:|---:|---:|---:|---:|---|")
    for v in vs:
        R = rows[(proj, v)]
        med = lambda k: statistics.median(x[k] for x in R.values() if k in x)
        cells = [v + (f" (output differed {diff[(proj, v)]}x)" if diff[(proj, v)] else ""), str(len(R)),
                 f"{med('ns')/1e6:.1f}", f"{med('total_cycles')/1e9:.3f}" if any('total_cycles' in x for x in R.values()) else "", f"{med('instructions')/1e9:.3f}", f"{med('rss_kb')/1024:.1f}"]
        if v != base and (proj, base) in rows:
            B = rows[(proj, base)]
            parts = []
            for k in K:
                rs = [R[r][k] / B[r][k] for r in R if r in B and k in R[r] and k in B[r]]
                if not rs: parts.append("-"); continue
                m = 100 * (1 - statistics.median(rs))
                if k == "ns":
                    parts.append(f"{m:.2f}% ({100*(1-q(rs,.75)):.2f} to {100*(1-q(rs,.25)):.2f})")
                else:
                    parts.append(f"{m:.2f}%")
            cells.append(" / ".join(parts))
        else:
            cells.append("")
        print("| " + " | ".join(cells) + " |")
