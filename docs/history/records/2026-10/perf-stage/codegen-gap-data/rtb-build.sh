#!/bin/sh
# On pup: Rig main 144f70057 (base) and the rt-by-value branch (item1)
# built on the E-cores; then Trig 2ba0719 PGO by each, and by item1 with
# ordered.zig's volatile key copy (vol), one at a time on the E-core slots.
set -u
W=/zfs/worktrees/rig/rt-by-value
CG=/zfs/worktrees/rig/codegen-gap
NEXUS=/zfs/rig/nexus/bin/nexus
cd $W
log() { echo "$(date '+%H:%M:%S') $*"; }
if [ ! -x $W/rig-base/bin/rig ]; then
  rm -rf rig-base && git -c advice.detachedHead=false clone -q /zfs/trig-pup/rig rig-base && cd rig-base
  git remote set-url origin https://github.com/shreeve/rig.git && git fetch -q origin && git -c advice.detachedHead=false checkout -q --detach 144f70057
  taskset -c 12-19 zig build -Dnexus=$NEXUS > build.log 2>&1 || { log "base rig FAILED"; tail -5 build.log; exit 1; }
  cd $W; log "base rig built"
fi
if [ ! -x $W/rig-item1/bin/rig ]; then
  cd rig-item1 && rm -f .git && taskset -c 12-19 zig build -Dnexus=$NEXUS > build.log 2>&1 || { log "item1 rig FAILED"; tail -5 build.log; exit 1; }
  cd $W; log "item1 rig built"
fi
# The volatile arm's patch is against the package's rig/ordered.zig.
RIG=$W/rig-base/bin/rig sh $CG/mkpgo.sh rtb-base $CG/trig/src - --release
RIG=$W/rig-item1/bin/rig sh $CG/mkpgo.sh rtb-item1 $CG/trig/src - --release
RIG=$W/rig-item1/bin/rig sh $CG/mkpgo.sh rtb-vol $CG/trig/src $W/ordered-volatile.patch --release
log done
