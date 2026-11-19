#!/usr/bin/env python3
"""board.py ROUNDS OUT.json NAME=PROGRAM...: each round runs every program
at 1 worker and at every core (RIG_WORKERS and RAYON_NUM_THREADS), the
worker counts in alternating order and the programs in rotating order.
A program prints `psum NS CHECK` and `qsort NS CHECK`, one psum and one
qsort a process; every sample goes to OUT.json."""
import json, os, subprocess, sys, time

rounds, out = int(sys.argv[1]), sys.argv[2]
progs = dict(a.split("=", 1) for a in sys.argv[3:])
names, cores = list(progs), os.cpu_count()
data = []  # (round, workers, program, row, ns, check)

def state(tag):
    print(tag, time.strftime("%H:%M:%S"), subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip(), flush=True)

state("start")
for k in range(rounds):
    line = []
    for w in ([1, cores] if k % 2 == 0 else [cores, 1]):
        r = k % len(names)
        env = dict(os.environ, RIG_WORKERS=str(w), RAYON_NUM_THREADS=str(w))
        for n in names[r:] + names[:r]:
            o = subprocess.run([progs[n]], capture_output=True, text=True, timeout=600, check=True, env=env).stdout
            for row in o.splitlines():
                name, ns, chk = row.split()
                data.append((k + 1, w, n, name, int(ns), chk))
                line.append("%s/%d %s %.2f" % (n, w, name, int(ns) / 1e6))
    print("round %d: %s" % (k + 1, ", ".join(line)), flush=True)
state("end")
json.dump(data, open(out, "w"))
