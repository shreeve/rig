#!/usr/bin/env python3
"""Cycles and instructions per byte on Linux, from `perf stat`: (N parses
minus one parse) / (N - 1) / bytes, the least of 3 runs. Like ins.py, which
reads macOS's /usr/bin/time -l. Variants are bench-json --out builds in DIR
or the external parsers of time.py (serde_json, sonic-rs, ...).
usage: perf.py DIR FILES VARIANTS [CPU]   (CPU: taskset list, a P core; default 6)
On a hybrid Intel CPU the cpu_core PMU is read, so pin to a P core."""
import os, re, subprocess, sys
d, files, variants = sys.argv[1], sys.argv[2].split(","), sys.argv[3].split(",")
cpu = sys.argv[4] if len(sys.argv) > 4 else "6"
H = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(H, "..", "..", "..", "test", "json", "data", "simd-json")
R = os.path.join(H, "..", "rust-bench", "target-native", "release")
EXT = {"sonic-rs": "sonic_value", "serde_json": "serde_json_value", "simd-json-tape": "simdjson_tape"}
EV = os.environ.get("PERF_EVENTS", "cpu_core/cycles/,cpu_core/instructions/")
def cmd(f, v, n):
    if v in EXT: return [os.path.join(R, EXT[v]), os.path.join(DATA, f + ".json"), str(n)]
    return [os.path.join(d, "%s-%s" % (f, v), "prog"), str(n)]
def count(f, v, n):
    p = subprocess.run(["perf", "stat", "-x,", "-e", EV, "taskset", "-c", cpu] + cmd(f, v, n),
                       capture_output=True, text=True)
    r = {}
    for line in p.stderr.splitlines():
        t = line.split(",")
        if len(t) > 2 and t[0].isdigit(): r["cyc" if "cycles" in t[2] else "ins"] = int(t[0])
    if len(r) != 2: sys.exit("no counters: %s\n%s" % (cmd(f, v, n), p.stderr))
    return r
print("cycles/byte, instructions/byte (perf stat, cpu_core, CPU %s)" % cpu)
print("| file | variant | cycles/byte | instructions/byte | IPC |")
print("|---|---|---:|---:|---:|")
for f in files:
    size = os.path.getsize(os.path.join(DATA, f + ".json"))
    k = max(21, int(6e7 / size))
    for v in variants:
        best = None
        for _ in range(3):
            a, b = count(f, v, k), count(f, v, 1)
            c = ((a["cyc"] - b["cyc"]) / (k - 1) / size, (a["ins"] - b["ins"]) / (k - 1) / size)
            best = c if best is None or c[0] < best[0] else best
        print("| %s | %s | %.3f | %.3f | %.2f |" % (f, v, best[0], best[1], best[1] / best[0]))
