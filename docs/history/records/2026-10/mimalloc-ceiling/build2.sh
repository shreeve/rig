#!/bin/sh
# build2.sh NAME RIG [mimalloc]: Trig main built release with the Rig in
# rig-RIG (built first if it has no bin/rig), through zig-wrap.sh (libc
# linked; with `mimalloc`, mimalloc's static.c in the runtime's module),
# into trig-NAME/bin. Cores 0,5, under any of the three release slots.
set -u
A=/zfs/worktrees/rig/alloc-grow
export PATH=$HOME/.local/bin:$PATH NEXUS=/zfs/rig/nexus/bin/nexus XDG_CACHE_HOME=/zfs/rig/xdg-cache
name=$1; rig=$2
[ -x $A/rig-$rig/bin/rig ] || (cd $A/rig-$rig && taskset -c 0,5 zig build -Dnexus=$NEXUS > $A/rig-$rig.log 2>&1) || { echo "rig $rig failed"; tail -5 $A/rig-$rig.log; exit 1; }
H=$A/trig-$name; rm -rf $H && mkdir -p $H/pack/src && for m in $A/trig/src/*/; do ln -sfn $m $H/pack/src/$(basename $m); done
cp $A/trig/tools/trig/main.rig $H/pack/src/main.rig
MIX=; [ "${3:-}" = mimalloc ] && MIX=$A/mimalloc
MI=$MIX ZIG=$A/zig-wrap.sh RIG_OUT_DIR=$H/out RIG_NO_CRASH_REPORT=1 TRIG_RELEASE_SLOTS="0,5 0,5 0,5" sh /zfs/trig-pup/trial/slot.sh $A/rig-$rig/bin/rig build --release -o $H/bin $H/pack/src/main.rig > $H/build.log 2>&1 || { echo "trig $name failed"; tail -5 $H/build.log; exit 1; }
rm -rf $H/out
echo "built $name"
