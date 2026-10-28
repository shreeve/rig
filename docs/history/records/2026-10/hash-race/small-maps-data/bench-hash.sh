#!/bin/bash
# bh.sh WORKTREE MAINRIG OUTDIR REPS [PIN]: bench/hash rig-fast by the worktree's bin/rig (new) and MAINRIG (main), interleaved, fastest of REPS.
set -u
W=$1; MAIN=$2; D=$3; N=$4; PIN=${5:-}
mkdir -p $D/new $D/main
cd $W
rm -f $D/new/rig-fast
RIG=$W/bin/rig bench/hash/bench-hash --out $D/new --build-only --variants rig-fast >/dev/null || exit 1
[ -e $D/main/rig-fast ] || RIG=$MAIN bench/hash/bench-hash --out $D/main --build-only --variants rig-fast >/dev/null || exit 1
rm -f $D/run.*.txt
for r in $(seq 1 $N); do
  for b in new main; do
    $PIN $D/$b/rig-fast > $D/run.$b.$r.txt 2>&1
  done
done
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
print("%-26s %8s %8s  new/main" % ("row", "new", "main"))
for k in best["new"]:
    if k not in best["main"]: continue
    a, b = best["new"][k] / 1e6, best["main"][k] / 1e6
    print("%-26s %8.2f %8.2f  %6.2f%s" % (k[0] + " " + k[1], a, b, a / b, " <SLOWER" if a / b > 1.03 else ""))
PY
