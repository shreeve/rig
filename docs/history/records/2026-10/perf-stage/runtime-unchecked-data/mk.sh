#!/bin/sh
# On pup: mk.sh NAME [SRC]: v/NAME/pkg is check-bisect's emitted package
# (Trig 403a823 by Rig main), with the runtime files in SRC (a directory
# of runtime.zig, table.zig, alloc.zig, ...) copied over its rig/ when
# given; compiled as rig build --release does (zig build-exe -Osafe
# -fomit-frame-pointer), on release slots 0,5 only.
set -u
W=/zfs/worktrees/rig/runtime-unchecked
d=$W/v/$1
mkdir -p $d
[ -e $d/pkg ] || cp -r /zfs/worktrees/rig/check-bisect/emit/pkg $d/pkg
[ -n "${2:-}" ] && cp $2/*.zig $d/pkg/rig/
export TRIG_RELEASE_SLOTS="0,5 0,5 0,5"
start=$(date +%s)
sh /zfs/trig-pup/trial/slot.sh /home/shreeve/.local/bin/zig build-exe -Osafe -fomit-frame-pointer --cache-dir $d/zig-cache $d/pkg/__rig_main.zig -femit-bin=$d/bin > $d/build.log 2>&1
e=$?
echo "$(date +%T) $1 exit=$e in $(( $(date +%s) - start )) s"
rm -rf /zfs/worktrees/rig/runtime-unchecked/v/$1/zig-cache
exit $e
