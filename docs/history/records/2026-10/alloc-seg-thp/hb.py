#!/usr/bin/env python3
"""hb.py REPS NAME=EXE ...: bench/hash's map.rig, each built rig-fast
(`bench-hash --variants rig-fast --build-only`) by another Rig: REPS runs
of each, interleaved, the fastest of each row, ns per operation, and each
build's time against the first's; then, REPS times interleaved, peak RSS
of `mem` (one Map[Int, Int] of 4M keys) and `mem0` (the keys alone) by
wait4, the least of each and bytes per entry, as bench-hash --mem."""
import math, os, subprocess, sys
reps = int(sys.argv[1]); specs = [s.split("=", 1) for s in sys.argv[2:]]
best = {n: {} for n, _ in specs}
for r in range(reps):
    for n, exe in (specs if r % 2 == 0 else specs[::-1]):
        p = subprocess.run([exe], check=True, capture_output=True, text=True)
        for line in (p.stdout + p.stderr).splitlines():
            k, op, ns, chk = line.split()
            best[n][(k, op)] = min(int(ns), best[n].get((k, op), int(ns)))
base = specs[0][0]
rows = list(best[base])
print("| keys | op | " + " | ".join(n for n, _ in specs) + " | " + " | ".join(n + "/" + base for n, _ in specs[1:]) + " |")
print("|---|---|" + "---:|" * (2 * len(specs) - 1))
for k in rows:
    print("| %s | %s | " % k + " | ".join("%.2f" % (best[n][k] / 1e6) for n, _ in specs) + " | " + " | ".join("%.3f" % (best[n][k] / best[base][k]) for n, _ in specs[1:]) + " |")
for n, _ in specs[1:]:
    g = math.exp(sum(math.log(best[n][k] / best[base][k]) for k in rows) / len(rows))
    big = [k for k in rows if k[0].endswith("000000") and int(''.join(c for c in k[0] if c.isdigit())) >= 3000000]
    gb = math.exp(sum(math.log(best[n][k] / best[base][k]) for k in big) / len(big)) if big else float("nan")
    print("\n%s against %s: geometric mean %.3f over %d rows; %.3f over the %d rows of 3M and 4M keys" % (n, base, g, len(rows), gb, len(big)))
def peak(exe, arg):
    p = subprocess.Popen([exe, arg], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _, st, use = os.wait4(p.pid, 0)
    assert st == 0
    return use.ru_maxrss * (1 if sys.platform == "darwin" else 1024)
mem = {n: [] for n, _ in specs}
for r in range(reps):
    for n, exe in specs:
        mem[n].append((peak(exe, "mem"), peak(exe, "mem0")))
print("\n| build | mem MB (least) | mem0 MB (least) | mem - mem0 MB | bytes per entry |")
print("|---|---:|---:|---:|---:|")
for n, _ in specs:
    a = min(m for m, _ in mem[n]); b = min(z for _, z in mem[n])
    print("| %s | %.1f | %.1f | %.1f | %.1f |" % (n, a / 2**20, b / 2**20, (a - b) / 2**20, (a - b) / 4e6))
