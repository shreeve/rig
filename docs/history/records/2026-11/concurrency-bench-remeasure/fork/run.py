#!/usr/bin/env python3
"""run.py ROUNDS RIG RAYON: fork.rig (built `rig build --release`) against
its Rayon twin (rayon/, `cargo build --release`), in rotating turns; the
fastest of each row counts, and the rows' checks must agree. Prints each
round's times too, so the spread is on record."""
import subprocess, sys

rounds, progs = int(sys.argv[1]), {"rig": sys.argv[2], "rayon": sys.argv[3]}
best, checks, names = {}, {}, list(progs)
for k in range(rounds):
    turn = names[k % 2:] + names[:k % 2]
    line = []
    for n in turn:
        out = subprocess.run([progs[n]], capture_output=True, text=True, timeout=600, check=True).stdout
        for row in out.splitlines():
            name, ns, chk = row.split()
            best[n, name] = min(int(ns), best.get((n, name), int(ns)))
            checks.setdefault(name, set()).add(chk)
            line.append("%s %s %.2f" % (n, name, int(ns) / 1e6))
    print("round %d: %s" % (k + 1, ", ".join(line)), flush=True)
bad = {r: v for r, v in checks.items() if len(v) != 1}
if bad:
    sys.exit("checks differ: %s" % bad)
print("checks:", {r: sorted(v) for r, v in checks.items()})
print("%-6s %10s %10s" % ("row", "rig ms", "rayon ms"))
for r in ("psum", "qsort"):
    print("%-6s %10.2f %10.2f" % (r, best["rig", r] / 1e6, best["rayon", r] / 1e6))
