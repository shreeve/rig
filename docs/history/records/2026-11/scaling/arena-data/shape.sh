#!/bin/bash
# shape.sh OUT ARMS...: per arm (binary /tmp/scal-ab/ARM), project and checker count: mappings, VmPTE and RSS
# near the end of a run, and the exit's teardown and TLB flushes by tracepoints over five runs.
set -u
N=$1; OUT=$2; shift 2; B=/tmp/scal-ab; P=/zfs/trig-pup/full/trig/misc/projects; t="-p tsconfig.trig.json --noEmit"
cores() { case $1 in 1) echo 12;; 4) echo 12-15;; 8) echo 12-19;; esac; }
mkdir -p $OUT
for proj in ts-pattern zod3; do cd $P/$proj
  for a in "$@"; do for c in 1 4 8; do
    taskset -c $(cores $c) $B/$a $t --checkers $c > /dev/null 2>&1 & pid=$!; last=""
    while kill -0 $pid 2>/dev/null; do s=$(grep -E "VmPTE|VmRSS" /proc/$pid/status 2>/dev/null | tr -s ' \t' ' ' | tr '\n' ' '); m=$(wc -l < /proc/$pid/maps 2>/dev/null); [ -n "$s" ] && [ -n "$m" ] && [ "$m" -gt 0 ] && last="$s maps=$m"; sleep 0.01; done
    echo "$proj $a $c: $last" >> $OUT/shape.txt
    sudo -n perf record -q -e syscalls:sys_enter_exit_group -e syscalls:sys_exit_wait4 -e tlb:tlb_flush -o $OUT/exit.$proj.$a.$c.data -- setpriv --reuid=1000 --regid=1000 --init-groups bash -c "for i in 1 2 3 4 5; do taskset -c $(cores $c) $B/$a $t --checkers $c > /dev/null 2>&1; done"
    sudo -n chown 1000:1000 $OUT/exit.$proj.$a.$c.data
  done; done
done
