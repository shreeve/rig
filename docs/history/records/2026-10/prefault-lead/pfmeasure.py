#!/usr/bin/env python3
"""pfmeasure.py ROUNDS NAME=TRIG ...: each trig on ts-pattern and zod3, at
one checker (pinned to core 6) and at all cores, interleaved; per case the
fastest wall of ROUNDS with its sys time, and the fewest page faults (traps)."""
import os, re, subprocess, sys
PD = "/zfs/trig-pup/full/trig/misc/projects"
PROJ = ["ts-pattern", "zod3"]
rounds = int(sys.argv[1])
specs = [s.split("=", 1) for s in sys.argv[2:]]
MODES = [("1", ["taskset", "-c", "6"], ["--checkers", "1"]), ("all", [], [])]
best = {}
def one(exe, proj, pin, extra):
    cmd = ["perf", "stat", "-e", "page-faults", "--"] + ["/usr/bin/time", "-f", "TIME %M"] + pin + [exe, "-p", "tsconfig.trig.json", "--noEmit"] + extra
    p = subprocess.run(cmd, cwd=os.path.join(PD, proj), capture_output=True, text=True)
    e = p.stderr
    rss = int(re.search(r"TIME (\d+)", e).group(1))
    f = int(re.search(r"([\d,]+)\s+page-faults", e).group(1).replace(",", ""))
    w = float(re.search(r"([\d.]+) seconds time elapsed", e).group(1))
    u = float(re.search(r"([\d.]+) seconds user", e).group(1))
    s = float(re.search(r"([\d.]+) seconds sys", e).group(1))
    return w, s, u, f, rss, p.stdout
outs = {}
for r in range(rounds):
    for proj in PROJ:
        for mode, pin, extra in MODES:
            for name, exe in specs:
                w, s, u, f, m, out = one(exe, proj, pin, extra)
                k = (proj, mode)
                if k in outs and outs[k] != out: sys.exit("outputs differ: %s %s %s" % (proj, mode, name))
                outs[k] = out
                b = best.setdefault((proj, mode, name), [1e9, 0, 0, 10**12, 0])
                if w < b[0]: b[0], b[2] = w, u
                b[1] = min(b[1] or 1e9, s); b[3] = min(b[3], f); b[4] = max(b[4], m)
    print("round %d" % (r + 1), file=sys.stderr, flush=True)
print("| project | checkers | build | wall s | sys s | user s | page faults (traps) | max RSS MB |")
print("|---|---|---|---:|---:|---:|---:|---:|")
for proj in PROJ:
    for mode, _, _ in MODES:
        for name, _ in specs:
            b = best[(proj, mode, name)]
            print("| %s | %s | %s | %.3f | %.3f | %.3f | %d | %.0f |" % (proj, mode, name, b[0], b[1], b[2], b[3], b[4] / 1024))
