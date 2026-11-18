#!/usr/bin/env python3
"""s1118-json-board.py BENCH_JSON_DIR BENCH_OUT PIN REPS OUT VARIANTS: bench/json/timers/time.py's method
(each program calibrated to about MS=400 ms of parsing, a warm run first, REPS interleaved runs) with
every sample kept: the variant order rotates each round, each sample is appended to OUT as it ends
(round file variant MB/s), and the summary gives MB/s per file as the fastest (time.py's figure) and
the median with its range, plus geomeans. Rig's builds are BENCH_OUT/<file>-<variant>/prog; the
competitors are time.py's EXT table, under BENCH_JSON_DIR. Every run is pinned to PIN by taskset."""
import math, os, re, statistics, subprocess, sys

J, B, PIN, reps, out = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
variants = sys.argv[6].split(",")
DATA = os.path.join(J, "check", "data", "simd-json")
FILES = ["twitter", "twitterescaped", "canada", "citm_catalog", "gsoc-2018", "github_events"]
R, C, G = J + "/rust-bench", J + "/cbench", J + "/gobench"
EXT = {
    "simdjson-dom": [C + "/prog-simdjson-dom"],
    "yyjson": [C + "/prog-yyjson"],
    "go-v2": [G + "/prog-go", "any"],
    "serde_json": [R + "/target-native/release/serde_json_value"],
    "simd-json-tape": [R + "/target-native/release/simdjson_tape"],
    "sonic-rs": [R + "/target-native/release/sonic_value"],
}
MS = int(os.environ.get("MS", "400"))

def args(f, v, n):
    pre = ["taskset", "-c", PIN]
    if v in EXT: return pre + EXT[v] + [os.path.join(DATA, f + ".json"), str(n)]
    return pre + [os.path.join(B, "%s-%s" % (f, v), "prog"), str(n)]

def run(f, v, n):
    p = subprocess.run(args(f, v, n), capture_output=True, text=True, timeout=120)
    if p.returncode != 0: sys.exit("failed %s %s: %s%s" % (f, v, p.stdout, p.stderr))
    for line in (p.stdout + "\n" + p.stderr).splitlines():
        m = re.fullmatch(r"\s*(\d+) (\d+)\s*", line)
        if m: return int(m.group(1)), int(m.group(2))
    sys.exit("no timing from %s %s" % (f, v))

size = {f: os.path.getsize(os.path.join(DATA, f + ".json")) for f in FILES}
counts = {}
for f in FILES:
    for v in variants:
        run(f, v, 2)
        ns, _ = run(f, v, 3)
        counts[f, v] = max(2, int(MS * 1e6 / max(ns / 3, 1)))
print("calibrated", flush=True)
mbs = {}
with open(out, "a") as log:
    for k in range(reps):
        order = variants[k % len(variants):] + variants[:k % len(variants)]
        for f in FILES:
            for v in order:
                n = counts[f, v]
                t = run(f, v, n)[0] / n
                x = size[f] / t * 1e3
                mbs.setdefault((f, v), []).append(x)
                log.write("%d %s %s %.1f\n" % (k + 1, f, v, x))
            log.flush()
        print("round %d done" % (k + 1), flush=True)

geo = lambda xs: math.exp(sum(map(math.log, xs)) / len(xs))
for title, stat in (("fastest", max), ("median", statistics.median)):
    print("\nMB/s, %s of %d interleaved runs of about %d ms, pinned to CPU %s" % (title, reps, MS, PIN))
    print("| file | bytes | " + " | ".join(variants) + " |")
    print("|---|---:|" + "---:|" * len(variants))
    for f in FILES:
        print("| %s | %d | %s |" % (f, size[f], " | ".join("%.0f" % stat(mbs[f, v]) for v in variants)))
    print("| geomean | | %s |" % " | ".join("%.0f" % geo([stat(mbs[f, v]) for f in FILES]) for v in variants))
print("\nranges (min-max MB/s):")
for f in FILES:
    print(f, "; ".join("%s %.0f-%.0f" % (v, min(mbs[f, v]), max(mbs[f, v])) for v in variants))
