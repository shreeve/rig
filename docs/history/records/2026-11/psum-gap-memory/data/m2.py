#!/usr/bin/env python3
"""m2.py ROUNDS OUT NAME=CMD...: fork.rig arms at 1 worker (P-core 6) and 12 (0-11), configs alternating
by round, arms rotating. CMD is a binary, or 'nothp:BIN' to run BIN with THP disabled for the process.
Appends 'round cfg arm row ns check' to OUT."""
import os, subprocess, sys
rounds, out = int(sys.argv[1]), sys.argv[2]
arms = [a.split("=", 1) for a in sys.argv[3:]]
M = "/zfs/trig-pup/psum-gap/mem"
cfgs = [("w1", "6", "1"), ("w12", "0-11", "12")]
with open(out, "a") as log:
    for k in range(rounds):
        sh = k % len(arms)
        for cfg, cores, w in (cfgs if k % 2 == 0 else cfgs[::-1]):
            env = dict(os.environ, RIG_WORKERS=w, RAYON_NUM_THREADS=w)
            for name, cmd in arms[sh:] + arms[:sh]:
                c = ["python3", M + "/nothp.py", cmd[6:]] if cmd.startswith("nothp:") else [cmd]
                p = subprocess.run(["taskset", "-c", cores] + c, capture_output=True, text=True, timeout=300, env=env, check=True)
                for row in p.stdout.splitlines():
                    r, ns, chk = row.split()
                    log.write("%d %s %s %s %s %s\n" % (k + 1, cfg, name, r, ns, chk))
                log.flush()
        print("round %d" % (k + 1), flush=True)
