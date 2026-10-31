#!/bin/bash
# pst.sh "ARGS" MUL...: perf counters of each multiplier's probe on P-core 6
cd "$(dirname "$0")"
a=$1; shift
E=cpu_core/cycles/u,cpu_core/instructions/u,cpu_core/mem_load_retired.l1_miss/u,cpu_core/mem_load_retired.l2_miss/u,cpu_core/mem_load_retired.l3_miss/u,cpu_core/ld_blocks.store_forward/u,cpu_core/ld_blocks.address_alias/u,cpu_core/branch-misses/u,cpu_core/exe_activity.bound_on_stores/u,cpu_core/dtlb_load_misses.walk_completed/u,cpu_core/dtlb_store_misses.walk_completed/u,page-faults
for m in "$@"; do
  echo "== $m $a"
  taskset -c 6 perf stat -x, -e $E ./p-$m-0.bin $a 2>&1 | awk -F, 'NF>3{printf "  %-40s %14s\n", $3, $1; next}{print}'
done
