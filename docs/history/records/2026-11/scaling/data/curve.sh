#!/bin/sh
# curve.sh ROUNDS OUT: Trig (Go order), tsrs shipped default, tsrs Go mode, on ts-pattern
# and zod3 at 1, 2, 4, 8 checkers, E-cores 12.., shuffled each round, perf counters + peak RSS.
set -u
N=$1; OUT=$2; B=/tmp/scal-probe
P=/zfs/trig-pup/full/trig/misc/projects
EV=duration_time,task-clock,page-faults,context-switches,cpu-migrations,cpu_atom/cycles/u,cpu_atom/cycles/k,cpu_atom/instructions/u,cpu_atom/ld_head.pgwalk_at_ret/u,cpu_atom/mem_bound_stalls_load.llc_miss/u,cpu_atom/mem_bound_stalls_load.llc_hit/u,cpu_atom/mem_bound_stalls_load.l2_hit/u,cpu_atom/dtlb_load_misses.walk_completed/u
t="-p tsconfig.trig.json --noEmit"
GO="--checkerAssignment go --noLazyMembers"
cores() { case $1 in 1) echo 12;; 2) echo 12-13;; 4) echo 12-15;; 8) echo 12-19;; esac; }
cmd() { # arm C
  case $1 in
    trig) echo "$B/trig $t --checkers $2" ;;
    tsrs) echo "env RAYON_NUM_THREADS=$2 $B/tsrs/tsrs $t --checkers $2" ;;
    tsrsg) echo "env RAYON_NUM_THREADS=$2 $B/tsrs/tsrs $t $GO --checkers $2" ;;
  esac
}
mkdir -p $OUT/out
for proj in ts-pattern zod3; do
  cd $P/$proj
  for a in trig tsrs tsrsg; do for c in 1 2 4 8; do
    taskset -c $(cores $c) $(cmd $a $c) > $OUT/out/$proj.$a.$c.ref 2>&1; echo "rc=$?" >> $OUT/out/$proj.$a.$c.ref
  done; done
done
for r in $(seq 1 $N); do
  for proj in ts-pattern zod3; do
    cd $P/$proj
    for arm in $(for a in trig tsrs tsrsg; do for c in 1 2 4 8; do echo $a.$c; done; done | shuf --random-source=<(yes $r)); do
      a=${arm%.*}; c=${arm#*.}
      s0=$(date +%s%N)
      /usr/bin/time -f "rss %M" -o $OUT/rss.tmp perf stat -x, -e $EV -o $OUT/stat.tmp taskset -c $(cores $c) $(cmd $a $c) > $OUT/run.out 2>&1; rc=$?; s1=$(date +%s%N)
      echo "rc=$rc" >> $OUT/run.out
      cmp -s $OUT/run.out $OUT/out/$proj.$a.$c.ref && same=same || same=DIFF
      echo "R $r $proj $a $c $same wall=$(( (s1 - s0) / 1000 ))us $(cat $OUT/rss.tmp | tr '\n' ' ') $(grep -v '^#' $OUT/stat.tmp | grep -v '^$' | awk -F, '{printf "%s=%s(%s) ", $3, $1, $5}')" >> $OUT/curve.txt
    done
  done
done
