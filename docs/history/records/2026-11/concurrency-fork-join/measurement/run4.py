#!/usr/bin/env python3
"""run4.py ROUNDS: rotate rig/rayon variants at 10 workers and at 1; fastest of each row."""
import subprocess, sys, os
S = os.path.dirname(os.path.abspath(__file__))
rounds = int(sys.argv[1])
progs = {
 "rig":    ([S+"/rig-forkv"], {}),
 "rayon":  ([S+"/rayon-target/release/forkv"], {}),
 "rig1":   ([S+"/rig-forkv"], {"RIG_WORKERS": "1"}),
 "rayon1": ([S+"/rayon-target/release/forkv"], {"RAYON_NUM_THREADS": "1"}),
}
best, checks, names = {}, {}, list(progs)
for k in range(rounds):
    turn = names[k % 4:] + names[:k % 4]
    line = []
    for n in turn:
        cmd, env = progs[n]
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=600, check=True, env={**os.environ, **env}).stdout
        for row in out.splitlines():
            name, ns, chk = row.split()
            best[n, name] = min(int(ns), best.get((n, name), int(ns)))
            checks.setdefault(name, set()).add(chk)
            line.append("%s %s %.2f" % (n, name, int(ns) / 1e6))
    print("round %d: %s" % (k + 1, ", ".join(line)), flush=True)
print("checks:", {r: sorted(v) for r, v in checks.items()})
rows = []
for (n, r) in best:
    if r not in rows: rows.append(r)
print("%-14s" % "row" + "".join("%10s" % n for n in names))
for r in rows:
    print("%-14s" % r + "".join("%10.3f" % (best[n, r] / 1e6) if (n, r) in best else "%10s" % "-" for n in names))
