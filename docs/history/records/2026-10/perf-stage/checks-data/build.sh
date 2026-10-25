#!/bin/sh
# build.sh VARIANT...: build the measuring Rig once, then Trig per variant
# (RIG_MEASURE_UNCHECKED=kinds; base unset), each on a release slot.
S=/zfs/worktrees/rig/perf-checks
SLOT="sh /zfs/trig-pup/trial/slot.sh"
export XDG_CACHE_HOME=/zfs/rig/xdg-cache RIG_NO_CRASH_REPORT=1 PATH=$HOME/.local/bin:$PATH
if [ ! -x $S/rig-meas/bin/rig ]; then
  (cd $S/rig-meas && $SLOT zig build -Dnexus=/zfs/rig/nexus/bin/nexus) > $S/logs/rig-meas.log 2>&1 || { echo rig build failed >> $S/logs/rig-meas.log; exit 1; }
fi
for name in "$@"; do
  start=$(date +%s)
  case $name in
    base) kinds= ;;
    all) kinds=index,cast,overflow,bounds,union,unwrap,other ;;
    *) kinds=$(echo $name | tr + ,) ;;
  esac
  (cd $S/trig && rm -rf $S/out/$name && export RIG_OUT_DIR=$S/out/$name &&
    if [ -n "$kinds" ]; then export RIG_MEASURE_UNCHECKED=$kinds; fi &&
    $SLOT $S/rig-meas/bin/rig build --release -o $S/bins/$name pack/src/main.rig) > $S/logs/build-$name.log 2>&1
  echo "$name built in $(( $(date +%s) - start ))s, status $?" >> $S/logs/build-$name.log
done
echo ALLDONE > $S/logs/done
