#!/bin/bash
# prof74.sh OUT RUNS: per-thread CPU (task-clock samples, 2 ms each) and every madvise call with its
# duration, Trig PGO on ts-pattern and zod3 at 1 checker (core 16) and 4 on 16-19.
set -u
OUT=$1; N=$2; B=/tmp/rw74; P=/zfs/trig-pup/full/trig/misc/projects
mkdir -p $OUT
for proj in ts-pattern zod3; do cd $P/$proj
  for arm in 1:16 4:16-19; do c=${arm%%:*}; cores=${arm#*:}
    k=$proj.c$c.$cores
    sudo -n perf record -q -e task-clock -c 2000000 -e syscalls:sys_enter_madvise -e syscalls:sys_exit_madvise -o $OUT/$k.data -- setpriv --reuid=1000 --regid=1000 --init-groups bash -c "for i in \$(seq 1 $N); do taskset -c $cores $B/trig -p tsconfig.trig.json --noEmit --checkers $c > /dev/null 2>&1; done"
    sudo -n chown 1000:1000 $OUT/$k.data
    perf script -i $OUT/$k.data -F comm,pid,tid,time,event,trace 2>/dev/null | gzip > $OUT/$k.txt.gz
  done
done
