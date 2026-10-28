#!/bin/sh
# On pup: Trig built by Rig main (373b6aed3) and by emit-inplace, timed on
# core 3 (sibling 4 idle), interleaved, N rounds (default 20): user and
# kernel cycles, user instructions, loads blocked by store forwarding,
# page faults, wall, peak RSS. One line a run.
set -u
W=/zfs/worktrees/rig/emit-inplace
T=/zfs/trig-pup/full/trig
N=${1:-20}
EV=cpu_core/cycles/u,cpu_core/cycles/k,cpu_core/instructions/u,cpu_core/ld_blocks.store_forward/u,page-faults
for proj in ts-pattern zod3; do
  dir=$T/misc/projects/$proj
  r=1
  while [ $r -le $N ]; do
    for b in main new; do
      (cd $dir && /usr/bin/time -f "%M %e" -o $W/time.$b perf stat -x, -e $EV -o $W/perf.$b taskset -c 3 $W/packs/$b/bin -p tsconfig.trig.json --noEmit --singleThreaded > $W/out.$proj.$b 2>&1)
      f=$W/perf.$b
      cu=$(grep 'cycles/u' $f | cut -d, -f1); ck=$(grep 'cycles/k' $f | cut -d, -f1); ins=$(grep instructions $f | cut -d, -f1); sf=$(grep store_forward $f | cut -d, -f1); pf=$(grep page-faults $f | cut -d, -f1); set -- $(tail -n 1 $W/time.$b)
      same=1; cmp -s $W/out.$proj.main $W/out.$proj.$b || same=0
      echo "$proj round=$r build=$b ucycles=$cu kcycles=$ck instructions=$ins stfwd=$sf faults=$pf secs=$2 rss_kb=$1 same=$same"
    done
    r=$((r + 1))
  done
done
