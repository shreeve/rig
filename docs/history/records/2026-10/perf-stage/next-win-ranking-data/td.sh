#!/bin/sh
cd /zfs/trig-pup/full/trig/misc/projects/${PROJ:-ts-pattern}
for r in 1 2; do for v in pgo shipped; do
  if [ $v = pgo ]; then set -- /zfs/worktrees/rig/standing-6/trig/bin -p tsconfig.trig.json --noEmit --singleThreaded
  else set -- env RAYON_NUM_THREADS=1 /zfs/trig-pup/tsrs-shipped/package/tsrs -p tsconfig.trig.json --noEmit --checkerAssignment go --noLazyMembers --singleThreaded; fi
  for ev in topdown_retiring.all:u,topdown_fe_bound.all:u,topdown_be_bound.all:u,topdown_bad_speculation.all:u topdown_fe_bound.icache:u,topdown_fe_bound.itlb_miss:u,cpu_atom/cycles/u,topdown_be_bound.mem_scheduler:u; do
    taskset -c 14 perf stat --no-scale -e $ev "$@" 2>&1 >/dev/null | grep cpu_atom | while read n e rest; do echo "$v $e $n"; done
  done
done; done
