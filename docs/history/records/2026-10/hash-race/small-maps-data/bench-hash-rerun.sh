#!/bin/bash
# bhrun.sh DIR N [PIN] [ROWS-REGEX]: time DIR/new and DIR/main rig-fast again, interleaved, fastest of N.
D=$1; N=$2; PIN=${3:-}
rm -f $D/run.*.txt
for r in $(seq 1 $N); do for b in new main; do $PIN $D/$b/rig-fast > $D/run.$b.$r.txt 2>&1; done; done
python3 - $D <<'PY'
import sys, glob
D = sys.argv[1]
best = {}
for n in ("new", "main"):
    for f in glob.glob(D + "/run." + n + ".*.txt"):
        for l in open(f):
            p = l.split()
            if len(p) != 4 or not p[2].isdigit(): continue
            k = (p[0], p[1]); v = int(p[2])
            best.setdefault(n, {}); best[n][k] = min(v, best[n].get(k, v))
for k in best["new"]:
    if k not in best["main"]: continue
    a, b = best["new"][k] / 1e6, best["main"][k] / 1e6
    print("%-26s %8.2f %8.2f  %6.2f%s" % (k[0] + " " + k[1], a, b, a / b, " <SLOWER" if a / b > 1.02 else (" faster" if a / b < 0.98 else "")))
PY
