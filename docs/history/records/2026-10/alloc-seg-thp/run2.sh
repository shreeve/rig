#!/bin/sh
# run2.sh: the re-measure on main 099c1bff3 (after #737-#739): main
# against seglead (the rebased branch), as run.sh, the same scripts.
# Results in *-2.md / *-2.txt.
A=/zfs/worktrees/rig/alloc-seg-thp
cd $A
# Time only on a quiet pup: no tsc or trig suite running, load under 2.5,
# checked a minute apart twice (waits at most three hours).
n=0; q=0
while [ $n -lt 180 ] && [ $q -lt 2 ]; do
  if ! pgrep -x tsc > /dev/null && awk "{ exit !(\$1 < 2.5) }" /proc/loadavg; then q=$((q + 1)); else q=0; fi
  sleep 60; n=$((n + 1))
done
echo "quiet after $n min: $(cat /proc/loadavg)"
V="main=$A/trig-main/bin seglead=$A/trig-seglead/bin"
python3 measure.py 20 $V > trig-perf-2.md 2> trig-perf-2.err
NOPERF=1 python3 measure.py 20 $V > trig-wall-2.md 2> trig-wall-2.err
FOUR=1 python3 measure.py 10 $V > trig-perf4-2.md 2> trig-perf4-2.err
python3 huge.py 3 $V > huge-2.md 2> huge-2.err
VARIANTS="main seglead" sh huge-ts.sh > huge-ts-2.txt 2>&1
VARIANTS="main seglead" sh sys-ts.sh > sys-ts-2.txt 2>&1
echo done
