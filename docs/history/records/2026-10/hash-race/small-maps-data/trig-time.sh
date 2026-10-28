#!/bin/sh
# sm-time.sh ROUNDS: Trig built by main's Rig (packs/main) and small-maps (packs/new), timed on
# core 8 (sibling 9 idle), interleaved: user and kernel cycles, user instructions, L3 load misses, faults, wall, peak RSS.
set -u
W=/zfs/worktrees/rig/sm-trig
T=/zfs/trig-pup/full/trig
N=${1:-20}
for proj in ts-pattern zod3; do
  dir=$T/misc/projects/$proj
  r=1
  while [ $r -le $N ]; do
    for b in main new; do
      (cd $dir && /usr/bin/time -f "%M %e" -o $W/time perf stat -x, -e cpu_core/cycles/u,cpu_core/cycles/k,cpu_core/instructions/u,cpu_core/mem_load_retired.l3_miss/u,page-faults -o $W/perf taskset -c 8 $W/packs/$b/bin -p tsconfig.trig.json --noEmit --singleThreaded > $W/out.$proj.$b 2>&1)
      cu=$(grep 'cycles/u' $W/perf | cut -d, -f1); ck=$(grep 'cycles/k' $W/perf | cut -d, -f1); ins=$(grep instructions $W/perf | cut -d, -f1); l3=$(grep l3_miss $W/perf | cut -d, -f1); pf=$(grep page-faults $W/perf | cut -d, -f1); set -- $(tail -n 1 $W/time)
      same=1; cmp -s $W/out.$proj.main $W/out.$proj.$b || same=0
      echo "$proj round=$r build=$b ucycles=$cu kcycles=$ck instructions=$ins l3miss=$l3 faults=$pf secs=$2 rss_kb=$1 same=$same"
    done
    r=$((r + 1))
  done
done
