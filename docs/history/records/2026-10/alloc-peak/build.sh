#!/bin/sh
# build.sh NAME...: Rig in rig-NAME (cores 0,5), then Trig main with it
# in trig-NAME/bin (release slot 0,5).
set -u
A=/zfs/worktrees/rig/alloc-peak
export PATH=$HOME/.local/bin:$PATH NEXUS=/zfs/rig/nexus/bin/nexus XDG_CACHE_HOME=/zfs/rig/xdg-cache
[ -d $A/trig ] || git clone -q /zfs/trig-pup/full/trig $A/trig
for name in "$@"; do
  (cd $A/rig-$name && taskset -c 0,5 zig build -Dnexus=$NEXUS > $A/rig-$name.log 2>&1) || { echo "rig $name failed"; tail -5 $A/rig-$name.log; exit 1; }
  H=$A/trig-$name; rm -rf $H && mkdir -p $H/pack/src && for m in $A/trig/src/*/; do ln -sfn $m $H/pack/src/$(basename $m); done
  cp $A/trig/tools/trig/main.rig $H/pack/src/main.rig
  RIG_OUT_DIR=$H/out RIG_NO_CRASH_REPORT=1 TRIG_RELEASE_SLOTS="0,5" sh /zfs/trig-pup/trial/slot.sh $A/rig-$name/bin/rig build --release -o $H/bin $H/pack/src/main.rig > $H/build.log 2>&1 || { echo "trig $name failed"; tail -5 $H/build.log; exit 1; }
  rm -rf $H/out
  echo "built $name"
done
