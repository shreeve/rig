#!/bin/sh
# On pup, core 3 (sibling 4 idle): whole-run memory counters of Trig (rel)
# and tsrs, ts-pattern and zod3, N rounds interleaved, two event groups
# (no multiplexing), plus software faults. CSV in counts/.
set -u
. /zfs/worktrees/rig/memory-traffic/cmds.sh
N=${1:-5}; V=${V:-"rel tsrs"}
O=$W/counts; mkdir -p $O
G1=cpu_core/cycles/u,cpu_core/instructions/u,cpu_core/mem_inst_retired.all_loads/u,cpu_core/mem_inst_retired.all_stores/u,cpu_core/mem_load_retired.l1_miss/u,cpu_core/mem_load_retired.l2_miss/u,cpu_core/mem_load_retired.l3_miss/u,cpu_core/ld_blocks.store_forward/u
G2=cpu_core/cycles/u,cpu_core/mem_inst_retired.stlb_miss_loads/u,cpu_core/mem_inst_retired.stlb_miss_stores/u,cpu_core/dtlb_load_misses.walk_completed/u,cpu_core/dtlb_load_misses.walk_active/u,cpu_core/dtlb_store_misses.walk_completed/u,cpu_core/l2_lines_in.all/u,cpu_core/cycles/k
SW=page-faults,minor-faults,major-faults,task-clock,user_time,system_time
for p in ts-pattern zod3; do
  cd $P/$p
  for r in $(seq 1 $N); do
    for v in $V; do
      for g in G1 G2 SW; do
        eval ev=\$$g
        quiet8
        perf stat -x, -e $ev -o $O/$p.$v.$g.$r.csv taskset -c 3 $(cmd_of $v) > /dev/null 2>&1
      done
    done
  done
done
echo done
