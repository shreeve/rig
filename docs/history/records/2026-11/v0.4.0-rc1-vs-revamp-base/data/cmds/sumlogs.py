#!/usr/bin/env python3
"""bench-sum.py DIR PREFIX: the concurrency bench logs PREFIX-BENCH-ARM-K.log in DIR (ARM base or rc1), each row's
median over the rounds per arm, and rc1 against base in words (time rows: lower is better; req/s: higher)."""
import glob, os, re, statistics, sys
d, pre = sys.argv[1], sys.argv[2]
for b in ("tasks", "actors", "net", "http"):
    vals = {}
    for arm in ("base", "rc1"):
        for f in sorted(glob.glob(os.path.join(d, "%s-%s-%s-*.log" % (pre, b, arm)))):
            for line in open(f):
                if b == "http":
                    m = re.match(r"rig-safe\s+(\d+)\s+(\d+) us\s+(\d+) us\s+([\d.]+) KiB", line)
                    if m:
                        for k, v, u in (("req/s", m.group(1), "req/s"), ("p50", m.group(2), "us"), ("p99", m.group(3), "us"), ("idle conn", m.group(4), "KiB")):
                            vals.setdefault((k, u), {}).setdefault(arm, []).append(float(v))
                else:
                    m = re.match(r"^(\w+)\s+([\d.]+) (\S+)/", line)
                    if m and m.group(1) not in ("rig",):
                        vals.setdefault((m.group(1), m.group(3)), {}).setdefault(arm, []).append(float(m.group(2)))
    for (k, u), a in vals.items():
        if "base" not in a or "rc1" not in a: continue
        mb, mr = statistics.median(a["base"]), statistics.median(a["rc1"])
        hib = k == "req/s"
        if mb == mr: w = "same"
        elif (mr < mb) != hib: w = "%.0f%% %s" % (abs(mr / mb - 1) * 100 if not hib else abs(mr / mb - 1) * 100, "faster" if k not in ("memory", "idle conn") else "less")
        else: w = "%.0f%% %s" % (abs(mr / mb - 1) * 100, "slower" if k not in ("memory", "idle conn") else "more")
        if k == "req/s": w = "%.0f%% %s" % (abs(mr / mb - 1) * 100, "more" if mr > mb else "fewer")
        print("| %s | %s | %g %s | %g %s | %s | n=%d/%d |" % (b, k, mb, u, mr, u, w, len(a["base"]), len(a["rc1"])))
# (best of the rounds: python3 sumlogs.py DIR PREFIX best)
