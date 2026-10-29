#!/bin/sh
# On pup: mk.sh NAME [MODE]: compile v/NAME/pkg as rig build --release
# does (zig build-exe -Osafe -fomit-frame-pointer), on release slot 10,11.
# MODE is -Osafe (default) or -Ofast.
set -u
W=/zfs/worktrees/rig/trig-zig-ceiling
d=$W/v/$1 mode=${2:--Osafe}
export TRIG_RELEASE_SLOTS="10,11"
start=$(date +%s)
sh /zfs/trig-pup/trial/slot.sh zig build-exe $mode -fomit-frame-pointer --cache-dir $d/pkg/.zig-cache $d/pkg/__rig_main.zig -femit-bin=$d/bin > $d/build.log 2>&1
e=$?
echo "$(date +%T) $1 $mode exit=$e in $(( $(date +%s) - start )) s"
rm -rf $d/pkg/.zig-cache
exit $e
