#!/bin/bash
# prof3.sh OUT: exit teardown by tracepoints, 5 runs per arm.
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
  for a in trig tsrsg tsrs; do for c in 1 4 8; do
    k=$proj.$a.$c
    sudo -n perf record -q -e syscalls:sys_enter_exit_group -e syscalls:sys_exit_wait4 -e tlb:tlb_flush -o $OUT/exit.$k.data -- setpriv --reuid=1000 --regid=1000 --init-groups bash -c "for i in 1 2 3 4 5; do taskset -c $(cores $c) $(cmd $a $c) > /dev/null 2>&1; done"
  done; done
done
