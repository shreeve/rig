"""Time bench-json builds and external parsers the way tools/bench-json does:
calibrate each to ~MS ms, interleave REPS runs across all variants, keep the fastest."""
import os, re, subprocess, sys
S = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "test", "json", "data", "simd-json")
FILES = ["twitter", "canada", "citm_catalog", "gsoc-2018", "github_events"]
B = os.environ.get("BENCH_OUT", "")  # the --out directory of bench-json
R = os.path.join(S, "rust-bench")
Z = os.path.join(S, "zimdjson")
EXT = {
    "zimdjson-dom-fast": [Z + "/prog-dom-fast"],
    "zimdjson-dom-safe": [Z + "/prog-dom-safe"],
    "zimdjson-od-fast": [Z + "/prog-od-fast"],
    "serde_json": [R + "/target-native/release/serde_json_value"],
    "serde_json-fr": [R + "/target-native/release/serde_json_value_fr"],
    "simd-json-tape": [R + "/target-native/release/simdjson_tape"],
    "simd-json-value": [R + "/target-native/release/simdjson_value"],
    "simd-json-tape-generic": [R + "/target-generic/release/simdjson_tape"],
    "sonic-rs": [R + "/target-native/release/sonic_value"],
    "serde_json-generic": [R + "/target-generic/release/serde_json_value"],
}
variants = sys.argv[1].split(",")
reps = int(sys.argv[2]) if len(sys.argv) > 2 else 7
MS = 400

def args(f, v, n):
    if v in EXT: return EXT[v] + [os.path.join(DATA, f + ".json"), str(n)]
    exe = os.path.join(B, "%s-%s" % (f, v), "prog")
    return [exe] + (["tape"] if v.startswith("zig-tape") else []) + [str(n)]

def run(f, v, n):
    p = subprocess.run(args(f, v, n), capture_output=True, text=True)
    if p.returncode != 0: sys.exit("failed %s %s: %s%s" % (f, v, p.stdout, p.stderr))
    for line in (p.stdout + "\n" + p.stderr).splitlines():
        m = re.fullmatch(r"\s*(\d+) (\d+)\s*", line)
        if m: return int(m.group(1)), int(m.group(2))
    sys.exit("no timing from %s %s" % (f, v))

size = {f: os.path.getsize(os.path.join(DATA, f + ".json")) for f in FILES}
counts = {}
for f in FILES:
    for v in variants:
        run(f, v, 2)  # warm
        ns, _ = run(f, v, 3)
        counts[f, v] = max(2, int(MS * 1e6 / max(ns / 3, 1)))
best = {}
for _ in range(reps):
    for f in FILES:
        for v in variants:
            n = counts[f, v]
            t = run(f, v, n)[0] / n
            best[f, v] = min(best.get((f, v), t), t)
print("| file | bytes | " + " | ".join(variants) + " |")
print("|---|---:|" + "---:|" * len(variants))
for f in FILES:
    print("| %s | %d | %s |" % (f, size[f], " | ".join("%.0f" % (size[f] / best[f, v] * 1e3) for v in variants)))
print("\nMB/s, fastest of %d interleaved runs of about %d ms" % (reps, MS))
