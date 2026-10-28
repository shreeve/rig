#!/bin/sh
# On pup: ctr.sh N TAG V...: the front end's counters for the variants V,
# interleaved, N rounds, on core 6 (sibling 7 idle), ts-pattern then zod3,
# in four event sets so that no counter is multiplexed.
set -u
N=$1 TAG=$2; shift 2
W=/zfs/worktrees/rig/check-bisect
O=$W/ctr/$TAG; mkdir -p $O
A=cpu_core/instructions/u,cpu_core/cycles/u,cpu_core/br_inst_retired.all_branches/u,cpu_core/branch-misses/u
B=cpu_core/frontend_retired.l1i_miss/u,cpu_core/icache_data.stalls/u,cpu_core/icache_tag.stalls/u
D=cpu_core/dsb2mite_switches.penalty_cycles/u,cpu_core/idq.dsb_uops/u,cpu_core/idq.mite_uops/u
C=cpu_core/frontend_retired.itlb_miss/u
for proj in ts-pattern zod3; do
  cd $W/projects/$proj
  r=1
  while [ $r -le $N ]; do
    for v in "$@"; do
      for set in A B C D; do
        eval ev=\$$set
        perf stat -x, -e $ev -o $O/perf taskset -c 6 $W/v/$v/bin -p tsconfig.trig.json --noEmit --singleThreaded > /dev/null 2>&1
        awk -F, -v p=$proj -v r=$r -v v=$v '/cpu_core/{printf "%s round=%d v=%s %s=%s pct=%s\n", p, r, v, $3, $1, $5}' $O/perf
      done
    done
    r=$((r + 1))
  done
done >> $O/ctr.txt
