#!/usr/bin/env python3
"""b10.py ROUNDS OUT NAME=PROG...: fork.rig's qsort at 10 workers only, arms rotating; rows to OUT."""
import os, subprocess, sys
rounds, out = int(sys.argv[1]), sys.argv[2]
progs = [a.split("=", 1) for a in sys.argv[3:]]
env = dict(os.environ, RIG_WORKERS="10", RAYON_NUM_THREADS="10")
with open(out, "a") as f:
    for k in range(rounds):
        r = k % len(progs)
        for n, p in progs[r:] + progs[:r]:
            o = subprocess.run([p], capture_output=True, text=True, timeout=600, check=True, env=env).stdout
            for l in o.splitlines():
                x = l.split()
                if x[0] in ("psum", "qsort"): f.write("%d %s %s %s %s\n" % (k + 1, n, x[0], x[1], x[2]))
        f.flush()
