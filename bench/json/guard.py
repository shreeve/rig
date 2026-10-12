#!/usr/bin/env python3
"""The JSON benchmark guard: builds rig-safe for the six corpus files and
compares its instructions retired per byte with bench/json/guard.txt. Any
file more than 2% above its baseline is a regression, and the guard exits
1. Instruction counts do not move with the machine's load, so the guard
runs on a busy machine; they come from `/usr/bin/time -l`, so it runs on
macOS only. After a change that is meant to move them (a new Zig, a
faster parser), `--update` writes the new baseline, which is committed.

usage: cpuq run --cores 2 --label rig:json -- bench/json/guard.py [--update]
"""
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DATA = os.path.join(ROOT, "test", "json", "data", "simd-json")
BASE = os.path.join(HERE, "guard.txt")
FILES = ["twitter", "twitterescaped", "canada", "citm_catalog", "gsoc-2018", "github_events"]
LIMIT = 1.02

def instructions(exe, n):
    p = subprocess.run(["/usr/bin/time", "-l", exe, str(n)], capture_output=True, text=True)
    m = re.search(r"(\d+)\s+instructions retired", p.stderr)
    if p.returncode != 0 or not m:
        sys.exit("guard: %s %d failed: %s" % (exe, n, p.stderr[-400:]))
    return int(m.group(1))

def per_byte(exe, size):
    # (N parses - 1 parse) / (N - 1) / bytes, N giving about 60 MB of
    # parsing, so the program's start costs nothing; the median of 5, since
    # a run's count can be off by several percent either way.
    n = max(21, int(6e7 / size))
    runs = sorted((instructions(exe, n) - instructions(exe, 1)) / (n - 1) / size for _ in range(5))
    return runs[2]

def main():
    if sys.platform != "darwin":
        sys.exit("guard: instruction counts come from macOS's /usr/bin/time -l")
    update = "--update" in sys.argv[1:]
    with tempfile.TemporaryDirectory() as out:
        subprocess.run([os.path.join(HERE, "bench-json"), "--out", out, "--build-only",
                        "--variants", "rig-safe", "--files", ",".join(FILES)], check=True)
        now = {f: per_byte(os.path.join(out, "%s-rig-safe" % f, "prog"),
                           os.path.getsize(os.path.join(DATA, f + ".json"))) for f in FILES}
    if update:
        with open(BASE, "w") as w:
            w.write("# instructions retired per byte, rig-safe; bench/json/guard.py --update writes it\n")
            for f in FILES:
                w.write("%s %.4f\n" % (f, now[f]))
        print("guard: wrote %s" % os.path.relpath(BASE, ROOT))
        return
    base = {}
    for line in open(BASE):
        if line.strip() and not line.startswith("#"):
            f, v = line.split()
            base[f] = float(v)
    bad = 0
    for f in FILES:
        ratio = now[f] / base[f]
        word = "more" if ratio >= 1 else "fewer"
        flag = "  REGRESSION" if ratio > LIMIT else ""
        bad += bool(flag)
        print("%-15s %.4f (baseline %.4f, %.1f%% %s instructions)%s" % (f, now[f], base[f], abs(ratio - 1) * 100, word, flag))
    sys.exit(1 if bad else 0)

main()
