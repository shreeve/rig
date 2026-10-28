#!/bin/sh
# On pup: mk.sh NAME [MODE]: compile v/NAME/pkg as rig build --release
# does (zig build-exe -Osafe -fomit-frame-pointer), on release slot 0,5.
set -u
W=/zfs/worktrees/rig/check-bisect
d=$W/v/$1 mode=${2:--Osafe}
# Cores 0,5 only. Each list entry is a lock (by position), and a lone
# "0,5" shares lock 0 with every 10,11 build; three entries on 0,5 let
# this take whichever lock is free, still only on cores 0,5. queue.sh
# runs one build at a time.
export TRIG_RELEASE_SLOTS="0,5 0,5 0,5"
start=$(date +%s)
sh /zfs/trig-pup/trial/slot.sh zig build-exe $mode -fomit-frame-pointer --cache-dir $d/pkg/.zig-cache $d/pkg/__rig_main.zig -femit-bin=$d/bin > $d/build.log 2>&1
e=$?
echo "$(date +%T) $1 $mode exit=$e in $(( $(date +%s) - start )) s"
rm -rf $d/pkg/.zig-cache
exit $e
