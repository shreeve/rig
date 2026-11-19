#!/usr/bin/env python3
"""pboard.py ROUNDS OUT.json NAME=PROG...: fork-order's board.py, keeping
every output line (the `ph` stamps too)."""
import json, os, subprocess, sys, time
rounds, out = int(sys.argv[1]), sys.argv[2]
progs = dict(a.split("=", 1) for a in sys.argv[3:])
names, cores = list(progs), os.cpu_count()
data = []
def state(tag):
    print(tag, time.strftime("%H:%M:%S"), subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip(), flush=True)
state("start")
for k in range(rounds):
    for w in ([1, cores] if k % 2 == 0 else [cores, 1]):
        r = k % len(names)
        env = dict(os.environ, RIG_WORKERS=str(w), RAYON_NUM_THREADS=str(w))
        for n in names[r:] + names[:r]:
            o = subprocess.run([progs[n]], capture_output=True, text=True, timeout=600, check=True, env=env).stdout
            data.append((k + 1, w, n, o.splitlines()))
    print("round", k + 1, flush=True)
    json.dump(data, open(out, "w"))
state("end")
