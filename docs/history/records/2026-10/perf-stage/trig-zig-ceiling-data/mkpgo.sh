#!/bin/sh
# On pup: mkpgo.sh NAME PATCH|- MODE: Trig built --pgo as Trig ships it
# (trained by tools/trig/bolt-train), by Rig main, with PATCH applied to the
# emitted package first (zigw); MODE --release or --release=fast. Slot 10,11.
set -u
W=/zfs/worktrees/rig/trig-zig-ceiling
T=/zfs/trig-pup/full/trig
name=$1 patch=$2 mode=$3
d=$W/pgo/$name
rm -rf $d && mkdir -p $d
[ "$patch" = - ] && patch=
cd $W/v/main/src
start=$(date +%s)
CEIL_PATCH=$patch ZIG=$W/zigw RIG_OUT_DIR=$d/out RIG_NO_CRASH_REPORT=1 TRIG_RELEASE_SLOTS=10,11 sh /zfs/trig-pup/trial/slot.sh $W/rig/bin/rig build $mode --pgo --pgo-profile=$d/trig.profdata -o $d/bin $W/v/main/src/main.rig -- $T/tools/trig/bolt-train $d/bin > $d/build.log 2>&1
e=$?
echo "$(date +%T) pgo $name $mode exit=$e patched=$([ -e $d/out/.ceil-patched ] && echo yes || echo no) in $(( $(date +%s) - start )) s"
rm -rf $d/out/.zig-cache $d/out/pgo
