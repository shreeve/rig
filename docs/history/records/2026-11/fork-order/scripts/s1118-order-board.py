#!/usr/bin/env python3
"""s1118-order-board.py ROUNDS OUT NAME=EXE...: bench/fork's psum and qsort for any number of arms (the fork-order
record's four programs plus an A/A copy), at 1 worker on P-core 6 (sibling 7 idle) and 12 workers on P-cores 0-11
(RIG_WORKERS and RAYON_NUM_THREADS set to match). Each round runs both configurations in alternating order and the
arms in rotating order. Every sample is appended to OUT; the summary gives medians, ranges and each arm's ratio to
the first arm and to 'rayon'. Every run's check must agree."""
import os, statistics, subprocess, sys
rounds, out = int(sys.argv[1]), sys.argv[2]
arms = dict(a.split("=", 1) for a in sys.argv[3:])
cfgs = {"1 worker": ("6", "1"), "12 workers": ("0-11", "12")}
names, cn = list(arms), list(cfgs)
samples, checks = {}, {}
with open(out, "a") as log:
    for k in range(rounds):
        for c in (cn if k % 2 == 0 else cn[::-1]):
            cores, w = cfgs[c]
            env = dict(os.environ, RIG_WORKERS=w, RAYON_NUM_THREADS=w)
            n = len(names)
            for a in names[k % n:] + names[:k % n]:
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
print("| config | row | arm | median ms (range) | fastest | against rayon | against " + names[0] + " |")
print("|---|---|---|---|---|---|---|")
for c in cn:
    for r in ("psum", "qsort"):
        for a in names:
            v = samples[c, r, a]
            print("| %s | %s | %s | %.2f (%.2f-%.2f) | %.2f | %.3f | %.3f |" % (c, r, a, ms(med((c, r, a))), ms(min(v)), ms(max(v)),
                  ms(min(v)), med((c, r, a)) / med((c, r, "rayon")), med((c, r, a)) / med((c, r, names[0]))))
