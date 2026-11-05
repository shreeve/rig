#!/bin/bash
# ab.sh ROUNDS OUT ARMS...: Trig arms (binaries in /tmp/scal-ab/ARM) on ts-pattern and zod3 at 1, 4, 8
# checkers, E-cores 12.., shuffled each round; perf counters, wall (duration_time), peak RSS; output checked.
set -u
N=$1; OUT=$2; shift 2; ARMS="$*"; B=/tmp/scal-ab
P=/zfs/trig-pup/full/trig/misc/projects
EV=duration_time,task-clock,page-faults,cpu_atom/cycles/u,cpu_atom/cycles/k,cpu_atom/instructions/u,cpu_atom/ld_head.pgwalk_at_ret/u,cpu_atom/dtlb_load_misses.walk_completed/u
t="-p tsconfig.trig.json --noEmit"
cores() { case $1 in 1) echo 12;; 4) echo 12-15;; 8) echo 12-19;; esac; }
mkdir -p $OUT/out
for proj in ts-pattern zod3; do cd $P/$proj
  for a in $ARMS; do for c in 1 4 8; do
    taskset -c $(cores $c) $B/$a $t --checkers $c > $OUT/out/$proj.$a.$c.ref 2>&1; echo "rc=$?" >> $OUT/out/$proj.$a.$c.ref
  done; done
done
for r in $(seq 1 $N); do
  for proj in ts-pattern zod3; do cd $P/$proj
    for arm in $(for a in $ARMS; do for c in 1 4 8; do echo $a.$c; done; done | shuf --random-source=<(yes $r)); do
      a=${arm%.*}; c=${arm#*.}
      /usr/bin/time -f "rss %M" -o $OUT/rss.tmp perf stat -x, -e $EV -o $OUT/stat.tmp taskset -c $(cores $c) $B/$a $t --checkers $c > $OUT/run.out 2>&1; rc=$?
      echo "rc=$rc" >> $OUT/run.out
      cmp -s $OUT/run.out $OUT/out/$proj.trig.1.ref 2>/dev/null || cmp -s $OUT/run.out $OUT/out/$proj.$(echo $ARMS | cut -d' ' -f1).1.ref && same=same || same=DIFF
      echo "R $r $proj $a $c $same $(cat $OUT/rss.tmp | tr '\n' ' ') $(grep -v '^#' $OUT/stat.tmp | grep -v '^$' | awk -F, '{printf "%s=%s(%s) ", $3, $1, $5}')" >> $OUT/ab.txt
    done
  done
done
