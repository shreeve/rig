#!/bin/sh
# jsonab.sh N REPS: each std.json bench program of base and v4, interleaved
# (order reversed every other round) on core 8, `prog REPS` under perf stat;
# fastest task-clock and fewest user cycles of N.
n=$1; reps=$2; B=/zfs/trig-pup/trial/lg/bench; o=$(mktemp -d /zfs/trig-cache/jab.XXXX)
for d in $B/base/json/*-rig-*; do f=$(basename $d)
  for i in $(seq 1 $n); do
    if [ $((i % 2)) = 0 ]; then ord="v5 v4 base"; else ord="base v4 v5"; fi
    for v in $ord; do perf stat -x, -e cpu_core/cycles/u,task-clock -o $o/$f.$v.$i taskset -c 8 $B/$v/json/$f/prog $reps >/dev/null 2>&1; done
  done
  for v in base v4 v5; do
    t=$(grep -h ",task-clock," $o/$f.$v.* | cut -d, -f1 | sort -n | head -1); c=$(grep -h "/cycles/" $o/$f.$v.* | cut -d, -f1 | sort -n | head -1)
    echo "$f $v $t $c"
  done
done
rm -rf $o
