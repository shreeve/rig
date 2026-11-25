#!/usr/bin/env python3
"""check-best.py LOG...: each log of trig-check.sh as one set: per pass the best (fewest ms) of its runs, the best
real time, and the lowest peak RSS (MB); then, over the sets, each best's spread (largest over smallest, less 1)."""
import re, sys
sets = []
for f in sys.argv[1:]:
    best, real, rss = {}, None, None
    for line in open(f):
        m = re.match(r"^(\S.*?)\s+([\d.]+) ms$", line)
        if m: k = m.group(1); v = float(m.group(2)); best[k] = min(best.get(k, v), v); continue
        m = re.search(r"([\d.]+) real", line) or re.search(r"Elapsed \(wall clock\) time.*: (?:(\d+):)?([\d.]+)", line)
        if m:
            v = float(m.group(1)) if "real" in line else float(m.group(1) or 0) * 60 + float(m.group(2)); real = v if real is None else min(real, v); continue
        m = re.search(r"(\d+)\s+maximum resident set size", line)
        if m: v = int(m.group(1)) / 2**20; rss = v if rss is None else min(rss, v); continue
        m = re.search(r"Maximum resident set size \(kbytes\): (\d+)", line)
        if m: v = int(m.group(1)) / 1024; rss = v if rss is None else min(rss, v)
    best["wall (s)"] = real; best["peak RSS (MB)"] = rss; sets.append(best)
keys = list(sets[0])
print("| pass | " + " | ".join("set %d" % (i + 1) for i in range(len(sets))) + " | spread |")
print("|---|" + "---:|" * (len(sets) + 1))
for k in keys:
    vs = [s.get(k) for s in sets]
    sp = (max(vs) / min(vs) - 1) * 100 if all(vs) and min(vs) > 0 else 0
    print("| %s | %s | %.1f%% |" % (k, " | ".join("%.1f" % v for v in vs), sp))
