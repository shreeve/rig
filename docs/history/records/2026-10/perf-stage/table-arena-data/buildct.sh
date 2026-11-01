#!/bin/sh
# Trig checker-tasks (ad9ad36: aa3994b plus checkerpool.rig), plain --release,
# built by the base and fix2 Rigs, after buildtrigs.sh is done.
W=/zfs/worktrees/rig/item15
while pgrep -f "buildtrigs.sh" > /dev/null; do sleep 10; done
for v in ${*:-fix2 base}; do
  d=$W/v/$v-ct; rm -rf $d; mkdir -p $d
  s=$(date +%s)
  (cd $W/trig-ct/src && RIG_OUT_DIR=$d/out RIG_NO_CRASH_REPORT=1 TRIG_RELEASE_SLOTS="12,13 14,15 16,17" taskset -c 12-19 sh /zfs/trig-pup/trial/slot.sh $W/$v/bin/rig build --release -o $d/bin $W/trig-ct/src/main.rig > $d/build.log 2>&1)
  echo "$(date +%T) trig-ct $v exit=$? in $(( $(date +%s) - s )) s"
  rm -rf $d/out/.zig-cache
done
