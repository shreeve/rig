#!/bin/bash
# prep.sh: on pup E-cores 12-19, the builds slot-rb.sh times against: the bench programs (rig-safe) into
# bench-<name>, with the http load generator copied from bench-remeasure-3f4564a4b (same source; pup has no Go),
# and one Trig release build to warm the global Zig cache. Writes sha16 files for slot-rb.sh to check.
set -eu
D=/zfs/trig-pup/revamp-base; cd $D
export RIG=$D/bin/rig
for b in tasks actors net http; do
  mkdir -p $D/bench-$b
  [ $b = http ] && cp -n /zfs/trig-pup/bench-remeasure-3f4564a4b/build/http/load $D/bench-$b/load
  python3 rig/bench/$b/bench-$b --variants rig-safe --out $D/bench-$b --build-only
  sha256sum $D/bench-$b/rig-safe | cut -c1-16 > $D/bench-$b/rig-safe.sha16
done
cmds/trig-build.sh $RIG $D/trig-prog 1 $D/prep-trig
echo prep done
