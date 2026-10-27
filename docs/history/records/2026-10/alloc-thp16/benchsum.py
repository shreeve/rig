#!/usr/bin/env python3
"""benchsum.py LOG: the runtime benches' best per build (fewest ns, most
req/s, lowest latencies) and each build against the first."""
import re, sys
best = {}; cur = None; order = []; builds = []
for line in open(sys.argv[1]):
    m = re.match(r"== (\S+) (\S+) round", line)
    if m:
        cur = (m.group(1), m.group(2))
        if m.group(2) not in builds: builds.append(m.group(2))
        continue
    if cur is None: continue
    vals = []
    m = re.match(r"rig-fast\s+(\d+)\s+(\d+) us\s+(\d+) us\s+([\d.]+) KiB", line)
    if m:
        vals = [("req/s", float(m.group(1)), "req/s", True), ("p50", float(m.group(2)), "us", False), ("p99", float(m.group(3)), "us", False), ("idle conn", float(m.group(4)), "KiB", False)]
    else:
        m = re.match(r"(\w+)\s+([\d.]+) (\S+)\s*$", line)
        if m and m.group(1) != "rig": vals = [(m.group(1), float(m.group(2)), m.group(3), False)]
    for name, v, unit, hib in vals:
        k = (cur[0], name)
        if k not in order: order.append(k)
        d = best.setdefault(k, {"unit": unit, "hib": hib})
        d[cur[1]] = v if cur[1] not in d else (max(d[cur[1]], v) if hib else min(d[cur[1]], v))
b0 = builds[0]
print("| bench | case | unit | " + " | ".join(builds) + " | " + " | ".join(f"{b} vs {b0}" for b in builds[1:]) + " |")
print("|---|---|---|" + "---:|" * (2 * len(builds) - 1))
for k in order:
    d = best[k]
    def rel(b):
        r = d[b] / d[b0]
        if r == 1: return "same"
        return "%.1f%% %s" % (abs(r - 1) * 100 if not d["hib"] else abs(r - 1) * 100, ("faster" if (r > 1) == d["hib"] else "slower") if k[1] not in ("memory", "idle conn") else ("more" if r > 1 else "less"))
    print("| %s | %s | %s | " % (k[0], k[1], d["unit"]) + " | ".join("%g" % d[b] for b in builds) + " | " + " | ".join(rel(b) for b in builds[1:]) + " |")
