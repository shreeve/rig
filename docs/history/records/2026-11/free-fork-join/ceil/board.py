#!/usr/bin/env python3
"""board.py ROUNDS OUT.json NAME=PROGRAM...: each round runs every program
at 1 worker and at every core (CEIL_WORKERS, RIG_WORKERS and
RAYON_NUM_THREADS; WORKERS="1 12" overrides), the worker counts in
alternating order and the programs in rotating order. A program prints
`ROW NS CHECK` lines; every sample goes to OUT.json, and a check that
differs from the expected sum stops the board. PIN="1:6,12:0-11" runs each
worker count under `taskset -c` on those cores (Linux)."""
import json, os, subprocess, sys, time

rounds, out = int(sys.argv[1]), sys.argv[2]
progs = dict(a.split("=", 1) for a in sys.argv[3:])
names = list(progs)
counts = [int(x) for x in os.environ.get("WORKERS", "1 %d" % os.cpu_count()).split()]
pin = dict(x.split(":") for x in os.environ.get("PIN", "").split(",") if x)
expect = {"psum": "16760439056", "qsort": "4194304", "nil": "33554432"}
data = []  # (round, workers, program, row, ns, check)

def state(tag):
    print(tag, time.strftime("%H:%M:%S"), subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip(), flush=True)

state("start")
for k in range(rounds):
    line = []
    order = counts if k % 2 == 0 else counts[::-1]
    for w in order:
        r = k % len(names)
        env = dict(os.environ, CEIL_WORKERS=str(w), RIG_WORKERS=str(w), RAYON_NUM_THREADS=str(w))
        for n in names[r:] + names[:r]:
            cmd = (["taskset", "-c", pin[str(w)]] if str(w) in pin else []) + [progs[n]]
            o = subprocess.run(cmd, capture_output=True, text=True, timeout=600, check=True, env=env).stdout
            for row in o.splitlines():
                name, ns, chk = row.split()
                base = name.rstrip("0123456789")
                if base in expect and chk != expect[base]:
                    sys.exit("bad check: %s/%d %s %s" % (n, w, name, chk))
                data.append((k + 1, w, n, name, int(ns), chk))
                line.append("%s/%d %s %.2f" % (n, w, name, int(ns) / 1e6))
    print("round %d: %s" % (k + 1, ", ".join(line)), flush=True)
    json.dump(data, open(out, "w"))
state("end")
json.dump(data, open(out, "w"))
