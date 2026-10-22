#!/bin/sh
# build4.sh NAME...: build3.sh, each step started only with 12 GB available
# and at most one other release build (zig build-exe -Osafe) running;
# polls every three minutes.
S=/zfs/worktrees/rig/len-map
SLOT="sh /zfs/trig-pup/trial/slot.sh"
export XDG_CACHE_HOME=/zfs/rig/xdg-cache RIG_NO_CRASH_REPORT=1
gate() {
  until [ "$(free -g | awk "/^Mem:/ {print \$7}")" -ge 12 ] && [ "$(ps -eo args | grep -c "^[^ ]*zig build-exe -Osafe")" -le 1 ]; do sleep 180; done
}
for name in "$@"; do
  start=$(date +%s)
  if [ ! -x $S/rig-$name/bin/rig ]; then
    gate; (cd $S/rig-$name && $SLOT zig build -Dnexus=/zfs/rig/nexus/bin/nexus) > $S/logs/rig-$name.log 2>&1
  fi
  gate
  (cd $S/trig/src && export RIG_OUT_DIR=$S/out/$name && case $name in *map*) export RIG_MEASURE_MAP=1;; esac &&
    $SLOT $S/rig-$name/bin/rig build --release -o $S/bins/$name trig_main.rig) > $S/logs/build-$name.log 2>&1
  st=$?
  echo "$name built in $(( $(date +%s) - start ))s, status $st" >> $S/logs/build-$name.log
done
