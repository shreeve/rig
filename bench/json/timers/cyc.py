#!/usr/bin/env python3
"""Time builds in a bench-json --out dir: wall time and cycles (time -l).
usage: cyc.py DIR FILES VARIANTS [REPS] [MS]"""
import os, re, subprocess, sys
d, files, variants = sys.argv[1], sys.argv[2].split(","), sys.argv[3].split(",")
reps = int(sys.argv[4]) if len(sys.argv) > 4 else 11
ms = int(sys.argv[5]) if len(sys.argv) > 5 else 250
DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "test", "json", "data", "simd-json")
size = {f: os.path.getsize(os.path.join(DATA, f + ".json")) for f in files}
def run(f, v, n):
    exe = os.path.join(d, "%s-%s" % (f, v), "prog")
    p = subprocess.run(["/usr/bin/time", "-l", exe, str(n)], capture_output=True, text=True)
    ns, check = p.stdout.split()[:2]
    cyc = int(re.search(r"(\d+)\s+cycles elapsed", p.stderr).group(1))
    ins = int(re.search(r"(\d+)\s+instructions retired", p.stderr).group(1))
    return int(ns), cyc, ins, int(check)
counts, base_c, base_i = {}, {}, {}
for f in files:
    for v in variants:
        ns, c1, i1, chk = run(f, v, 2)
        n = max(4, int(ms * 1e6 / max(ns / 2, 1)))
        _, c0, i0, _ = run(f, v, 1)
        counts[f, v] = n
        base_c[f, v] = c0  # one parse plus setup
        base_i[f, v] = i0
best_ns, best_c, ins = {}, {}, {}
for _ in range(reps):
    for f in files:
        for v in variants:
            n = counts[f, v]
            ns, c, i, _ = run(f, v, n)
            t = ns / n
            cpp = (c - base_c[f, v]) / (n - 1)
            best_ns[f, v] = min(best_ns.get((f, v), t), t)
            best_c[f, v] = min(best_c.get((f, v), cpp), cpp)
            ins[f, v] = (i - base_i[f, v]) / (n - 1)
print("MB/s from wall time (fastest of %d) / bytes per kilocycle (fewest cycles) / instructions per byte" % reps)
print("| file | " + " | ".join(variants) + " |")
print("|---|" + "---:|" * len(variants))
for f in files:
    cells = []
    for v in variants:
        cells.append("%.0f / %.0f / %.2f" % (size[f] / best_ns[f, v] * 1e3, size[f] / best_c[f, v] * 1e3, ins[f, v] / size[f]))
    print("| %s | %s |" % (f, " | ".join(cells)))
