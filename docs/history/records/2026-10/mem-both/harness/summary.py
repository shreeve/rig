#!/usr/bin/env python3
"""summary.py RESULTS: per test and arm, the best of the rounds (req/s
highest; xmalloc rtime and sh8bench seconds lowest), its ratio to main's
best, and the range of peak RSS (MB)."""
import sys, collections
rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    f = line.split()
    if len(f) != 5 or not f[0].isdigit():
        continue
    try:
        rows[(f[2], f[1])].append((int(f[3]), float(f[4])))
    except ValueError:
        pass
tests = sorted({t for t, _ in rows}, key=["kv64k", "kv32", "kv32c1000", "kvP16", "xmalloc", "sh8bench"].index)
arms = []
for _, a in rows:
    if a not in arms:
        arms.append(a)
arms.sort(key=lambda a: (a != "main", a))
for t in tests:
    higher = t.startswith("kv")
    best = lambda a: (max if higher else min)(v for _, v in rows[(t, a)])
    base = best("main") if (t, "main") in rows else None
    print(f"{t}  ({'req/s, highest' if higher else 'seconds, lowest'})")
    for a in arms:
        if (t, a) not in rows:
            continue
        b = best(a)
        rel = ""
        if base:
            r = b / base if higher else base / b
            rel = f"{abs(r - 1) * 100:.1f}% {'faster' if r >= 1 else 'slower'}"
        rss = [m / 1024 for m, _ in rows[(t, a)]]
        print(f"  {a:6} best {b:12.3f}  {rel:14}  rss {min(rss):6.1f}-{max(rss):6.1f} MB  n={len(rss)}")
