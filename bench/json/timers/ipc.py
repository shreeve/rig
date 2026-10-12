#!/usr/bin/env python3
"""Instructions and cycles per byte, and their ratio (IPC), for parsers
that take [FILE] N, over the six corpus files.

usage: ipc.py NAME=COMMAND ...

COMMAND is the program and its arguments before N; `{file}` stands for
the corpus file's path and `{f}` for its name, for example
`std.json=$OUT/{f}-rig-safe/prog` (a `bench-json --out` build) or
`sonic-rs=rust-bench/target-native/release/sonic_value {file}`. Each
count is (N parses - 1) / (N - 1) / bytes, the median of 5, from macOS
`/usr/bin/time -l`. Instructions do not depend on load, though one run
can be off by several percent either way; cycles do, since the counter
follows the core the program runs on and its clock, so judge time by
`time.py`'s interleaved runs.
"""
import os, re, subprocess, sys

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "test", "json", "data", "simd-json")
FILES = ["twitter", "twitterescaped", "canada", "citm_catalog", "gsoc-2018", "github_events"]

def counters(cmd, n):
    p = subprocess.run(["/usr/bin/time", "-l"] + cmd + [str(n)], capture_output=True, text=True)
    if p.returncode != 0: sys.exit("%s failed: %s" % (" ".join(cmd), p.stderr[-400:]))
    return (int(re.search(r"(\d+)\s+instructions retired", p.stderr).group(1)),
            int(re.search(r"(\d+)\s+cycles elapsed", p.stderr).group(1)))

def main():
    if len(sys.argv) < 2: sys.exit(__doc__)
    progs = [a.split("=", 1) for a in sys.argv[1:]]
    print("| file | " + " | ".join("%s instructions/byte | cycles/byte | IPC" % n for n, _ in progs) + " |")
    print("|---|" + "---:|---:|---:|" * len(progs))
    for f in FILES:
        path = os.path.join(DATA, f + ".json")
        size = os.path.getsize(path)
        n = max(21, int(6e7 / size))
        cells = []
        for _, tmpl in progs:
            cmd = [x.replace("{file}", path).replace("{f}", f) for x in tmpl.split()]
            ins, cyc = [], []
            for _ in range(5):
                i1, c1 = counters(cmd, 1)
                i2, c2 = counters(cmd, n)
                ins.append((i2 - i1) / (n - 1) / size)
                cyc.append((c2 - c1) / (n - 1) / size)
            i, c = sorted(ins)[2], sorted(cyc)[2]
            cells.append("%.2f | %.3f | %.1f" % (i, c, i / c))
        print("| %s | %s |" % (f, " | ".join(cells)), flush=True)

main()
