#!/bin/sh
# On pup: mkpgo.sh NAME SRC PATCH|- MODE: Trig (SRC: a copy of Trig 2ba0719's
# src/ with tools/trig/main.rig as main.rig) built --pgo by Rig main 179c50afa
# as Trig ships it (trained by tools/trig/bolt-train), with PATCH applied to
# the emitted package before its first zig build-exe (zigw). E-core slots.
# RIG names another Rig (the second round: #810's, /zfs/trig-pup/rig-store-forward).
set -u
RIG=${RIG:-/zfs/worktrees/rig/codegen-gap/rig/bin/rig}
W=/zfs/worktrees/rig/codegen-gap
name=$1 src=$2 patch=$3 mode=$4
d=$W/v/$name
rm -rf $d && mkdir -p $d
[ "$patch" = - ] && patch=
cd $src
start=$(date +%s)
CEIL_PATCH=$patch ZIG=$W/zigw RIG_OUT_DIR=$d/out RIG_NO_CRASH_REPORT=1 TRIG_RELEASE_SLOTS='12,13 14,15 16,17' taskset -c 12-19 sh /zfs/trig-pup/trial/slot.sh $RIG build $mode --pgo --pgo-profile=$d/trig.profdata -o $d/bin $src/main.rig -- $W/trig/tools/trig/bolt-train $d/bin > $d/build.log 2>&1
e=$?
echo "$(date +%T) pgo $name $mode exit=$e patched=$([ -e $d/out/.ceil-patched ] && echo yes || echo no) in $(( $(date +%s) - start )) s sha=$(sha256sum $d/bin 2>/dev/null | cut -c1-16)"
rm -rf $d/out/.zig-cache $d/out/pgo
