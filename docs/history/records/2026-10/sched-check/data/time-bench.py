#!/usr/bin/env python3
"""Interleaved timing of the small benchmarks, fastest of N.
usage: time-bench.py ROUNDS OUT.md VARIANT ...   (the first is the reference)
Binaries are bench/<prog>-<variant>. knucleotide-fast reads fasta 25M on
stdin; fannkuchredux and -fast take 12; tasks reports hog (per step: /50)
and fanout from its own clock."""
import os, re, subprocess, sys, time
S = os.environ.get("S", os.getcwd())  # the study folder
FASTA = "/Users/shreeve/Data/Code/rig/compare/rig/benchmarksgame/.run/pop/fasta25m.txt"
PROGS = os.environ.get("PROGS", "knucleotide-fast,fannkuchredux,fannkuchredux-fast,tasks").split(",")
def run(prog, v):
    exe = "%s/bench/%s-%s" % (S, prog, v)
    args = [exe] + (["12"] if prog.startswith("fannkuch") else [])
    stdin = open(FASTA, "rb") if prog.startswith("knucleotide") else subprocess.DEVNULL
    t = time.perf_counter()
    p = subprocess.run(args, stdin=stdin, capture_output=True)
    w = time.perf_counter() - t
    if p.returncode != 0: sys.exit("%s failed" % exe)
    res = {"wall": w}
    if prog == "tasks":
        for line in p.stdout.decode().splitlines():
            f = line.split()
            if f[0] in ("hog", "fanout"): res[f[0]] = int(f[1]) / (50 if f[0] == "hog" else 1) / 1e9
    return res, (p.stdout if prog != "tasks" else b"")
rounds, out, vs = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
outs = {}
for prog in PROGS:
    for v in vs:
        o = run(prog, v)[1]
        if outs.setdefault(prog, o) != o: sys.exit("%s prints differently under %s" % (prog, v))
best = {}; raw = open(out + ".raw", "w")
LOAD_MAX = float(os.environ.get("LOAD_MAX", "1e9"))
for r in range(rounds):
    t_end = time.time() + 600
    while os.getloadavg()[0] >= LOAD_MAX and time.time() < t_end: time.sleep(5)
    for prog in PROGS:
        for v in (vs if r % 2 == 0 else vs[::-1]):
            res, _ = run(prog, v)
            for k, x in res.items():
                key = (prog, k, v)
                raw.write("%d\t%s\t%s\t%s\t%.6f\n" % (r, prog, k, v, x)); raw.flush()
                best[key] = min(best.get(key, 1e18), x)
    print("round %d of %d" % (r + 1, rounds), file=sys.stderr, flush=True)
with open(out, "w") as f:
    f.write("| measure | " + " | ".join(vs) + " |\n|---|" + "---:|" * len(vs) + "\n")
    for (prog, k) in sorted({(p, k) for (p, k, _) in best}):
        a = best[(prog, k, vs[0])]
        cells = []
        for v in vs:
            b = best[(prog, k, v)]
            unit = "%.1f ms" % (b * 1e3) if b > 1e-3 else "%.0f us" % (b * 1e6)
            cells.append(unit if v == vs[0] else "%s (%.1f%% %s)" % (unit, (a / b - 1) * 100 if a >= b else (b / a - 1) * 100, "faster" if a >= b else "slower"))
        f.write("| %s %s | %s |\n" % (prog, k, " | ".join(cells)))
print(open(out).read())
