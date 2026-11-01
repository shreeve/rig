#!/bin/sh
# mk.sh NAME...: compile v/NAME/pkg as rig build --release does
# (zig build-exe -Osafe -fomit-frame-pointer), through slot.sh on the
# E-cores, one after another.
W=/zfs/worktrees/rig/scan-yield-study
export TRIG_RELEASE_SLOTS="12,13 14,15 16,17"
export PATH=$HOME/.local/bin:$PATH
for n in "$@"; do
  d=$W/v/$n; start=$(date +%s)
  sh /zfs/trig-pup/trial/slot.sh zig build-exe -Osafe -fomit-frame-pointer --cache-dir $d/pkg/.zig-cache $d/pkg/__rig_main.zig -femit-bin=$d/bin > $d/build.log 2>&1
  e=$?
  echo "$(date +%T) $n -Osafe exit=$e in $(( $(date +%s) - start )) s"
  rm -rf $d/pkg/.zig-cache
done
