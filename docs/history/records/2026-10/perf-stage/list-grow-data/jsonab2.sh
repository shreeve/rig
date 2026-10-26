#!/bin/sh
# jsonab2.sh N REPS A B [FILES...]: std.json bench programs of builds A and B,
# interleaved (order reversed every other round) on core 8, `prog REPS`
# under perf stat; fastest task-clock and fewest user cycles and instructions of N.
n=$1; reps=$2; A=$3; Bv=$4; shift 4; B=/zfs/trig-pup/trial/lg/bench; o=$(mktemp -d /zfs/trig-cache/jab.XXXX)
files="$*"; [ -n "$files" ] || files=$(cd $B/$A/json && ls -d *-rig-*)
for f in $files; do
  for i in $(seq 1 $n); do
    if [ $((i % 2)) = 0 ]; then ord="$Bv $A"; else ord="$A $Bv"; fi
    for v in $ord; do perf stat -x, -e cpu_core/cycles/u,cpu_core/instructions/u,task-clock -o $o/$f.$v.$i taskset -c 8 $B/$v/json/$f/prog $reps >/dev/null 2>&1; done
  done
  for v in $A $Bv; do
    t=$(grep -h ",task-clock," $o/$f.$v.* | cut -d, -f1 | sort -n | head -1); c=$(grep -h "/cycles/" $o/$f.$v.* | cut -d, -f1 | sort -n | head -1)
    echo "$f $v $t $c"
  done
done
rm -rf $o
