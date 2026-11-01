#!/bin/sh
# Trig main (aa3994b), plain --release, built by each Rig, on E-core slots.
W=/zfs/worktrees/rig/item15
:
for v in ${*:-base fix3 fix2}; do
  d=$W/v/$v; rm -rf $d; mkdir -p $d
  s=$(date +%s)
  (cd $W/trig/src && RIG_OUT_DIR=$d/out RIG_NO_CRASH_REPORT=1 TRIG_RELEASE_SLOTS="12,13 14,15 16,17" taskset -c 12-19 sh /zfs/trig-pup/trial/slot.sh $W/$v/bin/rig build --release -o $d/bin $W/trig/src/main.rig > $d/build.log 2>&1)
  e=$?
  echo "$(date +%T) trig $v exit=$e in $(( $(date +%s) - s )) s sha=$(sha256sum $d/bin 2>/dev/null | cut -c1-16)"
  rm -rf $d/out/.zig-cache
done
