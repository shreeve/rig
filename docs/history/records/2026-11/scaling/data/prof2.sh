#!/bin/bash
# prof2.sh OUT: more cycle samples (6 runs per arm), smaps at about 70% of a run, and exit teardown by tracepoints.
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
at70() { case $1.$2 in ts-pattern.1) echo 0.80;; ts-pattern.8) echo 0.30;; zod3.1) echo 0.14;; zod3.8) echo 0.08;; esac; }
for proj in ts-pattern zod3; do cd $P/$proj
  for a in trig tsrsg; do for c in 1 8; do
    k=$proj.$a.$c
    perf record -q -c 3400000 -e cpu_atom/cycles/ -g -o $OUT/cyc.$k.data -- bash -c "for i in 1 2 3 4 5 6; do taskset -c $(cores $c) $(cmd $a $c) > /dev/null 2>&1; done"
    taskset -c $(cores $c) $(cmd $a $c) > /dev/null 2>&1 & pid=$!
    sleep $(at70 $proj $c); cat /proc/$pid/smaps > $OUT/smaps.$k 2>/dev/null; wait $pid
    sudo -n perf record -q -e syscalls:sys_enter_exit_group -e sched:sched_process_exit -e tlb:tlb_flush -o $OUT/exit.$k.data -- setpriv --reuid=1000 --regid=1000 --init-groups bash -c "for i in 1 2 3 4 5; do taskset -c $(cores $c) $(cmd $a $c) > /dev/null 2>&1; done"
    sudo -n chown 1000:1000 $OUT/exit.$k.data
  done; done
done
