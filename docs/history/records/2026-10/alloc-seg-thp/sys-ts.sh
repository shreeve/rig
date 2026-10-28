#!/bin/sh
# sys-ts.sh: tsrs-standing-data/sys.sh on this record's builds: user and
# kernel time, kernel cycles, page faults, dTLB misses, 10 rounds
# interleaved on core 6 (--singleThreaded), ts-pattern and zod3.
set -u
A=/zfs/worktrees/rig/alloc-seg-thp
for proj in ts-pattern zod3; do
  cd /zfs/trig-pup/full/trig/misc/projects/$proj
  for r in 1 2 3 4 5 6 7 8 9 10; do
    for v in ${VARIANTS:-main seg segnp seglead tbl}; do
      perf stat -x, -e duration_time,user_time,system_time,cpu_core/cycles/k,page-faults,dTLB-load-misses -o $A/sys.perf taskset -c 6 $A/trig-$v/bin -p tsconfig.trig.json --noEmit --singleThreaded > /dev/null 2>&1
      echo "$proj round=$r v=$v $(awk -F, '/^[0-9]/ { printf "%s=%s ", $3, $1 }' $A/sys.perf)"
    done
  done
done
