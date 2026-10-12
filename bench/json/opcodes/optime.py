#!/usr/bin/env python3
"""Interleaved timing of build.py variants: wall time and cycles.

usage: optime.py OUT FILES VARIANTS [REPS] [MS]

Each run parses the file N times (N set for about MS ms, default 300).
Runs are interleaved across every file and variant, REPS rounds (default
15), and each keeps its fastest. Cycles per parse come from /usr/bin/time -l
on macOS and `perf stat -e cycles` on Linux, as (cycles of N parses -
cycles of one) / (N - 1), the fewest kept; they leave out time the
program was descheduled. The first variant is the baseline: every other
cell says how much faster or slower it is, in time and in cycles.
Set PIN=CPU on Linux to pin every run to one core (taskset).
"""
import json, os, platform, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
DATA = os.path.join(ROOT, "test", "json", "data", "simd-json")
MAC = platform.system() == "Darwin"


def run(exe, n):
    pin = ["taskset", "-c", os.environ["PIN"]] if os.environ.get("PIN") and not MAC else []
    if MAC:
        cmd = ["/usr/bin/time", "-l", exe, str(n)]
    else:
        cmd = pin + ["perf", "stat", "-x", ",", "-e", "cycles,instructions", exe, str(n)]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit("failed: %s\n%s%s" % (" ".join(cmd), p.stdout, p.stderr))
    ns, check = p.stdout.split()[:2]
    if MAC:
        cyc = int(re.search(r"(\d+)\s+cycles elapsed", p.stderr).group(1))
        ins = int(re.search(r"(\d+)\s+instructions retired", p.stderr).group(1))
    else:
        vals = {}
        for line in p.stderr.splitlines():
            f = line.split(",")
            if len(f) > 2 and f[0].strip().isdigit():
                vals[f[2].split(":")[0]] = int(f[0])
        cyc, ins = vals.get("cycles", 0), vals.get("instructions", 0)
    return int(ns), cyc, ins, int(check)


def pct(base, new):
    """How much faster `new` is than `base` (times: lower is better)."""
    r = base / new - 1
    if abs(r) < 0.005:
        return "0%"
    return "%.0f%% %s" % (abs(r) * 100, "faster" if r > 0 else "slower")


def main():
    out, files, variants = sys.argv[1], sys.argv[2].split(","), sys.argv[3].split(",")
    reps = int(sys.argv[4]) if len(sys.argv) > 4 else 15
    ms = int(sys.argv[5]) if len(sys.argv) > 5 else 300
    exe = lambda f, v: os.path.join(out, "%s-%s" % (f, v), "prog")
    size = {f: os.path.getsize(os.path.join(DATA, f + ".json")) for f in files}
    counts, one_c, one_i, checks = {}, {}, {}, {}
    for f in files:
        for v in variants:
            ns, _, _, chk = run(exe(f, v), 3)
            checks.setdefault(f, chk)
            if chk != checks[f]:
                sys.exit("%s %s: check %d, not %d" % (f, v, chk, checks[f]))
            counts[f, v] = max(4, int(ms * 1e6 / max(ns / 3, 1)))
            _, c0, i0, _ = run(exe(f, v), 1)
            one_c[f, v], one_i[f, v] = c0, i0
    best_t, best_c, ins = {}, {}, {}
    for r in range(reps):
        for f in files:
            for v in variants:
                n = counts[f, v]
                ns, c, i, _ = run(exe(f, v), n)
                t = ns / n
                cp = (c - one_c[f, v]) / (n - 1)
                best_t[f, v] = min(best_t.get((f, v), t), t)
                best_c[f, v] = min(best_c.get((f, v), cp), cp)
                ins[f, v] = (i - one_i[f, v]) / (n - 1)
        print("round %d of %d" % (r + 1, reps), file=sys.stderr, flush=True)
    b = variants[0]
    print("MB/s (fastest of %d interleaved runs) and the change against `%s` in time / in cycles; "
          "instructions per byte last" % (reps, b))
    print("| file | " + " | ".join(variants) + " |")
    print("|---|" + "---:|" * len(variants))
    for f in files:
        cells = []
        for v in variants:
            mbs = size[f] / best_t[f, v] * 1e3
            ipb = ins[f, v] / size[f]
            if v == b:
                cells.append("%.0f (%.2f i/B)" % (mbs, ipb))
            else:
                cells.append("%.0f: %s / %s (%.2f i/B)" % (mbs, pct(best_t[f, b], best_t[f, v]),
                                                          pct(best_c[f, b], best_c[f, v]), ipb))
        print("| %s | %s |" % (f, " | ".join(cells)))
    raw = {"%s %s" % k: {"ns": best_t[k], "cycles": best_c[k], "ins": ins[k], "bytes": size[k[0]]} for k in best_t}
    if os.environ.get("JSON_OUT"):
        json.dump(raw, open(os.environ["JSON_OUT"], "w"), indent=1)


main()
