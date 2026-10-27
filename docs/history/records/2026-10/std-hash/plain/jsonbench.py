#!/usr/bin/env python3
"""jsonbench.py ROUNDS: std.json's programs built by Rig main (json/base)
and map-stage (json/new), rig-safe and rig-fast, each corpus file timed
interleaved on core 8, the order alternating; fastest of ROUNDS; checksums
must agree."""
import subprocess, sys, os
W = "/zfs/worktrees/rig/std-hash/json"
rounds = int(sys.argv[1])
files = ["twitter", "twitterescaped", "canada", "citm_catalog", "gsoc-2018", "github_events"]
def run(exe, n):
    out = subprocess.run(["taskset", "-c", "8", exe, str(n)], capture_output=True, text=True, check=True).stdout.split()
    return int(out[0]), int(out[1])
for v in ["rig-safe", "rig-fast"]:
    print(v)
    for f in files:
        a = f"{W}/base/{f}-{v}/prog"; b = f"{W}/new/{f}-{v}/prog"
        ns, _ = run(a, 10)
        n = max(10, int(10 * 300e6 / max(ns, 1)))
        best = {a: 10**18, b: 10**18}; checks = set()
        for r in range(rounds):
            for exe in ([a, b] if r % 2 == 0 else [b, a]):
                t, c = run(exe, n); checks.add(c)
                best[exe] = min(best[exe], t)
        d = (best[a] - best[b]) / best[a] * 100
        word = f"{d:.1f}% faster" if d >= 0 else f"{-d:.1f}% slower"
        print(f"  {f:<16} n={n:<6} A {best[a]/n/1e3:9.1f} us  B {best[b]/n/1e3:9.1f} us  {word}  {'ok' if len(checks) == 1 else 'CHECK DIFFERS'}")
