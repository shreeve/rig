#!/bin/sh
# On pup: build Rig main and the branch (bin/rig), then each concurrency
# bench's rig-fast and rig-safe with each, into bench-out/{main,branch}/NAME,
# every build on release slots 0,5.
set -u
W=/zfs/worktrees/rig/runtime-unchecked
N=/home/shreeve/Data/Code/nexus/bin/nexus
export TRIG_RELEASE_SLOTS="0,5 0,5 0,5"
[ -d $W/rig-main ] || { git clone -q --shared $W/rig $W/rig-main && (cd $W/rig-main && git fetch -q origin main && git checkout -q FETCH_HEAD); }
for r in rig rig-main; do
  (cd $W/$r && sh /zfs/trig-pup/trial/slot.sh /home/shreeve/.local/bin/zig build -Dnexus=$N > $W/build-$r.log 2>&1; echo "$r $(git log --oneline -1 | cut -c1-60) build exit=$?")
done
for side in main branch; do
  r=$W/rig; [ $side = main ] && r=$W/rig-main
  for b in tasks actors net http; do
    mkdir -p $W/bench-out/$side
    (cd $W/rig && RIG=$r/bin/rig sh /zfs/trig-pup/trial/slot.sh python3 bench/$b/bench-$b --variants rig-fast,rig-safe --out $W/bench-out/$side/$b --build-only > $W/bench-out/$side/$b.build.log 2>&1; echo "$side $b build exit=$?")
  done
done
