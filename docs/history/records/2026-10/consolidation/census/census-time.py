#!/usr/bin/env python3
"""census-time ROUNDS NAME=TRIG ...: Trig's six projects, each build once a
round, interleaved; per project and build, the fastest wall, the fewest user
cycles and instructions (perf stat), and the peak RSS (wait4, fewest of 3
more runs), on core $CORE (6). It stops if the builds print differently."""
import os, subprocess, sys, time
P = "/zfs/trig-pup/full/trig/misc/projects"
PROJ = os.environ.get("TRIG_PROJECTS", "ts-pattern,zod3,mitt,neverthrow,superstruct,tiny-invariant").split(",")
rounds = int(sys.argv[1]); specs = [s.split("=", 1) for s in sys.argv[2:]]
names = [n for n, _ in specs]; exe = dict(specs)
best = {}
def one(n, proj):
    cmd = ["taskset", "-c", os.environ.get("CORE", "6"), "perf", "stat", "-x,", "-e", "cycles:u,instructions:u", exe[n], "-p", "tsconfig.trig.json", "--noEmit"]
    t = time.perf_counter()
    p = subprocess.Popen(cmd, cwd=os.path.join(P, proj), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, err = p.communicate(); wall = time.perf_counter() - t
    cyc = ins = 0
    for line in err.splitlines():
        f = line.split(",")
        if len(f) > 2 and "cycles" in f[2] and f[0].isdigit(): cyc += int(f[0])
        if len(f) > 2 and "instructions" in f[2] and f[0].isdigit(): ins += int(f[0])
    return wall, cyc, ins, out
def rss(n, proj):
    p = subprocess.Popen(["taskset", "-c", os.environ.get("CORE", "6"), exe[n], "-p", "tsconfig.trig.json", "--noEmit"], cwd=os.path.join(P, proj), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _, _, ru = os.wait4(p.pid, 0)
    return ru.ru_maxrss
outs = {}
for proj in PROJ:
    for n in names:
        outs[n] = one(n, proj)[3]
    if len(set(outs.values())) != 1: sys.exit("census-time: %s prints differently" % proj)
for r in range(rounds):
    for proj in PROJ:
        for n in names:
            w, c, i, _ = one(n, proj); k = (proj, n)
            b = best.get(k, (9e9, 1 << 62, 1 << 62))
            best[k] = (min(b[0], w), min(b[1], c), min(b[2], i))
    print("round %d of %d" % (r + 1, rounds), file=sys.stderr, flush=True)
mem = {}
for r in range(3):
    for proj in PROJ:
        for n in names:
            mem[(proj, n)] = min(mem.get((proj, n), 1 << 62), rss(n, proj))
def pct(a, b): s = a / b; return "%.1f%% %s" % (abs(s - 1) * 100, "faster" if s >= 1 else "slower")
def less(a, b): s = b / a; return "%.1f%% %s" % (abs(s - 1) * 100, "fewer" if s <= 1 else "more")
ref = names[0]
print("| project | build | wall | user cycles | instructions | peak RSS | wall vs %s | cycles vs %s | RSS vs %s |" % (ref, ref, ref))
print("|---|---|---:|---:|---:|---:|---:|---:|---:|")
for proj in PROJ:
    for n in names:
        w, c, i = best[(proj, n)]; m = mem[(proj, n)]
        w0, c0, i0 = best[(proj, ref)]; m0 = mem[(proj, ref)]
        vs = ("", "", "") if n == ref else (pct(w0, w), pct(c0, c), less(m0, m))
        print("| %s | %s | %.3f s | %.3fG | %.3fG | %.1f MB | %s | %s | %s |" % (proj, n, w, c / 1e9, i / 1e9, m / 1024, *vs))
