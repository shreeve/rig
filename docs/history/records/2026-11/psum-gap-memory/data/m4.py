#!/usr/bin/env python3
"""m4.py ROUNDS NET_ROUNDS OUT DIR: the board for seg-first-small on pup. DIR holds fork-{main,aa,new},
tasks-{main,aa,new}, net-{main,aa,new} and rayon. Each round, configs alternating and arms rotating:
fork at 1 worker (P-core 6) and 12 (0-11) with Rayon; bench/tasks' timed rows at 12 workers (0-11);
and, in the first NET_ROUNDS rounds, bench/net's rows at 12 workers (0-11), waiting between net runs
until TIME_WAIT sockets fall under 20,000. Appends 'round cfg arm row ns check' to OUT."""
import os, subprocess, sys, time
rounds, net_rounds, out, d = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
arms = os.environ.get("ARMS", "main aa new").split()

def tw():
    p = subprocess.run(["ss", "-tan", "state", "time-wait"], capture_output=True, text=True)
    return len(p.stdout.splitlines())

def run(log, k, cfg, arm, cores, w, cmd):
    env = dict(os.environ, RIG_WORKERS=w, RAYON_NUM_THREADS=w)
    p = subprocess.run(["taskset", "-c", cores] + cmd, capture_output=True, text=True, timeout=300, env=env, check=True)
    for row in p.stdout.splitlines():
        f = row.split()
        if len(f) == 3:
            log.write("%d %s %s %s %s %s\n" % (k, cfg, arm, f[0], f[1], f[2]))
    log.flush()

with open(out, "a") as log:
    for k in range(1, rounds + 1):
        rot = arms[k % len(arms):] + arms[:k % len(arms)]
        forks = [("w1", "6", "1"), ("w12", "0-11", "12")]
        for cfg, cores, w in (forks if k % 2 else forks[::-1]):
            for a in (rot + ["rayon"]) if k % 2 else (["rayon"] + rot):
                run(log, k, cfg, a, cores, w, [d + ("/rayon" if a == "rayon" else "/fork-" + a)])
        for a in rot:
            run(log, k, "tasks", a, "0-11", "12", [d + "/tasks-" + a])
        if k <= net_rounds:
            for a in rot:
                for i in range(120):
                    if tw() < 20000: break
                    time.sleep(1)
                run(log, k, "net", a, "0-11", "12", [d + "/net-" + a])
        print("round", k, flush=True)
