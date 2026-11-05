#!/bin/bash
# prof.sh OUT: profiles for the scaling probe (E-cores), Trig and tsrs Go mode, ts-pattern and zod3, 1 and 8 checkers.
set -u
OUT=$1; B=/tmp/scal-probe; P=/zfs/trig-pup/full/trig/misc/projects
mkdir -p $OUT
t="-p tsconfig.trig.json --noEmit"
GO="--checkerAssignment go --noLazyMembers"
cores() { case $1 in 1) echo 12;; 4) echo 12-15;; 8) echo 12-19;; esac; }
cmd() { case $1 in
  trig) echo "$B/trig $t --checkers $2" ;;
  tsrsg) echo "env RAYON_NUM_THREADS=$2 $B/tsrs/tsrs $t $GO --checkers $2" ;;
  tsrs) echo "env RAYON_NUM_THREADS=$2 $B/tsrs/tsrs $t --checkers $2" ;; esac; }
for proj in ts-pattern zod3; do cd $P/$proj
  for a in trig tsrsg; do for c in 1 8; do
    k=$proj.$a.$c
    # cycles with call stacks, user and kernel
    perf record -q -F 2999 -e cpu_atom/cycles/ -g -o $OUT/cyc.$k.data taskset -c $(cores $c) $(cmd $a $c) > /dev/null 2>&1
    # loads that missed the STLB, with their data addresses
    perf record -q -c 2003 -e cpu_atom/mem_uops_retired.stlb_miss_loads/upp -d -o $OUT/stlb.$k.data taskset -c $(cores $c) $(cmd $a $c) > /dev/null 2>&1 &
    pp=$!; sleep 0.05; pid=$(pgrep -P $pp | head -1); cpid=$(pgrep -P $pid | head -1); x=${cpid:-$pid}
    i=0; while kill -0 $pp 2>/dev/null; do cat /proc/$x/maps > $OUT/maps.$k.$i 2>/dev/null; cat /proc/$x/smaps_rollup > $OUT/rollup.$k.$i 2>/dev/null; grep -c . /proc/$x/maps > /dev/null 2>&1; i=$((i+1)); sleep 0.02; done
    wait $pp
    # keep the last non-empty maps snapshot
    last=$(ls -v $OUT/maps.$k.* 2>/dev/null | while read f; do [ -s $f ] && echo $f; done | tail -1); [ -n "$last" ] && cp $last $OUT/maps.$k
    lr=$(ls -v $OUT/rollup.$k.* 2>/dev/null | while read f; do [ -s $f ] && echo $f; done | tail -1); [ -n "$lr" ] && cp $lr $OUT/rollup.$k
    mid=$(ls -v $OUT/rollup.$k.* 2>/dev/null | while read f; do [ -s $f ] && echo $f; done | awk '{a[NR]=$0} END{print a[int(NR*0.7)+0]}'); [ -n "$mid" ] && cp $mid $OUT/rollup70.$k
    rm -f $OUT/maps.$k.* $OUT/rollup.$k.*
  done; done
  # the scheduler's own counts
  for c in 4 8; do RIG_SCHED_STATS=1 taskset -c $(cores $c) $(cmd trig $c) > $OUT/sched.$proj.$c.txt 2>&1; done
done
