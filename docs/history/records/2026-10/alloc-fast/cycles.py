#!/usr/bin/env python3
"""cycles.py ROUNDS NAME=TRIG ...: one checker on core 6, interleaved (order
reversed every other round); per project and build the fewest user
cycles and the fastest wall, and the median of each."""
import os, re, subprocess, sys, statistics
PD = "/zfs/trig-pup/full/trig/misc/projects"
rounds = int(sys.argv[1]); specs = [s.split("=", 1) for s in sys.argv[2:]]
res = {}
for r in range(rounds):
    for proj in ["ts-pattern", "zod3"]:
        for name, exe in (specs if r % 2 == 0 else specs[::-1]):
            e = subprocess.run(["perf", "stat", "-e", "cycles:u", "--", "taskset", "-c", "6", exe, "-p", "tsconfig.trig.json", "--noEmit", "--checkers", "1"], cwd=os.path.join(PD, proj), capture_output=True, text=True).stderr
            c = sum(int(x.replace(",", "")) for x in re.findall(r"([\d,]+)\s+\S*cycles", e))
            w = float(re.search(r"([\d.]+) seconds time elapsed", e).group(1))
            res.setdefault((proj, name), []).append((c, w))
print("| project | build | cycles (user), fewest | median | wall s, fastest | median |")
print("|---|---|---:|---:|---:|---:|")
for proj in ["ts-pattern", "zod3"]:
    for name, _ in specs:
        v = res[(proj, name)]
        print("| %s | %s | %d | %d | %.3f | %.3f |" % (proj, name, min(x[0] for x in v), statistics.median(x[0] for x in v), min(x[1] for x in v), statistics.median(x[1] for x in v)))
