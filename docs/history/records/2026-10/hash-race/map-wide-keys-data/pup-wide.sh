#!/bin/sh
# On pup: bench/hash's wide-key rows (pair, triple), core 3, N rounds interleaved:
# map.rig by Rig main and each variant; map.zig on bench/hash/ordered.zig (the
# hand-written ceiling), its entries without the hash and with it, unchecked and
# with Rig's bounds tests (-checked).
set -u
O=/zfs/worktrees/rig/mwk; N=${1:-5}; RV=${RV:-"base nh nhnp"}
export TRIG_RELEASE_SLOTS='10,11'
mkdir -p $O/wide
for v in $RV; do
  [ -x $O/wide/rig-$v ] || RIG_OUT_DIR=$O/wide/out-$v sh /zfs/trig-pup/trial/slot.sh $O/rig-$v/bin/rig build --release -o $O/wide/rig-$v $O/map.rig > $O/wide/build-$v.log 2>&1
done
B=""
for v in $RV; do B="$B $O/wide/rig-$v"; done
for kh in false true; do for z in zig-ordered zig-ordered-checked; do B="$B $O/bh/zo-$kh/$z"; done; done
for r in $(seq 1 $N); do
  for b in $B; do
    n=$(echo $b | sed "s|$O/||; s|/|_|g")
    taskset -c 3 $b 2>&1 | grep -E "^(pair|triple) " > $O/wide/$n.$r.txt
  done
done
echo done
