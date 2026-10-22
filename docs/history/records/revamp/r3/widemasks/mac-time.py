#!/usr/bin/env python3
"""ws_stage on the Mac, for the owner-approved exclusive window: main's
build (ws_main), the branch's (ws_new), and the Zig reference with the
study's best NEON mask (ws_ref best), interleaved, 21 rounds per file.
Run as
  cpuq run --exclusive --label rig:bench --note "#249 widemasks" -- python3 mac-time.py

Every run is appended to mac-time.log as it ends (round, file, command,
ps/64B, checksum). The summary judges by medians: each command's median
with a 95% interval for it (order statistics, ranks 6 and 16 of 21), and
the paired per-round ratio of each command to ws_main (same round, so
drift cancels), with its median and interval. The fastest is shown too."""
import os, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
D = "/Users/shreeve/Data/Code/rig/test/json/data/simdjson"
ROUNDS = 21
LO, HI = 5, 15  # 0-based ranks 6 and 16 of 21: a 95% interval for the median
FILES = (("citm_catalog.json", 4000), ("twitter.json", 10000))
CMDS = (["./ws_main"], ["./ws_new"], ["./ws_ref", "best"])
os.chdir(HERE)
log = open("mac-time.log", "a", buffering=1)

def note(s):
    print(s, flush=True)
    log.write(s + "\n")

def run(cmd):
    out = subprocess.run(cmd, capture_output=True, text=True)
    f = (out.stdout + out.stderr).strip().split("\n")[-1].split()
    return int(f[0]), f[-1]

def interval(xs):
    s = sorted(xs)
    return s[LO], statistics.median(s), s[HI]

note(f"# {time.strftime('%Y-%m-%d %H:%M:%S')} {subprocess.run(['uptime'], capture_output=True, text=True).stdout.strip()}")
results = {}
for f, n in FILES:
    path = os.path.join(D, f)
    res = {" ".join(c): [] for c in CMDS}
    sums = {k: set() for k in res}
    for r in range(ROUNDS):
        for c in CMDS:
            ps, check = run(c + [path, str(n)])
            k = " ".join(c)
            res[k].append(ps); sums[k].add(check)
            note(f"{r}\t{f}\t{k}\t{ps}\t{check}")
    results[f] = (res, sums)

note(f"# {time.strftime('%Y-%m-%d %H:%M:%S')} {subprocess.run(['uptime'], capture_output=True, text=True).stdout.strip()}")
note("# ps/64B: median [95% interval] fastest; ratio to ws_main per round: median [95% interval]")
for f, (res, sums) in results.items():
    base = res["./ws_main"]
    for k, xs in res.items():
        lo, med, hi = interval(xs)
        ratios = [x / b for x, b in zip(xs, base)]
        rlo, rmed, rhi = interval(ratios)
        note(f"{f:18} {k:14} {med:7.0f} [{lo}, {hi}] fastest {min(xs)}   x main {rmed:.3f} [{rlo:.3f}, {rhi:.3f}]   sums {sorted(sums[k])}")
