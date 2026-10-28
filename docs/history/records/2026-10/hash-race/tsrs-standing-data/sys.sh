#!/bin/sh
# On pup: user and kernel time, 10 rounds interleaved on core 8, ts-pattern
# and zod3: Trig's PGO build by Rig main against shipped tsrs.
set -u
W=/zfs/worktrees/rig/tsrs-standing
. $W/cmds.sh
for proj in ts-pattern zod3; do
  cd /zfs/trig-pup/full/trig/misc/projects/$proj
  for r in 1 2 3 4 5 6 7 8 9 10; do
    for v in main-pgo tsrs; do
      perf stat -x, -e duration_time,user_time,system_time,cpu_core/cycles/k,page-faults,dTLB-load-misses -o $W/sys.perf taskset -c 8 $(cmd_of $v) > /dev/null 2>&1
      echo "$proj round=$r v=$v $(awk -F, '/^[0-9]/ { printf "%s=%s ", $3, $1 }' $W/sys.perf)"
    done
  done
done
