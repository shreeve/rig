#!/bin/sh
# build3.sh NAME...: one at a time, each step under Trig's slot lock
# (/zfs/trig-pup/trial/slot.sh), each started only with 10 GB available.
S=/zfs/worktrees/rig/len-map
SLOT="sh /zfs/trig-pup/trial/slot.sh"
export XDG_CACHE_HOME=/zfs/rig/xdg-cache RIG_NO_CRASH_REPORT=1
mem() { until [ "$(free -g | awk "/^Mem:/ {print \$7}")" -ge 10 ]; do sleep 30; done; }
for name in "$@"; do
  start=$(date +%s)
  if [ ! -x $S/rig-$name/bin/rig ]; then
    mem; (cd $S/rig-$name && $SLOT zig build -Dnexus=/zfs/rig/nexus/bin/nexus) > $S/logs/rig-$name.log 2>&1
  fi
  mem
  (cd $S/trig/src && export RIG_OUT_DIR=$S/out/$name && case $name in *map*) export RIG_MEASURE_MAP=1;; esac &&
    $SLOT $S/rig-$name/bin/rig build --release -o $S/bins/$name trig_main.rig) > $S/logs/build-$name.log 2>&1
  echo "$name built in $(( $(date +%s) - start ))s, status $?" >> $S/logs/build-$name.log
done
