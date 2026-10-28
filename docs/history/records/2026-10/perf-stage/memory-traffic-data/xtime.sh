#!/bin/sh
# On pup, core 8 (sibling 9 idle), in a window the coordinator gave: the
# ceiling experiments' binary (mkx.py) under each $RIG_X arm, N rounds
# interleaved with the order reversed every other round, ts-pattern then
# zod3; perf stat (wall, user and kernel cycles, instructions, dTLB walks,
# STLB load misses, blocked loads, faults) and /usr/bin/time for peak RSS.
# Every arm's output is compared with the base arm's.
set -u
W=/zfs/worktrees/rig/memory-traffic
P=/zfs/trig-pup/full/trig/misc/projects
N=${1:-20}; ARMS=${ARMS:-"0 1 2 4 7"}
O=$W/xtime; mkdir -p $O
B=$W/packs/x/bin
EV=duration_time,cpu_core/cycles/u,cpu_core/cycles/k,cpu_core/instructions/u,cpu_core/dtlb_load_misses.walk_active/u,cpu_core/mem_inst_retired.stlb_miss_loads/u,cpu_core/ld_blocks.store_forward/u,page-faults
for p in ts-pattern zod3; do
  cd $P/$p
  RIG_X=0 taskset -c 8 $B -p tsconfig.trig.json --noEmit --singleThreaded > $O/$p.ref.out 2>&1
  for r in $(seq 1 $N); do
    order=$ARMS; [ $((r % 2)) = 0 ] && order=$(echo $ARMS | tr ' ' '\n' | tac | tr '\n' ' ')
    for a in $order; do
      RIG_X=$a perf stat -x, -e $EV -o $O/$p.$a.$r.csv taskset -c 8 $B -p tsconfig.trig.json --noEmit --singleThreaded > $O/$p.$a.$r.out 2>&1
      cmp -s $O/$p.$a.$r.out $O/$p.ref.out || echo "DIFF $p $a $r"
      rm -f $O/$p.$a.$r.out
      RIG_X=$a /usr/bin/time -f %M -o $O/$p.$a.$r.rss taskset -c 8 $B -p tsconfig.trig.json --noEmit --singleThreaded > /dev/null 2>&1
    done
  done
done
echo done
