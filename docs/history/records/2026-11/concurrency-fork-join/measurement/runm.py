#!/usr/bin/env python3
"""runm.py ROUNDS: fork.rig, the original Rayon twin, and the twin with std.sort's leaves (forkm), rotating; fastest of each row."""
import subprocess, sys, os
S = os.path.dirname(os.path.abspath(__file__))
progs = {"rig": S+"/rig-fork", "rayon": S+"/rayon-target/release/fork-rayon", "rayon-symmerge": S+"/rayon-target/release/forkm"}
best, names = {}, list(progs)
for k in range(int(sys.argv[1])):
    turn = names[k % 3:] + names[:k % 3]; line = []
    for n in turn:
        out = subprocess.run([progs[n]], capture_output=True, text=True, timeout=600, check=True).stdout
        for row in out.splitlines():
            name, ns, chk = row.split()
            best[n, name] = min(int(ns), best.get((n, name), int(ns)))
            line.append("%s %s %.2f" % (n, name, int(ns) / 1e6))
    print("round %d: %s" % (k + 1, ", ".join(line)), flush=True)
for (n, r), v in sorted(best.items()):
    print("%-16s %-10s %10.3f" % (n, r, v / 1e6))
