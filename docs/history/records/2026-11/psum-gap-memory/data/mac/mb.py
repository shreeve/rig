#!/usr/bin/env python3
"""mb.py ROUNDS OUT: the Mac memory board: fork.rig (main) with an A/A copy and its Rayon twin at 1 and 10
workers, and the bw ceiling (write psum's input, time one pass) at 1 thread (orders, loops) and 4 and 10
threads. Arms rotate each round; rows append to OUT as 'round name row ns check'."""
import os, subprocess, sys
rounds, out = int(sys.argv[1]), sys.argv[2]
S = os.path.dirname(os.path.abspath(__file__))
jobs = []
for w in ("1", "10"):
    for a, b in (("rig", S + "/rig"), ("rig-aa", S + "/rig-aa"), ("rayon", S + "/rayon/target/release/fork-rayon")):
        jobs.append(("w%s %s" % (w, a), [b], {"RIG_WORKERS": w, "RAYON_NUM_THREADS": w}))
for o in ("asc", "leafasc", "leafdesc"):
    for l in ("scalar", "vec"):
        jobs.append(("bw1 %s %s" % (o, l), [S + "/bw", "plain", o, "1", l], {}))
for t in ("4", "10"):
    jobs.append(("bw%s asc vec" % t, [S + "/bw", "plain", "asc", t, "vec"], {}))
with open(out, "a") as log:
    for k in range(rounds):
        sh = (k * 5) % len(jobs)
        for name, cmd, env in jobs[sh:] + jobs[:sh]:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=300, env=dict(os.environ, **env), check=True)
            for row in p.stdout.splitlines():
                f = row.split()
                if len(f) == 2: f = ["pass"] + f
                log.write("%d|%s|%s|%s|%s\n" % (k + 1, name, f[0], f[1], f[2]))
            log.flush()
        print("round", k + 1, flush=True)
