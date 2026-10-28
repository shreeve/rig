#!/bin/sh
# On pup: mkpgo.sh NAME CEIL_ARGS|-: Trig built --release --pgo as Trig
# ships it (trained by Trig's tools/trig/bolt-train: mitt, neverthrow,
# superstruct, zod3), by Rig 773978d1d, with ceil.py's variant made of the
# emitted package first (zigw). Cores 0,5.
set -u
W=/zfs/worktrees/rig/check-bisect
T=/zfs/trig-pup/full/trig
name=$1 args=$2
[ "$args" = - ] && args=
d=$W/v/$name
rm -rf $d && mkdir -p $d
cd $W/emit/src
start=$(date +%s)
CEIL_ARGS="$args" ZIG=$W/zigw RIG_OUT_DIR=$d/pkg RIG_NO_CRASH_REPORT=1 TRIG_RELEASE_SLOTS="0,5 0,5 0,5" sh /zfs/trig-pup/trial/slot.sh $W/rig/bin/rig build --release --pgo --pgo-profile=$d/trig.profdata -o $d/bin $W/emit/src/main.rig -- $T/tools/trig/bolt-train $d/bin > $d/build.log 2>&1
e=$?
echo "$(date +%T) pgo $name exit=$e made=$([ -e $d/pkg/.ceil-made ] && echo yes || echo no) in $(( $(date +%s) - start )) s"
rm -rf $d/pkg/.zig-cache $d/pkg/pgo
