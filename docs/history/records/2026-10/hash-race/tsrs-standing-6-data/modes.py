#!/usr/bin/env python3
"""Peak RSS by mode: each variant's runs split at the largest gap in their
peak RSS when it exceeds 3% (the allocator's huge-page gate opened or not),
with each mode's run count, median peak RSS and median wall time.
Usage: modes.py times.txt"""
import statistics as st, sys
runs = {}
order = []
for line in open(sys.argv[1]):
    if " round=" not in line: continue
    f = line.split()
    d = dict(x.split("=", 1) for x in f[1:] if "=" in x)
    k = (f[0], d["v"])
    if k not in runs: runs[k] = []; order.append(k)
    runs[k].append((int(d["rss_kb"]) / 1024, int(d["duration_time"]) / 1e6))
print("| project | variant | low runs | low RSS MB | low wall ms | high runs | high RSS MB | high wall ms |")
print("|---|---|---:|---:|---:|---:|---:|---:|")
for k in order:
    r = sorted(runs[k])
    gaps = [(r[i + 1][0] - r[i][0], i) for i in range(len(r) - 1)]
    g, i = max(gaps)
    if g > 0.03 * r[i][0]:
        lo, hi = r[:i + 1], r[i + 1:]
    else:
        lo, hi = r, []
    cell = lambda m: (f"{len(m)} | {st.median(x[0] for x in m):.1f} | {st.median(x[1] for x in m):.1f}" if m else "0 | | ")
    print(f"| {k[0]} | {k[1]} | {cell(lo)} | {cell(hi)} |")
