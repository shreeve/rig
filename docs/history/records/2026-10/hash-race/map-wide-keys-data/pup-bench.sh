#!/bin/sh
# On pup: bench/hash/map.rig built by each Rig, then N rounds interleaved on core 3.
set -u
O=/zfs/worktrees/rig/mwk; N=${1:-3}; VS=${VS:-"base b4 il"}
export TRIG_RELEASE_SLOTS='10,11'
mkdir -p $O/bh
for v in $VS; do
  [ -x $O/bh/map-$v ] || RIG_OUT_DIR=$O/bh/out-$v sh /zfs/trig-pup/trial/slot.sh $O/rig-$v/bin/rig build --release -o $O/bh/map-$v $O/map.rig > $O/bh/build-$v.log 2>&1
done
for r in $(seq 1 $N); do for v in $VS; do taskset -c 3 $O/bh/map-$v > $O/bh/$v-$r.txt; done; done
echo done
