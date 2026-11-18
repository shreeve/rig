#!/usr/bin/env python3
"""s1118-fork-board.py ROUNDS OUT RIG RIG_AA RAYON: bench/fork's psum and qsort (fork.rig against its
Rayon twin, docs/history/records/2026-11/concurrency-bench-remeasure/fork), with an A/A arm (a byte
copy of Rig's binary), at 1 worker on P-core 6 (its sibling 7 idle) and at 12 workers on P-cores
0-11 (RIG_WORKERS and RAYON_NUM_THREADS set to match). Each round runs both configurations, in
alternating order, and the three arms in rotating order. Every sample is appended to OUT as it
ends (round config arm row ns check); the summary gives each row's median and range in ms, the
fastest, and the ratios of medians. Every run's check must agree."""
import os, statistics, subprocess, sys

rounds, out = int(sys.argv[1]), sys.argv[2]
arms = {"rig": sys.argv[3], "rig-aa": sys.argv[4], "rayon": sys.argv[5]}
cfgs = {"1 worker": ("6", "1"), "12 workers": ("0-11", "12")}
names, cn = list(arms), list(cfgs)
samples, checks = {}, {}
with open(out, "a") as log:
    for k in range(rounds):
        for c in (cn if k % 2 == 0 else cn[::-1]):
            cores, w = cfgs[c]
            env = dict(os.environ, RIG_WORKERS=w, RAYON_NUM_THREADS=w)
            for a in names[k % 3:] + names[:k % 3]:
                p = subprocess.run(["taskset", "-c", cores, arms[a]], capture_output=True, text=True,
                                   timeout=300, env=env, check=True)
                for row in p.stdout.splitlines():
                    name, ns, chk = row.split()
                    samples.setdefault((c, name, a), []).append(int(ns))
                    checks.setdefault(name, set()).add(chk)
                    log.write("%d %s %s %s %s %s\n" % (k + 1, c.replace(" ", "-"), a, name, ns, chk))
                log.flush()
        print("round %d done" % (k + 1), flush=True)

bad = {r: v for r, v in checks.items() if len(v) != 1}
print("checks:", {r: sorted(v) for r, v in checks.items()}, "DIFFER" if bad else "agree")
ms = lambda v: v / 1e6
med = lambda key: statistics.median(samples[key])
print("| config | row | Rig median (range) | A/A median (range) | Rayon median (range) | Rig fastest | Rayon fastest | Rig/Rayon, medians | A/A/Rig, medians |")
print("|---|---|---|---|---|---|---|---|---|")
for c in cn:
    for r in ("psum", "qsort"):
        cell = lambda a: "%.2f (%.2f-%.2f)" % (ms(med((c, r, a))), ms(min(samples[c, r, a])), ms(max(samples[c, r, a])))
        print("| %s | %s | %s | %s | %s | %.2f | %.2f | %.3f | %.3f |" % (
            c, r, cell("rig"), cell("rig-aa"), cell("rayon"), ms(min(samples[c, r, "rig"])),
            ms(min(samples[c, r, "rayon"])), med((c, r, "rig")) / med((c, r, "rayon")),
            med((c, r, "rig-aa")) / med((c, r, "rig"))))
print("n per cell:", {"%s/%s/%s" % k: len(v) for k, v in samples.items()})
