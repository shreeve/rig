#!/usr/bin/env python3
"""trigsum.py FILE... [--base NAME]: per label and build, the fastest of the
runs (time, cycles) and the least instructions, peak RSS, outputs, and each
build against the base: fastest against fastest, and the median of the
paired per-round differences in cycles."""
import sys, re, collections, statistics
args = sys.argv[1:]; base = "base"
if "--base" in args:
    i = args.index("--base"); base = args[i + 1]; del args[i:i + 2]
runs = collections.defaultdict(list)
for f in args:
    for line in open(f):
        m = re.match(r"(\S+) round=(\d+) build=(\S+) cycles=(\d+) instructions=(\d+) secs=([\d.]+) rss_kb=(\d+) same=(\d)", line)
        if m:
            l, r, b, c, i, s, rss, same = m.groups()
            runs[(l, b)].append((int(r), int(c), int(i), float(s), int(rss), int(same)))
def pct(a, b):
    d = (a - b) / a * 100
    return f"{d:.1f}% faster" if d >= 0 else f"{-d:.1f}% slower"
for label in sorted({l for l, _ in runs}):
    print(f"\n{label}")
    bl = runs.get((label, base), [])
    bc = {r: c for r, c, *_ in bl}
    tb = min((x[3] for x in bl), default=None); cb = min((x[1] for x in bl), default=None)
    ib = min((x[2] for x in bl), default=None); rb = max((x[4] for x in bl), default=None)
    for (l, b), rs in sorted(runs.items()):
        if l != label: continue
        t = min(x[3] for x in rs); c = min(x[1] for x in rs); i = min(x[2] for x in rs); rss = max(x[4] for x in rs)
        same = all(x[5] for x in rs)
        line = f"  {b:<8} n={len(rs):<3} time {t:.3f}s cycles {c/1e9:.4f}G instr {i/1e9:.4f}G rss {rss/1024:.1f}MB {'' if same else 'OUTPUT DIFFERS'}"
        if b != base and bl:
            diffs = [(bc[r] - c2) / bc[r] * 100 for r, c2, *_ in rs if r in bc]
            line += f" | time {pct(tb, t)}, cycles {pct(cb, c)} (median pair {statistics.median(diffs):+.1f}%), instr {(i-ib)/ib*100:+.2f}%, rss {(rss-rb)/rb*100:+.1f}%"
        print(line)
