#!/usr/bin/env python3
"""sweep.py ROUNDS MB...: the probe trig (RIG_PF_MB=MB, 0 = no size rule, as main) on
ts-pattern and zod3 at Trig's default checkers, interleaved; per case the fastest
wall of ROUNDS with its user time, least sys, fewest page faults, largest RSS."""
import os, re, subprocess, sys
PD = "/zfs/trig-pup/full/trig/misc/projects"
EXE = "/zfs/worktrees/rig/prefault-large/bin/trig-probe"
rounds = int(sys.argv[1]); mbs = sys.argv[2:]
best = {}; loads = []
for r in range(rounds):
    loads.append(open("/proc/loadavg").read().split()[0])
    for proj in ["ts-pattern", "zod3"]:
        for mb in mbs:
            env = dict(os.environ, RIG_PF_MB=mb)
            p = subprocess.run(["perf", "stat", "-e", "page-faults", "--", "/usr/bin/time", "-f", "TIME %M", EXE, "-p", "tsconfig.trig.json", "--noEmit"], cwd=os.path.join(PD, proj), env=env, capture_output=True, text=True)
            e = p.stderr
            m = int(re.search(r"TIME (\d+)", e).group(1))
            f = int(re.search(r"([\d,]+)\s+page-faults", e).group(1).replace(",", ""))
            w = float(re.search(r"([\d.]+) seconds time elapsed", e).group(1))
            u = float(re.search(r"([\d.]+) seconds user", e).group(1))
            s = float(re.search(r"([\d.]+) seconds sys", e).group(1))
            b = best.setdefault((proj, mb), [1e9, 1e9, 0, 10**12, 0])
            if w < b[0]: b[0], b[2] = w, u
            b[1] = min(b[1], s); b[3] = min(b[3], f); b[4] = max(b[4], m)
print("load at round starts: " + " ".join(loads))
print("| project | MB | wall s | sys s | user s | page faults | RSS MB |")
print("|---|---:|---:|---:|---:|---:|---:|")
for proj in ["ts-pattern", "zod3"]:
    for mb in mbs:
        b = best[(proj, mb)]
        print("| %s | %s | %.3f | %.3f | %.3f | %d | %.0f |" % (proj, mb, b[0], b[1], b[2], b[3], b[4] / 1024))
